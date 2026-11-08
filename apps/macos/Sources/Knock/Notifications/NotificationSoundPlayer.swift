import AppKit

/// Plays a `NotificationSound` locally via `NSSound(named:)`, which resolves
/// against the app bundle's own `Library/Sounds` AND `/System/Library/Sounds`
/// (unlike `UNNotificationSound(named:)`, which only ever finds a bundled
/// `Library/Sounds` file). This lets the Sound row reuse Apple's own system
/// sounds without bundling their `.aiff` files at build time - not certain to
/// be redistributable (Contract's "Verify how" note; see the story's Choices
/// ledger). `NotificationCenterController` therefore posts every notification
/// silent (no `UNNotificationSound` set, exactly today's behaviour) and calls
/// this instead the moment it posts.
enum NotificationSoundPlayer {
    static func play(_ sound: NotificationSound) {
        guard let name = sound.systemSoundName else { return }
        NSSound(named: name)?.play()
    }
}
