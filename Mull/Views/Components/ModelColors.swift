import SwiftUI

/// Presentation colors for service-layer model types.
///
/// These properties used to live on the models themselves, which forced
/// `TimeBlockEngine.swift` and `CalendarService.swift` to `import SwiftUI` — and
/// through them the MullMCP command-line target, which had to compile
/// `DesignTokens.swift` just to satisfy a data model's colour property.
///
/// Colour is a presentation concern, so it belongs here: the service layer stays
/// UI-free and linkable from a headless binary, while call sites keep the same
/// `block.color` / `project.color` API they had before.
extension TimeBlock {
    var color: Color { DS.appColor(app) }
}

extension ActivitySummary {
    /// The dominant block's colour; `.secondary` for an activity with no blocks.
    var color: Color { blocks.first?.color ?? .secondary }
}

extension ProjectSnapshot {
    var color: Color { DS.appColor(primaryApp) }
}

extension CalendarEvent {
    /// The owning calendar's tint. The model carries a `CGColor` so it stays free
    /// of SwiftUI; this is the SwiftUI form the views actually draw with.
    var color: Color { Color(cgColor: calendarColor) }
}
