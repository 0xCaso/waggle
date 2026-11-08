import SwiftUI

/// The copy on one preset card (HAIL-100). Plain words for the operator; the
/// daemon holds the separate text agents read (`PRESET_INSTRUCTIONS`).
extension ArtifactPreset {
    var title: String {
        switch self {
        case .quick: "Quick"
        case .visual: "Visual"
        case .rich: "Rich"
        }
    }

    var bullets: [String] {
        switch self {
        case .quick: ["Plain pages, text and tables", "Preview card only if it helps"]
        case .visual: ["Cards and a chart or two", "Preview card and real screenshots first"]
        case .rich: ["Interactive prototypes", "React for flows with real state"]
        }
    }

    /// How many of the three mini-picture blocks are filled in.
    var filledBlocks: Int {
        switch self {
        case .quick: 1
        case .visual: 2
        case .rich: 3
        }
    }
}

/// Holds the Artifacts page's selected preset. The daemon owns the value
/// (only it writes knock.db), so a pick is sent over `settings.set`; a failed
/// send puts the previous pick back.
@MainActor
final class ArtifactsSettingsModel: ObservableObject {
    @Published private(set) var preset: ArtifactPreset = .visual

    private let client: KnockClient
    private let retryDelay: Duration
    private let maxAttempts: Int

    init(client: KnockClient, retryDelay: Duration = .milliseconds(500), maxAttempts: Int = 20) {
        self.client = client
        self.retryDelay = retryDelay
        self.maxAttempts = maxAttempts
    }

    /// The socket may still be connecting (or the daemon still starting on
    /// demand) when the page first appears, so a failed read is retried for a
    /// few seconds rather than leaving the default showing.
    func load() async {
        for attempt in 0..<maxAttempts {
            if let stored = try? await client.artifactPreset() {
                preset = stored
                return
            }
            if attempt < maxAttempts - 1 { try? await Task.sleep(for: retryDelay) }
        }
    }

    func select(_ next: ArtifactPreset) async {
        guard next != preset else { return }
        let previous = preset
        preset = next
        do {
            try await client.setArtifactPreset(next)
        } catch {
            preset = previous
        }
    }
}

/// The Artifacts page (HAIL-100): three preset cards, one selected.
struct ArtifactsSettingsView: View {
    @StateObject private var model: ArtifactsSettingsModel
    private let client: KnockClient

    init(client: KnockClient) {
        self.client = client
        _model = StateObject(wrappedValue: ArtifactsSettingsModel(client: client))
    }

    var body: some View {
        SettingsPageChrome(title: SettingsPage.artifacts.title, subtitle: SettingsPage.artifacts.subtitle) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(ArtifactPreset.allCases) { preset in
                    card(preset)
                }
            }
            Text("Agents pick this up the next time they read Waggle's guide.")
                .knockTextStyle(Theme.Typography.body12_5w400)
                .foregroundColor(Theme.Colors.ink3)
            DesignKitSection(client: client)
        }
        .task { await model.load() }
    }

    private func card(_ preset: ArtifactPreset) -> some View {
        let isSelected = model.preset == preset
        return Button(action: { Task { await model.select(preset) } }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        let filled = index < preset.filledBlocks
                        RoundedRectangle(cornerRadius: 4)
                            .fill(filled ? Theme.Colors.win : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Theme.Colors.line, style: StrokeStyle(lineWidth: 1, dash: filled ? [] : [3, 2]))
                            )
                    }
                }
                .padding(6)
                .frame(height: 62)
                .background(Theme.Colors.list)
                .cornerRadius(7)
                Text(preset.title)
                    .knockTextStyle(Theme.Typography.rowTitle13_5w600)
                    .foregroundColor(Theme.Colors.ink)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(preset.bullets, id: \.self) { bullet in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            Text(bullet).fixedSize(horizontal: false, vertical: true)
                        }
                        .knockTextStyle(Theme.Typography.body12_5w400)
                        .foregroundColor(Theme.Colors.ink2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.Colors.win)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Theme.Colors.ink : Theme.Colors.line, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).pointerCursor()
        .accessibilityLabel(preset.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
