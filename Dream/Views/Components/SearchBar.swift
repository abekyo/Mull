import SwiftUI

/// Raycast-style search bar. Auto-focuses on appear. Esc clears or closes.
struct SearchBar: View {
    @Binding var query: String
    @FocusState private var isFocused: Bool
    var onEscape: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: DS.sm) {
            Image(systemName: "magnifyingglass")
                .font(DS.bodyFont)
                .foregroundStyle(isFocused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))

            TextField("Search your memory...", text: $query)
                .textFieldStyle(.plain)
                .font(DS.bodyFont)
                .focused($isFocused)
                .onKeyPress(.escape) {
                    if !query.isEmpty {
                        query = ""
                        return .handled
                    }
                    onEscape?()
                    return .handled
                }

            if !query.isEmpty {
                Button {
                    withAnimation(.spring(duration: 0.2)) { query = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(DS.captionFont)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, DS.md)
        .padding(.vertical, DS.sm)
        .background(Color(.controlBackgroundColor).opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusMd))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }
}
