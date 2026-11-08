import Foundation

/// HAIL-240: the page element a comment pin points at, read from the sandboxed web view when the
/// pin is dropped. The page is untrusted, so the app reads it (`readScript` runs in the app's own
/// content world, read-only, no callback) and treats every value as data: it is capped, stripped of
/// control and direction characters, and only ever shown or sent as plain text.
struct PageElementContext: Equatable, Sendable {
    static let textCap = 80
    static let headingCap = 80
    static let valueCap = 40
    static let maxLevels = 5
    /// The most characters of the script's answer the app will even parse.
    static let rawCap = 8_000

    /// One level of the page's element tree, from the pinned element upward, as the page reports it.
    struct Node: Equatable, Sendable {
        var tag: String
        var id: String? = nil
        var dataName: String? = nil
        var dataValue: String? = nil
        /// 1-based position among siblings of the same tag.
        var nth: Int = 1
        /// How many siblings share the tag, this element included.
        var sameTagSiblings: Int = 1
    }

    /// What the element is: "button", "link", "heading", "input", "image", or its tag.
    var role: String
    var text: String
    var selector: String
    var heading: String

    /// The script for `evaluateJavaScript`. `fx`, `fy` are 0...1 of the viewport. It returns a JSON
    /// string, or null. It only reads; the page gets no way to call the app.
    static func readScript(fx: Double, fy: Double) -> String {
        let x = min(max(fx, 0), 1), y = min(max(fy, 0), 1)
        return script(find: "var el=document.elementFromPoint(\(x)*window.innerWidth,\(y)*window.innerHeight);")
    }

    /// The script for a point in page coordinates (CSS px from the top left of the document, so
    /// scroll offsets and zoom play no part). WAG-280: a pin on an old capture, or on a part of
    /// the page that is now scrolled away, still finds its element. A point inside the viewport is
    /// hit-tested, which respects overflow clipping and sideways scrollers; a point outside it
    /// takes the smallest element whose box holds the point.
    static func readScript(pageX: Double, pageY: Double) -> String {
        let x = pageX.isFinite ? max(pageX, 0) : 0, y = pageY.isFinite ? max(pageY, 0) : 0
        return script(find: """
        var px=\(x),py=\(y),sx=window.scrollX,sy=window.scrollY,el=null;
        var vx=px-sx,vy=py-sy;
        if(vx>=0&&vy>=0&&vx<window.innerWidth&&vy<window.innerHeight){el=document.elementFromPoint(vx,vy);}
        else if(document.body){var all=document.body.getElementsByTagName('*'),best=1/0;
        for(var i=0;i<all.length&&i<\(geometryScanCap);i++){var e=all[i];
        if(/^(script|style|link|meta|noscript|template)$/i.test(e.tagName))continue;
        var r=e.getBoundingClientRect();if(r.width<=0||r.height<=0)continue;
        if(px<r.left+sx||px>r.right+sx||py<r.top+sy||py>r.bottom+sy)continue;
        var a=r.width*r.height;if(a<=best){best=a;el=e;}}}
        """)
    }

    /// The most elements the page-coordinate script looks at.
    static let geometryScanCap = 5_000

    /// The shared script: `find` sets `el`; the rest describes it.
    private static func script(find: String) -> String {
        return """
        (function(){try{
        \(find)
        if(!el||el===document.documentElement||el===document.body)return null;
        var hit=el.closest('button,a[href],input,select,textarea,summary,label,[role],h1,h2,h3,h4,h5,h6,img');
        if(hit)el=hit;
        function c(v,n){return String(v==null?'':v).replace(/\\s+/g,' ').trim().slice(0,n);}
        var tag=el.tagName.toLowerCase();
        var text=c(tag==='img'?el.getAttribute('alt'):(el.innerText||el.value||el.getAttribute('aria-label')||el.getAttribute('placeholder')||el.getAttribute('title')),200);
        var chain=[];var n=el;
        for(var i=0;n&&n.nodeType===1&&n!==document.body&&n!==document.documentElement&&i<\(maxLevels);i++){
        var k=0,nth=0;var p=n.parentElement;
        if(p){for(var q=p.firstElementChild;q;q=q.nextElementSibling){if(q.tagName===n.tagName){k++;if(q===n)nth=k;}}}
        var dn=null,dv=null;
        for(var a=0;a<n.attributes.length;a++){var at=n.attributes[a];if(/^data-(testid|test|id|qa|cy|name)$/.test(at.name)){dn=at.name;dv=c(at.value,80);break;}}
        chain.push({tag:n.tagName.toLowerCase(),id:c(n.id,80),dn:dn,dv:dv,nth:nth||1,of:k||1});
        n=n.parentElement;}
        var heading='';
        var box=el.closest('figure,article,li,[role=group]');
        var own=box?box.querySelector('h1,h2,h3,h4,h5,h6'):null;
        if(own&&own!==el&&!own.contains(el))heading=c(own.textContent,200);
        if(!heading){var hs=document.querySelectorAll('h1,h2,h3,h4,h5,h6');var lvl=/^h[1-6]$/.test(tag)?+tag.charAt(1):7;
        for(var j=0;j<hs.length&&j<500;j++){var h=hs[j];if(h===el||h.contains(el))continue;
        if(h.compareDocumentPosition(el)&4){if(+h.tagName.charAt(1)<lvl)heading=c(h.textContent,200);}else break;}}
        return JSON.stringify({tag:tag,role:c(el.getAttribute('role'),20),type:c(el.getAttribute('type'),20),href:el.hasAttribute('href'),alt:el.hasAttribute('alt'),text:text,chain:chain,heading:heading});
        }catch(e){return null;}})()
        """
    }

    /// Reads the script's answer. `nil` when it is not the small JSON the script returns.
    static func parse(_ raw: Any?) -> PageElementContext? {
        guard let string = raw as? String, string.utf8.count <= rawCap,
              let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else { return nil }
        let tag = sanitizeTag(object["tag"])
        guard !tag.isEmpty else { return nil }
        let role = role(tag: tag, ariaRole: sanitizeTag(object["role"]), type: sanitizeTag(object["type"]))
        let rawChain = (object["chain"] as? [[String: Any]]) ?? []
        let nodes: [Node] = rawChain.prefix(maxLevels).compactMap { entry in
            let nodeTag = sanitizeTag(entry["tag"])
            guard !nodeTag.isEmpty else { return nil }
            return Node(
                tag: nodeTag,
                id: sanitizeIdentifier(entry["id"]),
                dataName: sanitizeDataName(entry["dn"]),
                dataValue: sanitizeIdentifier(entry["dv"]),
                nth: clampCount(entry["nth"]),
                sameTagSiblings: clampCount(entry["of"])
            )
        }
        var text = sanitize(object["text"], cap: textCap)
        if role == "input", (object["type"] as? String)?.lowercased() == "password" { text = "" }
        return PageElementContext(
            role: role, text: text, selector: selector(for: nodes), heading: sanitize(object["heading"], cap: headingCap)
        )
    }

    /// The short CSS path: from the pinned element up, stopping at the first id or data attribute,
    /// or after `maxLevels`. Written top-down: "main > section:nth-of-type(2) > button".
    static func selector(for nodes: [Node]) -> String {
        var parts: [String] = []
        for node in nodes.prefix(maxLevels) {
            if let id = node.id {
                parts.append("#\(id)")
                break
            }
            if let name = node.dataName, let value = node.dataValue {
                parts.append("[\(name)=\"\(value)\"]")
                break
            }
            parts.append(node.sameTagSiblings > 1 ? "\(node.tag):nth-of-type(\(node.nth))" : node.tag)
        }
        return parts.reversed().joined(separator: " > ")
    }

    static func role(tag: String, ariaRole: String, type: String) -> String {
        let aria: [String: String] = ["button": "button", "link": "link", "heading": "heading", "img": "image", "textbox": "input", "checkbox": "input", "tab": "tab", "menuitem": "menu item"]
        if let mapped = aria[ariaRole] { return mapped }
        switch tag {
        case "button", "summary": return "button"
        case "a": return "link"
        case "h1", "h2", "h3", "h4", "h5", "h6": return "heading"
        case "input", "textarea", "select": return type == "submit" || type == "button" ? "button" : "input"
        case "img": return "image"
        default: return tag
        }
    }

    /// "On the button "Review 3 flagged"": what a comment card says about the pinned element.
    var cardLabel: String {
        text.isEmpty ? "On the \(role)" : "On the \(role) \"\(text)\""
    }

    /// The text the agent reads for this comment: `Note` text with the element in front.
    /// "on the button "Review 3 flagged" (main > section:nth-of-type(2) > button): make it say Review now".
    func wireText(note: String) -> String {
        var target = "on the \(role)"
        if !text.isEmpty { target += " \"\(text)\"" }
        if !selector.isEmpty { target += " (\(selector))" }
        var line = "\(target): \(note)"
        if !heading.isEmpty { line += " [under the heading \"\(heading)\"]" }
        return line
    }

    // MARK: Sanitising. Everything below treats page values as hostile.

    /// Control, direction and invisible format characters never reach the agent or the UI.
    private static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: return true
        default: return false
        }
    }

    /// One line, no unsafe characters, straight quotes turned to single quotes, whitespace collapsed, capped.
    static func sanitize(_ value: Any?, cap: Int) -> String {
        guard let string = value as? String else { return "" }
        var out = String.UnicodeScalarView()
        for scalar in string.unicodeScalars.prefix(cap * 4) {
            if scalar == "\"" || scalar == "\u{201C}" || scalar == "\u{201D}" { out.append("'") }
            else if scalar.properties.isWhitespace { out.append(" ") }
            else if !isUnsafe(scalar) { out.append(scalar) }
        }
        let collapsed = String(out).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard collapsed.count > cap else { return collapsed }
        return String(collapsed.prefix(cap - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func sanitizeTag(_ value: Any?) -> String {
        guard let string = (value as? String)?.lowercased(), string.count <= 20,
              string.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil else { return "" }
        return string
    }

    private static func sanitizeDataName(_ value: Any?) -> String? {
        guard let string = (value as? String)?.lowercased(),
              string.range(of: "^data-[a-z0-9-]{1,30}$", options: .regularExpression) != nil else { return nil }
        return string
    }

    /// An id or a data value as it sits in a selector: letters, digits, `_`, `-`, `.`, `:` only.
    private static func sanitizeIdentifier(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty, string.count <= valueCap,
              string.range(of: "^[A-Za-z0-9_.:-]+$", options: .regularExpression) != nil else { return nil }
        return string
    }

    private static func clampCount(_ value: Any?) -> Int {
        min(max((value as? NSNumber)?.intValue ?? 1, 1), 999)
    }
}
