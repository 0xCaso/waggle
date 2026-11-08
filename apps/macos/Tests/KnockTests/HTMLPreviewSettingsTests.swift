import Testing
import Foundation
@testable import Knock

/// The `HTML preview` toggle's off-by-default-when-isolation-fails rule
/// (KNOCK-17). Each case uses a temp `KNOCK_HOME` so the marker file is written
/// there, never to the operator's real data root.
struct HTMLPreviewSettingsTests {
    private func withTempHome(_ body: ([String: String]) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("knock-html-preview-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(["KNOCK_HOME": dir.path])
    }

    @Test func enabledWhenIsolationPassedAndNotDisabled() throws {
        try withTempHome { env in
            #expect(HTMLPreviewSettings.isEnabled(isolationPassed: true, environment: env))
        }
    }

    @Test func disabledWhenTheMarkerIsSet() throws {
        try withTempHome { env in
            HTMLPreviewSettings.setDisabled(true, environment: env)
            #expect(!HTMLPreviewSettings.isEnabled(isolationPassed: true, environment: env))
        }
    }

    @Test func disabledWhenIsolationFailed() throws {
        try withTempHome { env in
            HTMLPreviewSettings.setDisabled(false, environment: env)
            #expect(!HTMLPreviewSettings.isEnabled(isolationPassed: false, environment: env))
        }
    }

    @Test func setDisabledRoundTrips() throws {
        try withTempHome { env in
            HTMLPreviewSettings.setDisabled(true, environment: env)
            #expect(HTMLPreviewSettings.isDisabled(environment: env))
            HTMLPreviewSettings.setDisabled(false, environment: env)
            #expect(!HTMLPreviewSettings.isDisabled(environment: env))
        }
    }
}
