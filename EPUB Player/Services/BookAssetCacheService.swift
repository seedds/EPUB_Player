//
//  BookAssetCacheService.swift
//  EPUB Player
//

import Foundation

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

    /// Writes a new cover under a temporary staging name WITHOUT touching any
    /// existing cover, returning the staged filename. Used during import prepare
    /// so a failed/cancelled overwrite does not destroy the book it replaces.
    /// Call `commitStagedCover` to promote it to the final name.
    nonisolated static func cacheStagedCoverImage(asset: EPUBArchiveAsset, for bookID: UUID) throws -> String {
        let ext = asset.pathExtension.isEmpty ? "img" : asset.pathExtension
        let stagedFilename = "\(bookID.uuidString).import-\(UUID().uuidString).\(ext)"
        let destinationURL = try AppStorage.coversDirectory()
            .appendingPathComponent(stagedFilename, isDirectory: false)
        try asset.data.write(to: destinationURL, options: .atomic)
        return stagedFilename
    }

    /// Promotes a staged cover to the canonical `<bookID>.<ext>` name, removing
    /// any prior cover only now (at commit). Returns the final filename.
    nonisolated static func commitStagedCover(stagedFilename: String, for bookID: UUID) throws -> String {
        let coversDirectory = try AppStorage.coversDirectory()
        let stagedURL = coversDirectory.appendingPathComponent(stagedFilename, isDirectory: false)
        let ext = URL(fileURLWithPath: stagedFilename).pathExtension
        let finalURL = try AppStorage.coverImageURL(for: bookID, pathExtension: ext)

        // Remove any prior cover for this book, but keep the staged file if it
        // happens to already be the final name.
        try removeCoverFiles(for: bookID, in: coversDirectory, keeping: stagedURL)

        if stagedURL.standardizedFileURL.path != finalURL.standardizedFileURL.path {
            _ = try? FileManager.default.replaceItemAt(finalURL, withItemAt: stagedURL)
            if FileManager.default.fileExists(atPath: stagedURL.path) {
                // replaceItemAt can leave the source when the destination did not
                // exist; fall back to a move.
                try? FileManager.default.moveItem(at: stagedURL, to: finalURL)
            }
        }
        return finalURL.lastPathComponent
    }

    /// Removes a staged cover file left behind by a failed import.
    nonisolated static func removeStagedCover(stagedFilename: String) {
        guard let url = try? AppStorage.coversDirectory().appendingPathComponent(stagedFilename, isDirectory: false) else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated static func removeCachedCover(for bookID: UUID) throws {
        try removeCoverFiles(for: bookID, in: AppStorage.coversDirectory())
    }

    /// Deletes every `<bookID>.<ext>` cover in `coversDirectory`, optionally
    /// sparing one file (used at commit time to keep the staged cover).
    private nonisolated static func removeCoverFiles(
        for bookID: UUID,
        in coversDirectory: URL,
        keeping keptURL: URL? = nil
    ) throws {
        let prefix = bookID.uuidString + "."
        let keptPath = keptURL?.standardizedFileURL.path
        for url in try FileManager.default.contentsOfDirectory(
            at: coversDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) where url.lastPathComponent.hasPrefix(prefix) && url.standardizedFileURL.path != keptPath {
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

    /// Whether the book's cached manifest is present and non-empty. The cheap
    /// gate for "is preparation done": it runs on the main actor at book open
    /// and on every enqueue, where fully decoding a multi-megabyte manifest
    /// stalled the UI. A manifest that exists but is corrupt surfaces at
    /// playback load (`ReaderView.readAloudStatusMessage`) and is repaired by
    /// the refresh gate (`overlayCacheIsValid`), so it need not be detected here.
    @MainActor
    static func hasOverlayManifest(for book: Book) -> Bool {
        guard let overlayURL = try? book.resolvedMediaOverlayJSONURL(),
              let size = (try? overlayURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        else {
            return false
        }
        return size > 0
    }

    /// Whether the book's cached manifest exists *and* decodes to at least one
    /// clip. The decode runs off the main actor: this is the refresh repair
    /// gate, evaluated once per existing book, and a long audiobook's manifest
    /// is megabytes of JSON.
    @MainActor
    static func overlayCacheIsValid(for book: Book) async -> Bool {
        guard let overlayURL = try? book.resolvedMediaOverlayJSONURL() else {
            return false
        }
        return await Task.detached(priority: .utility) {
            (try? MediaOverlayPlaybackController.resolvedClips(from: overlayURL))?.isEmpty == false
        }.value
    }

    @MainActor
    static func cachedOverlayClips(for book: Book) -> [EPUBMediaOverlayClip]? {
        guard let overlayURL = try? book.resolvedMediaOverlayJSONURL() else {
            return nil
        }
        return try? MediaOverlayPlaybackController.resolvedClips(from: overlayURL)
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
