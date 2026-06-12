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
    var tempDocumentsDirectory: URL!
    var store: AppStateStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDocumentsDirectory = try TestDocumentsDirectory.activate()

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        store = AppStateStore()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        TestDocumentsDirectory.deactivate(rootURL: tempDocumentsDirectory)
        tempDocumentsDirectory = nil
        try await super.tearDown()
    }

    func testImportNonEPUBFails() async throws {
        // Create a non-EPUB file
        let textFileURL = tempDirectory.appendingPathComponent("test.txt")
        try "Test content".write(to: textFileURL, atomically: true, encoding: .utf8)

        do {
            _ = try await BookImportService.importBook(
                from: textFileURL,
                filename: textFileURL.lastPathComponent,
                store: store
            )
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

    private func makeEPUBFile(named filename: String, title: String, extraEntry: String? = nil) throws -> URL {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(title)</dc:title>
            <dc:creator>Test Author</dc:creator>
            <dc:identifier id="uid">test-\(title)</dc:identifier>
          </metadata>
          <manifest>
            <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="chapter1"/>
          </spine>
        </package>
        """
        var entries = [
            ZIPFixtureEntry(name: "OEBPS/content.opf", data: Data(opf.utf8)),
            ZIPFixtureEntry(name: "OEBPS/chapter1.xhtml", data: Data("<html/>".utf8))
        ]
        if let extraEntry {
            entries.append(ZIPFixtureEntry(name: extraEntry, data: Data("padding".utf8)))
        }
        let epub = ZIPFixtureBuilder.makeEPUB(entries: entries)
        let url = tempDirectory.appendingPathComponent(filename, isDirectory: false)
        try epub.write(to: url)
        return url
    }

    func testImportValidEPUB() async throws {
        let sourceURL = try makeEPUBFile(named: "valid.epub", title: "A Real Book")

        let book = try await BookImportService.importBook(
            from: sourceURL,
            filename: "valid.epub",
            store: store
        )

        let imported = try XCTUnwrap(book)
        XCTAssertEqual(imported.title, "A Real Book")
        XCTAssertEqual(imported.author, "Test Author")
        XCTAssertEqual(store.books.count, 1)
        let libraryFileURL = try imported.resolvedEPUBFileURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryFileURL.path))
    }

    func testImportCleanupOnFailure() async throws {
        // Has the .epub extension but is not a valid archive, so the import
        // fails after the source file has already been staged in the library.
        let badURL = tempDirectory.appendingPathComponent("broken.epub", isDirectory: false)
        try Data("definitely not a zip".utf8).write(to: badURL)

        do {
            _ = try await BookImportService.importBook(from: badURL, filename: "broken.epub", store: store)
            XCTFail("Importing an invalid archive should throw")
        } catch {
            // expected
        }

        XCTAssertTrue(store.books.isEmpty)
        let booksDirectory = try AppStorage.booksDirectory()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: booksDirectory.path)
        XCTAssertTrue(leftovers.isEmpty, "A failed import must not leave staged files in the library: \(leftovers)")
    }

    func testImportWithExistingBook() async throws {
        let firstURL = try makeEPUBFile(named: "book.epub", title: "First Edition")
        let firstImport = try await BookImportService.importBook(from: firstURL, filename: "book.epub", store: store)
        let original = try XCTUnwrap(firstImport)
        original.lastLocatorJSON = "{\"href\":\"/old\"}"

        // Skip strategy: re-importing the same unchanged file returns nil.
        let skipped = try await BookImportService.importBook(
            from: firstURL,
            filename: "book.epub",
            store: store,
            existingBookStrategy: .skip
        )
        XCTAssertNil(skipped)
        XCTAssertEqual(store.books.count, 1)

        // Overwrite strategy with different content: same ID, new metadata,
        // and the stale reading position from the old content is cleared.
        let replacementURL = try makeEPUBFile(named: "book3.epub", title: "Second Edition", extraEntry: "OEBPS/extra.txt")
        let replaced = try await BookImportService.importBook(
            from: replacementURL,
            filename: "book.epub",
            store: store,
            existingBookStrategy: .overwrite
        )

        let overwritten = try XCTUnwrap(replaced)
        XCTAssertEqual(overwritten.id, original.id, "Overwrite must preserve the book's identity")
        XCTAssertEqual(overwritten.title, "Second Edition")
        XCTAssertNil(overwritten.lastLocatorJSON, "Positions saved against the old content are invalid")
        XCTAssertEqual(store.books.count, 1)
    }

    func testRefreshBooksFromDocuments() async throws {
        let booksDirectory = try AppStorage.booksDirectory()

        // A new EPUB dropped directly into Documents/Books.
        let directURL = try makeEPUBFile(named: "direct.epub", title: "Dropped In")
        try FileManager.default.copyItem(
            at: directURL,
            to: booksDirectory.appendingPathComponent("direct.epub", isDirectory: false)
        )

        // A book record whose file no longer exists.
        let ghost = Book(
            title: "Ghost Book",
            originalFilename: "ghost.epub",
            epubFilePath: AppStorage.storedBookPath(for: "ghost.epub")
        )
        store.addBook(ghost)

        // A broken file must be skipped without aborting the refresh.
        try Data("not a zip".utf8).write(
            to: booksDirectory.appendingPathComponent("broken.epub", isDirectory: false)
        )

        let refreshed = try await BookImportService.refreshBooksFromDocuments(store: store)

        XCTAssertEqual(refreshed.map(\.title), ["Dropped In"])
        XCTAssertEqual(store.books.map(\.title), ["Dropped In"], "Missing book removed, new book imported, broken file skipped")
    }

    func testProgressReporting() async throws {
        let sourceURL = try makeEPUBFile(named: "progress.epub", title: "Progress Book")

        final class ProgressLog: @unchecked Sendable {
            var fractions: [Double] = []
        }
        let log = ProgressLog()

        _ = try await BookImportService.importBook(
            from: sourceURL,
            filename: "progress.epub",
            store: store
        ) { @MainActor progress in
            log.fractions.append(progress.fractionCompleted)
        }

        XCTAssertFalse(log.fractions.isEmpty)
        XCTAssertTrue(log.fractions.allSatisfy { (0...1).contains($0) })
        XCTAssertEqual(log.fractions.last, 1, "Progress must finish at 1")
        XCTAssertEqual(log.fractions, log.fractions.sorted(), "Progress must not move backwards")
    }
}
