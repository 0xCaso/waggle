import SwiftUI

/// Runs `body` with `animation`, or at once when Reduce Motion is on (WAG-336, audit F19).
enum ReducedMotion {
    static func animate(reduceMotion: Bool, _ animation: Animation? = .default, _ body: () -> Void) {
        if reduceMotion { body() } else { withAnimation(animation, body) }
    }
}
