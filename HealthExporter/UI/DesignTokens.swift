import SwiftUI

/// The redesign's palette and type ramp, in one place.
///
/// Deliberately *not* semantic system colours. `MetricStyle` follows Health's
/// category colouring so a glance here and a glance at Health agree about what
/// kind of thing a row is, and that stays — but the surfaces around it are this
/// app's own, because the screens it now draws are not screens Health has.
///
/// Fixed rather than adaptive. These are chosen against a warm near-black
/// ground; handing them to `Color(.systemBackground)` in light mode would give
/// a different design, not a lighter one. A light variant is a deliberate piece
/// of work, not a colour-scheme flip — see `docs/design/README.md`.
enum Ink {
    /// Screen background. Warm, never pure black — pure black on OLED makes the
    /// hairlines used throughout disappear entirely.
    static let ground = Color(red: 0.071, green: 0.067, blue: 0.075)   // #121113
    /// Cards and grouped rows.
    static let surface = Color(red: 0.090, green: 0.082, blue: 0.094)  // #171518
    /// Chips and secondary controls.
    static let raised = Color(red: 0.102, green: 0.094, blue: 0.106)   // #1A181B
    /// The ask bar.
    static let field = Color(red: 0.118, green: 0.106, blue: 0.125)    // #1E1B20
    /// Every border.
    static let hairline = Color(red: 0.180, green: 0.165, blue: 0.188) // #2E2A30
    /// Between rows inside one card — quieter than a border.
    static let divider = Color(red: 0.125, green: 0.114, blue: 0.133)  // #201D22

    static let primary = Color(red: 0.957, green: 0.945, blue: 0.925)  // #F4F1EC
    static let secondary = Color(red: 0.788, green: 0.761, blue: 0.784) // #C9C2C8
    static let muted = Color(red: 0.604, green: 0.576, blue: 0.608)    // #9A939B
    /// The quietest text: section labels, timestamps, units, placeholders.
    ///
    /// Was #665F68, which measured 3.05:1 on `ground` and 2.76:1 on `field` —
    /// under WCAG AA for text, on the colour that carries the "not medical
    /// advice" line. #8A838C clears 4.5:1 on every surface here (5.12 ground,
    /// 4.93 surface, 4.63 field) and still sits a clear step below `muted`.
    static let faint = Color(red: 0.541, green: 0.514, blue: 0.549)    // #8A838C

    /// What you said, behind your own words.
    ///
    /// A step above `raised` so a question reads as quoted rather than as
    /// another card. Deliberately not `accent.opacity(_:)`, which is what this
    /// was: a tinted bubble makes the question the loudest thing on a screen
    /// whose whole point is the answer.
    static let quoted = Color(red: 0.165, green: 0.141, blue: 0.161)   // #2A2429

    /// The existing brand red, unchanged: `AccentColor` is rgb(0.902, 0.310, 0.353).
    static let accent = Color(red: 0.902, green: 0.310, blue: 0.353)   // #E64F5A

    /// Destructive actions. Warmer and a shade lighter than `accent`, which is
    /// the point: on this palette the brand colour is already red, so a delete
    /// row tinted with it is indistinguishable from every other emphasis on the
    /// screen. Close enough to read as the same family, far enough to read as a
    /// warning.
    static let danger = Color(red: 0.910, green: 0.416, blue: 0.384)   // #E86A62

    /// Reserved status colours. `measured` means "this rests on real days" and
    /// `absent` means "this stopped arriving" — neither is ever borrowed to
    /// distinguish one metric from another.
    static let measured = Color(red: 0.435, green: 0.749, blue: 0.659) // #6FBFA8
    static let absent = Color(red: 0.878, green: 0.643, blue: 0.345)   // #E0A458
    /// Text on an amber ground, where `absent` itself would not carry contrast.
    static let absentInk = Color(red: 0.910, green: 0.784, blue: 0.604) // #E8C89A
}

extension Font {
    /// Figures, units, timestamps and section labels.
    ///
    /// Monospaced digits are the point: a column of numbers that shifts as the
    /// values change is a column nobody scans. `.monospaced()` on the system
    /// face rather than a bundled one — no font files, no licence, and it
    /// matches the register the design asks for.
    static func figure(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The one sentence the Today screen leads with.
    static let lead = Font.system(size: 26, weight: .semibold)
    /// Uppercase section headers.
    static let sectionLabel = Font.system(size: 11, weight: .semibold, design: .monospaced)
}

/// A fixed point size that follows Dynamic Type.
///
/// `.system(size:)` is a fixed size, and nearly every label in this app was set
/// with one, so the text-size setting in iOS changed nothing outside the few
/// system-styled lists. `@ScaledMetric` returns exactly the base size at the
/// default setting — so at default nothing moves — and scales it with the text
/// style nearest that size when the person asks for bigger (or smaller) text.
private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(_ base: CGFloat, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: base, relativeTo: Self.style(for: base))
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }

    /// The system text style whose default size is nearest, so a 13pt caption
    /// grows like a caption and a 26pt lead like a title.
    private static func style(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.75: return .caption2
        case ..<12.75: return .caption
        case ..<14: return .footnote
        case ..<15.5: return .subheadline
        case ..<16.5: return .callout
        case ..<19: return .body
        case ..<24: return .title2
        case ..<30: return .title
        default: return .largeTitle
        }
    }
}

extension View {
    /// The system face at `size`, scaled with Dynamic Type.
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size, weight: weight, design: design))
    }

    /// `Font.figure`, scaled with Dynamic Type.
    func figureFont(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        scaledFont(size, weight: weight, design: .monospaced)
    }

    /// A section header: small, spaced, uppercase, and quiet. Marked as a
    /// header, so VoiceOver's headings rotor can jump between sections on every
    /// screen.
    func sectionLabelStyle() -> some View {
        self.scaledFont(11, weight: .semibold, design: .monospaced)
            .tracking(1.1)
            .textCase(.uppercase)
            .foregroundStyle(Ink.faint)
            .accessibilityAddTraits(.isHeader)
    }

    /// A card: surface fill, hairline border, 14pt corners.
    func cardStyle() -> some View {
        self.background(Ink.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Ink.hairline, lineWidth: 1)
            )
    }
}

extension View {
    /// A placeholder in the design's own colour.
    ///
    /// `TextField`'s built-in placeholder cannot be tinted, and the system
    /// default is far brighter than `faint` — bright enough on this ground to
    /// read as text somebody typed. Drawing it behind an empty field is the
    /// only way to hit the specified colour, which means taking it away by hand
    /// the moment there is anything to overlap with.
    func prompt(_ text: String, visible: Bool, size: CGFloat = 14) -> some View {
        background(alignment: .leading) {
            if visible {
                // Hidden from VoiceOver: it is drawn decoration, and the field
                // carries its own label.
                Text(text)
                    .scaledFont(size)
                    .foregroundStyle(Ink.faint)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
