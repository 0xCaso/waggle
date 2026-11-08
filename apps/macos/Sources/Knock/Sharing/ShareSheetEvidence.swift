import AppKit
import SwiftUI

/// Evidence only (WAG-387): `KNOCK_EVIDENCE_SHARE_SHEET=<png path>[,<state>[,<delay s>]]` opens the Share
/// sheet of the first case on screen and draws the sheet window to a PNG with `cacheDisplay`, once. It
/// never reads the screen or another app's windows, so it needs no Screen Recording permission.
/// `<state>`: `link` (default), `emails` (two emails typed), `error` (presses Share, so an unreachable
/// relay shows its line), or `open` (the sheet as it opens, for a case already shared or with sharing off).
@MainActor
enum ShareSheetEvidence {
    private static var fired = false

    /// Called by the Share button once its model loaded. Returns true when the sheet should open.
    static func prepare(_ model: SharingModel) -> Bool {
        guard !fired, let raw = ProcessInfo.processInfo.environment["KNOCK_EVIDENCE_SHARE_SHEET"], !raw.isEmpty else {
            return false
        }
        fired = true
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let path = parts.first, !path.isEmpty else { return false }
        let state = parts.count > 1 ? parts[1] : "link"
        let delay = parts.count > 2 ? Double(parts[2]) ?? 3 : 3
        switch state {
        case "emails":
            model.mode = .emails
            model.emailText = "ada@example.com, bo@example.com"
        case "error":
            model.mode = .link
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Task { await model.share() } }
        default:
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { write(to: path) }
        return true
    }

    private static func write(to path: String) {
        guard let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }),
              let content = sheet.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            FileHandle.standardError.write(Data("share-sheet-shot: no sheet window\n".utf8))
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        writeInWindow(sheet: sheet, sheetRep: rep, path: path)
    }

    /// The same sheet drawn over its parent window's content, where macOS shows it: `<name>-in-window.png`.
    private static func writeInWindow(sheet: NSWindow, sheetRep: NSBitmapImageRep, path: String) {
        guard let parent = sheet.sheetParent, let content = parent.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        let size = content.bounds.size
        let parentContent = parent.contentRect(forFrameRect: parent.frame)
        let frame = NSRect(x: sheet.frame.minX - parentContent.minX, y: sheet.frame.minY - parentContent.minY,
                           width: sheet.frame.width, height: sheet.frame.height)
        let out = NSImage(size: size)
        out.lockFocus()
        rep.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSColor.black.withAlphaComponent(0.08).setFill()
        NSRect(origin: .zero, size: size).fill(using: .sourceOver)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 24
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.set()
        NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12).addClip()
        sheetRep.draw(in: frame)
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let target = path.hasSuffix(".png") ? String(path.dropLast(4)) + "-in-window.png" : path + "-in-window.png"
        try? png.write(to: URL(fileURLWithPath: target))
    }
}
