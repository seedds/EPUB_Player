//
//  XMLHardeningTests.swift
//  EPUB PlayerTests
//

import XCTest
@testable import EPUBPlayer

/// EPUBs arrive from an unauthenticated LAN upload server, so every XML
/// document the importer parses is attacker-controlled.
///
/// Foundation's `XMLParser` is safe here by default: it does not substitute
/// custom internal entities, and it never fetches external ones. These are
/// characterization tests, not regressions — they fail if someone later opts
/// into entity resolution (by setting `shouldResolveExternalEntities` or
/// implementing `parser(_:resolveExternalEntityName:systemID:)`), which would
/// turn a malicious EPUB into a file-disclosure or out-of-memory vector.
final class XMLHardeningTests: XCTestCase {
    /// Classic "billion laughs": nested internal entities that expand
    /// exponentially and exhaust memory during parsing.
    private static let billionLaughs = """
    <?xml version="1.0"?>
    <!DOCTYPE container [
     <!ENTITY a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">
     <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
     <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
     <!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;">
     <!ENTITY e "&d;&d;&d;&d;&d;&d;&d;&d;&d;&d;">
     <!ENTITY f "&e;&e;&e;&e;&e;&e;&e;&e;&e;&e;">
     <!ENTITY g "&f;&f;&f;&f;&f;&f;&f;&f;&f;&f;">
     <!ENTITY h "&g;&g;&g;&g;&g;&g;&g;&g;&g;&g;">
    ]>
    <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
      <rootfiles>
        <rootfile full-path="&h;" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    /// External entity pointing at a local file. If resolved, the file's
    /// contents are exfiltrated into the parsed document.
    private static func externalEntityDocument(targetPath: String) -> String {
        """
        <?xml version="1.0"?>
        <!DOCTYPE container [
         <!ENTITY xxe SYSTEM "file://\(targetPath)">
        ]>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles>
            <rootfile full-path="&xxe;" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
    }

    func testEntityExpansionDoesNotHangOrExhaustMemory() throws {
        let data = Data(Self.billionLaughs.utf8)

        let started = Date()
        let rootPath = EPUBMetadataService.test_parseContainerRootPath(data: data)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 5.0, "Entity expansion took \(elapsed)s -- parser is not bounded")
        // Whether it fails outright or returns unexpanded text, it must not
        // return a megabytes-long expanded string.
        if let rootPath {
            XCTAssertLessThan(
                rootPath.count,
                10_000,
                "Entities expanded to \(rootPath.count) characters"
            )
        }
    }

    func testExternalEntityIsNotResolved() throws {
        let secretURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xxe-secret-\(UUID().uuidString).txt")
        let secret = "TOP-SECRET-CONTENTS-\(UUID().uuidString)"
        try Data(secret.utf8).write(to: secretURL)
        defer { try? FileManager.default.removeItem(at: secretURL) }

        let document = Self.externalEntityDocument(targetPath: secretURL.path)
        let rootPath = EPUBMetadataService.test_parseContainerRootPath(data: Data(document.utf8))

        XCTAssertNotEqual(rootPath, secret, "External entity was resolved -- local file disclosed")
        XCTAssertFalse(
            rootPath?.contains("TOP-SECRET-CONTENTS") ?? false,
            "External entity leaked file contents into the parsed document"
        )
    }

    func testWellFormedContainerStillParses() throws {
        let document = """
        <?xml version="1.0"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

        XCTAssertEqual(
            EPUBMetadataService.test_parseContainerRootPath(data: Data(document.utf8)),
            "OEBPS/content.opf",
            "Hardening must not break legitimate EPUBs"
        )
    }
}
