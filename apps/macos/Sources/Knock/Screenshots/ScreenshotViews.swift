import AppKit
import SwiftUI

/// Colours from the WAG-402 design (board "Screenshot to a session"). They are not in `Theme` yet.
private enum SC {
    static let ink = Color(hex: 0x1C1B19)
    static let mute = Color(hex: 0x8C8A83)
    static let ink2 = Color(hex: 0x57554F)
    static let line = Color(hex: 0xE7E5E0)
    static let working = Color(hex: 0x3B5BDB)
    static let waiting = Color(hex: 0xE0352B)
    static let idle = Color(hex: 0xB9B7B0)
    static let ended = Color(hex: 0xC2410C)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Theme.FontFamily.sans, size: size).weight(weight)
    }
}

/// A small image for a screenshot file. Decodes a thumbnail, never the full image.
struct ScreenshotThumbnail: View {
    let url: URL
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(hex: 0xF3F3F3)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(SC.line, lineWidth: 1))
        .task(id: url) {
            let url = url, longest = max(size.width, size.height) * 2
            image = await Task.detached { Self.load(url, longest: longest) }.value
        }
    }

    nonisolated static func load(_ url: URL, longest: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Badge

struct ScreenshotBadgeView: View {
    let subtitle: String?
    let onOpen: () -> Void
    let onTurnOff: () -> Void
    @State private var shown = false
    @State private var pressed = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Theme.Colors.honey300)
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(SC.ink)
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ScreenshotCopy.badgeTitle).font(SC.font(12.5, .semibold)).foregroundColor(SC.ink)
                    if let subtitle { Text(subtitle).font(SC.font(11)).foregroundColor(SC.mute).lineLimit(1) }
                }
            }
            .padding(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 14))
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().strokeBorder(SC.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
        }
        .buttonStyle(BadgePressStyle(pressed: $pressed))
        .pointerCursor()
        .contextMenu { Button(ScreenshotCopy.turnOff, action: onTurnOff) }
        .padding(14)
        .opacity(shown ? 1 : 0)
        .animation(.easeOut(duration: 0.2), value: shown)
        .onAppear { shown = true }
        .preferredColorScheme(.light)
    }
}

private struct BadgePressStyle: ButtonStyle {
    @Binding var pressed: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.onChange(of: configuration.isPressed) { _, now in pressed = now }
    }
}

// MARK: - Panel

struct ScreenshotPanelView: View {
    @ObservedObject var model: ScreenshotPanelModel
    let onClose: () -> Void
    @FocusState private var noteFocused: Bool

    var body: some View {
        Group {
            if case let .sent(name, working) = model.phase {
                sentLine(text: ScreenshotCopy.sent(to: name), sub: working ? ScreenshotCopy.workingSub : nil)
            } else if case let .started(folder) = model.phase {
                sentLine(text: ScreenshotCopy.started(in: folder), sub: nil)
            } else {
                form
            }
        }
        .frame(width: ScreenshotGeometry.panelWidth)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(SC.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 8)
        .padding(20)
        .preferredColorScheme(.light)
        .onExitCommand(perform: onClose)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            head
            if model.kind == .shortcut { shotRow }
            if model.kind == .snip, let shot = model.captures.first { snipImage(shot) }
            Text(ScreenshotCopy.sendTo).font(SC.font(10.5, .semibold)).tracking(0.5).foregroundColor(SC.mute)
            VStack(spacing: 6) {
                ForEach(model.rows) { row in sessionRow(row) }
                if model.newSession != nil { newSessionRow }
            }
            noteField
            footer
        }
        .padding(16)
    }

    private var head: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headTitle).font(SC.font(13.5, .semibold)).foregroundColor(SC.ink)
                Text(headMeta).font(SC.font(11.5)).foregroundColor(SC.mute)
            }
            Spacer(minLength: 0)
            if model.kind == .snip {
                Text(ScreenshotCopy.snipKeyChip).font(SC.font(11, .semibold)).foregroundColor(SC.mute)
                    .padding(.horizontal, 6).frame(height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SC.line, lineWidth: 1))
            }
            if model.kind == .badge, let shot = model.captures.first {
                ScreenshotThumbnail(url: shot.url, size: CGSize(width: 56, height: 36))
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundColor(SC.mute)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain).pointerCursor().accessibilityLabel("Close")
        }
    }

    private var headTitle: String {
        switch model.kind {
        case .badge: ScreenshotCopy.sendHead
        case .shortcut: ScreenshotCopy.shortcutHead
        case .snip: ScreenshotCopy.snipHead
        }
    }

    private var headMeta: String {
        switch model.kind {
        case .badge: ScreenshotCopy.justNow
        case .shortcut: ScreenshotCopy.shortcutMeta
        case .snip: model.snip?.meta ?? ""
        }
    }

    private func snipImage(_ shot: ScreenCapture) -> some View {
        ScreenshotFitImage(url: shot.url)
            .frame(maxWidth: .infinity).frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0xF6F5F2)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SC.line, lineWidth: 1))
    }

    private var newSessionRow: some View {
        let picked = model.newSessionPicked
        return HStack(spacing: 8) {
            ZStack {
                Circle().fill(Color(hex: 0xF2F1EE))
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: 0x57554F))
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(ScreenshotCopy.newSession).font(SC.font(13, .semibold)).foregroundColor(SC.ink).lineLimit(1)
                Text(model.newSession?.subtitle ?? "").font(SC.font(11.5)).foregroundColor(SC.mute).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            // The folder name matters more than the agent line, so the chip keeps its width first (WAG-405).
            folderChip.layoutPriority(1)
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.Colors.honey600)
                .opacity(picked ? 1 : 0)
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(RoundedRectangle(cornerRadius: 10).fill(picked ? Theme.Colors.honeySoft : Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(picked ? Theme.Colors.honey500 : Color.clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { model.pickNewSession() }
        .pointerCursor()
    }

    /// The folder name's width plus the padding, chevron and gap, capped at 150 pt.
    static func chipWidth(_ name: String) -> CGFloat {
        let font = NSFont(name: Theme.FontFamily.sans, size: 11.5).map { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
            ?? .systemFont(ofSize: 11.5, weight: .semibold)
        let text = (name as NSString).size(withAttributes: [.font: font]).width
        return min(150, ceil(text) + 9 * 2 + 4 + 12)
    }

    private var folderChip: some View {
        Menu {
            ForEach(model.folders) { folder in
                Button(folder.name) { model.pickFolder(folder) }
            }
            Divider()
            Button(ScreenshotCopy.otherFolder) { model.chooseOtherFolder() }
        } label: {
            HStack(spacing: 4) {
                Text(model.pickedFolderName).font(SC.font(11.5, .semibold)).foregroundColor(SC.ink).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundColor(SC.mute)
            }
            .padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().strokeBorder(SC.line, lineWidth: 1))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        // A menu button ignores its label's width, so the chip gets a measured one (WAG-406).
        .frame(width: Self.chipWidth(model.pickedFolderName))
        .pointerCursor()
    }

    private var shotRow: some View {
        Group {
            if model.captures.isEmpty {
                Text(ScreenshotCopy.noScreenshots).font(SC.font(12)).foregroundColor(SC.mute)
            } else {
                HStack(spacing: 8) {
                    ForEach(model.captures) { shot in
                        let picked = model.pickedShots.contains(shot.url)
                        Button { model.toggleShot(shot) } label: {
                            ScreenshotThumbnail(url: shot.url, size: CGSize(width: 96, height: 62))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .stroke(picked ? Theme.Colors.honey500 : Color.clear, lineWidth: 2))
                                .overlay(alignment: .topTrailing) {
                                    if picked {
                                        ZStack {
                                            Circle().fill(Theme.Colors.honey500)
                                            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundColor(.white)
                                        }
                                        .frame(width: 16, height: 16).padding(4)
                                    }
                                }
                        }
                        .buttonStyle(.plain).pointerCursor()
                    }
                }
            }
        }
    }

    private func sessionRow(_ row: ScreenshotSessionRow) -> some View {
        let picked = !model.newSessionPicked && model.pickedSession == row.id
        let ended = model.endedSessions.contains(row.id)
        let content = HStack(spacing: 10) {
                Circle().fill(dotColor(row.dot)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).font(SC.font(13, .semibold)).foregroundColor(SC.ink).lineLimit(1)
                    if !row.place.isEmpty {
                        Text(row.place).font(SC.font(11.5)).foregroundColor(SC.ink2).lineLimit(1).truncationMode(.middle)
                    }
                    if ended {
                        Text(ScreenshotCopy.sessionEnded).font(SC.font(11.5)).foregroundColor(SC.ended)
                    } else {
                        Text(row.detailLine).font(SC.font(11.5)).foregroundColor(SC.mute).lineLimit(1)
                    }
                }
                .help(row.path)
                Spacer(minLength: 0)
                if !row.canSend {
                    Button { model.copyPath(row: row) } label: {
                        Text(model.copiedRow == row.id ? ScreenshotCopy.copied : ScreenshotCopy.copyPath)
                            .font(SC.font(11.5, .semibold)).foregroundColor(SC.ink)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .overlay(Capsule().strokeBorder(SC.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain).pointerCursor()
                } else if picked {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.Colors.honey600)
                }
            }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(RoundedRectangle(cornerRadius: 10).fill(picked ? Theme.Colors.honeySoft : Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(picked ? Theme.Colors.honey500 : Color.clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        return Group {
            if row.canSend && !ended {
                Button { model.pickSession(row.id) } label: { content }.buttonStyle(.plain).pointerCursor()
            } else {
                content
            }
        }
    }

    private func dotColor(_ dot: ScreenshotSessionRow.Dot) -> Color {
        switch dot {
        case .working: SC.working
        case .waiting: SC.waiting
        case .idle: SC.idle
        }
    }

    private var noteField: some View {
        TextField(model.kind == .snip ? ScreenshotCopy.snipNotePlaceholder : ScreenshotCopy.notePlaceholder, text: $model.note, axis: .vertical)
            .textFieldStyle(.plain)
            .font(SC.font(13))
            .foregroundColor(SC.ink)
            .tint(Theme.Colors.honey600)
            .lineLimit(1...4)
            .focused($noteFocused)
            .onSubmit { Task { await model.send() } }
            .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(SC.line, lineWidth: 1))
            .onAppear { noteFocused = true }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.phase == .failed {
                Text(ScreenshotCopy.couldNotSend).font(SC.font(11.5, .semibold)).foregroundColor(SC.ended)
            }
            HStack(spacing: 8) {
                Button { Task { await model.send() } } label: {
                    Text(model.phase == .failed ? ScreenshotCopy.tryAgain : model.sendLabel)
                        .font(SC.font(13, .semibold)).foregroundColor(.white).lineLimit(1)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(Theme.Colors.ink))
                        .opacity(model.canSend || model.phase == .failed ? 1 : 0.4)
                }
                .buttonStyle(.plain).pointerCursor()
                .keyboardShortcut(.defaultAction)
                .disabled(!(model.canSend || model.phase == .failed))
                Button(action: onClose) {
                    Text(model.kind == .snip ? ScreenshotCopy.cancel : ScreenshotCopy.notNow).font(SC.font(13, .semibold)).foregroundColor(SC.ink)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.plain).pointerCursor()
                Spacer(minLength: 0)
            }
        }
    }

    private func sentLine(text: String, sub: String?) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.Colors.ok)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(SC.font(13, .semibold)).foregroundColor(SC.ink)
                if let sub { Text(sub).font(SC.font(11.5)).foregroundColor(SC.mute) }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}

/// The snip, scaled to fit its frame. Decodes a bounded thumbnail.
struct ScreenshotFitImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
        }
        .task(id: url) {
            let url = url
            image = await Task.detached { ScreenshotThumbnail.load(url, longest: 700) }.value
        }
    }
}

/// One plain line, for example when the snip could not run.
struct ScreenshotNoticeView: View {
    let text: String

    var body: some View {
        Text(text).font(SC.font(13, .semibold)).foregroundColor(SC.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: ScreenshotGeometry.panelWidth - 32, alignment: .leading)
            .padding(16)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(SC.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 8)
            .padding(20)
            .preferredColorScheme(.light)
    }
}
