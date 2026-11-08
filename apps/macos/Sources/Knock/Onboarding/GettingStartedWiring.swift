import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// The getting started list asks for the job picker (step 2 of the short window).
    static let knockOpenJobPicker = Notification.Name("knockOpenJobPicker")
    /// Opens Settings on a page. `object` is the `SettingsPage`.
    static let knockShowSettingsPage = Notification.Name("knockShowSettingsPage")
}

extension GettingStartedModel {
    /// Connects the model to the app: the asks the app holds (they tick the lines and start the tour), the
    /// notification permission, and the design kit. The model only ever reads from these.
    func observe(_ appModel: AppModel, permission: NotificationPermissionObserver = .shared) {
        let askChanges = Publishers.CombineLatest(appModel.$needsYouCases, appModel.$waitingOnAgentCases)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] needsYou, waiting in self?.apply(cases: needsYou + waiting) }
        let permissionChanges = permission.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.updateNotifications(state) }
        let becameActive = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self, weak appModel] _ in
                guard let self, let appModel else { return }
                Task { await self.refreshDesignKit(client: appModel.client) }
            }
        observations = [askChanges, permissionChanges, becameActive]
        Task { await refreshDesignKit(client: appModel.client) }
    }

    /// The design kit line ticks once a kit is on and holds something.
    func refreshDesignKit(client: KnockClient) async {
        guard let result = try? await client.designKit() else { return }
        let kit = result.kit
        updateDesignKit(isSet: kit.enabled && !(kit.designSystem.isEmpty && kit.penFile.isEmpty && kit.tone.isEmpty))
    }
}

/// The Help menu item that brings the getting started list back.
struct GettingStartedMenuCommand: View {
    @ObservedObject var gettingStarted: GettingStartedModel

    var body: some View {
        Button("Show getting started") {
            gettingStarted.show()
            AppActivation.showMainWindow()
        }
        .disabled(gettingStarted.isListVisible)
    }
}
