//
//  LocalUploadServerTests.swift
//  EPUB PlayerTests
//

import XCTest
@testable import EPUBPlayer

final class LocalUploadServerTests: XCTestCase {
    func testUploadFileKindMapping() {
        XCTAssertEqual(UploadFileKind(filename: "book.epub"), .book)
        XCTAssertEqual(UploadFileKind(filename: "Book.EPUB"), .book)
        XCTAssertEqual(UploadFileKind(filename: "font.ttf"), .customFont)
        XCTAssertEqual(UploadFileKind(filename: "Font.OTF"), .customFont)
        XCTAssertNil(UploadFileKind(filename: "archive.zip"))
        XCTAssertNil(UploadFileKind(filename: "noextension"))
        XCTAssertNil(UploadFileKind(filename: ""))
    }
}
