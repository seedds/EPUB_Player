//
//  CustomFontStoreTests.swift
//  EPUB PlayerTests
//
//

import XCTest
@testable import EPUBPlayer

@MainActor
final class CustomFontStoreTests: XCTestCase {
    var tempFontsDirectory: URL!
    var tempDocumentsDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDocumentsDirectory = try TestDocumentsDirectory.activate()

        // Create temporary fonts directory
        tempFontsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempFontsDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // Clean up temp directory
        try? FileManager.default.removeItem(at: tempFontsDirectory)
        TestDocumentsDirectory.deactivate(rootURL: tempDocumentsDirectory)
        tempDocumentsDirectory = nil
        try await super.tearDown()
    }

    func testFontFamilyGrouping() async throws {
        // This test would require creating actual font files or mocking the font detection
        // Placeholder for font family grouping logic test

        let store = AppStateStore()

        // Test that fonts with the same family name are grouped together
        // Test that regular and italic variants are in the same family
        // Test that different families are kept separate
    }

    func testFontStyleDetection() async throws {
        // Test that italic fonts are correctly identified
        // Test that regular fonts are correctly identified
        // Test fallback to filename parsing when CoreText fails
    }

    func testFontRemoval() async throws {
        let store = AppStateStore()

        // Test that removing a family removes all its files
        // Test that removing individual files works
        // Test that removing the last file in a family removes the family
    }

    func testFontRegistrationCaching() async throws {
        // Test that fonts are only registered once
        // Test that the registration cache is updated on removal
        // Test thread safety of the registration lock
    }

    func testSynchronizedFamilies() async throws {
        let store = AppStateStore()

        // Test that missing files are filtered out
        // Test that families with no remaining files are removed
        // Test that the selected font family is synchronized
    }
}
