import CoreServices
import Foundation
import os

/// WAG-277: Waggle keeps the bundle id `dev.limone.knock`, so old Knock.app copies stay registered
/// in Launch Services and Notification Center can take the old Knock icon from one of them. On the
/// first launch of each version the app registers its own bundle again, so the icon comes from this
/// bundle. It never unregisters another app and never touches a file. Tests, test copies and dev
/// builds skip it.
protocol LaunchServicesRegistering: Sendable {
    func register(bundleURL: URL) throws
}

struct LaunchServicesRegistrationError: Error { let status: OSStatus }

struct SystemLaunchServicesRegistrar: LaunchServicesRegistering {
    func register(bundleURL: URL) throws {
        let status = LSRegisterURL(bundleURL as CFURL, true)
        if status != noErr { throw LaunchServicesRegistrationError(status: status) }
    }
}

enum LaunchServicesRegistration {
    static let versionKey = "launchServicesRegisteredVersion"
    private static let logger = Logger(subsystem: "dev.limone.knock", category: "launch-services")

    static func shouldRun(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        currentVersion: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let currentVersion, !currentVersion.isEmpty else { return false }
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        if TestCopyEnvironment.isActive(environment: environment, bundleIdentifier: bundleIdentifier) { return false }
        if let id = bundleIdentifier, id.hasSuffix(".dev") { return false }
        return defaults.string(forKey: versionKey) != currentVersion
    }

    /// Registers once per version, off the main thread. Stores the version even when the call
    /// fails, so a failure is logged once and not retried on every launch.
    static func runAtLaunch(
        registrar: LaunchServicesRegistering = SystemLaunchServicesRegistrar(),
        bundleURL: URL = Bundle.main.bundleURL,
        currentVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        defaults: UserDefaults = .standard,
        queue: DispatchQueue = .global(qos: .utility),
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard shouldRun(
            environment: environment, bundleIdentifier: bundleIdentifier,
            currentVersion: currentVersion, defaults: defaults), let currentVersion
        else { completion?(); return }
        defaults.set(currentVersion, forKey: versionKey)
        queue.async {
            do {
                try registrar.register(bundleURL: bundleURL)
            } catch {
                logger.error("Launch Services register failed: \(String(describing: error), privacy: .public)")
            }
            completion?()
        }
    }
}
