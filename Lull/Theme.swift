import BedJetKit
import SwiftUI

enum Theme {
    static let background = Color.black
    static let surface = Color(red: 0.055, green: 0.059, blue: 0.071)
    static let raised = Color(red: 0.098, green: 0.102, blue: 0.118)
    static let hairline = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)

    static let cool = Color(red: 0.30, green: 0.64, blue: 1.0)
    static let deepCool = Color(red: 0.17, green: 0.36, blue: 1.0)
    static let warm = Color(red: 1.0, green: 0.54, blue: 0.24)
    static let hot = Color(red: 1.0, green: 0.30, blue: 0.18)
    static let neutral = Color(red: 0.56, green: 0.56, blue: 0.60)
}

extension Mode {
    var tint: Color {
        switch self {
        case .cool: return Theme.cool
        case .heat: return Theme.warm
        case .turbo: return Theme.hot
        case .extendedHeat: return Color(red: 1.0, green: 0.70, blue: 0.25)
        case .dry: return Color(red: 0.35, green: 0.84, blue: 0.77)
        case .standby, .wait: return Theme.neutral
        }
    }
}

/// Small all-caps label used above groups of content.
struct Eyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(Theme.secondary)
            // Read as written rather than in capitals, which VoiceOver can spell out letter by letter.
            .accessibilityLabel(text)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(prominent ? Color.white : Theme.raised, in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Theme.hairline))
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// A slider with a tinted track that snaps to whole steps and shows its value inline.
struct LabeledSlider: View {
    let title: String
    let valueText: String
    /// What VoiceOver reads for the value, when the shown text abbreviates it.
    var spokenValue: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var tint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.secondary)
                Spacer()
                Text(valueText)
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            // The slider says the same, so VoiceOver stops once, on the control it can adjust.
            .accessibilityHidden(true)
            Slider(value: $value, in: range, step: step)
                .tint(tint)
                .accessibilityLabel(title)
                .accessibilityValue(spokenValue ?? valueText)
                .sensoryFeedback(.selection, trigger: value)
        }
    }
}
