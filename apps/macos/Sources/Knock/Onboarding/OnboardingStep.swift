import Foundation

/// The two steps of the short setup window, in order, and the "Step N of 2" label each screen shows
/// (WAG-338; the old setup had eight). One source, so a step added later renumbers every screen at once.
enum OnboardingStep: Int, CaseIterable, Equatable {
    case connect = 1
    case firstJob

    var label: String { "Step \(rawValue) of \(Self.allCases.count)" }

    /// The pill in the progress row.
    var pillTitle: String {
        switch self {
        case .connect: "Connect"
        case .firstJob: "Your first job"
        }
    }
}

extension OnboardingModel.Screen {
    var step: OnboardingStep {
        switch self {
        case .connect: .connect
        case .firstJob: .firstJob
        }
    }
}
