import SwiftUI

enum Design {
    static let ink = Color(red: 14 / 255, green: 16 / 255, blue: 21 / 255)
    static let panel = Color(red: 25 / 255, green: 29 / 255, blue: 38 / 255)
    static let raised = Color(red: 32 / 255, green: 37 / 255, blue: 48 / 255)
    static let line = Color(red: 50 / 255, green: 57 / 255, blue: 71 / 255)
    static let text = Color(red: 242 / 255, green: 244 / 255, blue: 250 / 255)
    static let muted = Color(red: 174 / 255, green: 183 / 255, blue: 199 / 255)
    static let accent = Color(red: 166 / 255, green: 187 / 255, blue: 255 / 255)
    static let accentInk = Color(red: 20 / 255, green: 32 / 255, blue: 64 / 255)
}

struct FanButtonStyle: ButtonStyle {
    var highlighted = true
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 12 : 17)
        configuration.label
            .font(compact ? .subheadline.weight(highlighted ? .semibold : .regular) : .headline)
            .foregroundStyle(highlighted ? Design.accentInk : (compact ? Design.muted : Design.text))
            .multilineTextAlignment(.center)
            .padding(.horizontal, compact ? 5 : 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: compact ? 47 : 58)
            .background(highlighted ? Design.accent : (compact ? Design.panel : Design.raised), in: shape)
            .overlay { shape.strokeBorder(highlighted ? Design.accent : Design.line, lineWidth: 1) }
            .contentShape(shape)
            .opacity(enabled ? (configuration.isPressed ? 0.74 : 1) : 0.46)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .foregroundStyle(Design.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct SheetScaffold<Content: View>: View {
    let title: String
    var titleID = "sheet.title"
    let close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(titleID)
                Spacer(minLength: 8)
                Button(L.t("common.done"), action: close)
                    .buttonStyle(QuietButtonStyle())
                    .accessibilityIdentifier("sheet.done")
            }
            .padding(.horizontal, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.top, 17)
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity)
        .background(Design.panel.ignoresSafeArea())
        .foregroundStyle(Design.text)
    }
}
