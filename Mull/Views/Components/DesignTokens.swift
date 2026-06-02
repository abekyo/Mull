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

    // MARK: - Semantic Colors (warm, not clinical)

    static let recording = Color(red: 0.35, green: 0.72, blue: 0.55) // Sage green, not neon
    static let paused = Color(red: 0.88, green: 0.65, blue: 0.35)    // Warm amber
    static let error = Color(red: 0.85, green: 0.35, blue: 0.35)     // Soft red
    static let nowLine = Color(red: 0.85, green: 0.35, blue: 0.35)   // Calendar now indicator

    // MARK: - Event Type Colors
    //
    // Used in LiveTab, HomeTab, InsightsTab for event type indicators.
    // Never use raw .blue/.orange/.green — always go through these.

    static let eventKeystroke = Color.blue
    static let eventClipboard = Color(red: 0.88, green: 0.65, blue: 0.35)  // Same as paused
    static let eventWindow = Color(red: 0.35, green: 0.72, blue: 0.55)     // Same as recording
    static let eventApp = Color.purple
    static let eventAudio = Color.pink

    // MARK: - Insight Colors

    static let langJapanese = Color(red: 0.85, green: 0.35, blue: 0.35)    // Same as error
    static let langEnglish = Color.accentColor
    static let langCode = Color(red: 0.35, green: 0.72, blue: 0.55)        // Same as recording

    // MARK: - Gradients (warm tones)

    static let accentGradient = LinearGradient(
        colors: [
            Color(red: 0.58, green: 0.38, blue: 0.58),  // Warm mauve
            Color(red: 0.50, green: 0.35, blue: 0.65)   // Soft purple
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
    /// Standard card — warm shadow, soft edges.
    func mullCard(isHovered: Bool = false) -> some View {
        self
            .padding(DS.md)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusMd)
                    .fill(.ultraThinMaterial)
                    .shadow(
                        color: Color(red: 0.4, green: 0.3, blue: 0.3).opacity(isHovered ? 0.10 : 0.05),
                        radius: isHovered ? 10 : 5, y: 2
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusMd)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.06 : 0.03), lineWidth: 0.5)
            )
    }

    /// Hero card — the warmest card. Gentle glow.
    func mullHeroCard() -> some View {
        self
            .padding(DS.xl)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: DS.radiusLg)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: DS.radiusLg)
                        .fill(Color.accentColor.opacity(0.03))
                }
                .shadow(
                    color: Color.accentColor.opacity(0.10),
                    radius: 14, y: 4
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusLg)
                    .strokeBorder(Color.accentColor.opacity(0.10), lineWidth: 0.5)
            )
    }

    /// Section label style.
    func sectionLabel() -> some View {
        self
            .font(DS.labelFont)
            .tracking(DS.labelTracking)
            .foregroundStyle(.secondary)
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
