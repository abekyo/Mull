import Foundation

/// Pure project/entity extraction from a window title. Dependency-free (Foundation
/// only) so the selection layer, the current-state anchor, AND the standalone eval
/// harness can all share one definition.
///
///   "ContentView.swift — PantryApp" → "PantryApp"
///
/// The segment-splitting and the "could this be a project name" test live in
/// `ProjectNames`, which every other caller in the app shares. This type is the
/// single-title convenience on top of it: given one window title and no wider
/// corpus, which segment is the entity?
enum Entity {

    /// Best-effort project/entity from a window title. Conservative: returns nil
    /// when nothing looks like a stable entity.
    static func from(_ title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }

        let candidates = ProjectNames.segments(of: title).filter { ProjectNames.isPlausible($0) }
        // Editors (Xcode/VS Code) tend to put the project last; fall back to first.
        return candidates.last ?? candidates.first
    }

    /// App-aware variant. A content-driven app (browser, Finder) titles its window
    /// after whatever happens to be open — a web page, a folder — so no segment of
    /// it names a project, however plausible its shape. `ProjectNames.rank` already
    /// refuses candidates from these apps; this applies the same rule on the
    /// single-title path, which is how "Downloads" and "iCloud Drive" used to
    /// become projects the proactive loop would brief on.
    static func from(_ title: String?, app: String?) -> String? {
        if let app, ProjectNames.contentDrivenApps.contains(app.lowercased()) { return nil }
        return from(title)
    }
}
