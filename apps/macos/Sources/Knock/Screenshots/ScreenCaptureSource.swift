import AppKit
import Foundation

/// Finds screenshots the operator took. Behind a protocol so tests inject fake files from a temp folder. An
/// implementation never calls `screencapture` and never reads the screen.
@MainActor
protocol ScreenCaptureSource: AnyObject {
    /// Starts the watch. `onNew` gets each screenshot that appears after this call.
    func start(onNew: @escaping (ScreenCapture) -> Void)
    func stop()
    /// The newest screenshots, newest first.
    func latest(_ count: Int) -> [ScreenCapture]
}

/// Spotlight's own list of files macOS marks as screen captures (`kMDItemIsScreenCapture`). It follows the
/// operator's screenshot folder wherever it is, so Waggle reads no system setting.
@MainActor
final class MetadataScreenCaptureSource: NSObject, ScreenCaptureSource {
    private var query: NSMetadataQuery?
    private var onNew: ((ScreenCapture) -> Void)?
    private var seen = Set<URL>()
    private var gathered = false

    func start(onNew: @escaping (ScreenCapture) -> Void) {
        stop()
        self.onNew = onNew
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K == 1", "kMDItemIsScreenCapture")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        query.notificationBatchingInterval = 0.3
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(gathered(_:)), name: .NSMetadataQueryDidFinishGathering, object: query)
        center.addObserver(self, selector: #selector(updated(_:)), name: .NSMetadataQueryDidUpdate, object: query)
        self.query = query
        gathered = false
        seen = []
        query.start()
    }

    func stop() {
        guard let query else { return }
        query.stop()
        NotificationCenter.default.removeObserver(self)
        self.query = nil
        onNew = nil
    }

    func latest(_ count: Int) -> [ScreenCapture] {
        guard let query else { return [] }
        query.disableUpdates()
        defer { query.enableUpdates() }
        let items = (query.results as? [NSMetadataItem]) ?? []
        return Array(items.compactMap(Self.capture).sorted { $0.date > $1.date }.prefix(count))
    }

    @objc private func gathered(_ note: Notification) {
        // What exists at the start is not new.
        guard let query else { return }
        query.disableUpdates()
        for case let item as NSMetadataItem in query.results { if let c = Self.capture(item) { seen.insert(c.url) } }
        query.enableUpdates()
        gathered = true
    }

    @objc private func updated(_ note: Notification) {
        guard gathered, let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] else { return }
        for item in added {
            guard let capture = Self.capture(item), seen.insert(capture.url).inserted else { continue }
            onNew?(capture)
        }
    }

    private static func capture(_ item: NSMetadataItem) -> ScreenCapture? {
        guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
        let date = (item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date)
            ?? (item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date) ?? Date()
        return ScreenCapture(url: URL(fileURLWithPath: path), date: date)
    }
}

/// Reads a folder of images. Tests and the evidence hook use it with a temp folder. `scan()` reports each image
/// that came after `start`.
@MainActor
final class FolderScreenCaptureSource: ScreenCaptureSource {
    private let directory: URL
    private var onNew: ((ScreenCapture) -> Void)?
    private var seen = Set<URL>()
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var isRunning: Bool { onNew != nil }

    init(directory: URL) { self.directory = directory }

    func start(onNew: @escaping (ScreenCapture) -> Void) {
        startCount += 1
        self.onNew = onNew
        seen = Set(all().map(\.url))
    }

    func stop() {
        stopCount += 1
        onNew = nil
    }

    func scan() {
        guard let onNew else { return }
        for capture in all().sorted(by: { $0.date < $1.date }) where seen.insert(capture.url).inserted { onNew(capture) }
    }

    func latest(_ count: Int) -> [ScreenCapture] {
        Array(all().sorted { $0.date > $1.date }.prefix(count))
    }

    private func all() -> [ScreenCapture] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }.map { url in
            let date = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? Date()
            return ScreenCapture(url: url, date: date)
        }
    }
}

/// Runs the watch only while the mode is on, and says when a badge is due. Mode Off starts nothing.
@MainActor
final class ScreenshotWatcher {
    private let source: ScreenCaptureSource
    private let now: () -> Date
    /// A screenshot older than this when it shows up is not new.
    static let freshSeconds: TimeInterval = 30
    private(set) var mode: ScreenshotMode = .off
    private(set) var isWatching = false
    /// Called for a new screenshot in mode "After every screenshot".
    var onBadge: ((ScreenCapture) -> Void)?

    init(source: ScreenCaptureSource, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.now = now
    }

    func apply(_ mode: ScreenshotMode) {
        self.mode = mode
        if mode.isOn, !isWatching {
            isWatching = true
            source.start { [weak self] capture in self?.captured(capture) }
        } else if !mode.isOn, isWatching {
            isWatching = false
            source.stop()
        }
    }

    func latest(_ count: Int) -> [ScreenCapture] { mode.isOn ? source.latest(count) : [] }

    private func captured(_ capture: ScreenCapture) {
        guard mode == .everyShot, now().timeIntervalSince(capture.date) <= Self.freshSeconds else { return }
        onBadge?(capture)
    }
}
