//
//  BookTests.swift
//  EPUB PlayerTests
//

import XCTest
@testable import EPUBPlayer

@MainActor
final class BookTests: XCTestCase {
    func testRecordHistoryCollapsesConsecutiveDuplicateAndKeepsNewest() {
        let book = makeBook()
        let older = HistoryEntry(resourceHref: "chapter.xhtml", chapterProgress: 0.4, createdAt: Date(timeIntervalSince1970: 1))
        let newer = HistoryEntry(resourceHref: "chapter.xhtml", chapterProgress: 0.405, createdAt: Date(timeIntervalSince1970: 2))

        book.recordHistory(older, isSamePosition: sameHistoryPosition)
        book.recordHistory(newer, isSamePosition: sameHistoryPosition)

        XCTAssertEqual(book.history.count, 1)
        XCTAssertEqual(book.history.first?.id, newer.id)
    }

    func testRecordHistoryDropsPriorMatchingSameReasonBreadcrumb() {
        let book = makeBook()
        let origin = HistoryEntry(reason: "Jumped from", resourceHref: "chapter.xhtml", chapterProgress: 0.4)
        let destination = HistoryEntry(reason: "Played", resourceHref: "other.xhtml", chapterProgress: 0.9)
        let originAgain = HistoryEntry(reason: "Jumped from", resourceHref: "chapter.xhtml", chapterProgress: 0.4)

        book.recordHistory(origin, isSamePosition: sameHistoryPosition, dropPriorMatchingSameReason: true)
        book.recordHistory(destination, isSamePosition: sameHistoryPosition)
        book.recordHistory(originAgain, isSamePosition: sameHistoryPosition, dropPriorMatchingSameReason: true)

        // The earlier "Jumped from" for the same origin is removed even though a
        // "Played" entry sits between them; the newest breadcrumb remains.
        XCTAssertEqual(book.history.map(\.id), [originAgain.id, destination.id])
    }

    func testRecordHistoryKeepsBreadcrumbsForDifferentOrigins() {
        let book = makeBook()
        let first = HistoryEntry(reason: "Jumped from", resourceHref: "chapter.xhtml", chapterProgress: 0.4)
        let second = HistoryEntry(reason: "Jumped from", resourceHref: "chapter.xhtml", chapterProgress: 0.8)

        book.recordHistory(first, isSamePosition: sameHistoryPosition, dropPriorMatchingSameReason: true)
        book.recordHistory(second, isSamePosition: sameHistoryPosition, dropPriorMatchingSameReason: true)

        XCTAssertEqual(book.history.map(\.id), [second.id, first.id])
    }

    func testRecordHistoryCapsEntriesFromTheEnd() {
        let book = makeBook()

        for index in 0..<5 {
            book.recordHistory(
                HistoryEntry(resourceHref: "chapter\(index).xhtml", chapterProgress: Double(index)),
                limit: 3,
                isSamePosition: sameHistoryPosition
            )
        }

        XCTAssertEqual(book.history.count, 3)
        XCTAssertEqual(book.history.map(\.resourceHref), ["chapter4.xhtml", "chapter3.xhtml", "chapter2.xhtml"])
    }

    func testBookmarkMutatorsAddAndRemoveByID() {
        let book = makeBook()
        let first = Bookmark(resourceHref: "one.xhtml")
        let second = Bookmark(resourceHref: "two.xhtml")

        book.addBookmark(first)
        book.addBookmark(second)
        book.removeBookmark(id: first.id)

        XCTAssertEqual(book.bookmarks.map(\.id), [second.id])

        book.removeBookmarks(ids: [second.id])
        XCTAssertTrue(book.bookmarks.isEmpty)
    }

    func testLastPlayedClipMutatorsSetAndClearFields() {
        let book = makeBook()

        book.updateLastPlayedClip(
            textResourceHref: "chapter.xhtml",
            fragmentID: "p1",
            clipBegin: 1.2,
            clipEnd: 3.4
        )

        XCTAssertEqual(book.lastPlayedTextResourceHref, "chapter.xhtml")
        XCTAssertEqual(book.lastPlayedFragmentID, "p1")
        XCTAssertEqual(book.lastPlayedClipBegin, 1.2)
        XCTAssertEqual(book.lastPlayedClipEnd, 3.4)

        book.clearLastPlayedClip()

        XCTAssertNil(book.lastPlayedTextResourceHref)
        XCTAssertNil(book.lastPlayedFragmentID)
        XCTAssertNil(book.lastPlayedClipBegin)
        XCTAssertNil(book.lastPlayedClipEnd)
    }

    func testRenameStoredFilePreservesCustomTitle() {
        let book = makeBook(title: "Custom title", originalFilename: "Old.epub")

        book.renameStoredFile(
            to: "New.epub",
            storedPath: "Books/New.epub",
            displayTitle: displayTitle
        )

        XCTAssertEqual(book.title, "Custom title")
        XCTAssertEqual(book.originalFilename, "New.epub")
        XCTAssertEqual(book.epubFilePath, "Books/New.epub")
    }

    func testRenameStoredFileUpdatesDerivedTitle() {
        let book = makeBook(title: "Old", originalFilename: "Old.epub")

        book.renameStoredFile(
            to: "New.epub",
            storedPath: "Books/New.epub",
            displayTitle: displayTitle
        )

        XCTAssertEqual(book.title, "New")
    }

    func testContentGenerationRoundTripsThroughPersistence() throws {
        let generation = UUID()
        let book = Book(
            title: "Book",
            originalFilename: "Book.epub",
            epubFilePath: "Books/Book.epub",
            contentGeneration: generation
        )

        let decoded = try JSONDecoder().decode(Book.self, from: JSONEncoder().encode(book))

        XCTAssertEqual(decoded.contentGeneration, generation)
    }

    private func makeBook(
        title: String = "Book",
        originalFilename: String = "Book.epub"
    ) -> Book {
        Book(
            title: title,
            originalFilename: originalFilename,
            epubFilePath: "Books/\(originalFilename)"
        )
    }

    private func sameHistoryPosition(_ lhs: HistoryEntry, _ rhs: HistoryEntry) -> Bool {
        if lhs.textResourceHref != nil || rhs.textResourceHref != nil {
            return lhs.textResourceHref == rhs.textResourceHref &&
                lhs.fragmentID == rhs.fragmentID &&
                lhs.clipBegin == rhs.clipBegin &&
                lhs.clipEnd == rhs.clipEnd
        }

        return lhs.resourceHref == rhs.resourceHref &&
            abs((lhs.chapterProgress ?? 0) - (rhs.chapterProgress ?? 0)) <= 0.01
    }

    private func displayTitle(for filename: String) -> String {
        NSString(string: filename).deletingPathExtension
    }
}
