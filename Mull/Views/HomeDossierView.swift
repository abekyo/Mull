import SwiftUI

// MARK: - Dossier aliases & serif (Cucinelli, in daylight)
//
// This block used to be a second palette: it re-declared the ivory page, the
// espresso ink, the tobacco accent and the hairline as fresh literals, several of
// them byte-identical to the tokens in DesignTokens.swift. That is two sources of
// truth for the same colour, and the accent in particular would have drifted the
// first time anyone tuned one of them.
//
// The app-wide palette moved to daylight, so the duplicates are now plain aliases
// onto the canonical DS tokens, and the shades that are just an opacity of a
// canonical colour are expressed that way. Only the genuinely new things — the
// raised paper, the luxurious rhythm, the serif — are declared here.
extension DS {

    // Warm ivory page — the cream of fine paper / undyed cashmere.
    static let paperBg = canvas                                              // = DS.canvas
    /// The one shade with no DS equivalent: a *darker* paper, where `surface` is lighter.
    static let paperBgRaised = Color(red: 0.925, green: 0.902, blue: 0.847)  // #ECE6D8

    // Espresso ink — warm, never harsh black.
    static let umberInk   = ink                                              // = DS.ink
    // Held one notch under the canonical text tiers, but no longer under the
    // contrast floor: these were 0.60 (3.53:1) and 0.34 (1.92:1) on the ivory page,
    // which is a watermark, not body copy. See the budget on `DS.inkDim`.
    static let umberDim   = ink.opacity(0.76)   // 5.47:1 on canvas — a hair under DS.inkDim (0.78)
    static let umberFaint = ink.opacity(0.70)   // 4.61:1 on canvas — = DS.inkFaint

    // Tobacco / camel — the single accent. A thread, never a fill.
    static let tobacco    = moon                                             // = DS.moon
    static let tobaccoDim = moon.opacity(0.66)

    // Warm taupe hairline — barely there.
    static let paperRule  = hairline                                         // = DS.hairline

    // Luxurious rhythm — far past the 4px dashboard grid. Space is the material.
    static let airColumn: CGFloat  = 600   // narrow, confident column
    static let airLede: CGFloat    = 500   // the lede sits narrower still
    static let airSection: CGFloat = 68    // silence between movements
    static let airTop: CGFloat     = 92    // the title page floats down
    static let airBottom: CGFloat  = 120

    // Literary serif — the whole human surface speaks in it here.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - HomeDossierView
//
// ⚠️ DESIGN STUDY — NOT SHIPPED. This view is not routed into the app: nothing
// constructs `HomeDossierView` outside its own `#Preview`, and the live Home
// surface is `HomeTab`. It renders entirely from the hard-coded `Dossier.sample`
// below, so every name, project and duration you see here is invented — none of
// it comes from the database, and editing this file changes nothing a user sees.
// It exists to hold the visual argument while the real Home catches up.
//
// To ship it, someone has to (a) write `Dossier.live(from:)` against
// ProjectSnapshot + me.md and (b) route Home to it. Until both are done, treat
// this as a drawing, not as UI.
//
// Home as a DIGNIFIED DOSSIER — a private monograph about you, kept by a
// custodian. A lit ivory page with vast margins, an espresso serif, and one
// tobacco thread. Luxury here is restraint and air: most of the page is left
// empty on purpose. No cards, no chrome, no emoji — ink on paper.
struct HomeDossierView: View {
    let dossier: Dossier

    /// What "Amend" does. Optional, and the control is drawn only when it is
    /// supplied — a deliberate constraint rather than a convenience.
    ///
    /// The footer places amendment as the reader's one act of sovereignty over a
    /// record kept about them, and it used to be `Button { }` — an empty closure.
    /// A dead button is worse here than no button: it says the record is yours to
    /// correct and then refuses. Because this view is a design study that nothing
    /// routes yet, that would have shipped the instant someone wired it up. Making
    /// the affordance conditional on real behaviour means it cannot.
    var onAmend: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.airSection) {
                masthead
                lede
                chapter
                particulars
                custodeFooter
            }
            .frame(maxWidth: DS.airColumn, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 56)
            .padding(.top, DS.airTop)
            .padding(.bottom, DS.airBottom)
        }
        .background(DS.paperBg.ignoresSafeArea())
    }

    // MARK: Masthead — the frontispiece

    private var masthead: some View {
        VStack(alignment: .leading, spacing: DS.xl) {
            HStack(alignment: .firstTextBaseline) {
                Text("DOSSIER")
                    .font(DS.miniMedium).tracking(3.4)
                    .foregroundStyle(DS.tobacco)
                Spacer()
                Text("IN CUSTODY SINCE \(dossier.keptSince)".uppercased())
                    .font(DS.miniFont).tracking(2.0)
                    .foregroundStyle(DS.umberFaint)
            }

            // The person — named the way a frontispiece names its subject.
            Text(dossier.name)
                .font(DS.serif(40, .regular))
                .foregroundStyle(DS.umberInk)
                .tracking(0.2)
                .padding(.top, DS.lg)

            // Standing — one quiet sentence, not tags.
            Text(dossier.standing)
                .font(DS.serif(17))
                .italic()
                .foregroundStyle(DS.umberDim)
        }
    }

    // MARK: Lede — the custode's measured account, set narrow with air

    private var lede: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            Text(dossier.dateline.uppercased())
                .font(DS.miniMedium).tracking(2.4)
                .foregroundStyle(DS.umberFaint)
            Text(dossier.lede)
                .font(DS.serif(21))
                .foregroundStyle(DS.umberInk)
                .lineSpacing(11)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: DS.airLede, alignment: .leading)
        }
    }

    // MARK: Chapter — today's work as a quiet table of contents

    private var chapter: some View {
        VStack(alignment: .leading, spacing: DS.xl) {
            sectionRule("The Present Chapter")

            // A day with nothing in it is a real state, not a bug, and this page is
            // the one surface that can say so without apologising: a custodian with
            // an empty page says the page is empty. Rendering an unlabelled void
            // instead — which is what an unguarded ForEach over no chapters does —
            // reads as a failure to load.
            if dossier.chapters.isEmpty {
                Text("Nothing has been entered for today yet.")
                    .font(DS.serif(17))
                    .italic()
                    .foregroundStyle(DS.umberDim)
            } else {
                VStack(spacing: DS.lg) {
                    ForEach(dossier.chapters) { c in
                        leaderRow(title: c.title, detail: c.detail, trailing: c.duration,
                                  emphasis: c == dossier.chapters.first)
                    }
                }
            }

            if let resume = dossier.resume {
                HStack(spacing: DS.md) {
                    Text("TO RESUME").font(DS.miniMedium).tracking(2.4)
                        .foregroundStyle(DS.tobacco)
                    Text(resume).font(DS.serif(15)).italic()
                        .foregroundStyle(DS.umberDim).lineLimit(1)
                }
                .padding(.top, DS.sm)
            }
        }
    }

    // A book's TOC row: title … faint leader … value. Generous vertical air.
    private func leaderRow(title: String, detail: String, trailing: String, emphasis: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.md) {
            VStack(alignment: .leading, spacing: DS.xs) {
                Text(title)
                    .font(DS.serif(emphasis ? 20 : 17, emphasis ? .medium : .regular))
                    .foregroundStyle(emphasis ? DS.umberInk : DS.umberDim)
                if !detail.isEmpty {
                    Text(detail).font(DS.captionFont)
                        .foregroundStyle(DS.umberFaint)
                }
            }
            LeaderLine()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [1, 5]))
                .foregroundStyle(DS.paperRule)
                .frame(height: 1)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 5 }
            Text(trailing)
                .font(DS.serif(13))
                .foregroundStyle(emphasis ? DS.tobacco : DS.umberDim)
                .monospacedDigit()
        }
    }

    // MARK: Particulars — standing facts, set like the leaf of a fine ledger

    private var particulars: some View {
        VStack(alignment: .leading, spacing: DS.xl) {
            sectionRule("Particulars")
            VStack(alignment: .leading, spacing: DS.lg) {
                ForEach(Array(dossier.particulars.enumerated()), id: \.offset) { _, p in
                    HStack(alignment: .firstTextBaseline) {
                        Text(p.key.uppercased())
                            .font(DS.miniMedium).tracking(1.8)
                            .foregroundStyle(DS.umberFaint)
                            .frame(width: 150, alignment: .leading)
                        Text(p.value)
                            .font(DS.serif(16))
                            .foregroundStyle(DS.umberInk)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: Footer — sovereignty (yours to amend) & dignity (held here)

    private var custodeFooter: some View {
        VStack(alignment: .leading, spacing: DS.lg) {
            Rectangle().fill(DS.paperRule).frame(height: 1)
            HStack(alignment: .firstTextBaseline) {
                Text("Held on this Mac. Never sent. Yours alone.")
                    .font(DS.serif(14)).italic()
                    .foregroundStyle(DS.umberDim)
                Spacer()
                if let onAmend {
                    Button(action: onAmend) {
                        HStack(spacing: DS.xs) {
                            Image(systemName: DS.Glyph.edit).font(DS.captionFont)
                            Text("Amend").font(DS.smallMedium)
                        }
                        .foregroundStyle(DS.tobacco)
                    }
                    .buttonStyle(.plain)
                    .help("Edit this record")
                }
            }
            .padding(.top, DS.xs)
            // One line, not two. The second one here said the same thing the first
            // one says ("kept on this Mac, never sent"), a caption below an italic
            // line already carrying it.
        }
        .padding(.top, DS.lg)
    }

    // A quiet section rule: a small-caps serif title over a faint hairline.
    private func sectionRule(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: DS.md) {
            HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                StippleMark(color: DS.tobaccoDim, dot: 2.5)
                Text(title.uppercased())
                    .font(DS.miniMedium).tracking(3.0)
                    .foregroundStyle(DS.tobaccoDim)
            }
            Rectangle().fill(DS.paperRule).frame(height: 1)
        }
    }
}

// A baseline-sittable dotted leader line for table-of-contents rows.
private struct LeaderLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// MARK: - Dossier sample model
//
// Presentation model for the Home dossier. `sample` powers the preview;
// `live(from:)` is the seam to map ProjectSnapshot + me.md into this shape.
struct Dossier {
    struct Chapter: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let detail: String
        let duration: String
    }
    struct Particular { let key: String; let value: String }

    let name: String
    let standing: String
    let keptSince: String
    let dateline: String
    let lede: String
    let chapters: [Chapter]
    let resume: String?
    let particulars: [Particular]

    /// An invented person, deliberately. This is preview fixture text that ships
    /// in a public repository, so it must not describe anyone real.
    static let sample = Dossier(
        name: "A. Kestrel",
        standing: "Swift developer · two projects held at once · Tokyo",
        keptSince: "Apr 2026",
        dateline: "Tuesday, 9 June",
        lede: "Most of today was given to mull — shaping how a second brain should "
            + "carry a person with dignity. The morning ran deep and unbroken; the "
            + "afternoon turns to the client work, where a review waits at three.",
        chapters: [
            .init(title: "mull", detail: "Design language · the dossier", duration: "2h 40m"),
            .init(title: "Ledger", detail: "Storyboard refactor · Phase 5", duration: "1h 05m"),
            .init(title: "Client work", detail: "Review prep", duration: "35m"),
        ],
        resume: "DesignTokens.swift — the custode palette",
        particulars: [
            .init(key: "Role", value: "Founder & engineer"),
            .init(key: "Craft", value: "Swift, SwiftUI, macOS"),
            .init(key: "Tongue", value: "日本語 / English"),
            .init(key: "Rhythm", value: "Deepest before noon"),
        ]
    )
}

#Preview("Home — Dignified Dossier") {
    HomeDossierView(dossier: .sample)
        .frame(width: 860, height: 940)
}
