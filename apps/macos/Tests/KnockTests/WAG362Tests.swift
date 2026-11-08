import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Knock

// WAG-362: Home is three pictures (plan, prototype variants, decide) and starts nothing.

@MainActor
@Suite struct WAG362Tests {
    @Test func homeIsTheThreeStepsInOrder() {
        #expect(HomePage.blocks() == [.steps])
        #expect(HomePage.blocks(showsPluginOffer: true, showsPluginSetup: true) == [.pluginOffer, .pluginSetup, .steps])
        #expect(HomePage.Step.allCases.map(\.name) == ["Plan", "Prototype variants", "Decide"])
    }

    @Test func theCopyHasNoEmDash() {
        let copy = [HomePage.headline, HomePage.lead, HomePage.foot] + HomePage.Step.allCases.flatMap { [$0.name, $0.line] }
        for text in copy {
            #expect(!text.isEmpty)
            #expect(!text.contains("—"))
        }
    }

    @Test func theIdeaBoxAndItsEntryPointsAreGone() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Knock")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        let gone = [
            "NewIdeaRow", "NewIdeaView", "showNewIdea", "newIdeaPinned", "pendingIdeaFiles", "Text(\"New idea\")",
            "New idea with a file", "handleDocumentDrop", "DocumentDropOverlay",
        ]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in gone { #expect(!text.contains(word), "\(word) in \(file.lastPathComponent)") }
        }
        let home = try String(contentsOf: root.appendingPathComponent("Home/HomeView.swift"), encoding: .utf8)
        for control in ["Button(", "TextField(", "onTapGesture", "onDrop("] {
            #expect(!home.contains(control), "Home has \(control)")
        }
    }

    /// Evidence only: `WAG362_EVIDENCE_DIR=<dir>` writes Home at three pane widths as PNG files.
    @Test func homeRendersAtWideAndNarrowWidths() throws {
        guard let dir = ProcessInfo.processInfo.environment["WAG362_EVIDENCE_DIR"] else { return }
        for width in [1100.0, 760.0, 520.0] {
            let home = HomeStepsView()
                .frame(maxWidth: 720)
                .padding(40)
                .frame(width: width)
                .background(Color.white)
            let renderer = ImageRenderer(content: home)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("home-\(Int(width)).png"))
        }
    }
}
