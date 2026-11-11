import AppKit
import SwiftUI
import Testing
@testable import Knock

/// The foundation of matching the request page to the mockups (decision 2026-11-10, STYLE-AUDIT.md):
/// the new colour tokens, the exact Inter Tight face per weight, and the CSS line height helper.
struct RequestPageStyleFoundationTests {
    private func hex(_ color: Color, dark: Bool = false) -> UInt32 {
        var value: UInt32 = 0
        // A token has a light and a dark value: read it under the look the test names, not the Mac's look.
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = NSColor(color).usingColorSpace(.sRGB)!
            let r = UInt32((c.redComponent * 255).rounded())
            let g = UInt32((c.greenComponent * 255).rounded())
            let b = UInt32((c.blueComponent * 255).rounded())
            value = r << 16 | g << 8 | b
        }
        return value
    }

    @Test func mockupColourTokens() {
        #expect(hex(Theme.Colors.needFill) == 0xFBF3D9)
        #expect(hex(Theme.Colors.needDivider) == 0xEFE2B8)
        #expect(hex(Theme.Colors.link) == 0x2F5BD8)
        #expect(hex(Theme.Colors.pickedFill) == 0xFFFDF5)
        #expect(hex(Theme.Colors.latestFill) == 0xF4F6FD)
        // Reused as they are: the mockup hex already matches.
        #expect(hex(Theme.AskDoc.Colors.quiet) == 0x8A8A8A)
        #expect(hex(Theme.AskDoc.Colors.pro) == 0x0E7A43)
        #expect(hex(Theme.AskDoc.Colors.watch) == 0xC2410C)
    }

    @Test func eachWeightPicksItsOwnInterTightFace() {
        #expect(PromptBarLogic.sansFaceName(for: .regular) == "InterTight-Regular")
        #expect(PromptBarLogic.sansFaceName(for: .light) == "InterTight-Regular")
        #expect(PromptBarLogic.sansFaceName(for: .medium) == "InterTight-Medium")
        #expect(PromptBarLogic.sansFaceName(for: .semibold) == "InterTight-SemiBold")
        #expect(PromptBarLogic.sansFaceName(for: .bold) == "InterTight-Bold")
        #expect(PromptBarLogic.sansFaceName(for: .heavy) == "InterTight-Bold")
    }

    @Test func sansFontDrawsTheBundledFaceForEachWeight() {
        FontRegistration.registerBundledFonts()
        guard FontRegistration.didRegisterBundledFonts else { return }
        #expect(PromptBarLogic.sansFont(size: 13).fontName == "InterTight-Regular")
        #expect(PromptBarLogic.sansFont(size: 13, weight: .medium).fontName == "InterTight-Medium")
        #expect(PromptBarLogic.sansFont(size: 13, weight: .semibold).fontName == "InterTight-SemiBold")
        #expect(PromptBarLogic.sansFont(size: 13, weight: .bold).fontName == "InterTight-Bold")
    }

    @Test func cssLineSpacingGivesTheCSSLineBox() {
        // 13 px / 1.5 → a 19.5 pt line box; Inter Tight draws 1.21 × 13 = 15.73 by itself.
        #expect(abs(Theme.Typography.cssLineSpacing(size: 13, lineHeight: 1.5) - 13 * 0.29) < 0.0001)
        #expect(abs(Theme.Typography.cssLineSpacing(size: 12, lineHeight: 1.45) - 12 * 0.24) < 0.0001)
        #expect(abs(Theme.Typography.cssLineSpacing(size: 10, lineHeight: 1.5, mono: true) - 10 * 0.18) < 0.0001)
        // `/1` and anything under the natural line height draw at the natural height.
        #expect(Theme.Typography.cssLineSpacing(size: 10.5, lineHeight: 1) == 0)
        #expect(Theme.Typography.cssLineSpacing(size: 11.5, lineHeight: 1.25, mono: true) == 0)
    }
}
