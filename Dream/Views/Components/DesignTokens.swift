import SwiftUI

/// Design tokens — single source of truth for all visual constants.
///
/// Typography: 5 levels with clear hierarchy
/// Spacing: 4px grid
/// Radius: 3 tiers
/// Colors: semantic + accent gradients
/// Shadows: 2 tiers for depth
enum DS {

    // MARK: - Typography

    static let heroFont = Font.system(size: 28, weight: .bold)
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
    static let xxl: CGFloat = 32

    // MARK: - Radius

    static let radiusSm: CGFloat = 6
    static let radiusMd: CGFloat = 10
    static let radiusLg: CGFloat = 14

    // MARK: - Semantic Colors

    static let recording = Color.green
    static let paused = Color.orange
    static let error = Color.red

    // MARK: - Accent Gradient

    static let accentGradient = LinearGradient(
        colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let warmGradient = LinearGradient(
        colors: [Color.orange.opacity(0.8), Color.pink.opacity(0.6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let coolGradient = LinearGradient(
        colors: [Color.blue.opacity(0.6), Color.cyan.opacity(0.4)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Panel

    static let panelWidth: CGFloat = 420
    static let panelMaxHeight: CGFloat = 440
}

// MARK: - View Extensions

extension View {
    /// Standard card with subtle shadow and border.
    func dreamCard(isHovered: Bool = false) -> some View {
        self
            .padding(DS.md)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusMd)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(isHovered ? 0.08 : 0.04), radius: isHovered ? 8 : 4, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusMd)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.08 : 0.04), lineWidth: 0.5)
            )
    }

    /// Primary card — more prominent with accent tint.
    func dreamPrimaryCard() -> some View {
        self
            .padding(DS.lg)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusLg)
                    .fill(.ultraThinMaterial)
                    .shadow(color: Color.accentColor.opacity(0.1), radius: 8, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusLg)
                    .strokeBorder(Color.accentColor.opacity(0.12), lineWidth: 0.5)
            )
    }

    /// Hero card with gradient accent.
    func dreamHeroCard() -> some View {
        self
            .padding(DS.xl)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: DS.radiusLg)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: DS.radiusLg)
                        .fill(Color.accentColor.opacity(0.04))
                }
                .shadow(color: Color.accentColor.opacity(0.12), radius: 12, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusLg)
                    .strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 0.5)
            )
    }

    /// Section label style.
    func sectionLabel() -> some View {
        self
            .font(DS.labelFont)
            .tracking(DS.labelTracking)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
