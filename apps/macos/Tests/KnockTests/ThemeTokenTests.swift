import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Knock

/// The Waggle Cell W token map (HAIL-171).
struct ThemeTokenTests {
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

    @Test func neutralsAndInk() {
        #expect(hex(Theme.Colors.ink) == 0x16181A)
        #expect(hex(Theme.Colors.ink2) == 0x4A4C50)
        #expect(hex(Theme.Colors.ink3) == 0x6B6B6B)
        #expect(hex(Theme.Colors.side) == 0xF3F3F3)
        #expect(hex(Theme.Colors.list) == 0xFAFAFA)
        #expect(hex(Theme.Colors.line) == 0xE6E6E6)
        #expect(hex(Theme.Colors.line2) == 0xD9D9D9)
    }

    @Test func statusColours() {
        #expect(hex(Theme.Colors.accent) == 0xE0352B)
        #expect(hex(Theme.Colors.ok) == 0x18A058)
        #expect(hex(Theme.Colors.okSoft) == 0xE3F5EA)
        #expect(hex(Theme.Colors.ds) == 0x2B59F0)
        #expect(hex(Theme.Colors.dsUpdateFill) == 0xF2F5FE)
        #expect(hex(Theme.Colors.dsUpdateStroke) == 0xDCE4FD)
    }

    @Test func honey() {
        #expect(hex(Theme.Colors.honey300) == 0xF9C846)
        #expect(hex(Theme.Colors.honey500) == 0xF2B01E)
        #expect(hex(Theme.Colors.honey600) == 0xE89A0C)
        #expect(hex(Theme.Colors.honeySoft) == 0xFDF4DA)
        #expect(hex(Theme.Colors.recommendedTagText) == 0xC98A00)
    }

    /// Dark Mode (decision 2026-11-11): the approved dark palette.
    @Test func theDarkLook() {
        #expect(hex(Theme.Colors.win, dark: true) == 0x1C1E21)
        #expect(hex(Theme.Colors.list, dark: true) == 0x18191C)
        #expect(hex(Theme.Colors.side, dark: true) == 0x141517)
        #expect(hex(Theme.Colors.ink, dark: true) == 0xF1F1EF)
        #expect(hex(Theme.Colors.ink2, dark: true) == 0xC5C7CB)
        #expect(hex(Theme.Colors.ink3, dark: true) == 0x9C9EA3)
        #expect(hex(Theme.Colors.onFill, dark: true) == 0x16181A)
        #expect(hex(Theme.Colors.ok, dark: true) == 0x4CC38A)
        #expect(hex(Theme.Colors.ds, dark: true) == 0x8DA6FF)
        #expect(hex(Theme.Colors.accentText, dark: true) == 0xFF8A80)
        // Honey and red fills, and the text on red, are the same in both looks.
        #expect(hex(Theme.Colors.accent, dark: true) == 0xE0352B)
        #expect(hex(Theme.Colors.honey500, dark: true) == 0xF2B01E)
        #expect(hex(Theme.Colors.onAccent, dark: true) == 0xFFFFFF)
    }

    /// WCAG relative luminance of a 0xRRGGBB value.
    private func luminance(_ value: UInt32) -> Double {
        func channel(_ byte: UInt32) -> Double {
            let c = Double(byte) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(value >> 16 & 0xFF) + 0.7152 * channel(value >> 8 & 0xFF) + 0.0722 * channel(value & 0xFF)
    }

    private func contrast(_ text: Color, on fill: Color, dark: Bool) -> Double {
        let a = luminance(hex(text, dark: dark)), b = luminance(hex(fill, dark: dark))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Dark Mode record, Constraints: text in the dark look is at least 4.5 to 1 on each surface.
    @Test func darkTextContrastIsAtLeastFourPointFive() {
        let text = [
            Theme.Colors.ink, Theme.Colors.ink2, Theme.Colors.ink3, Theme.Colors.ok, Theme.Colors.ds,
            Theme.Colors.accentText,
        ]
        for surface in [Theme.Colors.win, Theme.Colors.list, Theme.Colors.side] {
            for colour in text { #expect(contrast(colour, on: surface, dark: true) >= 4.5) }
        }
        // The primary button and the canvas tool switch: dark text on the light ink fill.
        #expect(contrast(Theme.Colors.onFill, on: Theme.Colors.ink, dark: true) >= 4.5)
        // White on red is the same in both looks.
        #expect(contrast(Theme.Colors.onAccent, on: Theme.Colors.accent, dark: true) >= 4.0)
    }
}
