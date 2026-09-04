//
//  LocalUploadServerTests.swift
//  EPUB PlayerTests
//

import XCTest
@testable import EPUBPlayer

final class LocalUploadServerTests: XCTestCase {
    func testHTTPRequestParsingNormalizesMethodAndHeaders() {
        let request = HTTPUploadRequest.parse(headerData: Data("get /api/books HTTP/1.1\r\nHost: local\r\nX-EPUBPlayer-Token: token\r\n\r\n".utf8))

        XCTAssertEqual(request?.method, "GET")
        XCTAssertEqual(request?.target, "/api/books")
        XCTAssertEqual(request?.headers["host"], "local")
        XCTAssertEqual(request?.headers["x-epubplayer-token"], "token")
    }

    func testHTTPRequestParsesUploadFilenameAndSanitizesIt() {
        let request = HTTPUploadRequest.parse(headerData: Data("POST /upload?filename=My%20Book.epub HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8))

        XCTAssertEqual(request?.uploadFilename, "My Book.epub")
    }

    func testHTTPRequestRejectsDuplicateContentLength() {
        // A conflicting duplicate Content-Length is a request-smuggling vector.
        let request = HTTPUploadRequest.parse(headerData: Data(
            "POST /upload?filename=x.epub HTTP/1.1\r\nContent-Length: 10\r\nContent-Length: 20\r\n\r\n".utf8
        ))
        XCTAssertNil(request, "Duplicate Content-Length headers must be rejected")
    }

    func testHTTPRequestRejectsMalformedRequestLine() {
        XCTAssertNil(
            HTTPUploadRequest.parse(headerData: Data("GET /api/books\r\n\r\n".utf8)),
            "A request line missing the HTTP-version must be rejected"
        )
        XCTAssertNil(
            HTTPUploadRequest.parse(headerData: Data("GARBAGE\r\n\r\n".utf8)),
            "A single-token request line must be rejected"
        )
    }

    func testHTTPRequestParsesRenameAndDeleteRoutes() throws {
        let bookID = UUID()
        let rename = HTTPUploadRequest.parse(headerData: Data("POST /api/books/\(bookID.uuidString)/rename?filename=Renamed.epub HTTP/1.1\r\n\r\n".utf8))
        let delete = HTTPUploadRequest.parse(headerData: Data("DELETE /api/books/\(bookID.uuidString) HTTP/1.1\r\n\r\n".utf8))

        XCTAssertEqual(rename?.renameRequest?.bookId, bookID)
        XCTAssertEqual(rename?.renameRequest?.filename, "Renamed.epub")
        XCTAssertEqual(delete?.deleteBookID, bookID)
    }

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

    // MARK: - UploadRequestLimits

    func testHeaderBufferWithinLimitIsAccepted() {
        XCTAssertFalse(UploadRequestLimits.isHeaderBufferTooLarge(byteCount: 0))
        XCTAssertFalse(UploadRequestLimits.isHeaderBufferTooLarge(byteCount: UploadRequestLimits.maxHeaderBytes))
    }

    func testHeaderBufferOverLimitIsRejected() {
        XCTAssertTrue(UploadRequestLimits.isHeaderBufferTooLarge(byteCount: UploadRequestLimits.maxHeaderBytes + 1))
    }

    func testBodyWithinLimitIsAccepted() {
        XCTAssertFalse(UploadRequestLimits.isBodyTooLarge(contentLength: 0))
        XCTAssertFalse(UploadRequestLimits.isBodyTooLarge(contentLength: UploadRequestLimits.maxBodyBytes))
    }

    func testBodyOverLimitIsRejected() {
        XCTAssertTrue(UploadRequestLimits.isBodyTooLarge(contentLength: UploadRequestLimits.maxBodyBytes + 1))
    }

    func testBodyLimitIsBoundedForADeviceSizedDisk() {
        // A limit larger than any plausible device disk is not a limit.
        XCTAssertLessThanOrEqual(
            UploadRequestLimits.maxBodyBytes,
            5 * 1024 * 1024 * 1024,
            "Upload cap must stay within a plausible device disk size"
        )
    }

    // MARK: - Disk exhaustion

    func testUploadFittingComfortablyOnDiskIsAllowed() {
        XCTAssertFalse(
            UploadRequestLimits.wouldExhaustDisk(
                contentLength: 100 * 1024 * 1024,
                availableBytes: 8 * 1024 * 1024 * 1024
            )
        )
    }

    func testUploadThatWouldFillDiskIsRejected() {
        // 900 MB free, 800 MB upload: fits numerically, but leaves less than
        // the margin the app needs to keep writing its own state.
        XCTAssertTrue(
            UploadRequestLimits.wouldExhaustDisk(
                contentLength: 800 * 1024 * 1024,
                availableBytes: 900 * 1024 * 1024
            )
        )
    }

    func testUploadLargerThanFreeSpaceIsRejected() {
        XCTAssertTrue(
            UploadRequestLimits.wouldExhaustDisk(
                contentLength: 4 * 1024 * 1024 * 1024,
                availableBytes: 1024 * 1024 * 1024
            )
        )
    }

    // MARK: - Host validation (DNS-rebinding guard)

    func testTrustedHostAcceptsIPAndLocalNames() {
        XCTAssertTrue(UploadRequestLimits.isTrustedHost("192.168.1.5"))
        XCTAssertTrue(UploadRequestLimits.isTrustedHost("192.168.1.5:8080"))
        XCTAssertTrue(UploadRequestLimits.isTrustedHost("10.0.0.1"))
        XCTAssertTrue(UploadRequestLimits.isTrustedHost("iphone.local"))
        XCTAssertTrue(UploadRequestLimits.isTrustedHost("iphone.local:80"))
        XCTAssertTrue(UploadRequestLimits.isTrustedHost("localhost"))
        XCTAssertTrue(UploadRequestLimits.isTrustedHost("[::1]"))
        XCTAssertTrue(UploadRequestLimits.isTrustedHost("[fe80::1]:80"))
    }

    func testTrustedHostRejectsDomainsAndEmpty() {
        XCTAssertFalse(UploadRequestLimits.isTrustedHost(nil))
        XCTAssertFalse(UploadRequestLimits.isTrustedHost(""))
        XCTAssertFalse(UploadRequestLimits.isTrustedHost("evil.com"))
        XCTAssertFalse(UploadRequestLimits.isTrustedHost("attacker.example.org:80"))
        XCTAssertFalse(UploadRequestLimits.isTrustedHost("epub-player.internal"))
    }

    // MARK: - Content-Type validation

    func testAcceptedUploadContentTypes() {
        XCTAssertTrue(UploadRequestLimits.isAcceptedUploadContentType("application/epub+zip"))
        XCTAssertTrue(UploadRequestLimits.isAcceptedUploadContentType("application/octet-stream"))
        XCTAssertTrue(UploadRequestLimits.isAcceptedUploadContentType("font/sfnt"))
        XCTAssertTrue(UploadRequestLimits.isAcceptedUploadContentType("APPLICATION/EPUB+ZIP; charset=binary"))
    }

    func testRejectedUploadContentTypes() {
        XCTAssertFalse(UploadRequestLimits.isAcceptedUploadContentType(nil))
        XCTAssertFalse(UploadRequestLimits.isAcceptedUploadContentType(""))
        XCTAssertFalse(UploadRequestLimits.isAcceptedUploadContentType("multipart/form-data; boundary=x"))
        XCTAssertFalse(UploadRequestLimits.isAcceptedUploadContentType("text/plain"))
    }

    // MARK: - Upload target path

    func testUploadTargetRequiresExactPath() {
        func request(_ target: String) -> HTTPUploadRequest? {
            HTTPUploadRequest.parse(headerData: Data("POST \(target) HTTP/1.1\r\nContent-Length: 1\r\n\r\n".utf8))
        }
        XCTAssertEqual(request("/upload?filename=x.epub")?.isUploadTarget, true)
        XCTAssertEqual(request("/upload")?.isUploadTarget, true)
        XCTAssertEqual(request("/uploadxyz")?.isUploadTarget, false)
        XCTAssertEqual(request("/api/books")?.isUploadTarget, false)
    }

    // MARK: - constantTimeEquals

    func testConstantTimeEqualsMatchesIdenticalStrings() {
        XCTAssertTrue(constantTimeEquals("", ""))
        XCTAssertTrue(constantTimeEquals("secret", "secret"))
        XCTAssertTrue(constantTimeEquals("üñïçødé", "üñïçødé"))
    }

    func testConstantTimeEqualsRejectsDifferentStrings() {
        XCTAssertFalse(constantTimeEquals("secret", "Secret"))
        XCTAssertFalse(constantTimeEquals("secret", "secret "))
        XCTAssertFalse(constantTimeEquals("secret", "secre"))
        XCTAssertFalse(constantTimeEquals("", "x"))
    }
}
