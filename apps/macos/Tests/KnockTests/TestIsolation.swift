import Foundation

/// WAG-358: an environment whose `KNOCK_HOME` is a fresh temp folder, so an `AppModel` built in a test
/// saves pending replies and writes `queue.log` there, never under the real Application Support or Logs.
/// A `KNOCK_HOME` in `extra` wins.
func isolatedKnockEnvironment(_ extra: [String: String] = [:]) -> [String: String] {
    var environment = extra
    if environment["KNOCK_HOME"] == nil {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("knock_test_home_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        environment["KNOCK_HOME"] = dir.path
    }
    return environment
}
