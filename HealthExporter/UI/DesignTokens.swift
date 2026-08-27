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
    static let faint = Color(red: 0.400, green: 0.373, blue: 0.408)    // #665F68

    /// What you said, behind your own words.
    ///
    /// A step above `raised` so a question reads as quoted rather than as
    /// another card. Deliberately not `accent.opacity(_:)`, which is what this
    /// was: a tinted bubble makes the question the loudest thing on a screen
    /// whose whole point is the answer.
    static let quoted = Color(red: 0.165, green: 0.141, blue: 0.161)   // #2A2429

    /// The existing brand red, unchanged: `AccentColor` is rgb(0.902, 0.310, 0.353).
    static let accent = Color(red: 0.902, green: 0.310, blue: 0.353)   // #E64F5A

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

extension View {
    /// A section header: small, spaced, uppercase, and quiet.
    func sectionLabelStyle() -> some View {
        self.font(.sectionLabel)
            .tracking(1.1)
            .textCase(.uppercase)
            .foregroundStyle(Ink.faint)
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
