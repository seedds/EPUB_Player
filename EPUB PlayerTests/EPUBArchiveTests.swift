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
}
