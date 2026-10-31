// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct NoteDocument: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var body: String
    var updatedAt: Date
    var tags: [String] = []
    var properties: [NoteProperty] = []
    var type: String = "markdown"
    private enum CodingKeys: String, CodingKey { case id, title, body, updatedAt, tags, properties, type }
    init(id: UUID, title: String, body: String, updatedAt: Date) {
        self.id = id; self.title = title; self.body = body; self.updatedAt = updatedAt
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        body = try values.decode(String.self, forKey: .body)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        properties = try values.decodeIfPresent([NoteProperty].self, forKey: .properties) ?? []
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? "markdown"
    }
}
struct NoteProperty: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var kind = "文本"
    var value = ""
}


