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

    // Fake font bytes can't be parsed by CoreText, which exercises the
    // filename-fallback metadata path deterministically.
    private func makeFontFile(named filename: String) throws -> URL {
        let url = tempFontsDirectory.appendingPathComponent(filename, isDirectory: false)
        try Data("not real font data".utf8).write(to: url)
        return url
    }

    func testFontFamilyGroupingAndStyleDetection() async throws {
        let store = AppStateStore()
        let regular = try makeFontFile(named: "MyFamily-Regular.ttf")
        let italic = try makeFontFile(named: "MyFamily-Italic.ttf")
        let other = try makeFontFile(named: "OtherFace.otf")

        try CustomFontStore.importFonts(from: [regular, italic, other], store: store)

        let families = store.customFontFamilies
        XCTAssertEqual(families.count, 2)

        let myFamily = try XCTUnwrap(families.first { $0.displayName == "MyFamily" })
        XCTAssertEqual(myFamily.files.count, 2, "Regular and italic variants belong to one family")
        XCTAssertEqual(
            Set(myFamily.files.map(\.style)),
            [.normal, .italic],
            "Style must be detected from the filename when CoreText can't parse the file"
        )

        let otherFamily = try XCTUnwrap(families.first { $0.displayName == "OtherFace" })
        XCTAssertEqual(otherFamily.files.count, 1)
    }

    func testFontRemovalDeletesRecordsAndFiles() async throws {
        let store = AppStateStore()
        let font = try makeFontFile(named: "Removable.ttf")
        try CustomFontStore.importFonts(from: [font], store: store)
        let familyID = try XCTUnwrap(store.customFontFamilies.first?.id)

        try CustomFontStore.removeFamilies(withIDs: [familyID], store: store)

        XCTAssertTrue(store.customFontFamilies.isEmpty)
        let fontsDirectory = try AppStorage.customFontsDirectory()
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: fontsDirectory.path)
        XCTAssertTrue(remainingFiles.isEmpty, "Removing a family must delete its stored files")
    }

    func testSynchronizedFamiliesPrunesRecordsForMissingFiles() async throws {
        let store = AppStateStore()
        let font = try makeFontFile(named: "Vanishing.ttf")
        try CustomFontStore.importFonts(from: [font], store: store)
        XCTAssertEqual(store.customFontFamilies.count, 1)

        // Simulate the stored file disappearing from disk (e.g. cleared cache).
        let fontsDirectory = try AppStorage.customFontsDirectory()
        for file in try FileManager.default.contentsOfDirectory(atPath: fontsDirectory.path) {
            try FileManager.default.removeItem(
                at: fontsDirectory.appendingPathComponent(file, isDirectory: false)
            )
        }

        let families = CustomFontStore.allFamilies(store: store)
        XCTAssertTrue(families.isEmpty, "Families whose files are gone must be pruned")
        XCTAssertTrue(store.customFontFamilies.isEmpty)
    }

    func testFailedImportRemovesEarlierCopiedFiles() async throws {
        let store = AppStateStore()

        let supportedFont = tempFontsDirectory.appendingPathComponent("MyFont.ttf", isDirectory: false)
        try Data("not really font data".utf8).write(to: supportedFont)
        let unsupportedFile = tempFontsDirectory.appendingPathComponent("notes.txt", isDirectory: false)
        try Data("hello".utf8).write(to: unsupportedFile)

        do {
            try CustomFontStore.importFonts(from: [supportedFont, unsupportedFile], store: store)
            XCTFail("Importing an unsupported file should throw")
        } catch {
            // expected
        }

        let fontsDirectory = try AppStorage.customFontsDirectory()
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: fontsDirectory.path)
        XCTAssertTrue(remainingFiles.isEmpty, "A failed batch import must not orphan files copied in earlier iterations")
        XCTAssertTrue(store.customFontFamilies.isEmpty, "No families should be recorded for a failed import")
    }
}
