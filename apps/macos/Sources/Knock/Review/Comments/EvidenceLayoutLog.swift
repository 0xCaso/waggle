import AppKit
import Combine
import Foundation

/// WAG-365: a counter for the layout of the request page, to find a layout cycle on a real Mac.
///
/// It is off. A person turns it on with `defaults write dev.limone.knock WaggleLayoutLog -bool YES` (or the launch
/// argument `-WaggleLayoutLog YES`), then quits and opens Waggle. The flag is read one time, the first time a hook
/// runs. An evidence build turns it on with `KNOCK_EVIDENCE_LAYOUT_LOG=<file>` instead.
///
/// Off costs one read of a stored `Bool` per hook: `detail` is an autoclosure, so no string is built, and no file,
/// queue or timer exists. On, a timer on the log's own queue writes one line a second, so the file still grows while
/// the main thread spins. A line holds the count of each name since the last line; the lines under it hold the first
/// details (a moved value with its old and new number, a measured width).
///
/// Private by design: a detail holds only counts, widths, heights, origins, rects and item keys (see `safe`). Never
/// request text, titles, option labels, source labels, paths or session names.
enum EvidenceLayoutLog {
    static let flagKey = "WaggleLayoutLog"
    static let envPath = "KNOCK_EVIDENCE_LAYOUT_LOG"

    /// The log of this process, or nil when it is off. Set once, on first use.
    nonisolated(unsafe) private static var shared: Sink? = {
        guard let path = Config.resolve() else { return nil }
        let sink = Sink(path: path)
        sink.start()
        return sink
    }()
    nonisolated(unsafe) private static var isOn: Bool = shared != nil

    /// For a test: puts a log in place of the launch choice. `nil` puts it off again.
    static func install(_ sink: Sink?) {
        shared = sink
        isOn = sink != nil
    }

    static var enabled: Bool { isOn }
    static var path: String? { shared?.path }

    /// Counts one call of `name`.
    @inline(__always)
    static func bump(_ name: String) {
        guard isOn else { return }
        shared?.bump(name)
    }

    /// Counts `name` and keeps `detail` for the next line.
    @inline(__always)
    static func event(_ name: String, _ detail: @autoclosure () -> String) {
        guard isOn else { return }
        shared?.event(name, detail)
    }

    /// WAG-375: counts each send of `object` under `name`, so a burst names the object that keeps the page drawing.
    /// Nil while the log is off. The caller keeps the result for as long as it wants the count.
    static func watch<O: ObservableObject>(_ object: O, as name: String) -> AnyCancellable?
    where O.ObjectWillChangePublisher == ObservableObjectPublisher {
        guard isOn else { return nil }
        return object.objectWillChange.sink { _ in bump(name) }
    }

    /// An item key (`recommendation|one|a||title`, a pill key adds `#0`) that cannot carry request text: a part of
    /// 16 letters, digits or `_.:-` stays; any other part becomes `h` and 6 hex digits of its hash.
    static func safe(_ key: String) -> String {
        key.split(separator: "|", omittingEmptySubsequences: false).map { part -> String in
            let pieces = part.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let head = pieces[0]
            let tail = pieces.count > 1 ? pieces[1] : ""
            let headOK = head.utf8.count <= 16 && head.utf8.allSatisfy { Self.plain($0) }
            let tailOK = tail.utf8.count <= 3 && tail.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
            if headOK && tailOK { return String(part) }
            var hash: UInt32 = 2166136261
            for byte in part.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
            return "h" + String(format: "%06x", hash & 0xFFFFFF)
        }.joined(separator: "|")
    }

    private static func plain(_ b: UInt8) -> Bool {
        (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b == 46 || b == 58 || b == 45
    }

    /// Where the log goes, or nil when it is off.
    enum Config {
        static func resolve(
            defaults: UserDefaults = .standard, env: [String: String] = ProcessInfo.processInfo.environment,
            underTest: Bool = Config.runsUnderTest, home: String = NSHomeDirectory()
        ) -> String? {
            if let file = env[EvidenceLayoutLog.envPath], !file.isEmpty { return file }
            guard defaults.bool(forKey: EvidenceLayoutLog.flagKey) else { return nil }
            // A test or an evidence process never writes under the real home.
            if underTest || env["KNOCK_BUNDLE_ID"]?.hasPrefix("dev.limone.knock.evidence") == true { return nil }
            return home + "/Library/Logs/Waggle/layout.log"
        }

        static var runsUnderTest: Bool {
            let args = ProcessInfo.processInfo.arguments.first ?? ""
            return NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                || args.contains("xctest") || args.contains("swiftpm-testing-helper")
        }
    }

    /// The writer. `EvidenceLayoutLog` holds one when the log is on; a test makes its own.
    final class Sink: @unchecked Sendable {
        static let maxDetailsPerLine = 40
        static let maxDetailsPerName = 4
        /// Room kept for the last line.
        private static let reserve = 200

        let path: String
        private let maxBytes: Int
        private let maxSeconds: TimeInterval
        private let now: () -> Date
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var perName: [String: Int] = [:]
        private var events: [String] = []
        private var extra = 0
        private var written = 0
        private var stopped = false
        private var timer: DispatchSourceTimer?
        private var began: Date

        init(path: String, maxBytes: Int = 20_000_000, maxSeconds: TimeInterval = 1800, now: @escaping () -> Date = Date.init) {
            self.path = path
            self.maxBytes = maxBytes
            self.maxSeconds = maxSeconds
            self.now = now
            self.began = now()
        }

        /// Creates the folder, starts a new file with the header line, and starts the timer (`timer: false` in a test).
        func start(timer startsTimer: Bool = true, scale: String? = nil, scroller: String? = nil) {
            try? FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: nil)
            began = now()
            let info = Bundle.main.infoDictionary
            let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
            let build = (info?["CFBundleVersion"] as? String) ?? "?"
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            let scale = scale ?? Self.windowScale()
            let scroller = scroller ?? Self.scrollerStyle()
            append("layout log: waggle \(version) build \(build), macOS \(os), backing scale \(scale), scroller \(scroller)\n")
            guard startsTimer else { return }
            let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "waggle.layoutlog"))
            source.schedule(deadline: .now() + 1, repeating: 1)
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }

        func bump(_ name: String) {
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return }
            counts[name, default: 0] += 1
        }

        func event(_ name: String, _ detail: () -> String) {
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return }
            counts[name, default: 0] += 1
            let seen = perName[name, default: 0]
            guard seen < Self.maxDetailsPerName else { return }
            perName[name] = seen + 1
            if events.count < Self.maxDetailsPerLine { events.append("\(name) \(detail())") } else { extra += 1 }
        }

        /// Writes the line of the last second. The timer calls it; a test calls it by hand.
        func tick() {
            lock.lock()
            if stopped { lock.unlock(); return }
            let snapshot = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            let moved = events
            let more = extra
            counts = [:]; perName = [:]; events = []; extra = 0
            let elapsed = now().timeIntervalSince(began)
            lock.unlock()

            var text = "t=\(String(format: "%.0f", elapsed))s \(snapshot.isEmpty ? "(none)" : snapshot)\n"
            for line in moved { text += "  \(line)\n" }
            if more > 0 { text += "  (+\(more) more detail lines)\n" }

            let overTime = elapsed >= maxSeconds
            let overSize = written + text.utf8.count + Self.reserve > maxBytes
            if !overTime && !overSize { append(text); return }
            lock.lock(); stopped = true; lock.unlock()
            timer?.cancel(); timer = nil
            if !overSize { append(text) }
            append("log stopped: \(overSize ? "size limit of \(maxBytes / 1_000_000) MB" : "time limit of \(Int(maxSeconds / 60)) minutes")\n")
        }

        private func append(_ text: String) {
            guard let data = text.data(using: .utf8), let handle = FileHandle(forWritingAtPath: path) else { return }
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            written += data.count
        }

        private static func windowScale() -> String {
            guard Thread.isMainThread else { return "unknown" }
            return MainActor.assumeIsolated {
                let window = NSApp?.mainWindow ?? NSApp?.windows.first(where: \.isVisible)
                guard let window else { return "unknown" }
                return String(format: "%.1f", window.backingScaleFactor)
            }
        }

        private static func scrollerStyle() -> String {
            guard Thread.isMainThread else { return "unknown" }
            return MainActor.assumeIsolated { NSScroller.preferredScrollerStyle == .overlay ? "overlay" : "legacy" }
        }
    }
}
