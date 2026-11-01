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
    init(id: UUID, title: String, body: String, updatedAt: Date) {
        self.id = id; self.title = title; self.body = body; self.updatedAt = updatedAt
    }
}
struct NoteProperty: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var kind = "文本"
    var value = ""
}


