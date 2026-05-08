//
//  BookImportService.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation
import SwiftData

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
    struct ImportProgress: Sendable {
        let fractionCompleted: Double
        let message: String
    }

    struct RefreshProgress: Sendable {
        let fractionCompleted: Double
        let message: String
    }

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
    }

    private struct StagedLibraryFile: Sendable {
        let fileURL: URL
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
        modelContext: ModelContext,
        existingBookStrategy: ExistingBookStrategy = .skip,
        progressHandler: (@MainActor @Sendable (ImportProgress) -> Void)? = nil
    ) async throws -> Book? {
        let filename = AppStorage.sanitizedFilename(sourceURL.lastPathComponent)
        guard filename.lowercased().hasSuffix(".epub") else {
            throw BookImportError.notEpub(filename)
        }

        let existingBook = try existingBook(originalFilename: filename, modelContext: modelContext)
        let existingBookSnapshot = existingBook.map(snapshot(for:))

        let bookID = existingBook?.id ?? UUID()
        let preparedImport = try await Task.detached(priority: .userInitiated) {
            try await prepareImport(
                from: sourceURL,
                filename: filename,
                existingBook: existingBookSnapshot,
                existingBookStrategy: existingBookStrategy,
                bookID: bookID,
                progressHandler: progressHandler
            )
        }.value

        guard let preparedImport else {
            return nil
        }

        await reportImportProgress(
            ImportProgress(fractionCompleted: 0.96, message: "Saving book..."),
            using: progressHandler
        )

        let book = try applyPreparedImport(
            preparedImport,
            existingBookID: existingBook?.id,
            modelContext: modelContext
        )
        MediaOverlayPreparationCoordinator.shared.enqueuePreparation(
            for: book.id,
            modelContext: modelContext,
            priority: .utility
        )

        await reportImportProgress(
            ImportProgress(fractionCompleted: 1, message: "Import complete"),
            using: progressHandler
        )
        return book
    }

    @MainActor
    @discardableResult
    static func refreshBooksFromDocuments(
        modelContext: ModelContext,
        progressHandler: (@MainActor @Sendable (RefreshProgress) -> Void)? = nil
    ) async throws -> [Book] {
        await reportRefreshProgress(
            RefreshProgress(fractionCompleted: 0.02, message: "Scanning EPUB files..."),
            using: progressHandler
        )

        let existingBooks = try modelContext.fetch(FetchDescriptor<Book>())
        let fileManager = FileManager.default
        let epubURLs = try await refreshSourceEPUBURLs(
            existingBooks: existingBooks,
            fileManager: fileManager,
            progressHandler: progressHandler
        )

        let existingBooksByFilename = Dictionary(uniqueKeysWithValues: existingBooks.map { ($0.originalFilename, $0) })
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
            modelContext.delete(book)

            completedOperations += 1
            await reportRefreshProgress(
                RefreshProgress(
                    fractionCompleted: 0.08 + (Double(completedOperations) / Double(totalOperations)) * 0.84,
                    message: "Removing missing books \(completedOperations) of \(removedBooks.count)"
                ),
                using: progressHandler
            )
        }

        var refreshedBooks: [Book] = []
        var overlayRetryIDs: Set<UUID> = []
        for (index, sourceURL) in epubURLs.enumerated() {
            let filename = AppStorage.sanitizedFilename(sourceURL.lastPathComponent)
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
                        try regenerateCoverImage(from: sourceURL, bookID: existingBook.id)
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
                    book = existingBook
                } else {
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
                    modelContext.insert(newBook)
                    book = newBook
                }

                overlayRetryIDs.insert(book.id)
            }

            refreshedBooks.append(book)

            completedOperations += 1
            await reportRefreshProgress(
                RefreshProgress(
                    fractionCompleted: 0.08 + (Double(completedOperations) / Double(totalOperations)) * 0.84,
                    message: "Updating library \(index + 1) of \(epubURLs.count)"
                ),
                using: progressHandler
            )
        }

        await reportRefreshProgress(
            RefreshProgress(fractionCompleted: 0.97, message: "Saving library..."),
            using: progressHandler
        )
        try modelContext.save()

        for bookID in overlayRetryIDs {
            MediaOverlayPreparationCoordinator.shared.enqueuePreparation(
                for: bookID,
                modelContext: modelContext,
                priority: .utility,
                allowFailedRetry: true
            )
        }

        await reportRefreshProgress(
            RefreshProgress(fractionCompleted: 1, message: "Refresh complete"),
            using: progressHandler
        )
        return refreshedBooks
    }

    @MainActor
    private static func existingBook(originalFilename: String, modelContext: ModelContext) throws -> Book? {
        var descriptor = FetchDescriptor<Book>(
            predicate: #Predicate { book in
                book.originalFilename == originalFilename
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    @MainActor
    private static func bookForID(_ id: UUID, modelContext: ModelContext) throws -> Book? {
        var descriptor = FetchDescriptor<Book>(
            predicate: #Predicate { book in
                book.id == id
            }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    @MainActor
    private static func applyPreparedImport(
        _ preparedImport: PreparedBookImport,
        existingBookID: UUID?,
        modelContext: ModelContext
    ) throws -> Book {
        let book: Book
        if let existingBookID,
           let existingBook = try bookForID(existingBookID, modelContext: modelContext) {
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
            book = existingBook
        } else {
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
            modelContext.insert(newBook)
            book = newBook
        }

        try modelContext.save()
        return book
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

        let destinationURL = stagedLibraryFile.fileURL
        let fingerprint = try sourceFileFingerprint(for: destinationURL)
        if case .skip = existingBookStrategy,
           let existingBook,
           shouldSkipPreparedBook(for: destinationURL, existingBook: existingBook, fingerprint: fingerprint) {
            await reportImportProgress(
                ImportProgress(fractionCompleted: 1, message: "Book already exists, skipping"),
                using: progressHandler
            )
            return nil
        }

        let fileManager = FileManager.default

        do {
            await reportImportProgress(
                ImportProgress(fractionCompleted: 0.24, message: "Validating EPUB..."),
                using: progressHandler
            )
            let archive = try EPUBArchive(url: destinationURL)
            try archive.validateEPUB()

            await reportImportProgress(
                ImportProgress(fractionCompleted: 0.6, message: "Reading metadata..."),
                using: progressHandler
            )
            let package = try EPUBMetadataService.packageInfo(in: archive)
            var metadata = package.map(EPUBMetadataService.metadata(from:)) ?? EPUBMetadata()

            await reportImportProgress(
                ImportProgress(fractionCompleted: 0.8, message: "Caching cover..."),
                using: progressHandler
            )
            metadata.coverImagePath = try cacheCoverImage(from: archive, package: package, bookID: bookID)

            try? BookAssetCacheService.removeOverlayArtifacts(for: bookID)

            await reportImportProgress(
                ImportProgress(fractionCompleted: 0.92, message: "Finalizing book..."),
                using: progressHandler
            )
            return PreparedBookImport(
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
                fingerprint: fingerprint
            )
        } catch {
            if stagedLibraryFile.shouldCleanupOnFailure {
                try? fileManager.removeItem(at: destinationURL)
            }
            throw error
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
        let libraryDirectory = try AppStorage.documentsDirectory()
        let destinationURL = libraryDirectory.appendingPathComponent(filename, isDirectory: false)
        let sourcePath = sourceURL.standardizedFileURL.path
        let destinationPath = destinationURL.standardizedFileURL.path

        await reportImportProgress(
            ImportProgress(fractionCompleted: 0.08, message: "Staging EPUB..."),
            using: progressHandler
        )

        let shouldMoveUploadedSource = shouldMoveUploadedSourceIntoLibrary(sourceURL)

        guard sourcePath != destinationPath else {
            return StagedLibraryFile(fileURL: destinationURL, shouldCleanupOnFailure: false)
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        if shouldMoveUploadedSource {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } else {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }

        return StagedLibraryFile(fileURL: destinationURL, shouldCleanupOnFailure: true)
    }

    nonisolated private static func prepareRefreshImport(
        from sourceURL: URL,
        filename: String,
        bookID: UUID
    ) async throws -> PreparedBookImport {
        let archive = try EPUBArchive(url: sourceURL)
        try archive.validateEPUB()

        let package = try EPUBMetadataService.packageInfo(in: archive)
        var metadata = package.map(EPUBMetadataService.metadata(from:)) ?? EPUBMetadata()
        metadata.coverImagePath = try cacheCoverImage(from: archive, package: package, bookID: bookID)

        try? BookAssetCacheService.removeOverlayArtifacts(for: bookID)

        let fingerprint = try sourceFileFingerprint(for: sourceURL)
        return PreparedBookImport(
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
            fingerprint: fingerprint
        )
    }

    nonisolated private static func regenerateCoverImage(from sourceURL: URL, bookID: UUID) throws -> String? {
        let archive = try EPUBArchive(url: sourceURL)
        try archive.validateEPUB()
        let package = try EPUBMetadataService.packageInfo(in: archive)
        return try cacheCoverImage(from: archive, package: package, bookID: bookID)
    }

    nonisolated private static func cacheCoverImage(
        from archive: EPUBArchive,
        package: EPUBPackageInfo?,
        bookID: UUID
    ) throws -> String? {
        try BookAssetCacheService.removeCachedCover(for: bookID)
        guard let package,
              let coverAsset = try EPUBMetadataService.coverImageAsset(in: archive, package: package)
        else {
            return nil
        }

        return try BookAssetCacheService.cacheCoverImage(asset: coverAsset, for: bookID)
    }

    nonisolated private static func reportRefreshProgress(
        _ progress: RefreshProgress,
        using progressHandler: (@MainActor @Sendable (RefreshProgress) -> Void)?
    ) async {
        guard let progressHandler else {
            return
        }

        await progressHandler(
            RefreshProgress(
                fractionCompleted: min(max(progress.fractionCompleted, 0), 1),
                message: progress.message
            )
        )
    }

    @MainActor
    static func restoreMissingCovers(modelContext: ModelContext) async {
        let descriptor = FetchDescriptor<Book>()
        guard let books = try? modelContext.fetch(descriptor) else {
            return
        }

        var didUpdateLibrary = false
        for book in books {
            guard !BookAssetCacheService.hasCachedCover(for: book),
                  let sourceURL = try? book.resolvedEPUBFileURL(),
                  FileManager.default.fileExists(atPath: sourceURL.path)
            else {
                continue
            }

            let cachedCoverPath = try? await Task.detached(priority: .utility) {
                try regenerateCoverImage(from: sourceURL, bookID: book.id)
            }.value

            guard let cachedCoverPath else {
                continue
            }

            if book.coverImagePath != cachedCoverPath {
                book.coverImagePath = cachedCoverPath
                didUpdateLibrary = true
            }
        }

        if didUpdateLibrary {
            try? modelContext.save()
        }
    }

    @MainActor
    private static func refreshSourceEPUBURLs(
        existingBooks: [Book],
        fileManager: FileManager,
        progressHandler: (@MainActor @Sendable (RefreshProgress) -> Void)?
    ) async throws -> [URL] {
        do {
            let scannedEPUBURLs = try scannedLibraryEPUBURLs(fileManager: fileManager)
            if !scannedEPUBURLs.isEmpty || existingBooks.isEmpty {
                return scannedEPUBURLs
            }
        } catch {
            guard !existingBooks.isEmpty else {
                throw error
            }
        }

        let fallbackEPUBURLs = existingLibraryEPUBURLs(for: existingBooks, fileManager: fileManager)
        guard !fallbackEPUBURLs.isEmpty else {
            throw BookImportError.libraryFilesUnavailable
        }

        await reportRefreshProgress(
            RefreshProgress(fractionCompleted: 0.05, message: "Rebuilding library from saved book paths..."),
            using: progressHandler
        )
        return fallbackEPUBURLs
    }

    nonisolated private static func reportImportProgress(
        _ progress: ImportProgress,
        using progressHandler: (@MainActor @Sendable (ImportProgress) -> Void)?
    ) async {
        guard let progressHandler else {
            return
        }

        await progressHandler(
            ImportProgress(
                fractionCompleted: min(max(progress.fractionCompleted, 0), 1),
                message: progress.message
            )
        )
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
        let libraryDirectory = try AppStorage.documentsDirectory()
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

    private static func displayTitle(for filename: String) -> String {
        URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
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

    nonisolated static func hasCachedCover(for book: Book) -> Bool {
        guard let coverURL = try? book.resolvedCoverImageURL() else {
            return false
        }
        return FileManager.default.fileExists(atPath: coverURL.path)
    }

    nonisolated static func hasValidOverlayCache(for book: Book) -> Bool {
        guard let overlayURL = try? book.resolvedMediaOverlayJSONURL() else {
            return false
        }
        return FileManager.default.fileExists(atPath: overlayURL.path)
    }

    nonisolated static func materializeAudioAsset(
        resourcePath: String,
        bookID: UUID,
        epubURL: URL
    ) throws -> URL {
        let destinationURL = try AppStorage.audioCacheFileURL(for: bookID, resourcePath: resourcePath)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }

        let archive = try EPUBArchive(url: epubURL)
        guard let data = try archive.data(for: resourcePath) else {
            throw BookAssetCacheError.missingArchiveEntry(resourcePath)
        }

        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }
}

@MainActor
final class MediaOverlayPreparationCoordinator {
    static let shared = MediaOverlayPreparationCoordinator()

    private var tasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    func resumePendingBooks(modelContext: ModelContext) {
        let descriptor = FetchDescriptor<Book>()
        guard let books = try? modelContext.fetch(descriptor) else {
            return
        }

        var didUpdateState = false
        for book in books {
            if book.mediaOverlayPreparationState == .processing {
                book.mediaOverlayPreparationState = .pending
                book.mediaOverlayPreparationError = nil
                didUpdateState = true
            }

            if book.mediaOverlayPreparationState == .pending {
                enqueuePreparation(for: book.id, modelContext: modelContext, priority: .utility)
            }
        }

        if didUpdateState {
            try? modelContext.save()
        }
    }

    func enqueuePreparation(
        for bookID: UUID,
        modelContext: ModelContext,
        priority: TaskPriority,
        allowFailedRetry: Bool = false
    ) {
        guard tasks[bookID] == nil,
              let book = fetchBook(id: bookID, modelContext: modelContext)
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
        try? modelContext.save()

        tasks[bookID] = Task { @MainActor [weak self] in
            defer { self?.tasks.removeValue(forKey: bookID) }

            guard let sourceURL = try? book.resolvedEPUBFileURL() else {
                book.mediaOverlayPreparationState = .failed
                book.mediaOverlayPreparationError = "The EPUB file could not be found."
                try? modelContext.save()
                return
            }

            do {
                let result = try await Task.detached(priority: priority) {
                    try EPUBMediaOverlayService.parseAndWrite(at: sourceURL, bookID: bookID)
                }.value

                guard let updatedBook = self?.fetchBook(id: bookID, modelContext: modelContext) else {
                    return
                }

                updatedBook.mediaOverlayJSONPath = result?.jsonURL.lastPathComponent
                updatedBook.mediaOverlayActiveClass = result?.manifest.activeClass
                updatedBook.mediaOverlayDuration = result?.manifest.duration
                updatedBook.mediaOverlayClipCount = result?.manifest.clipCount
                updatedBook.mediaOverlayPreparationState = .ready
                updatedBook.mediaOverlayPreparationError = nil
                try? modelContext.save()
            } catch {
                guard let updatedBook = self?.fetchBook(id: bookID, modelContext: modelContext) else {
                    return
                }

                updatedBook.mediaOverlayJSONPath = nil
                updatedBook.mediaOverlayActiveClass = nil
                updatedBook.mediaOverlayDuration = nil
                updatedBook.mediaOverlayClipCount = nil
                updatedBook.mediaOverlayPreparationState = .failed
                updatedBook.mediaOverlayPreparationError = error.localizedDescription
                try? modelContext.save()
            }
        }
    }

    func ensurePreparedForPlayback(bookID: UUID, modelContext: ModelContext) async {
        if let task = tasks[bookID] {
            await task.value
            return
        }

        guard let book = fetchBook(id: bookID, modelContext: modelContext) else {
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
            try? modelContext.save()
            fallthrough
        case .pending, .processing:
            enqueuePreparation(for: bookID, modelContext: modelContext, priority: .userInitiated)
            if let task = tasks[bookID] {
                await task.value
            }
        }
    }

    private func fetchBook(id: UUID, modelContext: ModelContext) -> Book? {
        var descriptor = FetchDescriptor<Book>(predicate: #Predicate { book in
            book.id == id
        })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}
