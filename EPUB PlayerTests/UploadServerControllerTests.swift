//
//  UploadServerControllerTests.swift
//  EPUB PlayerTests
//

import XCTest
@testable import EPUBPlayer

@MainActor
final class UploadServerControllerTests: XCTestCase {
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

    /// `stop()` used to cancel the import task without releasing the handle.
    /// `startImportProcessing` treats a non-nil handle as "already running", so
    /// an upload enqueued while the cancelled task was still unwinding was
    /// queued and never processed.
    func testStopReleasesImportTaskSoLaterEnqueueStartsProcessing() async throws {
        let controller = UploadServerController()
        // A path that does not exist: the import fails fast without touching
        // the library, which is all this state-machine test needs.
        let missingEPUB = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).epub", isDirectory: false)

        controller.importBooks(from: [missingEPUB], store: store)
        XCTAssertTrue(controller.test_hasImportTask, "Enqueueing must start an import task")

        controller.stop()
        XCTAssertFalse(controller.test_hasImportTask, "stop() must release the import task handle")

        controller.importBooks(from: [missingEPUB], store: store)
        XCTAssertTrue(controller.test_hasImportTask, "A fresh enqueue after stop() must start a new task")

        var attempts = 0
        while controller.test_hasImportTask, attempts < 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            attempts += 1
        }
        XCTAssertFalse(controller.test_hasImportTask, "The new task must finish and release its handle")
        XCTAssertNotNil(controller.manualImportErrorMessage, "The second import must actually have been processed")
        XCTAssertFalse(controller.isImportingBooks)
    }
}
