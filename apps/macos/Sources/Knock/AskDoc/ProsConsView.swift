import SwiftUI

/// The good and the bad of one option (WAG-276, prototype `.pc`): a PROS box and a CONS box, each line with
/// a green plus or a red minus. A side with no lines is left out.
struct ProsConsView: View {
    let pros: [String]
    let cons: [String]

    init(pros: [String], cons: [String]) {
        self.pros = pros
        self.cons = cons
    }

    init(option: Option) {
        self.init(pros: option.pros, cons: option.cons)
    }

    var body: some View {
        if !pros.isEmpty || !cons.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                if !pros.isEmpty { box("PROS", lines: pros, sign: "+", color: Theme.AskDoc.Colors.pro) }
                if !cons.isEmpty { box("CONS", lines: cons, sign: "−", color: Theme.AskDoc.Colors.con) }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func box(_ label: String, lines: [String], sign: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .knockTextStyle(Theme.AskDoc.Typography.monoLabel10_5)
                .foregroundColor(Theme.Colors.ink3)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(sign).foregroundColor(color).frame(width: 10)
                    SourcedText(text: line, style: Theme.AskDoc.Typography.optionCard13, color: Theme.Colors.ink2)
                }
                .knockTextStyle(Theme.AskDoc.Typography.optionCard13)
                .accessibilityLabel((sign == "+" ? "Pro: " : "Con: ") + line)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.list)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
