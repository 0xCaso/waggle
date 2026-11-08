import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Knock

// WAG-248, WAG-271, then WAG-362: the window takes no file drop, and the old entry points stay gone.

@Suite struct DocumentDropEntryTests {
    @Test func theSidebarRowAndTheDocumentSheetAreGone() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Knock")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("StartFromDocumentRow"), "\(file.lastPathComponent)")
            #expect(!text.contains("StartFromDocumentSheet"), "\(file.lastPathComponent)")
            #expect(!text.contains("StartFromDocumentModel"), "\(file.lastPathComponent)")
            #expect(!text.contains("Text(\"Start from a document\")"), "\(file.lastPathComponent)")
        }
    }

    @Test func theOldBottomPillIsGone() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Knock")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("Drop it here to start from it"), "\(file.lastPathComponent)")
            #expect(!text.contains("DocumentDropPill"), "\(file.lastPathComponent)")
        }
    }
}
