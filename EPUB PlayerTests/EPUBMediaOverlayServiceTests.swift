//
//  EPUBMediaOverlayServiceTests.swift
//  EPUB PlayerTests
//

import XCTest
@testable import EPUBPlayer

final class EPUBMediaOverlayServiceTests: XCTestCase {
    var tempDocumentsDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDocumentsDirectory = try TestDocumentsDirectory.activate()
    }

    override func tearDown() async throws {
        TestDocumentsDirectory.deactivate(rootURL: tempDocumentsDirectory)
        tempDocumentsDirectory = nil
        try await super.tearDown()
    }

    func testParseAndWriteExtractsClipsInDocumentOrder() async throws {
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Overlay Book</dc:title>
            <dc:identifier id="uid">test-overlay</dc:identifier>
            <meta property="media:duration">0:00:05.5</meta>
            <meta property="media:duration" refines="#smil1">0:00:02</meta>
            <meta property="media:active-class">-epub-media-overlay-active</meta>
          </metadata>
          <manifest>
            <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml" media-overlay="smil1"/>
            <item id="smil1" href="chapter1.smil" media-type="application/smil+xml"/>
            <item id="audio1" href="audio.mp3" media-type="audio/mpeg"/>
          </manifest>
          <spine>
            <itemref idref="chapter1"/>
          </spine>
        </package>
        """
        let smil = """
        <?xml version="1.0" encoding="UTF-8"?>
        <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
          <body>
            <par id="p1">
              <text src="chapter1.xhtml#f1"/>
              <audio src="audio.mp3" clipBegin="0:00:01.5" clipEnd="2.75s"/>
            </par>
            <par id="p2">
              <text src="chapter1.xhtml#f2"/>
              <audio src="audio.mp3" clipBegin="2.75s" clipEnd="0:00:05.5"/>
            </par>
          </body>
        </smil>
        """
        let epub = ZIPFixtureBuilder.makeEPUB(entries: [
            ZIPFixtureEntry(name: "OEBPS/content.opf", data: Data(opf.utf8)),
            ZIPFixtureEntry(name: "OEBPS/chapter1.xhtml", data: Data("<html/>".utf8)),
            ZIPFixtureEntry(name: "OEBPS/chapter1.smil", data: Data(smil.utf8)),
            ZIPFixtureEntry(name: "OEBPS/audio.mp3", data: Data([0xff, 0xfb, 0x90, 0x00]))
        ])
        let url = try ZIPFixtureBuilder.write(epub, named: "overlay.epub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let bookID = UUID()
        let result = try await EPUBMediaOverlayService.parseAndWrite(at: url, bookID: bookID)

        let manifest = try XCTUnwrap(result?.manifest)
        XCTAssertEqual(manifest.documents.count, 1)
        // The refines-scoped duration must not overwrite the publication total.
        XCTAssertEqual(manifest.duration, 5.5)

        let clips = manifest.documents[0].clips
        XCTAssertEqual(clips.map(\.fragmentID), ["f1", "f2"], "Clips must come out in document order")
        XCTAssertEqual(clips[0].clipBegin, 1.5)
        XCTAssertEqual(clips[0].clipEnd, 2.75)
        XCTAssertEqual(clips[1].clipBegin, 2.75)
        XCTAssertEqual(clips[1].clipEnd, 5.5)
        XCTAssertEqual(clips[0].textResourceHref, "OEBPS/chapter1.xhtml")
        XCTAssertEqual(clips[0].audioPath, "OEBPS/audio.mp3")

        // The manifest JSON must land in the cache and round-trip.
        let jsonURL = try XCTUnwrap(result?.jsonURL)
        let decoded = try JSONDecoder().decode(
            EPUBMediaOverlayManifest.self,
            from: Data(contentsOf: jsonURL)
        )
        XCTAssertEqual(decoded.documents[0].clips.count, 2)
    }

    func testDocumentsFollowSpineOrderNotManifestOrder() async throws {
        // The manifest declares chapter2 BEFORE chapter1, but the spine (the
        // authoritative reading order) is chapter1 then chapter2. The flattened
        // clip timeline must follow the spine, not the manifest.
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Spine Order Book</dc:title>
            <dc:identifier id="uid">test-spine</dc:identifier>
          </metadata>
          <manifest>
            <item id="chapter2" href="chapter2.xhtml" media-type="application/xhtml+xml" media-overlay="smil2"/>
            <item id="smil2" href="chapter2.smil" media-type="application/smil+xml"/>
            <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml" media-overlay="smil1"/>
            <item id="smil1" href="chapter1.smil" media-type="application/smil+xml"/>
            <item id="audio1" href="audio.mp3" media-type="audio/mpeg"/>
          </manifest>
          <spine>
            <itemref idref="chapter1"/>
            <itemref idref="chapter2"/>
          </spine>
        </package>
        """
        func smil(fragment: String, begin: String, end: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
              <body>
                <par id="p">
                  <text src="\(fragment.hasPrefix("c1") ? "chapter1" : "chapter2").xhtml#\(fragment)"/>
                  <audio src="audio.mp3" clipBegin="\(begin)" clipEnd="\(end)"/>
                </par>
              </body>
            </smil>
            """
        }
        let epub = ZIPFixtureBuilder.makeEPUB(entries: [
            ZIPFixtureEntry(name: "OEBPS/content.opf", data: Data(opf.utf8)),
            ZIPFixtureEntry(name: "OEBPS/chapter1.xhtml", data: Data("<html/>".utf8)),
            ZIPFixtureEntry(name: "OEBPS/chapter2.xhtml", data: Data("<html/>".utf8)),
            ZIPFixtureEntry(name: "OEBPS/chapter1.smil", data: Data(smil(fragment: "c1f", begin: "0s", end: "1s").utf8)),
            ZIPFixtureEntry(name: "OEBPS/chapter2.smil", data: Data(smil(fragment: "c2f", begin: "1s", end: "2s").utf8)),
            ZIPFixtureEntry(name: "OEBPS/audio.mp3", data: Data([0xff, 0xfb, 0x90, 0x00]))
        ])
        let url = try ZIPFixtureBuilder.write(epub, named: "spine-order.epub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try await EPUBMediaOverlayService.parseAndWrite(at: url, bookID: UUID())
        let manifest = try XCTUnwrap(result?.manifest)

        let orderedFragments = manifest.documents.flatMap(\.clips).map(\.fragmentID)
        XCTAssertEqual(
            orderedFragments,
            ["c1f", "c2f"],
            "Media-overlay documents must follow spine order, not manifest declaration order"
        )
    }

    func testMalformedOPFYieldsNoPackageRatherThanPartial() async throws {
        // A truncated/malformed OPF must surface as "no package" instead of a
        // partially-parsed manifest that would wrongly prune valid bookmarks.
        let malformedOPF = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest>
            <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
        """  // deliberately unterminated: no closing tags
        let epub = ZIPFixtureBuilder.makeEPUB(entries: [
            ZIPFixtureEntry(name: "OEBPS/content.opf", data: Data(malformedOPF.utf8)),
            ZIPFixtureEntry(name: "OEBPS/chapter1.xhtml", data: Data("<html/>".utf8))
        ])
        let url = try ZIPFixtureBuilder.write(epub, named: "malformed.epub")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let archive = try await EPUBArchive(url: url)
        let package = try await EPUBMetadataService.packageInfo(in: archive)
        XCTAssertNil(package, "A malformed OPF must not produce a partial package")
    }

    func testClockValueParsing() {
        XCTAssertEqual(EPUBMediaOverlayTimeParser.seconds(from: "0:01:02.5"), 62.5)
        XCTAssertEqual(EPUBMediaOverlayTimeParser.seconds(from: "12.7s"), 12.7)
        XCTAssertEqual(EPUBMediaOverlayTimeParser.seconds(from: "500ms"), 0.5)
        XCTAssertEqual(EPUBMediaOverlayTimeParser.seconds(from: "2min"), 120)
        XCTAssertEqual(EPUBMediaOverlayTimeParser.seconds(from: "1.5h"), 5400)
        XCTAssertEqual(EPUBMediaOverlayTimeParser.seconds(from: "90"), 90)
        XCTAssertNil(EPUBMediaOverlayTimeParser.seconds(from: ""))
        XCTAssertNil(EPUBMediaOverlayTimeParser.seconds(from: nil))
    }

    func testClockValueStripsNPTPrefix() {
        // RFC 2326 "npt=" prefixed clock values must parse the same as bare ones.
        XCTAssertEqual(EPUBMediaOverlayTimeParser.seconds(from: "npt=0:00:05.5"), 5.5)
        XCTAssertEqual(EPUBMediaOverlayTimeParser.seconds(from: "npt=12.7s"), 12.7)
        XCTAssertEqual(EPUBMediaOverlayTimeParser.seconds(from: "NPT=90"), 90)
        XCTAssertNil(EPUBMediaOverlayTimeParser.seconds(from: "npt="))
    }
}
