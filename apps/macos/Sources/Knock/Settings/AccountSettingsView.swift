import SwiftUI

/// The Account page (WAG-392). Local use needs no account. Signed out: "Sign in". Signed in: the email,
/// "Sign out" and "Your shared links", each with Open and Stop sharing.
struct AccountSettingsView: View {
    @StateObject private var model: AccountSettingsModel

    init(client: KnockClient) {
        _model = StateObject(wrappedValue: AccountSettingsModel(client: client))
    }

    var body: some View {
        SettingsPageChrome(title: SettingsPage.account.title, subtitle: SettingsPage.account.subtitle) {
            VStack(alignment: .leading, spacing: 20) {
                accountCard
                if model.account.signedIn { linksSection }
            }
        }
        .task { await model.loadUntilReady() }
        .onReceive(NotificationCenter.default.publisher(for: .knockSharingChanged)) { _ in Task { await model.load() } }
        .confirmationDialog(
            AccountLogic.stopConfirmTitle,
            isPresented: Binding(get: { model.confirmingStop != nil }, set: { if !$0 { model.confirmingStop = nil } }),
            presenting: model.confirmingStop
        ) { share in
            Button("Stop sharing", role: .destructive) { Task { await model.stop(share) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(AccountLogic.stopConfirmText)
        }
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionLabel("ACCOUNT")
            if model.account.signedIn {
                SettingsCard {
                    SettingsCardRow(title: model.account.email ?? "Signed in", subtitle: "Your shared links show this email.", showsDivider: false) {
                        SettingsSecondaryButton(title: "Sign out") { Task { await model.signOut() } }
                            .disabled(model.isBusy)
                    }
                }
            } else {
                SettingsCard {
                    SettingsCardRow(
                        title: "Not signed in",
                        subtitle: model.loaded ? AccountLogic.signInLine : "Checking the Waggle service...",
                        showsDivider: model.connect.isWaiting
                    ) {
                        if !model.connect.isWaiting {
                            SettingsPrimaryButton(title: model.connect.problem != nil ? "Try again" : "Sign in", minWidth: 72) {
                                Task { await model.connect.start() }
                            }
                            .disabled(!model.loaded || model.connect.isBusy)
                        }
                    }
                    if model.connect.isWaiting {
                        SignInStepView(connect: model.connect)
                            .padding(14)
                        HStack {
                            Spacer(minLength: 0)
                            SettingsSecondaryButton(title: "Cancel") { Task { await model.connect.cancel() } }
                        }
                        .padding([.horizontal, .bottom], 14)
                    } else if let problem = model.connect.problem {
                        Text(problem)
                            .knockTextStyle(Theme.Typography.body12_5w400)
                            .foregroundColor(Theme.Colors.accent)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding([.horizontal, .bottom], 14)
                    }
                }
            }
            if let problem = model.problem {
                Text(problem)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionLabel("YOUR SHARED LINKS")
            if model.shares.isEmpty {
                Text("Nothing is shared right now. Use Share on a case to make a link.")
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink3)
            } else {
                SettingsCard {
                    ForEach(Array(model.shares.enumerated()), id: \.element.id) { index, share in
                        SettingsCardRow(
                            title: share.title.isEmpty ? "Untitled case" : share.title,
                            subtitle: AccountLogic.detail(share) + "\n" + share.url,
                            showsDivider: index < model.shares.count - 1
                        ) {
                            HStack(spacing: 8) {
                                SettingsSecondaryButton(title: "Open") { model.openShare(share) }
                                SettingsSecondaryButton(title: model.stoppingId == share.relayId ? "Stopping..." : "Stop sharing") {
                                    model.confirmingStop = share
                                }
                                .disabled(model.stoppingId != nil)
                            }
                            .fixedSize()
                        }
                    }
                }
            }
        }
    }
}
