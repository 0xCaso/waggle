import Foundation
import XCTest

/// HAIL-222: the app never reads a person's project folder on its own. macOS asks "Waggle would like to
/// access files in your Desktop folder" for any such read. A session's `cwd` and `project` are plain strings
/// the shim reported over the socket. The app may show them, copy them, or hand the folder to an open panel
/// on a click. It never stats, lists, reads or runs a process on them.
final class NoProjectFolderAccessTests: XCTestCase {
    private static let sources: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Knock", isDirectory: true)

    /// Calls that touch the file system, run a process, or open a path.
    private static let accessCalls = [
        "FileManager", "contentsOfFile", "contentsOf:", "Process()", "currentDirectoryURL", "NSWorkspace",
        "fileExists", "attributesOfItem", "enumerator(", "Data(contentsOf", "String(contentsOf", "NSImage(contentsOf",
        "fileURLWithPath", "URL(filePath", "stat(", "opendir", "access(",
    ]

    /// Names that carry a session's folder.
    private static let folderNames = ["cwd", "gitRoot", "git_root"]

    private func swiftFiles() throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: Self.sources, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func testNoLineMixesASessionFolderWithAFileSystemCall() throws {
        var offenders: [String] = []
        for file in try swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                guard Self.folderNames.contains(where: { line.contains($0) }) else { continue }
                if let call = Self.accessCalls.first(where: { line.contains($0) }) {
                    offenders.append("\(file.lastPathComponent):\(index + 1) uses \(call): \(trimmed)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "The app must not touch a session's folder on its own.")
    }

    /// The one place a session folder becomes a path is the New idea model. It stores a string,
    /// and the open panel starts there only after a click.
    func testNewIdeaOnlyStoresTheFolderAsAString() throws {
        let text = try String(
            contentsOf: Self.sources.appendingPathComponent("NewIdea/NewIdeaModel.swift"),
            encoding: .utf8)
        let uses = text.components(separatedBy: "\n").filter { $0.contains("session.cwd") }
        XCTAssertEqual(uses.count, 1, "session.cwd is kept as a string folder (hover tooltip), nothing more")
        XCTAssertFalse(uses.contains { line in Self.accessCalls.contains { line.contains($0) } })
    }
}
