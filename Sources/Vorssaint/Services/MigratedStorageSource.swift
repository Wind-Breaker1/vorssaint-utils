// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Remember old locations until the user explicitly removes the migrated data.
struct MigratedStorageSource: Codable, Identifiable, Equatable {
    let path: String
    let bookmark: Data
    var id: String { path }

    init(url: URL) throws {
        path = url.resolvingSymlinksInPath().standardizedFileURL.path
        bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    func resolve(excluding active: URL) throws -> URL {
        var stale = false
        let url = try Self.resolveBookmark(bookmark, isStale: &stale)
        let source = url.resolvingSymlinksInPath().standardizedFileURL.path
        let target = active.resolvingSymlinksInPath().standardizedFileURL.path
        guard source != target, !target.hasPrefix(source + "/"), !source.hasPrefix(target + "/") else {
            throw NSError(domain: "Storage", code: 1, userInfo: [NSLocalizedDescriptionKey: "旧目录与当前保存目录重叠，不能删除"])
        }
        return url
    }
    /// A bookmark created by another build may have no usable app-scoped token.
    /// The non-sandboxed app can still resolve its location using normal filesystem access.
    static func resolveBookmark(_ data: Data, isStale: inout Bool) throws -> URL {
        do {
            return try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale)
        } catch {
            return try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale)
        }
    }
    static func load(key: String) -> [Self] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }
    static func save(_ sources: [Self], key: String) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(sources), forKey: key)
    }
}
