import SwiftUI

extension View {
    /// The view fills the width it is given, but never asks for more than `ideal` on its own.
    /// A `Text` reports its whole unwrapped line as its ideal width, so one long title, path or command
    /// would otherwise ask the window for thousands of points (WAG-257, width bug seen in 0.2.11).
    /// Put it on the root of any view that holds text from an agent.
    func boundedIdealWidth(_ ideal: CGFloat = 640) -> some View {
        frame(minWidth: 0, idealWidth: ideal, maxWidth: .infinity)
    }
}
