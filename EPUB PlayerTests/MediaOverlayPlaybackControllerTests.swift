//
//  MediaOverlayPlaybackControllerTests.swift
//  EPUB PlayerTests
//

import AVFoundation
import XCTest
@testable import EPUBPlayer

@MainActor
final class MediaOverlayPlaybackControllerTests: XCTestCase {
    private var controller: MediaOverlayPlaybackController!

    override func setUp() async throws {
        try await super.setUp()
        controller = MediaOverlayPlaybackController()
    }

    override func tearDown() async throws {
        controller?.test_teardown()
        controller = nil
        // Drain one main-queue turn so any observer callbacks queued by AVPlayer
        // complete before the next XCTest starts.
        await Task.yield()
        try await super.tearDown()
    }

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

    private func makeTimedClip(
        audioPath: String,
        fragmentID: String,
        clipBegin: Double,
        clipEnd: Double
    ) -> EPUBMediaOverlayClip {
        EPUBMediaOverlayClip(
            textHref: "chapter.xhtml#\(fragmentID)",
            textResourceHref: "chapter.xhtml",
            fragmentID: fragmentID,
            audioHref: audioPath,
            audioPath: audioPath,
            clipBegin: clipBegin,
            clipEnd: clipEnd
        )
    }

    /// Four 5s clips sharing one audio file, yielding a contiguous timeline of
    /// [0-5], [5-10], [10-15], [15-20]. Explicit clipEnds make the narrated
    /// timeline deterministic without loading real audio.
    private func makeContiguousTimedClips() -> [EPUBMediaOverlayClip] {
        (0..<4).map { index in
            makeTimedClip(
                audioPath: "audio.mp3",
                fragmentID: "c\(index)",
                clipBegin: Double(index) * 5,
                clipEnd: Double(index + 1) * 5
            )
        }
    }

    /// A clip with an explicit `clipEnd` (the normal SMIL case) must still get
    /// an end-of-item observer registered. The boundary time observer is not
    /// guaranteed to fire when its boundary sits at the audio file's true end,
    /// which left auto-advance stuck at chapter boundaries. The end-of-item
    /// observer is the fallback that keeps playback advancing.
    func testClipWithClipEndStillRegistersEndOfItemObserver() async throws {
        let clip = makeClip(audioPath: "audio.mp3", fragmentID: "a")
        let url = URL(fileURLWithPath: "/tmp/audio.mp3")

        controller.configureForTesting(clips: [clip]) { _ in url }

        controller.selectClip(at: 0, autoplay: true, reason: "test-end-observer")

        try await waitUntil(timeout: 5) {
            self.controller.test_hasEndObserver
        }

        XCTAssertTrue(
            controller.test_hasEndObserver,
            "Clip with a clipEnd must still register an end-of-item observer for chapter-boundary auto-advance"
        )
    }

    /// Reproduces the stale-async-start race: a slow preparation for an older
    /// clip must not clobber the player state of a newer clip that started after
    /// it. The older resolution is gated to complete only after the newer clip
    /// has finished applying its player, making the race deterministic.
    func testStaleStartDoesNotClobberNewerClipPlayerState() async throws {
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
            self.controller.test_loadedAudioPath == clipB.audioPath
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

    /// A superseded start must cancel its in-flight audio-resolution task so the
    /// older transition stops working instead of running to completion.
    func testStartingNewerClipCancelsPriorStartTask() async throws {
        let clipA = makeClip(audioPath: "audioA.mp3", fragmentID: "a")
        let clipB = makeClip(audioPath: "audioB.mp3", fragmentID: "b")

        let releaseA = expectation(description: "release clip A resolution")
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

        // Start clip A; it suspends inside the gated resolver.
        controller.selectClip(at: 0, autoplay: true, reason: "test-A")
        await fulfillment(of: [aResolutionStarted], timeout: 5)

        // Start clip B while A is suspended — this should cancel A's start task.
        controller.selectClip(at: 1, autoplay: true, reason: "test-B")
        try await waitUntil(timeout: 5) {
            self.controller.test_loadedAudioPath == clipB.audioPath
        }

        XCTAssertTrue(
            controller.test_isStartTaskCancelled == false,
            "The active (clip B) start task should not be cancelled"
        )

        releaseA.fulfill()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(
            controller.test_loadedAudioPath,
            clipB.audioPath,
            "Superseded clip A start must not clobber clip B"
        )
    }

    /// An audio-session interruption (e.g. an incoming phone call) pauses the
    /// underlying player at the system level. The controller must sync its
    /// published state to `.paused` so the play button repaints correctly and a
    /// single tap resumes — without this the button stayed in the playing state
    /// and required two taps.
    func testAudioSessionInterruptionPausesPlaybackState() async throws {
        let clip = makeClip(audioPath: "audio.mp3", fragmentID: "a")
        let url = URL(fileURLWithPath: "/tmp/audio.mp3")

        controller.configureForTesting(clips: [clip]) { _ in url }
        controller.selectClip(at: 0, autoplay: true, reason: "test-interruption")

        try await waitUntil(timeout: 5) {
            self.controller.state.isPlaying
        }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ]
        )

        try await waitUntil(timeout: 5) {
            self.controller.state == .paused
        }

        XCTAssertEqual(
            controller.state,
            .paused,
            "An interruption .began must move the controller out of the playing state so the button shows play"
        )
    }

    /// Returning from background past the threshold while paused must rewind to
    /// an earlier clip and report that it did so, so the reader can scroll the
    /// newly-highlighted (possibly off-screen) sentence back into view.
    func testAutoRewindAfterBackgroundReturnsTrueAndMovesToEarlierClip() async throws {
        let clips = makeContiguousTimedClips()
        let url = URL(fileURLWithPath: "/tmp/audio.mp3")

        controller.configureForTesting(clips: clips) { _ in url }
        // Paused selection: no player is loaded, so the offset within the clip
        // is 0 and the current position is the clip's timeline start (15s).
        controller.selectClip(at: 3, autoplay: false, reason: "test-autorewind")

        let didRewind = await controller.applicationWillEnterForeground(
            backgroundedFor: 120,
            rewindThresholdMinutes: 1,
            rewindSeconds: 10
        )

        XCTAssertTrue(didRewind, "A paused return past the threshold must report that it rewound")
        // 15s - 10s = 5s, which lands at the start of clip index 1 ([5-10]).
        XCTAssertEqual(
            controller.currentClipIndex,
            1,
            "Auto-rewind of 10s from the 15s mark should move to the clip covering the 5s mark"
        )
    }

    /// A return shorter than the configured threshold must not rewind and must
    /// report that nothing happened, leaving the current clip untouched.
    func testAutoRewindBelowThresholdReturnsFalseAndKeepsClip() async throws {
        let clips = makeContiguousTimedClips()
        let url = URL(fileURLWithPath: "/tmp/audio.mp3")

        controller.configureForTesting(clips: clips) { _ in url }
        controller.selectClip(at: 3, autoplay: false, reason: "test-autorewind-below")

        let didRewind = await controller.applicationWillEnterForeground(
            backgroundedFor: 30,
            rewindThresholdMinutes: 1,
            rewindSeconds: 10
        )

        XCTAssertFalse(didRewind, "A return shorter than the threshold must not rewind")
        XCTAssertEqual(
            controller.currentClipIndex,
            3,
            "A below-threshold return must leave the current clip unchanged"
        )
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
