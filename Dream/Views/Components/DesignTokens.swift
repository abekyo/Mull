import SwiftUI

/// Design tokens — single source of truth for all visual constants.
/// Changing a value here changes it everywhere.
///
/// Typography scale (4 levels only):
///   Title:   15pt semibold
///   Body:    13pt regular
///   Caption: 11pt regular
///   Micro:   10pt monospaced
///
/// Spacing (4px grid):
///   xs: 4    sm: 8    md: 12    lg: 16    xl: 24
///
/// Radius:
///   sm: 6    md: 8    lg: 12
enum DS {

    // MARK: - Typography

    static let titleFont = Font.system(size: 15, weight: .semibold)
    static let bodyFont = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let captionFont = Font.system(size: 11)
    static let microFont = Font.system(size: 10, design: .monospaced)

    static let labelFont = Font.system(size: 11, weight: .medium)
    static let labelTracking: CGFloat = 0.5

    // MARK: - Spacing (4px grid)

    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24

    // MARK: - Radius

    static let radiusSm: CGFloat = 6
    static let radiusMd: CGFloat = 8
    static let radiusLg: CGFloat = 12

    // MARK: - Card Styles

    /// Standard card background — visible but not heavy.
    static func cardBackground(isHovered: Bool = false) -> some ShapeStyle {
        Color(.controlBackgroundColor).opacity(isHovered ? 0.8 : 0.6)
    }

    /// Primary card (today's card) — slightly more prominent.
    static let primaryCardBackground = Color(.controlBackgroundColor).opacity(0.7)

    // MARK: - Semantic Colors

    static let recording = Color.green
    static let paused = Color.orange
    static let error = Color.red

    // MARK: - Common Modifiers

    static let panelWidth: CGFloat = 420
    static let panelMaxHeight: CGFloat = 440
}

// MARK: - View Extensions

extension View {
    /// Standard card wrapper with consistent padding, background, and radius.
    func dreamCard(isHovered: Bool = false) -> some View {
        self
            .padding(DS.md)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusMd)
                    .fill(Color(.controlBackgroundColor).opacity(isHovered ? 0.8 : 0.6))
            )
    }

    /// Primary card (today) — more prominent.
    func dreamPrimaryCard() -> some View {
        self
            .padding(DS.lg)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusLg)
                    .fill(Color(.controlBackgroundColor).opacity(0.7))
            )
    }

    /// Section label style — ALL CAPS, tracked, secondary color.
    func sectionLabel() -> some View {
        self
            .font(DS.labelFont)
            .tracking(DS.labelTracking)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
