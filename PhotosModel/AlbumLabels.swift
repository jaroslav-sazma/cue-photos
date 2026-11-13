import Foundation
import Observation
import os

private nonisolated let labelsLog = Logger(subsystem: "app.cue.photos", category: "labels")

// A label lives only on this Mac; on Google's side it is nothing but the emoji the
// album title starts with, so albums keep their label everywhere Google shows them
nonisolated struct AlbumLabel: Codable, Hashable, Identifiable, Sendable {
    var emoji: String
    var name: String

    var id: String { Self.key(emoji) }

    // U+FE0F only requests emoji presentation and emoji pickers add or omit it
    // freely: "🏖" and "🏖️" must be the same label
    static func key(_ text: some StringProtocol) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { $0 != "\u{FE0F}" })
        return String(scalars)
    }

    // digits, # and * carry the Unicode emoji property too; bare ASCII is text,
    // while "🏖" without U+FE0F (text presentation by default) still counts
    static func isValidEmoji(_ text: String) -> Bool {
        guard text.count == 1, let first = text.unicodeScalars.first else { return false }
        let scalars = text.unicodeScalars
        return scalars.contains { $0.properties.isEmojiPresentation }
            || (first.properties.isEmoji && (!first.isASCII || scalars.count > 1))
    }
}

nonisolated extension [AlbumLabel] {
    func label(of title: String) -> AlbumLabel? {
        guard let key = title.leadingLabelKey else { return nil }
        return first { $0.id == key }
    }

    // a title carries at most one label: picking another replaces it
    func applying(_ label: AlbumLabel?, to title: String) -> String {
        let rest = removingLabel(from: title)
        guard let label else { return rest }
        return label.emoji + " " + rest
    }

    func removingLabel(from title: String) -> String {
        let trimmed = title.drop(while: \.isWhitespace)
        guard label(of: title) != nil else { return String(trimmed) }
        return String(trimmed.dropFirst().drop(while: \.isWhitespace))
    }
}

nonisolated extension Album {
    func hasLabel(_ label: AlbumLabel) -> Bool {
        title?.leadingLabelKey == label.id
    }
}

nonisolated extension [Album] {
    func filtered(search: String, label: AlbumLabel?) -> [Album] {
        filter { album in
            (label.map(album.hasLabel) ?? true) && album.displayTitle.matchesSearchTerms(search)
        }
    }
}

nonisolated extension String {
    fileprivate var leadingLabelKey: String? {
        drop(while: \.isWhitespace).first.map { AlbumLabel.key(String($0)) }
    }

    // every whitespace-separated term must occur somewhere: "🏖 itálie" finds
    // "🏖 2025-07 Itálie"
    func matchesSearchTerms(_ query: String) -> Bool {
        let haystack = AlbumLabel.key(self)
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            haystack.localizedSearchContains(AlbumLabel.key($0))
        }
    }
}

@Observable
final class AlbumLabelStore {
    nonisolated struct File: Codable, Sendable {
        var version = 1
        var labels: [AlbumLabel]
    }

    nonisolated enum ImportError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            String(localized: "The file doesn’t contain album labels.")
        }
    }

    private(set) var labels: [AlbumLabel]
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            if let stored = try? JSONDecoder().decode(File.self, from: data) {
                labels = stored.labels
            } else {
                // never silently overwrite what might be a recoverable label list
                labels = []
                let quarantine = fileURL.appendingPathExtension("unreadable")
                try? FileManager.default.removeItem(at: quarantine)
                try? FileManager.default.moveItem(at: fileURL, to: quarantine)
                labelsLog.error("labels file unreadable, moved aside")
            }
        } else {
            labels = []
        }
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Cue Photos/labels.json")
    }

    func label(id: String?) -> AlbumLabel? {
        guard let id else { return nil }
        return labels.first { $0.id == id }
    }

    @discardableResult
    func add(_ label: AlbumLabel) -> Bool {
        guard AlbumLabel.isValidEmoji(label.emoji), self.label(id: label.id) == nil else { return false }
        labels.append(label)
        save()
        return true
    }

    func rename(id: String, to name: String) {
        guard let index = labels.firstIndex(where: { $0.id == id }) else { return }
        labels[index].name = name
        save()
    }

    func remove(id: String) {
        labels.removeAll { $0.id == id }
        save()
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(File(labels: labels))
    }

    // Merges by emoji: an imported name wins over the local one, local labels the
    // file does not mention stay. Returns how many labels were added or renamed.
    @discardableResult
    func importData(_ data: Data) throws -> Int {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            throw ImportError.unreadable
        }
        var changed = 0
        for imported in file.labels where AlbumLabel.isValidEmoji(imported.emoji) {
            if let index = labels.firstIndex(where: { $0.id == imported.id }) {
                guard labels[index].name != imported.name else { continue }
                labels[index].name = imported.name
            } else {
                labels.append(imported)
            }
            changed += 1
        }
        if changed > 0 { save() }
        return changed
    }

    // the list is tiny and changes only on explicit edits; a synchronous atomic
    // write keeps it simple and loses nothing on quit
    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try exportData().write(to: fileURL, options: .atomic)
        } catch {
            labelsLog.error("labels save failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
