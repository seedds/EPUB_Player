//
//  DebugLogTests.swift
//  EPUB PlayerTests
//

import XCTest
@testable import EPUBPlayer

@MainActor
final class DebugLogTests: XCTestCase {
    private var tempDocumentsDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDocumentsDirectory = try TestDocumentsDirectory.activate()
    }

    override func tearDown() async throws {
        TestDocumentsDirectory.deactivate(rootURL: tempDocumentsDirectory)
        tempDocumentsDirectory = nil
        try await super.tearDown()
    }

    private func logFileSize() throws -> Int {
        let url = try AppStorage.cacheDirectory().appendingPathComponent("debug-log.txt", isDirectory: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? Int) ?? 0
    }

    /// The log file must stay bounded no matter how much is written. Without
    /// rotation it grew until it filled the device and made launch fail.
    func testFileStaysBoundedAcrossManyWrites() throws {
        let log = DebugLog(capacity: 50, maxFileBytes: 4096, tailReadBytes: 4096)

        for index in 0..<5000 {
            log.log("line \(index) with some padding to make the entry non-trivial")
        }

        let size = try logFileSize()
        // Bound is maxFileBytes plus at most one buffer's worth written since
        // the last rotation.
        XCTAssertLessThan(size, 4096 * 4, "Log file grew past its bound: \(size) bytes")
        XCTAssertEqual(log.entries.count, 50, "In-memory buffer must stay at capacity")
    }

    /// A pre-existing oversized file must not be read into memory whole.
    func testLoadReadsOnlyTailOfLargeFile() throws {
        let url = try AppStorage.cacheDirectory().appendingPathComponent("debug-log.txt", isDirectory: false)
        let line = String(repeating: "x", count: 99) + "\n"
        let contents = String(repeating: line, count: 20_000) // ~2 MB
        try Data(contents.utf8).write(to: url)

        let log = DebugLog(capacity: 100, maxFileBytes: 4096, tailReadBytes: 2048)

        XCTAssertLessThanOrEqual(log.entries.count, 100)
        XCTAssertFalse(log.entries.isEmpty, "Tail read should recover some lines")
        // 2048 bytes of tail can hold at most ~21 lines of 100 bytes.
        XCTAssertLessThan(log.entries.count, 30, "Read back more than the tail")
    }

    /// Rotation must preserve the most recent lines, not silently lose them.
    func testRotationKeepsMostRecentEntries() throws {
        let log = DebugLog(capacity: 10, maxFileBytes: 512, tailReadBytes: 4096)

        for index in 0..<500 {
            log.log("entry-\(index)")
        }

        XCTAssertEqual(log.entries.count, 10)
        XCTAssertTrue(
            log.entries.last?.contains("entry-499") == true,
            "Most recent entry missing after rotation: \(log.entries.last ?? "nil")"
        )

        // A fresh reader over the same file must see the retained tail.
        let reloaded = DebugLog(capacity: 10, maxFileBytes: 512, tailReadBytes: 4096)
        XCTAssertTrue(
            reloaded.entries.contains { $0.contains("entry-499") },
            "Rotated file lost the most recent entry"
        )
    }

    func testClearTruncatesFile() throws {
        let log = DebugLog(capacity: 100, maxFileBytes: 1_000_000, tailReadBytes: 4096)
        for index in 0..<200 {
            log.log("entry-\(index)")
        }
        XCTAssertGreaterThan(try logFileSize(), 0)

        log.clear()

        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(try logFileSize(), 0, "clear() must truncate the on-disk log")
    }
}
