//
//  BookImportServiceTests.swift
//  EPUB PlayerTests
//
//

import XCTest
@testable import EPUBPlayer

@MainActor
final class BookImportServiceTests: XCTestCase {
    var tempDirectory: URL!
    var store: AppStateStore!

    override func setUp() async throws {
        try await super.setUp()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        store = AppStateStore()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    func testImportNonEPUBFails() async throws {
        // Create a non-EPUB file
        let textFileURL = tempDirectory.appendingPathComponent("test.txt")
        try "Test content".write(to: textFileURL, atomically: true, encoding: .utf8)

        do {
            _ = try await BookImportService.importBook(from: textFileURL, store: store)
            XCTFail("Should have thrown BookImportError.notEpub")
        } catch let error as BookImportError {
            switch error {
            case .notEpub:
                // Expected error
                break
            default:
                XCTFail("Wrong error type: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testImportValidEPUB() async throws {
        // This test would require creating a valid EPUB file
        // Placeholder for valid EPUB import test

        // Test that:
        // - Book is added to store
        // - EPUB file is copied to Books directory
        // - Cover is extracted
        // - Media overlays are parsed if present
        // - Book metadata is correctly populated
    }

    func testImportCleanupOnFailure() async throws {
        // Test that orphaned files are cleaned up when import fails
        // This requires mocking the import process to fail after files are created

        // Test that:
        // - EPUB file is removed on failure
        // - Cover image is removed on failure
        // - Media overlay JSON is removed on failure
        // - Audio cache directory is removed on failure
    }

    func testImportWithExistingBook() async throws {
        // Test skip strategy
        // Test overwrite strategy

        // Test that:
        // - Skip strategy returns nil when book exists
        // - Overwrite strategy replaces existing book
        // - Book ID is preserved on overwrite
    }

    func testRefreshBooksFromDocuments() async throws {
        // Test that:
        // - New EPUBs in Documents/Books are imported
        // - Missing EPUBs are removed from library
        // - Existing EPUBs are preserved
        // - Progress handler is called appropriately
    }

    func testProgressReporting() async throws {
        // Test that progress handler is called with appropriate values
        // Test that progress goes from 0 to 1
        // Test that progress messages are meaningful
    }
}
