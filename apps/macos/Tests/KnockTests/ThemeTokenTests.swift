import AppKit
import SwiftUI
import Testing
@testable import Knock

/// The Waggle Cell W token map (HAIL-171).
struct ThemeTokenTests {
    private func hex(_ color: Color) -> UInt32 {
        let c = NSColor(color).usingColorSpace(.sRGB)!
        let r = UInt32((c.redComponent * 255).rounded())
        let g = UInt32((c.greenComponent * 255).rounded())
        let b = UInt32((c.blueComponent * 255).rounded())
        return r << 16 | g << 8 | b
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
}
