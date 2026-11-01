// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Owns the long-lived read-only SQLite connection used by note search.
/// Keeping query concurrency out of NotesStore prevents UI state and database
/// connection lifecycle from becoming one responsibility.
final class NotesIndexQueryService {
    private let queue = DispatchQueue(label: "com.vorssaint.notes.search", qos: .userInitiated)
    private var index: NotesIndex?
    private var url: URL?

    func configure(url: URL) {
        queue.sync {
            index = nil
            self.url = url
        }
    }

    func release() {
        queue.sync { index = nil }
    }

    func search(_ query: String, completion: @escaping (Result<[String], Error>) -> Void) {
        queue.async {
            let result = Result {
                guard let url = self.url else { throw CocoaError(.fileReadNoSuchFile) }
                if self.index == nil { self.index = try NotesIndex(url: url, readOnly: true) }
                return try self.index!.search(query)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
