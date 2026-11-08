import Foundation

/// The Sound row's picker options (Contract: "None, and 5 short macOS
/// sounds"). Raw values are the exact `/System/Library/Sounds` file stems,
/// so they double as the name `NSSound(named:)` resolves.
enum NotificationSound: String, CaseIterable, Identifiable, Hashable, Sendable {
    case none
    case tink = "Tink"
    case glass = "Glass"
    case pop = "Pop"
    case ping = "Ping"
    case purr = "Purr"

    var id: String { rawValue }

    var displayName: String {
        self == .none ? "None" : rawValue
    }

    /// `nil` for `.none` - both "nothing to preview" and "nothing to play
    /// locally when a notification posts".
    var systemSoundName: String? {
        self == .none ? nil : rawValue
    }
}
