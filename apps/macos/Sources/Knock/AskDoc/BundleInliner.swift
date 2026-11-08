import Foundation

/// Makes a self-contained copy of a bundle page for "In the browser" (WAG-283).
///
/// The browser frame is sandboxed without `allow-same-origin`, so its origin is opaque and Chrome refuses
/// every `file:` subresource ("Not allowed to load local resource"). No CSP source can lift that. So the
/// page's own local files are inlined as `data:` URIs instead (images, srcset, CSS `url()`, fonts, media),
/// plus local stylesheets and scripts. A reference is inlined only if it is a relative path that stays
/// inside the bundle root. Remote URLs, absolute paths, `file:` URLs and `..` escapes are left alone, so
/// they stay blocked by the frame CSP.
struct BundleInliner {
    static let maxFileBytes = 25_000_000
    static let maxTotalBytes = 120_000_000

    private let root: String
    private var total = 0

    init(root: URL) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func inline(html: String, entry: URL, root: URL) -> String {
        var inliner = BundleInliner(root: root)
        return inliner.page(html, base: entry.deletingLastPathComponent())
    }

    // MARK: Resolving

    /// The file a reference names, or nil when it is remote, absolute, outside the root or too big.
    func resolve(_ reference: String, base: URL) -> URL? {
        var ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = ref.firstIndex(where: { $0 == "?" || $0 == "#" }) { ref = String(ref[..<cut]) }
        guard !ref.isEmpty, !ref.hasPrefix("/"), !ref.hasPrefix("\\"),
              ref.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil,
              let decoded = ref.removingPercentEncoding, !decoded.contains("\0") else { return nil }
        let file = URL(fileURLWithPath: decoded, relativeTo: base).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root + "/") else { return nil }
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize, size <= Self.maxFileBytes else { return nil }
        return file
    }

    private mutating func data(_ reference: String, base: URL) -> (url: URL, data: Data)? {
        guard let file = resolve(reference, base: base), let data = try? Data(contentsOf: file),
              total + data.count <= Self.maxTotalBytes else { return nil }
        total += data.count
        return (file, data)
    }

    private mutating func dataURI(_ reference: String, base: URL) -> String? {
        guard let (file, data) = data(reference, base: base) else { return nil }
        return "data:\(Self.mime(file.pathExtension));base64,\(data.base64EncodedString())"
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "bmp": return "image/bmp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        case "m4a": return "audio/mp4"
        case "css": return "text/css"
        case "js", "mjs": return "text/javascript"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }

    // MARK: Rewriting

    private mutating func page(_ html: String, base: URL) -> String {
        var out = html
        out = replacing(out, #"<link\b[^>]*>"#) { me, g in
            let tag = g[0]
            guard tag.range(of: #"rel\s*=\s*["']?[^"'>]*stylesheet"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  let href = me.attribute("href", in: tag), let (file, bytes) = me.data(href, base: base),
                  let css = String(data: bytes, encoding: .utf8) else { return nil }
            return "<style>\(me.css(css, base: file.deletingLastPathComponent()))</style>"
        }
        out = replacing(out, #"<script\b[^>]*\bsrc\s*=[^>]*>\s*</script\s*>"#) { me, g in
            let tag = g[0]
            guard let src = me.attribute("src", in: tag), let (_, bytes) = me.data(src, base: base),
                  let js = String(data: bytes, encoding: .utf8) else { return nil }
            let open = tag.replacingOccurrences(of: #"\s+src\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, with: "",
                                                options: [.regularExpression, .caseInsensitive])
            guard let end = open.firstIndex(of: ">") else { return nil }
            let safe = js.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
            return "\(open[...end])\(safe)</script>"
        }
        out = replacing(out, #"(<style\b[^>]*>)(.*?)(</style\s*>)"#, options: [.caseInsensitive, .dotMatchesLineSeparators]) { me, g in
            "\(g[1])\(me.css(g[2], base: base))\(g[3])"
        }
        out = replacing(out, #"<(?:img|source|video|audio|input|image)\b[^>]*>"#) { me, g in
            var tag = g[0]
            for name in ["src", "poster"] {
                if let value = me.attribute(name, in: tag), let uri = me.dataURI(value, base: base) {
                    tag = me.setAttribute(name, to: uri, in: tag)
                }
            }
            if let value = me.attribute("srcset", in: tag) {
                tag = me.setAttribute("srcset", to: me.srcset(value, base: base), in: tag)
            }
            return tag
        }
        out = replacing(out, #"\bstyle\s*=\s*"([^"]*)""#) { me, g in
            "style=\"\(me.css(g[1], base: base))\""
        }
        return out
    }

    private mutating func srcset(_ value: String, base: URL) -> String {
        value.split(separator: ",", omittingEmptySubsequences: true).map { part -> String in
            let pieces = part.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1)
            guard let first = pieces.first else { return String(part) }
            let url = dataURI(String(first), base: base) ?? String(first)
            return pieces.count > 1 ? "\(url) \(pieces[1])" : url
        }.joined(separator: ", ")
    }

    /// CSS text with each local `url()` inlined.
    private mutating func css(_ text: String, base: URL) -> String {
        replacing(text, #"url\(\s*(["']?)([^"')]*)\1\s*\)"#) { me, g in
            guard let uri = me.dataURI(g[2], base: base) else { return nil }
            return "url(\(uri))"
        }
    }

    // MARK: Helpers

    private func attribute(_ name: String, in tag: String) -> String? {
        guard let match = tag.range(of: #"\b"# + name + #"\s*=\s*("[^"]*"|'[^']*'|[^\s>"']+)"#,
                                    options: [.regularExpression, .caseInsensitive]) else { return nil }
        let text = tag[match]
        var value = String(text[text.index(after: text.firstIndex(of: "=")!)...]).trimmingCharacters(in: .whitespaces)
        if let q = value.first, q == "\"" || q == "'" { value = String(value.dropFirst().dropLast()) }
        return value.replacingOccurrences(of: "&amp;", with: "&")
    }

    private func setAttribute(_ name: String, to value: String, in tag: String) -> String {
        guard let match = tag.range(of: #"\b"# + name + #"\s*=\s*("[^"]*"|'[^']*'|[^\s>"']+)"#,
                                    options: [.regularExpression, .caseInsensitive]) else { return tag }
        var copy = tag
        copy.replaceSubrange(match, with: "\(name)=\"\(value)\"")
        return copy
    }

    private mutating func replacing(
        _ text: String, _ pattern: String, options: NSRegularExpression.Options = [.caseInsensitive],
        _ transform: (inout BundleInliner, [String]) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let parts = (0..<match.numberOfRanges).map { i -> String in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result += transform(&self, parts) ?? parts[0]
            last = match.range.location + match.range.length
        }
        return result + ns.substring(from: last)
    }
}
