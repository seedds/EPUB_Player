//
//  ClipLocationMatcherTests.swift
//  EPUB PlayerTests
//

import XCTest
@testable import EPUBPlayer

final class ClipLocationMatcherTests: XCTestCase {
    func testSavedPositionPrefersExactClipTiming() {
        let clips = [
            clip(resource: "Text/chapter.xhtml", fragmentID: "p1", begin: 1, end: 2),
            clip(resource: "Text/chapter.xhtml", fragmentID: "p1", begin: 3, end: 4),
        ]

        let index = ClipLocationMatcher.savedPositionIndex(
            textResourceHref: "chapter.xhtml",
            fragmentID: "p1",
            clipBegin: 3,
            clipEnd: 4,
            clips: clips,
            normalize: filename
        )

        XCTAssertEqual(index, 1)
    }

    func testSavedPositionFallsBackToFragmentWhenTimingChanges() {
        let clips = [
            clip(resource: "Text/chapter.xhtml", fragmentID: "p1", begin: 10, end: 12),
        ]

        let index = ClipLocationMatcher.savedPositionIndex(
            textResourceHref: "chapter.xhtml",
            fragmentID: "p1",
            clipBegin: 3,
            clipEnd: 4,
            clips: clips,
            normalize: filename
        )

        XCTAssertEqual(index, 0)
    }

    func testExactIndexRequiresFragment() {
        let clips = [clip(resource: "chapter.xhtml", fragmentID: "p1")]

        XCTAssertNil(ClipLocationMatcher.exactIndex(
            resourceHref: "chapter.xhtml",
            fragmentID: nil,
            clips: clips,
            normalize: filename
        ))
        XCTAssertEqual(ClipLocationMatcher.exactIndex(
            resourceHref: "chapter.xhtml",
            fragmentID: "p1",
            clips: clips,
            normalize: filename
        ), 0)
    }

    func testFirstIndexUsesFragmentBeforeResourceFallback() {
        let clips = [
            clip(resource: "chapter.xhtml", fragmentID: "p1"),
            clip(resource: "chapter.xhtml", fragmentID: "p2"),
        ]

        XCTAssertEqual(ClipLocationMatcher.firstIndex(
            resourceHref: "chapter.xhtml",
            fragmentID: "p2",
            clips: clips,
            normalize: filename
        ), 1)
        XCTAssertEqual(ClipLocationMatcher.firstIndex(
            resourceHref: "chapter.xhtml",
            fragmentID: "missing",
            clips: clips,
            normalize: filename
        ), 0)
    }

    func testFirstIndexAfterResourceUsesReadingOrder() {
        let clips = [
            clip(resource: "intro.xhtml", fragmentID: "p1"),
            clip(resource: "chapter2.xhtml", fragmentID: "p1"),
        ]

        let index = ClipLocationMatcher.firstIndexAfterResource(
            "chapter1.xhtml",
            readingOrderResourceHrefs: ["intro.xhtml", "chapter1.xhtml", "chapter2.xhtml"],
            clips: clips,
            normalize: filename
        )

        XCTAssertEqual(index, 1)
    }

    private func clip(
        resource: String,
        fragmentID: String?,
        begin: Double = 0,
        end: Double? = 1
    ) -> EPUBMediaOverlayClip {
        EPUBMediaOverlayClip(
            textResourceHref: resource,
            fragmentID: fragmentID,
            audioPath: "audio.mp3",
            clipBegin: begin,
            clipEnd: end
        )
    }

    private func filename(_ href: String) -> String {
        URL(fileURLWithPath: href).lastPathComponent
    }
}
