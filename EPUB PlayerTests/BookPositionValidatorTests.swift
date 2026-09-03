//
//  BookPositionValidatorTests.swift
//  EPUB PlayerTests
//

import XCTest
@testable import EPUBPlayer

final class BookPositionValidatorTests: XCTestCase {
    private func clip(
        resourceHref: String,
        fragmentID: String?,
        clipBegin: Double,
        clipEnd: Double?,
        audioPath: String = "audio.mp3"
    ) -> EPUBMediaOverlayClip {
        EPUBMediaOverlayClip(
            textResourceHref: resourceHref,
            fragmentID: fragmentID,
            audioPath: audioPath,
            clipBegin: clipBegin,
            clipEnd: clipEnd
        )
    }

    // MARK: - Resource href validation

    func testResourceHrefValidationKeepsPresentResourceAndDropsMissing() {
        let positions = BookPositionValidator.Positions(
            lastLocatorJSON: #"{"href":"Text/chapter1.xhtml","type":"application/xhtml+xml"}"#,
            lastPlayedTextResourceHref: "chapter1.xhtml",
            lastPlayedFragmentID: "p1",
            lastPlayedClipBegin: 1,
            lastPlayedClipEnd: 2,
            bookmarks: [
                Bookmark(textResourceHref: "chapter1.xhtml", fragmentID: "p1"),
                Bookmark(textResourceHref: "removed.xhtml", fragmentID: "p9"),
            ],
            history: [
                HistoryEntry(textResourceHref: "chapter2.xhtml", fragmentID: "p2"),
                HistoryEntry(textResourceHref: "gone.xhtml", fragmentID: "p3"),
            ]
        )

        // New manifest hrefs are OPF-relative; matching is by filename.
        let result = BookPositionValidator.validatedAgainstResourceHrefs(
            positions,
            resourceHrefs: ["OEBPS/Text/chapter1.xhtml", "OEBPS/Text/chapter2.xhtml"]
        )

        XCTAssertNotNil(result.lastLocatorJSON)
        XCTAssertEqual(result.lastPlayedTextResourceHref, "chapter1.xhtml")
        XCTAssertEqual(result.bookmarks.count, 1)
        XCTAssertEqual(result.bookmarks.first?.textResourceHref, "chapter1.xhtml")
        XCTAssertEqual(result.history.count, 1)
        XCTAssertEqual(result.history.first?.textResourceHref, "chapter2.xhtml")
    }

    func testResourceHrefValidationDropsResumeWhenResourceMissing() {
        let positions = BookPositionValidator.Positions(
            lastLocatorJSON: #"{"href":"Text/gone.xhtml"}"#,
            lastPlayedTextResourceHref: "gone.xhtml",
            lastPlayedFragmentID: "p1",
            lastPlayedClipBegin: 1,
            lastPlayedClipEnd: 2,
            bookmarks: [],
            history: []
        )

        let result = BookPositionValidator.validatedAgainstResourceHrefs(
            positions,
            resourceHrefs: ["chapter1.xhtml"]
        )

        XCTAssertNil(result.lastLocatorJSON)
        XCTAssertNil(result.lastPlayedTextResourceHref)
        XCTAssertNil(result.lastPlayedClipBegin)
    }

    func testResourceHrefValidationKeepsLocatorWhenJSONUnparseable() {
        let positions = BookPositionValidator.Positions(
            lastLocatorJSON: "not-json",
            lastPlayedTextResourceHref: nil,
            lastPlayedFragmentID: nil,
            lastPlayedClipBegin: nil,
            lastPlayedClipEnd: nil,
            bookmarks: [],
            history: []
        )

        let result = BookPositionValidator.validatedAgainstResourceHrefs(positions, resourceHrefs: [])

        XCTAssertEqual(result.lastLocatorJSON, "not-json")
    }

    // MARK: - Clip validation

    func testClipValidationKeepsExactMatchUnchanged() {
        let positions = BookPositionValidator.Positions(
            lastLocatorJSON: nil,
            lastPlayedTextResourceHref: "chapter1.xhtml",
            lastPlayedFragmentID: "p1",
            lastPlayedClipBegin: 1.0,
            lastPlayedClipEnd: 2.0,
            bookmarks: [],
            history: []
        )

        let result = BookPositionValidator.validatedAgainstClips(
            positions,
            clips: [clip(resourceHref: "chapter1.xhtml", fragmentID: "p1", clipBegin: 1.0, clipEnd: 2.0)]
        )

        XCTAssertEqual(result.lastPlayedTextResourceHref, "chapter1.xhtml")
        XCTAssertEqual(result.lastPlayedClipBegin, 1.0)
        XCTAssertEqual(result.lastPlayedClipEnd, 2.0)
    }

    func testClipValidationRefreshesTimingOnFragmentMatch() {
        let positions = BookPositionValidator.Positions(
            lastLocatorJSON: nil,
            lastPlayedTextResourceHref: "Text/chapter1.xhtml",
            lastPlayedFragmentID: "p1",
            lastPlayedClipBegin: 1.0,
            lastPlayedClipEnd: 2.0,
            bookmarks: [Bookmark(textResourceHref: "chapter1.xhtml", fragmentID: "p1", clipBegin: 1.0, clipEnd: 2.0)],
            history: [HistoryEntry(textResourceHref: "chapter1.xhtml", fragmentID: "p1", clipBegin: 1.0, clipEnd: 2.0)]
        )

        // Same resource (different base) + fragment, but shifted audio times.
        let result = BookPositionValidator.validatedAgainstClips(
            positions,
            clips: [clip(resourceHref: "OEBPS/Text/chapter1.xhtml", fragmentID: "p1", clipBegin: 5.5, clipEnd: 7.0)]
        )

        XCTAssertEqual(result.lastPlayedClipBegin, 5.5)
        XCTAssertEqual(result.lastPlayedClipEnd, 7.0)
        XCTAssertEqual(result.bookmarks.first?.clipBegin, 5.5)
        XCTAssertEqual(result.bookmarks.first?.clipEnd, 7.0)
        XCTAssertEqual(result.history.first?.clipBegin, 5.5)
        XCTAssertEqual(result.history.first?.clipEnd, 7.0)
    }

    func testClipValidationDropsUnmatchedClipPositions() {
        let positions = BookPositionValidator.Positions(
            lastLocatorJSON: nil,
            lastPlayedTextResourceHref: "chapter1.xhtml",
            lastPlayedFragmentID: "missing",
            lastPlayedClipBegin: 1.0,
            lastPlayedClipEnd: 2.0,
            bookmarks: [
                Bookmark(textResourceHref: "chapter1.xhtml", fragmentID: "p1", clipBegin: 1.0, clipEnd: 2.0),
                Bookmark(textResourceHref: "chapter1.xhtml", fragmentID: "gone", clipBegin: 3.0, clipEnd: 4.0),
            ],
            history: []
        )

        let result = BookPositionValidator.validatedAgainstClips(
            positions,
            clips: [clip(resourceHref: "chapter1.xhtml", fragmentID: "p1", clipBegin: 1.0, clipEnd: 2.0)]
        )

        XCTAssertNil(result.lastPlayedTextResourceHref)
        XCTAssertNil(result.lastPlayedClipBegin)
        XCTAssertEqual(result.bookmarks.count, 1)
        XCTAssertEqual(result.bookmarks.first?.fragmentID, "p1")
    }

    func testClipValidationLeavesNonClipRecordsUntouched() {
        let positions = BookPositionValidator.Positions(
            lastLocatorJSON: "keep",
            lastPlayedTextResourceHref: nil,
            lastPlayedFragmentID: nil,
            lastPlayedClipBegin: nil,
            lastPlayedClipEnd: nil,
            bookmarks: [Bookmark(textResourceHref: nil, fragmentID: nil)],
            history: [HistoryEntry(resourceHref: "chapter1.xhtml")]
        )

        let result = BookPositionValidator.validatedAgainstClips(positions, clips: [])

        XCTAssertEqual(result.lastLocatorJSON, "keep")
        XCTAssertEqual(result.bookmarks.count, 1)
        XCTAssertEqual(result.history.count, 1)
    }

    // MARK: - Drop on failure

    func testDroppingClipPositionsRemovesOnlyClipRecords() {
        let positions = BookPositionValidator.Positions(
            lastLocatorJSON: "keep",
            lastPlayedTextResourceHref: "chapter1.xhtml",
            lastPlayedFragmentID: "p1",
            lastPlayedClipBegin: 1.0,
            lastPlayedClipEnd: 2.0,
            bookmarks: [
                Bookmark(textResourceHref: "chapter1.xhtml", fragmentID: "p1", clipBegin: 1.0, clipEnd: 2.0),
                Bookmark(resourceHref: "chapter1.xhtml"),
            ],
            history: [HistoryEntry(textResourceHref: "chapter1.xhtml", fragmentID: "p1", clipBegin: 1.0, clipEnd: 2.0)]
        )

        let result = BookPositionValidator.droppingClipPositions(positions)

        XCTAssertEqual(result.lastLocatorJSON, "keep")
        XCTAssertNil(result.lastPlayedTextResourceHref)
        XCTAssertNil(result.lastPlayedClipBegin)
        XCTAssertEqual(result.bookmarks.count, 1)
        XCTAssertNil(result.bookmarks.first?.clipBegin)
        XCTAssertTrue(result.history.isEmpty)
    }
}
