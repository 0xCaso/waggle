import Foundation

/// The links the guided connect flow opens (HAIL-148), and the shape checks that catch a wrong
/// paste before any call. Pure: nothing here opens a URL or talks to the daemon. The app opens a
/// link only from a click, through `NSWorkspace`.
enum ConnectorLinks {
    static let botFather = URL(string: "https://t.me/BotFather")!
    static let slackApps = URL(string: "https://api.slack.com/apps")!

    /// Characters a query value may keep: the RFC 3986 unreserved set. Everything else is encoded,
    /// so a manifest with quotes, braces, `&` and `#` cannot break the URL.
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed)
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    /// `https://t.me/<bot>?start=<code>`: one tap in Telegram sends `/start <code>`. Nil when the
    /// username or the code could not be part of a link.
    static func telegramBot(username: String?, code: String?) -> URL? {
        guard let username, let code,
              matches(username, "^[A-Za-z0-9_]{3,64}$"),
              matches(code, "^[A-Za-z0-9_-]{1,64}$")
        else { return nil }
        return URL(string: "https://t.me/\(username)?start=\(code)")
    }

    /// `https://t.me/<bot>`, for when there is no code yet.
    static func telegramBotPage(username: String?) -> URL? {
        guard let username, matches(username, "^[A-Za-z0-9_]{3,64}$") else { return nil }
        return URL(string: "https://t.me/\(username)")
    }

    /// Opens Slack's "create an app" with the manifest already filled in.
    static func slackCreateApp(manifest: String) -> URL? {
        guard !manifest.isEmpty, let encoded = encode(manifest) else { return nil }
        return URL(string: "https://api.slack.com/apps?new_app=1&manifest_json=\(encoded)")
    }

    /// The app's Basic Information page, where Slack issues the app-level token. Falls back to the
    /// list of apps when the app id is not known (or not a plain id).
    static func slackAppPage(appId: String?) -> URL {
        guard let appId, matches(appId, "^[A-Z0-9]{3,32}$"),
              let url = URL(string: "https://api.slack.com/apps/\(appId)/general")
        else { return slackApps }
        return url
    }

    /// Opens the direct message with the bot in the Slack app.
    static func slackDM(teamId: String?, botUserId: String?) -> URL? {
        guard let teamId, let botUserId,
              matches(teamId, "^[A-Z0-9]{3,32}$"), matches(botUserId, "^[A-Z0-9]{3,32}$")
        else { return nil }
        return URL(string: "slack://user?team=\(teamId)&id=\(botUserId)")
    }

    /// Where a link goes, in words for the line next to its button. A manifest URL is long, so its
    /// query is left out.
    static func destination(_ url: URL) -> String {
        guard url.scheme == "https", let host = url.host else { return url.absoluteString }
        let query = url.query.flatMap { $0.contains("manifest_json") ? nil : "?\($0)" } ?? ""
        return host + url.path + query
    }
}

/// What is wrong with a pasted token, judged by its shape alone. The words match the daemon's.
enum TokenShape {
    static func isSlackApp(_ t: String) -> Bool { t.hasPrefix("xapp-") }
    static func isSlackBot(_ t: String) -> Bool { t.hasPrefix("xoxb-") }

    /// A Telegram bot token: digits, a colon, a secret.
    static func telegramProblem(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty { return nil }
        if token.range(of: "^[0-9]{3,}:[A-Za-z0-9_-]{6,}$", options: .regularExpression) != nil { return nil }
        if isSlackApp(token) || isSlackBot(token) {
            return "That is a Slack token. Telegram bot tokens look like 123456789:ABC... Copy it from BotFather."
        }
        return "That does not look like a bot token. It has digits, a colon, then letters and numbers, like 123456789:ABC... Copy it from BotFather again."
    }

    /// The problem with the app-level field alone, or nil.
    static func slackAppProblem(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || isSlackApp(t) { return nil }
        if isSlackBot(t) {
            return "That is the bot token (xoxb-). This box takes the app-level token, which starts with xapp-."
        }
        return "The app-level token starts with xapp-. Check the one you pasted."
    }

    /// The problem with the bot field alone, or nil.
    static func slackBotProblem(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || isSlackBot(t) { return nil }
        if isSlackApp(t) {
            return "That is the app-level token (xapp-). This box takes the bot token, which starts with xoxb-."
        }
        return "The bot token starts with xoxb-. Check the one you pasted."
    }

    /// True when each token sits in the other's box.
    static func slackAreSwapped(app: String, bot: String) -> Bool {
        isSlackBot(app.trimmingCharacters(in: .whitespacesAndNewlines))
            && isSlackApp(bot.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
