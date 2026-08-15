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

    // MARK: Which glyph — the symbol台帳
    //
    // The size tiers above fixed *how big* an icon is drawn and left *which icon*
    // to the call site, so the same meaning acquired several glyphs: two spellings
    // of "there is a problem" (`exclamationmark.triangle` and `exclamationmark.circle`
    // alongside the filled triangle), `lock` and `lock.fill` for the same padlock,
    // `folder` and `folder.fill` in one sidebar, and three different moons standing
    // in for mull itself. A reader has to learn each spelling separately before
    // discovering they meant one thing.
    //
    // **One meaning, one symbol.** Reach for a bare `Image(systemName:)` only for a
    // glyph that appears once in the whole app; anything a second screen could
    // plausibly want belongs here, where the second screen will find it.
    //
    // **Fill is a state, not a decoration.** Filled = a condition the reader has to
    // notice right now (it failed / it succeeded / it was refused). Outline = a
    // label or an affordance — a thing to read or press. That rule is why `locked`
    // and `folder` are outline: neither is an alarm, they are nouns.
    enum Glyph {
        // States worth interrupting for — filled, by the rule above.
        static let problem = "exclamationmark.triangle.fill"
        static let success = "checkmark.circle.fill"
        static let denied = "xmark.circle.fill"
        /// The empty half of a checklist pair whose filled half is `success`.
        static let pending = "circle"

        // Nouns and affordances — outline.
        static let locked = "lock"
        static let folder = "folder"
        static let file = "doc.text"
        static let settings = "gearshape"
        static let search = "magnifyingglass"
        static let clearField = "xmark.circle.fill"   // a filled glyph by SF convention
        static let copy = "doc.on.clipboard"
        static let trash = "trash"

        static let add = "plus"
        static let edit = "pencil"
        /// A bare tick on a button that accepts something. Not `success` — that one
        /// reports a state that has already landed.
        static let confirm = "checkmark"
        /// An excerpt quoted back from the record.
        static let quote = "text.quote"
        /// A clock face is a point in time; an hourglass is a length of one. Two
        /// meanings, two glyphs, and neither borrows the other's.
        static let timeOfDay = "clock"
        static let duration = "hourglass"

        /// Reload from disk. Distinct from `repeats` on purpose: that one means a
        /// calendar series, and the two were never the same idea.
        static let refresh = "arrow.clockwise"
        static let repeats = "arrow.triangle.2.circlepath"

        // mull's own face.
        /// The brand mark — used wherever mull identifies itself as the speaker.
        static let brand = "moon.stars"
        /// Actively working (menu bar only, where the icon is the whole status).
        static let brandWorking = "moon.stars.fill"
        /// Capture is paused. A state of mull, not the brand.
        static let asleep = "moon.zzz"

        // Primary surfaces. `chat` is one bubble rather than the two-bubble
        // compound it used to be: a `Label` list sizes its icon column to the
        // widest glyph in it, so a 2-unit-wide symbol beside `house`, `calendar`
        // and `waveform` indented all four titles to make room for one of them.
        static let home = "house"
        static let calendar = "calendar"
        static let live = "waveform"
        static let chat = "bubble.left"

        /// Show/hide the sidebar. mull draws this itself — see
        /// `AppDelegate.installSidebarToggle`.
        static let sidebar = "sidebar.leading"
    }

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

    // MARK: - Two pages, one palette — daylight and lamplight (Cucinelli)
    //
    // The app lives on a warm page: Umbrian daylight by day, the same room by
    // lamp at night. Espresso ink on ivory, or ivory ink on espresso — one
    // tobacco accent either way, hairlines like a faint pencil rule. Type-led,
    // lots of air. (The dark side is NOT the old cool "Nocturne": DESIGN.md rules
    // out cold colour outright, so lamplight is the *warm* inversion — the page
    // goes to espresso, and the ivory that was the page becomes the ink.)
    //
    // **Every token below keeps its name.** Dark mode is a change to what the
    // tokens resolve to, not to what the app asks for, so no call site moved.

    // MARK: The adaptive primitive
    //
    // The tokens are `static let`s that views read directly, so they cannot be
    // computed from `@Environment(\.colorScheme)` without touching all 27 files
    // that draw with them. A dynamic `NSColor` resolves per-appearance at draw
    // time instead, which keeps every token a plain stored constant — and works
    // in AppKit too, which matters because `AppDelegate` paints three windows'
    // `backgroundColor` from `canvasNS`.
    //
    // `NSColor(someDynamicColor)` does survive the round trip with its provider
    // intact — that was assumed to freeze, and the test written to pin the
    // freeze failed (`testNSColorRoundTripStaysDynamic`). The `…NS` tokens exist
    // anyway, because an AppKit call site asking for an AppKit colour should not
    // have to go out through SwiftUI and back to get one.

    private static func adaptiveNS(
        light: (r: Double, g: Double, b: Double, a: Double),
        dark: (r: Double, g: Double, b: Double, a: Double)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        }
    }

    /// Internal rather than private so the dossier's `paperBgRaised` — the one
    /// token declared outside this file — can be built the same way. It is for
    /// *declaring tokens*, not for mixing colours at a call site: a view that
    /// needs a colour should ask for a token, not invent one.
    static func adaptive(
        light: (r: Double, g: Double, b: Double, a: Double),
        dark: (r: Double, g: Double, b: Double, a: Double)
    ) -> Color {
        Color(nsColor: adaptiveNS(light: light, dark: dark))
    }

    /// The ink itself, before any tier picks an opacity off it. Private so there
    /// is exactly one pair of literals for it in the app: the text tiers, the
    /// hairline and the dossier's `umberDim` are all opacities of *this*, and
    /// when they were written out longhand the dossier's copy had already
    /// drifted into claiming a daylight-only ratio.
    private static let inkLight = (r: 0.224, g: 0.192, b: 0.149)   // #393127 espresso
    private static let inkDark  = (r: 0.810, g: 0.793, b: 0.753)   // #CFCAC0 warm ivory

    /// A tier of the ink. The two alphas are independent because the same alpha
    /// does not buy the same contrast against opposite pages — see the ladder on
    /// `ink`, where every lamplight alpha was solved backwards from its daylight
    /// ratio rather than copied across.
    static func inkTier(light: Double, dark: Double) -> Color {
        adaptive(light: (inkLight.r, inkLight.g, inkLight.b, light),
                 dark:  (inkDark.r, inkDark.g, inkDark.b, dark))
    }

    /// The page — everything sits on this. Warm ivory by day, espresso by lamp.
    static let canvasNS = adaptiveNS(
        light: (0.949, 0.929, 0.882, 1),   // #F2EDE1
        dark:  (0.106, 0.090, 0.071, 1)    // #1B1712
    )
    static let canvas = Color(nsColor: canvasNS)
    /// A surface lifted off the page (cards, sidebar wells) — barely lifted.
    /// Lighter than the page in daylight, lighter than it in lamplight too: a
    /// card is *raised*, and raised reads as nearer the light in both rooms.
    static let surface = adaptive(
        light: (0.969, 0.953, 0.918, 1),   // #F7F3EA
        dark:  (0.145, 0.125, 0.098, 1)    // #252019
    )
    /// A cast shadow.
    ///
    /// **Never write a shadow as `ink.opacity()`.** That is what the notice bar
    /// did, and it was correct for exactly as long as the ink was espresso: the
    /// moment the ink inverted to ivory, the drop shadow under a floating panel
    /// became an ivory halo around it.
    ///
    /// A shadow is the absence of light, so both values are the same near-black
    /// — this is the one token that does *not* mirror. The lamplight value is
    /// carried much further because a soft dark shadow on a dark page has almost
    /// no room to be seen: 0.12 over espresso is invisible, 0.50 reads.
    static let shadow = adaptive(
        light: (0.224, 0.192, 0.149, 0.12),
        dark:  (0.031, 0.024, 0.016, 0.50)
    )

    /// A surface on hover / selection.
    static let surfaceHi = adaptive(
        light: (0.988, 0.976, 0.949, 1),   // #FCF9F2
        dark:  (0.192, 0.169, 0.133, 1)    // #312B22
    )
    /// Hairline rule — the ink at low opacity. The structural signature.
    /// Both sides land at 1.23:1 against their own page, so the rule is exactly
    /// as present in one room as the other.
    static let hairline = inkTier(light: 0.12, dark: 0.10)

    /// Tobacco — the single accent. A thread, never a fill.
    ///
    /// The name is a fossil: this token was moonlight when the app was the dark
    /// "Nocturne" palette. It is kept only so every call site did not have to
    /// change when the app moved to daylight. Read `moon` as "the accent" —
    /// warm lamplight on paper, never a cool night blue.
    ///
    /// The lamplight value is the same tobacco lifted to L\*55 (4.74:1 rather
    /// than the 4.00:1 the daylight value scores on espresso). It is lifted
    /// because this is the token `mullChrome()` hands to `.tint`, so it has to
    /// carry native controls, and because `nowLine` is it.
    static let moon = adaptive(
        light: (0.580, 0.447, 0.196, 1),   // #947232
        dark:  (0.626, 0.497, 0.253, 1)    // #A07F41
    )
    /// The accent's quieter partner (list bullets in `MarkdownView`). "Dim" means
    /// *nearer the page* — so it is deeper than `moon` on ivory and darker than
    /// `moon` on espresso. Non-text by use; 3.20:1 in lamplight.
    static let moonDim = adaptive(
        light: (0.46, 0.36, 0.18, 1),      // #755C2E
        dark:  (0.490, 0.394, 0.221, 1)    // #7D6438
    )

    /// Text tiers (warm espresso on ivory, warm ivory on espresso — never pure
    /// black, never pure white).
    ///
    /// The opacities are contrast budgets, not taste. Composited over `canvas`
    /// and measured against WCAG 2.1 AA (4.5:1 for text this size):
    ///
    ///                 daylight                    lamplight
    ///     ink       1.00  #393127  10.94:1 ✅   1.00  #CFCAC0  10.94:1 ✅
    ///     inkDim    0.78  #625A4F   5.79:1 ✅   0.69  #97928A   5.79:1 ✅
    ///     inkFaint  0.70  #71695E   4.61:1 ✅   0.59  #858179   4.61:1 ✅
    ///     inkGhost  0.22  #C9C4B8   1.49:1 ❌   0.17  #3A3630   1.49:1 ❌
    ///
    /// **The two columns are the same ladder.** The lamplight alphas were solved
    /// backwards from the daylight ratios rather than picked, so the hierarchy a
    /// reader learns in one appearance is the hierarchy they get in the other.
    /// That is also why `ink` is #CFCAC0 and not the full ivory of the page:
    /// ivory-on-espresso measures 15.25:1, which is more contrast than the app
    /// has ever asked for and reads as halation at body size.
    ///
    /// `inkDim` was 0.62 (3.72:1) and `inkFaint` was 0.36 (1.99:1). Neither was an
    /// accent: `inkFaint` is what `sectionLabel()` paints every section header in
    /// the app with, and 1.99:1 is roughly the contrast of a watermark. The two
    /// text tiers are necessarily closer together now — you cannot fit three
    /// legible lightnesses of one hue on ivory — so the hierarchy under `ink`
    /// leans on weight, case and tracking (as `sectionLabel()` already did) rather
    /// than on fading toward the page.
    static let ink = inkTier(light: 1.00, dark: 1.00)
    static let inkDim = inkTier(light: 0.78, dark: 0.69)
    static let inkFaint = inkTier(light: 0.70, dark: 0.59)
    /// The fourth tier — the warm answer to `.quaternary`. Axis ticks, disabled
    /// glyphs, decoration that must be present without being read. **Never text**:
    /// at 1.49:1 it is below every readability threshold there is, which is the
    /// point — it is a rule or a tick, and it is exempt from AA because it carries
    /// no information a reader has to recover.
    static let inkGhost = inkTier(light: 0.22, dark: 0.17)

    // MARK: - Earth palette (one harmonious family — warm, muted, low-sat)
    //
    // Cucinelli is not a rainbow. Every accent is a natural dye drawn from the
    // same earth as the tobacco anchor: ochre, olive, clay, plum, taupe.
    // Nothing competes with the ink or the page; the whole screen reads tonal.
    //
    // **These seven do not adapt, and that is measured rather than skipped.**
    // Every one of them is a mid-tone — L\* 43.7 to 60.4, all of it between the
    // two pages — so each dye is darker than ivory *and* lighter than espresso
    // without moving. Against its own page in each appearance:
    //
    //             daylight   lamplight
    //     camel      2.68        5.70
    //     olive      4.16        3.66
    //     clay       4.20        3.63
    //     slate      3.66        4.17
    //     plum       4.82        3.17
    //     dustyRose  3.29        4.64
    //     taupe      3.23        4.72
    //
    // The floor across both rooms is 2.68:1 (camel in daylight) — which is the
    // value this palette already shipped, unchanged. Nothing here is text: these
    // dye an app's tag, an event-type dot, a language bar. `langJapanese` (clay)
    // is the closest to being read as text and it sits at 3.63:1 in lamplight,
    // under AA — it is a 9pt legend beside a bar whose length carries the number,
    // so the colour is a label for the bar and not the datum.
    //
    // Giving them dark counterparts was tried and rejected: matching each dye's
    // *contrast* across the flip makes it darker than its daylight self on a
    // near-black page (camel #B88A3D → #7A6034), which goes to mud. Contrast
    // parity is the wrong invariant when the background changes polarity.

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
    // Used in LiveTab and HomeTab for event type indicators.
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
    //
    // Both stops adapt. The deep stop is the reason: at #735726 it scores 2.64:1
    // on espresso, so in lamplight the gradient's far end sank into the page and
    // the ramp read as a fade-out rather than a shape.

    static let accentGradient = LinearGradient(
        colors: [
            adaptive(light: (0.62, 0.49, 0.24, 1),    // #9E7D3D — tobacco
                     dark:  (0.667, 0.545, 0.302, 1)), // #AA8B4D
            adaptive(light: (0.45, 0.34, 0.15, 1),    // #735726 — deeper tobacco
                     dark:  (0.514, 0.408, 0.216, 1))  // #836837
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
    /// Brightness range that stays readable on **either** page.
    ///
    /// Like the hand-picked dyes above, the band is a mid-tone one and does not
    /// flip. Measured at all eight corners of the (hue × saturation × brightness)
    /// box, the worst case is 2.49:1 in daylight and 2.37:1 in lamplight — the
    /// two rooms are within 0.12 of each other, so widening the band for one of
    /// them would cost the other more than it gained. These dye an unknown app's
    /// tag or an imported calendar's tint; none of them is text.
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
    /// Give a glyph-sized control a pointer-sized target.
    ///
    /// A `Button` whose whole label is an `Image(systemName:)` is hit-testable over
    /// the glyph and nothing else, so its target is whatever `.font()` happened to be
    /// set on it. That was 9pt for the notice bar's dismiss and 11pt for the buttons
    /// that reveal an API key, re-draft a report, and delete an MCP source — the last
    /// of which is not asked about first, so a target you can slip off is attached to
    /// an action you cannot take back.
    ///
    /// 30pt because that is the size `FullWindowView.sidebarButton` had already
    /// settled on for the same job; this is that decision, made once, where the rest
    /// of the app can reach it. Nothing about the drawing changes — the glyph keeps
    /// its font and its position — only the area that answers the pointer.
    ///
    /// Pass a smaller `side` where the row's own height is the constraint, and say
    /// which constraint at the call site.
    func iconHitTarget(_ side: CGFloat = 30) -> some View {
        frame(width: side, height: side).contentShape(Rectangle())
    }
}

/// A `DisclosureGroup` label that opens the group when it is clicked.
///
/// On macOS a `DisclosureGroup`'s label is not a toggle: only the chevron is, and it
/// is a 10pt glyph. So the obvious target — the folder's name, the words "Advanced —
/// add a source by command" — does nothing at all, and the real one is smaller than
/// the pointer that has to find it. (`OutlineGroup` gives this for free and is not
/// always an option: its selection model does not honour a per-row `.tag`.)
///
/// A `Button` rather than `.onTapGesture`, because the row is a control and should
/// answer to VoiceOver and the keyboard as one thing; a bare tap gesture is invisible
/// to both. `.contentShape` after the frame is what makes the empty space beside a
/// short label clickable rather than just the text.
struct DisclosureLabel<Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button { isExpanded.toggle() } label: {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // No `accessibilityLabel`: the content carries its own text, and replacing it
        // here would silence whatever the caller wrote. Only the state is added.
        .accessibilityHint(isExpanded ? "Collapse" : "Expand")
    }
}

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
    /// It no longer pins `.preferredColorScheme(.light)`. That pin was correct
    /// while the palette had one page; now every colour token resolves per
    /// appearance, so pinning here would be the one line overriding all of them.
    /// **Nothing in the app sets `preferredColorScheme` or `NSAppearance` any
    /// more** — the window follows the system, and the tokens follow the window.
    func mullChrome() -> some View {
        self
            .tint(DS.moon)
    }

    /// A faint tobacco wash behind a hero element — warm lamplight falling across
    /// the page from the top-left. It reads as light on the page rather than as
    /// an emitted glow, which is what keeps it out of Nocturne territory now that
    /// there *is* a dark page for it to fall on: the wash is the same tobacco in
    /// both rooms, and `DS.moon` carries it.
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
