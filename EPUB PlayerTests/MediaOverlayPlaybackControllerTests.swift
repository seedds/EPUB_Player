//
//  MediaOverlayPlaybackControllerTests.swift
//  EPUB PlayerTests
//

import XCTest
@testable import EPUBPlayer

@MainActor
final class MediaOverlayPlaybackControllerTests: XCTestCase {
    private func makeClip(audioPath: String, fragmentID: String) -> EPUBMediaOverlayClip {
        EPUBMediaOverlayClip(
            textHref: "chapter.xhtml#\(fragmentID)",
            textResourceHref: "chapter.xhtml",
            fragmentID: fragmentID,
            audioHref: audioPath,
            audioPath: audioPath,
            clipBegin: 0,
            clipEnd: 1
        )
    }

    /// Reproduces the stale-async-start race: a slow preparation for an older
    /// clip must not clobber the player state of a newer clip that started after
    /// it. The older resolution is gated to complete only after the newer clip
    /// has finished applying its player, making the race deterministic.
    func testStaleStartDoesNotClobberNewerClipPlayerState() async throws {
        let controller = MediaOverlayPlaybackController()

        let clipA = makeClip(audioPath: "audioA.mp3", fragmentID: "a")
        let clipB = makeClip(audioPath: "audioB.mp3", fragmentID: "b")

        // Gate that releases clip A's resolution only once the test allows it.
        let releaseA = expectation(description: "release clip A resolution")
        // Signals that clip A's resolver has been entered (i.e. A's start is
        // genuinely suspended on resolution when B begins).
        let aResolutionStarted = expectation(description: "clip A resolution started")

        let urlA = URL(fileURLWithPath: "/tmp/audioA.mp3")
        let urlB = URL(fileURLWithPath: "/tmp/audioB.mp3")

        controller.configureForTesting(clips: [clipA, clipB]) { audioPath in
            if audioPath == clipA.audioPath {
                aResolutionStarted.fulfill()
                await self.fulfillment(of: [releaseA], timeout: 5)
                return urlA
            }
            return urlB
        }

        // Start clip A; it will suspend inside the gated resolver.
        controller.selectClip(at: 0, autoplay: true, reason: "test-A")
        await fulfillment(of: [aResolutionStarted], timeout: 5)

        // Start clip B while A is still suspended. B resolves immediately and
        // applies its player.
        controller.selectClip(at: 1, autoplay: true, reason: "test-B")
        try await waitUntil(timeout: 5) {
            controller.test_loadedAudioPath == clipB.audioPath
        }

        // Now let the stale A resolution complete. It must NOT overwrite B.
        releaseA.fulfill()

        // Give the stale A continuation ample opportunity to (wrongly) run.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(
            controller.test_loadedAudioPath,
            clipB.audioPath,
            "Stale clip A preparation clobbered the newer clip B player state"
        )
        XCTAssertEqual(controller.currentClipIndex, 1)
    }

    private func waitUntil(
        timeout: TimeInterval,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
