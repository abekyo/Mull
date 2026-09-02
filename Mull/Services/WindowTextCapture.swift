import AppKit
import ApplicationServices

/// Capture-fidelity #1 (MAP-ARCHITECTURE.md audit): read the BODY text of the
/// focused window, not just its title. The title ("Notes – 240 notes") is a
/// label; the body is the work itself — and the territory can't be re-captured
/// later, so what we don't read now is lost forever.
///
/// Implementation: a bounded walk of the focused window's Accessibility tree,
/// collecting the values of text-bearing elements (text areas, text fields,
/// static text — which is also how web page text surfaces under AXWebArea).
///
/// Bounds keep it cheap and safe:
///   - node/depth caps so a huge tree (Xcode) can't stall the 30s timer
///   - char cap aligned with the clipboard fidelity cap (40k)
///   - AXSecureTextField subtrees are NEVER read (passwords)
/// Caller is responsible for app exclusions / private-browsing / secure-input
/// gating (RecordingService does all three before calling).
enum WindowTextCapture {

    private static let maxChars = 40_000
    private static let maxNodes = 1_500
    private static let maxDepth = 14

    /// Text roles whose AXValue is worth collecting.
    private static let textRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXStaticText", "AXComboBox",
    ]

    /// The collected body text of the frontmost app's front window, or nil.
    ///
    /// `kAXFocusedWindow` was the whole of how that window was found, and it is the
    /// attribute an app is likeliest not to answer — so this returned nil for apps
    /// whose text was sitting in `AXWindows[0]` the entire time. The title path was
    /// taught to fall back before this one was, which had it backwards: this is the
    /// larger half of the record, around 80% of the characters mull keeps.
    ///
    /// The cascade picks the window, not the text. A window that is found and holds
    /// nothing readable is an answer, and re-walking the next candidate to argue with
    /// it would cost a second 1,500-node crawl of somebody's frontmost app for a
    /// result that is usually the same window twice.
    static func focusedWindowText() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let windowEl = FrontWindow.element(of: appEl) else { return nil }

        var pieces: [String] = []
        var chars = 0
        var nodes = 0
        walk(windowEl, depth: 0, pieces: &pieces, chars: &chars, nodes: &nodes)

        let body = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    private static func walk(_ element: AXUIElement, depth: Int,
                             pieces: inout [String], chars: inout Int, nodes: inout Int) {
        guard depth <= maxDepth, nodes < maxNodes, chars < maxChars else { return }
        nodes += 1

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        // Never descend into password fields.
        if role == "AXSecureTextField" { return }

        if textRoles.contains(role) {
            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
            if let value = valueRef as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip empties and exact repeats of the previous piece (labels
                // often appear twice as static text + accessibility description).
                if !trimmed.isEmpty, trimmed != pieces.last {
                    let budget = maxChars - chars
                    let piece = String(trimmed.prefix(budget))
                    pieces.append(piece)
                    chars += piece.count
                }
            }
        }

        guard chars < maxChars, nodes < maxNodes else { return }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            walk(child, depth: depth + 1, pieces: &pieces, chars: &chars, nodes: &nodes)
            if chars >= maxChars || nodes >= maxNodes { return }
        }
    }
}
