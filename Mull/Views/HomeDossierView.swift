import SwiftUI

// MARK: - Custode palette & serif (Cucinelli, in daylight)
//
// Cucinelli is not nocturnal. It is Umbrian daylight on ivory stone, undyed
// cashmere, linen, the warm cream of a fine book's page. So this surface is a
// LIT PAGE — warm ivory, espresso ink, one tobacco thread — and it stays that
// way regardless of system appearance, the way a good book is ivory whether the
// room is bright or dark. (This is a deliberate break from the app's cool
// Nocturne; if we commit to Cucinelli, Nocturne itself is the next thing to
// reconsider.)
//
// Additive tokens — they do not touch the existing Nocturne tokens.
extension DS {

    // Warm ivory page — the cream of fine paper / undyed cashmere.
    static let paperBg       = Color(red: 0.949, green: 0.929, blue: 0.882)  // #F2EDE1
    static let paperBgRaised = Color(red: 0.925, green: 0.902, blue: 0.847)  // #ECE6D8

    // Espresso ink — warm, never harsh black.
    static let umberInk   = Color(red: 0.224, green: 0.192, blue: 0.149)     // #393127
    static let umberDim   = Color(red: 0.224, green: 0.192, blue: 0.149).opacity(0.60)
    static let umberFaint = Color(red: 0.224, green: 0.192, blue: 0.149).opacity(0.34)

    // Tobacco / camel — the single accent. A thread, never a fill.
    static let tobacco    = Color(red: 0.580, green: 0.447, blue: 0.196)     // #945F32-ish ochre
    static let tobaccoDim = Color(red: 0.580, green: 0.447, blue: 0.196).opacity(0.66)

    // Warm taupe hairline — barely there.
    static let paperRule  = Color(red: 0.224, green: 0.192, blue: 0.149).opacity(0.12)

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
// Home as a DIGNIFIED DOSSIER — a private monograph about you, kept by a
// custodian. A lit ivory page with vast margins, an espresso serif, and one
// tobacco thread. Luxury here is restraint and air: most of the page is left
// empty on purpose. No cards, no chrome, no emoji — ink on paper.
//
// Self-contained mock: renders from `Dossier.sample` so it previews without
// services. Wire `Dossier.live(from:)` to ProjectSnapshot + me.md to ship.
struct HomeDossierView: View {
    let dossier: Dossier

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

            VStack(spacing: DS.lg) {
                ForEach(dossier.chapters) { c in
                    leaderRow(title: c.title, detail: c.detail, trailing: c.duration,
                              emphasis: c == dossier.chapters.first)
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
                .font(.system(size: 13, design: .serif))
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
                Button { } label: {
                    HStack(spacing: DS.xs) {
                        Image(systemName: "pencil").font(.system(size: 11))
                        Text("Amend").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(DS.tobacco)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, DS.xs)
            Text("A custodian keeps; it does not own. This record is kept for the person you are becoming.")
                .font(DS.captionFont)
                .foregroundStyle(DS.umberFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.xs)
        }
        .padding(.top, DS.lg)
    }

    // A quiet section rule: a small-caps serif title over a faint hairline.
    private func sectionRule(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: DS.md) {
            Text(title.uppercased())
                .font(DS.miniMedium).tracking(3.0)
                .foregroundStyle(DS.tobaccoDim)
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

    static let sample = Dossier(
        name: "Stanford Oport",
        standing: "Swift developer · three ventures held at once · Tokyo",
        keptSince: "Apr 2026",
        dateline: "Tuesday, 9 June",
        lede: "Most of today was given to mull — shaping how a second brain should "
            + "carry a person with dignity. The morning ran deep and unbroken; the "
            + "afternoon turns to the FX venture, where a client review waits at three.",
        chapters: [
            .init(title: "mull", detail: "Design language · the dossier", duration: "2h 40m"),
            .init(title: "PantryApp", detail: "Storyboard refactor · Phase 5", duration: "1h 05m"),
            .init(title: "FX venture", detail: "Client review prep", duration: "35m"),
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
