import Foundation

/// The file format of a staged diagram artifact (HAIL-141): `.mmd` (Mermaid
/// source, drawn client-side by the bundled Mermaid build) or `.svg` (shown as
/// is after sanitising).
enum DiagramFormat {
    case mermaid
    case svg

    init(pathExtension: String) {
        self = pathExtension.lowercased() == "svg" ? .svg : .mermaid
    }
}

/// Sanitises a raw `.svg` file before it is shown (HAIL-141 contract): strip
/// `<script>`, `on*` attributes, `<foreignObject>`, and any `href`/`xlink:href`
/// whose value does not start with `#`. Pure string rewriting, so it is unit
/// testable without loading anything.
enum DiagramSVGSanitizer {
    static func sanitize(_ svg: String) -> String {
        var result = svg
        result = removeBlocks(of: "script", in: result)
        result = removeBlocks(of: "foreignObject", in: result)
        result = removeEventHandlerAttributes(in: result)
        result = removeExternalHrefs(in: result)
        return result
    }

    /// Removes `<element ...>...</element>` (content included) and the
    /// self-closing `<element .../>` form, case-insensitive, across newlines.
    private static func removeBlocks(of element: String, in input: String) -> String {
        let pattern = "<\(element)\\b[^>]*>.*?</\(element)\\s*>|<\(element)\\b[^>]*/>"
        return replaceAll(pattern, in: input)
    }

    /// Removes `on*="..."` / `on*='...'` / `on*=value` attributes.
    private static func removeEventHandlerAttributes(in input: String) -> String {
        let pattern = "\\s+on\\w+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)"
        return replaceAll(pattern, in: input)
    }

    /// Removes `href` and `xlink:href` attributes whose value is not a
    /// same-document fragment (`#...`). The leading whitespace is removed with
    /// the attribute so no double space is left behind.
    private static func removeExternalHrefs(in input: String) -> String {
        let pattern = "\\s+(?:xlink:)?href\\s*=\\s*(\"[^\"]*\"|'[^']*')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return input
        }
        let ns = input as NSString
        var ranges: [NSRange] = []
        regex.enumerateMatches(in: input, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let attribute = ns.substring(with: match.range)
            guard let value = hrefValue(in: attribute), !value.hasPrefix("#") else { return }
            ranges.append(match.range)
        }
        return removing(ranges, from: ns)
    }

    /// The unquoted value of `href="..."`, `href='...'`, or `href=value`.
    private static func hrefValue(in attribute: String) -> String? {
        guard let equals = attribute.firstIndex(of: "=") else { return nil }
        let after = attribute[attribute.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard let quote = after.first, quote == "\"" || quote == "'" else {
            return after.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        }
        let body = after.dropFirst()
        guard let close = body.firstIndex(of: quote) else { return nil }
        return String(body[..<close])
    }

    private static func replaceAll(_ pattern: String, in input: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "")
    }

    private static func removing(_ ranges: [NSRange], from ns: NSString) -> String {
        var result = ns as String
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            guard let r = Range(range, in: result) else { continue }
            result.removeSubrange(r)
        }
        return result
    }
}

/// Builds the small generated page the isolated web viewer shows for a
/// diagram (HAIL-141): a Mermaid page (drawing the source with the bundled
/// build) for `.mmd`, or an inline-sanitised page for `.svg`. The page is
/// offline (no network URL, no CDN) and self-contained apart from the bundled
/// `mermaid.min.js` copied next to it.
enum DiagramPage {
    /// The `document.title` the wrapper sets once the diagram is drawn (or the
    /// draw failed). The off-screen card render polls for it before it snaps.
    static let titleSentinel = "knock-diagram-done"
    static let mermaidScriptName = "mermaid.min.js"
    /// The page background, matching the viewer's light canvas
    /// (`Theme.Colors.list` 0xFAF9F7) so a diagram never sits on black.
    static let pageBackgroundHex = "#FAF9F7"

    /// The wrapper HTML for one diagram. Pure, so the "no network URLs" test
    /// can check it without materialising a file.
    static func wrapperHTML(source: String, format: DiagramFormat) -> String {
        switch format {
        case .svg:
            return svgWrapper(sanitized: DiagramSVGSanitizer.sanitize(source))
        case .mermaid:
            return mermaidWrapper(source: source)
        }
    }

    /// Writes the wrapper (and, for Mermaid, a copy of `mermaidJSURL` beside
    /// it) into `directory`, returning the entry URL to load.
    static func materialize(
        source: String, format: DiagramFormat, mermaidJSURL: URL?,
        into directory: URL, fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if format == .mermaid, let mermaidJSURL {
            let destination = directory.appendingPathComponent(mermaidScriptName)
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: mermaidJSURL, to: destination)
        }
        let entry = directory.appendingPathComponent("index.html")
        try wrapperHTML(source: source, format: format).write(to: entry, atomically: true, encoding: .utf8)
        return entry
    }

    /// A fresh, private directory for one render. Lives under the system temp
    /// root, so macOS reclaims it; a later change can add eager cleanup.
    static func makeTempDirectory(fileManager: FileManager = .default) throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("knock-diagrams", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The source embedded as a JS string literal: JSON-escaped, with `</`
    /// rewritten to `<\/` so a `</script>` inside the source cannot close the
    /// wrapper's script block early.
    static func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        var json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        if json.hasPrefix("[") && json.hasSuffix("]") {
            json = String(json.dropFirst().dropLast())
        }
        return json.replacingOccurrences(of: "</", with: "<\\/")
    }

    private static func mermaidWrapper(source: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        html, body { margin: 0; padding: 0; background: \(pageBackgroundHex); }
        #diagram { display: flex; }
        /* HAIL-158: the SVG keeps its natural size. A flex item shrinks to the layout width, and pageZoom narrows that width, so a zoomed-in diagram stopped growing. Auto margins centre it and never clip its left edge. */
        #diagram svg { flex: none; max-width: none; margin: 0 auto; }
        #diagram > :not(svg) { margin: 0 auto; }
        .knock-error { color: #c62828; font-weight: 600; margin: 0 0 12px; }
        pre.knock-source { background: #fff; border: 1px solid #ddd; border-radius: 8px; padding: 12px; white-space: pre-wrap; word-break: break-word; font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; color: #1a1a1a; }
        </style>
        <script src="\(mermaidScriptName)"></script>
        </head>
        <body>
        <div id="diagram"></div>
        <script>
        (function () {
          var source = \(jsString(source));
          function fail() {
            document.getElementById("diagram").innerHTML = '<div class="knock-error">Waggle could not draw this diagram</div><pre class="knock-source"></pre>';
            document.querySelector(".knock-source").textContent = source;
            document.title = "\(titleSentinel)";
          }
          if (typeof mermaid === "undefined") { fail(); return; }
          mermaid.initialize({ startOnLoad: false, theme: "neutral", securityLevel: "strict" });
          // mermaid.render resolves to { svg, bindFunctions }, not the SVG string.
          mermaid.render("knock-diagram-svg", source).then(function (result) {
            var container = document.getElementById("diagram");
            container.innerHTML = result.svg;
            var svg = container.querySelector("svg");
            if (svg) {
              // Mermaid's default useMaxWidth caps the SVG with `max-width` and
              // a responsive width. Draw it at its natural size so 100% zoom
              // shows the true size and Fit scales it up to the viewer width.
              svg.style.maxWidth = "none";
              var vb = svg.viewBox && svg.viewBox.baseVal;
              if (vb && vb.width > 0) {
                svg.setAttribute("width", vb.width);
                svg.setAttribute("height", vb.height);
              }
            }
            document.title = "\(titleSentinel)";
          }).catch(fail);
        })();
        </script>
        </body>
        </html>
        """
    }

    private static func svgWrapper(sanitized: String) -> String {
        let svg = deriveViewBoxIfMissing(in: sanitized)
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        html, body { margin: 0; padding: 0; background: \(pageBackgroundHex); }
        #diagram { display: flex; }
        /* HAIL-158: the SVG keeps its natural size. A flex item shrinks to the layout width, and pageZoom narrows that width, so a zoomed-in diagram stopped growing. Auto margins centre it and never clip its left edge. */
        #diagram svg { flex: none; max-width: none; margin: 0 auto; }
        #diagram > :not(svg) { margin: 0 auto; }
        </style>
        </head>
        <body>
        <div id="diagram"></div>
        <script>
        (function () {
          var svg = \(jsString(svg));
          function draw() {
            document.getElementById("diagram").innerHTML = svg;
            document.title = "\(titleSentinel)";
          }
          // Draw after the document paints: a synchronous injection during the
          // initial load is not captured by WKWebView.takeSnapshot (the
          // evidence window shot showed a blank stage). Mermaid works because
          // its own render resolves after the page has loaded; mirror that.
          if (document.readyState === "complete") { draw(); }
          else { window.addEventListener("load", draw); }
        })();
        </script>
        </body>
        </html>
        """
    }

    /// Derives a `viewBox` for an SVG that has only `width`/`height` (HAIL-141
    /// contract): the browser needs the viewBox to scale the SVG
    /// proportionally. An SVG that already has one, or whose dimensions carry
    /// units, is returned unchanged.
    static func deriveViewBoxIfMissing(in svg: String) -> String {
        guard svg.range(of: "viewBox", options: [.caseInsensitive]) == nil else { return svg }
        guard let tagRange = svg.range(of: "<svg\\b[^>]*>", options: [.regularExpression, .caseInsensitive]) else { return svg }
        let tag = String(svg[tagRange])
        guard let width = numericAttribute("width", in: tag), let height = numericAttribute("height", in: tag) else { return svg }
        let viewBox = " viewBox=\"0 0 \(width) \(height)\""
        var out = svg
        out.insert(contentsOf: viewBox, at: svg.index(tagRange.lowerBound, offsetBy: 4))
        return out
    }

    /// The unitless numeric value of an attribute (`width="520"`), or nil when
    /// it is missing or carries units (`width="100%"`, `width="520px"`).
    private static func numericAttribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*['\"]([0-9]+(?:\\.[0-9]+)?)['\"]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[valueRange])
    }
}

/// Locates the pinned Mermaid build bundled in the app's resources
/// (`Resources/Mermaid/mermaid.min.js`, MIT license shipped beside it). It
/// reuses `FontRegistration`'s non-crashing bundle lookup; `nil` means the
/// resource is missing and the wrapper shows the render-error state instead.
enum MermaidResource {
    static func mermaidJSURL(
        mainBundle: Bundle = .main, fileManager: FileManager = .default
    ) -> URL? {
        guard let bundle = FontRegistration.resourceBundleURL(mainBundle: mainBundle) else { return nil }
        let url = bundle.appendingPathComponent("Mermaid/\(DiagramPage.mermaidScriptName)")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }
}
