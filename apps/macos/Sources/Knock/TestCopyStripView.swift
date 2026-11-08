import SwiftUI

/// The full-width "TEST COPY" strip (docs/stories/HAIL-34.md operator report
/// 21:51): shown at the top of every Knock window whenever `TestCopyEnvironment.
/// isActive()` is true, so a worker's evidence build never looks exactly like
/// the operator's real app. Renders nothing otherwise - the real app never
/// shows it.
///
/// "path middle-truncated" (the operator's own words) means only the data-root
/// path segment shrinks; the leading and trailing sentence fragments around it
/// never truncate. Three `Text` segments in an `HStack` do this: the two
/// sentence fragments get a high layout priority so SwiftUI starves the path
/// segment first, and only the path segment sets `.lineLimit(1)` with
/// `.truncationMode(.middle)`.
struct TestCopyStripView: View {
    var body: some View {
        if TestCopyEnvironment.isActive() {
            HStack(spacing: 0) {
                Text("TEST COPY · data in ")
                    .layoutPriority(1)
                Text(TestCopyEnvironment.dataRootLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(". Not your real Waggle.")
                    .layoutPriority(1)
            }
            .knockTextStyle(Theme.Typography.recommendLine12w400)
            .foregroundColor(Theme.Colors.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(Theme.Colors.accentSoft)
        }
    }
}
