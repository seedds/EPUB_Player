//
//  AppStateStoreTests.swift
//  EPUB PlayerTests
//
//

import XCTest
@testable import EPUBPlayer

@MainActor
final class AppStateStoreTests: XCTestCase {
    var tempStateURL: URL!
    var originalStateURL: URL!

    override func setUp() async throws {
        try await super.setUp()

        // Create temporary state file location
        tempStateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        // Backup original state URL method if needed
        // Note: This requires making AppStorage.stateURL() configurable for testing
    }

    override func tearDown() async throws {
        // Clean up temp files
        try? FileManager.default.removeItem(at: tempStateURL)
        try await super.tearDown()
    }

    func testInitialState() async throws {
        let store = AppStateStore()

        XCTAssertTrue(store.books.isEmpty, "New store should have no books")
        XCTAssertTrue(store.customFontFamilies.isEmpty, "New store should have no custom fonts")
        XCTAssertEqual(store.fontSize, ReaderSettings.defaultFontSize)
        XCTAssertEqual(store.lineHeight, ReaderSettings.defaultLineHeight)
        XCTAssertEqual(store.autoRewindAfterBackgroundMinutes, ReaderSettings.defaultAutoRewindAfterBackgroundMinutes)
    }

    func testAutoRewindNormalization() {
        XCTAssertEqual(ReaderSettings.normalizedAutoRewindAfterBackgroundMinutes(1), 1)
        XCTAssertEqual(ReaderSettings.normalizedAutoRewindAfterBackgroundMinutes(3), 2)
        XCTAssertEqual(ReaderSettings.normalizedAutoRewindAfterBackgroundMinutes(6), 5)
        XCTAssertEqual(ReaderSettings.normalizedAutoRewindAfterBackgroundMinutes(99), 10)
    }

    func testAddBook() async throws {
        let store = AppStateStore()
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
        let store = AppStateStore()
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
        let store = AppStateStore()

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
    }

    func testDebouncedSave() async throws {
        let store = AppStateStore()

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
        let store = AppStateStore()
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
}
