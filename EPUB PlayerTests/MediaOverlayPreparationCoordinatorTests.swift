//
//  MediaOverlayPreparationCoordinatorTests.swift
//  EPUB PlayerTests
//

import XCTest
@testable import EPUBPlayer

@MainActor
final class MediaOverlayPreparationCoordinatorTests: XCTestCase {
    private let coordinator = MediaOverlayPreparationCoordinator.shared

    override func setUp() async throws {
        try await super.setUp()
        // The coordinator is a singleton shared across suites; drain any
        // in-flight preparation from a prior suite so it can't mutate the task
        // map mid-test.
        await coordinator.test_cancelAllPreparations()
        coordinator.test_reset()
    }

    override func tearDown() async throws {
        await coordinator.test_cancelAllPreparations()
        coordinator.test_reset()
        try await super.tearDown()
    }

    /// Reproduces finding #11c: a task that was cancelled and superseded by a
    /// re-enqueue must not let its (deferred) cleanup remove the NEWER task's
    /// map entry — otherwise a subsequent enqueue would start a duplicate
    /// concurrent preparation.
    func testFinishedSupersededTaskDoesNotClearNewerEntry() {
        let bookID = UUID()

        // Task A is tracked, then cancel + re-enqueue replaces it with Task B.
        let taskA = coordinator.test_trackDummyTask(for: bookID)
        let taskB = coordinator.test_trackDummyTask(for: bookID) // overwrites entry with B

        // Task A now finishes and its defer fires with A's identity.
        coordinator.test_clearTaskEntryIfCurrent(for: bookID, task: taskA)

        XCTAssertTrue(
            coordinator.test_isTracked(bookID),
            "A superseded task's cleanup must not remove the newer task's entry"
        )
        _ = taskB
    }

    /// The current task's cleanup does clear its own entry.
    func testCurrentTaskClearsItsOwnEntry() {
        let bookID = UUID()
        let task = coordinator.test_trackDummyTask(for: bookID)

        coordinator.test_clearTaskEntryIfCurrent(for: bookID, task: task)

        XCTAssertFalse(
            coordinator.test_isTracked(bookID),
            "The current task's cleanup must clear its own map entry"
        )
    }

    func testStaleContentGenerationCannotPublishPreparationResult() {
        let store = AppStateStore()
        let originalGeneration = UUID()
        let book = Book(
            title: "Book",
            originalFilename: "book.epub",
            epubFilePath: "Books/book.epub",
            contentGeneration: originalGeneration
        )
        store.addBook(book)

        XCTAssertTrue(coordinator.test_isCurrentGeneration(originalGeneration, for: book.id, store: store))

        book.contentGeneration = UUID()

        XCTAssertFalse(
            coordinator.test_isCurrentGeneration(originalGeneration, for: book.id, store: store),
            "Preparation started for replaced content must not publish into the current book"
        )
    }
}
