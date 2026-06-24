//
//  MediaOverlayPlaybackController.swift
//  EPUB Player
//
//  Created by F2PGOD on 25/4/2026.
//

@preconcurrency import AVFoundation
import Combine
import Foundation
import MediaPlayer
import os
import UIKit

/// Lightweight wrapper around `OSSignposter` for measuring the cost of the
/// pause/resume path. Signposts compile to near-nothing when Instruments is not
/// recording, so this can live in the codebase permanently. Open the
/// "com.epubplayer.playback" subsystem in Instruments' os_signpost instrument to
/// inspect the named intervals (e.g. "pause.player", "pause.deactivate").
enum PlaybackSignposter {
    static let signposter = OSSignposter(
        subsystem: "com.epubplayer.playback",
        category: "pause"
    )

    /// Measures the synchronous body of `operation` as a signpost interval.
    @discardableResult
    static func measure<T>(_ name: StaticString, _ operation: () -> T) -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return operation()
    }
}

/// Owns the AVPlayer-, time-observer-, and remote-command resources that must
/// be released on the main thread. Kept as a separate reference type so the
/// controller's `nonisolated deinit` can hand off cleanup by reading a single
/// `let` holder instead of touching the controller's `@MainActor`-isolated
/// stored properties directly (which is a data race under strict concurrency).
private final class PlaybackResources: @unchecked Sendable {
    var player: AVPlayer?
    var boundaryObserver: Any?
    var endObserver: NSObjectProtocol?
    var periodicTimeObserver: Any?
    var playCommandTarget: Any?
    var pauseCommandTarget: Any?
    var togglePlayPauseCommandTarget: Any?
    var skipForwardCommandTarget: Any?
    var skipBackwardCommandTarget: Any?

    /// Removes all retained observers and remote-command targets. Must run on
    /// the main thread.
    func teardown() {
        let commandCenter = MPRemoteCommandCenter.shared()
        if let playCommandTarget {
            commandCenter.playCommand.removeTarget(playCommandTarget)
        }
        if let pauseCommandTarget {
            commandCenter.pauseCommand.removeTarget(pauseCommandTarget)
        }
        if let togglePlayPauseCommandTarget {
            commandCenter.togglePlayPauseCommand.removeTarget(togglePlayPauseCommandTarget)
        }
        if let skipForwardCommandTarget {
            commandCenter.skipForwardCommand.removeTarget(skipForwardCommandTarget)
        }
        if let skipBackwardCommandTarget {
            commandCenter.skipBackwardCommand.removeTarget(skipBackwardCommandTarget)
        }
        // Nil each token as it is removed (and drop the player at the end) so a
        // second teardown — or a teardown racing an in-flight observer
        // registration — cannot remove the same time-observer token twice, which
        // over-releases it and aborts with "pointer being freed was not allocated".
        if let periodicTimeObserver, let player {
            player.removeTimeObserver(periodicTimeObserver)
        }
        periodicTimeObserver = nil
        if let boundaryObserver, let player {
            player.removeTimeObserver(boundaryObserver)
        }
        boundaryObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        playCommandTarget = nil
        pauseCommandTarget = nil
        togglePlayPauseCommandTarget = nil
        skipForwardCommandTarget = nil
        skipBackwardCommandTarget = nil
        player = nil
    }
}

@MainActor
final class MediaOverlayPlaybackController: ObservableObject {
    private struct NowPlayingSnapshot {
        let displayTitle: String
        let displayArtist: String?
        let elapsedTime: Double
        let duration: Double
    }

    enum State: Equatable {
        case unavailable
        case ready
        case playing
        case paused
        case failed(String)

        var isPlaying: Bool {
            if case .playing = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .unavailable
    @Published private(set) var clips: [EPUBMediaOverlayClip] = []
    @Published private(set) var currentClipIndex: Int?
    @Published private(set) var canJumpBackward = false
    @Published private(set) var canJumpForward = false

    private var nextTransitionID = 0
    /// Maximum time gap (in seconds) between consecutive clips in the same audio file
    /// that allows seamless playback without reloading the player.
    /// Clips separated by less than this duration will continue playing from the current position.
    private let seamlessAutoAdvanceTolerance: Double = 0.1
    private var playbackRate = ReaderSettings.defaultPlaybackSpeed
    private var jumpInterval = ReaderSettings.defaultPlaybackJumpInterval
    private var cachedAudioDurations: [String: Double] = [:]
    private var cachedNarratedTimeline: [ClipTimelineEntry]?
    private var cachedNowPlayingArtwork: MPMediaItemArtwork?
    private var hasLoadedNowPlayingArtwork = false

    /// Test-only override for audio URL resolution. When set, `resolvedAudioFileURL`
    /// routes through this closure instead of materializing the asset from disk,
    /// allowing tests to inject delays and reproduce stale-start races.
    private var audioURLResolverOverride: ((String) async throws -> URL)?

    // Player, observers, and remote-command targets live in this holder so the
    // nonisolated deinit can clean them up without reading isolated state.
    private let resources = PlaybackResources()
    private var player: AVPlayer? {
        get { resources.player }
        set { resources.player = newValue }
    }
    private var boundaryObserver: Any? {
        get { resources.boundaryObserver }
        set { resources.boundaryObserver = newValue }
    }
    private var endObserver: NSObjectProtocol? {
        get { resources.endObserver }
        set { resources.endObserver = newValue }
    }
    private var periodicTimeObserver: Any? {
        get { resources.periodicTimeObserver }
        set { resources.periodicTimeObserver = newValue }
    }
    private var playCommandTarget: Any? {
        get { resources.playCommandTarget }
        set { resources.playCommandTarget = newValue }
    }
    private var pauseCommandTarget: Any? {
        get { resources.pauseCommandTarget }
        set { resources.pauseCommandTarget = newValue }
    }
    private var togglePlayPauseCommandTarget: Any? {
        get { resources.togglePlayPauseCommandTarget }
        set { resources.togglePlayPauseCommandTarget = newValue }
    }
    private var skipForwardCommandTarget: Any? {
        get { resources.skipForwardCommandTarget }
        set { resources.skipForwardCommandTarget = newValue }
    }
    private var skipBackwardCommandTarget: Any? {
        get { resources.skipBackwardCommandTarget }
        set { resources.skipBackwardCommandTarget = newValue }
    }
    private var loadedAudioPath: String?
    private var currentBookID: UUID?
    private var currentEPUBURL: URL?
    private var currentBookTitle: String?
    private var currentBookAuthor: String?
    private var currentBookCoverURL: URL?
    private var currentTransitionID: Int?
    private var startTask: Task<Void, Never>?
    private var updateNowPlayingTask: Task<Void, Never>?
    private var jumpAvailabilityRefreshTask: Task<Void, Never>?
    private var didConfigureRemoteCommands = false

    /// Idle delay before deactivating the audio session after an ordinary pause.
    /// An ordinary pause keeps the session active so resume is instant; if the
    /// user does not resume within this window the session is released so other
    /// apps' audio is not blocked.
    private let audioSessionIdleTimeout: TimeInterval = 60
    /// Pending deactivation scheduled by an ordinary pause. Cancelled on resume
    /// and on every immediate-deactivation path (stop/teardown/background).
    private var audioSessionIdleTask: Task<Void, Never>?

    var currentClip: EPUBMediaOverlayClip? {
        guard let currentClipIndex, clips.indices.contains(currentClipIndex) else {
            return nil
        }
        return clips[currentClipIndex]
    }

    func load(for book: Book, from jsonURL: URL?) async {
        stop(reason: "load")
        cachedAudioDurations = [:]
        cachedNarratedTimeline = nil
        cachedNowPlayingArtwork = nil
        hasLoadedNowPlayingArtwork = false
        currentBookID = book.id
        currentBookTitle = book.title
        currentBookAuthor = book.author
        // Resolve URLs up front; log (rather than swallow) failures so a missing
        // EPUB surfaces a real cause instead of only a generic playback error.
        do {
            currentEPUBURL = try book.resolvedEPUBFileURL()
        } catch {
            currentEPUBURL = nil
            print("MediaOverlayPlaybackController: could not resolve EPUB URL for \(book.title): \(error)")
        }
        do {
            currentBookCoverURL = try book.resolvedCoverImageURL()
        } catch {
            currentBookCoverURL = nil
            print("MediaOverlayPlaybackController: could not resolve cover URL for \(book.title): \(error)")
        }

        guard let jsonURL else {
            state = .unavailable
            clips = []
            currentClipIndex = nil
            clearNowPlayingInfo()
            scheduleRefreshJumpAvailability()
            return
        }

        do {
            clips = try await Task.detached(priority: .userInitiated) {
                try Self.resolvedClips(from: jsonURL)
            }.value
            currentClipIndex = nil
            state = clips.isEmpty ? .unavailable : .ready
            clearNowPlayingInfo()
            scheduleRefreshJumpAvailability()
        } catch {
            clips = []
            currentClipIndex = nil
            state = .failed(error.localizedDescription)
            clearNowPlayingInfo()
            scheduleRefreshJumpAvailability()
        }
    }

    nonisolated static func resolvedClips(from jsonURL: URL) throws -> [EPUBMediaOverlayClip] {
        let data = try Data(contentsOf: jsonURL)
        let manifest = try JSONDecoder().decode(EPUBMediaOverlayManifest.self, from: data)
        return manifest.documents.flatMap(\.clips)
    }

    func togglePlayback() {
        if state.isPlaying {
            pause(reason: "togglePlayback")
        } else {
            play(reason: "togglePlayback")
        }
    }

    func play(reason: String = "directPlay") {
        guard !clips.isEmpty else {
            state = .unavailable
            scheduleRefreshJumpAvailability()
            return
        }

        if currentClipIndex == nil {
            currentClipIndex = 0
        }

        guard let clip = currentClip else {
            state = .unavailable
            scheduleRefreshJumpAvailability()
            return
        }

        let transitionID = nextPlaybackTransitionID()
        currentTransitionID = transitionID
        start(clip, reason: reason, transitionID: transitionID)
    }

     func pause(reason: String = "directPause") {
          // Urgent path: pause audio and flip state so the button repaints
          // immediately. Everything else is deferred off this run-loop turn so
          // it cannot stall the tap.
          PlaybackSignposter.measure("pause.player") {
              player?.pause()
          }
          currentTransitionID = nil
          PlaybackSignposter.measure("pause.state") {
              if clips.isEmpty {
                  state = .unavailable
              } else {
                  state = .paused
              }
          }

          // An ordinary pause keeps the audio session active so resume is
          // instant; release it only after an idle timeout.
          scheduleAudioSessionIdleDeactivation(reason: reason)

          // Non-urgent work: lock-screen metadata and jump availability. Hop to
          // the next main-actor turn so SwiftUI has already repainted the icon.
          Task { @MainActor [weak self] in
              guard let self else { return }
              PlaybackSignposter.measure("pause.nowPlaying") {
                  self.updateNowPlayingInfo(playbackRateOverride: 0)
              }
              PlaybackSignposter.measure("pause.jumpAvailability") {
                  self.scheduleRefreshJumpAvailability()
              }
          }
      }

    func stop(reason: String = "directStop") {
        startTask?.cancel()
        startTask = nil
        updateNowPlayingTask?.cancel()
        updateNowPlayingTask = nil
        player?.pause()
        removeObservers(reason: "stop[\(reason)]")
        if let player {
            removePeriodicTimeObserver(from: player)
        }
        player = nil
        loadedAudioPath = nil
        deactivateAudioSession(reason: "stop[\(reason)]")
        currentTransitionID = nil
        currentClipIndex = clips.isEmpty ? nil : currentClipIndex
        state = clips.isEmpty ? .unavailable : .ready
        clearNowPlayingInfo()
        scheduleRefreshJumpAvailability()
    }

    func nextClip(reason: String = "manualNext") {
        guard let currentClipIndex else {
            return
        }

        guard let currentClip = currentClip else {
            return
        }

        let nextIndex = clips.index(after: currentClipIndex)
        guard clips.indices.contains(nextIndex) else {
            player?.pause()
            removeObservers(reason: "nextClip.noNext[\(reason)]")
            deactivateAudioSession(reason: "nextClip.noNext[\(reason)]")
            currentTransitionID = nil
            state = .ready
            clearNowPlayingInfo()
            scheduleRefreshJumpAvailability()
            return
        }

        let nextClip = clips[nextIndex]
        if continueCurrentItemForAutomaticAdvanceIfPossible(
            from: currentClip,
            to: nextClip,
            fromIndex: currentClipIndex,
            toIndex: nextIndex,
            reason: reason
        ) {
            return
        }

        self.currentClipIndex = nextIndex
        scheduleRefreshJumpAvailability()
        if state.isPlaying {
            play(reason: "nextClip[\(reason)]")
        }
    }

    func selectClip(at index: Int, autoplay: Bool, reason: String = "directSelect") {
        guard clips.indices.contains(index) else {
            return
        }
        player?.pause()
        removeObservers(reason: "selectClip[\(reason)]")
        deactivateAudioSession(reason: "selectClip[\(reason)]")
        currentTransitionID = nil

        currentClipIndex = index
        scheduleRefreshJumpAvailability()

        if autoplay {
            play(reason: "selectClip[\(reason)]")
        } else {
            state = .paused
            updateNowPlayingInfo(playbackRateOverride: 0)
            scheduleRefreshJumpAvailability()
        }
    }

    func setPlaybackRate(_ rate: Double) {
        let normalizedRate = ReaderSettings.normalizedPlaybackSpeed(rate)
        playbackRate = normalizedRate
        applyPlaybackRateIfNeeded(shouldUpdateActiveRate: state.isPlaying, reason: "setPlaybackRate")
        updateNowPlayingInfo(playbackRateOverride: state.isPlaying ? Float(normalizedRate) : 0)
    }

    func setJumpInterval(_ interval: Double) {
        jumpInterval = ReaderSettings.normalizedPlaybackJumpInterval(interval)
        updateRemoteCommandIntervals()
        scheduleRefreshJumpAvailability()
    }

    func canJump(by seconds: Double) async -> Bool {
        await resolvedJumpTargetIndex(by: seconds) != nil
    }

    func jump(by seconds: Double, reason: String = "manualJump") async {
        guard let startingClip = currentClip,
              let targetIndex = await resolvedJumpTargetIndex(by: seconds),
              isCurrentClip(startingClip)
        else {
            scheduleRefreshJumpAvailability()
            return
        }

        selectClip(at: targetIndex, autoplay: state.isPlaying, reason: "jump[\(reason)]")
    }

    /// Starts playback of a media overlay clip with race condition protection.
    ///
    /// This method handles the complex state transitions required for audio playback:
    /// 1. Cleans up any existing observers to prevent duplicate callbacks
    /// 2. Configures the audio session for playback
    /// 3. Prepares or reuses the AVPlayer for the clip's audio file
    /// 4. Seeks to the clip's start time with zero tolerance for precision
    /// 5. Verifies the clip is still current before starting (user may have navigated away)
    /// 6. Checks the transitionID to prevent stale async callbacks from starting playback
    ///
    /// The transitionID pattern prevents race conditions where:
    /// - User rapidly taps next/previous
    /// - Async seek completes after user has moved to a different clip
    /// - Old callback would incorrectly start playback of the wrong clip
    ///
    /// - Parameters:
    ///   - clip: The media overlay clip to play
    ///   - reason: Debug string for logging the playback trigger
    ///   - transitionID: Unique ID for this playback transition, used to invalidate stale callbacks
    private func start(_ clip: EPUBMediaOverlayClip, reason: String, transitionID: Int) {
        removeObservers(reason: "start[\(reason)]")

        do {
            try configureAudioSession()
        } catch {
            state = .failed(error.localizedDescription)
            scheduleRefreshJumpAvailability()
            return
        }

        // Cancel any prior in-flight start so a superseded transition stops its
        // audio-resolution work instead of running to completion.
        startTask?.cancel()
        startTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let audioURL = try await self.resolvedAudioFileURL(for: clip.audioPath)

                // A stale preparation must not mutate player state. By the time
                // the slow URL resolution above completes, the user may have
                // navigated to a newer clip and started a newer transition.
                // Validate the transition before touching self.player.
                guard !Task.isCancelled,
                      self.isCurrentClip(clip), self.currentTransitionID == transitionID else {
                    return
                }

                let player = self.applyPreparedPlayer(audioURL: audioURL, for: clip)
                player.pause()
                // Await the seek inside this task instead of using the callback
                // form, so the post-seek work stays anchored to `startTask`'s
                // lifetime. An escaping seek-completion handler could outlive the
                // task (and the controller), racing the deinit teardown of the
                // player's time observers and double-freeing an observer token.
                await player.seek(
                    to: CMTime(seconds: clip.clipBegin, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )

                guard !Task.isCancelled,
                      self.isCurrentClip(clip), self.currentTransitionID == transitionID else {
                    return
                }

                self.addObservers(for: clip, reason: reason, transitionID: transitionID)
                player.play()
                self.state = .playing
                self.applyPlaybackRateIfNeeded(
                    player: player,
                    shouldUpdateActiveRate: true,
                    reason: "start[\(reason)]",
                    transitionID: transitionID
                )
                self.updateNowPlayingInfo(playbackRateOverride: Float(self.playbackRate))
                self.scheduleRefreshJumpAvailability()
            } catch {
                // A stale preparation failure must not clobber the state of a
                // newer clip that is already playing.
                guard self.isCurrentClip(clip), self.currentTransitionID == transitionID else {
                    return
                }

                self.state = .failed(error.localizedDescription)
                self.clearNowPlayingInfo()
                self.scheduleRefreshJumpAvailability()
            }
        }
    }

    /// Applies a resolved audio URL to the player, reusing or creating the
    /// `AVPlayer` as needed. Synchronous and `@MainActor`-isolated: callers
    /// must validate the current transition before invoking this, since it
    /// mutates `self.player`, `loadedAudioPath`, and the time observers.
    private func applyPreparedPlayer(audioURL: URL, for clip: EPUBMediaOverlayClip) -> AVPlayer {
        if let player,
           loadedAudioPath == clip.audioPath,
           player.currentItem != nil {
            return player
        }

        let item = AVPlayerItem(url: audioURL)
        item.audioTimePitchAlgorithm = .timeDomain

        if let player {
            removePeriodicTimeObserver(from: player)
            player.replaceCurrentItem(with: item)
            addPeriodicTimeObserver(to: player)
            loadedAudioPath = clip.audioPath
            return player
        }

        let player = AVPlayer(playerItem: item)
        self.player = player
        addPeriodicTimeObserver(to: player)
        loadedAudioPath = clip.audioPath
        return player
    }

    private func resolvedAudioFileURL(for audioPath: String) async throws -> URL {
        if let audioURLResolverOverride {
            return try await audioURLResolverOverride(audioPath)
        }

        guard let currentBookID, let currentEPUBURL else {
            throw BookAssetCacheError.missingArchiveEntry(audioPath)
        }

        return try await Task.detached(priority: .userInitiated) {
            try await BookAssetCacheService.materializeAudioAsset(
                resourcePath: audioPath,
                bookID: currentBookID,
                epubURL: currentEPUBURL
            )
        }.value
    }

    private func applyPlaybackRateIfNeeded(
        player: AVPlayer? = nil,
        shouldUpdateActiveRate: Bool,
        reason: String,
        transitionID: Int? = nil
    ) {
        guard let player = player ?? self.player else {
            return
        }

        player.currentItem?.audioTimePitchAlgorithm = .timeDomain

        guard shouldUpdateActiveRate else {
            return
        }

        player.rate = Float(playbackRate)
    }

    private func scheduleRefreshJumpAvailability() {
        jumpAvailabilityRefreshTask?.cancel()
        jumpAvailabilityRefreshTask = Task { @MainActor [weak self] in
            await self?.refreshJumpAvailability()
        }
    }

    private func refreshJumpAvailability() async {
        guard !Task.isCancelled else {
            return
        }

        let backward = await canJump(by: -jumpInterval)
        guard !Task.isCancelled else {
            return
        }

        let forward = await canJump(by: jumpInterval)
        guard !Task.isCancelled else {
            return
        }

        canJumpBackward = backward
        canJumpForward = forward
    }

    private func resolvedJumpTargetIndex(by seconds: Double) async -> Int? {
        guard let currentClipIndex,
              clips.indices.contains(currentClipIndex),
              let currentClip
        else {
            return nil
        }

        let timeline = await narratedTimeline()
        guard self.currentClipIndex == currentClipIndex,
              isCurrentClip(currentClip)
        else {
            return nil
        }

        guard !timeline.isEmpty,
              let currentEntryIndex = timeline.firstIndex(where: { $0.clipIndex == currentClipIndex })
        else {
            return nil
        }

        let currentEntry = timeline[currentEntryIndex]
        let totalDuration = timeline.last?.end ?? 0
        guard totalDuration > 0 else {
            return nil
        }

        let currentOffset = await currentOffsetWithinCurrentClip()
        guard self.currentClipIndex == currentClipIndex,
              isCurrentClip(currentClip)
        else {
            return nil
        }

        let currentPosition = currentEntry.start + currentOffset
        let targetPosition = currentPosition + seconds

        if targetPosition < 0 {
            guard currentEntryIndex > 0 || currentOffset > 0 else {
                return nil
            }
            return timeline.first?.clipIndex
        }

        if targetPosition >= totalDuration {
            guard currentEntryIndex < timeline.count - 1 else {
                return nil
            }
            return timeline.last?.clipIndex
        }

        return timeline.first(where: { targetPosition >= $0.start && targetPosition < $0.end })?.clipIndex
            ?? timeline.last?.clipIndex
    }

    private func currentOffsetWithinCurrentClip() async -> Double {
        guard let currentClipIndex,
              clips.indices.contains(currentClipIndex),
              let currentClip = currentClip
        else {
            return 0
        }

        let duration = await effectiveDuration(for: currentClipIndex)
        guard self.currentClipIndex == currentClipIndex,
              isCurrentClip(currentClip)
        else {
            return 0
        }

        guard duration > 0 else {
            return 0
        }

        guard loadedAudioPath == currentClip.audioPath,
              let currentTime = player?.currentTime().seconds,
              currentTime.isFinite
        else {
            return 0
        }

        let offset = currentTime - currentClip.clipBegin
        guard offset.isFinite,
              offset >= -seamlessAutoAdvanceTolerance,
              offset <= duration + seamlessAutoAdvanceTolerance
        else {
            return 0
        }

        return min(max(offset, 0), duration)
    }

    private func narratedTimeline() async -> [ClipTimelineEntry] {
        // The lock-screen tick calls this twice a second; recomputing the
        // O(clips) timeline each time burns CPU for an unchanged result. The
        // cache is invalidated when a new audio duration is learned.
        if let cachedNarratedTimeline {
            return cachedNarratedTimeline
        }

        let clipSnapshot = clips
        var entries: [ClipTimelineEntry] = []
        var currentStart = 0.0

        for clipIndex in clipSnapshot.indices {
            let duration = await effectiveDuration(for: clipIndex, in: clipSnapshot)
            guard duration > 0 else {
                continue
            }

            let end = currentStart + duration
            entries.append(ClipTimelineEntry(clipIndex: clipIndex, start: currentStart, end: end))
            currentStart = end
        }

        cachedNarratedTimeline = entries
        return entries
    }

    private func effectiveDuration(for clipIndex: Int) async -> Double {
        await effectiveDuration(for: clipIndex, in: clips)
    }

    private func effectiveDuration(for clipIndex: Int, in clipList: [EPUBMediaOverlayClip]) async -> Double {
        guard clipList.indices.contains(clipIndex) else {
            return 0
        }

        let clip = clipList[clipIndex]
        if let clipEnd = clip.clipEnd, clipEnd > clip.clipBegin {
            return clipEnd - clip.clipBegin
        }

        let nextIndex = clipList.index(after: clipIndex)
        if clipList.indices.contains(nextIndex) {
            let nextClip = clipList[nextIndex]
            if nextClip.audioPath == clip.audioPath, nextClip.clipBegin > clip.clipBegin {
                return nextClip.clipBegin - clip.clipBegin
            }
        }

        let audioDuration = await audioDuration(for: clip.audioPath)
        guard audioDuration > clip.clipBegin else {
            return 0
        }
        return audioDuration - clip.clipBegin
    }

    private func audioDuration(for audioPath: String) async -> Double {
        if let cachedDuration = cachedAudioDurations[audioPath] {
            return cachedDuration
        }

        if loadedAudioPath == audioPath,
           let currentItemDuration = player?.currentItem?.duration.seconds,
           currentItemDuration.isFinite,
           currentItemDuration > 0 {
            cachedAudioDurations[audioPath] = currentItemDuration
            cachedNarratedTimeline = nil
            return currentItemDuration
        }

        let assetURL: URL
        do {
            assetURL = try await resolvedAudioFileURL(for: audioPath)
        } catch {
            return 0
        }

        let asset = AVURLAsset(url: assetURL)
        let assetDuration: Double
        do {
            assetDuration = try await asset.load(.duration).seconds
        } catch {
            return 0
        }

        guard assetDuration.isFinite, assetDuration > 0 else {
            return 0
        }

        cachedAudioDurations[audioPath] = assetDuration
        cachedNarratedTimeline = nil
        return assetDuration
    }

    private func isCurrentClip(_ clip: EPUBMediaOverlayClip) -> Bool {
        currentClip == clip
    }

    private func addObservers(for clip: EPUBMediaOverlayClip, reason: String, transitionID: Int) {
        guard let player else { return }

        if let clipEnd = clip.clipEnd, clipEnd > clip.clipBegin {
            boundaryObserver = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: CMTime(seconds: clipEnd, preferredTimescale: 600))],
                queue: .main
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.currentTransitionID == transitionID,
                          self.isCurrentClip(clip)
                    else {
                        return
                    }
                    self.nextClip(reason: "boundaryObserver transitionID=\(transitionID)")
                }
            }
        }

        // Always observe end-of-item, even when the clip has an explicit
        // `clipEnd`. The boundary time observer is not guaranteed to fire when
        // its boundary sits at (or essentially at) the audio file's true end:
        // the player reaches end-of-stream and pauses before crossing it. For
        // the last clip in an audio file (e.g. a chapter boundary) that would
        // otherwise leave playback stuck. This end observer is the fallback
        // that still advances. If both fire, `nextClip` is idempotent thanks
        // to the `currentTransitionID`/`isCurrentClip` guards.
        if let item = player.currentItem {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.currentTransitionID == transitionID,
                          self.isCurrentClip(clip)
                    else {
                        return
                    }
                    self.nextClip(reason: "itemEndObserver transitionID=\(transitionID)")
                }
            }
        }
    }

    private func removeObservers(reason: String) {
        if let boundaryObserver, let player {
            player.removeTimeObserver(boundaryObserver)
        }
        boundaryObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    private func continueCurrentItemForAutomaticAdvanceIfPossible(
        from currentClip: EPUBMediaOverlayClip,
        to nextClip: EPUBMediaOverlayClip,
        fromIndex: Int,
        toIndex: Int,
        reason: String
    ) -> Bool {
        guard state.isPlaying,
              isAutomaticAdvanceReason(reason),
              let player,
              player.currentItem != nil,
              currentClip.audioPath == nextClip.audioPath,
              loadedAudioPath == nextClip.audioPath,
              let currentClipEnd = currentClip.clipEnd,
              abs(currentClipEnd - nextClip.clipBegin) <= seamlessAutoAdvanceTolerance
        else {
            return false
        }

        let currentTime = player.currentTime().seconds
        guard currentTime.isFinite,
              abs(currentTime - nextClip.clipBegin) <= seamlessAutoAdvanceTolerance
        else {
            return false
        }

        removeObservers(reason: "continueSameAudioWithoutSeek[\(reason)]")
        currentClipIndex = toIndex

        let transitionID = nextPlaybackTransitionID()
        currentTransitionID = transitionID
        addObservers(for: nextClip, reason: "continueSameAudioWithoutSeek[\(reason)]", transitionID: transitionID)
        state = .playing
        updateNowPlayingInfo(playbackRateOverride: Float(playbackRate))
        scheduleRefreshJumpAvailability()
        return true
    }

    private func isAutomaticAdvanceReason(_ reason: String) -> Bool {
        reason.hasPrefix("boundaryObserver") || reason.hasPrefix("itemEndObserver")
    }

    private func addPeriodicTimeObserver(to player: AVPlayer) {
        removePeriodicTimeObserver(from: player)
        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlayingInfo()
            }
        }
    }

    private func removePeriodicTimeObserver(from player: AVPlayer) {
        if let periodicTimeObserver {
            player.removeTimeObserver(periodicTimeObserver)
        }
        periodicTimeObserver = nil
    }

    private func updateNowPlayingInfo(playbackRateOverride: Float? = nil) {
        guard let clip = currentClip,
              let clipIndex = currentClipIndex,
              let clipID = clipIdentity(for: clip)
        else {
            clearNowPlayingInfo()
            return
        }

        let activePlaybackRate = playbackRateOverride ?? currentPlaybackRate()
        // Coalesce updates: the periodic observer fires every 0.5s, so cancel
        // any prior in-flight snapshot task and replace it with the freshest one
        // instead of letting them pile up.
        updateNowPlayingTask?.cancel()
        updateNowPlayingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let snapshot = await self.nowPlayingSnapshot(for: clip, clipIndex: clipIndex, clipID: clipID) else {
                self.clearNowPlayingInfo()
                return
            }

            guard !Task.isCancelled else {
                return
            }

            var nowPlayingInfo: [String: Any] = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            nowPlayingInfo[MPMediaItemPropertyTitle] = snapshot.displayTitle
            nowPlayingInfo[MPMediaItemPropertyArtist] = snapshot.displayArtist
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyAlbumTitle)
            nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = activePlaybackRate
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = snapshot.elapsedTime
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = snapshot.duration

            if let artwork = self.nowPlayingArtwork() {
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
            } else {
                nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtwork)
            }

            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }

        configureRemoteCommandsIfNeeded()
        updateRemoteCommandIntervals()
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func currentPlaybackRate() -> Float {
        state.isPlaying ? Float(playbackRate) : 0
    }

    private func clipIdentity(for clip: EPUBMediaOverlayClip?) -> String? {
        clip?.identityKey
    }

    private func nowPlayingArtwork() -> MPMediaItemArtwork? {
        // The cover is constant per loaded book; decoding it from disk on
        // every 0.5 s lock-screen tick wastes CPU and battery.
        if hasLoadedNowPlayingArtwork {
            return cachedNowPlayingArtwork
        }
        hasLoadedNowPlayingArtwork = true

        guard let currentBookCoverURL,
              let image = UIImage(contentsOfFile: currentBookCoverURL.path)
        else {
            cachedNowPlayingArtwork = nil
            return nil
        }

        cachedNowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        return cachedNowPlayingArtwork
    }

    private func nowPlayingSnapshot(
        for clip: EPUBMediaOverlayClip,
        clipIndex: Int,
        clipID: String
    ) async -> NowPlayingSnapshot? {
        let timeline = await narratedTimeline()
        guard currentClipIndex == clipIndex,
              clipIdentity(for: currentClip) == clipID,
              let currentEntry = timeline.first(where: { $0.clipIndex == clipIndex })
        else {
            return nil
        }

        let clipOffset = await currentOffsetWithinCurrentClip()
        guard currentClipIndex == clipIndex,
              clipIdentity(for: currentClip) == clipID
        else {
            return nil
        }

        let totalDuration = timeline.last?.end ?? 0
        let elapsedTime = min(max(currentEntry.start + clipOffset, 0), totalDuration)
        let displayTitle = currentBookTitle ?? "Read Aloud"
        let displayArtist = currentBookAuthor

        return NowPlayingSnapshot(
            displayTitle: displayTitle,
            displayArtist: displayArtist,
            elapsedTime: elapsedTime,
            duration: totalDuration
        )
    }

    private func configureRemoteCommandsIfNeeded() {
        guard !didConfigureRemoteCommands else {
            return
        }

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false

        playCommandTarget = commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.play(reason: "remote.play")
            return .success
        }

        pauseCommandTarget = commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.pause(reason: "remote.pause")
            return .success
        }

        togglePlayPauseCommandTarget = commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.togglePlayback()
            return .success
        }

        skipForwardCommandTarget = commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.jump(by: self.jumpInterval, reason: "remote.skipForward")
            }
            return .success
        }

        skipBackwardCommandTarget = commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.jump(by: -self.jumpInterval, reason: "remote.skipBackward")
            }
            return .success
        }

        didConfigureRemoteCommands = true
    }

    private func updateRemoteCommandIntervals() {
        let interval = NSNumber(value: jumpInterval)
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipForwardCommand.preferredIntervals = [interval]
        commandCenter.skipBackwardCommand.preferredIntervals = [interval]
    }

    private func configureAudioSession() throws {
        cancelAudioSessionIdleDeactivation()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func deactivateAudioSession(reason: String) {
        // Any explicit deactivation supersedes a pending idle one.
        cancelAudioSessionIdleDeactivation()
        PlaybackSignposter.measure("pause.deactivate") {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    func applicationDidEnterBackground() {
        // Background playback keeps the session active. If paused, release it so
        // other apps' audio is not blocked.
        if !state.isPlaying {
            deactivateAudioSession(reason: "scenePhase.background")
        }
    }

    func applicationWillEnterForeground(
        backgroundedFor duration: TimeInterval,
        rewindThresholdMinutes: Int,
        rewindSeconds: Double
    ) async {
        guard duration >= TimeInterval(rewindThresholdMinutes * 60),
              currentClip != nil,
              !state.isPlaying
        else {
            return
        }

        await jump(by: -rewindSeconds, reason: "autoRewindAfterBackground")
    }

    /// Schedules deactivation of the audio session after `audioSessionIdleTimeout`
    /// unless playback resumes (which cancels it via `configureAudioSession`).
    private func scheduleAudioSessionIdleDeactivation(reason: String) {
        audioSessionIdleTask?.cancel()
        audioSessionIdleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.audioSessionIdleTimeout * 1_000_000_000))
            guard !Task.isCancelled, !self.state.isPlaying else { return }
            self.deactivateAudioSession(reason: "idle[\(reason)]")
        }
    }

    private func cancelAudioSessionIdleDeactivation() {
        audioSessionIdleTask?.cancel()
        audioSessionIdleTask = nil
    }

    private func nextPlaybackTransitionID() -> Int {
        nextTransitionID += 1
        return nextTransitionID
    }

    deinit {
        jumpAvailabilityRefreshTask?.cancel()
        startTask?.cancel()
        updateNowPlayingTask?.cancel()
        // Read only the resource holder (a `let`, assigned once) — never the
        // controller's isolated stored properties.
        let resources = resources
        // Tear observers down synchronously when deinit already runs on the main
        // thread. Deferring to `DispatchQueue.main.async` left the time-observer
        // removal to fire on a later run-loop turn — potentially in the middle of
        // an unrelated later XCTest — which raced other AVPlayer teardown and
        // over-released an observer token ("pointer being freed was not
        // allocated"). Doing it inline ties the teardown to this object's
        // lifetime. Off the main thread (the AVPlayer APIs require main), fall
        // back to a synchronous hop.
        if Thread.isMainThread {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            resources.teardown()
        } else {
            DispatchQueue.main.sync {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                resources.teardown()
            }
        }
    }
}

private struct ClipTimelineEntry {
    let clipIndex: Int
    let start: Double
    let end: Double
}

#if DEBUG
extension MediaOverlayPlaybackController {
    /// Injects clips and a custom audio URL resolver for testing, bypassing the
    /// disk-backed asset materialization and EPUB loading path.
    func configureForTesting(
        clips: [EPUBMediaOverlayClip],
        audioURLResolver: @escaping (String) async throws -> URL
    ) {
        self.clips = clips
        self.audioURLResolverOverride = audioURLResolver
        self.currentClipIndex = nil
        self.state = clips.isEmpty ? .unavailable : .ready
    }

    var test_loadedAudioPath: String? { loadedAudioPath }

    /// True when an end-of-item observer is registered. Used to verify that a
    /// clip with an explicit `clipEnd` still gets the end-of-file fallback that
    /// auto-advances across chapter boundaries.
    var test_hasEndObserver: Bool { endObserver != nil }

    /// True when the most recent start transition's task has been cancelled.
    /// Used to verify a superseded start stops its audio-resolution work.
    var test_isStartTaskCancelled: Bool { startTask?.isCancelled ?? false }

    /// Synchronously tears the controller down for tests so AVPlayer observer
    /// removal is completed before the test releases its last reference.
    func test_teardown() {
        stop(reason: "test_teardown")
    }
}
#endif
