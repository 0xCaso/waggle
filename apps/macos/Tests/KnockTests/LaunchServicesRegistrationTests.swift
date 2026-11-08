import XCTest
@testable import Knock

final class LaunchServicesRegistrationTests: XCTestCase {
    private final class FakeRegistrar: LaunchServicesRegistering, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var fail = false
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        func register(bundleURL: URL) throws {
            lock.lock(); _calls += 1; lock.unlock()
            if fail { throw LaunchServicesRegistrationError(status: -1) }
        }
    }

    private func defaults() -> UserDefaults {
        let name = "ls-reg-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func run(
        _ registrar: FakeRegistrar, _ d: UserDefaults, version: String = "78",
        environment: [String: String] = [:], bundleId: String? = "dev.limone.knock"
    ) {
        let done = expectation(description: "done")
        LaunchServicesRegistration.runAtLaunch(
            registrar: registrar, bundleURL: URL(fileURLWithPath: "/tmp/Fake.app"), currentVersion: version,
            environment: environment, bundleIdentifier: bundleId, defaults: d,
            completion: { done.fulfill() })
        wait(for: [done], timeout: 20)
    }

    func testRegistersOncePerVersion() {
        let r = FakeRegistrar(), d = defaults()
        run(r, d)
        run(r, d)
        XCTAssertEqual(r.calls, 1)
        run(r, d, version: "79")
        XCTAssertEqual(r.calls, 2)
        XCTAssertEqual(d.string(forKey: LaunchServicesRegistration.versionKey), "79")
    }

    func testSkipsInTestCopyAndDevBuild() {
        let r = FakeRegistrar(), d = defaults()
        run(r, d, environment: ["KNOCK_HOME": "/tmp/x"])
        run(r, d, bundleId: "dev.limone.knock.dev")
        run(r, d, bundleId: nil)
        XCTAssertEqual(r.calls, 0)
        XCTAssertNil(d.string(forKey: LaunchServicesRegistration.versionKey))
    }

    func testErrorIsIgnoredAndNotRetriedOnSameVersion() {
        let r = FakeRegistrar(), d = defaults()
        r.fail = true
        run(r, d)
        run(r, d)
        XCTAssertEqual(r.calls, 1)
    }
}
