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

    // MARK: - Nocturne — ink on night
    //
    // The app is a calm nocturnal surface: mull mulls over your life while you
    // rest. A near-black indigo canvas, content surfacing in soft moonlight, one
    // luminous accent. Type-led, lots of air.

    /// The night canvas — everything sits on this. Deep indigo-black.
    static let canvas = Color(red: 0.039, green: 0.047, blue: 0.078)   // #0A0C14
    /// A surface lifted off the canvas (cards, sidebar wells).
    static let surface = Color(red: 0.071, green: 0.082, blue: 0.122)  // #12151F
    /// A surface on hover / selection.
    static let surfaceHi = Color(red: 0.105, green: 0.118, blue: 0.165) // #1B1E2A
    /// Hairline rule — moonlight at low opacity. The structural signature.
    static let hairline = Color.white.opacity(0.07)

    /// Moonlight indigo — the single accent.
    static let moon = Color(red: 0.58, green: 0.56, blue: 1.0)         // #948FFF
    static let moonDim = Color(red: 0.46, green: 0.45, blue: 0.82)

    /// Text tiers (soft white, never pure).
    static let ink = Color.white.opacity(0.92)
    static let inkDim = Color.white.opacity(0.60)
    static let inkFaint = Color.white.opacity(0.38)

    // MARK: - Semantic Colors (luminous on night)

    static let recording = Color(red: 0.45, green: 0.82, blue: 0.66)  // Moonlit sage
    static let paused = Color(red: 0.93, green: 0.74, blue: 0.45)     // Soft amber
    static let error = Color(red: 0.95, green: 0.48, blue: 0.50)      // Soft red glow
    static let nowLine = Color(red: 0.58, green: 0.56, blue: 1.0)     // Moonlight

    // MARK: - Event Type Colors
    //
    // Used in LiveTab, HomeTab, InsightsTab for event type indicators.
    // Never use raw .blue/.orange/.green — always go through these.

    static let eventKeystroke = Color(red: 0.55, green: 0.66, blue: 1.0)   // Cool moonlight blue
    static let eventClipboard = Color(red: 0.93, green: 0.74, blue: 0.45)  // Same as paused
    static let eventWindow = Color(red: 0.45, green: 0.82, blue: 0.66)     // Same as recording
    static let eventApp = Color(red: 0.70, green: 0.58, blue: 1.0)         // Moon violet
    static let eventAudio = Color(red: 0.95, green: 0.60, blue: 0.78)      // Soft rose

    // MARK: - Insight Colors

    static let langJapanese = Color(red: 0.95, green: 0.48, blue: 0.50)
    static let langEnglish = moon
    static let langCode = Color(red: 0.45, green: 0.82, blue: 0.66)

    // MARK: - Gradients (moonlight)

    static let accentGradient = LinearGradient(
        colors: [
            Color(red: 0.58, green: 0.56, blue: 1.0),   // Moonlight indigo
            Color(red: 0.42, green: 0.40, blue: 0.78)   // Deeper night violet
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Panel

    static let panelWidth: CGFloat = 260

    // MARK: - App Colors (deterministic from name)

    /// Generate a consistent color for any app name.
    /// Well-known apps get curated colors. Everything else gets a hash-based color.
    static func appColor(_ name: String) -> Color {
        // Curated colors for common apps
        switch name {
        case "Xcode": return .blue
        case "Code", "Visual Studio Code": return .purple
        case "Cursor": return .cyan
        case "Safari": return .blue.opacity(0.7)
        case "Firefox": return .orange
        case "Chrome", "Google Chrome": return .green
        case "Arc": return .pink
        case "Slack": return Color(red: 0.6, green: 0.2, blue: 0.6)
        case "Discord": return Color(red: 0.35, green: 0.4, blue: 0.9)
        case "Messages": return .green
        case "Mail": return .blue
        case "Finder": return .blue.opacity(0.5)
        case "Terminal", "iTerm2", "Warp", "Ghostty": return .mint
        case "Simulator": return .indigo
        case "Figma": return Color(red: 0.6, green: 0.3, blue: 1.0)
        case "Notion": return .primary.opacity(0.6)
        case "Obsidian": return Color(red: 0.5, green: 0.3, blue: 0.8)
        case "Notes": return .yellow
        case "Photoshop": return Color(red: 0.0, green: 0.6, blue: 1.0)
        case "Illustrator": return Color(red: 1.0, green: 0.6, blue: 0.0)
        case "Preview": return .blue.opacity(0.4)
        case "Zoom": return Color(red: 0.2, green: 0.5, blue: 1.0)
        case "Teams": return Color(red: 0.3, green: 0.3, blue: 0.8)
        default: break
        }

        // Hash-based color for any unknown app
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
        let saturation = 0.30 + Double((hash >> 8) % 25) / 100.0  // 0.30-0.55 (softer)
        let brightness = 0.60 + Double((hash >> 16) % 20) / 100.0  // 0.60-0.80

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
