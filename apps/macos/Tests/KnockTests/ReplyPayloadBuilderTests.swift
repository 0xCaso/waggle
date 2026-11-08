import Testing
import AppKit
@testable import Knock

/// The wire payload `reply.submit` sends (docs/protocol-mvp.md "Socket
/// RPC"): only captures with at least one comment go out, each with a valid
/// raw and annotated JPEG capped for the wire, and comments come back ordered.
@MainActor
struct ReplyPayloadBuilderTests {
    /// A raw `CGContext` bitmap, not `NSImage.lockFocus()` - unreliable
    /// without a window server connection (see `AnnotatedCaptureRenderer`'s
    /// own note).
    private static func image(width: Int = 20, height: Int = 20) -> NSImage {
        let size = NSSize(width: width, height: height)
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        return NSImage(cgImage: context.makeImage()!, size: size)
    }

    @Test func onlyCapturesWithAtLeastOneCommentAreIncluded() {
        var model = CommentsModel()
        let commented = model.addCapture(revision: 2)
        let uncommented = model.addCapture(revision: 2)
        model.addComment(captureId: commented.id, rect: Rect(x: 0.1, y: 0.1, w: 0.2, h: 0.1), text: "note")
        _ = uncommented

        let images = [commented.id: Self.image(), uncommented.id: Self.image()]
        let (comments, captures) = ReplyPayloadBuilder.build(model: model, imagesByCaptureId: images)

        #expect(captures.map(\.id) == [commented.id])
        #expect(comments.count == 1)
    }

    @Test func commentRectsGoOutInsideZeroToOne() {
        var model = CommentsModel()
        let capture = model.addCapture(revision: 1)
        model.addComment(captureId: capture.id, rect: Rect(x: 0.0055, y: 0, w: 0.389, h: 1.0000000000000002), text: "edge")
        model.addComment(captureId: capture.id, rect: Rect(x: 0.9, y: -0.0000001, w: 0.3, h: 0.2), text: "right edge")

        let (comments, _) = ReplyPayloadBuilder.build(model: model, imagesByCaptureId: [capture.id: Self.image()])

        #expect(comments[0].rect.h == 1)
        #expect(comments[1].rect.y == 0)
        #expect(comments[1].rect.x + comments[1].rect.w <= 1)
    }

    @Test func capturesCarryValidRawAndAnnotatedJpegData() {
        var model = CommentsModel()
        let capture = model.addCapture(revision: 3)
        model.addComment(captureId: capture.id, rect: Rect(x: 0, y: 0, w: 0.2, h: 0.2), text: "note")

        let (_, captures) = ReplyPayloadBuilder.build(model: model, imagesByCaptureId: [capture.id: Self.image()])

        guard let sent = captures.first else {
            Issue.record("expected one capture")
            return
        }
        #expect(sent.revision == 3)
        let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]
        for base64 in [sent.pngBase64, sent.annotatedPngBase64] {
            let data = Data(base64Encoded: base64)
            #expect(data != nil)
            #expect(Array(data?.prefix(3) ?? Data()) == jpegSignature, "should decode back to a real JPEG")
            #expect(data.flatMap(NSImage.init(data:)) != nil)
        }
    }

    /// Operator, 4 Oct: four Retina captures as raw + annotated PNG made a
    /// 17.8 MB reply that timed out. The wire copy keeps the aspect ratio
    /// with the long edge capped at 2048 px.
    @Test func largeCapturesAreScaledDownForTheWire() throws {
        var model = CommentsModel()
        let capture = model.addCapture(revision: 1)
        model.addComment(captureId: capture.id, rect: Rect(x: 0.1, y: 0.1, w: 0.5, h: 0.5), text: "note")

        let (_, captures) = ReplyPayloadBuilder.build(
            model: model, imagesByCaptureId: [capture.id: Self.image(width: 4096, height: 2304)])

        let sent = try #require(captures.first)
        for base64 in [sent.pngBase64, sent.annotatedPngBase64] {
            let data = try #require(Data(base64Encoded: base64))
            let rep = try #require(NSBitmapImageRep(data: data))
            #expect(rep.pixelsWide == 2048)
            #expect(rep.pixelsHigh == 1152)
        }
    }

    @Test func commentsAreOrderedByCaptureThenByNumber() {
        var model = CommentsModel()
        let first = model.addCapture(revision: 1)
        let second = model.addCapture(revision: 2)
        // Add out of the eventual expected order to prove sorting happens.
        model.addComment(captureId: second.id, rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1), text: "on second")
        model.addComment(captureId: first.id, rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1), text: "first note on first")
        model.addComment(captureId: first.id, rect: Rect(x: 0.5, y: 0.5, w: 0.1, h: 0.1), text: "second note on first")

        let images = [first.id: Self.image(), second.id: Self.image()]
        let (comments, _) = ReplyPayloadBuilder.build(model: model, imagesByCaptureId: images)

        #expect(comments.map(\.text) == ["first note on first", "second note on first", "on second"])
    }

    // HAIL-40: a screenshots case's `note` rides the screen label the
    // caller supplies - "Screen N · caption" with one, "Screen N" without.
    @Test func screenLabelBecomesTheCaptureNoteWithACaption() {
        var model = CommentsModel()
        let capture = model.addCapture(revision: 1)
        model.addComment(captureId: capture.id, rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1), text: "note")

        let (_, captures) = ReplyPayloadBuilder.build(
            model: model, imagesByCaptureId: [capture.id: Self.image()],
            screenLabel: { _ in "Screen 2 · Verify email" }
        )

        #expect(captures.first?.note == "Screen 2 · Verify email")
    }

    @Test func screenLabelBecomesTheCaptureNoteWithoutACaption() {
        var model = CommentsModel()
        let capture = model.addCapture(revision: 1)
        model.addComment(captureId: capture.id, rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1), text: "note")

        let (_, captures) = ReplyPayloadBuilder.build(
            model: model, imagesByCaptureId: [capture.id: Self.image()],
            screenLabel: { _ in "Screen 2" }
        )

        #expect(captures.first?.note == "Screen 2")
    }

    @Test func noteStaysNilWithoutAScreenLabel() {
        var model = CommentsModel()
        let capture = model.addCapture(revision: 1)
        model.addComment(captureId: capture.id, rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1), text: "note")

        let (_, captures) = ReplyPayloadBuilder.build(model: model, imagesByCaptureId: [capture.id: Self.image()])

        #expect(captures.first?.note == nil, "the pre-HAIL-40 default: no screenLabel closure means no note")
    }

    @Test func aCaptureMissingItsImageIsSkippedRatherThanCrashing() {
        var model = CommentsModel()
        let capture = model.addCapture(revision: 1)
        model.addComment(captureId: capture.id, rect: Rect(x: 0, y: 0, w: 0.1, h: 0.1), text: "note")

        let (comments, captures) = ReplyPayloadBuilder.build(model: model, imagesByCaptureId: [:])

        #expect(captures.isEmpty)
        #expect(comments.count == 1, "the comment itself is still sent even if its capture image never loaded")
    }
}
