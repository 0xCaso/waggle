import Foundation
import Testing
@testable import Knock

/// 0.1.9 crashed at launch on every Mac but the build machine: SwiftPM's
/// `Bundle.module` could not find the fonts bundle inside Knock.app and
/// called `fatalError`. The lookup must find the bundle in
/// Contents/Resources, and return nil (never crash) when it is missing.
struct FontBundleLookupTests {
    private func makeApp(withFonts: Bool) throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("FontLookup-\(UUID().uuidString)/Waggle.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist = app.appendingPathComponent("Contents/Info.plist")
        try #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.fontlookup</string></dict></plist>"#
            .write(to: plist, atomically: true, encoding: .utf8)
        if withFonts {
            let fonts = resources.appendingPathComponent("Knock_Knock.bundle/Fonts")
            try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        }
        return app
    }

    @Test func findsTheFontsBundleInContentsResources() throws {
        let app = try makeApp(withFonts: true)
        let bundle = try #require(Bundle(url: app))
        let url = try #require(FontRegistration.resourceBundleURL(mainBundle: bundle, codeBundle: bundle))
        #expect(url.path.contains("Contents/Resources/Knock_Knock.bundle"))
    }

    @Test func returnsNilInsteadOfCrashingWhenTheBundleIsMissing() throws {
        let app = try makeApp(withFonts: false)
        let bundle = try #require(Bundle(url: app))
        #expect(FontRegistration.resourceBundleURL(mainBundle: bundle, codeBundle: bundle) == nil)
    }
}
