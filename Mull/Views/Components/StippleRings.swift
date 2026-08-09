import SwiftUI

// MARK: - StippleRings
//
// The app-icon motif — "点描", tree rings drawn as rows of dots — rendered live.
// This is the same algorithm and the same mulberry32 random stream as the icon
// renderer (scripts render the Dock icon from it), so the figure that appears in
// the UI is literally the figure on the icon: one dot per kept moment, rings of
// days, the centre pushed off-frame so the record reads as still growing.
//
// Deliberately static. It never animates, never fills toward a target, and is
// never wired to a live count — a texture of the record, not a meter of it.
// Stated, not scored: no streaks, and nothing that asks to be fed.
struct StippleRings: View {
    /// Seed for the deterministic dot stream. 112 is the icon's own seed.
    var seed: UInt32 = 112
    /// Ring centre as a fraction of the view's bounds (the icon sits at 0.72, 0.30).
    var center: CGPoint = CGPoint(x: 0.72, y: 0.30)
    /// First ring radius / ring spacing, as fractions of the longer side.
    var startR: Double = 0.035
    var gap: Double = 0.06
    /// Rings stop once they pass this fraction of the longer side.
    var maxR: Double = 1.55
    /// Dot radius, spacing along a ring, and the chance a dot is skipped.
    var dotR: Double = 0.0062
    var dotGap: Double = 0.027
    var skip: Double = 0.08
    /// Waviness of the rings.
    var amp: Double = 0.014
    /// Most dots are tobacco; roughly a third fall in ink, like the icon.
    var primary: Color = DS.moon
    var secondary: Color = DS.ink

    /// The empty-state figure used across the app: a small contained roundel of
    /// sparse, half-formed rings — a record that has only begun to accrete.
    /// One set of parameters, so every quiet page wears the same face.
    static func roundel() -> StippleRings {
        StippleRings(center: CGPoint(x: 0.5, y: 0.5),
                     startR: 0.08, gap: 0.13, maxR: 0.46,
                     dotR: 0.016, dotGap: 0.062, skip: 0.12)
    }

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            draw(&context, size)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Split out of `body`, with a type written on every local, because inline it
    /// compiled here and failed on CI with "the compiler is unable to type-check
    /// this expression in reasonable time". The cost is not the length: it is that
    /// `Double` and `CGFloat` interconvert implicitly, so each unannotated `let`
    /// multiplies the overloads the checker carries through the whole closure.
    ///
    /// The order of `rnd.next()` calls is the figure. It is unchanged here, and has
    /// to stay unchanged — the same stream draws the app icon, and reordering a
    /// single draw would leave the two no longer the same image.
    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let rnd = Mulberry32(seed)
        let S: Double = Double(max(size.width, size.height))
        let harmonics: [Double] = [2, 3, 5, 8]
        let amps: [Double] = harmonics.map { (k: Double) -> Double in
            amp * (0.7 + rnd.next() * 0.6) / k.squareRoot()
        }
        let phases: [Double] = harmonics.map { _ -> Double in rnd.next() * Double.pi * 2 }

        let cx: Double = Double(size.width) * Double(center.x)
        let cy: Double = Double(size.height) * Double(center.y)
        var R: Double = startR * S
        var ring: Int = 0
        while ring < 64 && R < S * maxR {
            let n: Int = max(6, Int((2 * Double.pi * R / (S * dotGap)).rounded()))
            for s in 0..<n {
                if rnd.next() < skip { continue }
                let th: Double = Double(s) / Double(n) * 2 * Double.pi
                var w: Double = 1
                for k in harmonics.indices {
                    w += amps[k] * sin(harmonics[k] * th + phases[k] + Double(ring) * 0.25)
                }
                let r: Double = R * w
                let color: Color = rnd.next() < 0.3 ? secondary : primary
                let alpha: Double = 0.7 + rnd.next() * 0.3
                let rad: Double = S * dotR * (0.75 + rnd.next() * 0.5)
                let rect = CGRect(x: CGFloat(cx + cos(th) * r - rad),
                                  y: CGFloat(cy + sin(th) * r - rad),
                                  width: CGFloat(rad * 2), height: CGFloat(rad * 2))
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(alpha)))
            }
            R += S * gap * (0.8 + rnd.next() * 0.4)
            ring += 1
        }
    }
}

// MARK: - StippleMark
//
// The smallest unit of the motif: three dots off one ring, used as a printer's
// ornament — the bullet before a note, the fleuron beside a section label, the
// mark that used to be a decorative SF Symbol. Symbols stay on what operates
// (buttons, status, navigation); the mark goes on what adorns. That split is
// what keeps the app from reading as a grab-bag of stock glyphs.
struct StippleMark: View {
    var color: Color = DS.moon
    /// Diameter of the largest dot; the whole mark is about four dots wide.
    var dot: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            // Hand-placed, not seeded: at this scale the figure must be exact.
            // Three dots on a shallow rising arc — the tail of a ring, fading
            // as it goes, the way the icon's rings thin toward their edge.
            let dots: [(x: CGFloat, y: CGFloat, scale: CGFloat, alpha: CGFloat)] = [
                (0.14, 0.68, 1.00, 1.00),
                (0.50, 0.42, 0.80, 0.85),
                (0.86, 0.28, 0.62, 0.70),
            ]
            for d in dots {
                let r = dot * d.scale / 2
                let rect = CGRect(x: size.width * d.x - r, y: size.height * d.y - r,
                                  width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(d.alpha)))
            }
        }
        .frame(width: dot * 4.2, height: dot * 2.6)
        .accessibilityHidden(true)
    }
}

/// mulberry32, ported bit-for-bit from the icon renderer so both draw the same
/// figure. A class so the closures above can advance it without `inout`.
private final class Mulberry32 {
    private var a: UInt32
    init(_ seed: UInt32) { a = seed }
    func next() -> Double {
        a = a &+ 0x6D2B79F5
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296.0
    }
}

#Preview("Stipple rings — icon figure") {
    StippleRings()
        .frame(width: 320, height: 320)
        .background(DS.surface)
}

#Preview("Stipple rings — roundel") {
    StippleRings(center: CGPoint(x: 0.5, y: 0.5),
                 startR: 0.08, gap: 0.13, maxR: 0.46,
                 dotR: 0.016, dotGap: 0.062, skip: 0.12)
        .frame(width: 96, height: 96)
        .background(DS.canvas)
}
