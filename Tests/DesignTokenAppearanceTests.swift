import XCTest
import SwiftUI
import AppKit
@testable import mull

/// The palette has two pages, and every token is one dynamic `NSColor` that has
/// to pick the right one on its own. That resolution is the whole mechanism, and
/// it is invisible: a token that quietly froze on one page would still compile,
/// still draw, and still look correct in whichever appearance the author had on.
///
/// These tests resolve the tokens under both appearances and assert they differ
/// in the right direction. They are also the guard on the round-trip trap — see
/// `testNSColorRoundTripFreezes`, which pins the failure mode the AppKit call
/// sites have to avoid.
final class DesignTokenAppearanceTests: XCTestCase {

    private let aqua = NSAppearance(named: .aqua)!
    private let darkAqua = NSAppearance(named: .darkAqua)!

    /// Resolve a SwiftUI `Color` the way a view in that appearance would.
    private func resolve(_ color: Color, _ appearance: NSAppearance) -> NSColor {
        var out = NSColor.black
        appearance.performAsCurrentDrawingAppearance {
            out = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        return out
    }

    private func luminance(_ c: NSColor) -> CGFloat {
        func lin(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent)
            + 0.7152 * lin(c.greenComponent)
            + 0.0722 * lin(c.blueComponent)
    }

    // MARK: The mechanism

    /// The page inverts. If this fails, nothing else in the palette matters.
    func testCanvasInverts() {
        let light = resolve(DS.canvas, aqua)
        let dark = resolve(DS.canvas, darkAqua)
        XCTAssertGreaterThan(luminance(light), 0.7, "daylight canvas should be ivory")
        XCTAssertLessThan(luminance(dark), 0.05, "lamplight canvas should be espresso")
    }

    /// Ink inverts with it, so text never lands ink-on-ink.
    func testInkInvertsWithTheCanvas() {
        XCTAssertLessThan(luminance(resolve(DS.ink, aqua)), 0.1)
        XCTAssertGreaterThan(luminance(resolve(DS.ink, darkAqua)), 0.5)
    }

    /// Every token that carries a light/dark pair must actually differ. A token
    /// declared with `adaptive` but accidentally given two identical values, or
    /// one that got flattened somewhere, shows up here.
    func testAdaptiveTokensDifferBetweenAppearances() {
        let tokens: [(String, Color)] = [
            ("canvas", DS.canvas), ("surface", DS.surface), ("surfaceHi", DS.surfaceHi),
            ("hairline", DS.hairline), ("moon", DS.moon), ("moonDim", DS.moonDim),
            ("ink", DS.ink), ("inkDim", DS.inkDim), ("inkFaint", DS.inkFaint),
            ("inkGhost", DS.inkGhost), ("paperBgRaised", DS.paperBgRaised),
        ]
        for (name, color) in tokens {
            let l = resolve(color, aqua), d = resolve(color, darkAqua)
            XCTAssertNotEqual(l.redComponent, d.redComponent, accuracy: 0.0,
                              "\(name) resolved identically in both appearances")
        }
    }

    /// The dyes are the deliberate opposite: mid-tones that hold on both pages
    /// without moving. If someone "fixes" one by giving it a dark counterpart,
    /// this catches it and sends them to the measurement table in DesignTokens.
    func testEarthDyesDoNotAdapt() {
        let dyes: [(String, Color)] = [
            ("camel", DS.camel), ("olive", DS.olive), ("clay", DS.clay),
            ("slate", DS.slate), ("plum", DS.plum), ("dustyRose", DS.dustyRose),
            ("taupe", DS.taupe),
        ]
        for (name, color) in dyes {
            let l = resolve(color, aqua), d = resolve(color, darkAqua)
            XCTAssertEqual(l.redComponent, d.redComponent, accuracy: 0.001, "\(name)")
            XCTAssertEqual(l.greenComponent, d.greenComponent, accuracy: 0.001, "\(name)")
            XCTAssertEqual(l.blueComponent, d.blueComponent, accuracy: 0.001, "\(name)")
        }
    }

    // MARK: The contrast budget
    //
    // The ladder documented on `DS.ink` is the promise; these assert it in both
    // rooms. The numbers are the same on both sides by construction — the
    // lamplight alphas were solved backwards from the daylight ratios.

    private func contrast(_ fg: Color, on bg: Color, _ appearance: NSAppearance) -> CGFloat {
        // Text tiers carry alpha, so composite over the page before measuring.
        let f = resolve(fg, appearance), b = resolve(bg, appearance)
        let a = f.alphaComponent
        let composited = NSColor(
            srgbRed: f.redComponent * a + b.redComponent * (1 - a),
            green: f.greenComponent * a + b.greenComponent * (1 - a),
            blue: f.blueComponent * a + b.blueComponent * (1 - a),
            alpha: 1
        )
        let l1 = luminance(composited), l2 = luminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    func testTextTiersMeetAAInBothAppearances() {
        for (label, appearance) in [("daylight", aqua), ("lamplight", darkAqua)] {
            XCTAssertEqual(contrast(DS.ink, on: DS.canvas, appearance), 10.94, accuracy: 0.25,
                           "ink in \(label)")
            XCTAssertEqual(contrast(DS.inkDim, on: DS.canvas, appearance), 5.79, accuracy: 0.25,
                           "inkDim in \(label)")
            XCTAssertEqual(contrast(DS.inkFaint, on: DS.canvas, appearance), 4.61, accuracy: 0.25,
                           "inkFaint in \(label)")
            // AA for body text. inkFaint is what `sectionLabel()` uses everywhere.
            XCTAssertGreaterThanOrEqual(contrast(DS.inkFaint, on: DS.canvas, appearance), 4.5,
                                        "inkFaint falls under AA in \(label)")
        }
    }

    /// `inkGhost` is exempt by contract — it is a tick, never text. Pinned so the
    /// exemption stays deliberate rather than becoming an accident someone
    /// "fixes" by painting a label with it.
    func testInkGhostIsBelowTextContrastInBothAppearances() {
        for (label, appearance) in [("daylight", aqua), ("lamplight", darkAqua)] {
            XCTAssertLessThan(contrast(DS.inkGhost, on: DS.canvas, appearance), 2.0,
                              "inkGhost in \(label)")
        }
    }

    /// A card has to read as lifted off the page in both rooms — which means
    /// *lighter* than the page in both, not "lighter in one and darker in the
    /// other". This is the token most likely to be got backwards.
    func testSurfaceIsLiftedOffThePageInBothAppearances() {
        for (label, appearance) in [("daylight", aqua), ("lamplight", darkAqua)] {
            XCTAssertGreaterThan(luminance(resolve(DS.surface, appearance)),
                                 luminance(resolve(DS.canvas, appearance)),
                                 "surface should sit above canvas in \(label)")
            XCTAssertGreaterThan(luminance(resolve(DS.surfaceHi, appearance)),
                                 luminance(resolve(DS.surface, appearance)),
                                 "surfaceHi should sit above surface in \(label)")
        }
    }

    /// The dossier's well is pressed *into* the page — darker than the canvas in
    /// both rooms. The one token that deliberately does not mirror.
    func testPaperBgRaisedIsARecessInBothAppearances() {
        for (label, appearance) in [("daylight", aqua), ("lamplight", darkAqua)] {
            XCTAssertLessThan(luminance(resolve(DS.paperBgRaised, appearance)),
                              luminance(resolve(DS.canvas, appearance)),
                              "paperBgRaised should sit below canvas in \(label)")
        }
    }

    /// The accent has to stay legible enough to carry `.tint` on native controls
    /// and to draw the now-line, in both rooms.
    func testAccentCarriesInBothAppearances() {
        for (label, appearance) in [("daylight", aqua), ("lamplight", darkAqua)] {
            XCTAssertGreaterThanOrEqual(contrast(DS.moon, on: DS.canvas, appearance), 3.0,
                                        "moon in \(label)")
        }
    }

    /// Call sites dim tokens inline — `DS.moon.opacity(0.22)` edges a hovered
    /// card, `DS.ink.opacity(0.04)` is the shimmer, `tobaccoDim` is
    /// `moon.opacity(0.66)`. If `.opacity` resolved the colour before applying
    /// alpha, every one of those would freeze on whichever page was current, and
    /// nothing else in this file would catch it.
    func testOpacityPreservesTheDynamicProvider() {
        let dimmed = DS.ink.opacity(0.5)
        let l = resolve(dimmed, aqua), d = resolve(dimmed, darkAqua)
        XCTAssertLessThan(l.redComponent, 0.3, "dimmed ink should still be espresso in daylight")
        XCTAssertGreaterThan(d.redComponent, 0.7, "dimmed ink should still be ivory in lamplight")
        XCTAssertEqual(l.alphaComponent, 0.5, accuracy: 0.01)
        XCTAssertEqual(d.alphaComponent, 0.5, accuracy: 0.01)
    }

    /// The dossier's own tiers. `umberFaint` claims to *be* `DS.inkFaint` and
    /// `umberDim` claims a fixed 5.47:1 — both were true only in daylight when
    /// they were plain `.opacity()` of the ink.
    func testDossierTiersHoldTheirClaimsInBothAppearances() {
        for (label, appearance) in [("daylight", aqua), ("lamplight", darkAqua)] {
            XCTAssertEqual(contrast(DS.umberDim, on: DS.canvas, appearance), 5.47, accuracy: 0.25,
                           "umberDim in \(label)")
            let faint = resolve(DS.inkFaint, appearance)
            let umber = resolve(DS.umberFaint, appearance)
            XCTAssertEqual(faint.redComponent, umber.redComponent, accuracy: 0.001, label)
            XCTAssertEqual(faint.alphaComponent, umber.alphaComponent, accuracy: 0.001, label)
        }
    }

    /// A shadow must stay a shadow. The notice bar cast its own in
    /// `DS.ink.opacity(0.12)`, which inverted into an ivory halo the moment the
    /// ink did — the one place in the app where "just use the ink" produced a
    /// bug rather than a colour.
    func testShadowStaysDarkInBothAppearances() {
        for (label, appearance) in [("daylight", aqua), ("lamplight", darkAqua)] {
            XCTAssertLessThan(luminance(resolve(DS.shadow, appearance)), 0.06,
                              "shadow is not dark in \(label)")
        }
        XCTAssertGreaterThan(resolve(DS.shadow, darkAqua).alphaComponent,
                             resolve(DS.shadow, aqua).alphaComponent,
                             "a shadow needs to be carried further on a dark page")
    }

    /// No view may build a shadow out of the ink again.
    func testNoShadowIsPaintedWithTheInk() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Mull")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") && !code.hasPrefix("///") else { continue }
                guard code.contains(".shadow(color:") else { continue }
                XCTAssertFalse(code.contains("DS.ink"),
                               "\(file.lastPathComponent):\(index + 1) casts a shadow in the ink — use DS.shadow")
            }
        }
    }

    // MARK: The round trip
    //
    // Written first as `testNSColorRoundTripFreezes`, asserting that
    // `NSColor(someDynamicColor)` resolves at conversion time and freezes there.
    // It failed: the round trip preserves the provider and the re-read came back
    // espresso. Kept, inverted, because the wrong belief is the plausible one —
    // it is what the iOS-side folklore says — and because an SDK that *did*
    // start flattening the conversion would silently freeze all three windows on
    // whichever page they were born with, which is exactly the class of bug only
    // the person running the other appearance would ever see.

    /// The conversion back to `NSColor` keeps the colour dynamic.
    func testNSColorRoundTripStaysDynamic() {
        var converted = NSColor.black
        aqua.performAsCurrentDrawingAppearance {
            converted = NSColor(DS.canvas)
        }
        var reread = NSColor.black
        darkAqua.performAsCurrentDrawingAppearance {
            reread = converted.usingColorSpace(.sRGB) ?? .black
        }
        XCTAssertLessThan(luminance(reread), 0.05,
                          "NSColor(Color) began flattening the dynamic provider")
    }

    /// The AppKit-side token the windows actually use.
    func testCanvasNSFollowsTheAppearance() {
        var light = NSColor.black, dark = NSColor.black
        aqua.performAsCurrentDrawingAppearance {
            light = DS.canvasNS.usingColorSpace(.sRGB) ?? .black
        }
        darkAqua.performAsCurrentDrawingAppearance {
            dark = DS.canvasNS.usingColorSpace(.sRGB) ?? .black
        }
        XCTAssertGreaterThan(luminance(light), 0.7)
        XCTAssertLessThan(luminance(dark), 0.05)
    }

    /// Nothing may pin an appearance any more — a single stray
    /// `preferredColorScheme` or `NSAppearance(named:)` overrides the entire
    /// adaptive palette, and it would only be visible to someone running the
    /// other appearance.
    func testNoSourceFilePinsAnAppearance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Mull")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "found no sources to scan")

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // Skip prose: these names are discussed at length in the comments
                // that explain why they are gone.
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//") && !code.hasPrefix("///") else { continue }
                XCTAssertFalse(code.contains("preferredColorScheme"),
                               "\(file.lastPathComponent):\(index + 1) pins a colour scheme")
                XCTAssertFalse(code.contains("NSAppearance(named:"),
                               "\(file.lastPathComponent):\(index + 1) pins an appearance")
            }
        }
    }
}
