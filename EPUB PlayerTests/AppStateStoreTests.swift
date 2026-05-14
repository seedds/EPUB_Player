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
        // Change multiple properties rapidly
        store.fontSize = 16
        store.fontSize = 18
        store.fontSize = 20

        // Wait for debounce period (150ms + buffer)
        try await Task.sleep(nanoseconds: 200_000_000)

        // Verify save was called (would need to mock file system to verify)
        // This is a placeholder for actual persistence testing
    }

    func testPersistNow() async throws {
        let book = Book(
            title: "Test Book",
            originalFilename: "test.epub",
            epubFilePath: "Books/test.epub"
        )

        store.addBook(book)
        store.persistNow()

        // Verify immediate save (would need to check file system)
        // This is a placeholder for actual persistence testing
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
