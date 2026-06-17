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

    // MARK: - UploadServerAuthConfig

    func testOpenConfigAlwaysAuthorized() {
        let config = UploadServerAuthConfig.open
        XCTAssertTrue(config.isAuthorized(token: nil))
        XCTAssertTrue(config.isAuthorized(token: ""))
        XCTAssertTrue(config.isAuthorized(token: "anything"))
    }

    func testProtectedConfigRequiresMatchingToken() {
        let config = UploadServerAuthConfig.makeProtected(password: "secret")
        XCTAssertFalse(config.isAuthorized(token: nil),    "nil token must be rejected")
        XCTAssertFalse(config.isAuthorized(token: ""),     "empty token must be rejected")
        XCTAssertFalse(config.isAuthorized(token: "wrong"), "wrong token must be rejected")
        XCTAssertTrue(config.isAuthorized(token: config.sessionToken), "correct token must be accepted")
    }

    func testEachProtectedConfigHasUniqueToken() {
        let a = UploadServerAuthConfig.makeProtected(password: "pw")
        let b = UploadServerAuthConfig.makeProtected(password: "pw")
        XCTAssertNotEqual(a.sessionToken, b.sessionToken, "each server start should produce a distinct token")
    }

    func testProtectedConfigDoesNotAcceptTokenFromDifferentConfig() {
        let a = UploadServerAuthConfig.makeProtected(password: "pw")
        let b = UploadServerAuthConfig.makeProtected(password: "pw")
        XCTAssertFalse(b.isAuthorized(token: a.sessionToken), "token from another server instance must be rejected")
    }
}
