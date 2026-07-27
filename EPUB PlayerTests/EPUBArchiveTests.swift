//
//  EPUBArchiveTests.swift
//  EPUB PlayerTests
//
//  Contract tests for the ZIP layer. These define the behavior any archive
//  implementation must preserve: EPUB validation, entry reads, legacy name
//  encodings, EOCD edge cases, and path-traversal safety on extraction.
//

import XCTest
@testable import EPUBPlayer

final class EPUBArchiveTests: XCTestCase {
    func testValidEPUBOpensAndReadsEntries() async throws {
        let chapter = Data("<html><body>hello</body></html>".utf8)
        let epub = ZIPFixtureBuilder.makeEPUB(entries: [
            ZIPFixtureEntry(name: "OEBPS/chapter1.xhtml", data: chapter)
        ])
        let url = try ZIPFixtureBuilder.write(epub, named: "valid.epub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let archive = try await EPUBArchive(url: url)
        try await archive.validateEPUB()
        let containsChapter = await archive.containsEntry(at: "OEBPS/chapter1.xhtml")
        XCTAssertTrue(containsChapter)
        let containsMissing = await archive.containsEntry(at: "OEBPS/missing.xhtml")
        XCTAssertFalse(containsMissing)
        let chapterData = try await archive.data(for: "OEBPS/chapter1.xhtml")
        XCTAssertEqual(chapterData, chapter)
        let missingData = try await archive.data(for: "OEBPS/missing.xhtml")
        XCTAssertNil(missingData)
    }

    func testMissingMimetypeFailsValidation() async throws {
        let archive = ZIPFixtureBuilder.makeArchive(entries: [
            ZIPFixtureEntry(name: "META-INF/container.xml", data: Data("<container/>".utf8)),
            ZIPFixtureEntry(name: "OEBPS/chapter1.xhtml", data: Data("<html/>".utf8))
        ])
        let url = try ZIPFixtureBuilder.write(archive, named: "nomimetype.epub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let opened = try await EPUBArchive(url: url)
        do {
            try await opened.validateEPUB()
            XCTFail("Validation must fail without a mimetype entry")
        } catch {
            // expected
        }
    }

    func testCP437EntryNameOpensArchive() async throws {
        // "caf" + 0x82 (CP437 'é'), UTF-8 flag unset — as written by legacy
        // Windows zip tools. 0x82 is not valid UTF-8, so a UTF-8-only decoder
        // rejects the whole archive.
        var nameBytes = Data("caf".utf8)
        nameBytes.append(0x82)
        nameBytes.append(contentsOf: Data(".txt".utf8))

        let content = Data("legacy".utf8)
        let archive = ZIPFixtureBuilder.makeArchive(entries: [
            ZIPFixtureEntry(name: "mimetype", data: Data("application/epub+zip".utf8)),
            ZIPFixtureEntry(name: "META-INF/container.xml", data: Data("<container/>".utf8)),
            ZIPFixtureEntry(nameBytes: nameBytes, data: content, utf8Flag: false)
        ])
        let url = try ZIPFixtureBuilder.write(archive, named: "cp437.epub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let opened = try await EPUBArchive(url: url)
        let entryData = try await opened.data(for: "café.txt")
        XCTAssertEqual(entryData, content)
    }

    func testArchiveWithPlainCommentOpens() async throws {
        // Archives with an ordinary trailing comment must still open.
        // (Known limitation inherited from ZIPFoundation: a comment that
        // itself embeds the EOCD signature bytes is rejected, because the
        // backward scan takes the first signature match.)
        let content = Data("payload".utf8)
        let archive = ZIPFixtureBuilder.makeArchive(
            entries: [ZIPFixtureEntry(name: "file.txt", data: content)],
            comment: Data("created by a legacy tool".utf8)
        )
        let url = try ZIPFixtureBuilder.write(archive, named: "comment.zip")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let opened = try await EPUBArchive(url: url)
        let entryData = try await opened.data(for: "file.txt")
        XCTAssertEqual(entryData, content)
    }

    func testExtractRejectsPathTraversalEntries() async throws {
        let epubData = ZIPFixtureBuilder.makeArchive(entries: [
            ZIPFixtureEntry(name: "mimetype", data: Data("application/epub+zip".utf8)),
            ZIPFixtureEntry(name: "META-INF/container.xml", data: Data("<container/>".utf8)),
            ZIPFixtureEntry(name: "../escape.txt", data: Data("evil".utf8))
        ])
        let url = try ZIPFixtureBuilder.write(epubData, named: "traversal.epub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let escapeTarget = destination.deletingLastPathComponent()
            .appendingPathComponent("escape.txt", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: escapeTarget) }

        let opened = try await EPUBArchive(url: url)
        do {
            try await opened.extract(to: destination)
            XCTFail("Extraction must reject path-traversal entry names")
        } catch {
            // expected
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: escapeTarget.path),
            "An entry named ../escape.txt must never be written outside the destination"
        )
    }

    // MARK: - Decompression limits

    /// A compression bomb declares a huge uncompressed size backed by a tiny
    /// compressed payload. `data(for:)` buffers a whole entry in memory, so
    /// without a ceiling a single uploaded EPUB can exhaust RAM.
    func testDataForRejectsEntryDeclaringOversizedContent() async throws {
        let epubData = ZIPFixtureBuilder.makeArchive(entries: [
            ZIPFixtureEntry(name: "mimetype", data: Data("application/epub+zip".utf8)),
            ZIPFixtureEntry(name: "META-INF/container.xml", data: Data("<container/>".utf8)),
            ZIPFixtureEntry(
                name: "OEBPS/bomb.xhtml",
                data: Data("small".utf8),
                declaredUncompressedSize: 900 * 1024 * 1024
            )
        ])
        let url = try ZIPFixtureBuilder.write(epubData, named: "bomb.epub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let opened = try await EPUBArchive(url: url)
        do {
            _ = try await opened.data(for: "OEBPS/bomb.xhtml")
            XCTFail("Reading an entry that declares 900 MB must be rejected")
        } catch {
            // expected
        }
    }

    /// Legitimate entries must stay readable — the cap has to sit above the
    /// largest thing the app actually reads through this path (audio clips).
    func testDataForAllowsNormallySizedEntry() async throws {
        let content = Data(repeating: 0x41, count: 512 * 1024)
        let epubData = ZIPFixtureBuilder.makeEPUB(entries: [
            ZIPFixtureEntry(name: "OEBPS/audio.mp3", data: content)
        ])
        let url = try ZIPFixtureBuilder.write(epubData, named: "normal.epub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let opened = try await EPUBArchive(url: url)
        let read = try await opened.data(for: "OEBPS/audio.mp3")
        XCTAssertEqual(read?.count, content.count)
    }

    /// Extraction must stop once the archive's declared contents exceed the
    /// budget, rather than filling the device's disk.
    func testExtractRejectsArchiveExceedingTotalSizeBudget() async throws {
        let epubData = ZIPFixtureBuilder.makeArchive(entries: [
            ZIPFixtureEntry(name: "mimetype", data: Data("application/epub+zip".utf8)),
            ZIPFixtureEntry(name: "META-INF/container.xml", data: Data("<container/>".utf8)),
            ZIPFixtureEntry(
                name: "OEBPS/huge.bin",
                data: Data("x".utf8),
                declaredUncompressedSize: 3 * 1024 * 1024 * 1024 - 1
            )
        ])
        let url = try ZIPFixtureBuilder.write(epubData, named: "hugetotal.epub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let opened = try await EPUBArchive(url: url)
        do {
            try await opened.extract(to: destination)
            XCTFail("Extraction must reject an archive declaring 3 GB of content")
        } catch {
            // expected
        }
    }

    /// A failed extraction must not leave a partial tree behind.
    func testExtractCleansUpAfterRejection() async throws {
        let epubData = ZIPFixtureBuilder.makeArchive(entries: [
            ZIPFixtureEntry(name: "mimetype", data: Data("application/epub+zip".utf8)),
            ZIPFixtureEntry(name: "META-INF/container.xml", data: Data("<container/>".utf8)),
            ZIPFixtureEntry(name: "OEBPS/ok.xhtml", data: Data("fine".utf8)),
            ZIPFixtureEntry(name: "../escape.txt", data: Data("evil".utf8))
        ])
        let url = try ZIPFixtureBuilder.write(epubData, named: "cleanup.epub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let opened = try await EPUBArchive(url: url)
        do {
            try await opened.extract(to: destination)
            XCTFail("Extraction must reject the traversal entry")
        } catch {
            // expected
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path),
            "A rejected extraction must not leave a partial tree behind"
        )
    }
}
