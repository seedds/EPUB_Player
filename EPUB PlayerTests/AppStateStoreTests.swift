//
//  AppStateStoreTests.swift
//  EPUB PlayerTests
//
//

import XCTest
@testable import EPUBPlayer

@MainActor
final class AppStateStoreTests: XCTestCase {
    var tempDocumentsDirectory: URL!
    var store: AppStateStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDocumentsDirectory = try TestDocumentsDirectory.activate()
        store = AppStateStore()
    }

    override func tearDown() async throws {
        store = nil
        TestDocumentsDirectory.deactivate(rootURL: tempDocumentsDirectory)
        tempDocumentsDirectory = nil
        try await super.tearDown()
    }

    func testInitialState() async throws {
        XCTAssertTrue(store.books.isEmpty, "New store should have no books")
        XCTAssertTrue(store.customFontFamilies.isEmpty, "New store should have no custom fonts")
        XCTAssertEqual(store.fontSize, ReaderSettings.defaultFontSize)
        XCTAssertEqual(store.lineHeight, ReaderSettings.defaultLineHeight)
        XCTAssertEqual(store.autoRewindAfterBackgroundMinutes, ReaderSettings.defaultAutoRewindAfterBackgroundMinutes)
        XCTAssertEqual(store.booksSortOption, .recentlyAdded)
    }

    func testAutoRewindNormalization() {
        XCTAssertEqual(ReaderSettings.normalizedAutoRewindAfterBackgroundMinutes(1), 1)
        XCTAssertEqual(ReaderSettings.normalizedAutoRewindAfterBackgroundMinutes(3), 2)
        XCTAssertEqual(ReaderSettings.normalizedAutoRewindAfterBackgroundMinutes(6), 5)
        XCTAssertEqual(ReaderSettings.normalizedAutoRewindAfterBackgroundMinutes(99), 10)
    }

    func testPlaybackJumpIntervalNormalization() {
        XCTAssertEqual(ReaderSettings.normalizedPlaybackJumpInterval(15), 15)
        XCTAssertEqual(ReaderSettings.normalizedPlaybackJumpInterval(22), 15)
        XCTAssertEqual(ReaderSettings.normalizedPlaybackJumpInterval(37), 30)
        XCTAssertEqual(ReaderSettings.normalizedPlaybackJumpInterval(52), 45)
        XCTAssertEqual(ReaderSettings.normalizedPlaybackJumpInterval(99), 60)
    }

    func testAddBook() async throws {
        let book = Book(
            title: "Test Book",
            author: "Test Author",
            originalFilename: "test.epub",
            epubFilePath: "Books/test.epub"
        )

        store.addBook(book)

        XCTAssertEqual(store.books.count, 1)
        XCTAssertEqual(store.books.first?.title, "Test Book")
        XCTAssertEqual(store.books.first?.author, "Test Author")
    }

    func testRemoveBook() async throws {
        let book = Book(
            title: "Test Book",
            originalFilename: "test.epub",
            epubFilePath: "Books/test.epub"
        )

        store.addBook(book)
        XCTAssertEqual(store.books.count, 1)

        store.removeBook(id: book.id)
        XCTAssertTrue(store.books.isEmpty)
    }

    func testBooksSortedByImportDate() async throws {
        let book1 = Book(
            title: "Book 1",
            originalFilename: "book1.epub",
            epubFilePath: "Books/book1.epub",
            importedAt: Date(timeIntervalSince1970: 1000)
        )

        let book2 = Book(
            title: "Book 2",
            originalFilename: "book2.epub",
            epubFilePath: "Books/book2.epub",
            importedAt: Date(timeIntervalSince1970: 2000)
        )

        store.addBook(book1)
        store.addBook(book2)

        XCTAssertEqual(store.books.first?.title, "Book 2", "Most recently imported book should be first")
        XCTAssertEqual(store.books.last?.title, "Book 1")
        XCTAssertEqual(store.sortedBooks.first?.title, "Book 2")
        XCTAssertEqual(store.sortedBooks.last?.title, "Book 1")
    }

    func testBooksSortedByTitleAscending() async throws {
        let store = AppStateStore()

        store.replaceBooks([
            makeBook(title: "Zulu", author: "Author C", importedAt: 1000),
            makeBook(title: "Alpha", author: "Author B", importedAt: 2000),
            makeBook(title: "Bravo", author: "Author A", importedAt: 3000)
        ])
        store.booksSortOption = .titleAscending

        XCTAssertEqual(store.sortedBooks.map(\.title), ["Alpha", "Bravo", "Zulu"])
    }

    func testBooksSortedByAuthorDescending() async throws {
        let store = AppStateStore()

        store.replaceBooks([
            makeBook(title: "Book 1", author: "Author A", importedAt: 1000),
            makeBook(title: "Book 2", author: "Author C", importedAt: 2000),
            makeBook(title: "Book 3", author: "Author B", importedAt: 3000)
        ])
        store.booksSortOption = .authorDescending

        XCTAssertEqual(store.sortedBooks.map(\.author), ["Author C", "Author B", "Author A"])
    }

    func testSortOptionPersistsAcrossStoreInstances() async throws {
        let store = AppStateStore()
        store.booksSortOption = .titleDescending
        store.persistNow()

        let reloadedStore = AppStateStore()
        XCTAssertEqual(reloadedStore.booksSortOption, .titleDescending)
    }

    func testSortedBooksReflectUpdatedTitle() async throws {
        let store = AppStateStore()
        let alpha = makeBook(title: "Alpha", author: "Author A", importedAt: 1000)
        let bravo = makeBook(title: "Bravo", author: "Author B", importedAt: 2000)

        store.replaceBooks([alpha, bravo])
        store.booksSortOption = .titleAscending
        XCTAssertEqual(store.sortedBooks.map(\.title), ["Alpha", "Bravo"])

        bravo.title = "Aaron"

        XCTAssertEqual(store.sortedBooks.map(\.title), ["Aaron", "Alpha"])
    }

    func testDebouncedSave() async throws {
        // A burst of synchronous mutations must coalesce into a single disk
        // write. Before the CancellationError-guard fix, every cancelled save
        // task still wrote, producing one write per mutation.
        store.fontSize = 16
        store.fontSize = 18
        store.fontSize = 20
        store.lineHeight = 1.4
        store.playbackSpeed = 1.25

        // Wait past the 150ms debounce window (plus buffer).
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(
            store.test_diskWriteCount,
            1,
            "A burst of mutations should debounce into exactly one disk write"
        )
    }

    func testPersistNow() async throws {
        let book = Book(
            title: "Test Book",
            originalFilename: "test.epub",
            epubFilePath: "Books/test.epub"
        )

        store.addBook(book)
        store.persistNow()

        // The state file must exist on disk and decode with the added book.
        let stateURL = try AppStorage.stateURL()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stateURL.path),
            "persistNow must flush state to disk immediately"
        )

        let reloaded = AppStateStore()
        XCTAssertEqual(reloaded.books.map(\.title), ["Test Book"])
    }

    func testStateSurvivesMissingKeys() async throws {
        // Simulates upgrading from a build persisted before newer settings
        // keys existed: the books must survive, missing keys get defaults.
        let stateJSON = """
        {
            "books": [
                {
                    "id": "11111111-1111-1111-1111-111111111111",
                    "title": "Old Build Book",
                    "author": "Author",
                    "originalFilename": "old.epub",
                    "epubFilePath": "Books/old.epub",
                    "importedAt": 0
                }
            ],
            "customFontFamilies": [],
            "fontSize": 20,
            "lineHeight": 1.5,
            "fontFamilyRawValue": "Literata",
            "themeRawValue": "system",
            "readAloudColorRawValue": "#FFFF00",
            "playbackSpeed": 1,
            "playbackJumpInterval": 15
        }
        """
        try Data(stateJSON.utf8).write(to: AppStorage.stateURL())

        let reloadedStore = AppStateStore()
        XCTAssertEqual(reloadedStore.books.map(\.title), ["Old Build Book"])
        XCTAssertEqual(reloadedStore.fontSize, 20)
        XCTAssertEqual(reloadedStore.uploadServerPort, ReaderSettings.defaultUploadServerPort)
        XCTAssertEqual(reloadedStore.booksSortOption, .recentlyAdded)
    }

    func testStateSurvivesCorruptBookRecord() async throws {
        let stateJSON = """
        {
            "books": [
                {"id": "not-a-uuid", "title": 42},
                {
                    "id": "22222222-2222-2222-2222-222222222222",
                    "title": "Intact Book",
                    "author": "Author",
                    "originalFilename": "intact.epub",
                    "epubFilePath": "Books/intact.epub",
                    "importedAt": 0
                }
            ]
        }
        """
        try Data(stateJSON.utf8).write(to: AppStorage.stateURL())

        let reloadedStore = AppStateStore()
        XCTAssertEqual(reloadedStore.books.map(\.title), ["Intact Book"])
    }

    func testUnreadableStateIsBackedUpBeforeOverwriting() async throws {
        let stateURL = try AppStorage.stateURL()
        try Data("not json".utf8).write(to: stateURL)

        let reloadedStore = AppStateStore()
        XCTAssertTrue(reloadedStore.books.isEmpty)

        reloadedStore.fontSize = 30
        reloadedStore.persistNow()

        let cacheContents = try FileManager.default.contentsOfDirectory(
            at: stateURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        let backups = cacheContents.filter { $0.lastPathComponent.hasPrefix("state-corrupt-") }
        XCTAssertEqual(backups.count, 1, "Unreadable state file should be moved aside, not destroyed")
        XCTAssertEqual(try Data(contentsOf: backups[0]), Data("not json".utf8))
    }

    func testNonArrayBooksIsTreatedAsCorruptAndBackedUp() async throws {
        // A structurally wrong file (books present but not an array) must not
        // silently load zero books and then let the next save overwrite it.
        let stateURL = try AppStorage.stateURL()
        let stateJSON = Data(#"{"books": {"oops": true}, "fontSize": 20}"#.utf8)
        try stateJSON.write(to: stateURL)

        let reloadedStore = AppStateStore()
        XCTAssertTrue(reloadedStore.books.isEmpty)
        XCTAssertEqual(reloadedStore.fontSize, ReaderSettings.defaultFontSize, "Corrupt state must load defaults, not partial values")

        reloadedStore.persistNow()

        let backups = try FileManager.default.contentsOfDirectory(
            at: stateURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("state-corrupt-") }
        XCTAssertEqual(backups.count, 1, "Non-array books must be backed up before defaults overwrite it")
        XCTAssertEqual(try Data(contentsOf: backups[0]), stateJSON)
    }

    func testMinimalObjectLoadsDefaultsWithoutBackup() async throws {
        // A parseable object with no books key is a legitimately minimal state,
        // not corruption: load defaults, keep persisting, don't back anything up.
        let stateURL = try AppStorage.stateURL()
        try Data("{}".utf8).write(to: stateURL)

        let reloadedStore = AppStateStore()
        XCTAssertTrue(reloadedStore.books.isEmpty)
        XCTAssertNil(reloadedStore.persistenceFailure)

        reloadedStore.fontSize = 30
        reloadedStore.persistNow()

        let backups = try FileManager.default.contentsOfDirectory(
            at: stateURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("state-corrupt-") }
        XCTAssertTrue(backups.isEmpty, "A minimal {} state must not be treated as corrupt")

        let reReloaded = AppStateStore()
        XCTAssertEqual(reReloaded.fontSize, 30, "Saving must stay enabled after loading a minimal state")
    }

    func testUploadServerPasswordDefaultsToOff() {
        XCTAssertFalse(store.uploadServerRequiresPassword)
        XCTAssertEqual(store.uploadServerPassword, "")
    }

    func testUploadServerPasswordPersistsAcrossStoreInstances() async throws {
        store.uploadServerRequiresPassword = true
        store.uploadServerPassword = "mysecret"
        store.persistNow()

        let reloadedStore = AppStateStore()
        XCTAssertTrue(reloadedStore.uploadServerRequiresPassword)
        XCTAssertEqual(reloadedStore.uploadServerPassword, "mysecret")
    }

    func testUploadServerPasswordDefaultsWhenMissingFromPersistedState() async throws {
        // Simulate a state file written before the password fields were added.
        let stateJSON = """
        {
            "books": [],
            "customFontFamilies": [],
            "fontSize": 1.2,
            "lineHeight": 1.2,
            "fontFamilyRawValue": "Literata",
            "themeRawValue": "system",
            "readAloudColorRawValue": "#34C759",
            "readingBackgroundRawValue": "white",
            "playbackSpeed": 1.0,
            "playbackJumpInterval": 15.0,
            "uploadServerPort": 8080,
            "booksSortOptionRawValue": "recentlyAdded"
        }
        """
        try Data(stateJSON.utf8).write(to: AppStorage.stateURL())

        let reloadedStore = AppStateStore()
        XCTAssertFalse(reloadedStore.uploadServerRequiresPassword, "missing key should default to false")
        XCTAssertEqual(reloadedStore.uploadServerPassword, "", "missing key should default to empty string")
    }

    private func makeBook(title: String, author: String, importedAt: TimeInterval) -> Book {
        let filename = "\(title)-\(author).epub"
        return Book(
            title: title,
            author: author,
            originalFilename: filename,
            epubFilePath: AppStorage.storedBookPath(for: filename),
            importedAt: Date(timeIntervalSince1970: importedAt)
        )
    }
}
