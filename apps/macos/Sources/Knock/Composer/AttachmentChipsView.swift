import AppKit
import SwiftUI

/// The chips above the reply field (WAG-345): a thumbnail or a type icon, the name, the size and a × to remove.
struct AttachmentChipsRow: View {
    @ObservedObject var files: ComposerAttachments

    var body: some View {
        if !files.items.isEmpty || files.notice != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !files.items.isEmpty {
                    ChipFlowLayout(spacing: 6) {
                        ForEach(files.items) { item in
                            DraftAttachmentChip(item: item) { files.remove(item.id) }
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: files.items.map(\.id))
                }
                if let notice = files.notice {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 11))
                        Text(notice).knockTextStyle(Theme.Typography.caption11_5w400)
                    }
                    .foregroundColor(Theme.Colors.accent)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: 8, leading: 8, bottom: 2, trailing: 8))
        }
    }
}

private struct DraftAttachmentChip: View {
    let item: DraftAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            AttachmentGlyph(thumbnail: item.thumbnail, symbolName: item.symbolName)
            Text(item.name)
                .knockTextStyle(Theme.Typography.promptButton12w500)
                .foregroundColor(Theme.Colors.ink)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 170, alignment: .leading)
            Text(item.sizeText)
                .knockTextStyle(Theme.Typography.caption11_5w400)
                .foregroundColor(Theme.Colors.ink3)
                .fixedSize()
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.Colors.ink3)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerCursor()
            .accessibilityLabel("Remove \(item.name)")
            .help("Remove")
        }
        .padding(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
        .background(Theme.Colors.side)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.promptButton, style: .continuous))
        .accessibilityElement(children: .contain)
        .help(item.isHeld ? item.name : item.stagedURL.lastPathComponent)
    }
}

/// A 22 pt square: the image's own thumbnail, or the type's icon on a white tile.
struct AttachmentGlyph: View {
    let thumbnail: NSImage?
    let symbolName: String

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Colors.ink2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.Colors.win)
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Theme.Colors.ink.opacity(0.1), lineWidth: 1))
    }
}

/// A file of an answered reply (WAG-345). A click shows it in Finder; the menu opens it.
struct SentAttachmentChip: View {
    let file: ReplyAttachment
    @State private var hovered = false

    private var url: URL { URL(fileURLWithPath: file.path) }
    private var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            HStack(spacing: 7) {
                AttachmentGlyph(
                    thumbnail: file.isImage ? ComposerAttachments.thumbnail(of: url) : nil,
                    symbolName: AttachmentLook.symbolName(type: file.type, name: file.name))
                Text(file.name)
                    .knockTextStyle(Theme.Typography.promptButton12w500)
                    .foregroundColor(Theme.Colors.ink)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 170, alignment: .leading)
                Text(AttachmentLook.sizeText(file.size))
                    .knockTextStyle(Theme.Typography.caption11_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .fixedSize()
            }
            .padding(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 9))
            .background(hovered ? Theme.Colors.hover : Theme.Colors.side)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.promptButton, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .help(exists ? "Show \(file.name) in Finder" : "\(file.name) is no longer on this Mac")
        .accessibilityLabel("\(file.name), \(AttachmentLook.sizeText(file.size)). Show in Finder")
    }
}

/// The files of a reply, wrapped onto lines; nothing when the reply has none.
struct SentAttachmentsView: View {
    let files: [ReplyAttachment]

    var body: some View {
        if !files.isEmpty {
            ChipFlowLayout(spacing: 6) {
                ForEach(files) { SentAttachmentChip(file: $0) }
            }
        }
    }
}

/// Drop files on a composer and they attach (WAG-345). The nearest drop wins, so this beats the window's
/// New idea drop wherever a reply can be written.
struct AttachDropModifier: ViewModifier {
    let files: ComposerAttachments
    /// False once the reply is sent: a drop then falls through to the window.
    var enabled = true
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: enabled ? [.fileURL] : [], isTargeted: $targeted) { providers in
                FileDrop.urls(from: providers) { files.add(urls: $0) }
                return true
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .stroke(Theme.Colors.honey500, lineWidth: 2)
                        .background(Theme.Colors.honeySoft.opacity(0.45).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)))
                        .overlay(
                            Text("Drop to attach")
                                .knockTextStyle(Theme.Typography.promptButton12w500)
                                .foregroundColor(Theme.Colors.ink))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

extension View {
    /// Files dropped here attach to `files`.
    func attachesDroppedFiles(to files: ComposerAttachments, enabled: Bool = true) -> some View {
        modifier(AttachDropModifier(files: files, enabled: enabled))
    }
}

enum FileDrop {
    /// The file URLs of a drop, handed over on the main actor once every provider has answered.
    static func urls(from providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier("public.file-url") }
        guard !fileProviders.isEmpty else { return }
        let group = DispatchGroup()
        let collected = LockedURLs()
        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { collected.append(url) }
                else if let url = item as? URL { collected.append(url) }
            }
        }
        group.notify(queue: .main) {
            let urls = collected.values
            Task { @MainActor in completion(urls) }
        }
    }
}

/// The file picker of the "+" menu. No test reaches it.
enum AttachPicker {
    @MainActor
    static func pick() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose files to send with your reply"
        panel.prompt = "Attach"
        return panel.runModal() == .OK ? panel.urls : []
    }
}

final class LockedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []
    func append(_ url: URL) { lock.lock(); items.append(url); lock.unlock() }
    var values: [URL] { lock.lock(); defer { lock.unlock() }; return items }
}
