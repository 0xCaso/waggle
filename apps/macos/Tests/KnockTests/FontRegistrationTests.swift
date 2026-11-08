import Foundation
import Testing
@testable import Knock

/// Guards the Amendments fix (KNOCK-08): friends without Inter/JetBrains Mono
/// installed must not silently fall back to SF. This fails if the bundled
/// fonts stop registering (moved, renamed, or dropped from Package.swift).
struct FontRegistrationTests {
    @Test func bundledSansFamilyResolvesAfterRegistration() {
        FontRegistration.registerBundledFonts()
        #expect(FontRegistration.familyResolves(Theme.FontFamily.sans))
    }

    @Test func bundledMonoFamilyResolvesAfterRegistration() {
        FontRegistration.registerBundledFonts()
        #expect(FontRegistration.familyResolves(Theme.FontFamily.mono))
    }
}

struct InterTightFontTests {
    @Test func sansIsInterTight() {
        #expect(Theme.FontFamily.sans == "Inter Tight")
    }

    @Test func interTightFilesAreBundledWithTheLicence() throws {
        let fonts = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Knock/Resources/Fonts")
        for name in ["Regular", "Medium", "SemiBold", "Bold"] {
            #expect(FileManager.default.fileExists(atPath: fonts.appendingPathComponent("InterTight/InterTight-\(name).ttf").path))
        }
        #expect(FileManager.default.fileExists(atPath: fonts.appendingPathComponent("InterTight/OFL.txt").path))
        #expect(!FileManager.default.fileExists(atPath: fonts.appendingPathComponent("Inter").path))
    }

    @Test func headingsUseMediumWithMinus3_5PercentTracking() {
        let style = Theme.Typography.panelTitle22w650
        #expect(abs((style.letterSpacing ?? 0) - (-0.035 * 22)) < 0.001)
        let wordmark = Theme.Typography.wordmark(size: 20)
        #expect(abs((wordmark.letterSpacing ?? 0) - (-0.7)) < 0.001)
    }
}
