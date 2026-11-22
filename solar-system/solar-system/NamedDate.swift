import Foundation

/// A date the user can jump to: a preset notable date or a saved bookmark.
/// Shared by the iOS and macOS targets; bookmarks persist as JSON in
/// UserDefaults under "savedDates", so keep this Codable shape stable.
struct NamedDate: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String
    let date: Date
    init(name: String, date: Date) { id = UUID(); self.name = name; self.date = date }
}
