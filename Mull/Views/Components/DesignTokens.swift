import SwiftUI

/// Design tokens — single source of truth for all visual constants.
///
/// Typography: 5 levels with clear hierarchy
/// Spacing: 4px grid
/// Radius: 3 tiers
/// Colors: semantic + accent gradients
/// Shadows: 2 tiers for depth
enum DS {

    // MARK: - Typography (8 levels, strict hierarchy)
    //
    //   hero     28pt bold         — large numbers, empty states
    //   title    15pt semibold     — section titles, card headers
    //   body     13pt regular      — primary text
    //   bodyMed  13pt medium       — emphasized body text
    //   small    12pt regular      — button labels, secondary UI
    //   smallMed 12pt medium       — emphasized button labels
    //   caption  11pt regular      — metadata, tertiary text
    //   micro    10pt monospaced   — timestamps, code, data
    //   mini      9pt regular      — tags, evidence, minimal text
    //   miniMed   9pt medium       — mini labels, badges
    //   tiny      8pt regular      — sparkline labels, extreme compact

    static let heroFont = Font.system(size: 28, weight: .bold)
    static let titleFont = Font.system(size: 15, weight: .semibold)
    static let bodyFont = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let smallFont = Font.system(size: 12)
    static let smallMedium = Font.system(size: 12, weight: .medium)
    static let captionFont = Font.system(size: 11)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let microFont = Font.system(size: 10, design: .monospaced)
    static let miniFont = Font.system(size: 9)
    static let miniMedium = Font.system(size: 9, weight: .medium)
    static let miniBold = Font.system(size: 9, weight: .bold)
    static let tinyFont = Font.system(size: 8)

    static let labelFont = Font.system(size: 11, weight: .medium)
    static let labelTracking: CGFloat = 0.5

    // MARK: - Reading surface (editor + rendered markdown)
    //
    // Borrowed from Crane MD §4: a reading/writing surface breathes more than the
    // dense dashboard. Generous measure, ~1.5 line-height, 1行目 = title. These are
    // the ONLY large type sizes — they belong to the editor, not the chrome.
    static let readTitleFont = Font.system(size: 22, weight: .bold)      // 1行目 / # heading
    static let readH2Font = Font.system(size: 17, weight: .semibold)     // ##
    static let readH3Font = Font.system(size: 15, weight: .semibold)     // ###
    static let readFont = Font.system(size: 15)                          // body — read & write
    static let readLineSpacing: CGFloat = 7                              // ≈1.46 line-height at 15pt
    static let readMeasure: CGFloat = 680                                // max line length (40–75 chars)
    static let readMargin: CGFloat = 24                                  // = xl; wider than dashboard

    // MARK: - Spacing (4px grid)

    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

    // MARK: - Radius (softer, more organic)

    static let radiusSm: CGFloat = 8
    static let radiusMd: CGFloat = 12
    static let radiusLg: CGFloat = 16

    // MARK: - Daylight — espresso ink on ivory (Cucinelli)
    //
    // The app lives on a warm ivory page: Umbrian daylight, undyed cashmere, the
    // cream of a fine book. Espresso ink, one tobacco accent, hairlines like a
    // faint pencil rule. Type-led, lots of air. (Replaces the cool Nocturne;
    // these are the same token names so every call site flips in one place.)

    /// The ivory page — everything sits on this. Warm cream.
    static let canvas = Color(red: 0.949, green: 0.929, blue: 0.882)   // #F2EDE1
    /// A surface lifted off the page (cards, sidebar wells) — barely lighter.
    static let surface = Color(red: 0.969, green: 0.953, blue: 0.918)  // #F7F3EA
    /// A surface on hover / selection.
    static let surfaceHi = Color(red: 0.988, green: 0.976, blue: 0.949) // #FCF9F2
    /// Hairline rule — warm umber at low opacity. The structural signature.
    static let hairline = Color(red: 0.224, green: 0.192, blue: 0.149).opacity(0.12)

    /// Tobacco — the single accent. A thread, never a fill. (Named `moon` for
    /// call-site compatibility; it is no longer moonlight.)
    static let moon = Color(red: 0.580, green: 0.447, blue: 0.196)     // #945F32
    static let moonDim = Color(red: 0.46, green: 0.36, blue: 0.18)

    /// Text tiers (warm espresso, never pure black).
    static let ink = Color(red: 0.224, green: 0.192, blue: 0.149)            // #393127
    static let inkDim = Color(red: 0.224, green: 0.192, blue: 0.149).opacity(0.62)
    static let inkFaint = Color(red: 0.224, green: 0.192, blue: 0.149).opacity(0.36)

    // MARK: - Earth palette (one harmonious family — warm, muted, low-sat)
    //
    // Cucinelli is not a rainbow. Every accent is a natural dye drawn from the
    // same earth as the tobacco anchor: ochre, olive, clay, slate, plum, taupe.
    // Nothing competes with the ink or the page; the whole screen reads tonal.

    static let camel     = Color(red: 0.72, green: 0.54, blue: 0.24)  // #B88A3D — lighter tobacco
    static let olive     = Color(red: 0.43, green: 0.46, blue: 0.29)  // #6E7549 — greyed green
    static let clay      = Color(red: 0.66, green: 0.36, blue: 0.26)  // #A85C42 — terracotta
    static let slate     = Color(red: 0.42, green: 0.49, blue: 0.53)  // #6B7D87 — the one cool note, muted
    static let plum      = Color(red: 0.52, green: 0.36, blue: 0.42)  // #855C6B — greyed rosewood
    static let dustyRose = Color(red: 0.68, green: 0.45, blue: 0.44)  // #AD7370 — faded clay rose
    static let taupe     = Color(red: 0.55, green: 0.51, blue: 0.45)  // #8C8273 — warm neutral

    // MARK: - Semantic Colors (drawn from the earth palette)

    static let recording = olive   // active / "remembering"
    static let paused = camel      // a pause, not an alarm
    static let error = clay        // trouble, spoken warmly
    static let nowLine = moon      // tobacco — the present moment

    // MARK: - Event Type Colors
    //
    // Used in LiveTab, HomeTab, InsightsTab for event type indicators.
    // Never use raw .blue/.orange/.green — always go through these.

    static let eventKeystroke = slate      // the single cool note
    static let eventClipboard = camel
    static let eventWindow = olive
    static let eventApp = plum
    static let eventAudio = dustyRose

    // MARK: - Insight Colors

    static let langJapanese = clay
    static let langEnglish = moon
    static let langCode = olive

    // MARK: - Gradients (tobacco)

    static let accentGradient = LinearGradient(
        colors: [
            Color(red: 0.62, green: 0.49, blue: 0.24),   // Tobacco
            Color(red: 0.45, green: 0.34, blue: 0.15)    // Deeper tobacco
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Panel

    static let panelWidth: CGFloat = 260

    // MARK: - App Colors (deterministic from name)

    /// Generate a consistent color for any app name.
    /// Well-known apps map to the earth palette; everything else gets a muted
    /// hash-based dye. No raw system colors — nothing breaks the tonal family.
    static func appColor(_ name: String) -> Color {
        switch name {
        case "Xcode", "Safari", "Mail", "Zoom", "Preview", "Cursor": return slate
        case "Code", "Visual Studio Code", "Figma", "Slack", "Obsidian",
             "Simulator", "Teams", "Discord": return plum
        case "Firefox", "Illustrator", "Notes": return camel
        case "Chrome", "Google Chrome", "Messages",
             "Terminal", "iTerm2", "Warp", "Ghostty": return olive
        case "Arc", "Photoshop": return dustyRose
        case "Finder", "Notion": return taupe
        default: break
        }

        // Muted earth dye for any unknown app
        return colorFromHash(name)
    }

    /// Deterministic color from string hash. Same app name → always same color.
    /// Warm bias — saturation is moderate, brightness is high. Feels friendly.
    private static func colorFromHash(_ string: String) -> Color {
        var hash: UInt64 = 5381
        for char in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)
        }

        let hue = Double(hash % 360) / 360.0
        let saturation = 0.16 + Double((hash >> 8) % 18) / 100.0  // 0.16-0.34 (muted — a natural dye, not a crayon)
        let brightness = 0.44 + Double((hash >> 16) % 16) / 100.0  // 0.44-0.60 (readable on ivory)

        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

// MARK: - View Extensions

extension View {
    /// The night canvas behind a whole surface.
    func nocturneCanvas() -> some View {
        self.background(DS.canvas.ignoresSafeArea())
    }

    /// A faint moonlight glow behind a hero element.
    func moonGlow(_ intensity: Double = 0.16) -> some View {
        self.background(
            RadialGradient(
                colors: [DS.moon.opacity(intensity), .clear],
                center: .topLeading, startRadius: 0, endRadius: 320
            )
            .allowsHitTesting(false)
        )
    }

    /// Standard card — a surface lifted off the night with a hairline edge.
    func mullCard(isHovered: Bool = false) -> some View {
        self
            .padding(DS.md)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusMd)
                    .fill(isHovered ? DS.surfaceHi : DS.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusMd)
                    .strokeBorder(isHovered ? DS.moon.opacity(0.22) : DS.hairline, lineWidth: 0.75)
            )
    }

    /// Hero card — a surface touched by moonlight.
    func mullHeroCard() -> some View {
        self
            .padding(DS.xl)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: DS.radiusLg)
                        .fill(DS.surface)
                    RoundedRectangle(cornerRadius: DS.radiusLg)
                        .fill(DS.moon.opacity(0.05))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusLg)
                    .strokeBorder(DS.moon.opacity(0.18), lineWidth: 0.75)
            )
    }

    /// Section label style — letterspaced moonlight, quiet.
    func sectionLabel() -> some View {
        self
            .font(DS.labelFont)
            .tracking(1.4)
            .foregroundStyle(DS.inkFaint)
            .textCase(.uppercase)
    }

    /// Shimmer animation for skeleton loading states.
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - Shimmer Effect

private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    colors: [
                        .clear,
                        Color.primary.opacity(0.04),
                        .clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: phase * 300)
                .mask(content)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// MARK: - Card ViewModifiers (for skeleton type-erasure)

struct mullCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.mullCard()
    }
}

struct mullHeroCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.mullHeroCard()
    }
}

/// Type-erased ViewModifier to switch card styles dynamically.
struct AnyViewModifier: ViewModifier {
    private let modify: (Content) -> AnyView

    init<M: ViewModifier>(_ modifier: M) {
        self.modify = { AnyView($0.modifier(modifier)) }
    }

    func body(content: Content) -> some View {
        modify(content)
    }
}
