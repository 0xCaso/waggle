import AppKit
import Combine
import KnockMark

/// The menu bar item showing the Needs you count (contract: "A menu bar
/// item shows the Needs you count; clicking it opens the main window. No
/// popover."; docs/design/mvp-values.md §M2 `HS75s` → `xHJOz` "Knock status
/// item"). KNOCK-21 adds a menu with "Open Knock" and "Check for Updates…", so
/// the single-click now opens that menu instead of the window directly.
///
/// The mock draws that status item as app chrome (a tinted background pill,
/// the brand orange on the count). This uses a plain template icon (the
/// `KnockMark` glyph, Pen `zO4B3`) and the system's own status-bar text
/// colour instead: like the M3/M11 traffic lights (Theme.swift,
/// `Colors.trafficLight*`), a real menu bar item is system chrome the app
/// does not repaint, not a surface to redraw pixel for pixel (see the
/// story's Choices ledger).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private var observeTask: Task<Void, Never>?
    private var reachTask: Task<Void, Never>?
    private let preferences: AskPreferencesModel
    private let reachControl = NSSegmentedControl()
    private var count = 0
    private var level: AskReach
    private let screenshots: ScreenshotController?
    private var screenshotItem: NSMenuItem?
    private var snipItem: NSMenuItem?

    init(model: AppModel, screenshots: ScreenshotController? = nil) {
        self.screenshots = screenshots
        preferences = model.askPreferences
        level = model.askPreferences.reach
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            let image = KnockMark.menuBarTemplateImage()
            image.accessibilityDescription = "Waggle: needs you"
            button.image = image
            button.imagePosition = .imageLeading
        }
        // The menu adds "Check for Updates…" (KNOCK-21) beside the open action.
        let menu = NSMenu()
        if TestCopyEnvironment.isActive() {
            // Leads the menu with the same "TEST COPY" label the window
            // strip shows (docs/stories/HAIL-34.md 21:51) - a disabled item,
            // there only to be read, not clicked.
            let testCopyItem = NSMenuItem(title: TestCopyEnvironment.stripLabel, action: nil, keyEquivalent: "")
            testCopyItem.isEnabled = false
            menu.addItem(testCopyItem)
        }
        // HAIL-193: what agents bring you, the same choice as Settings › Requests.
        menu.addItem(reachItem())
        menu.addItem(.separator())
        menu.delegate = self
        let openItem = NSMenuItem(title: "Open Waggle", action: #selector(openMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        // WAG-402: the same panel as the badge. Hidden while Screenshots are Off.
        let shotItem = NSMenuItem(title: ScreenshotCopy.menuItem, action: #selector(sendScreenshot), keyEquivalent: "s")
        shotItem.keyEquivalentModifierMask = [.control, .option]
        shotItem.target = self
        shotItem.isHidden = screenshots?.mode.isOn != true
        menu.addItem(shotItem)
        screenshotItem = shotItem
        // WAG-404: the crosshair. Hidden while Snip an area is Off. The menu shows ⌃⇧W.
        let snipMenuItem = NSMenuItem(title: ScreenshotCopy.snipMenuItem, action: #selector(snipArea), keyEquivalent: "w")
        snipMenuItem.keyEquivalentModifierMask = [.control, .shift]
        snipMenuItem.target = self
        snipMenuItem.isHidden = screenshots?.snipIsOn != true
        menu.addItem(snipMenuItem)
        snipItem = snipMenuItem
        menu.addItem(.separator())
        if Updater.isAvailable {
            let checkItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            checkItem.target = self
            menu.addItem(checkItem)
        } else {
            // Dev build: no update key, so updates are off (KNOCK-17 fold pass 2).
            let offItem = NSMenuItem(title: "Updates are off in development builds", action: nil, keyEquivalent: "")
            offItem.isEnabled = false
            menu.addItem(offItem)
        }
        statusItem.menu = menu
        updateCount(model.needsYouCases.count)
        observeTask = Task { [weak self] in
            for await cases in model.$needsYouCases.values {
                self?.updateCount(cases.count)
            }
        }
        reachTask = Task { [weak self] in
            guard let preferences = self?.preferences else { return }
            for await level in preferences.$reach.values {
                self?.show(level)
            }
        }
        Task { await preferences.load() }
    }

    /// The compact switch: Off, Things to look at, Look and read, Everything.
    private func reachItem() -> NSMenuItem {
        let levels = AskReach.allCases
        reachControl.segmentCount = levels.count
        for (index, level) in levels.enumerated() {
            reachControl.setLabel(level.menuTitle, forSegment: index)
        }
        reachControl.segmentStyle = .rounded
        reachControl.trackingMode = .selectOne
        reachControl.controlSize = .small
        reachControl.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        reachControl.target = self
        reachControl.action = #selector(reachPicked)
        reachControl.setAccessibilityLabel("What agents bring you")
        show(preferences.reach)

        let title = NSTextField(labelWithString: "Agents bring you")
        title.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, reachControl])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 8, right: 14)
        stack.frame = NSRect(x: 0, y: 0, width: 400, height: 56)
        let item = NSMenuItem()
        item.view = stack
        return item
    }

    private func show(_ level: AskReach) {
        self.level = level
        if let index = AskReach.allCases.firstIndex(of: level) { reachControl.selectedSegment = index }
        updateCount(count)
    }

    @objc private func reachPicked() {
        let index = reachControl.selectedSegment
        guard AskReach.allCases.indices.contains(index) else { return }
        let level = AskReach.allCases[index]
        Task { await preferences.setReach(level) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        screenshotItem?.isHidden = ScreenshotSettings.mode() == .off
        snipItem?.isHidden = !ScreenshotSettings.snipIsOn()
        Task { await preferences.refreshReach() }
    }

    private func updateCount(_ count: Int) {
        self.count = count
        statusItem.button?.title = level == .off ? " Off" : " \(count)"
    }

    @objc private func openMainWindow() {
        AppActivation.showMainWindow()
    }

    @objc private func sendScreenshot() {
        screenshots?.openShortcutPanel()
    }

    @objc private func snipArea() {
        screenshots?.startSnip()
    }

    @objc private func checkForUpdates() {
        Updater.checkForUpdates()
    }
}
