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

    var errorDescription: String? {
        switch self {
        case .notEpub(let filename):
            "Only EPUB files are supported. \(filename) is not an EPUB."
        case .libraryFilesUnavailable:
            "Could not verify the imported EPUB files. Your library was left unchanged."
        }
    }
}

enum BookImportService {
    struct BookOperationProgress: Sendable {
        let fractionCompleted: Double
        let message: String
    }

    typealias ImportProgress = BookOperationProgress
    typealias RefreshProgress = BookOperationProgress

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
        let mediaOverlayJSONPath: String?
        let mediaOverlayActiveClass: String?
        let mediaOverlayDuration: Double?
        let mediaOverlayClipCount: Int?
        let mediaOverlayPreparationState: MediaOverlayPreparationState
        let mediaOverlayPreparationError: String?
        let fingerprint: SourceFileFingerprint
        /// Content-document hrefs from the new EPUB manifest, used to validate
        /// saved positions on reimport.
        let resourceHrefs: [String]
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

    @MainActor
    @discardableResult
    static func importBook(
        from sourceURL: URL,
        filename requestedFilename: String,
        store: AppStateStore,
        existingBookStrategy: ExistingBookStrategy = .skip,
        progressHandler: (@MainActor @Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> Book? {
        let filename = AppStorage.sanitizedFilename(requestedFilename)
        guard filename.lowercased().hasSuffix(".epub") else {
            throw BookImportError.notEpub(filename)
        }

        try Task.checkCancellation()

        let existingBook = existingBook(originalFilename: filename, store: store)
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

        try Task.checkCancellation()

        await reportProgress(
            ImportProgress(fractionCompleted: 0.96, message: "Saving book..."),
            using: progressHandler
        )

        do {
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
                ImportProgress(fractionCompleted: 1, message: "Import complete"),
                using: progressHandler
            )
            return book
        } catch {
            try? cleanupPreparedImport(preparedImport, bookID: bookID)
            throw error
        }
    }

    @MainActor
    @discardableResult
    static func refreshBooksFromDocuments(
        store: AppStateStore,
        progressHandler: (@MainActor @Sendable (RefreshProgress) -> Void)? = nil
    ) async throws -> [Book] {
        await reportProgress(
            RefreshProgress(fractionCompleted: 0.02, message: "Scanning EPUB files..."),
            using: progressHandler
        )

        let existingBooks = store.books
        let fileManager = FileManager.default
        let epubURLs = try await refreshSourceEPUBURLs(
            existingBooks: existingBooks,
            fileManager: fileManager,
            progressHandler: progressHandler
        )

        let existingBooksByFilename = Dictionary(
            existingBooks.map { ($0.originalFilename, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        let removedBooks = existingBooks.filter { book in
            guard let epubURL = try? book.resolvedEPUBFileURL() else {
                return true
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
                RefreshProgress(
                    fractionCompleted: 0.08 + (Double(completedOperations) / Double(totalOperations)) * 0.84,
                    message: "Removing missing books \(completedOperations) of \(removedBooks.count)"
                ),
                using: progressHandler
            )
        }

        var refreshedBooks: [Book] = []
        var overlayRetryIDs: Set<UUID> = []
        var skippedFilenames: [String] = []
        for (index, sourceURL) in epubURLs.enumerated() {
            let filename = AppStorage.sanitizedFilename(sourceURL.lastPathComponent)
            // One unreadable file must not abort the refresh of every other book.
            do {
                guard filename.lowercased().hasSuffix(".epub") else {
                    throw BookImportError.notEpub(filename)
                }

                let fingerprint = try sourceFileFingerprint(for: sourceURL)
                let existingBook = existingBooksByFilename[filename]
                let book: Book

                if let existingBook,
                   shouldSkipPreparedBook(for: sourceURL, existingBook: snapshot(for: existingBook), fingerprint: fingerprint) {
                    let cachedCoverPath: String?
                    if !BookAssetCacheService.hasCachedCover(for: existingBook) {
                        let coverTask = Task.detached(priority: .utility) {
                            try await regenerateCoverImage(from: sourceURL, bookID: existingBook.id)
                        }
                        cachedCoverPath = try await coverTask.value
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

                    if !BookAssetCacheService.hasValidOverlayCache(for: existingBook) &&
                        (existingBook.mediaOverlayClipCount ?? 0) > 0 {
                        existingBook.mediaOverlayPreparationState = .pending
                        existingBook.mediaOverlayPreparationError = nil
                        existingBook.mediaOverlayJSONPath = nil
                        existingBook.mediaOverlayActiveClass = nil
                        existingBook.mediaOverlayDuration = nil
                        existingBook.mediaOverlayClipCount = nil
                    }

                    if existingBook.mediaOverlayPreparationState == .pending || existingBook.mediaOverlayPreparationState == .failed {
                        overlayRetryIDs.insert(existingBook.id)
                    }

                    book = existingBook
                } else {
                    let preparedImport = try await Task.detached(priority: .userInitiated) {
                        try await prepareRefreshImport(from: sourceURL, filename: filename, bookID: existingBook?.id ?? UUID())
                    }.value

                    book = upsertBook(from: preparedImport, existingBook: existingBook, store: store)

                    overlayRetryIDs.insert(book.id)
                }

                refreshedBooks.append(book)
            } catch {
                skippedFilenames.append(filename)
            }

            completedOperations += 1
            await reportProgress(
                RefreshProgress(
                    fractionCompleted: 0.08 + (Double(completedOperations) / Double(totalOperations)) * 0.84,
                    message: "Updating library \(index + 1) of \(epubURLs.count)"
                ),
                using: progressHandler
            )
        }

        await reportProgress(
            RefreshProgress(fractionCompleted: 0.97, message: "Saving library..."),
            using: progressHandler
        )
        store.sortBooksByImportedAt()
        store.persistNow()

        for bookID in overlayRetryIDs {
            MediaOverlayPreparationCoordinator.shared.enqueuePreparation(
                for: bookID,
                store: store,
                priority: .utility,
                allowFailedRetry: true
            )
        }

        let completionMessage = skippedFilenames.isEmpty
            ? "Refresh complete"
            : "Refresh complete — skipped \(skippedFilenames.count): \(skippedFilenames.joined(separator: ", "))"
        await reportProgress(
            RefreshProgress(fractionCompleted: 1, message: completionMessage),
            using: progressHandler
        )
        return refreshedBooks
    }

    @MainActor
    private static func existingBook(originalFilename: String, store: AppStateStore) -> Book? {
        store.firstBook(originalFilename: originalFilename)
    }

    @MainActor
    private static func bookForID(_ id: UUID, store: AppStateStore) -> Book? {
        store.book(withID: id)
    }

    @MainActor
    private static func applyPreparedImport(
        _ preparedImport: PreparedBookImport,
        existingBookID: UUID?,
        store: AppStateStore
    ) throws -> Book {
        try finalizeStagedLibraryFile(preparedImport.stagedLibraryFile)

        let book = upsertBook(
            from: preparedImport,
            existingBook: existingBookID.flatMap { bookForID($0, store: store) },
            store: store
        )

        store.sortBooksByImportedAt()
        store.persistNow()
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
            existingBook.coverImagePath = preparedImport.metadata.coverImagePath
            existingBook.language = preparedImport.metadata.language
            existingBook.metadataIdentifier = preparedImport.metadata.identifier
            existingBook.mediaOverlayJSONPath = preparedImport.mediaOverlayJSONPath
            existingBook.mediaOverlayActiveClass = preparedImport.mediaOverlayActiveClass
            existingBook.mediaOverlayDuration = preparedImport.mediaOverlayDuration
            existingBook.mediaOverlayClipCount = preparedImport.mediaOverlayClipCount
            existingBook.mediaOverlayPreparationState = preparedImport.mediaOverlayPreparationState
            existingBook.mediaOverlayPreparationError = preparedImport.mediaOverlayPreparationError
            existingBook.sourceFileSize = preparedImport.fingerprint.fileSize
            existingBook.sourceFileModifiedAt = preparedImport.fingerprint.modifiedAt
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
            coverImagePath: preparedImport.metadata.coverImagePath,
            language: preparedImport.metadata.language,
            metadataIdentifier: preparedImport.metadata.identifier,
            mediaOverlayJSONPath: preparedImport.mediaOverlayJSONPath,
            mediaOverlayActiveClass: preparedImport.mediaOverlayActiveClass,
            mediaOverlayDuration: preparedImport.mediaOverlayDuration,
            mediaOverlayClipCount: preparedImport.mediaOverlayClipCount,
            mediaOverlayPreparationStateRawValue: preparedImport.mediaOverlayPreparationState.rawValue,
            mediaOverlayPreparationError: preparedImport.mediaOverlayPreparationError,
            sourceFileSize: preparedImport.fingerprint.fileSize,
            sourceFileModifiedAt: preparedImport.fingerprint.modifiedAt
        )
        store.addBook(newBook)
        return newBook
    }

    @MainActor
    private static func applyResourceHrefValidatedPositions(to book: Book, resourceHrefs: [String]) {
        let positions = BookPositionValidator.Positions(
            lastLocatorJSON: book.lastLocatorJSON,
            lastPlayedTextResourceHref: book.lastPlayedTextResourceHref,
            lastPlayedFragmentID: book.lastPlayedFragmentID,
            lastPlayedClipBegin: book.lastPlayedClipBegin,
            lastPlayedClipEnd: book.lastPlayedClipEnd,
            bookmarks: book.bookmarks,
            history: book.history
        )
        let validated = BookPositionValidator.validatedAgainstResourceHrefs(positions, resourceHrefs: resourceHrefs)
        applyPositions(validated, to: book)
    }

    @MainActor
    private static func applyPositions(_ positions: BookPositionValidator.Positions, to book: Book) {
        book.lastLocatorJSON = positions.lastLocatorJSON
        book.lastPlayedTextResourceHref = positions.lastPlayedTextResourceHref
        book.lastPlayedFragmentID = positions.lastPlayedFragmentID
        book.lastPlayedClipBegin = positions.lastPlayedClipBegin
        book.lastPlayedClipEnd = positions.lastPlayedClipEnd
        book.bookmarks = positions.bookmarks
        book.history = positions.history
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
        progressHandler: (@MainActor @Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> PreparedBookImport? {
        let stagedLibraryFile = try await stageSourceFileInLibrary(
            from: sourceURL,
            filename: filename,
            progressHandler: progressHandler
        )

        let stagedURL = stagedLibraryFile.fileURL
        let fingerprint = try sourceFileFingerprint(for: stagedURL)
        if case .skip = existingBookStrategy,
           let existingBook,
           shouldSkipPreparedBook(for: stagedLibraryFile.destinationURL, existingBook: existingBook, fingerprint: fingerprint) {
            await reportProgress(
                ImportProgress(fractionCompleted: 1, message: "Book already exists, skipping"),
                using: progressHandler
            )
            if stagedLibraryFile.shouldCleanupOnFailure {
                try? FileManager.default.removeItem(at: stagedURL)
            }
            return nil
        }

        do {
            let preparedImport = try await preparedBookImport(
                validating: stagedURL,
                stagedLibraryFile: stagedLibraryFile,
                filename: filename,
                bookID: bookID,
                fingerprint: fingerprint,
                progressHandler: progressHandler
            )
            await reportProgress(
                ImportProgress(fractionCompleted: 0.92, message: "Finalizing book..."),
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
        progressHandler: (@MainActor @Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> PreparedBookImport {
        await reportProgress(
            ImportProgress(fractionCompleted: 0.24, message: "Validating EPUB..."),
            using: progressHandler
        )
        let archive = try await EPUBArchive(url: fileURL)
        try await archive.validateEPUB()

        await reportProgress(
            ImportProgress(fractionCompleted: 0.6, message: "Reading metadata..."),
            using: progressHandler
        )
        let package = try await EPUBMetadataService.packageInfo(in: archive)
        var metadata = package.map(EPUBMetadataService.metadata(from:)) ?? EPUBMetadata()

        await reportProgress(
            ImportProgress(fractionCompleted: 0.8, message: "Caching cover..."),
            using: progressHandler
        )
        metadata.coverImagePath = try await cacheCoverImage(from: archive, package: package, bookID: bookID)

        try? BookAssetCacheService.removeOverlayArtifacts(for: bookID)

        return PreparedBookImport(
            stagedLibraryFile: stagedLibraryFile,
            id: bookID,
            filename: filename,
            epubFilePath: AppStorage.storedBookPath(for: filename),
            metadata: metadata,
            mediaOverlayJSONPath: nil,
            mediaOverlayActiveClass: nil,
            mediaOverlayDuration: nil,
            mediaOverlayClipCount: nil,
            mediaOverlayPreparationState: .pending,
            mediaOverlayPreparationError: nil,
            fingerprint: fingerprint,
            resourceHrefs: contentResourceHrefs(from: package)
        )
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
        progressHandler: (@MainActor @Sendable (ImportProgress) -> Void)? = nil
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
            ".import-\(UUID().uuidString)-\(filename)",
            isDirectory: false
        )
        let sourcePath = sourceURL.standardizedFileURL.path
        let destinationPath = destinationURL.standardizedFileURL.path

        await reportProgress(
            ImportProgress(fractionCompleted: 0.08, message: "Staging EPUB..."),
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
        return try await preparedBookImport(
            validating: sourceURL,
            stagedLibraryFile: StagedLibraryFile(
                fileURL: sourceURL,
                destinationURL: sourceURL,
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
        _ progress: BookOperationProgress,
        using progressHandler: (@MainActor @Sendable (BookOperationProgress) -> Void)?
    ) async {
        guard let progressHandler else {
            return
        }

        await progressHandler(
            BookOperationProgress(
                fractionCompleted: min(max(progress.fractionCompleted, 0), 1),
                message: progress.message
            )
        )
    }

    @MainActor
    static func restoreMissingCovers(store: AppStateStore) async {
        let books = store.books
        var didUpdateLibrary = false
        for book in books {
            guard !BookAssetCacheService.hasCachedCover(for: book),
                  let sourceURL = try? book.resolvedEPUBFileURL(),
                  FileManager.default.fileExists(atPath: sourceURL.path)
            else {
                continue
            }

            let cachedCoverPath: String?
            do {
                cachedCoverPath = try await Task.detached(priority: .utility) {
                    try await regenerateCoverImage(from: sourceURL, bookID: book.id)
                }.value
            } catch {
                print("BookImportService: cover regeneration failed for \(book.originalFilename): \(error)")
                cachedCoverPath = nil
            }

            guard let cachedCoverPath else {
                continue
            }

            if book.coverImagePath != cachedCoverPath {
                book.coverImagePath = cachedCoverPath
                didUpdateLibrary = true
            }
        }

        if didUpdateLibrary {
            store.persistNow()
        }
    }

    @MainActor
    private static func refreshSourceEPUBURLs(
        existingBooks: [Book],
        fileManager: FileManager,
        progressHandler: (@MainActor @Sendable (RefreshProgress) -> Void)?
    ) async throws -> [URL] {
        do {
            // A successful scan is authoritative, even when empty: an empty
            // result lets the refresh remove stale records for files that are
            // genuinely gone instead of leaving ghost books behind.
            return try scannedLibraryEPUBURLs(fileManager: fileManager)
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
            RefreshProgress(fractionCompleted: 0.05, message: "Rebuilding library from saved book paths..."),
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
        .filter { $0.pathExtension.lowercased() == "epub" }
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
        let normalizedPaths = book.normalizedStoragePaths
        return ExistingBookSnapshot(
            id: book.id,
            originalFilename: book.originalFilename,
            epubFilePath: normalizedPaths.epubFilePath,
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
    /// - Parameters:
    ///   - preparedImport: The prepared import containing file paths to clean up
    ///   - bookID: The book ID used for cache directories
    private static func cleanupPreparedImport(_ preparedImport: PreparedBookImport, bookID: UUID) throws {
        let fileManager = FileManager.default

        if preparedImport.stagedLibraryFile.shouldCleanupOnFailure {
            try? fileManager.removeItem(at: preparedImport.stagedLibraryFile.fileURL)
        }

        if let coverPath = preparedImport.metadata.coverImagePath,
           let coverURL = try? AppStorage.coversDirectory().appendingPathComponent(coverPath) {
            try? fileManager.removeItem(at: coverURL)
        }

        if let overlayPath = preparedImport.mediaOverlayJSONPath,
           let overlayURL = try? AppStorage.mediaOverlaysDirectory().appendingPathComponent(overlayPath) {
            try? fileManager.removeItem(at: overlayURL)
        }

        if let audioCacheDir = try? AppStorage.audioCacheDirectory(for: bookID) {
            try? fileManager.removeItem(at: audioCacheDir)
        }
    }
}

enum BookAssetCacheError: LocalizedError {
    case missingArchiveEntry(String)

    var errorDescription: String? {
        switch self {
        case .missingArchiveEntry(let path):
            return "Missing EPUB resource: \(path)"
        }
    }
}

enum BookAssetCacheService {
    nonisolated static func cacheCoverImage(asset: EPUBArchiveAsset, for bookID: UUID) throws -> String {
        try removeCachedCover(for: bookID)
        let destinationURL = try AppStorage.coverImageURL(for: bookID, pathExtension: asset.pathExtension)
        try asset.data.write(to: destinationURL, options: .atomic)
        return destinationURL.lastPathComponent
    }

    nonisolated static func removeCachedCover(for bookID: UUID) throws {
        let coversDirectory = try AppStorage.coversDirectory()
        let prefix = bookID.uuidString + "."
        for url in try FileManager.default.contentsOfDirectory(at: coversDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated static func removeOverlayArtifacts(for bookID: UUID) throws {
        let overlayURL = try AppStorage.mediaOverlayManifestURL(for: bookID)
        try? FileManager.default.removeItem(at: overlayURL)

        let audioDirectory = try AppStorage.audioCacheDirectory(for: bookID)
        try? FileManager.default.removeItem(at: audioDirectory)
    }

    nonisolated static func removeAllCachedAssets(for bookID: UUID) throws {
        try removeCachedCover(for: bookID)
        try removeOverlayArtifacts(for: bookID)
    }

    @MainActor
    static func hasCachedCover(for book: Book) -> Bool {
        guard let coverURL = try? book.resolvedCoverImageURL() else {
            return false
        }
        return FileManager.default.fileExists(atPath: coverURL.path)
    }

    @MainActor
    static func hasValidOverlayCache(for book: Book) -> Bool {
        guard let overlayURL = try? book.resolvedMediaOverlayJSONURL() else {
            return false
        }
        // Existence alone is insufficient: a corrupt or stale manifest is treated
        // as ready and silently fails at playback load. Decode it (via the same
        // path the playback controller uses) so re-preparation gates can detect
        // an unusable cache and regenerate it.
        guard let clips = try? MediaOverlayPlaybackController.resolvedClips(from: overlayURL) else {
            return false
        }
        return !clips.isEmpty
    }

    nonisolated static func materializeAudioAsset(
        resourcePath: String,
        bookID: UUID,
        epubURL: URL
    ) async throws -> URL {
        let destinationURL = try AppStorage.audioCacheFileURL(for: bookID, resourcePath: resourcePath)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }

        let archive = try await EPUBArchive(url: epubURL)
        guard let data = try await archive.data(for: resourcePath) else {
            throw BookAssetCacheError.missingArchiveEntry(resourcePath)
        }

        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }
}

@MainActor
final class MediaOverlayPreparationCoordinator {
    struct PreparationProgress: Sendable {
        let fractionCompleted: Double
        let message: String
    }

    static let shared = MediaOverlayPreparationCoordinator()

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var progressSnapshots: [UUID: PreparationProgress] = [:]
    private var progressObservers: [UUID: [UUID: (@MainActor @Sendable (PreparationProgress) -> Void)]] = [:]

    private init() {}

    func resumePendingBooks(store: AppStateStore) {
        let books = store.books

        var didUpdateState = false
        for book in books {
            if book.mediaOverlayPreparationState == .processing {
                book.mediaOverlayPreparationState = .pending
                book.mediaOverlayPreparationError = nil
                didUpdateState = true
            }

            if book.mediaOverlayPreparationState == .pending {
                enqueuePreparation(for: book.id, store: store, priority: .utility)
            }
        }

        if didUpdateState {
            store.persistNow()
        }
    }

    func enqueuePreparation(
        for bookID: UUID,
        store: AppStateStore,
        priority: TaskPriority,
        allowFailedRetry: Bool = false
    ) {
        guard tasks[bookID] == nil,
              let book = fetchBook(id: bookID, store: store)
        else {
            return
        }

        if book.mediaOverlayPreparationState == .failed, !allowFailedRetry {
            return
        }
        if book.mediaOverlayPreparationState == .ready,
           BookAssetCacheService.hasValidOverlayCache(for: book) {
            return
        }

        book.mediaOverlayPreparationState = .processing
        book.mediaOverlayPreparationError = nil
        publishProgress(
            PreparationProgress(fractionCompleted: 0, message: "Preparing read-aloud..."),
            for: bookID
        )
        store.persistNow()

        tasks[bookID] = Task { @MainActor [weak self] in
            defer { self?.tasks.removeValue(forKey: bookID) }

            guard let sourceURL = try? book.resolvedEPUBFileURL() else {
                book.mediaOverlayPreparationState = .failed
                book.mediaOverlayPreparationError = "The EPUB file could not be found."
                store.persistNow()
                return
            }

            do {
                let progressHandler: @Sendable (EPUBMediaOverlayProgress) -> Void = { [weak self] progress in
                    DispatchQueue.main.async {
                        self?.publishProgress(Self.preparationProgress(from: progress), for: bookID)
                    }
                }
                // Detached tasks don't inherit cancellation; forward it so a
                // deleted book's parse stops instead of re-writing its cache.
                let parseTask = Task.detached(priority: priority) {
                    try await EPUBMediaOverlayService.parseAndWrite(
                        at: sourceURL,
                        bookID: bookID,
                        progressHandler: progressHandler
                    )
                }
                let result = try await withTaskCancellationHandler {
                    try await parseTask.value
                } onCancel: {
                    parseTask.cancel()
                }

                guard let updatedBook = self?.fetchBook(id: bookID, store: store) else {
                    return
                }

                updatedBook.mediaOverlayJSONPath = result?.jsonURL.lastPathComponent
                updatedBook.mediaOverlayActiveClass = result?.manifest.activeClass
                updatedBook.mediaOverlayDuration = result?.manifest.duration
                updatedBook.mediaOverlayClipCount = result?.manifest.clipCount
                updatedBook.mediaOverlayPreparationState = .ready
                updatedBook.mediaOverlayPreparationError = nil
                if updatedBook.pendingClipPositionRevalidation {
                    let clips = result?.manifest.documents.flatMap(\.clips) ?? []
                    Self.revalidateClipPositions(for: updatedBook, against: clips)
                    updatedBook.pendingClipPositionRevalidation = false
                }
                self?.publishProgress(
                    PreparationProgress(fractionCompleted: 1, message: "Read-aloud ready"),
                    for: bookID
                )
                store.persistNow()
            } catch {
                guard let updatedBook = self?.fetchBook(id: bookID, store: store) else {
                    return
                }

                updatedBook.mediaOverlayJSONPath = nil
                updatedBook.mediaOverlayActiveClass = nil
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
                    PreparationProgress(fractionCompleted: 1, message: "Read-aloud unavailable"),
                    for: bookID
                )
                store.persistNow()
            }
        }
    }

    /// Validates a book's clip-based positions against the freshly prepared clip
    /// set, refreshing or pruning each. An empty clip list drops them all (used
    /// when preparation failed or produced no clips).
    @MainActor
    private static func revalidateClipPositions(for book: Book, against clips: [EPUBMediaOverlayClip]) {
        let positions = BookPositionValidator.Positions(
            lastLocatorJSON: book.lastLocatorJSON,
            lastPlayedTextResourceHref: book.lastPlayedTextResourceHref,
            lastPlayedFragmentID: book.lastPlayedFragmentID,
            lastPlayedClipBegin: book.lastPlayedClipBegin,
            lastPlayedClipEnd: book.lastPlayedClipEnd,
            bookmarks: book.bookmarks,
            history: book.history
        )
        let validated = clips.isEmpty
            ? BookPositionValidator.droppingClipPositions(positions)
            : BookPositionValidator.validatedAgainstClips(positions, clips: clips)

        book.lastLocatorJSON = validated.lastLocatorJSON
        book.lastPlayedTextResourceHref = validated.lastPlayedTextResourceHref
        book.lastPlayedFragmentID = validated.lastPlayedFragmentID
        book.lastPlayedClipBegin = validated.lastPlayedClipBegin
        book.lastPlayedClipEnd = validated.lastPlayedClipEnd
        book.bookmarks = validated.bookmarks
        book.history = validated.history
    }

    func cancelPreparation(for bookID: UUID) {
        tasks[bookID]?.cancel()
        tasks.removeValue(forKey: bookID)
    }

    func ensurePreparedForPlayback(
        bookID: UUID,
        store: AppStateStore,
        progressHandler: (@MainActor @Sendable (PreparationProgress) -> Void)? = nil
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

        guard let book = fetchBook(id: bookID, store: store) else {
            return
        }

        switch book.mediaOverlayPreparationState {
        case .failed:
            return
        case .ready:
            if BookAssetCacheService.hasValidOverlayCache(for: book) {
                return
            }
            book.mediaOverlayPreparationState = .pending
            book.mediaOverlayPreparationError = nil
            store.persistNow()
            fallthrough
        case .pending, .processing:
            enqueuePreparation(for: bookID, store: store, priority: .userInitiated)
            if let task = tasks[bookID] {
                await task.value
            }
        }
    }

    private func fetchBook(id: UUID, store: AppStateStore) -> Book? {
        store.book(withID: id)
    }

    private func addProgressObserver(
        for bookID: UUID,
        using progressHandler: @escaping @MainActor @Sendable (PreparationProgress) -> Void
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

    private func publishProgress(_ progress: PreparationProgress, for bookID: UUID) {
        progressSnapshots[bookID] = PreparationProgress(
            fractionCompleted: min(max(progress.fractionCompleted, 0), 1),
            message: progress.message
        )

        guard let progress = progressSnapshots[bookID] else {
            return
        }

        progressObservers[bookID]?.values.forEach { observer in
            observer(progress)
        }
    }

    private static func preparationProgress(from progress: EPUBMediaOverlayProgress) -> PreparationProgress {
        PreparationProgress(
            fractionCompleted: progress.fractionCompleted,
            message: progress.message
        )
    }
}
