//
//  MediaOverlayPlaybackController.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class MediaOverlayPlaybackController: ObservableObject {
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

    private static var nextTransitionID: Int = 0
    /// Maximum time gap (in seconds) between consecutive clips in the same audio file
    /// that allows seamless playback without reloading the player.
    /// Clips separated by less than this duration will continue playing from the current position.
    private let seamlessAutoAdvanceTolerance: Double = 0.1
    private var playbackRate = ReaderSettings.defaultPlaybackSpeed
    private var jumpInterval = ReaderSettings.defaultPlaybackJumpInterval
    private var cachedAudioDurations: [String: Double] = [:]

    private var player: AVPlayer?
    private var loadedAudioPath: String?
    private var currentBookID: UUID?
    private var currentEPUBURL: URL?
    private var boundaryObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var currentTransitionID: Int?
    private var jumpAvailabilityRefreshTask: Task<Void, Never>?

    var currentClip: EPUBMediaOverlayClip? {
        guard let currentClipIndex, clips.indices.contains(currentClipIndex) else {
            return nil
        }
        return clips[currentClipIndex]
    }

    func load(for book: Book, from jsonURL: URL?) async {
        stop(reason: "load")
        cachedAudioDurations = [:]
        currentBookID = book.id
        currentEPUBURL = try? book.resolvedEPUBFileURL()

        guard let jsonURL else {
            state = .unavailable
            clips = []
            currentClipIndex = nil
            scheduleRefreshJumpAvailability()
            return
        }

        do {
            clips = try await Task.detached(priority: .userInitiated) {
                try Self.resolvedClips(from: jsonURL)
            }.value
            currentClipIndex = nil
            state = clips.isEmpty ? .unavailable : .ready
            scheduleRefreshJumpAvailability()
        } catch {
            clips = []
            currentClipIndex = nil
            state = .failed(error.localizedDescription)
            scheduleRefreshJumpAvailability()
        }
    }

    nonisolated private static func resolvedClips(from jsonURL: URL) throws -> [EPUBMediaOverlayClip] {
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
         player?.pause()
         currentTransitionID = nil
         if clips.isEmpty {
             state = .unavailable
         } else {
             state = .paused
         }
        deactivateAudioSession(reason: "pause[\(reason)]")
         scheduleRefreshJumpAvailability()
     }

    func stop(reason: String = "directStop") {
        player?.pause()
        removeObservers(reason: "stop[\(reason)]")
        player = nil
        loadedAudioPath = nil
        deactivateAudioSession(reason: "stop[\(reason)]")
        currentTransitionID = nil
        currentClipIndex = clips.isEmpty ? nil : currentClipIndex
        state = clips.isEmpty ? .unavailable : .ready
        scheduleRefreshJumpAvailability()
    }

    func previousClip(reason: String = "manualPrevious") {
        guard let currentClipIndex, currentClipIndex > 0 else {
            return
        }
        self.currentClipIndex = currentClipIndex - 1
        scheduleRefreshJumpAvailability()
        if state.isPlaying {
            play(reason: "previousClip[\(reason)]")
        }
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
            scheduleRefreshJumpAvailability()
        }
    }

    func setPlaybackRate(_ rate: Double) {
        let normalizedRate = ReaderSettings.normalizedPlaybackSpeed(rate)
        playbackRate = normalizedRate
        applyPlaybackRateIfNeeded(shouldUpdateActiveRate: state.isPlaying, reason: "setPlaybackRate")
    }

    func setJumpInterval(_ interval: Double) {
        jumpInterval = ReaderSettings.normalizedPlaybackJumpInterval(interval)
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

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let player = try await self.preparedPlayer(for: clip)
                player.pause()
                player.seek(to: CMTime(seconds: clip.clipBegin, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, clip, player] _ in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        guard self.isCurrentClip(clip) else {
                            return
                        }

                        guard self.currentTransitionID == transitionID else {
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
                        self.scheduleRefreshJumpAvailability()
                    }
                }
            } catch {
                self.state = .failed(error.localizedDescription)
                self.scheduleRefreshJumpAvailability()
            }
        }
    }

    private func preparedPlayer(for clip: EPUBMediaOverlayClip) async throws -> AVPlayer {
        let audioURL = try await resolvedAudioFileURL(for: clip.audioPath)
        if let player,
           loadedAudioPath == clip.audioPath,
           player.currentItem != nil {
            return player
        }

        let item = AVPlayerItem(url: audioURL)
        item.audioTimePitchAlgorithm = .timeDomain

        if let player {
            player.replaceCurrentItem(with: item)
            loadedAudioPath = clip.audioPath
            return player
        }

        let player = AVPlayer(playerItem: item)
        self.player = player
        loadedAudioPath = clip.audioPath
        return player
    }

    private func resolvedAudioFileURL(for audioPath: String) async throws -> URL {
        guard let currentBookID, let currentEPUBURL else {
            throw BookAssetCacheError.missingArchiveEntry(audioPath)
        }

        return try await Task.detached(priority: .userInitiated) {
            try BookAssetCacheService.materializeAudioAsset(
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
        return assetDuration
    }

    private func isCurrentClip(_ clip: EPUBMediaOverlayClip) -> Bool {
        guard let currentClip else {
            return false
        }

        return currentClip.audioPath == clip.audioPath &&
            currentClip.textResourceHref == clip.textResourceHref &&
            currentClip.fragmentID == clip.fragmentID &&
            currentClip.clipBegin == clip.clipBegin &&
            currentClip.clipEnd == clip.clipEnd
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

        if clip.clipEnd == nil, let item = player.currentItem {
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
        scheduleRefreshJumpAvailability()
        return true
    }

    private func isAutomaticAdvanceReason(_ reason: String) -> Bool {
        reason.hasPrefix("boundaryObserver") || reason.hasPrefix("itemEndObserver")
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    private func deactivateAudioSession(reason: String) {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func nextPlaybackTransitionID() -> Int {
        Self.nextTransitionID += 1
        return Self.nextTransitionID
    }

    deinit {
        jumpAvailabilityRefreshTask?.cancel()
        let player = player
        let boundaryObserver = boundaryObserver
        let endObserver = endObserver
        DispatchQueue.main.async {
            if let boundaryObserver, let player {
                player.removeTimeObserver(boundaryObserver)
            }
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
            }
        }
    }
}

private struct ClipTimelineEntry {
    let clipIndex: Int
    let start: Double
    let end: Double
}
