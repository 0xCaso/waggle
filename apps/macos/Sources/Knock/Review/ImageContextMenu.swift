import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Right-click on a screenshot (WAG-372): "Copy Image" puts it on the clipboard, "Save Image…" writes a PNG
/// where the person picks. The image is the one on screen; nothing goes to the agent.
enum ImageActions {
    static let copyTitle = "Copy Image"
    static let saveTitle = "Save Image…"

    @discardableResult
    static func copy(_ image: NSImage, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// "Screenshot.png" when there is no name; a name keeps only what a file name can hold.
    static func fileName(_ name: String?) -> String {
        let cleaned = (name ?? "")
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Screenshot" : cleaned
        return base.lowercased().hasSuffix(".png") ? base : base + ".png"
    }

    @MainActor
    static func save(_ image: NSImage, name: String?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileName(name)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url, let data = pngData(image) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension View {
    /// Adds "Copy Image" and "Save Image…" on right-click. No image: no menu.
    @ViewBuilder
    func imageContextMenu(_ image: NSImage?, name: String? = nil) -> some View {
        if let image {
            contextMenu {
                Button(ImageActions.copyTitle) { ImageActions.copy(image) }
                Button(ImageActions.saveTitle) { ImageActions.save(image, name: name) }
            }
        } else {
            self
        }
    }
}
