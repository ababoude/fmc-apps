//! The six rows, saved in `UserDefaults`, and the bridge to the watch: push on change, run on tap.

import Combine
import Foundation

@MainActor
final class RowStore: ObservableObject {
    static let count = 6
    private static let key = "rows.v1"

    @Published var rows: [Row] {
        didSet { save() }
    }

    init() {
        rows = Self.load()
    }

    private static func load() -> [Row] {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([Row].self, from: data), !saved.isEmpty {
            return normalize(saved)
        }
        return normalize([])
    }

    /// Always six rows: the watch draws six, and a short array would leave stale names in the others.
    private static func normalize(_ rows: [Row]) -> [Row] {
        var out = Array(rows.prefix(count))
        while out.count < count { out.append(Row(name: "Shortcut \(out.count + 1)")) }
        return out
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// The names the watch gets, one per row. The watch refuses an empty name and always draws six rows, so a row
    /// without a target says where to finish setting it up.
    var watchNames: [String] {
        rows.map { $0.isRunnable ? $0.watchName : "Set up on iPhone" }
    }

    /// Empties one row's target, keeping its name: the watch row then reads "Set up on iPhone".
    func clear(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].target = ""
    }
}
