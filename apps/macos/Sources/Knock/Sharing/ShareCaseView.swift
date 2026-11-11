import SwiftUI

/// The "Share" button of the case header (WAG-387). After sharing it reads "Shared". It opens the small sheet.
/// It shows only when Sharing is on or the case is already shared (WAG-389). It never wraps and never shrinks:
/// the toolbar squeezes the other items first.
struct ShareCaseButton: View {
    @ObservedObject var model: SharingModel
    /// "View" in the sheet (WAG-399): opens the case on the Comments tab. Nil where the case has no tabs.
    var onViewComments: (() -> Void)?
    @State private var showsSheet = false

    var body: some View {
        // An HStack even when empty, so the load below runs while the button is hidden.
        HStack(spacing: 0) {
            if model.showsButton { pill }
        }
        .fixedSize()
        .layoutPriority(2)
        .task {
            await model.loadUntilReady()
            if ShareSheetEvidence.prepare(model) { showsSheet = true }
        }
    }

    private var pill: some View {
        Button { showsSheet = true } label: {
            HStack(spacing: 5) {
                Image(systemName: model.isShared ? "checkmark" : "square.and.arrow.up").font(.system(size: 11, weight: .semibold))
                Text(model.isShared ? "Shared" : "Share")
                    .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(minWidth: 58)
        }
        .buttonStyle(SharePillStyle(isShared: model.isShared))
        .help(model.isShared ? "See who can read this case" : "Share this case with your team")
        .accessibilityLabel(model.isShared ? "Shared. See who can read this case" : "Share this case")
        .sheet(isPresented: $showsSheet) { ShareSheetView(model: model, onClose: { showsSheet = false }, onViewComments: onViewComments.map { open in
            { showsSheet = false; open() }
        }) }
    }
}

/// The pill's look: a clean inner border, a hover fill and a short press.
struct SharePillStyle: ButtonStyle {
    let isShared: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(isShared: isShared, configuration: configuration)
    }

    private struct StyleBody: View {
        let isShared: Bool
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            let active = isHovered || configuration.isPressed
            configuration.label
                .foregroundColor(Theme.Colors.ink)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(isShared ? Theme.Colors.honeySoft : (active ? Theme.Colors.hover : Theme.Colors.win))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(isShared ? Theme.Colors.honey500 : Theme.Colors.line2, lineWidth: 1))
                .contentShape(Capsule())
                .pressFeel(isPressed: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: isHovered)
                .onHover { isHovered = $0 }
                .pointerCursor()
        }
    }
}

/// Who can see the case, "Copy link", "Stop sharing". Light look, explicit colours on every field.
struct ShareSheetView: View {
    @ObservedObject var model: SharingModel
    let onClose: () -> Void
    var onViewComments: (() -> Void)?
    @FocusState private var emailFocused: Bool
    @State private var confirmsStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.isShared ? "This case is shared" : (model.needsSignIn ? "Sign in to share" : "Share this case"))
                        .knockTextStyle(Theme.Typography.panelTitleSm16w650)
                        .foregroundColor(Theme.Colors.ink)
                    if model.isShared {
                        Spacer(minLength: 0)
                        HStack(spacing: 5) {
                            Circle().fill(Theme.Colors.ok).frame(width: 7, height: 7)
                            Text("Live").knockTextStyle(Theme.Typography.body12_5w400).foregroundColor(Theme.Colors.ok)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if !model.isShared && model.state.enabled && !model.needsSignIn {
                    Text("Your team reads it in a browser and can comment.")
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                }
            }
            if let share = model.state.share {
                sharedBody(share)
            } else if model.needsSignIn {
                SignInStepView(connect: model.connect)
            } else if !model.state.enabled {
                Text(ShareSheetLogic.offLine)
                    .knockTextStyle(Theme.Typography.body13w400)
                    .foregroundColor(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                chooseBody
            }
            if model.needsSignIn {
                // The sign-in step shows its own plain line.
            } else if let line = model.errorLine {
                Text(line)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.Colors.win)
        .preferredColorScheme(.light)
        .onDisappear { model.clearProblem() }
        .confirmationDialog(AccountLogic.stopConfirmTitle, isPresented: $confirmsStop) {
            Button("Stop sharing", role: .destructive) { Task { await model.stopSharing() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AccountLogic.stopConfirmText)
        }
    }

    private var chooseBody: some View { audienceChoice(showsExplainer: true) }

    private func audienceChoice(showsExplainer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            choice("Anyone with the link", detail: "People with the link can read it. They give a name to comment.", mode: .link)
            choice("Only these emails", detail: "People you list sign in with their email.", mode: .emails)
            if model.mode == .emails {
                TextField("ada@example.com, bo@example.com", text: $model.emailText)
                    .textFieldStyle(.plain)
                    .focused($emailFocused)
                    .accessibilityLabel("Emails")
                    .knockTextStyle(Theme.Typography.body13w400)
                    .foregroundColor(Theme.Colors.ink)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(Theme.Colors.list)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(emailFocused ? Theme.Colors.honey500 : Theme.Colors.line, lineWidth: 1))
                    .padding(.top, 4)
                    .onAppear { emailFocused = true }
                if let many = ShareSheetLogic.tooManyEmails(model.emailText) {
                    Text(many)
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.accent)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let bad = ShareSheetLogic.firstBadEmail(model.emailText) {
                    Text("Check \(bad). It is not a full email.")
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let note = model.newLinkNote {
                Text(note)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            if showsExplainer {
                Text(ShareSheetLogic.whatIsShared)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.mode)
    }

    private func choice(_ title: String, detail: String, mode: SharingMode) -> some View {
        ShareChoiceRow(title: title, detail: detail, isChosen: model.mode == mode) {
            model.mode = mode
            if mode == .emails { emailFocused = true }
        }
    }

    private func sharedBody(_ share: CaseShare) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            linkCard(share)
            if model.isChangingAudience {
                audienceChoice(showsExplainer: false)
            } else {
                rowsCard(share)
            }
            if let line = model.inviteLine {
                Text(line)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.skippedRounds, id: \.revision) { skipped in
                Text(skipped.reason)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The link, an "Open page" arrow, and a big "Copy link" under it (WAG-399, design A).
    private func linkCard(_ share: CaseShare) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.system(size: 12)).foregroundColor(Theme.Colors.ink3)
                    .accessibilityHidden(true)
                Text(share.url)
                    .knockTextStyle(Theme.Typography.monoMeta12w400)
                    .foregroundColor(Theme.Colors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ShareIconButton(symbol: "arrow.up.right", help: "Open page") { Task { await model.openPage() } }
                    .disabled(model.isBusy)
            }
            .padding(.vertical, 8)
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .background(Theme.Colors.list)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Colors.line, lineWidth: 1))
            Button { model.copyLink() } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.copied ? "checkmark" : "doc.on.doc").font(.system(size: 12))
                    Text(model.copied ? "Copied" : "Copy link").knockTextStyle(Theme.Typography.buttonSm12_5w600)
                }
                .foregroundColor(Theme.Colors.win)
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
            }
            .buttonStyle(SettingsButtonStyle(kind: .primary))
            .keyboardShortcut(.defaultAction)
            .animation(.easeOut(duration: 0.15), value: model.copied)
        }
    }

    /// Three rows in one card: who can read, comments (a toggle), the comment count (WAG-399).
    private func rowsCard(_ share: CaseShare) -> some View {
        let closed = model.commentsClosed
        return VStack(spacing: 0) {
            ShareRow(
                symbol: share.mode == .link ? "globe" : "person.2", title: "Who can read",
                subtitle: ShareSheetLogic.audienceSubtitle(share), action: model.isBusy ? nil : { model.beginChangeAudience() },
                trailing: { ShareRowTrailing(text: "Change") })
            Divider().overlay(Theme.Colors.line)
            ShareRow(
                symbol: "bubble.left", title: "Comments", subtitle: ShareSheetLogic.commentsSubtitle(closed: closed), action: nil,
                trailing: {
                    ShareSwitch(isOn: !model.commentsClosed, label: "Comments") { open in
                        Task { await model.setCommentsClosed(!open) }
                    }
                    .disabled(model.isBusy)
                })
            Divider().overlay(Theme.Colors.line)
            ShareRow(
                symbol: "text.bubble", title: ShareSheetLogic.commentCountTitle(model.comments),
                subtitle: ShareSheetLogic.lastCommentLine(model.comments),
                action: onViewComments,
                trailing: { if onViewComments != nil { ShareRowTrailing(text: "View") } })
        }
        .background(Theme.Colors.win)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Colors.line, lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.needsSignIn {
                SignInFooter(connect: model.connect, onClose: onClose)
            } else if model.isShared && model.isChangingAudience {
                Spacer(minLength: 0)
                SettingsSecondaryButton(title: "Cancel", shortcut: .cancelAction) { model.cancelChangeAudience() }
                SettingsPrimaryButton(title: model.isBusy ? "Saving..." : "Save", minWidth: 72, shortcut: .defaultAction) {
                    Task { await model.saveChangeAudience() }
                }
                .disabled(!model.canSaveChange)
            } else if model.isShared {
                StopSharingButton(isBusy: model.isBusy || !model.canStop) { confirmsStop = true }
                Spacer(minLength: 0)
                SettingsSecondaryButton(title: "Done", shortcut: .cancelAction, action: onClose)
            } else {
                Spacer(minLength: 0)
                SettingsSecondaryButton(title: "Cancel", shortcut: .cancelAction, action: onClose)
                SettingsPrimaryButton(
                    title: ShareSheetLogic.primaryTitle(busy: model.isBusy, problem: model.problem), minWidth: 72,
                    shortcut: .defaultAction
                ) { Task { await model.share() } }
                    .disabled(!model.canShare)
            }
        }
    }
}

/// One row of the rows card (WAG-399): a 28 px tile, a title with a subtitle, and a trailing control.
/// With an action the whole row is a button.
private struct ShareRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let subtitle: String?
    let action: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing
    @State private var isHovered = false

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .pointerCursor()
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundColor(Theme.Colors.ink2)
                .frame(width: 28, height: 28)
                .background(Theme.Colors.side)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).knockTextStyle(Theme.Typography.rowTitle13_5w600).foregroundColor(Theme.Colors.ink)
                if let subtitle {
                    Text(subtitle).knockTextStyle(Theme.Typography.body12_5w400).foregroundColor(Theme.Colors.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered && action != nil ? Theme.Colors.list : Color.clear)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// A small switch, honey when on. Drawn here so it keeps its colour when the window is not the key window.
private struct ShareSwitch: View {
    let isOn: Bool
    let label: String
    let onChange: (Bool) -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { onChange(!isOn) } label: {
            Capsule()
                .fill(isOn ? Theme.Colors.honey500 : Theme.Colors.line2)
                .frame(width: 34, height: 20)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(Theme.Colors.win).frame(width: 16, height: 16).padding(2)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isOn)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// "Change" or "View" with a chevron, at the end of a row.
private struct ShareRowTrailing: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Text(text).knockTextStyle(Theme.Typography.caption13w500)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(Theme.Colors.ink2)
    }
}

/// A small icon-only button with help text and a VoiceOver label (the arrow of the link card).
private struct ShareIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.Colors.ink)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(isHovered ? Theme.Colors.hover : Theme.Colors.win))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.Colors.line2, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .pointerCursor()
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The sign-in step (WAG-392): one line, then the code and a wait state once the browser is open.
struct SignInStepView: View {
    @ObservedObject var connect: AccountConnectModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AccountLogic.signInLine)
                .knockTextStyle(Theme.Typography.body13w400)
                .foregroundColor(Theme.Colors.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if let code = connect.account.connect {
                Text(code.userCode)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundColor(Theme.Colors.ink)
                    .textSelection(.enabled)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity)
                    .background(Theme.Colors.honeySoft)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Sign-in code \(code.userCode)")
                HStack(spacing: 8) {
                    Circle().fill(Theme.Colors.honey500).frame(width: 7, height: 7)
                        .opacity(pulse && !reduceMotion ? 0.35 : 1)
                    Text(AccountLogic.waitingLine)
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .onAppear { withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true } }
            }
            if let problem = connect.problem {
                Text(problem)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: connect.isWaiting) { if connect.isWaiting { await connect.poll() } }
    }
}

/// Cancel and "Continue in browser" for the sign-in step. Cancel while a code shows stops the sign-in; else it closes the sheet.
private struct SignInFooter: View {
    @ObservedObject var connect: AccountConnectModel
    let onClose: () -> Void

    var body: some View {
        Spacer(minLength: 0)
        SettingsSecondaryButton(title: "Cancel", shortcut: .cancelAction) {
            if connect.isWaiting { Task { await connect.cancel() } } else { onClose() }
        }
        if !connect.isWaiting {
            SettingsPrimaryButton(title: connect.buttonTitle, minWidth: 140, shortcut: .defaultAction) {
                Task { await connect.start() }
            }
            .disabled(connect.isBusy)
        }
    }
}

/// "Stop sharing" in red with an icon, at the foot of the shared sheet (WAG-399).
private struct StopSharingButton: View {
    let isBusy: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle").font(.system(size: 12))
                Text("Stop sharing").knockTextStyle(Theme.Typography.caption13w500)
            }
            .foregroundColor(Theme.Colors.accent.opacity(isHovered ? 0.8 : 1))
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { isHovered = $0 }
        .pointerCursor()
    }
}

/// One of the two audience choices: the chosen row has a soft honey fill, the row under the pointer a light one.
private struct ShareChoiceRow: View {
    let title: String
    let detail: String
    let isChosen: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(isChosen ? Theme.Colors.honey600 : Theme.Colors.ink3)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).knockTextStyle(Theme.Typography.rowTitle13_5w600).foregroundColor(Theme.Colors.ink)
                    Text(detail).knockTextStyle(Theme.Typography.body12_5w400).foregroundColor(Theme.Colors.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(isChosen ? Theme.Colors.honeySoft : (isHovered ? Theme.Colors.list : Color.clear)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: isChosen)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? [.isButton, .isSelected] : .isButton)
    }
}

/// The team's comments in the case (WAG-387, threads in WAG-394): a root comment with its replies, a reply field,
/// Resolve and Reopen. Plain text. Nothing shows for a case with no comments yet. The comments stay after Stop
/// sharing (WAG-391). A resolved thread folds to one line.
struct SharedCommentsSection: View {
    @ObservedObject var model: SharingModel

    var body: some View {
        if !model.comments.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("FROM YOUR TEAM")
                    .knockTextStyle(Theme.AskDoc.Typography.monoLabel10_5)
                    .foregroundColor(Theme.Colors.ink3)
                ForEach(model.threads) { thread in
                    CommentThreadView(model: model, thread: thread)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: model.comments.count)
        }
    }
}

/// WAG-397: the Decision tab shows one line for the team thread ("3 team comments, 1 new"). It opens the Comments tab.
struct TeamCountLine: View {
    @ObservedObject var model: SharingModel
    let onOpen: () -> Void

    var body: some View {
        if let line = MergedComments.countLine(model.comments) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Text(line)
                        .knockTextStyle(Theme.Typography.priorRevisionLink12w500)
                        .foregroundColor(Theme.Colors.ink2)
                    Text("\u{00B7} Show")
                        .knockTextStyle(Theme.Typography.priorRevisionLink12w500)
                        .foregroundColor(Theme.Colors.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityHint("Opens the Comments tab")
        }
    }
}

/// One thread. With `showsLabels` (the Comments tab, WAG-397) each comment has its label: Team, Agent, You · on the page.
struct CommentThreadView: View {
    @ObservedObject var model: SharingModel
    let thread: CommentThread
    var showsLabels = false
    @State private var expanded = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var showsFolded: Bool { thread.isResolved && !expanded }

    var body: some View {
        Group {
            if showsFolded { foldedRow } else { openCard }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.list)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.Colors.line, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: showsFolded)
    }

    private var foldedRow: some View {
        Button { expanded = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.Colors.ok)
                Text(CommentThreads.foldedLine(thread))
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(CommentThreads.foldedLine(thread))
        .accessibilityHint("Shows the thread")
    }

    private var openCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            commentView(thread.root, isRoot: true)
            ForEach(thread.replies) { reply in
                commentView(reply, isRoot: false)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.Colors.line2).frame(width: 2) }
            }
            if let problem = model.replyProblems[thread.id] {
                Text(problem)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.commentsClosed && !thread.isResolved { replyField }
        }
        .padding(12)
    }

    private func commentView(_ comment: SharedComment, isRoot: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let name = nameText(comment, isRoot: isRoot) {
                    Text(name)
                        .knockTextStyle(Theme.Typography.rowTitle13_5w600)
                        .foregroundColor(Theme.Colors.ink)
                        .help(comment.authorEmail ?? "")
                }
                if showsLabels { CommentLabelChip(text: MergedComments.label(comment)) }
                if let kind = SharedCommentText.kindLabel(comment) {
                    Text(kind)
                        .knockTextStyle(Theme.Typography.caption11_5w400)
                        .foregroundColor(Theme.Colors.ink3)
                }
                if comment.unread {
                    Circle().fill(Theme.Colors.honey500).frame(width: 6, height: 6)
                        .accessibilityLabel("New")
                }
                Spacer(minLength: 0)
                if isRoot { resolveButton }
            }
            if isRoot, let anchor = SharedCommentText.anchor(comment) {
                Text(anchor)
                    .knockTextStyle(Theme.Typography.body12_5w400)
                    .foregroundColor(Theme.Colors.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(comment.body)
                .knockTextStyle(Theme.Typography.body13w400)
                .foregroundColor(Theme.Colors.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The name above a comment. With labels on, the label already says "Agent" or "You · on the page", so only the round stays.
    private func nameText(_ comment: SharedComment, isRoot: Bool) -> String? {
        if showsLabels, !MergedComments.isTeam(comment) {
            return isRoot ? comment.revision.map { "Round \($0)" } : nil
        }
        return isRoot ? SharedCommentText.byline(comment) : CommentThreads.author(comment)
    }

    private var resolveButton: some View {
        QuietTextButton(title: thread.isResolved ? "Reopen" : "Resolve") {
            Task {
                await model.resolve(thread.id, resolved: !thread.isResolved)
                if thread.isResolved { expanded = false }
            }
        }
    }

    private var replyField: some View {
        let busy = model.replying.contains(thread.id)
        let canSend = CommentThreads.canSend(draft, busy: busy, commentsClosed: model.commentsClosed)
        return HStack(alignment: .bottom, spacing: 8) {
            TextField("Reply", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($focused)
                .accessibilityLabel("Reply")
                .knockTextStyle(Theme.Typography.body13w400)
                .foregroundColor(Theme.Colors.ink)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(Theme.Colors.win)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Theme.Colors.honey500 : Theme.Colors.line, lineWidth: 1))
            Button { send() } label: {
                Text(busy ? "Sending..." : "Reply")
                    .knockTextStyle(Theme.Typography.buttonSm12_5w600)
                    .foregroundColor(canSend ? Theme.Colors.ink : Theme.Colors.ink3)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 12)
                    .background(canSend ? Theme.Colors.honeySoft : Theme.Colors.side)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
            .pointerCursor()
        }
    }

    private func send() {
        let text = draft
        Task { if await model.reply(to: thread.id, body: text) { draft = "" } }
    }
}

/// The small label that says whose comment it is (WAG-397): a neutral chip, like the other chips of the app.
struct CommentLabelChip: View {
    let text: String

    var body: some View {
        Text(text)
            .knockTextStyle(Theme.Typography.caption11_5w400)
            .foregroundColor(Theme.Colors.ink2)
            .padding(.vertical, 1)
            .padding(.horizontal, 7)
            .background(Theme.Colors.side)
            .clipShape(Capsule())
    }
}

/// A quiet text button, like "Change" in the Share sheet.
private struct QuietTextButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .knockTextStyle(Theme.Typography.caption13w500)
                .foregroundColor(isHovered ? Theme.Colors.ink : Theme.Colors.ink2)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
    }
}
