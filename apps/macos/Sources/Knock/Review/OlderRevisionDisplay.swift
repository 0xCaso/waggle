import AppKit
import Foundation
import WebKit

/// One capture from an earlier, no-longer-latest revision, read-only
/// (docs/stories/KNOCK-14.md AC: "with its captures and pins"). `image` is
/// decoded from the capture's annotated image (`capture.image`, PERF-2: `cases.get` carries
/// no image data, so it is `nil` until `OlderRevisionDisplay.loadImages` fills it) - the daemon already
/// has the numbered pins baked into those bytes at `reply.submit` time
/// (`ReplyPayloadBuilder`/`AnnotatedCaptureRenderer`), so this needs no pin
/// overlay of its own the way the live Comment-mode stage does.
struct OlderRevisionCapture: Identifiable {
    let id: String
    var image: NSImage?
    let comments: [Comment]
}

/// What an older revision's artifact reads from disk, decided from its
/// `artifact.path` result alone (HAIL-142). Pure, so it is testable without a
/// file system or a web view.
enum OlderRevisionPlan: Equatable {
    case markdown(path: String)
    case images(paths: [String])
    case bundle(entry: String, root: String)
    case diagram(path: String)
    case bundleImage(path: String)
    case unavailable

    /// `htmlEnabled` is `HTMLPreviewSettings.isEnabled(isolationPassed:)`. A bundle with HTML
    /// preview off falls back to its image preview, else to a plain notice.
    static func plan(for result: ArtifactPathResult, htmlEnabled: Bool) -> OlderRevisionPlan {
        switch result.kind {
        case .markdown:
            return .markdown(path: result.root)
        case .screenshot:
            return .images(paths: [result.root])
        case .screenshots:
            let paths = (result.items ?? []).map(\.path)
            return paths.isEmpty ? .unavailable : .images(paths: paths)
        case .htmlBundle:
            if htmlEnabled { return .bundle(entry: result.entry, root: result.root) }
            if let preview = result.preview, preview.kind == .image { return .bundleImage(path: preview.path) }
            return .unavailable
        case .diagram:
            return .diagram(path: result.root)
        }
    }
}

/// What the read-only stage draws under an older revision's header.
enum OlderRevisionContent {
    case loading
    case markdown(String)
    case images([NSImage])
    /// A bundle or a diagram, in the isolated web view: no capture controller, no zoom, no comment layer.
    case web(entryURL: URL, directoryURL: URL, configuration: WKWebViewConfiguration)
    case unavailable
}

/// One earlier revision's captures, shown read-only in the artifact viewer
/// when the friend follows the "`<k> comments on v<n-1>` · view v<n-1>" link
/// (docs/design/mvp-values.md §M9 `E0OSB`). Never a side-by-side compare with
/// the latest revision (Non-goal) - this replaces the live stage entirely
/// while shown.
struct OlderRevisionDisplay {
    let revision: Int
    var captures: [OlderRevisionCapture]
    /// The revision's own artifact (HAIL-142), loaded from `artifact.path`
    /// after the display opens. Starts as `.loading`, never blank.
    var content: OlderRevisionContent = .loading

    /// Builds the read-only display for `revision` from a case's full
    /// detail: every capture staged against that revision, across every
    /// reply (docs/protocol-mvp.md `CaseDetail`: captures live on `Reply`,
    /// not on the case directly), each with its own saved comments/pins -
    /// never a capture's comments from a different revision (AC7: "Keep
    /// prior comments attached to their original revision, not moved").
    static func build(revision: Int, from detail: CaseDetail) -> OlderRevisionDisplay {
        let captures = detail.replies
            .flatMap(\.captures)
            .filter { $0.revision == revision }
            .map { capture -> OlderRevisionCapture in
                // An old daemon still sends the images inline; use them when present.
                let inline = Data(base64Encoded: capture.annotatedPngBase64).flatMap { $0.isEmpty ? nil : $0 }
                    ?? Data(base64Encoded: capture.pngBase64).flatMap { $0.isEmpty ? nil : $0 }
                let image = inline.flatMap { NSImage(data: $0) }
                let comments = detail.comments
                    .filter { $0.captureId == capture.id }
                    .sorted { $0.n < $1.n }
                return OlderRevisionCapture(id: capture.id, image: image, comments: comments)
            }
        return OlderRevisionDisplay(revision: revision, captures: captures)
    }

    /// Fetches the image of every capture still without one (PERF-2), annotated first,
    /// the raw one when the annotated copy is missing. `client` caches per capture id.
    static func loadedImages(for captures: [OlderRevisionCapture], with client: KnockClient) async -> [String: NSImage] {
        var images: [String: NSImage] = [:]
        for capture in captures where capture.image == nil {
            var data = await client.captureImageData(captureId: capture.id, which: .annotated)
            if data == nil { data = await client.captureImageData(captureId: capture.id, which: .raw) }
            if let data, let image = NSImage(data: data) { images[capture.id] = image }
        }
        return images
    }
}
