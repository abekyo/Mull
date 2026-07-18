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
    /// The dominant block's colour; the faint ink tier for an activity with no
    /// blocks (not `.secondary`, which is a cold system grey).
    var color: Color { blocks.first?.color ?? DS.inkFaint }
}

extension ProjectSnapshot {
    var color: Color { DS.appColor(primaryApp) }
}

extension CalendarEvent {
    /// The owning calendar's tint, brought into mull's family.
    ///
    /// The model carries a `CGColor` so it stays free of SwiftUI; this is the
    /// SwiftUI form the views actually draw with. It is deliberately *not* the raw
    /// EventKit colour: macOS hands out saturated system red/blue/green/purple,
    /// and painting those straight onto the ivory canvas was the single largest
    /// source of cold colour in the app. `DS.warmed` folds each calendar's hue
    /// into the warm band and caps its saturation and brightness — so two
    /// calendars still read as two calendars, but both belong to the page.
    var color: Color { DS.warmed(calendarColor) }
}
