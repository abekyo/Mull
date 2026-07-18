import Foundation

/// Pure project/entity extraction from a window title. Dependency-free (Foundation
/// only) so the selection layer, the current-state anchor, AND the standalone eval
/// harness can all share one definition.
///
///   "ContentView.swift — PantryApp" → "PantryApp"
enum Entity {

    private static let separators = [" — ", " – ", " - ", " | ", " · ", " : "]
    private static let knownApps: Set<String> = [
        "Xcode", "Code", "Visual Studio Code", "Terminal", "iTerm2", "Warp",
        "Safari", "Google Chrome", "Chrome", "Firefox", "Arc", "Brave Browser",
        "Finder", "Cursor", "Zed", "Simulator", "mull",
    ]

    /// Best-effort project/entity from a window title. Conservative: returns nil
    /// when nothing looks like a stable entity.
    static func from(_ title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }

        var segments = [title]
        for sep in separators where title.contains(sep) {
            segments = title.components(separatedBy: sep).map { $0.trimmingCharacters(in: .whitespaces) }
            break
        }

        let candidates = segments.filter { seg in
            guard seg.count >= 2, seg.count <= 40 else { return false }
            if knownApps.contains(seg) { return false }
            // Drop sentence/chat-like segments.
            if seg.contains("?") || seg.contains("？") || seg.contains("。") { return false }
            // Drop filenames (dotted, short alpha extension).
            if seg.contains("."), let ext = seg.split(separator: ".").last,
               ext.count <= 5, ext.allSatisfy({ $0.isLetter }) { return false }
            return true
        }
        // Editors (Xcode/VS Code) tend to put the project last; fall back to first.
        return candidates.last ?? candidates.first
    }
}
