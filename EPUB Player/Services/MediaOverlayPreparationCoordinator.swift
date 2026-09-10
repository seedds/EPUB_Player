//
//  MediaOverlayPreparationCoordinator.swift
//  EPUB Player
//

import Foundation

@MainActor
final class MediaOverlayPreparationCoordinator {
    static let shared = MediaOverlayPreparationCoordinator()

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var progressSnapshots: [UUID: OperationProgress] = [:]
    private var progressObservers: [UUID: [UUID: (@MainActor @Sendable (OperationProgress) -> Void)]] = [:]

    private init() {}

    func resumePendingBooks(store: AppStateStore) {
        // Reclaim dot-prefixed staged manifests (`.<bookID>-<generation>.json`)
        // orphaned by a crash mid-preparation. The normal path removes them in
        // a `defer`, so anything older than the staging age here is dead.
        if let overlaysDirectory = try? AppStorage.mediaOverlaysDirectory() {
            AppStorage.sweepStagingFiles(
                in: overlaysDirectory,
                prefix: ".",
                olderThan: Date().addingTimeInterval(-BookImportService.stalePartialImportAge)
            )
        }

        let books = store.books

        for book in books {
            if book.mediaOverlayPreparationState == .processing {
                book.mediaOverlayPreparationState = .pending
                book.mediaOverlayPreparationError = nil
            }

            if book.mediaOverlayPreparationState == .pending {
                enqueuePreparation(for: book.id, store: store, priority: .utility)
            } else if book.mediaOverlayPreparationState == .ready {
                _ = revalidatePendingClipPositionsAgainstCachedOverlay(for: book)
            }
        }
        // State mutations above already schedule a debounced save via the book
        // subscription.
    }

    func enqueuePreparation(
        for bookID: UUID,
        store: AppStateStore,
        priority: TaskPriority,
        allowFailedRetry: Bool = false
    ) {
        guard tasks[bookID] == nil,
              let book = store.book(withID: bookID)
        else {
            return
        }

        if book.mediaOverlayPreparationState == .failed, !allowFailedRetry {
            return
        }
        if book.mediaOverlayPreparationState == .ready,
           BookAssetCacheService.hasOverlayManifest(for: book) {
            return
        }

        // The `.processing` transition is not forced to disk: the debounced
        // save covers it, and `resumePendingBooks` treats a persisted
        // `.processing` exactly like `.pending`, so a crash before the write
        // resumes identically.
        book.mediaOverlayPreparationState = .processing
        book.mediaOverlayPreparationError = nil
        let contentGeneration = book.contentGeneration
        publishProgress(
            OperationProgress(fractionCompleted: 0, message: "Preparing read-aloud..."),
            for: bookID
        )

        // Capture this task so the defer only clears the map entry when it still
        // belongs to THIS task. Without the identity check, a cancel +
        // re-enqueue could let this (now-cancelled) task's defer delete a newer
        // task's entry, allowing a duplicate concurrent preparation.
        var thisTask: Task<Void, Never>?
        let task = Task { @MainActor [weak self] in
            defer {
                self?.clearTaskEntryIfCurrent(for: bookID, task: thisTask)
            }

            guard let sourceURL = try? book.resolvedEPUBFileURL() else {
                book.mediaOverlayPreparationState = .failed
                book.mediaOverlayPreparationError = "The EPUB file could not be found."
                return
            }

            let stagedManifestURL: URL
            do {
                stagedManifestURL = try AppStorage.mediaOverlaysDirectory().appendingPathComponent(
                    ".\(bookID.uuidString)-\(contentGeneration.uuidString).json",
                    isDirectory: false
                )
            } catch {
                guard self?.isCurrentGeneration(contentGeneration, for: bookID, store: store) == true else {
                    return
                }
                book.mediaOverlayPreparationState = .failed
                book.mediaOverlayPreparationError = error.localizedDescription
                return
            }
            defer {
                try? FileManager.default.removeItem(at: stagedManifestURL)
            }

            do {
                let progressHandler: @Sendable (OperationProgress) -> Void = { [weak self] progress in
                    DispatchQueue.main.async {
                        guard self?.isCurrentGeneration(contentGeneration, for: bookID, store: store) == true else {
                            return
                        }
                        self?.publishProgress(progress, for: bookID)
                    }
                }
                // Detached tasks don't inherit cancellation; forward it so a
                // deleted book's parse stops instead of re-writing its cache.
                let parseTask = Task.detached(priority: priority) {
                    try await EPUBMediaOverlayService.parseAndWrite(
                        at: sourceURL,
                        destinationURL: stagedManifestURL,
                        progressHandler: progressHandler
                    )
                }
                let result = try await withTaskCancellationHandler {
                    try await parseTask.value
                } onCancel: {
                    parseTask.cancel()
                }

                guard !Task.isCancelled,
                      self?.isCurrentGeneration(contentGeneration, for: bookID, store: store) == true,
                      let updatedBook = store.book(withID: bookID)
                else {
                    return
                }

                if result != nil {
                    let finalManifestURL = try AppStorage.mediaOverlayManifestURL(for: bookID)
                    // Move the staged manifest into place instead of reading the
                    // whole file into memory and rewriting it on the main actor.
                    let fileManager = FileManager.default
                    if fileManager.fileExists(atPath: finalManifestURL.path) {
                        _ = try fileManager.replaceItemAt(finalManifestURL, withItemAt: stagedManifestURL)
                    } else {
                        try fileManager.moveItem(at: stagedManifestURL, to: finalManifestURL)
                    }
                }

                updatedBook.mediaOverlayJSONPath = result == nil ? nil : try AppStorage.mediaOverlayManifestURL(for: bookID).lastPathComponent
                updatedBook.mediaOverlayDuration = result?.duration
                updatedBook.mediaOverlayClipCount = result?.clipCount
                updatedBook.mediaOverlayPreparationState = .ready
                updatedBook.mediaOverlayPreparationError = nil
                if updatedBook.pendingClipPositionRevalidation {
                    let clips = result?.documents.flatMap(\.clips) ?? []
                    Self.revalidateClipPositions(for: updatedBook, against: clips)
                    updatedBook.pendingClipPositionRevalidation = false
                }
                self?.publishProgress(
                    OperationProgress(fractionCompleted: 1, message: "Read-aloud ready"),
                    for: bookID
                )
            } catch {
                guard !Task.isCancelled,
                      self?.isCurrentGeneration(contentGeneration, for: bookID, store: store) == true,
                      let updatedBook = store.book(withID: bookID)
                else {
                    return
                }

                updatedBook.mediaOverlayJSONPath = nil
                updatedBook.mediaOverlayDuration = nil
                updatedBook.mediaOverlayClipCount = nil
                updatedBook.mediaOverlayPreparationState = .failed
                updatedBook.mediaOverlayPreparationError = error.localizedDescription
                if updatedBook.pendingClipPositionRevalidation {
                    // Preparation failed, so there are no clips to validate
                    // against; drop the dangling clip-based positions.
                    Self.revalidateClipPositions(for: updatedBook, against: [])
                    updatedBook.pendingClipPositionRevalidation = false
                }
                self?.publishProgress(
                    OperationProgress(fractionCompleted: 1, message: "Read-aloud unavailable"),
                    for: bookID
                )
            }
        }
        thisTask = task
        tasks[bookID] = task
    }

    /// Validates a book's clip-based positions against the freshly prepared clip
    /// set, refreshing or pruning each. An empty clip list drops them all (used
    /// when preparation failed or produced no clips).
    @MainActor
    private static func revalidateClipPositions(for book: Book, against clips: [EPUBMediaOverlayClip]) {
        let positions = BookPositionValidator.Positions(book)
        let validated = clips.isEmpty
            ? BookPositionValidator.droppingClipPositions(positions)
            : BookPositionValidator.validatedAgainstClips(positions, clips: clips)
        validated.apply(to: book)
    }

    func cancelPreparation(for bookID: UUID) {
        tasks[bookID]?.cancel()
        tasks.removeValue(forKey: bookID)
    }

    func cancelAndWaitPreparation(for bookID: UUID) async {
        guard let task = tasks[bookID] else {
            return
        }
        task.cancel()
        await task.value
        clearTaskEntryIfCurrent(for: bookID, task: task)
    }

    /// Removes the map entry for `bookID` only when it still holds `task`. A
    /// task that was cancelled and superseded by a re-enqueue must NOT clear the
    /// newer task's entry (which would allow a duplicate concurrent
    /// preparation), so a finished task clears the map only if it is still the
    /// tracked one.
    private func clearTaskEntryIfCurrent(for bookID: UUID, task: Task<Void, Never>?) {
        guard let task, tasks[bookID] == task else {
            return
        }
        tasks.removeValue(forKey: bookID)
    }

    func ensurePreparedForPlayback(
        bookID: UUID,
        store: AppStateStore,
        progressHandler: (@MainActor @Sendable (OperationProgress) -> Void)? = nil
    ) async {
        let observerID = progressHandler.map { addProgressObserver(for: bookID, using: $0) }
        defer {
            if let observerID {
                removeProgressObserver(observerID, for: bookID)
            }
        }

        if let task = tasks[bookID] {
            await task.value
            return
        }

        guard let book = store.book(withID: bookID) else {
            return
        }

        switch book.mediaOverlayPreparationState {
        case .failed:
            return
        case .ready:
            if BookAssetCacheService.hasOverlayManifest(for: book) {
                // Any revalidation mutation schedules a debounced save.
                _ = revalidatePendingClipPositionsAgainstCachedOverlay(for: book)
                return
            }
            book.mediaOverlayPreparationState = .pending
            book.mediaOverlayPreparationError = nil
            fallthrough
        case .pending, .processing:
            enqueuePreparation(for: bookID, store: store, priority: .userInitiated)
            if let task = tasks[bookID] {
                await task.value
            }
        }
    }

    private func isCurrentGeneration(_ generation: UUID, for bookID: UUID, store: AppStateStore) -> Bool {
        store.book(withID: bookID)?.contentGeneration == generation
    }

    @discardableResult
    private func revalidatePendingClipPositionsAgainstCachedOverlay(for book: Book) -> Bool {
        guard book.pendingClipPositionRevalidation,
              let clips = BookAssetCacheService.cachedOverlayClips(for: book),
              !clips.isEmpty
        else {
            return false
        }

        Self.revalidateClipPositions(for: book, against: clips)
        book.pendingClipPositionRevalidation = false
        return true
    }

    private func addProgressObserver(
        for bookID: UUID,
        using progressHandler: @escaping @MainActor @Sendable (OperationProgress) -> Void
    ) -> UUID {
        let observerID = UUID()
        if progressObservers[bookID] == nil {
            progressObservers[bookID] = [:]
        }
        progressObservers[bookID]?[observerID] = progressHandler

        if let progress = progressSnapshots[bookID] {
            progressHandler(progress)
        }

        return observerID
    }

    private func removeProgressObserver(_ observerID: UUID, for bookID: UUID) {
        progressObservers[bookID]?[observerID] = nil
        if progressObservers[bookID]?.isEmpty == true {
            progressObservers[bookID] = nil
        }
    }

    private func publishProgress(_ progress: OperationProgress, for bookID: UUID) {
        progressSnapshots[bookID] = progress
        progressObservers[bookID]?.values.forEach { observer in
            observer(progress)
        }
    }

}

#if DEBUG
extension MediaOverlayPreparationCoordinator {
    /// Stores a no-op task under `bookID` and returns it, so tests can drive the
    /// cancel + re-enqueue identity logic with real `Task` instances.
    func test_trackDummyTask(for bookID: UUID) -> Task<Void, Never> {
        let task = Task<Void, Never> {}
        tasks[bookID] = task
        return task
    }

    func test_isTracked(_ bookID: UUID) -> Bool {
        tasks[bookID] != nil
    }

    /// Exposes the identity-guarded map cleanup used by a finished task's defer.
    func test_clearTaskEntryIfCurrent(for bookID: UUID, task: Task<Void, Never>?) {
        clearTaskEntryIfCurrent(for: bookID, task: task)
    }

    func test_isCurrentGeneration(_ generation: UUID, for bookID: UUID, store: AppStateStore) -> Bool {
        isCurrentGeneration(generation, for: bookID, store: store)
    }

    /// Cancels and drains all in-flight preparation work. Used by tests that
    /// create transient EPUB libraries so background preparation cannot keep
    /// touching deleted files after the test has moved on to another suite.
    func test_cancelAllPreparations() async {
        let activeTasks = Array(tasks.values)
        tasks.removeAll()
        progressSnapshots.removeAll()
        progressObservers.removeAll()

        for task in activeTasks {
            task.cancel()
        }
        for task in activeTasks {
            await task.value
        }
    }
}
#endif
