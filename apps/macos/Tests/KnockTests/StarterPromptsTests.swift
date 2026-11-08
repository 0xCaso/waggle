import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Knock

struct StarterPromptsTests {
    @Test func hasThreeRolesWithTwoPromptsEach() {
        #expect(StarterRole.allCases.map(\.rawValue) == ["Research", "Product marketing", "Design"])
        for role in StarterRole.allCases { #expect(role.prompts.count == 2) }
    }

    @Test @MainActor func copyPutsTheExactPromptTextOnThePasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("knock.tests.\(UUID().uuidString)"))
        for role in StarterRole.allCases {
            for prompt in role.prompts {
                SettingsCopyButton.write(prompt.text, to: pasteboard)
                #expect(pasteboard.string(forType: .string) == prompt.text)
            }
        }
    }

    @Test func copiesNoEmDashes() {
        for role in StarterRole.allCases {
            for prompt in role.prompts { #expect(!(prompt.title + prompt.text).contains("\u{2014}")) }
        }
        #expect(!StarterPrompts.footnote.contains("\u{2014}"))
    }

    @Test func matchesTheGuideFile() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }  // repo root
        url.appendPathComponent("daemon/src/guide/starter-prompts.md")
        // The guide lands with HAIL-160; until it merges here there is nothing to compare.
        guard let guide = try? String(contentsOf: url, encoding: .utf8) else { return }
        let flat = guide.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for role in StarterRole.allCases {
            for prompt in role.prompts {
                #expect(flat.contains("**\(prompt.title).** \"\(prompt.text)\""), "\(prompt.title)")
            }
        }
    }

    @Test @MainActor func sectionRendersTwoPromptRowsAndTheFootnote() throws {
        let host = NSHostingView(rootView: StarterPromptsSection().frame(width: 640))
        let size = host.fittingSize
        // Label row + card with two wrapping rows + footnote: well over a single line high.
        #expect(size.width == 640)
        #expect(size.height > 150)
        host.frame = NSRect(origin: .zero, size: size)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
    }
}
