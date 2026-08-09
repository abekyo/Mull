import SwiftUI

// How a search result LOOKS. Split out of Mull/Services/SearchService.swift,
// which imported SwiftUI for exactly these two members and was the single
// layering leak below Mull/Views.
//
// The rule this restores: a type that decides *what matched* has no business
// deciding what colour it is. Search is testable without a UI framework; colour
// is not testable at all, and now nothing has to pretend otherwise.

extension SearchHit.Kind {
    var color: Color {
        switch self {
        case .typed: DS.eventKeystroke
        case .copied: DS.eventClipboard
        case .window: DS.eventWindow
        case .document: DS.taupe
        case .app: DS.eventApp
        case .audio: DS.eventAudio
        case .schedule: DS.moon
        }
    }
}

extension SearchService {
/// Render the matched text with the query terms emphasised (moonlight, medium), so the
/// eye lands on *why* this row matched. Case-insensitive; windowed to keep rows compact.
static func highlighted(_ raw: String, query: String) -> AttributedString {
    let text = snippet(raw, query: query)
    var result = AttributedString(text)
    for term in terms(in: query) {
        var from = text.startIndex
        while let r = text.range(of: term, options: .caseInsensitive, range: from..<text.endIndex) {
            if let lo = AttributedString.Index(r.lowerBound, within: result),
               let hi = AttributedString.Index(r.upperBound, within: result) {
                result[lo..<hi].foregroundColor = DS.moon
                // `captionFont`'s emphasis tier, not a hand-written 11pt. The row
                // renders in `DS.captionFont`; a literal size here would sit on a
                // different baseline the moment that token moved, and the line
                // would jitter mid-sentence. Same pairing as microFont/microBold.
                result[lo..<hi].font = DS.captionMedium
            }
            from = r.upperBound
        }
    }
    return result
}
}
