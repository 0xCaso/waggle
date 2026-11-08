import Testing
import Foundation
import AppKit
import SwiftUI
@testable import Knock

/// WAG-365 run 4: the layout log works in a release build behind a hidden flag, is free while off, holds no request
/// text and stops by itself. One serialized suite: `install` is process-wide.
@MainActor
@Suite(.serialized)
struct WAG365LayoutLogTests {
    private func tempFile(_ name: String = "layout.log") -> String {
        let dir = NSTemporaryDirectory() + "waggle-layoutlog-\(UUID().uuidString)"
        return dir + "/" + name
    }

    private func suite() -> UserDefaults {
        let name = "waggle-layoutlog-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func flagOffWritesNoFileAndNeverBuildsTheDetail() {
        EvidenceLayoutLog.install(nil)
        #expect(!EvidenceLayoutLog.enabled)
        var built = 0
        EvidenceLayoutLog.event("test", { built += 1; return "never" }())
        EvidenceLayoutLog.bump("test")
        #expect(built == 0, "the detail closure is never called while off")
        #expect(EvidenceLayoutLog.path == nil)

        let defaults = suite()
        #expect(EvidenceLayoutLog.Config.resolve(defaults: defaults, env: [:], underTest: false, home: "/h") == nil)
        defaults.set(true, forKey: "WaggleLayoutLog")
        #expect(EvidenceLayoutLog.Config.resolve(defaults: defaults, env: [:], underTest: false, home: "/h") == "/h/Library/Logs/Waggle/layout.log")
        #expect(EvidenceLayoutLog.Config.resolve(defaults: defaults, env: [:], underTest: true, home: "/h") == nil, "a test never writes under the home")
        #expect(EvidenceLayoutLog.Config.resolve(
            defaults: defaults, env: ["KNOCK_BUNDLE_ID": "dev.limone.knock.evidence07"], underTest: false, home: "/h") == nil)
        #expect(EvidenceLayoutLog.Config.resolve(defaults: suite(), env: ["KNOCK_EVIDENCE_LAYOUT_LOG": "/x/y.log"], underTest: true, home: "/h") == "/x/y.log")
    }

    @Test func flagOnWritesTheHeaderAndOneCountedLine() throws {
        let path = tempFile()
        let sink = EvidenceLayoutLog.Sink(path: path)
        sink.start(timer: false, scale: "2.0", scroller: "overlay")
        sink.bump("viewlayout"); sink.bump("viewlayout")
        sink.event("fits", { "w=456.5 key=title|i|||x" })
        sink.tick()
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("layout log: waggle "))
        #expect(lines[0].contains("macOS") && lines[0].contains("backing scale 2.0") && lines[0].contains("scroller overlay"))
        #expect(lines[1].hasPrefix("t=") && lines[1].contains("fits=1") && lines[1].contains("viewlayout=2"))
        #expect(lines[2] == "  fits w=456.5 key=title|i|||x")
        // A new start makes a new file.
        sink.start(timer: false, scale: "1.0", scroller: "legacy")
        #expect(try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").count == 1)
    }

    @Test func moreThanFortyDetailLinesWriteFortyAndACount() throws {
        let path = tempFile()
        let sink = EvidenceLayoutLog.Sink(path: path)
        sink.start(timer: false, scale: "2.0", scroller: "overlay")
        for n in 0..<30 { for i in 0..<5 { sink.event("n\(n)", { "i=\(i)" }) } }
        sink.tick()
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.filter { $0.hasPrefix("  n") }.count == 40)
        #expect(lines.last == "  (+80 more detail lines)")
    }

    @Test func theLogStopsAtTheSizeBound() throws {
        let path = tempFile()
        let sink = EvidenceLayoutLog.Sink(path: path, maxBytes: 700)
        sink.start(timer: false, scale: "2.0", scroller: "overlay")
        for _ in 0..<20 { sink.event("fits", { String(repeating: "w", count: 50) }); sink.tick() }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.utf8.count <= 700)
        #expect(text.hasSuffix("log stopped: size limit of 0 MB\n"))
        sink.bump("after"); sink.tick()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == text, "a stopped log writes nothing more")
    }

    @Test func theLogStopsAfterThirtyMinutes() throws {
        let path = tempFile()
        var clock = Date(timeIntervalSince1970: 1000)
        let sink = EvidenceLayoutLog.Sink(path: path, now: { clock })
        sink.start(timer: false, scale: "2.0", scroller: "overlay")
        sink.bump("a"); clock += 1799; sink.tick()
        #expect(!(try String(contentsOfFile: path, encoding: .utf8)).contains("log stopped"))
        sink.bump("a"); clock += 2; sink.tick()
        #expect(try String(contentsOfFile: path, encoding: .utf8).hasSuffix("log stopped: time limit of 30 minutes\n"))
    }

    @Test func watchCountsEachSendOfAnObjectWhileOnAndNothingWhileOff() throws {
        final class Source: ObservableObject {}
        let source = Source()
        EvidenceLayoutLog.install(nil)
        #expect(EvidenceLayoutLog.watch(source, as: "send.test") == nil, "off: no subscription at all")

        let path = tempFile()
        let sink = EvidenceLayoutLog.Sink(path: path)
        sink.start(timer: false, scale: "1.0", scroller: "legacy")
        EvidenceLayoutLog.install(sink)
        defer { EvidenceLayoutLog.install(nil) }
        let watch = EvidenceLayoutLog.watch(source, as: "send.test")
        source.objectWillChange.send(); source.objectWillChange.send(); source.objectWillChange.send()
        sink.tick()
        let lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines[1].contains("send.test=3"), "\(lines)")
        _ = watch
    }

    @Test func keysThatCouldCarryTextAreHashed() {
        #expect(EvidenceLayoutLog.safe("recommendation|one|a||title") == "recommendation|one|a||title")
        #expect(EvidenceLayoutLog.safe("recommendation|one|a||title#2") == "recommendation|one|a||title#2")
        let hashed = EvidenceLayoutLog.safe("title|Ship the secret plan now||x|")
        #expect(!hashed.contains("secret"))
        #expect(hashed.hasPrefix("title|h"))
    }

    @Test func noRequestTextReachesTheFileAfterAPageWithPillsAndItemsWasHosted() async throws {
        let path = tempFile()
        let sink = EvidenceLayoutLog.Sink(path: path)
        sink.start(timer: false, scale: "2.0", scroller: "overlay")
        EvidenceLayoutLog.install(sink)
        defer { EvidenceLayoutLog.install(nil) }

        let book = SourceBook(
            sources: [Source(id: "a", kind: "file", label: "Zebra label"), Source(id: "b", kind: "file", label: "Yak label")], citedIn: [])
        let sources = SourcesHub(book: book)
        let hub = AskCommentsHub(store: CommentsSessionStore())
        let texts = (0..<4).map { "Quokka item \($0) says the plan should land. [[s:a]] Narwhal tail [[s:b]] with a long end to wrap over many lines." }
        let content = ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    CommentableAskText(
                        text: texts[i], style: Theme.AskDoc.Typography.why13_5, color: .primary,
                        target: AskCommentTarget(.title, itemId: "Quokka secret item title \(i)"), hub: hub)
                }
            }.padding(16)
        }
        let hosting = NSHostingView(rootView: AnyView(AskCommentsHost(hub: hub) { SourcesHost(hub: sources) { content } }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 500)
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<30 { try await Task.sleep(nanoseconds: 10_000_000) }
        hosting.frame = NSRect(x: 0, y: 0, width: 470, height: 500)
        for _ in 0..<30 { try await Task.sleep(nanoseconds: 10_000_000) }
        sink.tick()

        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("fits"), "the page did reach the hooks: \(text)")
        for word in ["Quokka", "Narwhal", "Zebra", "Yak", "secret", "plan should land"] {
            #expect(!text.contains(word), "the log holds request text: \(word)")
        }
    }
}
