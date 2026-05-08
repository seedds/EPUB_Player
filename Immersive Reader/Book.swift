//
//  Book.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation
import SwiftData

enum MediaOverlayPreparationState: String, CaseIterable {
    case pending
    case processing
    case ready
    case failed
}

struct NormalizedBookStoragePaths: Equatable {
    let epubFilePath: String
    let coverImagePath: String?
    let mediaOverlayJSONPath: String?
}

@Model
final class Book {
    var id: UUID
    var title: String
    var author: String
    var originalFilename: String
    var epubFilePath: String
    var coverImagePath: String?
    var language: String?
    var metadataIdentifier: String?
    var lastLocatorJSON: String?
    var lastPlayedTextResourceHref: String?
    var lastPlayedFragmentID: String?
    var lastPlayedClipBegin: Double?
    var lastPlayedClipEnd: Double?
    var mediaOverlayJSONPath: String?
    var mediaOverlayActiveClass: String?
    var mediaOverlayDuration: Double?
    var mediaOverlayClipCount: Int?
    var mediaOverlayPreparationStateRawValue: String?
    var mediaOverlayPreparationError: String?
    var sourceFileSize: Int64?
    var sourceFileModifiedAt: Date?
    var importedAt: Date
    var lastOpenedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        author: String = "Unknown Author",
        originalFilename: String,
        epubFilePath: String,
        coverImagePath: String? = nil,
        language: String? = nil,
        metadataIdentifier: String? = nil,
        lastLocatorJSON: String? = nil,
        lastPlayedTextResourceHref: String? = nil,
        lastPlayedFragmentID: String? = nil,
        lastPlayedClipBegin: Double? = nil,
        lastPlayedClipEnd: Double? = nil,
        mediaOverlayJSONPath: String? = nil,
        mediaOverlayActiveClass: String? = nil,
        mediaOverlayDuration: Double? = nil,
        mediaOverlayClipCount: Int? = nil,
        mediaOverlayPreparationStateRawValue: String? = MediaOverlayPreparationState.pending.rawValue,
        mediaOverlayPreparationError: String? = nil,
        sourceFileSize: Int64? = nil,
        sourceFileModifiedAt: Date? = nil,
        importedAt: Date = Date(),
        lastOpenedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.originalFilename = originalFilename
        self.epubFilePath = epubFilePath
        self.coverImagePath = coverImagePath
        self.language = language
        self.metadataIdentifier = metadataIdentifier
        self.lastLocatorJSON = lastLocatorJSON
        self.lastPlayedTextResourceHref = lastPlayedTextResourceHref
        self.lastPlayedFragmentID = lastPlayedFragmentID
        self.lastPlayedClipBegin = lastPlayedClipBegin
        self.lastPlayedClipEnd = lastPlayedClipEnd
        self.mediaOverlayJSONPath = mediaOverlayJSONPath
        self.mediaOverlayActiveClass = mediaOverlayActiveClass
        self.mediaOverlayDuration = mediaOverlayDuration
        self.mediaOverlayClipCount = mediaOverlayClipCount
        self.mediaOverlayPreparationStateRawValue = mediaOverlayPreparationStateRawValue
        self.mediaOverlayPreparationError = mediaOverlayPreparationError
        self.sourceFileSize = sourceFileSize
        self.sourceFileModifiedAt = sourceFileModifiedAt
        self.importedAt = importedAt
        self.lastOpenedAt = lastOpenedAt
    }
}

extension Book {
    var mediaOverlayPreparationState: MediaOverlayPreparationState {
        get {
            guard let mediaOverlayPreparationStateRawValue else {
                return .pending
            }
            return MediaOverlayPreparationState(rawValue: mediaOverlayPreparationStateRawValue) ?? .pending
        }
        set {
            mediaOverlayPreparationStateRawValue = newValue.rawValue
        }
    }

    nonisolated var normalizedStoragePaths: NormalizedBookStoragePaths {
        let normalizedEPUBPath = AppStorage.sanitizedFilename(
            originalFilename.isEmpty ? URL(fileURLWithPath: epubFilePath).lastPathComponent : originalFilename
        )

        return NormalizedBookStoragePaths(
            epubFilePath: normalizedEPUBPath,
            coverImagePath: normalizedCachedAssetPath(for: coverImagePath),
            mediaOverlayJSONPath: normalizedCachedAssetPath(for: mediaOverlayJSONPath)
        )
    }

    nonisolated func resolvedEPUBFileURL() throws -> URL {
        try AppStorage.bookFileURL(named: normalizedStoragePaths.epubFilePath)
    }

    nonisolated func resolvedCoverImageURL() throws -> URL? {
        guard let storedPath = normalizedStoragePaths.coverImagePath else {
            return nil
        }

        if storedPath.hasPrefix("/") {
            return URL(fileURLWithPath: storedPath)
        }

        return try AppStorage.coversDirectory().appendingPathComponent(storedPath, isDirectory: false)
    }

    nonisolated func resolvedMediaOverlayJSONURL() throws -> URL? {
        guard let storedPath = normalizedStoragePaths.mediaOverlayJSONPath else {
            return nil
        }

        if storedPath.hasPrefix("/") {
            return URL(fileURLWithPath: storedPath)
        }

        return try AppStorage.mediaOverlaysDirectory().appendingPathComponent(storedPath, isDirectory: false)
    }

    nonisolated private func normalizedCachedAssetPath(for path: String?) -> String? {
        guard let path, !path.isEmpty else {
            return nil
        }

        if path.hasPrefix("/") {
            if let coversDirectory = try? AppStorage.coversDirectory(),
               let relativePath = AppStorage.relativePath(from: path, under: coversDirectory.path) {
                return relativePath
            }
            if let overlaysDirectory = try? AppStorage.mediaOverlaysDirectory(),
               let relativePath = AppStorage.relativePath(from: path, under: overlaysDirectory.path) {
                return relativePath
            }
        }

        return path
    }
}
