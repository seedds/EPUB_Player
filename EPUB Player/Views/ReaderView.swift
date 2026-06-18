//
//  ReaderView.swift
//  EPUB Player
//
//  Created by F2PGOD on 25/4/2026.
//

import ReadiumNavigator
import ReadiumShared
import SwiftUI
import UIKit
import WebKit

struct ReaderView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: AppStateStore
    @StateObject private var playback = MediaOverlayPlaybackController()

    @ObservedObject var book: Book

    @State private var state: ReaderState = .loading
    @State private var chapterItems: [ChapterListItem] = []
    @State private var isChapterListPresented = false
    @State private var currentLocationReference: EPUBReference?
    @State private var currentChapterProgress: Double?
    @State private var readingOrderResourceHrefs: [String] = []
    @State private var isPlaybackSpeedControlPresented = false
    @State private var isReaderSettingsControlPresented = false
    @State private var customFontFamilies: [CustomFontStore.ImportedFontFamily] = []
    @State private var layoutPreferenceTransitionID = 0
    @State private var suppressedLocationPersistenceDepth = 0
    @State private var navigatorFrame: CGRect = .zero
    @State private var playbackBarFrame: CGRect = .zero
    @State private var lastHandledPlaybackStartClipKey: String?
    @State private var pendingDecorationClipKey: String?
    @State private var pendingChapterEntryPlaybackStartClipKey: String?
    @State private var backgroundEnteredAt: Date?
    @State private var openingStatusMessage = "Opening EPUB..."
    @State private var openingSecondaryMessage: String?
    @State private var openingProgress: Double?
    @State private var hasRestoredPlaybackState = false

    var body: some View {
        Group {
            switch state {
            case .loading:
                loadingView

            case .ready(_, let navigator):
                readyReaderView(for: navigator)

            case .failed(let message):
                ContentUnavailableView(
                    "Couldn’t Open EPUB",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if case .ready = state {
                ToolbarItem(placement: .topBarTrailing) {
                    let isBookmarked = isCurrentLocationBookmarked
                    Button {
                        toggleBookmarkAtCurrentLocation()
                    } label: {
                        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    }
                    .accessibilityLabel(isBookmarked ? "Remove Bookmark" : "Add Bookmark")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismissBottomControls()
                        isChapterListPresented = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("Chapters & Bookmarks")
                }
            }
        }
        .navigationDestination(isPresented: $isChapterListPresented) {
            ChapterAndBookmarkScreen(
                items: chapterItems,
                selectedItemID: activeChapterItemID,
                bookmarks: book.bookmarks.sorted { $0.createdAt > $1.createdAt },
                history: book.history.sorted { $0.createdAt > $1.createdAt },
                onSelectChapter: { item in
                    guard case .ready(_, let navigator) = state else {
                        return
                    }
                    isChapterListPresented = false
                    Task {
                        await selectChapter(item, navigator: navigator)
                    }
                },
                onSelectBookmark: { bookmark in
                    guard case .ready(_, let navigator) = state else {
                        return
                    }
                    isChapterListPresented = false
                    Task {
                        await goToBookmark(bookmark, navigator: navigator)
                    }
                },
                onDeleteBookmarks: { ids in
                    book.bookmarks.removeAll { ids.contains($0.id) }
                },
                onSelectHistory: { entry in
                    guard case .ready(_, let navigator) = state else {
                        return
                    }
                    isChapterListPresented = false
                    Task {
                        await goToHistoryEntry(entry, navigator: navigator)
                    }
                },
                onDeleteHistory: { ids in
                    book.history.removeAll { ids.contains($0.id) }
                    store.persistNow()
                }
            )
        }
        .task(id: book.id) {
            await openBook()
        }
        .onDisappear {
            persistLastPlayedClip(immediately: true)
            isPlaybackSpeedControlPresented = false
            isReaderSettingsControlPresented = false
            // Don't tear down playback when disappearing because we pushed the
            // chapters/bookmarks screen on top of the reader; only stop when the
            // reader is actually being closed.
            guard !isChapterListPresented else {
                return
            }
            lastHandledPlaybackStartClipKey = nil
            pendingDecorationClipKey = nil
            backgroundEnteredAt = nil
            playback.stop(reason: "readerView.onDisappear")
        }
        .onChange(of: scenePhase) { _, newPhase in
            Task {
                await handleScenePhaseChange(newPhase)
            }
        }
    }

    @MainActor
    private func openBook() async {
        guard case .loading = state else {
            return
        }

        book.lastOpenedAt = Date()
        store.persistNow()
        playback.setPlaybackRate(store.playbackSpeed)
        playback.setJumpInterval(store.playbackJumpInterval)

        if shouldWaitForMediaOverlayPreparationBeforeOpening {
            openingStatusMessage = "Preparing read-aloud..."
            openingSecondaryMessage = "Checking media overlays..."
            openingProgress = 0
            await MediaOverlayPreparationCoordinator.shared.ensurePreparedForPlayback(bookID: book.id, store: store) { progress in
                openingStatusMessage = "Preparing read-aloud..."
                openingSecondaryMessage = progress.message
                openingProgress = progress.fractionCompleted
            }
        }

        openingStatusMessage = "Opening EPUB..."
        openingSecondaryMessage = nil
        openingProgress = nil
        await loadMediaOverlaysIfAvailable()
        customFontFamilies = CustomFontStore.allFamilies(store: store)

        do {
            let publication = try await ReadiumBookService.shared.openPublication(for: book)
            let initialLocation = savedLocation()
            let chapterItems = await loadChapterItems(from: publication)
            let preferences = readerPreferences()
            let navigator = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initialLocation,
                config: .init(
                    preferences: preferences,
                    defaults: EPUBDefaults(scroll: true, spread: .never),
                    disablePageTurnsWhileScrolling: true,
                    decorationTemplates: readerDecorationTemplates(),
                    fontFamilyDeclarations: fontFamilyDeclarations()
                )
            )
            navigator.submitPreferences(preferences)
            self.chapterItems = chapterItems
            self.readingOrderResourceHrefs = publication.readingOrder.map { normalizedResourceHref(for: $0.href) }
            state = .ready(publication: publication, navigator: navigator)
            await restoreLastPlayedClipSelectionIfAvailable(with: navigator)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func handleScenePhaseChange(_ newPhase: ScenePhase) async {
        switch newPhase {
        case .background:
            backgroundEnteredAt = Date()
            if playback.currentClip != nil {
                persistLastPlayedClip(immediately: true)
            }
        case .active:
            await handleAutoRewindIfNeeded()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    @MainActor
    private func handleAutoRewindIfNeeded() async {
        guard let backgroundEnteredAt else {
            return
        }

        self.backgroundEnteredAt = nil

        let requiredMinutes = ReaderSettings.normalizedAutoRewindAfterBackgroundMinutes(
            store.autoRewindAfterBackgroundMinutes
        )
        let requiredBackgroundDuration = TimeInterval(requiredMinutes * 60)

        guard Date().timeIntervalSince(backgroundEnteredAt) >= requiredBackgroundDuration,
              playback.currentClip != nil,
              !playback.state.isPlaying
        else {
            return
        }

        await playback.jump(by: -10, reason: "autoRewindAfterBackground")
    }

    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 14) {
            if let openingProgress {
                ProgressView(value: openingProgress)
                    .tint(.accentColor)

                Text(openingStatusMessage)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if let openingSecondaryMessage, !openingSecondaryMessage.isEmpty {
                    Text(openingSecondaryMessage)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                Text("\(Int((openingProgress * 100).rounded()))%")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView(openingStatusMessage)

                if let openingSecondaryMessage, !openingSecondaryMessage.isEmpty {
                    Text(openingSecondaryMessage)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 320)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var shouldWaitForMediaOverlayPreparationBeforeOpening: Bool {
        switch book.mediaOverlayPreparationState {
        case .failed:
            return false
        case .pending, .processing:
            return true
        case .ready:
            return !BookAssetCacheService.hasValidOverlayCache(for: book)
        }
    }

    private func readerPreferences() -> EPUBPreferences {
        let background = ReaderSettings.readingBackground(from: store.readingBackgroundRawValue)
        let backgroundColor = ReadiumNavigator.Color(hex: background.backgroundHex)
        let textColor = ReadiumNavigator.Color(hex: background.textHex)
        return EPUBPreferences(
            backgroundColor: backgroundColor,
            fontFamily: ReaderSettings.fontFamily(from: store.fontFamilyRawValue),
            fontSize: ReaderSettings.normalizedFontSize(store.fontSize),
            lineHeight: ReaderSettings.normalizedLineHeight(store.lineHeight),
            publisherStyles: false,
            scroll: true,
            textColor: textColor,
            theme: ReaderSettings.appTheme(from: store.themeRawValue).readiumTheme(for: colorScheme)
        )
    }

    /// Forces the reading background to match the current theme (light -> white,
    /// dark -> black). System resolves via the device color scheme.
    @MainActor
    private func applyThemeBackground() {
        let background = ReaderSettings.defaultBackground(
            forTheme: ReaderSettings.appTheme(from: store.themeRawValue),
            colorScheme: colorScheme
        )
        if store.readingBackgroundRawValue != background.rawValue {
            store.readingBackgroundRawValue = background.rawValue
        }
    }

    @ViewBuilder
    private func readyReaderView(for navigator: EPUBNavigatorViewController) -> some View {
        readerSettingsObservers(for: navigator) {
            navigatorHost(for: navigator)
            .onChange(of: playback.currentClipIndex) { oldIndex, newIndex in
                handleCurrentClipChange(oldIndex: oldIndex, newIndex: newIndex, navigator: navigator)
            }
            .onChange(of: playback.state) { oldValue, newValue in
                if oldValue.isPlaying && !newValue.isPlaying {
                    lastHandledPlaybackStartClipKey = nil
                    recordHistory(reason: .paused)
                    return
                }

                guard !oldValue.isPlaying, newValue.isPlaying else {
                    return
                }

                recordHistory(reason: .played)
                Task {
                    await handleClipPlaybackStartIfNeeded(with: navigator)
                }
            }
            .onChange(of: book.mediaOverlayPreparationState) { _, _ in
                Task {
                    await loadMediaOverlaysIfAvailable()
                }
            }
            .onChange(of: book.mediaOverlayJSONPath) { _, _ in
                Task {
                    await loadMediaOverlaysIfAvailable()
                }
            }
            .onPreferenceChange(NavigatorFramePreferenceKey.self) { navigatorFrame = $0 }
            .onPreferenceChange(PlaybackBarFramePreferenceKey.self) { playbackBarFrame = $0 }
        }
    }

    @ViewBuilder
    private func readerSettingsObservers<Content: View>(
        for navigator: EPUBNavigatorViewController,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .onChange(of: store.fontSize) { _, _ in
                Task {
                    await applyReaderPreferencesPreservingViewportAnchor(to: navigator)
                }
            }
            .onChange(of: store.lineHeight) { _, _ in
                Task {
                    await applyReaderPreferencesPreservingViewportAnchor(to: navigator)
                }
            }
            .onChange(of: store.fontFamilyRawValue) { _, _ in
                Task {
                    await applyReaderPreferencesPreservingViewportAnchor(to: navigator)
                }
            }
            .onChange(of: store.themeRawValue) { _, _ in
                applyThemeBackground()
                applyReaderPreferences(to: navigator)
            }
            .onChange(of: store.readingBackgroundRawValue) { _, _ in
                applyReaderPreferences(to: navigator)
            }
            .onChange(of: store.readAloudColorRawValue) { _, _ in
                applyCurrentClipDecoration(with: navigator)
            }
            .onChange(of: store.playbackSpeed) { _, newValue in
                playback.setPlaybackRate(newValue)
            }
            .onChange(of: store.playbackJumpInterval) { _, newValue in
                playback.setJumpInterval(newValue)
            }
            .onChange(of: colorScheme) { _, _ in
                if ReaderSettings.appTheme(from: store.themeRawValue) == .system {
                    applyThemeBackground()
                    applyReaderPreferences(to: navigator)
                }
            }
    }

    @ViewBuilder
    private func navigatorHost(for navigator: EPUBNavigatorViewController) -> some View {
        EPUBNavigatorHost(
            navigator: navigator,
            onLocationDidChange: { locator in
                handleLocationDidChange(locator, navigator: navigator)
            },
            onAudioTap: { resourceHref, point in
                Task {
                    await playFromTappedPoint(resourceHref: resourceHref, point: point, navigator: navigator)
                }
            }
        )
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: NavigatorFramePreferenceKey.self, value: proxy.frame(in: .global))
            }
        }
        .overlay {
            if isBottomControlPresented {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissBottomControls()
                    }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomInset(for: navigator)
        }
    }

    @ViewBuilder
    private func bottomInset(for navigator: EPUBNavigatorViewController) -> some View {
        if !playback.clips.isEmpty {
            MediaOverlayPlaybackBar(
                playback: playback,
                playbackSpeed: $store.playbackSpeed,
                playbackJumpInterval: store.playbackJumpInterval,
                fontSize: $store.fontSize,
                lineHeight: $store.lineHeight,
                fontFamilyRawValue: $store.fontFamilyRawValue,
                readingBackgroundRawValue: $store.readingBackgroundRawValue,
                customFontFamilies: customFontFamilies,
                isSpeedControlPresented: $isPlaybackSpeedControlPresented,
                isReaderSettingsControlPresented: $isReaderSettingsControlPresented,
                toggleSpeedControl: togglePlaybackSpeedControl,
                toggleReaderSettingsControl: toggleReaderSettingsControl,
                playPause: {
                    if playback.state.isPlaying {
                        playback.pause(reason: "playPauseButton.pause")
                    } else if playback.currentClipIndex != nil {
                        playback.play(reason: "playPauseButton.resumeCurrentClip")
                    } else {
                        Task {
                            await startPlaybackFromVisibleOrForwardPosition(with: navigator)
                        }
                    }
                },
                previous: {
                    Task {
                        await playback.jump(
                            by: -ReaderSettings.normalizedPlaybackJumpInterval(store.playbackJumpInterval),
                            reason: "playbackBar.previousButton"
                        )
                    }
                },
                next: {
                    Task {
                        await playback.jump(
                            by: ReaderSettings.normalizedPlaybackJumpInterval(store.playbackJumpInterval),
                            reason: "playbackBar.nextButton"
                        )
                    }
                }
            )
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: PlaybackBarFramePreferenceKey.self, value: proxy.frame(in: .global))
                }
            }
        } else if let readAloudStatusMessage {
            ReadAloudStatusView(message: readAloudStatusMessage)
        }
    }

    @MainActor
    private func loadMediaOverlaysIfAvailable() async {
        await playback.load(for: book, from: try? book.resolvedMediaOverlayJSONURL())
    }

    private var readAloudStatusMessage: String? {
        guard playback.clips.isEmpty else {
            return nil
        }

        switch book.mediaOverlayPreparationState {
        case .pending, .processing:
            return "Preparing read-aloud..."
        case .failed:
            if let reason = book.mediaOverlayPreparationError, !reason.isEmpty {
                return "Read-aloud is unavailable: \(reason) Return to Books and tap Refresh to retry."
            }
            return "Read-aloud is unavailable for this book. Return to Books and tap Refresh to retry."
        case .ready:
            // The book is marked ready, but the playback controller is the source
            // of truth for the cached manifest. A corrupt or stale cache surfaces
            // here as a load failure even though preparation state says ready.
            if case .failed = playback.state {
                return "Read-aloud is unavailable for this book. Return to Books and tap Refresh to retry."
            }
            return nil
        }
    }

    private func fontFamilyDeclarations() -> [AnyHTMLFontFamilyDeclaration] {
        bundledFontFamilyDeclarations() + CustomFontStore.fontFamilyDeclarations(customFontFamilies: customFontFamilies)
    }

    private func bundledFontFamilyDeclarations() -> [AnyHTMLFontFamilyDeclaration] {
        guard let regularFont = bundledFontURL(named: "Literata-VariableFont_opsz-wght.ttf"),
              let italicFont = bundledFontURL(named: "Literata-Italic-VariableFont_opsz-wght.ttf")
        else {
            return []
        }

        return [
            CSSFontFamilyDeclaration(
                fontFamily: "Literata",
                fontFaces: [
                    CSSFontFace(
                        file: regularFont,
                        style: .normal,
                        weight: .variable(200 ... 900)
                    ),
                    CSSFontFace(
                        file: italicFont,
                        style: .italic,
                        weight: .variable(200 ... 900)
                    ),
                ]
            )
            .eraseToAnyHTMLFontFamilyDeclaration(),
        ]
    }

    private func bundledFontURL(named filename: String) -> FileURL? {
        guard let url = Bundle.main.url(forResource: filename, withExtension: nil) else {
            return nil
        }
        return FileURL(url: url)
    }

    @MainActor
    private func applyReaderPreferences(to navigator: EPUBNavigatorViewController) {
        navigator.submitPreferences(readerPreferences())
    }

    @MainActor
    private func applyReaderPreferencesPreservingViewportAnchor(to navigator: EPUBNavigatorViewController) async {
        layoutPreferenceTransitionID += 1
        let transitionID = layoutPreferenceTransitionID

        // Coalesce rapid slider and font taps so only the latest reflow runs.
        try? await Task.sleep(nanoseconds: 50_000_000)
        guard transitionID == layoutPreferenceTransitionID else {
            return
        }

        let anchor = await currentViewportAnchor(with: navigator) ?? currentLocationReference
        beginSuppressingLocationPersistence()
        defer { endSuppressingLocationPersistence() }

        navigator.submitPreferences(readerPreferences())

        // Give Readium a brief moment to finish the internal reflow before restoring.
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard transitionID == layoutPreferenceTransitionID,
              let anchor
        else {
            return
        }

        await restoreViewportAnchor(anchor, with: navigator)
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    @MainActor
    private func beginSuppressingLocationPersistence() {
        suppressedLocationPersistenceDepth += 1
    }

    @MainActor
    private func endSuppressingLocationPersistence() {
        suppressedLocationPersistenceDepth = max(0, suppressedLocationPersistenceDepth - 1)
    }

    private var isSuppressingLocationPersistence: Bool {
        suppressedLocationPersistenceDepth > 0
    }

    private var isBottomControlPresented: Bool {
        isPlaybackSpeedControlPresented || isReaderSettingsControlPresented
    }

    private func dismissBottomControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isPlaybackSpeedControlPresented = false
            isReaderSettingsControlPresented = false
        }
    }

    private func togglePlaybackSpeedControl() {
        withAnimation(.easeInOut(duration: 0.2)) {
            let shouldPresent = !isPlaybackSpeedControlPresented
            isPlaybackSpeedControlPresented = shouldPresent
            if shouldPresent {
                isReaderSettingsControlPresented = false
            }
        }
    }

    private func toggleReaderSettingsControl() {
        withAnimation(.easeInOut(duration: 0.2)) {
            let shouldPresent = !isReaderSettingsControlPresented
            isReaderSettingsControlPresented = shouldPresent
            if shouldPresent {
                isPlaybackSpeedControlPresented = false
            }
        }
    }

    private func loadChapterItems(from publication: Publication) async -> [ChapterListItem] {
        let links = (try? await publication.tableOfContents().get()) ?? publication.readingOrder
        return flattenChapterLinks(links)
    }

    private func savedLocation() -> Locator? {
        guard let lastLocatorJSON = book.lastLocatorJSON else {
            return nil
        }
        return (try? Locator(jsonString: lastLocatorJSON)) ?? nil
    }

    @MainActor
    private func saveLocation(_ locator: Locator) {
        // Mutating the book already schedules a debounced save; a synchronous
        // full-state write per scroll tick would hitch the main thread.
        book.lastLocatorJSON = locator.jsonString
        book.lastOpenedAt = Date()
    }

    @MainActor
    private func persistLastPlayedClip(immediately: Bool = false) {
        defer {
            if immediately {
                store.persistNow()
            }
        }

        guard let clip = playback.currentClip else {
            // A nil clip before restore has run means the book is still
            // opening, not that the user cleared playback — keep the saved
            // resume point.
            guard hasRestoredPlaybackState else {
                return
            }

            book.lastPlayedTextResourceHref = nil
            book.lastPlayedFragmentID = nil
            book.lastPlayedClipBegin = nil
            book.lastPlayedClipEnd = nil
            return
        }

        book.lastPlayedTextResourceHref = normalizedResourceHref(for: clip.textResourceHref)
        book.lastPlayedFragmentID = clip.fragmentID
        book.lastPlayedClipBegin = clip.clipBegin
        book.lastPlayedClipEnd = clip.clipEnd
    }

    @MainActor
    private func restoreLastPlayedClipSelectionIfAvailable(with navigator: EPUBNavigatorViewController) async {
        hasRestoredPlaybackState = true
        guard let restoredIndex = restoredLastPlayedClipIndex() else {
            navigator.apply(decorations: [], in: mediaOverlayDecorationGroup)
            return
        }

        playback.selectClip(at: restoredIndex, autoplay: false, reason: "restoreLastPlayedClip")
        await navigateToCurrentClip(with: navigator)
        if let clip = playback.currentClip {
            currentLocationReference = normalizedReference(for: clip.textResourceHref)
        }
        applyCurrentClipDecoration(with: navigator)
    }

    private func restoredLastPlayedClipIndex() -> Int? {
        guard let storedResourceHref = book.lastPlayedTextResourceHref,
              let storedClipBegin = book.lastPlayedClipBegin
        else {
            return nil
        }

        let normalizedStoredResourceHref = normalizedResourceHref(for: storedResourceHref)
        if let exactMatch = playback.clips.firstIndex(where: { clip in
            normalizedResourceHref(for: clip.textResourceHref) == normalizedStoredResourceHref &&
            clip.fragmentID == book.lastPlayedFragmentID &&
            clip.clipBegin == storedClipBegin &&
            clip.clipEnd == book.lastPlayedClipEnd
        }) {
            return exactMatch
        }

        return playback.clips.firstIndex(where: { clip in
            normalizedResourceHref(for: clip.textResourceHref) == normalizedStoredResourceHref &&
            clip.fragmentID == book.lastPlayedFragmentID
        })
    }

    @MainActor
    private func handleLocationDidChange(_ locator: Locator, navigator: EPUBNavigatorViewController) {
        currentLocationReference = normalizedReference(for: locator.href.string)
        currentChapterProgress = locator.locations.progression
        applyDeferredCurrentClipDecorationIfNeeded(with: navigator)
        guard !isSuppressingLocationPersistence else {
            return
        }

        saveLocation(locator)
    }

    @MainActor
    private func navigateToCurrentClip(with navigator: EPUBNavigatorViewController) async {
        guard let clip = playback.currentClip,
              let locator = playbackLocator(for: clip)
        else {
            return
        }

        _ = await navigator.go(to: locator, options: .animated)
    }

    @MainActor
    private func navigateToClipResourceTop(_ clip: EPUBMediaOverlayClip, with navigator: EPUBNavigatorViewController) async {
        let reference = EPUBReference(
            resourceHref: normalizedResourceHref(for: clip.textResourceHref),
            fragmentID: nil
        )
        guard let locator = locator(for: reference) else {
            return
        }

        _ = await navigator.go(to: locator, options: .animated)
    }

    private var isCurrentLocationBookmarked: Bool {
        matchingBookmark() != nil
    }

    /// The bookmark representing the current reading position, if one exists.
    /// When a clip is active, matches on the clip's identity; otherwise matches
    /// a location bookmark in the same resource within a small progress window.
    private func matchingBookmark() -> Bookmark? {
        if let clip = playback.currentClip {
            let clipResourceHref = normalizedResourceHref(for: clip.textResourceHref)
            return book.bookmarks.first { bookmark in
                guard let bookmarkResourceHref = bookmark.textResourceHref else {
                    return false
                }
                return normalizedResourceHref(for: bookmarkResourceHref) == clipResourceHref &&
                    bookmark.fragmentID == clip.fragmentID &&
                    bookmark.clipBegin == clip.clipBegin &&
                    bookmark.clipEnd == clip.clipEnd
            }
        }

        guard let currentLocationReference else {
            return nil
        }

        return book.bookmarks.first { bookmark in
            guard bookmark.textResourceHref == nil,
                  let bookmarkResourceHref = bookmark.resourceHref,
                  normalizedResourceHref(for: bookmarkResourceHref) == currentLocationReference.resourceHref
            else {
                return false
            }

            let current = currentChapterProgress ?? 0
            let saved = bookmark.chapterProgress ?? 0
            return abs(current - saved) <= 0.01
        }
    }

    @MainActor
    private func toggleBookmarkAtCurrentLocation() {
        guard case .ready(_, let navigator) = state,
              let locator = navigator.currentLocation
        else {
            return
        }

        if let existing = matchingBookmark() {
            book.bookmarks.removeAll { $0.id == existing.id }
            store.persistNow()
            return
        }

        let snapshot = currentPositionSnapshot(for: locator)
        Task { @MainActor in
            let clipText = await readCurrentClipText(with: navigator)
            book.bookmarks.append(
                Bookmark(
                    chapterTitle: snapshot.chapterTitle,
                    locatorJSON: snapshot.locatorJSON,
                    resourceHref: snapshot.resourceHref,
                    chapterProgress: snapshot.chapterProgress,
                    totalProgress: snapshot.totalProgress,
                    clipText: clipText,
                    textResourceHref: snapshot.textResourceHref,
                    fragmentID: snapshot.fragmentID,
                    clipBegin: snapshot.clipBegin,
                    clipEnd: snapshot.clipEnd,
                    clipNumberInChapter: snapshot.clipNumberInChapter,
                    clipCountInChapter: snapshot.clipCountInChapter
                )
            )
            store.persistNow()
        }
    }

    /// Snapshot of the current reading position shared by bookmark and history
    /// recording. Captures the locator and, when a clip is active, its identity
    /// and per-resource ordinal. `clipText` is filled separately because reading
    /// it from the page is asynchronous.
    private struct PositionSnapshot {
        var chapterTitle: String?
        var locatorJSON: String?
        var resourceHref: String?
        var chapterProgress: Double?
        var totalProgress: Double?
        var textResourceHref: String?
        var fragmentID: String?
        var clipBegin: Double?
        var clipEnd: Double?
        var clipNumberInChapter: Int?
        var clipCountInChapter: Int?
    }

    private func currentPositionSnapshot(for locator: Locator) -> PositionSnapshot {
        let reference = normalizedReference(for: locator.href.string)
        let chapterTitle = chapterItems.last { item in
            normalizedResourceHref(for: item.link.href) == reference.resourceHref
        }?.title

        var snapshot = PositionSnapshot(
            chapterTitle: chapterTitle,
            locatorJSON: locator.jsonString,
            resourceHref: reference.resourceHref,
            chapterProgress: locator.locations.progression,
            totalProgress: locator.locations.totalProgression
        )

        if let clipIndex = playback.currentClipIndex,
           playback.clips.indices.contains(clipIndex) {
            let clip = playback.clips[clipIndex]
            snapshot.textResourceHref = clip.textResourceHref
            snapshot.fragmentID = clip.fragmentID
            snapshot.clipBegin = clip.clipBegin
            snapshot.clipEnd = clip.clipEnd

            let clipResourceHref = normalizedResourceHref(for: clip.textResourceHref)
            let chapterClipIndices = playback.clips.indices.filter { index in
                normalizedResourceHref(for: playback.clips[index].textResourceHref) == clipResourceHref
            }
            snapshot.clipCountInChapter = chapterClipIndices.count
            snapshot.clipNumberInChapter = chapterClipIndices.firstIndex(of: clipIndex).map { $0 + 1 }
        }

        return snapshot
    }

    private static let historyEntryLimit = 30

    @MainActor
    private func recordHistory(reason: HistoryEventReason) {
        guard case .ready(_, let navigator) = state,
              let locator = navigator.currentLocation
        else {
            return
        }

        let snapshot = currentPositionSnapshot(for: locator)
        Task { @MainActor in
            let clipText = await readCurrentClipText(with: navigator)
            let entry = HistoryEntry(
                reason: reason.label,
                chapterTitle: snapshot.chapterTitle,
                locatorJSON: snapshot.locatorJSON,
                resourceHref: snapshot.resourceHref,
                chapterProgress: snapshot.chapterProgress,
                totalProgress: snapshot.totalProgress,
                clipText: clipText,
                textResourceHref: snapshot.textResourceHref,
                fragmentID: snapshot.fragmentID,
                clipBegin: snapshot.clipBegin,
                clipEnd: snapshot.clipEnd,
                clipNumberInChapter: snapshot.clipNumberInChapter,
                clipCountInChapter: snapshot.clipCountInChapter
            )

            // Collapse a consecutive record at the same position into the newest
            // entry instead of stacking duplicates.
            if let newest = book.history.first, isSameHistoryPosition(newest, entry) {
                book.history.removeFirst()
            }

            book.history.insert(entry, at: 0)
            if book.history.count > Self.historyEntryLimit {
                book.history.removeLast(book.history.count - Self.historyEntryLimit)
            }
            store.persistNow()
        }
    }

    private func isSameHistoryPosition(_ lhs: HistoryEntry, _ rhs: HistoryEntry) -> Bool {
        if lhs.textResourceHref != nil || rhs.textResourceHref != nil {
            return lhs.textResourceHref == rhs.textResourceHref &&
                lhs.fragmentID == rhs.fragmentID &&
                lhs.clipBegin == rhs.clipBegin &&
                lhs.clipEnd == rhs.clipEnd
        }

        return lhs.resourceHref == rhs.resourceHref &&
            abs((lhs.chapterProgress ?? 0) - (rhs.chapterProgress ?? 0)) <= 0.01
    }

    @MainActor
    private func readCurrentClipText(with navigator: EPUBNavigatorViewController) async -> String? {
        guard let clip = playback.currentClip,
              let fragmentID = clip.fragmentID,
              !fragmentID.isEmpty
        else {
            return nil
        }

        let fragmentIDLiteral = javaScriptStringLiteral(fragmentID)
        let script = """
        (() => {
          const element = document.getElementById(\(fragmentIDLiteral));
          if (!element) {
            return "";
          }
          return (element.textContent || "").replace(/\\s+/g, " ").trim();
        })();
        """

        let result = await navigator.evaluateJavaScript(script)
        guard case .success(let value) = result,
              let text = value as? String,
              !text.isEmpty
        else {
            return nil
        }
        return text
    }

    @MainActor
    private func goToBookmark(_ bookmark: Bookmark, navigator: EPUBNavigatorViewController) async {
        await navigateToSavedPosition(
            textResourceHref: bookmark.textResourceHref,
            fragmentID: bookmark.fragmentID,
            clipBegin: bookmark.clipBegin,
            clipEnd: bookmark.clipEnd,
            locatorJSON: bookmark.locatorJSON,
            navigator: navigator
        )
        recordHistory(reason: .jumped)
    }

    @MainActor
    private func goToHistoryEntry(_ entry: HistoryEntry, navigator: EPUBNavigatorViewController) async {
        await navigateToSavedPosition(
            textResourceHref: entry.textResourceHref,
            fragmentID: entry.fragmentID,
            clipBegin: entry.clipBegin,
            clipEnd: entry.clipEnd,
            locatorJSON: entry.locatorJSON,
            navigator: navigator
        )
        recordHistory(reason: .jumped)
    }

    @MainActor
    private func navigateToSavedPosition(
        textResourceHref: String?,
        fragmentID: String?,
        clipBegin: Double?,
        clipEnd: Double?,
        locatorJSON: String?,
        navigator: EPUBNavigatorViewController
    ) async {
        if let clipIndex = savedPositionClipIndex(
            textResourceHref: textResourceHref,
            fragmentID: fragmentID,
            clipBegin: clipBegin,
            clipEnd: clipEnd
        ) {
            let wasPlaying = playback.state.isPlaying
            let clip = playback.clips[clipIndex]
            pendingChapterEntryPlaybackStartClipKey = playbackStartClipKey(for: clip)
            if let locator = playbackLocator(for: clip) {
                _ = await navigator.go(to: locator, options: .animated)
            }
            playback.selectClip(at: clipIndex, autoplay: wasPlaying, reason: "savedPositionSelect")
            applyCurrentClipDecoration(with: navigator)
            return
        }

        guard let locatorJSON,
              let locator = (try? Locator(jsonString: locatorJSON)) ?? nil
        else {
            return
        }
        _ = await navigator.go(to: locator, options: .animated)
    }

    private func savedPositionClipIndex(
        textResourceHref: String?,
        fragmentID: String?,
        clipBegin: Double?,
        clipEnd: Double?
    ) -> Int? {
        guard let textResourceHref else {
            return nil
        }

        let resourceHref = normalizedResourceHref(for: textResourceHref)
        if let exactMatch = playback.clips.firstIndex(where: { clip in
            normalizedResourceHref(for: clip.textResourceHref) == resourceHref &&
            clip.fragmentID == fragmentID &&
            clip.clipBegin == clipBegin &&
            clip.clipEnd == clipEnd
        }) {
            return exactMatch
        }

        return playback.clips.firstIndex(where: { clip in
            normalizedResourceHref(for: clip.textResourceHref) == resourceHref &&
            clip.fragmentID == fragmentID
        })
    }

    @MainActor
    private func selectChapter(_ item: ChapterListItem, navigator: EPUBNavigatorViewController) async {
        let wasPlaying = playback.state.isPlaying
        if let clipIndex = firstClipIndex(for: item.link) {
            let clip = playback.clips[clipIndex]
            pendingChapterEntryPlaybackStartClipKey = playbackStartClipKey(for: clip)
            _ = await navigator.go(to: item.link, options: .animated)
            playback.selectClip(at: clipIndex, autoplay: wasPlaying, reason: "chapterSelect")
            applyCurrentClipDecoration(with: navigator)
            recordHistory(reason: .jumped)
            return
        }

        if wasPlaying {
            playback.pause(reason: "chapterSelect.noClipMatch")
        }

        _ = await navigator.go(to: item.link, options: .animated)

        guard wasPlaying else {
            recordHistory(reason: .jumped)
            return
        }

        await startPlaybackFromVisibleOrForwardPosition(with: navigator)
        recordHistory(reason: .jumped)
    }

    @MainActor
    private func startPlaybackFromVisibleOrForwardPosition(with navigator: EPUBNavigatorViewController) async {
        let targetClipIndex = await resolvedPlaybackStartClipIndex(with: navigator)
        if let targetClipIndex,
           playback.currentClipIndex != targetClipIndex {
            playback.selectClip(at: targetClipIndex, autoplay: true, reason: "startPlaybackFromVisibleOrForwardPosition")
        } else if playback.currentClipIndex != nil {
            playback.play(reason: "startPlaybackFromVisibleOrForwardPosition.resumeCurrentClip")
        }
    }

    @MainActor
    private func handleClipPlaybackStartIfNeeded(with navigator: EPUBNavigatorViewController) async {
        guard playback.state.isPlaying,
              let currentClip = playback.currentClip
        else {
            return
        }

        let clipKey = playbackStartClipKey(for: currentClip)
        let usesChapterEntryScrollBehavior = pendingChapterEntryPlaybackStartClipKey == clipKey
        guard lastHandledPlaybackStartClipKey != clipKey else {
            return
        }
        lastHandledPlaybackStartClipKey = clipKey
        if usesChapterEntryScrollBehavior {
            pendingChapterEntryPlaybackStartClipKey = nil
        }

        if currentClip.fragmentID?.isEmpty != false {
            if !(await isCurrentClipResourceVisible(with: navigator, clip: currentClip)) {
                if usesChapterEntryScrollBehavior {
                    await navigateToClipResourceTop(currentClip, with: navigator)
                } else {
                    await navigateToCurrentClip(with: navigator)
                }
            }
            return
        }

        if !(await isCurrentClipResourceVisible(with: navigator, clip: currentClip)) {
            if usesChapterEntryScrollBehavior {
                await navigateToClipResourceTop(currentClip, with: navigator)
            } else {
                await navigateToCurrentClip(with: navigator)
            }
        }

        _ = await repositionCurrentClipForPlaybackIfNeeded(
            with: navigator,
            visibleBottomFraction: navigatorVisibleBottomFraction,
            pinCurrentClipToPreferredTop: !usesChapterEntryScrollBehavior
        )
    }

    @MainActor
    private func playFromTappedPoint(resourceHref: String, point: CGPoint, navigator: EPUBNavigatorViewController) async {
        let normalizedResource = normalizedResourceHref(for: resourceHref)
        guard let clipIndex = await resolvedTappedClipIndex(
            resourceHref: normalizedResource,
            point: point,
            navigator: navigator
        ) else {
            return
        }

        playback.selectClip(at: clipIndex, autoplay: true, reason: "audioTap")
        applyCurrentClipDecoration(with: navigator)
        recordHistory(reason: .jumped)
    }

    @MainActor
    private func resolvedTappedClipIndex(
        resourceHref: String,
        point: CGPoint,
        navigator: EPUBNavigatorViewController
    ) async -> Int? {
        let playableIDs = playableFragmentIDs(for: resourceHref)
        if !playableIDs.isEmpty,
           let fragmentID = await playableFragmentID(at: point, fragmentIDs: playableIDs, navigator: navigator),
           let clipIndex = exactClipIndex(for: EPUBReference(resourceHref: resourceHref, fragmentID: fragmentID)) {
            return clipIndex
        }

        // A tap inside a narrated resource should never be silently dropped:
        // fall back to that resource's first clip when no fragment resolves.
        return firstClipIndex(forResourceHref: resourceHref)
    }

    @MainActor
    private func playableFragmentID(
        at point: CGPoint,
        fragmentIDs: [String],
        navigator: EPUBNavigatorViewController
    ) async -> String? {
        let fragmentIDsLiteral = javaScriptArrayLiteral(fragmentIDs)
        let script = """
        (() => {
          const fragmentIDs = \(fragmentIDsLiteral);
          const x = \(String(Double(point.x)));
          const y = \(String(Double(point.y)));

          // Hit-test against per-line rectangles (getClientRects), which hug the
          // rendered glyphs the same way Readium draws its highlight. The single
          // getBoundingClientRect() box is avoided because a multi-line inline
          // phrase collapses into one full-width rectangle that includes the
          // empty space before a mid-line start and after a mid-line end.

          // Distance from point (x, y) to a rectangle (0 when inside).
          function pointRectDistance(rect) {
            const dx = Math.max(rect.left - x, 0, x - rect.right);
            const dy = Math.max(rect.top - y, 0, y - rect.bottom);
            return Math.sqrt(dx * dx + dy * dy);
          }

          var containing = null;
          var containingScore = Infinity; // distance from tap to containing line's center
          var nearest = null;
          var nearestDistance = Infinity;

          for (const fragmentID of fragmentIDs) {
            const element = document.getElementById(fragmentID);
            if (!element) {
              continue;
            }

            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden') {
              continue;
            }

            const lineRects = Array.from(element.getClientRects())
              .filter(r => r.width > 0 || r.height > 0);
            if (lineRects.length === 0) {
              continue;
            }

            var minDistance = Infinity;
            for (const r of lineRects) {
              const distance = pointRectDistance(r);
              if (distance < minDistance) {
                minDistance = distance;
              }
              if (y >= r.top && y <= r.bottom && x >= r.left && x <= r.right) {
                // Disambiguate overlapping containers by preferring the line
                // whose center is closest to the tap.
                const cx = (r.left + r.right) / 2;
                const cy = (r.top + r.bottom) / 2;
                const score = Math.sqrt((cx - x) * (cx - x) + (cy - y) * (cy - y));
                if (score < containingScore) {
                  containingScore = score;
                  containing = fragmentID;
                }
              }
            }

            // Nearest by point-to-rect distance (considers both X and Y).
            if (minDistance < nearestDistance) {
              nearestDistance = minDistance;
              nearest = fragmentID;
            }
          }

          const resolved = containing ?? nearest;
          return JSON.stringify({ fragmentID: resolved });
        })();
        """

        let result = await navigator.evaluateJavaScript(script)
        guard case .success(let value) = result,
              let json = value as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let fragmentID = object["fragmentID"] as? String,
              !fragmentID.isEmpty
        else {
            return nil
        }
        return fragmentID
    }

    private func exactClipIndex(for reference: EPUBReference) -> Int? {
        guard let fragmentID = reference.fragmentID,
              !fragmentID.isEmpty
        else {
            return nil
        }

        let exactReference = EPUBReference(
            resourceHref: reference.resourceHref,
            fragmentID: fragmentID
        )

        let match = playback.clips.firstIndex(where: { clip in
            normalizedResourceHref(for: clip.textResourceHref) == exactReference.resourceHref &&
            clip.fragmentID == exactReference.fragmentID
        })
        return match
    }

    private func firstClipIndex(for link: ReadiumShared.Link) -> Int? {
        firstClipIndex(for: normalizedReference(for: link.href))
    }

    private func firstClipIndex(for reference: EPUBReference) -> Int? {
        let chapterReference = reference

        if let exactMatch = playback.clips.firstIndex(where: { clip in
            normalizedReference(for: clip.textResourceHref) == chapterReference
        }) {
            return exactMatch
        }

        // Clip hrefs are fragment-stripped at creation, so a fragment reference
        // (e.g. a TOC entry into the middle of a file) must match on the clip's
        // own fragmentID, not fall through to the file's first clip.
        if let fragmentID = chapterReference.fragmentID,
           let fragmentMatch = playback.clips.firstIndex(where: { clip in
               normalizedResourceHref(for: clip.textResourceHref) == chapterReference.resourceHref &&
               clip.fragmentID == fragmentID
           }) {
            return fragmentMatch
        }

        return playback.clips.firstIndex(where: { clip in
            normalizedResourceHref(for: clip.textResourceHref) == chapterReference.resourceHref
        })
    }

    private func firstClipIndex(forResourceHref resourceHref: String) -> Int? {
        playback.clips.firstIndex(where: { clip in
            normalizedResourceHref(for: clip.textResourceHref) == resourceHref
        })
    }

    private func firstClipIndex(afterResourceHref resourceHref: String) -> Int? {
        guard let currentResourceOrder = readingOrderResourceHrefs.firstIndex(of: resourceHref) else {
            return nil
        }

        for (index, clip) in playback.clips.enumerated() {
            let clipResourceHref = normalizedResourceHref(for: clip.textResourceHref)
            guard let clipResourceOrder = readingOrderResourceHrefs.firstIndex(of: clipResourceHref),
                  clipResourceOrder > currentResourceOrder
            else {
                continue
            }

            return index
        }

        return nil
    }

    private func normalizedReference(for href: String) -> EPUBReference {
        let normalized = (AnyURL(string: href)?.normalized.string ?? href)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = normalized.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawResourceHref = parts.first.map(String.init) ?? ""
        let rawFragmentID = parts.count > 1 ? String(parts[1]) : nil
        // Navigator locators arrive percent-encoded while SMIL-derived clip
        // hrefs are already decoded; compare both in decoded form.
        let resourceHref = rawResourceHref.removingPercentEncoding ?? rawResourceHref
        let fragmentID = rawFragmentID.map { $0.removingPercentEncoding ?? $0 }
        return EPUBReference(resourceHref: resourceHref, fragmentID: fragmentID)
    }

    private func normalizedResourceHref(for href: String) -> String {
        normalizedReference(for: href).resourceHref
    }

    private var navigatorVisibleBottom: CGFloat {
        guard !navigatorFrame.isNull,
              !navigatorFrame.isEmpty
        else {
            return .greatestFiniteMagnitude
        }

        guard !playbackBarFrame.isNull,
              !playbackBarFrame.isEmpty
        else {
            return navigatorFrame.height
        }

        let visibleBottom = playbackBarFrame.minY - navigatorFrame.minY
        return min(max(visibleBottom, 0), navigatorFrame.height)
    }

    private var navigatorVisibleBottomFraction: CGFloat {
        guard !navigatorFrame.isNull,
              !navigatorFrame.isEmpty,
              navigatorFrame.height > 0
        else {
            return 1
        }

        return min(max(navigatorVisibleBottom / navigatorFrame.height, 0), 1)
    }

    private func playbackStartClipKey(for clip: EPUBMediaOverlayClip) -> String {
        clip.identityKey
    }

    private var activeChapterItemID: ChapterListItem.ID? {
        guard let currentLocationReference else {
            return nil
        }

        if let exactMatch = chapterItems.last(where: { item in
            normalizedReference(for: item.link.href) == currentLocationReference
        }) {
            return exactMatch.id
        }

        return chapterItems.last(where: { item in
            normalizedResourceHref(for: item.link.href) == currentLocationReference.resourceHref
        })?.id
    }

    @MainActor
    private func handleCurrentClipChange(oldIndex: Int?, newIndex: Int?, navigator: EPUBNavigatorViewController) {
        applyCurrentClipDecoration(with: navigator)
        persistLastPlayedClip()

        guard let newIndex,
              playback.clips.indices.contains(newIndex)
        else {
            return
        }

        let newClip = playback.clips[newIndex]
        let newClipKey = playbackStartClipKey(for: newClip)
        var markedChapterEntryPlaybackStart = false
        if let oldIndex,
           playback.clips.indices.contains(oldIndex) {
            let oldResourceHref = normalizedResourceHref(for: playback.clips[oldIndex].textResourceHref)
            let newResourceHref = normalizedResourceHref(for: newClip.textResourceHref)
            if oldResourceHref != newResourceHref,
               firstClipIndex(forResourceHref: newResourceHref) == newIndex {
                pendingChapterEntryPlaybackStartClipKey = newClipKey
                markedChapterEntryPlaybackStart = true
            }
        }

        if !markedChapterEntryPlaybackStart,
           pendingChapterEntryPlaybackStartClipKey != nil,
           pendingChapterEntryPlaybackStartClipKey != newClipKey {
            pendingChapterEntryPlaybackStartClipKey = nil
        }

        if playback.state.isPlaying,
           oldIndex != newIndex {
            Task {
                await handleClipPlaybackStartIfNeeded(with: navigator)
            }
        }
    }

    private func playbackLocator(for clip: EPUBMediaOverlayClip) -> Locator? {
        guard let href = RelativeURL(epubHREF: clip.textResourceHref) else {
            return nil
        }

        return Locator(
            href: href,
            mediaType: .xhtml,
            locations: Locator.Locations(
                fragments: clip.fragmentID.map { [$0] } ?? []
            )
        )
    }

    private func locator(for reference: EPUBReference) -> Locator? {
        guard let href = RelativeURL(epubHREF: reference.resourceHref) else {
            return nil
        }

        return Locator(
            href: href,
            mediaType: .xhtml,
            locations: Locator.Locations(
                fragments: reference.fragmentID.map { [$0] } ?? []
            )
        )
    }

    @MainActor
    private func isCurrentClipResourceVisible(with navigator: EPUBNavigatorViewController, clip: EPUBMediaOverlayClip) async -> Bool {
        guard let visibleLocator = await navigator.firstVisibleElementLocator() else {
            return false
        }

        return normalizedResourceHref(for: visibleLocator.href.string) == normalizedResourceHref(for: clip.textResourceHref)
    }

    @MainActor
    private func repositionCurrentClipForPlaybackIfNeeded(
        with navigator: EPUBNavigatorViewController,
        visibleBottomFraction: CGFloat,
        pinCurrentClipToPreferredTop: Bool
    ) async {
        guard let currentClip = playback.currentClip,
              let fragmentID = currentClip.fragmentID,
              !fragmentID.isEmpty
        else {
            return
        }

        let fragmentIDLiteral = javaScriptStringLiteral(fragmentID)
        let visibleBottomFractionLiteral = String(Double(min(max(visibleBottomFraction, 0), 1)))
        let pinCurrentClipToPreferredTopLiteral = pinCurrentClipToPreferredTop ? "true" : "false"
        let script = """
        (() => {
          const visibleBottomFraction = Math.min(Math.max(\(visibleBottomFractionLiteral), 0), 1);
          const pinCurrentClipToPreferredTop = \(pinCurrentClipToPreferredTopLiteral);
          const visibleBottom = window.innerHeight * visibleBottomFraction;
          const visibleHeight = Math.max(visibleBottom, 1);
          const preferredTop = visibleHeight * 0.05;
          const nextTextPartThreshold = visibleBottom * 0.90;

          const debugPayload = (action, nextTextPartElement, nextTextPartRect) => ({
            action,
            nextTextPartID: nextTextPartElement?.id ?? null,
            nextTextPartTop: nextTextPartRect?.top ?? null,
            visibleBottom,
            distanceToBottom: nextTextPartRect ? (visibleBottom - nextTextPartRect.top) : null,
            threshold: nextTextPartThreshold,
            triggerForNext: nextTextPartRect ? nextTextPartRect.top >= nextTextPartThreshold : false
          });

          const startElement = document.getElementById(\(fragmentIDLiteral));
          if (!startElement) {
            return debugPayload('missing', null, null);
          }

          const startStyle = window.getComputedStyle(startElement);
          if (startStyle.display === 'none' || startStyle.visibility === 'hidden') {
            return debugPayload('missing', null, null);
          }

          const isVisible = element => {
            if (!element) {
              return false;
            }

            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden') {
              return false;
            }

            const rect = element.getBoundingClientRect();
            return rect.width > 0 || rect.height > 0;
          };

          const currentRect = startElement.getBoundingClientRect();

          // Find the next on-screen text part that follows the current clip, so we
          // can scroll ahead before the current clip's tail slides off the bottom.
          //
          // querySelectorAll('[id]') returns every id-bearing element in DOM order,
          // NOT just sibling text parts. The element right after startElement in that
          // list is very often one of its OWN descendants (Kobo wraps each sentence in
          // nested <span id="kobo.x.y"> children). A descendant shares the current
          // clip's bounding box, so its top equals currentRect.top — which is far above
          // the bottom threshold. That made the "next part close to bottom" check below
          // never fire for the last clips of a page: it kept comparing the threshold
          // against the CURRENT clip's own top and concluded nothing needed scrolling.
          //
          // To get a genuinely-following part we skip any candidate that is:
          //   1. not visible,
          //   2. a descendant of the current clip (startElement.contains), or
          //   3. positioned at or above the current clip's top (ancestors / wrappers
          //      that begin at the same y as startElement).
          // Only an element that starts strictly below the current clip qualifies.
          const nextTextPartElement = (() => {
            const identifiedElements = Array.from(document.querySelectorAll('[id]'));
            const currentIndex = identifiedElements.indexOf(startElement);
            if (currentIndex < 0) {
              return null;
            }

            for (let index = currentIndex + 1; index < identifiedElements.length; index += 1) {
              const candidate = identifiedElements[index];
              if (isVisible(candidate)
                  && !startElement.contains(candidate)
                  && candidate.getBoundingClientRect().top > currentRect.top) {
                return candidate;
              }
            }

            return null;
          })();
          const nextTextPartRect = nextTextPartElement?.getBoundingClientRect() ?? null;
          const nextTextPartTooCloseToBottom = nextTextPartRect !== null && nextTextPartRect.top >= nextTextPartThreshold;
          const currentStartBeforePreferredTop = currentRect.top < preferredTop;
          const currentStartPastVisibleBottom = currentRect.top >= visibleBottom;

          if (!nextTextPartTooCloseToBottom && (!pinCurrentClipToPreferredTop || !currentStartBeforePreferredTop && !currentStartPastVisibleBottom)) {
            return debugPayload('noop', nextTextPartElement, nextTextPartRect);
          }

          const targetTop = pinCurrentClipToPreferredTop ? preferredTop : Math.max(0, Math.min(currentRect.top, preferredTop));
          const delta = currentRect.top - targetTop;
          if (Math.abs(delta) <= 2) {
            return debugPayload('noop', nextTextPartElement, nextTextPartRect);
          }

          window.scrollBy({ top: delta, behavior: 'smooth' });
          return debugPayload('scrolled', nextTextPartElement, nextTextPartRect);
        })();
        """

        _ = await navigator.evaluateJavaScript(script)
    }

    @MainActor
    private func currentViewportAnchor(with navigator: EPUBNavigatorViewController) async -> EPUBReference? {
        let visibleBottomFractionLiteral = String(Double(min(max(navigatorVisibleBottomFraction, 0), 1)))
        let script = """
        (() => {
          const href = window.location.pathname.replace(/^\\//, '');
          if (!href) {
            return null;
          }

          const visibleBottomFraction = Math.min(Math.max(\(visibleBottomFractionLiteral), 0), 1);
          const visibleBottom = Math.max(window.innerHeight * visibleBottomFraction, 1);
          const sampleRatios = [0.08, 0.12, 0.18, 0.24, 0.32];
          const centerX = Math.min(Math.max(window.innerWidth * 0.5, 1), Math.max(window.innerWidth - 1, 1));

          const nearestIdentifiedElement = element => {
            let node = element;
            while (node) {
              if (node.id) {
                return node;
              }
              node = node.parentElement;
            }
            return null;
          };

          for (const ratio of sampleRatios) {
            const y = Math.min(Math.max(visibleBottom * ratio, 1), Math.max(visibleBottom - 1, 1));
            const element = nearestIdentifiedElement(document.elementFromPoint(centerX, y));
            if (element) {
              return { href, fragmentID: element.id };
            }
          }

          const candidates = Array.from(document.querySelectorAll('[id]'));
          let firstVisible = null;
          for (const element of candidates) {
            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden') {
              continue;
            }

            const rect = element.getBoundingClientRect();
            if (!(rect.bottom > 0 && rect.top < visibleBottom)) {
              continue;
            }

            if (!firstVisible || rect.top < firstVisible.top) {
              firstVisible = { top: rect.top, fragmentID: element.id };
            }
          }

          return firstVisible ? { href, fragmentID: firstVisible.fragmentID } : { href, fragmentID: null };
        })();
        """

        let result = await navigator.evaluateJavaScript(script)
        guard case .success(let value) = result,
              let payload = value as? [String: Any],
              let href = payload["href"] as? String
        else {
            return nil
        }

        let fragmentID = (payload["fragmentID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return EPUBReference(resourceHref: normalizedResourceHref(for: href), fragmentID: fragmentID)
    }

    @MainActor
    private func restoreViewportAnchor(_ anchor: EPUBReference, with navigator: EPUBNavigatorViewController) async {
        if let fragmentID = anchor.fragmentID,
           await scrollFragmentIntoPreferredPosition(fragmentID, with: navigator) {
            return
        }

        guard let locator = locator(for: anchor) else {
            return
        }

        _ = await navigator.go(to: locator, options: .animated)
    }

    @MainActor
    private func scrollFragmentIntoPreferredPosition(_ fragmentID: String, with navigator: EPUBNavigatorViewController) async -> Bool {
        let fragmentIDLiteral = javaScriptStringLiteral(fragmentID)
        let visibleBottomFractionLiteral = String(Double(min(max(navigatorVisibleBottomFraction, 0), 1)))
        let script = """
        (() => {
          const element = document.getElementById(
            \(fragmentIDLiteral)
          );
          if (!element) {
            return false;
          }

          const style = window.getComputedStyle(element);
          if (style.display === 'none' || style.visibility === 'hidden') {
            return false;
          }

          const visibleBottomFraction = Math.min(Math.max(\(visibleBottomFractionLiteral), 0), 1);
          const visibleBottom = Math.max(window.innerHeight * visibleBottomFraction, 1);
          const targetTop = visibleBottom * 0.08;
          const rect = element.getBoundingClientRect();
          window.scrollTo({ top: window.scrollY + rect.top - targetTop, behavior: 'auto' });
          return true;
        })();
        """

        let result = await navigator.evaluateJavaScript(script)
        guard case .success(let value) = result,
              let didScroll = value as? Bool
        else {
            return false
        }

        return didScroll
    }

    private func playableFragmentIDs(for resourceHref: String) -> [String] {
        var fragmentIDs: [String] = []
        var seen = Set<String>()

        for clip in playback.clips {
            guard normalizedResourceHref(for: clip.textResourceHref) == resourceHref,
                  let fragmentID = clip.fragmentID,
                  !fragmentID.isEmpty,
                  seen.insert(fragmentID).inserted
            else {
                continue
            }

            fragmentIDs.append(fragmentID)
        }

        return fragmentIDs
    }

    private enum PlayableViewportPosition: String, CaseIterable {
        // Declaration order is the playback-start preference: a visible
        // fragment first, then the nearest one above, then the next one below.
        case inViewport
        case before
        case after
    }

    @MainActor
    private func resolvedPlaybackStartClipIndex(with navigator: EPUBNavigatorViewController) async -> Int? {
        guard let visibleLocator = await navigator.firstVisibleElementLocator() else {
            return nil
        }

        let visibleResourceHref = normalizedResourceHref(for: visibleLocator.href.string)
        let playableIDs = playableFragmentIDs(for: visibleResourceHref)

        if !playableIDs.isEmpty {
            let positionedFragmentIDs = await playableFragmentIDsByViewportPosition(
                fragmentIDs: playableIDs,
                navigator: navigator
            )

            for position in PlayableViewportPosition.allCases {
                if let fragmentID = positionedFragmentIDs[position],
                   let clipIndex = exactClipIndex(for: EPUBReference(
                       resourceHref: visibleResourceHref,
                       fragmentID: fragmentID
                   )) {
                    return clipIndex
                }
            }
        }

        if let laterClipIndex = firstClipIndex(afterResourceHref: visibleResourceHref) {
            return laterClipIndex
        }

        return nil
    }

    @MainActor
    private func playableFragmentIDsByViewportPosition(
        fragmentIDs: [String],
        navigator: EPUBNavigatorViewController
    ) async -> [PlayableViewportPosition: String] {
        let fragmentIDsLiteral = javaScriptArrayLiteral(fragmentIDs)
        let visibleBottomFractionLiteral = String(Double(min(max(navigatorVisibleBottomFraction, 0), 1)))
        let script = """
        (() => {
          const fragmentIDs = \(fragmentIDsLiteral);
          const visibleBottomFraction = Math.min(Math.max(\(visibleBottomFractionLiteral), 0), 1);
          const visibleBottom = Math.max(window.innerHeight * visibleBottomFraction, 1);

          var firstVisible = null;
          var nearestBefore = null;
          var firstForward = null;

          for (const fragmentID of fragmentIDs) {
            const element = document.getElementById(fragmentID);
            if (!element) {
              continue;
            }

            const style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden') {
              continue;
            }

            const rect = element.getBoundingClientRect();
            if (rect.bottom > 0 && rect.top < visibleBottom) {
              if (!firstVisible || rect.top < firstVisible.top) {
                firstVisible = { top: rect.top, fragmentID };
              }
            } else if (rect.bottom <= 0) {
              if (!nearestBefore || rect.bottom > nearestBefore.bottom) {
                nearestBefore = { bottom: rect.bottom, fragmentID };
              }
            } else if (rect.top >= visibleBottom) {
              if (!firstForward || rect.top < firstForward.top) {
                firstForward = { top: rect.top, fragmentID };
              }
            }
          }

          return JSON.stringify({
            inViewport: firstVisible?.fragmentID ?? null,
            before: nearestBefore?.fragmentID ?? null,
            after: firstForward?.fragmentID ?? null
          });
        })();
        """

        let result = await navigator.evaluateJavaScript(script)
        guard case .success(let value) = result,
              let json = value as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else {
            return [:]
        }

        var positionedFragmentIDs: [PlayableViewportPosition: String] = [:]
        for position in PlayableViewportPosition.allCases {
            if let fragmentID = object[position.rawValue] as? String, !fragmentID.isEmpty {
                positionedFragmentIDs[position] = fragmentID
            }
        }
        return positionedFragmentIDs
    }

    /// Decoration templates for the navigator.
    ///
    /// Overrides the active highlight to be background-only (`lineWeight: 0`).
    /// Readium fragments a single visual line into multiple overlay boxes with
    /// inconsistent bottoms, so a per-box `border-bottom` underline renders
    /// unevenly (left higher than right). The contiguous background fill does
    /// not have this problem. Other values mirror `defaultTemplates()`.
    private func readerDecorationTemplates() -> [Decoration.Style.Id: HTMLDecorationTemplate] {
        var templates = HTMLDecorationTemplate.defaultTemplates()
        templates[.highlight] = .highlight(
            defaultTint: .yellow,
            padding: UIEdgeInsets(top: 0, left: 1, bottom: 0, right: 1),
            lineWeight: 0,
            cornerRadius: 0,
            alpha: 0.3
        )
        return templates
    }

    @MainActor
    private func applyCurrentClipDecoration(with navigator: EPUBNavigatorViewController) {
        guard let clip = playback.currentClip,
              let href = RelativeURL(epubHREF: clip.textResourceHref)
        else {
            pendingDecorationClipKey = nil
            navigator.apply(decorations: [], in: mediaOverlayDecorationGroup)
            return
        }

        let clipKey = playbackStartClipKey(for: clip)
        let clipResourceHref = normalizedResourceHref(for: clip.textResourceHref)
        guard currentLocationReference?.resourceHref == clipResourceHref else {
            pendingDecorationClipKey = clipKey
            navigator.apply(decorations: [], in: mediaOverlayDecorationGroup)
            return
        }

        pendingDecorationClipKey = nil

        let locator = Locator(
            href: href,
            mediaType: .xhtml,
            locations: Locator.Locations(
                fragments: clip.fragmentID.map { [$0] } ?? []
            )
        )

        navigator.apply(
            decorations: [
                Decoration(
                    id: "media-overlay-active",
                    locator: locator,
                    style: .highlight(
                        tint: ReaderSettings.uiColor(from: store.readAloudColorRawValue),
                        isActive: true
                    )
                ),
            ],
            in: mediaOverlayDecorationGroup
        )
    }

    @MainActor
    private func applyDeferredCurrentClipDecorationIfNeeded(with navigator: EPUBNavigatorViewController) {
        guard let pendingDecorationClipKey,
              let currentClip = playback.currentClip,
              playbackStartClipKey(for: currentClip) == pendingDecorationClipKey,
              currentLocationReference?.resourceHref == normalizedResourceHref(for: currentClip.textResourceHref)
        else {
            return
        }

        applyCurrentClipDecoration(with: navigator)
    }
}

private let mediaOverlayDecorationGroup = "media-overlay"

private func javaScriptStringLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
    return "\"\(escaped)\""
}

private func javaScriptArrayLiteral(_ values: [String]) -> String {
    "[\(values.map(javaScriptStringLiteral).joined(separator: ", "))]"
}

private struct ReadAloudStatusView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.thinMaterial)
    }
}

private enum ReaderState {
    case loading
    case ready(publication: Publication, navigator: EPUBNavigatorViewController)
    case failed(String)
}

private struct ChapterListItem: Identifiable {
    let level: Int
    let link: ReadiumShared.Link

    var id: String {
        "\(level)-\(link.href)-\(link.title ?? "")"
    }

    var title: String {
        link.title ?? link.href
    }
}

private struct EPUBReference: Equatable {
    let resourceHref: String
    let fragmentID: String?
}

private enum ChapterBookmarkTab: Hashable {
    case chapters
    case bookmarks
    case history
}

private enum HistoryEventReason {
    case played
    case paused
    case jumped

    var label: String {
        switch self {
        case .played:
            return "Played"
        case .paused:
            return "Paused"
        case .jumped:
            return "Jumped"
        }
    }
}

private struct ChapterAndBookmarkScreen: View {
    let items: [ChapterListItem]
    let selectedItemID: ChapterListItem.ID?
    let bookmarks: [Bookmark]
    let history: [HistoryEntry]
    let onSelectChapter: (ChapterListItem) -> Void
    let onSelectBookmark: (Bookmark) -> Void
    let onDeleteBookmarks: (Set<Bookmark.ID>) -> Void
    let onSelectHistory: (HistoryEntry) -> Void
    let onDeleteHistory: (Set<HistoryEntry.ID>) -> Void

    @State private var selectedTab: ChapterBookmarkTab = .chapters

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                Text("Chapters").tag(ChapterBookmarkTab.chapters)
                Text("Bookmarks").tag(ChapterBookmarkTab.bookmarks)
                Text("History").tag(ChapterBookmarkTab.history)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch selectedTab {
            case .chapters:
                ChapterListScreen(
                    items: items,
                    selectedItemID: selectedItemID,
                    onSelect: onSelectChapter
                )
            case .bookmarks:
                BookmarkListScreen(
                    bookmarks: bookmarks,
                    onSelect: onSelectBookmark,
                    onDelete: onDeleteBookmarks
                )
            case .history:
                HistoryListScreen(
                    history: history,
                    onSelect: onSelectHistory,
                    onDelete: onDeleteHistory
                )
            }
        }
        .navigationTitle("Contents")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ChapterListScreen: View {
    let items: [ChapterListItem]
    let selectedItemID: ChapterListItem.ID?
    let onSelect: (ChapterListItem) -> Void

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Chapters",
                    systemImage: "list.bullet.rectangle",
                    description: Text("This book doesn't expose a table of contents.")
                )
            } else {
                List {
                    ForEach(items) { item in
                        let isSelected = selectedItemID == item.id
                        Button {
                            onSelect(item)
                        } label: {
                            HStack(spacing: 12) {
                                Text(item.title)
                                    .fontWeight(isSelected ? .semibold : .regular)
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.leading, CGFloat(item.level * 16))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct BookmarkListScreen: View {
    let bookmarks: [Bookmark]
    let onSelect: (Bookmark) -> Void
    let onDelete: (Set<Bookmark.ID>) -> Void

    var body: some View {
        Group {
            if bookmarks.isEmpty {
                ContentUnavailableView(
                    "No Bookmarks",
                    systemImage: "bookmark",
                    description: Text("Tap the bookmark button while reading to save your place.")
                )
            } else {
                List {
                    ForEach(bookmarks) { bookmark in
                        Button {
                            onSelect(bookmark)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(primaryText(for: bookmark))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(secondaryText(for: bookmark))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let ids = Set(offsets.map { bookmarks[$0].id })
                        onDelete(ids)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func primaryText(for bookmark: Bookmark) -> String {
        if let clipText = bookmark.clipText, !clipText.isEmpty {
            return clipText
        }
        if let chapterTitle = bookmark.chapterTitle, !chapterTitle.isEmpty {
            return chapterTitle
        }
        return "Bookmark"
    }

    private func secondaryText(for bookmark: Bookmark) -> String {
        var parts: [String] = []

        let hasClipText = (bookmark.clipText?.isEmpty == false)
        if hasClipText,
           let chapterTitle = bookmark.chapterTitle,
           !chapterTitle.isEmpty {
            parts.append(chapterTitle)
        }

        if let number = bookmark.clipNumberInChapter,
           let total = bookmark.clipCountInChapter {
            parts.append("Clip \(number)/\(total)")
        }

        if let progress = bookmark.chapterProgress {
            parts.append("\(Int((progress * 100).rounded()))%")
        }

        parts.append(bookmark.createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}

private struct HistoryListScreen: View {
    let history: [HistoryEntry]
    let onSelect: (HistoryEntry) -> Void
    let onDelete: (Set<HistoryEntry.ID>) -> Void

    var body: some View {
        Group {
            if history.isEmpty {
                ContentUnavailableView(
                    "No History",
                    systemImage: "clock",
                    description: Text("Your reading positions are recorded automatically as you play, pause, and jump.")
                )
            } else {
                List {
                    ForEach(history) { entry in
                        Button {
                            onSelect(entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(primaryText(for: entry))
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(secondaryText(for: entry))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let ids = Set(offsets.map { history[$0].id })
                        onDelete(ids)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func primaryText(for entry: HistoryEntry) -> String {
        if let clipText = entry.clipText, !clipText.isEmpty {
            return clipText
        }
        if let chapterTitle = entry.chapterTitle, !chapterTitle.isEmpty {
            return chapterTitle
        }
        return "Reading position"
    }

    private func secondaryText(for entry: HistoryEntry) -> String {
        var parts: [String] = []

        if let reason = entry.reason, !reason.isEmpty {
            parts.append(reason)
        }

        let hasClipText = (entry.clipText?.isEmpty == false)
        if hasClipText,
           let chapterTitle = entry.chapterTitle,
           !chapterTitle.isEmpty {
            parts.append(chapterTitle)
        }

        if let number = entry.clipNumberInChapter,
           let total = entry.clipCountInChapter {
            parts.append("Clip \(number)/\(total)")
        }

        if let progress = entry.chapterProgress {
            parts.append("\(Int((progress * 100).rounded()))%")
        }

        parts.append(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}

private struct MediaOverlayPlaybackBar: View {
    @ObservedObject var playback: MediaOverlayPlaybackController
    @Binding var playbackSpeed: Double
    let playbackJumpInterval: Double
    @Binding var fontSize: Double
    @Binding var lineHeight: Double
    @Binding var fontFamilyRawValue: String
    @Binding var readingBackgroundRawValue: String
    let customFontFamilies: [CustomFontStore.ImportedFontFamily]
    @Binding var isSpeedControlPresented: Bool
    @Binding var isReaderSettingsControlPresented: Bool
    let toggleSpeedControl: () -> Void
    let toggleReaderSettingsControl: () -> Void
    let playPause: () -> Void
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isSpeedControlPresented || isReaderSettingsControlPresented {
                Group {
                    if isSpeedControlPresented {
                        PlaybackSpeedControlPanel(playbackSpeed: $playbackSpeed)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if isReaderSettingsControlPresented {
                        ReaderTypographyControlPanel(
                            fontSize: $fontSize,
                            lineHeight: $lineHeight,
                            fontFamilyRawValue: $fontFamilyRawValue,
                            readingBackgroundRawValue: $readingBackgroundRawValue,
                            customFontFamilies: customFontFamilies
                        )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
            }

            HStack(spacing: 0) {
                Button(action: toggleSpeedControl) {
                    Text(ReaderSettings.playbackSpeedText(playbackSpeed))
                        .font(.body.weight(.medium))
                        .frame(width: 48, height: 48)
                        .background(Color(uiColor: .secondarySystemFill), in: Circle())
                }
                .accessibilityLabel("Playback speed")
                .accessibilityValue(ReaderSettings.playbackSpeedText(playbackSpeed))
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Button(action: previous) {
                    Image(systemName: ReaderSettings.playbackJumpSymbolName(playbackJumpInterval, direction: .backward))
                        .font(.title3.weight(.medium))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(.blue)
                }
                .accessibilityLabel(ReaderSettings.playbackJumpAccessibilityLabel(playbackJumpInterval, direction: .backward))
                .buttonStyle(.plain)
                .disabled(!playback.canJumpBackward)
                .frame(maxWidth: .infinity)

                Button(action: playPause) {
                    Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 48, height: 48)
                        .background(.blue, in: Circle())
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(playback.state.isPlaying ? "Pause read-aloud" : "Play read-aloud")
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Button(action: next) {
                    Image(systemName: ReaderSettings.playbackJumpSymbolName(playbackJumpInterval, direction: .forward))
                        .font(.title3.weight(.medium))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(.blue)
                }
                .accessibilityLabel(ReaderSettings.playbackJumpAccessibilityLabel(playbackJumpInterval, direction: .forward))
                .buttonStyle(.plain)
                .disabled(!playback.canJumpForward)
                .frame(maxWidth: .infinity)

                Button(action: toggleReaderSettingsControl) {
                    Image(systemName: "textformat.size")
                        .font(.body.weight(.medium))
                        .frame(width: 48, height: 48)
                        .background(Color(uiColor: .secondarySystemFill), in: Circle())
                }
                .accessibilityLabel("Reader settings")
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .animation(.easeInOut(duration: 0.2), value: isSpeedControlPresented)
        .animation(.easeInOut(duration: 0.2), value: isReaderSettingsControlPresented)
    }
}

private struct PlaybackSpeedControlPanel: View {
    @Binding var playbackSpeed: Double

    var body: some View {
        ReaderControlPanel {
            ReaderSettingSliderRow(
                title: "Playback Speed",
                valueText: ReaderSettings.playbackSpeedText(playbackSpeed),
                value: Binding(
                    get: { ReaderSettings.normalizedPlaybackSpeed(playbackSpeed) },
                    set: { playbackSpeed = ReaderSettings.normalizedPlaybackSpeed($0) }
                ),
                range: ReaderSettings.playbackSpeedRange,
                step: ReaderSettings.playbackSpeedStep
            )
        }
    }
}

private struct ReaderTypographyControlPanel: View {
    private enum PanelMode {
        case typography
        case fontFamilySelection
    }

    @Binding var fontSize: Double
    @Binding var lineHeight: Double
    @Binding var fontFamilyRawValue: String
    @Binding var readingBackgroundRawValue: String
    let customFontFamilies: [CustomFontStore.ImportedFontFamily]
    @State private var panelMode: PanelMode = .typography

    var body: some View {
        ReaderControlPanel {
            switch panelMode {
            case .typography:
                VStack(spacing: 10) {
                    ReaderSettingSliderRow(
                        title: "Font Size",
                        valueText: ReaderSettings.fontSizeText(fontSize),
                        value: Binding(
                            get: { ReaderSettings.normalizedFontSize(fontSize) },
                            set: { fontSize = ReaderSettings.normalizedFontSize($0) }
                        ),
                        range: ReaderSettings.fontSizeRange,
                        step: ReaderSettings.fontSizeStep
                    )

                    Divider()

                    ReaderSettingSliderRow(
                        title: "Line Height",
                        valueText: ReaderSettings.lineHeightText(lineHeight),
                        value: Binding(
                            get: { ReaderSettings.normalizedLineHeight(lineHeight) },
                            set: { lineHeight = ReaderSettings.normalizedLineHeight($0) }
                        ),
                        range: ReaderSettings.lineHeightRange,
                        step: ReaderSettings.lineHeightStep
                    )

                    Divider()

                    Button {
                        panelMode = .fontFamilySelection
                    } label: {
                        HStack(spacing: 12) {
                            Text("Font Family")
                                .font(.subheadline.weight(.semibold))

                            Spacer(minLength: 12)

                            Text(ReaderSettings.fontFamilyName(from: fontFamilyRawValue, customFontFamilies: customFontFamilies))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()

                    HStack(spacing: 12) {
                        Text("Background")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 12)

                        HStack(spacing: 10) {
                            ForEach(ReadingBackgroundOption.allCases) { option in
                                Button {
                                    readingBackgroundRawValue = option.rawValue
                                } label: {
                                    Circle()
                                        .fill(option.swatchColor)
                                        .frame(width: 26, height: 26)
                                        .overlay {
                                            Circle()
                                                .stroke(
                                                    isSelected(option) ? Color.primary : Color.black.opacity(0.12),
                                                    lineWidth: isSelected(option) ? 3 : 1
                                                )
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(option.name) background")
                                .accessibilityAddTraits(isSelected(option) ? .isSelected : [])
                            }
                        }
                    }
                }

            case .fontFamilySelection:
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        panelMode = .typography
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            FontFamilySelectionList(
                                customFontFamilies: customFontFamilies,
                                selectedFontFamilyRawValue: $fontFamilyRawValue,
                                onSelect: nil,
                                showsSeparators: true
                            )
                        }
                    }
                    .frame(maxHeight: 260)
                }
            }
        }
    }

    private func isSelected(_ option: ReadingBackgroundOption) -> Bool {
        option.rawValue == readingBackgroundRawValue
    }
}

private struct ReaderControlPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.black.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

private func flattenChapterLinks(_ links: [ReadiumShared.Link], level: Int = 0) -> [ChapterListItem] {
    links.flatMap { [ChapterListItem(level: level, link: $0)] + flattenChapterLinks($0.children, level: level + 1) }
}

private struct NavigatorFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct PlaybackBarFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct EPUBNavigatorHost: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    let onLocationDidChange: (Locator) -> Void
    let onAudioTap: (String, CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onLocationDidChange: onLocationDidChange,
            onAudioTap: onAudioTap
        )
    }

    func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        navigator.delegate = context.coordinator
        context.coordinator.attach(to: navigator)
        return navigator
    }

    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {
        context.coordinator.onLocationDidChange = onLocationDidChange
        context.coordinator.onAudioTap = onAudioTap
        context.coordinator.attach(to: uiViewController)
        uiViewController.delegate = context.coordinator
    }

    static func dismantleUIViewController(_ uiViewController: EPUBNavigatorViewController, coordinator: Coordinator) {
        coordinator.detach(from: uiViewController)
    }

    final class Coordinator: NSObject, EPUBNavigatorDelegate, UIGestureRecognizerDelegate, WKScriptMessageHandler {
        private enum BoundaryEdge {
            case top
            case bottom
        }

        var onLocationDidChange: (Locator) -> Void
        var onAudioTap: (String, CGPoint) -> Void
        private weak var navigator: EPUBNavigatorViewController?
        private weak var userContentController: WKUserContentController?
        private var panRecognizer: UIPanGestureRecognizer?
        private var currentViewport: EPUBNavigatorViewController.Viewport?
        private var armedBoundaryEdge: BoundaryEdge?
        private var boundaryPanStartEdge: BoundaryEdge?
        private var boundaryPanReachedEdge: BoundaryEdge?
        private var boundaryPanStartedWithArmedEdge = false
        private var lastBoundaryNavigationDate: Date?
        private let boundaryPullThreshold: CGFloat = 100
        private let boundaryProgressThreshold = 0.9997
        private let boundaryCooldown: TimeInterval = 1.0
        private let audioTapMessageName = "mediaOverlayAudioTap"

        init(
            onLocationDidChange: @escaping (Locator) -> Void,
            onAudioTap: @escaping (String, CGPoint) -> Void
        ) {
            self.onLocationDidChange = onLocationDidChange
            self.onAudioTap = onAudioTap
        }

        func attach(to navigator: EPUBNavigatorViewController) {
            self.navigator = navigator

            if panRecognizer == nil {
                let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleBoundaryPan(_:)))
                panRecognizer.cancelsTouchesInView = false
                panRecognizer.delegate = self
                navigator.view.addGestureRecognizer(panRecognizer)
                self.panRecognizer = panRecognizer
            }
        }

        func detach(from navigator: EPUBNavigatorViewController? = nil) {
            let navigator = navigator ?? self.navigator
            if let navigator,
               let panRecognizer {
                navigator.view.removeGestureRecognizer(panRecognizer)
            }
            panRecognizer = nil

            if let navigator,
               navigator.delegate === self {
                navigator.delegate = nil
            }

            userContentController?.removeScriptMessageHandler(forName: audioTapMessageName)
            userContentController = nil
            currentViewport = nil
            self.navigator = nil
        }

        func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
            onLocationDidChange(locator)
        }

        func navigator(_ navigator: EPUBNavigatorViewController, viewportDidChange viewport: EPUBNavigatorViewController.Viewport?) {
            currentViewport = viewport
            if let currentBoundaryEdge = currentBoundaryEdge() {
                boundaryPanReachedEdge = currentBoundaryEdge
            } else if currentBoundaryEdge() != armedBoundaryEdge {
                armedBoundaryEdge = nil
            }
        }

        func navigator(_ navigator: EPUBNavigatorViewController, setupUserScripts userContentController: WKUserContentController) {
            self.userContentController = userContentController
            userContentController.removeScriptMessageHandler(forName: audioTapMessageName)
            userContentController.add(self, name: audioTapMessageName)
            userContentController.addUserScript(
                WKUserScript(
                    source: lineHeightOverrideScript(),
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
            userContentController.addUserScript(
                WKUserScript(
                    source: audioTapScript(messageName: audioTapMessageName),
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        }

        func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == audioTapMessageName,
                  let body = message.body as? [String: Any],
                  let href = body["href"] as? String,
                  let x = body["x"] as? Double,
                  let y = body["y"] as? Double
            else {
                return
            }

            onAudioTap(href, CGPoint(x: x, y: y))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func handleBoundaryPan(_ gestureRecognizer: UIPanGestureRecognizer) {
            switch gestureRecognizer.state {
            case .began:
                boundaryPanStartEdge = currentBoundaryEdge()
                boundaryPanReachedEdge = boundaryPanStartEdge
                boundaryPanStartedWithArmedEdge = boundaryPanStartEdge == armedBoundaryEdge

            case .changed:
                if let currentBoundaryEdge = currentBoundaryEdge() {
                    boundaryPanReachedEdge = currentBoundaryEdge
                }

            case .ended:
                defer {
                    boundaryPanStartEdge = nil
                    boundaryPanReachedEdge = nil
                    boundaryPanStartedWithArmedEdge = false
                }

                guard let targetBoundaryEdge = boundaryPanReachedEdge ?? currentBoundaryEdge() else {
                    armedBoundaryEdge = nil
                    return
                }

                let translation = gestureRecognizer.translation(in: gestureRecognizer.view)
                let isVerticalPull = abs(translation.y) > abs(translation.x)
                let isPullingTowardBoundary =
                    (targetBoundaryEdge == .bottom && translation.y < 0) ||
                    (targetBoundaryEdge == .top && translation.y > 0)

                guard isVerticalPull, isPullingTowardBoundary else {
                    armedBoundaryEdge = currentBoundaryEdge() == targetBoundaryEdge ? targetBoundaryEdge : nil
                    return
                }

                guard boundaryPanStartedWithArmedEdge,
                      boundaryPanStartEdge == targetBoundaryEdge,
                      abs(translation.y) >= boundaryPullThreshold,
                      canTriggerBoundaryNavigation(),
                      let navigator
                else {
                    armedBoundaryEdge = targetBoundaryEdge
                    return
                }

                armedBoundaryEdge = nil

                if targetBoundaryEdge == .bottom {
                    triggerBoundaryNavigation { await navigator.goForward(options: .animated) }
                } else {
                    triggerBoundaryNavigation { await navigator.goBackward(options: .animated) }
                }

            case .cancelled, .failed:
                boundaryPanStartEdge = nil
                boundaryPanReachedEdge = nil
                boundaryPanStartedWithArmedEdge = false

            default:
                break
            }
        }

        private func currentBoundaryEdge() -> BoundaryEdge? {
            guard let viewport = currentViewport,
                  let href = viewport.readingOrder.first,
                  let progression = viewport.progressions[href]
            else {
                return nil
            }

            if progression.upperBound >= boundaryProgressThreshold {
                return .bottom
            }

            if progression.lowerBound <= (1 - boundaryProgressThreshold) {
                return .top
            }

            return nil
        }

        private func canTriggerBoundaryNavigation() -> Bool {
            guard let lastBoundaryNavigationDate else {
                return true
            }

            return Date().timeIntervalSince(lastBoundaryNavigationDate) > boundaryCooldown
        }

        private func triggerBoundaryNavigation(_ action: @escaping @MainActor () async -> Bool) {
            lastBoundaryNavigationDate = Date()
            Task { @MainActor in
                _ = await action()
            }
        }

        private func audioTapScript(messageName: String) -> String {
            """
            (() => {
              if (window.__immersiveReaderAudioTapInstalled) {
                return;
              }
              window.__immersiveReaderAudioTapInstalled = true;

              const messageHandler = window.webkit?.messageHandlers?.\(messageName);
              if (!messageHandler) {
                return;
              }

              const ignoredSelector = 'a, button, input, textarea, select, summary, label, [role="button"], [contenteditable="true"]';

              document.addEventListener('click', event => {
                const target = event.target;
                if (!(target instanceof Element)) {
                  return;
                }

                if (target.closest(ignoredSelector)) {
                  return;
                }

                const href = window.location.pathname.replace(/^\\//, '');
                if (!href) {
                  return;
                }

                messageHandler.postMessage({
                  href,
                  x: event.clientX,
                  y: event.clientY
                });
              }, true);
            })();
            """
        }

        private func lineHeightOverrideScript() -> String {
            """
            (() => {
              const styleID = 'immersive-reader-line-height-override';
              if (document.getElementById(styleID)) {
                return;
              }

              const style = document.createElement('style');
              style.id = styleID;
              style.textContent = `
                :root[style*="readium-advanced-on"][style*="--USER__lineHeight"] body,
                :root[style*="readium-advanced-on"][style*="--USER__lineHeight"] body *:not(img):not(svg):not(video):not(audio):not(canvas):not(iframe) {
                  line-height: inherit !important;
                }
              `;

              (document.head || document.documentElement).appendChild(style);
            })();
            """
        }
    }
}
