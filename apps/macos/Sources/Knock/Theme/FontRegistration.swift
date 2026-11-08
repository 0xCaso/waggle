import AppKit
import CoreText

/// Registers the bundled Inter and JetBrains Mono TTFs (Resources/Fonts/,
/// OFL-licensed) so `Theme`'s `Font.custom` calls resolve to the real
/// families on a Mac that never installed them, instead of SwiftUI silently
/// falling back to SF (Amendments, KNOCK-08).
final class FontBundleToken {}

enum FontRegistration {
    /// Idempotent: registering an already-registered font URL is a silent
    /// no-op, so calling this more than once (e.g. in tests and at launch)
    /// is safe.
    /// True once `registerBundledFonts()` found the bundled fonts and
    /// registered them in this process. AppKit code that needs an `NSFont` by
    /// name checks this first: asking for an unregistered family makes CoreText
    /// call the font daemon, which can block for good (it does in the test host).
    nonisolated(unsafe) private(set) static var didRegisterBundledFonts = false

    static func registerBundledFonts() {
        guard let resourceURL = resourceBundleURL() else { return }
        didRegisterBundledFonts = true
        let enumerator = FileManager.default.enumerator(at: resourceURL, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "ttf" else { continue }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
    }

    /// Where the fonts' resource bundle is, without touching `Bundle.module`:
    /// SwiftPM's generated accessor calls `fatalError` when the bundle is
    /// missing, and in a shipped app it only ever found the bundle through
    /// the build machine's absolute `.build` path (0.1.9 crashed at launch on
    /// every other Mac). Order: the app's Contents/Resources (bundle-app.sh
    /// copies it there), then next to the executable (`swift run`), then next to the code's own bundle (tests).
    /// Nil means no bundled fonts: the app uses system fonts, never crashes.
    static func resourceBundleURL(
        mainBundle: Bundle = .main,
        codeBundle: Bundle = Bundle(for: FontBundleToken.self),
        fileManager: FileManager = .default
    ) -> URL? {
        let name = "Knock_Knock.bundle"
        let candidates = [
            mainBundle.resourceURL?.appendingPathComponent(name),
            mainBundle.bundleURL.appendingPathComponent(name),
            mainBundle.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
            // Tests: this code lives in KnockPackageTests.xctest, a sibling of the bundle.
            codeBundle.bundleURL.deletingLastPathComponent().appendingPathComponent(name),
        ].compactMap { $0 }
        for bundleURL in candidates where fileManager.fileExists(atPath: bundleURL.path) {
            return Bundle(url: bundleURL)?.resourceURL ?? bundleURL
        }
        return nil
    }

    /// True when `family` resolves to itself through the same lookup
    /// SwiftUI's `Font.custom(_:size:)` performs (CoreType's name-based
    /// lookup, which falls back to a substitute family on no match). A
    /// mismatch means the family fell back silently instead of failing
    /// loudly, which is exactly what broke before the fonts were bundled.
    static func familyResolves(_ family: String) -> Bool {
        let font = CTFontCreateWithName(family as CFString, 13, nil)
        return (CTFontCopyFamilyName(font) as String) == family
    }
}
