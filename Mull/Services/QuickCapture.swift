import Foundation

/// Frictionless capture — Crane MD's "摩擦ゼロの捕捉" (principle 3) translated to mull.
///
/// One always-available field (the menu-bar panel) drops a thought into the vault
/// with zero ceremony: no file picker, no "where should this go", no save button.
/// It lands in `inbox.md`, a file NO agent ever writes — so it is
/// Round-trip safe by construction (原則6): the Curator can never clobber it, and
/// nothing here normalises bytes the user typed. mull routes it later; capture stays cheap.
enum QuickCapture {

    static let relativePath = VaultLayout.inboxFile

    private static let header = """
    # Captures

    _Quick thoughts caught in passing. Yours — mull never rewrites this file._

    """

    /// Append one captured line under today's date header. Returns true on success.
    /// Pure byte-append: reads the existing file, adds to the end, writes it back —
    /// every prior line is preserved exactly (原則6).
    @discardableResult
    static func append(_ text: String, now: Date = Date()) -> Bool {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return false }

        var existing = MullDirectory.read(relativePath) ?? header
        if existing.isEmpty { existing = header }
        if !existing.hasSuffix("\n") { existing += "\n" }

        let day = dayHeader(now)
        if !existing.contains("\n\(day)\n") && !existing.hasPrefix("\(day)\n") {
            existing += "\n\(day)\n"
        }
        existing += "- [\(time(now))] \(body)\n"

        return MullDirectory.write(existing, to: relativePath)
    }

    // MARK: - Formatting (stable, locale-independent)

    private static func dayHeader(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "## %04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func time(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
