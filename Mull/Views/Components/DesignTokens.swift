import SwiftUI
import AppKit

/// Design tokens — single source of truth for all visual constants.
///
/// Typography: 5 levels with clear hierarchy
/// Spacing: 4px grid
/// Radius: 6 tiers
/// Colors: semantic + accent gradients
/// Shadows: 2 tiers for depth
enum DS {

    // MARK: - Typography (8 levels, strict hierarchy)
    //
    //   pageTitle 30pt semibold    — the word a page opens with
    //   hero     28pt bold         — large numbers, empty states
    //   subtitle 14pt              — sheet/panel headers, onboarding steps
    //   title    15pt semibold     — section titles, card headers
    //   body     13pt regular      — primary text
    //   bodyMed  13pt medium       — emphasized body text
    //   small    12pt regular      — button labels, secondary UI
    //   smallMed 12pt medium       — emphasized button labels
    //   caption  11pt regular      — metadata, tertiary text
    //   micro    10pt monospaced   — timestamps, code, data
    //   mini      9pt regular      — tags, evidence, minimal text
    //   miniMed   9pt medium       — mini labels, badges
    //   miniMono  9pt monospaced   — counts and codes inside a mini row
    //
    // There is no tier below 9pt. An 8pt tier existed (`tinyFont`) and it carried
    // real content — sparkline labels, filter chips — at a size that is under the
    // floor of what most people can read. It is gone; its last call sites now use
    // `miniFont`.

    // MARK: Dynamic Type
    //
    // Every token below scales with the system text size. SwiftUI has no
    // `Font.system(size:relativeTo:)` — the *only* factory that produces a
    // scaling font at an exact point size is `Font.custom(_:size:relativeTo:)`,
    // so the tokens are built from the system UI font *by name*. These two names
    // are the documented ones `NSFont.systemFont(ofSize:)` and
    // `NSFont.monospacedSystemFont(ofSize:weight:)` report, and they resolve back
    // to the real system faces. Do not "simplify" them to `.SFNS-Regular` or a
    // bare `.AppleSystemUIFontMonospaced`: both silently fall back to Times New
    // Roman / Helvetica.
    //
    // `relativeTo:` picks the text style each token *rides on*, chosen so the ratio
    // to that style's own size is ~1. That is what makes the scaling proportional
    // rather than lurching.

    private static let systemFontName = ".AppleSystemUIFont"
    private static let monoFontName = ".AppleSystemUIFontMonospaced-Regular"
    private static let monoBoldFontName = ".AppleSystemUIFontMonospaced-Bold"

    private static func scaled(
        _ size: CGFloat,
        _ style: Font.TextStyle,
        _ weight: Font.Weight = .regular
    ) -> Font {
        Font.custom(systemFontName, size: size, relativeTo: style).weight(weight)
    }

    private static func scaledMono(
        _ size: CGFloat,
        _ style: Font.TextStyle,
        bold: Bool = false
    ) -> Font {
        Font.custom(bold ? monoBoldFontName : monoFontName, size: size, relativeTo: style)
    }

    /// The one size above `heroFont` — the printed title a page opens with
    /// ("Today"). Lighter in weight than the hero number, because it is a word and
    /// not a measurement. Named rather than inlined so the two screens that open
    /// this way cannot drift a point apart from each other.
    static let pageTitleFont = scaled(30, .largeTitle, .semibold)
    static let heroFont = scaled(28, .largeTitle, .bold)
    /// Onboarding / first-run display tier. These are the only screens that open
    /// with a spoken sentence rather than a measurement, so they sit above the
    /// dashboard scale. Named because they were five different literals across one
    /// file, none of which scaled.
    static let displayFont = scaled(20, .title2, .semibold)
    static let headlineFont = scaled(18, .title2, .semibold)

    static let titleFont = scaled(15, .title3, .semibold)
    static let titleMedium = scaled(15, .title3, .medium)
    static let titleRegular = scaled(15, .title3)
    static let subtitleFont = scaled(14, .title3)
    static let subtitleMedium = scaled(14, .title3, .medium)
    static let subtitleSemibold = scaled(14, .title3, .semibold)
    static let bodyFont = scaled(13, .body)
    static let bodyMedium = scaled(13, .body, .medium)
    static let smallFont = scaled(12, .callout)
    static let smallMedium = scaled(12, .callout, .medium)
    static let captionFont = scaled(11, .subheadline)
    static let captionMedium = scaled(11, .subheadline, .medium)
    static let microFont = scaledMono(10, .footnote)
    /// `microFont`'s emphasis tier — same size *and* same design, so a highlighted
    /// cell (today's column in the week strip) keeps the exact metrics of the cells
    /// beside it. A bold non-monospaced 10pt here was the reason one column sat a
    /// point off from its neighbours.
    static let microBold = scaledMono(10, .footnote, bold: true)
    static let miniFont = scaled(9, .caption2)
    static let miniMedium = scaled(9, .caption2, .medium)
    static let miniBold = scaled(9, .caption2, .bold)
    /// 9pt monospaced — the mini tier's figures. Digits in a chip or an evidence
    /// row have to column up with each other; `miniFont` does not tabulate.
    static let miniMono = scaledMono(9, .caption2)
    /// A keycap or a literal command, set at body size in the mono face.
    static let codeFont = scaledMono(13, .body, bold: true)

    // MARK: Icon tiers
    //
    // An SF Symbol takes its size and weight from the font it is drawn with, and
    // every bare `Image(systemName:)` used to pick that size inline — the same
    // kind of inline glyph was 8pt in one file and 10pt in the next, and none of
    // them scaled with the text beside them. Five tiers, built by the same scaling
    // factory as the text tokens, so an icon keeps its ratio to its neighbouring
    // text at any system text size. Weight stays at the call site:
    // `DS.iconMini.weight(.semibold)`.
    static let iconMini = scaled(9, .caption2)      // inline glyph beside mini/caption text
    static let iconSmall = scaled(12, .callout)     // small control glyphs, header marks
    static let iconBody = scaled(16, .body)         // row status marks, toolbar buttons
    static let iconAction = scaled(26, .title)      // the primary action (send / stop)
    static let iconHero = scaled(32, .largeTitle)   // empty-state and welcome emblems

    static let labelFont = scaled(11, .subheadline, .medium)
    static let labelTracking: CGFloat = 0.5

    // MARK: - Reading surface (editor + rendered markdown)
    //
    // Borrowed from Crane MD §4: a reading/writing surface breathes more than the
    // dense dashboard. Generous measure, ~1.5 line-height, 1行目 = title. These are
    // the ONLY large type sizes — they belong to the editor, not the chrome.
    static let readTitleFont = scaled(22, .title, .bold)                 // 1行目 / # heading
    static let readH2Font = scaled(17, .title2, .semibold)               // ##
    static let readH3Font = scaled(15, .title3, .semibold)               // ###
    static let readFont = scaled(15, .title3)                            // body — read & write
    static let readLineSpacing: CGFloat = 7                              // ≈1.46 line-height at 15pt
    static let readMeasure: CGFloat = 680                                // max line length (40–75 chars)
    static let readMargin: CGFloat = 24                                  // = xl; wider than dashboard

    // MARK: - Spacing (4px grid)

    /// The single sub-grid step. A label stacked directly on its value reads as one
    /// object, and 4px is already too much air for that — but "too much air" was
    /// being solved ad hoc with 1, 2 and 3 in different files, so the same two-line
    /// cell came out a point or two taller on Home than in the menu bar. One value,
    /// used everywhere that pairing occurs, and nothing between it and `xs`.
    static let hair: CGFloat = 2

    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32

    // MARK: - Radius (softer, more organic)

    static let radiusXs: CGFloat = 2      // hairline bars, progress rules
    static let radiusChip: CGFloat = 3    // pills, chips, skeleton bars
    static let radiusInset: CGFloat = 6   // small inset panels
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

    /// Tobacco — the single accent. A thread, never a fill.
    ///
    /// The name is a fossil: this token was moonlight when the app was the dark
    /// "Nocturne" palette. It is kept only so every call site did not have to
    /// change when the app moved to daylight. Read `moon` as "the accent" —
    /// warm lamplight on paper, never a cool night blue.
    static let moon = Color(red: 0.580, green: 0.447, blue: 0.196)     // #945F32
    static let moonDim = Color(red: 0.46, green: 0.36, blue: 0.18)

    /// Text tiers (warm espresso, never pure black).
    ///
    /// The opacities are contrast budgets, not taste. Composited over `canvas`
    /// (#F2EDE1) and measured against WCAG 2.1 AA (4.5:1 for text this size):
    ///
    ///     ink       1.00  #393127  10.94:1  ✅
    ///     inkDim    0.78  #625A4F   5.79:1  ✅
    ///     inkFaint  0.70  #71695E   4.61:1  ✅
    ///     inkGhost  0.22  #C9C4B8   1.49:1  ❌ — non-text only, by contract
    ///
    /// `inkDim` was 0.62 (3.72:1) and `inkFaint` was 0.36 (1.99:1). Neither was an
    /// accent: `inkFaint` is what `sectionLabel()` paints every section header in
    /// the app with, and 1.99:1 is roughly the contrast of a watermark. The two
    /// text tiers are necessarily closer together now — you cannot fit three
    /// legible lightnesses of one hue on ivory — so the hierarchy under `ink`
    /// leans on weight, case and tracking (as `sectionLabel()` already did) rather
    /// than on fading toward the page.
    ///
    /// The palette is daylight-only (`mullChrome()` pins `.preferredColorScheme(.light)`),
    /// so these are single fixed values with no dark-mode counterpart to check.
    static let ink = Color(red: 0.224, green: 0.192, blue: 0.149)            // #393127
    static let inkDim = Color(red: 0.224, green: 0.192, blue: 0.149).opacity(0.78)
    static let inkFaint = Color(red: 0.224, green: 0.192, blue: 0.149).opacity(0.70)
    /// The fourth tier — the warm answer to `.quaternary`. Axis ticks, disabled
    /// glyphs, decoration that must be present without being read. **Never text**:
    /// at 1.49:1 it is below every readability threshold there is, which is the
    /// point — it is a rule or a tick, and it is exempt from AA because it carries
    /// no information a reader has to recover.
    static let inkGhost = Color(red: 0.224, green: 0.192, blue: 0.149).opacity(0.22)

    // MARK: - Earth palette (one harmonious family — warm, muted, low-sat)
    //
    // Cucinelli is not a rainbow. Every accent is a natural dye drawn from the
    // same earth as the tobacco anchor: ochre, olive, clay, plum, taupe.
    // Nothing competes with the ink or the page; the whole screen reads tonal.

    static let camel     = Color(red: 0.72, green: 0.54, blue: 0.24)  // #B88A3D — lighter tobacco
    static let olive     = Color(red: 0.43, green: 0.46, blue: 0.29)  // #6E7549 — greyed green
    static let clay      = Color(red: 0.66, green: 0.36, blue: 0.26)  // #A85C42 — terracotta
    /// The one cool note, muted — held in reserve. Deliberately NOT wired to
    /// anything high-frequency: a single cool colour on ivory reads as a defect
    /// once it is repeated, so it marks one rare thing (the me.md leaf) and no more.
    static let slate     = Color(red: 0.42, green: 0.49, blue: 0.53)  // #6B7D87
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
    // Used in LiveTab, HomeTab, ProfileTab for event type indicators.
    // Never use raw .blue/.orange/.green — always go through these.

    // Keystrokes are by far the most-rendered event in a keystroke logger, so this
    // one gets the quietest warm neutral — present everywhere, loud nowhere.
    static let eventKeystroke = taupe
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
    /// Curated by *role*, so the colour carries meaning rather than being an
    /// arbitrary tag — and so no single dye ends up owning half the screen.
    static func appColor(_ name: String) -> Color {
        switch name {
        // Editors & IDEs — where the work gets made.
        case "Xcode", "Cursor", "Code", "Visual Studio Code", "Simulator": return plum
        // Browsers.
        case "Safari", "Arc", "Chrome", "Google Chrome", "Firefox": return camel
        // Terminals.
        case "Terminal", "iTerm2", "Warp", "Ghostty": return olive
        // Communication.
        case "Mail", "Slack", "Messages", "Teams", "Discord", "Zoom": return clay
        // Design tools.
        case "Figma", "Photoshop", "Illustrator": return dustyRose
        // Files, notes & reading.
        case "Finder", "Notion", "Obsidian", "Notes", "Preview": return taupe
        default: break
        }

        // Muted earth dye for any unknown app
        return colorFromHash(name)
    }

    // MARK: - The warm band (shared clamp for every generated colour)
    //
    // Any colour mull did not choose by hand — an unknown app's hash dye, a
    // calendar's tint imported from macOS — is folded into this arc before it is
    // ever drawn. Two arcs, 120° of wheel in total:
    //
    //   20°–120°   amber → ochre → olive
    //   340°–360°  clay → rose
    //
    // Everything between (the blues, cyans, indigos, greens) is unreachable by
    // construction, which is what makes "nothing breaks the tonal family" true
    // rather than aspirational.

    private static let warmArcPrimary = (start: 20.0, span: 100.0)   // amber → olive
    private static let warmArcClay    = (start: 340.0, span: 20.0)   // clay → rose
    private static let warmSpan = warmArcPrimary.span + warmArcClay.span   // 120°

    /// Muted-dye saturation range — a natural dye, not a crayon.
    private static let warmSaturation: ClosedRange<Double> = 0.16...0.34
    /// Brightness range that stays readable on the ivory page.
    private static let warmBrightness: ClosedRange<Double> = 0.44...0.60

    /// Fold a position on the full colour wheel (0..<1) into the warm band.
    /// Monotonic within each arc, so distinct inputs stay distinct outputs.
    static func warmHue(_ position: Double) -> Double {
        let wrapped = position - position.rounded(.down)          // → 0..<1
        let p = wrapped * warmSpan
        let degrees = p < warmArcPrimary.span
            ? warmArcPrimary.start + p
            : warmArcClay.start + (p - warmArcPrimary.span)
        return degrees.truncatingRemainder(dividingBy: 360) / 360
    }

    /// Bring an arbitrary colour into mull's family: its hue is folded into the
    /// warm band and its saturation/brightness are capped to the muted-dye range.
    /// Distinct source colours stay distinguishable; none of them stay cold.
    static func warmed(_ cgColor: CGColor) -> Color {
        guard let rgb = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else {
            return taupe
        }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)

        // A greyscale source has no hue to preserve — give it the neutral dye.
        guard s > 0.02 else { return taupe }

        return Color(
            hue: warmHue(Double(h)),
            saturation: min(max(Double(s), warmSaturation.lowerBound), warmSaturation.upperBound),
            brightness: min(max(Double(b), warmBrightness.lowerBound), warmBrightness.upperBound)
        )
    }

    /// Deterministic color from string hash. Same app name → always same color.
    /// The hue is drawn from the warm band only, so an unknown app can never
    /// land on a cold blue/indigo/cyan the curated palette would never use.
    private static func colorFromHash(_ string: String) -> Color {
        var hash: UInt64 = 5381
        for char in string.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)
        }

        let hue = warmHue(Double(hash % 360) / 360.0)
        let saturation = 0.16 + Double((hash >> 8) % 18) / 100.0  // 0.16-0.34 (muted — a natural dye, not a crayon)
        let brightness = 0.44 + Double((hash >> 16) % 16) / 100.0  // 0.44-0.60 (readable on ivory)

        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

// MARK: - View Extensions

extension View {
    /// Every window root wears this and nothing else does.
    ///
    /// `.tint` used to be applied per-view (nine call sites, five of them inside
    /// OnboardingView alone), which meant any screen whose author forgot it drew
    /// its native controls — toggles, pickers, progress bars, text selection — in
    /// whatever accent the user picked in System Settings. On an ivory page a
    /// stray system blue is the loudest thing on screen. Applying it once at the
    /// root of each scene makes "the accent is tobacco" true by construction:
    /// there is no screen left that can forget.
    ///
    /// `.preferredColorScheme(.light)` rides along for the same reason — the
    /// palette is daylight-only, and it was previously repeated at every root.
    func mullChrome() -> some View {
        self
            .tint(DS.moon)
            .preferredColorScheme(.light)
    }

    /// A faint tobacco wash behind a hero element — warm lamplight falling across
    /// the page from the top-left, not a glow in the dark.
    func moonGlow(_ intensity: Double = 0.16) -> some View {
        self.background(
            RadialGradient(
                colors: [DS.moon.opacity(intensity), .clear],
                center: .topLeading, startRadius: 0, endRadius: 320
            )
            .allowsHitTesting(false)
        )
    }

    /// Standard card — a surface lifted a shade off the ivory page, edged with a
    /// hairline like a faint pencil rule.
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

    /// Hero card — the same lifted surface, warmed by a breath of tobacco.
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

    /// Section label style — letterspaced, faint, quiet.
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
                        DS.ink.opacity(0.04),
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
