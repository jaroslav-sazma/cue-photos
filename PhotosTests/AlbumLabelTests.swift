import Foundation
import Testing

private let vacation = AlbumLabel(emoji: "🏖️", name: "Vacation")
private let party = AlbumLabel(emoji: "🎉", name: "Party")

private func album(_ key: String, _ title: String) -> Album {
    Album(mediaKey: key, title: title)
}

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "labels-test-\(UUID().uuidString).json")
}

struct AlbumLabelTests {
    @Test func emojiValidation() {
        #expect(AlbumLabel.isValidEmoji("🏖️"))
        #expect(AlbumLabel.isValidEmoji("🏖"))
        #expect(AlbumLabel.isValidEmoji("❤️"))
        #expect(AlbumLabel.isValidEmoji("👨‍👩‍👧"))
        #expect(!AlbumLabel.isValidEmoji("1"))
        #expect(!AlbumLabel.isValidEmoji("a"))
        #expect(!AlbumLabel.isValidEmoji("🏖🎉"))
        #expect(!AlbumLabel.isValidEmoji(""))
    }

    @Test func variationSelectorDoesNotSplitALabel() {
        #expect(AlbumLabel(emoji: "🏖", name: "").id == vacation.id)
        #expect(album("a", "🏖 2025-07 Italy").hasLabel(vacation))
        #expect(album("b", "🏖️ 2025-07 Italy").hasLabel(vacation))
        #expect(!album("c", "2025-07 Italy 🏖").hasLabel(vacation))
    }

    @Test func applyingReplacesTheLabel() {
        let labels = [vacation, party]
        #expect(labels.applying(vacation, to: "2025-07 Italy") == "🏖️ 2025-07 Italy")
        #expect(labels.applying(party, to: "🏖️ 2025-07 Italy") == "🎉 2025-07 Italy")
        #expect(labels.applying(nil, to: "🎉 2025-07 Italy") == "2025-07 Italy")
        #expect(labels.applying(vacation, to: "") == "🏖️ ")
        // an emoji that is no known label is part of the name
        #expect(labels.applying(vacation, to: "🚗 Road trip") == "🏖️ 🚗 Road trip")
        #expect(labels.label(of: "🎉 Birthday") == party)
        #expect(labels.removingLabel(from: "🏖️ ").isEmpty)
    }

    @Test func searchMatchesEveryTermAnywhere() {
        #expect("🏖️ 2025-07 Itálie".matchesSearchTerms("🏖 italie"))
        #expect("🏖️ 2025-07 Itálie".matchesSearchTerms("itálie 2025"))
        #expect(!"🏖️ 2025-07 Itálie".matchesSearchTerms("🎉 itálie"))
        #expect("Anything".matchesSearchTerms("  "))
    }

    @Test func filterCombinesLabelAndSearch() {
        let albums = [
            album("a", "🏖️ 2025-07 Itálie"),
            album("b", "🏖️ 2024-08 Chorvatsko"),
            album("c", "🎉 2025-03 Itálie party"),
            album("d", "2023 Itálie"),
        ]
        #expect(albums.filtered(search: "itálie", label: vacation).map(\.mediaKey) == ["a"])
        #expect(albums.filtered(search: "", label: vacation).map(\.mediaKey) == ["a", "b"])
        #expect(albums.filtered(search: "itálie", label: nil).map(\.mediaKey) == ["a", "c", "d"])
    }

    @Test func storePersistsAndRejectsDuplicates() {
        let url = tempURL()
        let store = AlbumLabelStore(fileURL: url)
        #expect(store.add(vacation))
        #expect(!store.add(AlbumLabel(emoji: "🏖", name: "Beach")))
        #expect(!store.add(AlbumLabel(emoji: "x", name: "Not an emoji")))
        #expect(store.add(party))
        store.rename(id: party.id, to: "Celebration")
        store.remove(id: vacation.id)
        let reloaded = AlbumLabelStore(fileURL: url)
        #expect(reloaded.labels == [AlbumLabel(emoji: "🎉", name: "Celebration")])
    }

    @Test func importMergesByEmoji() throws {
        let source = AlbumLabelStore(fileURL: tempURL())
        source.add(AlbumLabel(emoji: "🏖", name: "Holiday"))
        source.add(party)
        let target = AlbumLabelStore(fileURL: tempURL())
        target.add(vacation)
        target.add(AlbumLabel(emoji: "🎄", name: "Christmas"))
        let changed = try target.importData(try source.exportData())
        #expect(changed == 2)
        #expect(target.labels.map(\.name) == ["Holiday", "Christmas", "Party"])
        #expect(try target.importData(try source.exportData()) == 0)
    }

    @Test func importRejectsForeignFiles() {
        let store = AlbumLabelStore(fileURL: tempURL())
        #expect(throws: AlbumLabelStore.ImportError.self) {
            try store.importData(Data(#"{"something":"else"}"#.utf8))
        }
        #expect(store.labels.isEmpty)
    }

    @Test func unreadableFileIsMovedAside() throws {
        let url = tempURL()
        try Data("not json".utf8).write(to: url)
        let store = AlbumLabelStore(fileURL: url)
        #expect(store.labels.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("unreadable").path))
    }
}
