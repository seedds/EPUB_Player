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
        await MediaOverlayPreparationCoordinator.shared.test_cancelAllPreparations()
        store = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        TestDocumentsDirectory.deactivate(rootURL: tempDocumentsDirectory)
        tempDirectory = nil
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

    func testImportHonorsCancellation() async throws {
        let sourceURL = try makeEPUBFile(named: "cancel.epub", title: "Cancelled Book")
        let store = self.store!

        let task = Task { @MainActor in
            try await BookImportService.importBook(
                from: sourceURL,
                filename: "cancel.epub",
                store: store
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled import should throw")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(store.books.isEmpty, "A cancelled import must not add a book")
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

    private func makeEPUBFileWithCover(named filename: String, title: String, coverBytes: [UInt8]) throws -> URL {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>\(title)</dc:title>
            <dc:creator>Test Author</dc:creator>
            <dc:identifier id="uid">test-\(title)</dc:identifier>
          </metadata>
          <manifest>
            <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
            <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="chapter1"/>
          </spine>
        </package>
        """
        let epub = ZIPFixtureBuilder.makeEPUB(entries: [
            ZIPFixtureEntry(name: "OEBPS/content.opf", data: Data(opf.utf8)),
            ZIPFixtureEntry(name: "OEBPS/chapter1.xhtml", data: Data("<html/>".utf8)),
            ZIPFixtureEntry(name: "OEBPS/cover.png", data: Data(coverBytes))
        ])
        let url = tempDirectory.appendingPathComponent(filename, isDirectory: false)
        try epub.write(to: url)
        return url
    }

    private func makeEPUBFileWithMalformedOPF(named filename: String) throws -> URL {
        // Valid mimetype + container so validateEPUB passes, but a truncated OPF
        // that cannot be parsed into a manifest.
        let malformedOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest>
            <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
        """
        let epub = ZIPFixtureBuilder.makeEPUB(entries: [
            ZIPFixtureEntry(name: "OEBPS/content.opf", data: Data(malformedOPF.utf8)),
            ZIPFixtureEntry(name: "OEBPS/chapter1.xhtml", data: Data("<html/>".utf8))
        ])
        let url = tempDirectory.appendingPathComponent(filename, isDirectory: false)
        try epub.write(to: url)
        return url
    }

    // MARK: - Malformed OPF must not prune positions on reimport (#6.4)

    func testReimportWithUnparseableOPFPreservesBookmarks() async throws {
        let firstURL = try makeEPUBFile(named: "bm.epub", title: "First")
        let firstImport = try await BookImportService.importBook(from: firstURL, filename: "bm.epub", store: store)
        let original = try XCTUnwrap(firstImport)
        original.bookmarks = [Bookmark(textResourceHref: "chapter1.xhtml", fragmentID: "p1")]

        // Reimport with content whose OPF cannot be parsed: we cannot know the
        // manifest, so bookmarks must be preserved rather than pruned to empty.
        let replacementURL = try makeEPUBFileWithMalformedOPF(named: "bm2.epub")
        let replacedImport = try await BookImportService.importBook(
            from: replacementURL,
            filename: "bm.epub",
            store: store,
            existingBookStrategy: .overwrite
        )

        let overwritten = try XCTUnwrap(replacedImport)
        XCTAssertEqual(
            overwritten.bookmarks.count,
            1,
            "A reimport whose OPF failed to parse must not prune bookmarks against an empty manifest"
        )
    }

    // MARK: - Staged-file leak (#11a)

    func testRemoveStalePartialImportsReclaimsOrphanedStagingFiles() throws {
        let booksDirectory = try AppStorage.booksDirectory()

        // A dot-prefixed staging file orphaned by a crashed/cancelled import.
        // Backdated: a fresh staging file is presumed to belong to a live
        // import and must be spared (see
        // testStalePartialImportSweepSparesFreshStagingFiles).
        let orphan = booksDirectory.appendingPathComponent(
            "\(BookImportService.stagedImportPrefix)\(UUID().uuidString)-book.epub",
            isDirectory: false
        )
        try Data("partial".utf8).write(to: orphan)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: orphan.path
        )

        // A real book file that must be left untouched.
        let realBook = booksDirectory.appendingPathComponent("real.epub", isDirectory: false)
        try Data("epub".utf8).write(to: realBook)

        BookImportService.removeStalePartialImports()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path),
            "Stale .import-* staging files must be reclaimed"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: realBook.path),
            "Real EPUB files must not be swept"
        )
    }

    // MARK: - Refresh must never silently destroy the library

    /// The library directory going missing is not evidence that the user
    /// deleted their books — `booksDirectory()` recreates it on demand, so a
    /// data-protection eviction or a Files-app move produces an empty scan
    /// that previously looked authoritative and wiped every record.
    func testRefreshWithVanishedBooksDirectoryPreservesLibrary() async throws {
        let first = try makeEPUBFile(named: "keeper-one.epub", title: "Keeper One")
        let second = try makeEPUBFile(named: "keeper-two.epub", title: "Keeper Two")
        _ = try await BookImportService.importBook(from: first, filename: "keeper-one.epub", store: store)
        _ = try await BookImportService.importBook(from: second, filename: "keeper-two.epub", store: store)
        XCTAssertEqual(store.books.count, 2)

        // Remove the whole directory: the next booksDirectory() call recreates
        // it empty, so the scan succeeds and returns nothing.
        try FileManager.default.removeItem(at: try AppStorage.booksDirectory())

        do {
            _ = try await BookImportService.refreshBooksFromDocuments(store: store)
            XCTFail("Refresh must refuse to wipe a non-empty library it cannot verify")
        } catch let error as BookImportError {
            guard case .libraryFilesUnavailable = error else {
                return XCTFail("Wrong error: \(error)")
            }
        }

        XCTAssertEqual(
            store.books.count,
            2,
            "Refresh destroyed the library when the books directory vanished"
        )
    }

    /// The genuine case must still work: when the user really has deleted
    /// their books, refresh should prune the stale records.
    func testRefreshRemovesRecordsWhenFilesAreGenuinelyDeleted() async throws {
        let url = try makeEPUBFile(named: "doomed.epub", title: "Doomed")
        _ = try await BookImportService.importBook(from: url, filename: "doomed.epub", store: store)
        XCTAssertEqual(store.books.count, 1)

        // Delete the file but leave the directory in place — an ordinary
        // user-initiated deletion.
        let booksDirectory = try AppStorage.booksDirectory()
        for file in try FileManager.default.contentsOfDirectory(at: booksDirectory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }

        _ = try await BookImportService.refreshBooksFromDocuments(store: store)

        XCTAssertTrue(
            store.books.isEmpty,
            "Refresh must still prune records whose files the user really deleted"
        )
    }

    /// A partial disappearance must not take the surviving books with it.
    func testRefreshKeepsSurvivingBooksWhenSomeFilesAreDeleted() async throws {
        let first = try makeEPUBFile(named: "survivor.epub", title: "Survivor")
        let second = try makeEPUBFile(named: "casualty.epub", title: "Casualty")
        _ = try await BookImportService.importBook(from: first, filename: "survivor.epub", store: store)
        _ = try await BookImportService.importBook(from: second, filename: "casualty.epub", store: store)

        let booksDirectory = try AppStorage.booksDirectory()
        try FileManager.default.removeItem(
            at: booksDirectory.appendingPathComponent("casualty.epub", isDirectory: false)
        )

        _ = try await BookImportService.refreshBooksFromDocuments(store: store)

        XCTAssertEqual(store.books.map(\.title), ["Survivor"])
    }

    /// Two genuinely different books that happen to share a filename. Filename
    /// is the identity key for re-import, so the second overwrites the first
    /// rather than creating a second record. Pinning that here because the
    /// alternative -- two records over one file -- is silent data loss.
    func testImportingDifferentBooksWithTheSameFilename() async throws {
        let firstSource = tempDirectory.appendingPathComponent("a", isDirectory: true)
        let secondSource = tempDirectory.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: firstSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSource, withIntermediateDirectories: true)

        let firstURL = try makeEPUBFile(named: "shared.epub", title: "First Book")
        let movedFirst = firstSource.appendingPathComponent("shared.epub")
        try FileManager.default.moveItem(at: firstURL, to: movedFirst)

        let secondURL = try makeEPUBFile(named: "shared.epub", title: "Second Book")
        let movedSecond = secondSource.appendingPathComponent("shared.epub")
        try FileManager.default.moveItem(at: secondURL, to: movedSecond)

        _ = try await BookImportService.importBook(from: movedFirst, filename: "shared.epub", store: store)
        _ = try await BookImportService.importBook(
            from: movedSecond,
            filename: "shared.epub",
            store: store,
            existingBookStrategy: .overwrite
        )

        XCTAssertEqual(store.books.map(\.title), ["Second Book"])

        // Every record must point at a file that exists, and no two records may
        // share a backing file.
        var seenPaths: Set<String> = []
        for book in store.books {
            let url = try book.resolvedEPUBFileURL()
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "\(book.title) points at a missing file"
            )
            XCTAssertTrue(
                seenPaths.insert(url.standardizedFileURL.path).inserted,
                "Two library records share the backing file \(url.lastPathComponent)"
            )
        }
    }

    /// Uploads import while the user pulls to refresh. The scan can see a
    /// committed file before its Book record exists, which would import it a
    /// second time under a fresh UUID and leave a duplicate.
    func testConcurrentImportAndRefreshProduceNoDuplicates() async throws {
        let existing = try makeEPUBFile(named: "settled.epub", title: "Settled")
        _ = try await BookImportService.importBook(from: existing, filename: "settled.epub", store: store)

        let incoming = try makeEPUBFile(named: "incoming.epub", title: "Incoming")
        let store = self.store!

        async let importResult: Void = {
            _ = try? await BookImportService.importBook(
                from: incoming,
                filename: "incoming.epub",
                store: store
            )
        }()
        async let refreshResult: Void = {
            _ = try? await BookImportService.refreshBooksFromDocuments(store: store)
        }()
        _ = await (importResult, refreshResult)

        let filenames = store.books.map(\.originalFilename).sorted()
        XCTAssertEqual(
            filenames,
            ["incoming.epub", "settled.epub"],
            "Overlapping import and refresh produced \(filenames)"
        )

        let ids = Set(store.books.map(\.id))
        XCTAssertEqual(ids.count, store.books.count, "Duplicate book records created")
    }

    /// The sweep must not delete staging files belonging to a live import.
    /// An uploaded source is *moved* into staging, so deleting the staging file
    /// mid-import destroys the user's only copy of the upload.
    func testStalePartialImportSweepSparesFreshStagingFiles() async throws {
        let booksDirectory = try AppStorage.booksDirectory()
        let inFlight = booksDirectory.appendingPathComponent(
            "\(BookImportService.stagedImportPrefix)\(UUID().uuidString)-in-flight.epub",
            isDirectory: false
        )
        try Data("staged moments ago".utf8).write(to: inFlight)

        BookImportService.removeStalePartialImports()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: inFlight.path),
            "The sweep deleted a staging file that a live import still needs"
        )
    }

    /// Genuinely orphaned staging files must still be reclaimed.
    func testStalePartialImportSweepRemovesOldStagingFiles() async throws {
        let booksDirectory = try AppStorage.booksDirectory()
        let orphan = booksDirectory.appendingPathComponent(
            "\(BookImportService.stagedImportPrefix)\(UUID().uuidString)-orphan.epub",
            isDirectory: false
        )
        try Data("left by a crash".utf8).write(to: orphan)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: orphan.path
        )

        BookImportService.removeStalePartialImports()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path),
            "An hour-old staging file is an orphan and must be reclaimed"
        )
    }

    func testRefreshSweepsOrphanedStagingFiles() async throws {
        let booksDirectory = try AppStorage.booksDirectory()
        let orphan = booksDirectory.appendingPathComponent(
            "\(BookImportService.stagedImportPrefix)\(UUID().uuidString)-ghost.epub",
            isDirectory: false
        )
        try Data("partial".utf8).write(to: orphan)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: orphan.path
        )

        _ = try await BookImportService.refreshBooksFromDocuments(store: store)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphan.path),
            "A refresh must sweep orphaned staging files that the hidden-file-skipping scan cannot see"
        )
    }

    func testCancelledImportLeavesNoStagedFiles() async throws {
        // A cancellation can land at various points; whichever window it hits,
        // no dot-prefixed staging file may survive in the library.
        let sourceURL = try makeEPUBFile(named: "cancel-leak.epub", title: "Cancelled")
        let store = self.store!

        let task = Task { @MainActor in
            try await BookImportService.importBook(from: sourceURL, filename: "cancel-leak.epub", store: store)
        }
        task.cancel()
        _ = try? await task.value

        let booksDirectory = try AppStorage.booksDirectory()
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: booksDirectory.path)) ?? []
        let stagedLeftovers = leftovers.filter { $0.hasPrefix(BookImportService.stagedImportPrefix) }
        XCTAssertTrue(stagedLeftovers.isEmpty, "A cancelled import must not leak staged files: \(stagedLeftovers)")
    }

    // MARK: - Overwrite-safe cover staging (#11b)

    func testStagedCoverDoesNotTouchExistingCoverUntilCommit() throws {
        let bookID = UUID()
        let existing = try BookAssetCacheService.cacheCoverImage(
            asset: EPUBArchiveAsset(path: "old.png", mediaType: "image/png", data: Data([1, 2, 3])),
            for: bookID
        )
        let existingURL = try AppStorage.coversDirectory().appendingPathComponent(existing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingURL.path))

        // Staging a new cover must NOT remove or overwrite the existing one.
        let staged = try BookAssetCacheService.cacheStagedCoverImage(
            asset: EPUBArchiveAsset(path: "new.png", mediaType: "image/png", data: Data([4, 5, 6])),
            for: bookID
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingURL.path), "Existing cover must survive staging")
        XCTAssertNotEqual(staged, existing)

        // Simulate a failed import: removing the staged cover leaves the original.
        BookAssetCacheService.removeStagedCover(stagedFilename: staged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingURL.path), "Failed import must not disturb the existing cover")
        let stagedURL = try AppStorage.coversDirectory().appendingPathComponent(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path), "Staged cover must be cleaned up on failure")
    }

    func testCommitStagedCoverReplacesPriorCover() throws {
        let bookID = UUID()
        let old = try BookAssetCacheService.cacheCoverImage(
            asset: EPUBArchiveAsset(path: "old.png", mediaType: "image/png", data: Data([1, 2, 3])),
            for: bookID
        )
        let staged = try BookAssetCacheService.cacheStagedCoverImage(
            asset: EPUBArchiveAsset(path: "new.png", mediaType: "image/png", data: Data([9, 9, 9])),
            for: bookID
        )

        let final = try BookAssetCacheService.commitStagedCover(stagedFilename: staged, for: bookID)
        let finalURL = try AppStorage.coversDirectory().appendingPathComponent(final)

        XCTAssertEqual(try Data(contentsOf: finalURL), Data([9, 9, 9]), "Commit must promote the new cover bytes")
        // Only one cover file for the book should remain (old + staged collapsed).
        let coversDir = try AppStorage.coversDirectory()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: coversDir.path)
            .filter { $0.hasPrefix(bookID.uuidString) }
        XCTAssertEqual(remaining, [final], "Commit must leave exactly the final cover; got \(remaining)")
        XCTAssertNotEqual(old, staged)
    }

    func testOverwriteImportReplacesCoverAndLeavesNoStagedFiles() async throws {
        let firstURL = try makeEPUBFileWithCover(named: "cover.epub", title: "First", coverBytes: [0x89, 0x50, 0x4E, 0x47, 1])
        let firstImport = try await BookImportService.importBook(from: firstURL, filename: "cover.epub", store: store)
        let first = try XCTUnwrap(firstImport)
        let firstCover = try XCTUnwrap(first.coverImagePath)
        let firstCoverURL = try XCTUnwrap(try first.resolvedCoverImageURL())
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstCoverURL.path))

        let replacementURL = try makeEPUBFileWithCover(named: "cover2.epub", title: "Second", coverBytes: [0x89, 0x50, 0x4E, 0x47, 2, 3])
        let replacedImport = try await BookImportService.importBook(
            from: replacementURL,
            filename: "cover.epub",
            store: store,
            existingBookStrategy: .overwrite
        )
        let replaced = try XCTUnwrap(replacedImport)

        XCTAssertEqual(replaced.id, first.id)
        let newCoverURL = try XCTUnwrap(try replaced.resolvedCoverImageURL())
        XCTAssertTrue(FileManager.default.fileExists(atPath: newCoverURL.path), "Overwrite must leave a valid cover")

        // No `.import-` staged cover files may linger after a successful commit.
        let coversDir = try AppStorage.coversDirectory()
        let staged = try FileManager.default.contentsOfDirectory(atPath: coversDir.path)
            .filter { $0.contains(".import-") }
        XCTAssertTrue(staged.isEmpty, "Committed import must not leave staged cover files: \(staged)")
        XCTAssertNotNil(firstCover)
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
        let originalGeneration = original.contentGeneration
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
        XCTAssertNotEqual(overwritten.contentGeneration, originalGeneration, "Overwrite must begin a new content generation")
        XCTAssertEqual(overwritten.title, "Second Edition")
        XCTAssertNil(overwritten.lastLocatorJSON, "Positions saved against the old content are invalid")
        XCTAssertEqual(store.books.count, 1)
    }

    func testReimportPreservesResumePositionWhenResourceStillExists() async throws {
        let firstURL = try makeEPUBFile(named: "keep.epub", title: "First Edition")
        let firstImport = try await BookImportService.importBook(from: firstURL, filename: "keep.epub", store: store)
        let original = try XCTUnwrap(firstImport)
        // A resume position pointing at a resource that survives reimport.
        original.lastLocatorJSON = #"{"href":"OEBPS/chapter1.xhtml","type":"application/xhtml+xml"}"#

        let replacementURL = try makeEPUBFile(named: "keep2.epub", title: "Second Edition", extraEntry: "OEBPS/extra.txt")
        let replaced = try await BookImportService.importBook(
            from: replacementURL,
            filename: "keep.epub",
            store: store,
            existingBookStrategy: .overwrite
        )

        let overwritten = try XCTUnwrap(replaced)
        XCTAssertEqual(overwritten.id, original.id)
        XCTAssertEqual(overwritten.title, "Second Edition")
        XCTAssertNotNil(
            overwritten.lastLocatorJSON,
            "A resume position whose resource still exists must be preserved across reimport"
        )
    }

    func testReimportDropsBookmarkForRemovedResourceAndKeepsSurviving() async throws {
        let firstURL = try makeEPUBFile(named: "marks.epub", title: "First Edition")
        let firstImport = try await BookImportService.importBook(from: firstURL, filename: "marks.epub", store: store)
        let original = try XCTUnwrap(firstImport)
        original.bookmarks = [
            Bookmark(textResourceHref: "chapter1.xhtml", fragmentID: "p1"),
            Bookmark(textResourceHref: "deleted.xhtml", fragmentID: "p2"),
        ]

        let replacementURL = try makeEPUBFile(named: "marks2.epub", title: "Second Edition", extraEntry: "OEBPS/extra.txt")
        let replaced = try await BookImportService.importBook(
            from: replacementURL,
            filename: "marks.epub",
            store: store,
            existingBookStrategy: .overwrite
        )

        let overwritten = try XCTUnwrap(replaced)
        XCTAssertEqual(overwritten.bookmarks.count, 1)
        XCTAssertEqual(overwritten.bookmarks.first?.textResourceHref, "chapter1.xhtml")
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
