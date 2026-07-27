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
                isReloadingOverlays: false,
                hasLoadedClips: true
            )
        )
    }

    func testDoesNotClearDuringMidSessionOverlayReload() {
        // A background re-import / cache refresh transiently nils the clip
        // index. Restored, but reloading -> must preserve the saved point.
        XCTAssertFalse(
            ReaderView.shouldClearSavedClip(
                hasRestoredPlaybackState: true,
                isReloadingOverlays: true,
                hasLoadedClips: true
            ),
            "A mid-session overlay reload must not clear the saved resume point"
        )
    }

    func testClearsOnGenuineUserStop() {
        // Restored, not reloading, clips still loaded: a nil clip is a genuine
        // stop, so clearing the saved point is correct.
        XCTAssertTrue(
            ReaderView.shouldClearSavedClip(
                hasRestoredPlaybackState: true,
                isReloadingOverlays: false,
                hasLoadedClips: true
            )
        )
    }

    func testDoesNotClearWhenReloadingEvenIfNotRestored() {
        XCTAssertFalse(
            ReaderView.shouldClearSavedClip(
                hasRestoredPlaybackState: false,
                isReloadingOverlays: true,
                hasLoadedClips: true
            )
        )
    }

    /// The load-bearing case. A reload tears the clips down and nils the index;
    /// SwiftUI may deliver that change after the reload has already finished,
    /// so the reload flag can be back to false by the time this runs. An empty
    /// clip list still proves the clips were torn down rather than stopped,
    /// because stopping playback leaves them in place.
    func testDoesNotClearWhenClipsWereTornDownEvenAfterReloadFlagCleared() {
        XCTAssertFalse(
            ReaderView.shouldClearSavedClip(
                hasRestoredPlaybackState: true,
                isReloadingOverlays: false,
                hasLoadedClips: false
            ),
            "A nil clip with no clips loaded is a teardown, not a user stop"
        )
    }

    func testDoesNotClearWhenNoClipsAndReloading() {
        XCTAssertFalse(
            ReaderView.shouldClearSavedClip(
                hasRestoredPlaybackState: true,
                isReloadingOverlays: true,
                hasLoadedClips: false
            )
        )
    }
}
