//
//  AppStorageTests.swift
//  EPUB PlayerTests
//

import XCTest
@testable import EPUBPlayer

final class AppStorageTests: XCTestCase {
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

    // MARK: - bookFileURL containment

    func testBookFileURLResolvesLegitimatePathUnderDocuments() throws {
        let documents = try AppStorage.documentsDirectory().standardizedFileURL.path
        let url = try AppStorage.bookFileURL(storedPath: "Books/example.epub")
        XCTAssertTrue(
            url.standardizedFileURL.path.hasPrefix(documents + "/"),
            "A legitimate stored path must resolve inside Documents"
        )
        XCTAssertEqual(url.lastPathComponent, "example.epub")
    }

    func testBookFileURLRejectsParentTraversal() {
        // A crafted state.json could store this to escape Books/ and delete an
        // arbitrary file elsewhere in the container.
        XCTAssertThrowsError(
            try AppStorage.bookFileURL(storedPath: "Books/../../../../tmp/victim.epub")
        ) { error in
            guard case AppStorageError.pathEscapesBaseDirectory = error else {
                return XCTFail("Expected pathEscapesBaseDirectory, got \(error)")
            }
        }
    }

    func testBookFileURLRejectsLeadingParentTraversal() {
        XCTAssertThrowsError(
            try AppStorage.bookFileURL(storedPath: "../Library/Preferences/x.plist")
        ) { error in
            guard case AppStorageError.pathEscapesBaseDirectory = error else {
                return XCTFail("Expected pathEscapesBaseDirectory, got \(error)")
            }
        }
    }

    func testBookFileURLRejectsSingleDotComponent() {
        XCTAssertThrowsError(
            try AppStorage.bookFileURL(storedPath: "Books/./x.epub")
        ) { error in
            guard case AppStorageError.pathEscapesBaseDirectory = error else {
                return XCTFail("Expected pathEscapesBaseDirectory, got \(error)")
            }
        }
    }

    func testBookFileURLEmptyPathReturnsBase() throws {
        let url = try AppStorage.bookFileURL(storedPath: "")
        XCTAssertEqual(
            url.standardizedFileURL.path,
            try AppStorage.documentsDirectory().standardizedFileURL.path
        )
    }

    // MARK: - cover / overlay resolvers

    func testResolvedCoverImageURLRejectsTraversal() throws {
        let book = Book(
            title: "T",
            originalFilename: "t.epub",
            epubFilePath: "Books/t.epub",
            coverImagePath: "../../../../tmp/steal.png"
        )
        XCTAssertThrowsError(try book.resolvedCoverImageURL()) { error in
            guard case AppStorageError.pathEscapesBaseDirectory = error else {
                return XCTFail("Expected pathEscapesBaseDirectory, got \(error)")
            }
        }
    }

    func testResolvedCoverImageURLAcceptsBareFilename() throws {
        let coversDir = try AppStorage.coversDirectory().standardizedFileURL.path
        let book = Book(
            title: "T",
            originalFilename: "t.epub",
            epubFilePath: "Books/t.epub",
            coverImagePath: "ABCDEF.png"
        )
        let url = try XCTUnwrap(try book.resolvedCoverImageURL())
        XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(coversDir + "/"))
        XCTAssertEqual(url.lastPathComponent, "ABCDEF.png")
    }

    func testResolvedMediaOverlayJSONURLRejectsTraversal() throws {
        let book = Book(
            title: "T",
            originalFilename: "t.epub",
            epubFilePath: "Books/t.epub",
            mediaOverlayJSONPath: "../../secret.json"
        )
        XCTAssertThrowsError(try book.resolvedMediaOverlayJSONURL()) { error in
            guard case AppStorageError.pathEscapesBaseDirectory = error else {
                return XCTFail("Expected pathEscapesBaseDirectory, got \(error)")
            }
        }
    }
}
