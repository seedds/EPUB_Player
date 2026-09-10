//
//  BookImportService.swift
//  EPUB Player
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation

enum BookImportError: LocalizedError {
    case notEpub(String)
    case libraryFilesUnavailable
    case destinationNameCollision(String)

    var errorDescription: String? {
        switch self {
        case .notEpub(let filename):
            "Only EPUB files are supported. \(filename) is not an EPUB."
        case .libraryFilesUnavailable:
            "Could not verify the imported EPUB files. Your library was left unchanged."
        case .destinationNameCollision(let filename):
            "Another book already uses the name \(filename)."
        }
    }
}

enum BookImportService {
    private struct SourceFileFingerprint: Sendable, Equatable {
        let fileSize: Int64?
        let modifiedAt: Date?
    }

    private struct ExistingBookSnapshot: Sendable {
        let id: UUID
        let originalFilename: String
        let epubFilePath: String
        let sourceFileSize: Int64?
        let sourceFileModifiedAt: Date?
    }

    private struct PreparedBookImport: Sendable {
        let stagedLibraryFile: StagedLibraryFile
        let id: UUID
        let filename: String
        let epubFilePath: String
        let metadata: EPUBMetadata
        /// The committed cover's stored filename. Nil until `applyPreparedImport`
        /// promotes the staged cover, and nil for a book with no cover.
        var coverImagePath: String?
        let fingerprint: SourceFileFingerprint
        let contentGeneration: UUID
        /// Content-document hrefs from the new EPUB manifest, used to validate
        /// saved positions on reimport.
        let resourceHrefs: [String]
        /// A new cover written under a temporary staging name during prepare, or
        /// nil when the EPUB has no cover. Promoted to the canonical name at
        /// commit so a failed overwrite cannot destroy the existing cover.
        let stagedCoverFilename: String?
    }

    private struct StagedLibraryFile: Sendable {
        let fileURL: URL
        let destinationURL: URL
        let shouldCleanupOnFailure: Bool
    }

    enum ExistingBookStrategy {
        case skip
        case overwrite
    }

    /// Leading-dot prefix for in-library staging files. Dot-prefixed so an
    /// in-progress import is skipped by the `.skipsHiddenFiles` library scan;
    /// `removeStalePartialImports` reclaims any left behind by a crash/cancel.
    nonisolated static let stagedImportPrefix = ".import-"

    @MainActor
    @discardableResult
    static func importBook(
        from sourceURL: URL,
        filename requestedFilename: String,
        store: AppStateStore,
        existingBookStrategy: ExistingBookStrategy = .skip,
        progressHandler: (@MainActor @Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> Book? {
        let filename = AppStorage.sanitizedFilename(requestedFilename)
        guard UploadFileKind.isEPUB(filename) else {
            throw BookImportError.notEpub(filename)
        }

        try Task.checkCancellation()

        let existingBook = store.firstBook(originalFilename: filename)
        let existingBookSnapshot = existingBook.map(snapshot(for:))

        let bookID = existingBook?.id ?? UUID()
        let prepareTask = Task.detached(priority: .userInitiated) {
            try await prepareImport(
                from: sourceURL,
                filename: filename,
                existingBook: existingBookSnapshot,
                existingBookStrategy: existingBookStrategy,
                bookID: bookID,
                progressHandler: progressHandler
            )
        }
        // Task.detached does not inherit cancellation; forward it so a cancelled
        // import stops the long prepare work instead of running to completion.
        let preparedImport = try await withTaskCancellationHandler {
            try await prepareTask.value
        } onCancel: {
            prepareTask.cancel()
        }

        guard let preparedImport else {
            return nil
        }

        await reportProgress(
            OperationProgress(fractionCompleted: 0.96, message: "Saving book..."),
            using: progressHandler
        )

        do {
            // Inside the do/catch so a cancellation landing here cleans up the
            // already-staged file and cover instead of leaking them (the staged
            // `.import-*` file is dot-prefixed, so no sweep would reclaim it).
            try Task.checkCancellation()

            if let existingBook {
                await MediaOverlayPreparationCoordinator.shared.cancelAndWaitPreparation(for: existingBook.id)
                try Task.checkCancellation()
            }

            let book = try applyPreparedImport(
                preparedImport,
                existingBookID: existingBook?.id,
                store: store
            )
            MediaOverlayPreparationCoordinator.shared.enqueuePreparation(
                for: book.id,
                store: store,
                priority: .utility
            )

            await reportProgress(
                OperationProgress(fractionCompleted: 1, message: "Import complete"),
                using: progressHandler
            )
            return book
        } catch {
            cleanupPreparedImport(preparedImport)
            throw error
        }
    }

    @MainActor
    @discardableResult
    static func refreshBooksFromDocuments(
        store: AppStateStore,
        progressHandler: (@MainActor @Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> [Book] {
        // Sample this before anything else: nearly every AppStorage accessor
        // creates the directory it returns, so after the first such call the
        // difference between "the library directory is gone" and "the library
        // is empty" is no longer observable.
        let libraryDirectoryExisted = AppStorage.booksDirectoryExists()

        await reportProgress(
            OperationProgress(fractionCompleted: 0.02, message: "Scanning EPUB files..."),
            using: progressHandler
        )

        // Reclaim any dot-prefixed `.import-*` staging files orphaned by an
        // import that was cancelled/crashed mid-flight. The normal library scan
        // uses `.skipsHiddenFiles`, so these would otherwise never be found.
        removeStalePartialImports()

        let existingBooks = store.books
        let fileManager = FileManager.default
        let epubURLs = try await refreshSourceEPUBURLs(
            existingBooks: existingBooks,
            fileManager: fileManager,
            libraryDirectoryExisted: libraryDirectoryExisted,
            progressHandler: progressHandler
        )

        let removedBooks = existingBooks.filter { book in
            // Only a file that definitively is not there counts as removed. A
            // path that fails to resolve (data protection, a transient
            // Documents lookup failure) is unknown, not absent — treating it as
            // absent would discard the book's bookmarks and reading position.
            guard let epubURL = try? book.resolvedEPUBFileURL() else {
                return false
            }

            return !fileManager.fileExists(atPath: epubURL.path)
        }
        let totalOperations = max(removedBooks.count + epubURLs.count, 1)
        var completedOperations = 0

        for book in removedBooks {
            try? BookAssetCacheService.removeAllCachedAssets(for: book.id)
            store.removeBook(id: book.id)

            completedOperations += 1
            await reportProgress(
                OperationProgress(
                    fractionCompleted: 0.08 + (Double(completedOperations) / Double(totalOperations)) * 0.84,
                    message: "Removing missing books \(completedOperations) of \(removedBooks.count)"
                ),
                using: progressHandler
            )
        }

        // Built after the removal loop so re-scanned books resolve against the
        // current store, not against records that were just removed.
        let existingBooksByFilename = Dictionary(
            store.books.map { ($0.originalFilename, $0) },
            uniquingKeysWith: { _, newer in newer }
        )

        var refreshedBooks: [Book] = []
        var overlayRetryIDs: Set<UUID> = []
        var skippedFilenames: [String] = []
        for (index, sourceURL) in epubURLs.enumerated() {
            // Stop processing further files when the refresh is cancelled.
            try Task.checkCancellation()

            let filename = AppStorage.sanitizedFilename(sourceURL.lastPathComponent)
            // One unreadable file must not abort the refresh of every other book.
            do {
                guard UploadFileKind.isEPUB(filename) else {
                    throw BookImportError.notEpub(filename)
                }

                let fingerprint = try sourceFileFingerprint(for: sourceURL)
                let existingBook = existingBooksByFilename[filename]
                let book: Book

                if let existingBook,
                   shouldSkipPreparedBook(for: sourceURL, existingBook: snapshot(for: existingBook), fingerprint: fingerprint) {
                    let cachedCoverPath: String?
                    if !BookAssetCacheService.hasCachedCover(for: existingBook) {
                        cachedCoverPath = try await regenerateCoverImageCancellable(from: sourceURL, bookID: existingBook.id)
                    } else {
                        cachedCoverPath = nil
                    }

                    if let cachedCoverPath {
                        existingBook.coverImagePath = cachedCoverPath
                    }

                    if existingBook.mediaOverlayPreparationState == .processing {
                        existingBook.mediaOverlayPreparationState = .pending
                        existingBook.mediaOverlayPreparationError = nil
                    }

                    // Repair gate: a manifest that exists but no longer decodes
                    // must be regenerated. The decode runs off the main actor;
                    // this is evaluated once per existing book on every refresh.
                    if (existingBook.mediaOverlayClipCount ?? 0) > 0,
                       !(await BookAssetCacheService.overlayCacheIsValid(for: existingBook)) {
                        existingBook.mediaOverlayPreparationState = .pending
                        existingBook.mediaOverlayPreparationError = nil
                        existingBook.mediaOverlayJSONPath = nil
                        existingBook.mediaOverlayDuration = nil
                        existingBook.mediaOverlayClipCount = nil
                    }

                    if existingBook.mediaOverlayPreparationState == .pending || existingBook.mediaOverlayPreparationState == .failed {
                        overlayRetryIDs.insert(existingBook.id)
                    }

                    book = existingBook
                } else {
                    let prepareTask = Task.detached(priority: .userInitiated) {
                        try await prepareRefreshImport(from: sourceURL, filename: filename, bookID: existingBook?.id ?? UUID())
                    }
                    // Task.detached doesn't inherit cancellation; forward it.
                    let preparedImport = try await withTaskCancellationHandler {
                        try await prepareTask.value
                    } onCancel: {
                        prepareTask.cancel()
                    }

                    // The prepared import holds a staged cover; any throw from
                    // here on must remove it or it leaks in Cache/Covers (no
                    // sweep covers that directory, and a brand-new UUID is never
                    // reclaimed by a later commit).
                    do {
                        // Two distinct on-disk names can sanitise to the same
                        // destination. Renaming onto an existing, different file
                        // would clobber another book, so skip this one instead.
                        let destinationURL = preparedImport.stagedLibraryFile.destinationURL
                        let isRename = sourceURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path
                        if isRename, fileManager.fileExists(atPath: destinationURL.path) {
                            throw BookImportError.destinationNameCollision(filename)
                        }

                        if let existingBook {
                            await MediaOverlayPreparationCoordinator.shared.cancelAndWaitPreparation(for: existingBook.id)
                            try Task.checkCancellation()
                        }
                        // Route through applyPreparedImport (not upsertBook) so the
                        // staged file is renamed to its sanitised destination and the
                        // staged cover is promoted; upsertBook did neither, dropping
                        // covers and leaving records pointing at unsanitised names.
                        book = try applyPreparedImport(
                            preparedImport,
                            existingBookID: existingBook?.id,
                            store: store,
                            persist: false
                        )
                    } catch {
                        cleanupPreparedImport(preparedImport)
                        throw error
                    }

                    overlayRetryIDs.insert(book.id)
                }

                refreshedBooks.append(book)
            } catch is CancellationError {
                // The whole refresh was cancelled; don't misreport it as a
                // per-file skip. Abort the loop and propagate.
                throw CancellationError()
            } catch {
                DebugLog.shared.log("[refresh] skipped \(filename): \(error)")
                skippedFilenames.append(filename)
            }

            completedOperations += 1
            await reportProgress(
                OperationProgress(
                    fractionCompleted: 0.08 + (Double(completedOperations) / Double(totalOperations)) * 0.84,
                    message: "Updating library \(index + 1) of \(epubURLs.count)"
                ),
                using: progressHandler
            )
        }

        await reportProgress(
            OperationProgress(fractionCompleted: 0.97, message: "Saving library..."),
            using: progressHandler
        )
        store.persistNow()

        for bookID in overlayRetryIDs {
            MediaOverlayPreparationCoordinator.shared.enqueuePreparation(
                for: bookID,
                store: store,
                priority: .utility,
                allowFailedRetry: true
            )
        }

        let completionMessage: String
        if skippedFilenames.isEmpty {
            completionMessage = "Refresh complete"
        } else {
            let previewLimit = 5
            let preview = skippedFilenames.prefix(previewLimit).joined(separator: ", ")
            let overflow = skippedFilenames.count - previewLimit
            let suffix = overflow > 0 ? " and \(overflow) more" : ""
            completionMessage = "Refresh complete — skipped \(skippedFilenames.count): \(preview)\(suffix)"
        }
        await reportProgress(
            OperationProgress(fractionCompleted: 1, message: completionMessage),
            using: progressHandler
        )
        return refreshedBooks
    }

    /// Removes a book: cancels its read-aloud preparation, deletes its EPUB and
    /// cached assets from disk (logging but not failing on disk errors so the
    /// store record is always removed), and drops the store record. The single
    /// delete path shared by the library UI and the upload server. The caller
    /// persists.
    @MainActor
    static func deleteBook(_ book: Book, store: AppStateStore) {
        MediaOverlayPreparationCoordinator.shared.cancelPreparation(for: book.id)
        do {
            if let epubURL = try? book.resolvedEPUBFileURL() {
                try FileManager.default.removeItem(at: epubURL)
            }
            try BookAssetCacheService.removeAllCachedAssets(for: book.id)
        } catch {
            DebugLog.shared.log("BookImportService: failed to remove files for \(book.originalFilename): \(error)")
        }
        store.removeBook(id: book.id)
    }

    @MainActor
    private static func applyPreparedImport(
        _ preparedImport: PreparedBookImport,
        existingBookID: UUID?,
        store: AppStateStore,
        persist: Bool = true
    ) throws -> Book {
        // Commit the cover *before* moving the EPUB into place. Cover commit is
        // the fallible step (a cache move that can throw); the EPUB move is a
        // near-infallible same-directory rename. Doing the fallible work first
        // means a cover failure leaves the staged EPUB untouched, so the catch
        // in importBook can roll it back cleanly instead of leaving new bytes on
        // disk against the old store record.
        var preparedImport = preparedImport
        if let stagedCoverFilename = preparedImport.stagedCoverFilename {
            let finalCoverPath = try BookAssetCacheService.commitStagedCover(
                stagedFilename: stagedCoverFilename,
                for: preparedImport.id
            )
            preparedImport.coverImagePath = finalCoverPath
        } else {
            // No new cover: the reimported EPUB has none, so drop any prior one.
            try? BookAssetCacheService.removeCachedCover(for: preparedImport.id)
        }

        try finalizeStagedLibraryFile(preparedImport.stagedLibraryFile)

        // The old overlay artifacts are stale once the EPUB content changed;
        // remove them only after the new EPUB is in place.
        try? BookAssetCacheService.removeOverlayArtifacts(for: preparedImport.id)
        // New content may have a cover the previous file lacked.
        booksKnownWithoutCover.remove(preparedImport.id)

        let book = upsertBook(
            from: preparedImport,
            existingBook: existingBookID.flatMap { store.book(withID: $0) },
            store: store
        )

        if persist {
            store.persistNow()
        }
        return book
    }

    nonisolated private static func finalizeStagedLibraryFile(_ stagedLibraryFile: StagedLibraryFile) throws {
        let stagedURL = stagedLibraryFile.fileURL
        let destinationURL = stagedLibraryFile.destinationURL
        guard stagedURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path else {
            return
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
            return
        }

        try fileManager.moveItem(at: stagedURL, to: destinationURL)
    }

    @MainActor
    private static func upsertBook(
        from preparedImport: PreparedBookImport,
        existingBook: Book?,
        store: AppStateStore
    ) -> Book {
        if let existingBook {
            existingBook.title = preparedImport.metadata.title ?? displayTitle(for: preparedImport.filename)
            existingBook.author = preparedImport.metadata.author ?? "Unknown Author"
            existingBook.originalFilename = preparedImport.filename
            existingBook.epubFilePath = preparedImport.epubFilePath
            existingBook.coverImagePath = preparedImport.coverImagePath
            // New content: reset the media-overlay cache so preparation reruns.
            existingBook.mediaOverlayJSONPath = nil
            existingBook.mediaOverlayDuration = nil
            existingBook.mediaOverlayClipCount = nil
            existingBook.mediaOverlayPreparationState = .pending
            existingBook.mediaOverlayPreparationError = nil
            existingBook.sourceFileSize = preparedImport.fingerprint.fileSize
            existingBook.sourceFileModifiedAt = preparedImport.fingerprint.modifiedAt
            existingBook.contentGeneration = preparedImport.contentGeneration
            existingBook.importedAt = Date()
            // The file content changed (this branch only runs on a new
            // fingerprint). Rather than discard every saved position, keep the
            // ones that still resolve against the new content. Resource-href
            // validation runs now (manifest hrefs are known); clip validation is
            // deferred until the new media overlays finish preparing.
            applyResourceHrefValidatedPositions(to: existingBook, resourceHrefs: preparedImport.resourceHrefs)
            existingBook.pendingClipPositionRevalidation = bookHasClipPositions(existingBook)
            return existingBook
        }

        let newBook = Book(
            id: preparedImport.id,
            title: preparedImport.metadata.title ?? displayTitle(for: preparedImport.filename),
            author: preparedImport.metadata.author ?? "Unknown Author",
            originalFilename: preparedImport.filename,
            epubFilePath: preparedImport.epubFilePath,
            coverImagePath: preparedImport.coverImagePath,
            mediaOverlayPreparationStateRawValue: MediaOverlayPreparationState.pending.rawValue,
            sourceFileSize: preparedImport.fingerprint.fileSize,
            sourceFileModifiedAt: preparedImport.fingerprint.modifiedAt,
            contentGeneration: preparedImport.contentGeneration
        )
        store.addBook(newBook)
        return newBook
    }

    @MainActor
    private static func applyResourceHrefValidatedPositions(to book: Book, resourceHrefs: [String]) {
        // No resource hrefs means the manifest couldn't be read (e.g. a
        // malformed OPF). Validating against an empty set would wrongly prune
        // every position, so keep them all rather than trust an unknown
        // structure.
        guard !resourceHrefs.isEmpty else {
            return
        }

        let positions = BookPositionValidator.Positions(book)
        BookPositionValidator
            .validatedAgainstResourceHrefs(positions, resourceHrefs: resourceHrefs)
            .apply(to: book)
    }

    /// True when the book has any clip-based position (resume point, bookmark, or
    /// history entry) that still needs validation against new media overlays.
    @MainActor
    private static func bookHasClipPositions(_ book: Book) -> Bool {
        if book.lastPlayedTextResourceHref != nil, book.lastPlayedClipBegin != nil {
            return true
        }
        if book.bookmarks.contains(where: { $0.textResourceHref != nil && $0.clipBegin != nil }) {
            return true
        }
        if book.history.contains(where: { $0.textResourceHref != nil && $0.clipBegin != nil }) {
            return true
        }
        return false
    }

    nonisolated private static func prepareImport(
        from sourceURL: URL,
        filename: String,
        existingBook: ExistingBookSnapshot?,
        existingBookStrategy: ExistingBookStrategy,
        bookID: UUID,
        progressHandler: (@MainActor @Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> PreparedBookImport? {
        let stagedLibraryFile = try await stageSourceFileInLibrary(
            from: sourceURL,
            filename: filename,
            progressHandler: progressHandler
        )

        let stagedURL = stagedLibraryFile.fileURL

        // Everything after staging runs in this cleanup scope. Previously the
        // fingerprint read and skip-check sat outside the do/catch, so a throw
        // (or cancellation) between staging and prepare leaked the dot-prefixed
        // `.import-*` staged file, which no sweep reclaims.
        do {
            let fingerprint = try sourceFileFingerprint(for: stagedURL)
            if case .skip = existingBookStrategy,
               let existingBook,
               shouldSkipPreparedBook(for: stagedLibraryFile.destinationURL, existingBook: existingBook, fingerprint: fingerprint) {
                await reportProgress(
                    OperationProgress(fractionCompleted: 1, message: "Book already exists, skipping"),
                    using: progressHandler
                )
                if stagedLibraryFile.shouldCleanupOnFailure {
                    try? FileManager.default.removeItem(at: stagedURL)
                }
                return nil
            }

            let preparedImport = try await preparedBookImport(
                validating: stagedURL,
                stagedLibraryFile: stagedLibraryFile,
                filename: filename,
                bookID: bookID,
                fingerprint: fingerprint,
                progressHandler: progressHandler
            )
            await reportProgress(
                OperationProgress(fractionCompleted: 0.92, message: "Finalizing book..."),
                using: progressHandler
            )
            return preparedImport
        } catch {
            if stagedLibraryFile.shouldCleanupOnFailure {
                try? FileManager.default.removeItem(at: stagedURL)
            }
            throw error
        }
    }

    // The shared validate/metadata/cover body of the import and refresh
    // paths; keeping it in one place stops the two from diverging on what a
    // freshly (re)imported book looks like.
    nonisolated private static func preparedBookImport(
        validating fileURL: URL,
        stagedLibraryFile: StagedLibraryFile,
        filename: String,
        bookID: UUID,
        fingerprint: SourceFileFingerprint,
        progressHandler: (@MainActor @Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> PreparedBookImport {
        await reportProgress(
            OperationProgress(fractionCompleted: 0.24, message: "Validating EPUB..."),
            using: progressHandler
        )
        let archive = try await EPUBArchive(url: fileURL)
        try await archive.validateEPUB()

        await reportProgress(
            OperationProgress(fractionCompleted: 0.6, message: "Reading metadata..."),
            using: progressHandler
        )
        let package = try await EPUBMetadataService.packageInfo(in: archive)
        let metadata = package.map(EPUBMetadataService.metadata(from:)) ?? EPUBMetadata()

        await reportProgress(
            OperationProgress(fractionCompleted: 0.8, message: "Caching cover..."),
            using: progressHandler
        )
        // Stage the cover under a temporary name and DON'T remove overlay
        // artifacts here: on overwrite, `bookID` is the existing book's id, so
        // destroying its cover/overlay during prepare would damage the book we
        // are replacing if this import then fails or is cancelled. Both are
        // committed only in `applyPreparedImport`.
        let stagedCoverFilename = try await cacheStagedCoverImage(from: archive, package: package, bookID: bookID)

        return PreparedBookImport(
            stagedLibraryFile: stagedLibraryFile,
            id: bookID,
            filename: filename,
            epubFilePath: AppStorage.storedBookPath(for: filename),
            metadata: metadata,
            fingerprint: fingerprint,
            contentGeneration: UUID(),
            resourceHrefs: contentResourceHrefs(from: package),
            stagedCoverFilename: stagedCoverFilename
        )
    }

    /// Prepare-time cover caching: writes the new cover under a staging name
    /// without disturbing any existing cover. Returns the staged filename (or
    /// nil when the EPUB has no cover).
    nonisolated private static func cacheStagedCoverImage(
        from archive: EPUBArchive,
        package: EPUBPackageInfo?,
        bookID: UUID
    ) async throws -> String? {
        guard let package,
              let coverAsset = try await EPUBMetadataService.coverImageAsset(in: archive, package: package)
        else {
            return nil
        }
        return try BookAssetCacheService.cacheStagedCoverImage(asset: coverAsset, for: bookID)
    }

    /// Content-document hrefs (XHTML/HTML) from the parsed package manifest,
    /// used to validate that saved positions still point at existing resources.
    nonisolated private static func contentResourceHrefs(from package: EPUBPackageInfo?) -> [String] {
        guard let package else {
            return []
        }
        return package.manifestItems.compactMap { item in
            let mediaType = item.mediaType?.lowercased()
            let isContentDocument = mediaType == "application/xhtml+xml"
                || mediaType == "text/html"
                || item.href.lowercased().hasSuffix(".xhtml")
                || item.href.lowercased().hasSuffix(".html")
            return isContentDocument ? item.href : nil
        }
    }

    nonisolated private static func stageSourceFileInLibrary(
        from sourceURL: URL,
        filename: String,
        progressHandler: (@MainActor @Sendable (OperationProgress) -> Void)? = nil
    ) async throws -> StagedLibraryFile {
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        let libraryDirectory = try AppStorage.booksDirectory()
        let destinationURL = libraryDirectory.appendingPathComponent(filename, isDirectory: false)
        let stagedURL = libraryDirectory.appendingPathComponent(
            "\(stagedImportPrefix)\(UUID().uuidString)-\(filename)",
            isDirectory: false
        )
        let sourcePath = sourceURL.standardizedFileURL.path
        let destinationPath = destinationURL.standardizedFileURL.path

        await reportProgress(
            OperationProgress(fractionCompleted: 0.08, message: "Staging EPUB..."),
            using: progressHandler
        )

        let shouldMoveUploadedSource = shouldMoveUploadedSourceIntoLibrary(sourceURL)

        guard sourcePath != destinationPath else {
            return StagedLibraryFile(
                fileURL: destinationURL,
                destinationURL: destinationURL,
                shouldCleanupOnFailure: false
            )
        }

        if shouldMoveUploadedSource {
            try fileManager.moveItem(at: sourceURL, to: stagedURL)
        } else {
            try fileManager.copyItem(at: sourceURL, to: stagedURL)
        }

        return StagedLibraryFile(
            fileURL: stagedURL,
            destinationURL: destinationURL,
            shouldCleanupOnFailure: true
        )
    }

    nonisolated private static func prepareRefreshImport(
        from sourceURL: URL,
        filename: String,
        bookID: UUID
    ) async throws -> PreparedBookImport {
        let fingerprint = try sourceFileFingerprint(for: sourceURL)
        // Point the destination at the sanitised name so applyPreparedImport
        // renames a Files-app drop whose original name would be an invalid
        // stored path. finalizeStagedLibraryFile is a no-op when the source is
        // already at the sanitised destination.
        let destinationURL = try AppStorage.booksDirectory()
            .appendingPathComponent(filename, isDirectory: false)
        return try await preparedBookImport(
            validating: sourceURL,
            stagedLibraryFile: StagedLibraryFile(
                fileURL: sourceURL,
                destinationURL: destinationURL,
                shouldCleanupOnFailure: false
            ),
            filename: filename,
            bookID: bookID,
            fingerprint: fingerprint
        )
    }

    nonisolated private static func regenerateCoverImage(from sourceURL: URL, bookID: UUID) async throws -> String? {
        let archive = try await EPUBArchive(url: sourceURL)
        try await archive.validateEPUB()
        let package = try await EPUBMetadataService.packageInfo(in: archive)
        return try await cacheCoverImage(from: archive, package: package, bookID: bookID)
    }

    /// Regenerates a book's cover on a detached task, forwarding cooperative
    /// cancellation (`Task.detached` does not inherit it). Both the refresh and
    /// the restore-missing-covers paths need the same off-actor extraction with
    /// cancellation, so they share this one wrapper.
    nonisolated private static func regenerateCoverImageCancellable(from sourceURL: URL, bookID: UUID) async throws -> String? {
        let coverTask = Task.detached(priority: .utility) {
            try await regenerateCoverImage(from: sourceURL, bookID: bookID)
        }
        return try await withTaskCancellationHandler {
            try await coverTask.value
        } onCancel: {
            coverTask.cancel()
        }
    }

    nonisolated private static func cacheCoverImage(
        from archive: EPUBArchive,
        package: EPUBPackageInfo?,
        bookID: UUID
    ) async throws -> String? {
        try BookAssetCacheService.removeCachedCover(for: bookID)
        guard let package,
              let coverAsset = try await EPUBMetadataService.coverImageAsset(in: archive, package: package)
        else {
            return nil
        }

        return try BookAssetCacheService.cacheCoverImage(asset: coverAsset, for: bookID)
    }

    nonisolated private static func reportProgress(
        _ progress: OperationProgress,
        using progressHandler: (@MainActor @Sendable (OperationProgress) -> Void)?
    ) async {
        await progressHandler?(progress)
    }

    /// Books whose EPUB was found to contain no cover during this session.
    /// `restoreMissingCovers` runs on every scene activation; without this it
    /// re-opened and re-parsed every cover-less EPUB each time the app came to
    /// the foreground. Cleared for a book when new content is imported.
    @MainActor
    private static var booksKnownWithoutCover: Set<UUID> = []

    @MainActor
    static func restoreMissingCovers(store: AppStateStore) async {
        let books = store.books
        for book in books {
            if Task.isCancelled {
                break
            }

            guard !booksKnownWithoutCover.contains(book.id),
                  !BookAssetCacheService.hasCachedCover(for: book),
                  let sourceURL = try? book.resolvedEPUBFileURL(),
                  FileManager.default.fileExists(atPath: sourceURL.path)
            else {
                continue
            }

            let cachedCoverPath: String?
            do {
                cachedCoverPath = try await regenerateCoverImageCancellable(from: sourceURL, bookID: book.id)
            } catch {
                DebugLog.shared.log("BookImportService: cover regeneration failed for \(book.originalFilename): \(error)")
                cachedCoverPath = nil
            }

            guard let cachedCoverPath else {
                // A successful parse that yielded no cover: the EPUB simply
                // has none. Remember that instead of re-parsing next time.
                booksKnownWithoutCover.insert(book.id)
                continue
            }

            if book.coverImagePath != cachedCoverPath {
                book.coverImagePath = cachedCoverPath
            }
        }
        // Cover mutations above already schedule a debounced save via the book
        // subscription; no forced write is needed here.
    }

    @MainActor
    private static func refreshSourceEPUBURLs(
        existingBooks: [Book],
        fileManager: FileManager,
        libraryDirectoryExisted: Bool,
        progressHandler: (@MainActor @Sendable (OperationProgress) -> Void)?
    ) async throws -> [URL] {
        do {
            let scannedURLs = try scannedLibraryEPUBURLs(fileManager: fileManager)

            // A non-empty scan is authoritative, and so is an empty one when
            // the directory was really there — that is an ordinary "user
            // deleted their books" refresh.
            if !scannedURLs.isEmpty || existingBooks.isEmpty || libraryDirectoryExisted {
                return scannedURLs
            }

            // The directory was missing and we still hold book records. The
            // library was not deleted through the app; something removed or
            // made the directory unavailable (a Files-app move, a restore, a
            // data-protection eviction). Pruning here is unrecoverable, so
            // refuse instead.
            throw BookImportError.libraryFilesUnavailable
        } catch let error as BookImportError {
            throw error
        } catch {
            guard !existingBooks.isEmpty else {
                throw error
            }
        }

        let fallbackEPUBURLs = existingLibraryEPUBURLs(for: existingBooks, fileManager: fileManager)
        guard !fallbackEPUBURLs.isEmpty else {
            throw BookImportError.libraryFilesUnavailable
        }

        await reportProgress(
            OperationProgress(fractionCompleted: 0.05, message: "Rebuilding library from saved book paths..."),
            using: progressHandler
        )
        return fallbackEPUBURLs
    }

    nonisolated private static func shouldSkipPreparedBook(
        for libraryFileURL: URL,
        existingBook: ExistingBookSnapshot,
        fingerprint: SourceFileFingerprint
    ) -> Bool {
        let fileManager = FileManager.default
        let fileSizeMatches = fingerprint.fileSize == existingBook.sourceFileSize
        let modifiedAtMatches = modificationDatesMatch(
            fingerprint.modifiedAt,
            existingBook.sourceFileModifiedAt
        )
        let storedFilename = URL(fileURLWithPath: existingBook.epubFilePath).lastPathComponent
        let libraryFilename = libraryFileURL.lastPathComponent
        let filenameMatches = storedFilename == libraryFilename
        let epubExists = (try? AppStorage.bookFileURL(storedPath: existingBook.epubFilePath))
            .map { fileManager.fileExists(atPath: $0.path) } ?? false
        guard fileSizeMatches,
              modifiedAtMatches,
              filenameMatches,
              epubExists
        else {
            return false
        }

        return true
    }

    nonisolated private static func modificationDatesMatch(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }

        return abs(lhs.timeIntervalSince(rhs)) <= 3
    }

    nonisolated private static func sourceFileFingerprint(for url: URL) throws -> SourceFileFingerprint {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = resourceValues.fileSize.map(Int64.init)
        return SourceFileFingerprint(
            fileSize: fileSize,
            modifiedAt: resourceValues.contentModificationDate
        )
    }

    nonisolated private static func scannedLibraryEPUBURLs(fileManager: FileManager) throws -> [URL] {
        let libraryDirectory = try AppStorage.booksDirectory()
        return try fileManager.contentsOfDirectory(
            at: libraryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .filter { UploadFileKind.isEPUB($0.lastPathComponent) }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    @MainActor
    private static func existingLibraryEPUBURLs(for books: [Book], fileManager: FileManager) -> [URL] {
        books.compactMap { book in
            guard let epubURL = try? book.resolvedEPUBFileURL(),
                  fileManager.fileExists(atPath: epubURL.path)
            else {
                return nil
            }

            return epubURL
        }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    @MainActor
    private static func snapshot(for book: Book) -> ExistingBookSnapshot {
        ExistingBookSnapshot(
            id: book.id,
            originalFilename: book.originalFilename,
            epubFilePath: book.epubFilePath,
            sourceFileSize: book.sourceFileSize,
            sourceFileModifiedAt: book.sourceFileModifiedAt
        )
    }

    nonisolated private static func shouldMoveUploadedSourceIntoLibrary(_ sourceURL: URL) -> Bool {
        guard let uploadsDirectory = try? AppStorage.uploadsDirectory() else {
            return false
        }

        let sourcePath = sourceURL.standardizedFileURL.path
        let uploadsPath = uploadsDirectory.standardizedFileURL.path
        return sourcePath == uploadsPath || sourcePath.hasPrefix(uploadsPath + "/")
    }

    static func displayTitle(for filename: String) -> String {
        URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
    }

    /// Removes files created during import preparation if the import fails.
    ///
    /// This prevents orphaned files from accumulating when imports fail after
    /// files have been copied but before the book is added to the app state.
    ///
    /// - Parameter preparedImport: The prepared import containing file paths to clean up
    private static func cleanupPreparedImport(_ preparedImport: PreparedBookImport) {
        let fileManager = FileManager.default

        if preparedImport.stagedLibraryFile.shouldCleanupOnFailure {
            try? fileManager.removeItem(at: preparedImport.stagedLibraryFile.fileURL)
        }

        // Only the staged (not-yet-committed) cover is ours to remove. The
        // canonical cover, overlay artifacts, and audio cache belong to the
        // existing book on an overwrite and must survive a failed import.
        if let stagedCoverFilename = preparedImport.stagedCoverFilename {
            BookAssetCacheService.removeStagedCover(stagedFilename: stagedCoverFilename)
        }
    }

    /// A staging file younger than this is presumed to belong to an import
    /// that is still running, not one that crashed or was cancelled. A refresh
    /// can run concurrently with an in-progress import (refresh has no lock on
    /// the import pipeline), so sweeping unconditionally could delete the only
    /// copy of a file that was *moved* rather than copied into staging.
    static let stalePartialImportAge: TimeInterval = 5 * 60

    /// Deletes dot-prefixed `.import-*` staging files orphaned in the library by
    /// an import that was cancelled or crashed between staging and commit.
    nonisolated static func removeStalePartialImports() {
        guard let libraryDirectory = try? AppStorage.booksDirectory() else {
            return
        }
        AppStorage.sweepStagingFiles(
            in: libraryDirectory,
            prefix: stagedImportPrefix,
            olderThan: Date().addingTimeInterval(-stalePartialImportAge)
        )
    }
}

#if DEBUG
extension BookImportService {
    /// Whether `restoreMissingCovers` has recorded this book as having no cover.
    static func test_isKnownWithoutCover(_ bookID: UUID) -> Bool {
        booksKnownWithoutCover.contains(bookID)
    }
}
#endif
