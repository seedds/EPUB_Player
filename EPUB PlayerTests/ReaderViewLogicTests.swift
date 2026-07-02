//
//  ReaderViewLogicTests.swift
//  EPUB PlayerTests
//

import XCTest
@testable import EPUBPlayer

final class ReaderViewLogicTests: XCTestCase {
    // MARK: - shouldClearSavedClip

    func testDoesNotClearBeforePlaybackRestored() {
        // The book is still opening: a nil clip must not wipe the saved resume
        // point.
        XCTAssertFalse(
            ReaderView.shouldClearSavedClip(
                hasRestoredPlaybackState: false,
                isReloadingOverlays: false
            )
        )
    }

    func testDoesNotClearDuringMidSessionOverlayReload() {
        // A background re-import / cache refresh transiently nils the clip
        // index. Restored, but reloading -> must preserve the saved point.
        XCTAssertFalse(
            ReaderView.shouldClearSavedClip(
                hasRestoredPlaybackState: true,
                isReloadingOverlays: true
            ),
            "A mid-session overlay reload must not clear the saved resume point"
        )
    }

    func testClearsOnGenuineUserStop() {
        // Restored and not reloading: a nil clip is a genuine stop, so clearing
        // the saved point is correct.
        XCTAssertTrue(
            ReaderView.shouldClearSavedClip(
                hasRestoredPlaybackState: true,
                isReloadingOverlays: false
            )
        )
    }

    func testDoesNotClearWhenReloadingEvenIfNotRestored() {
        XCTAssertFalse(
            ReaderView.shouldClearSavedClip(
                hasRestoredPlaybackState: false,
                isReloadingOverlays: true
            )
        )
    }
}
