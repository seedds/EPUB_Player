//
//  Book.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Combine
import Foundation

enum MediaOverlayPreparationState: String, CaseIterable, Codable {
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

final class Book: ObservableObject, Identifiable, Codable, Hashable {
    let id: UUID
    @Published var title: String
    @Published var author: String
    @Published var originalFilename: String
    @Published var epubFilePath: String
    @Published var coverImagePath: String?
    @Published var language: String?
    @Published var metadataIdentifier: String?
    @Published var lastLocatorJSON: String?
    @Published var lastPlayedTextResourceHref: String?
    @Published var lastPlayedFragmentID: String?
    @Published var lastPlayedClipBegin: Double?
    @Published var lastPlayedClipEnd: Double?
    @Published var mediaOverlayJSONPath: String?
    @Published var mediaOverlayActiveClass: String?
    @Published var mediaOverlayDuration: Double?
    @Published var mediaOverlayClipCount: Int?
    @Published var mediaOverlayPreparationStateRawValue: String?
    @Published var mediaOverlayPreparationError: String?
    @Published var sourceFileSize: Int64?
    @Published var sourceFileModifiedAt: Date?
    @Published var importedAt: Date
    @Published var lastOpenedAt: Date?

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

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case author
        case originalFilename
        case epubFilePath
        case coverImagePath
        case language
        case metadataIdentifier
        case lastLocatorJSON
        case lastPlayedTextResourceHref
        case lastPlayedFragmentID
        case lastPlayedClipBegin
        case lastPlayedClipEnd
        case mediaOverlayJSONPath
        case mediaOverlayActiveClass
        case mediaOverlayDuration
        case mediaOverlayClipCount
        case mediaOverlayPreparationStateRawValue
        case mediaOverlayPreparationError
        case sourceFileSize
        case sourceFileModifiedAt
        case importedAt
        case lastOpenedAt
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        author = try container.decode(String.self, forKey: .author)
        originalFilename = try container.decode(String.self, forKey: .originalFilename)
        epubFilePath = try container.decode(String.self, forKey: .epubFilePath)
        coverImagePath = try container.decodeIfPresent(String.self, forKey: .coverImagePath)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        metadataIdentifier = try container.decodeIfPresent(String.self, forKey: .metadataIdentifier)
        lastLocatorJSON = try container.decodeIfPresent(String.self, forKey: .lastLocatorJSON)
        lastPlayedTextResourceHref = try container.decodeIfPresent(String.self, forKey: .lastPlayedTextResourceHref)
        lastPlayedFragmentID = try container.decodeIfPresent(String.self, forKey: .lastPlayedFragmentID)
        lastPlayedClipBegin = try container.decodeIfPresent(Double.self, forKey: .lastPlayedClipBegin)
        lastPlayedClipEnd = try container.decodeIfPresent(Double.self, forKey: .lastPlayedClipEnd)
        mediaOverlayJSONPath = try container.decodeIfPresent(String.self, forKey: .mediaOverlayJSONPath)
        mediaOverlayActiveClass = try container.decodeIfPresent(String.self, forKey: .mediaOverlayActiveClass)
        mediaOverlayDuration = try container.decodeIfPresent(Double.self, forKey: .mediaOverlayDuration)
        mediaOverlayClipCount = try container.decodeIfPresent(Int.self, forKey: .mediaOverlayClipCount)
        mediaOverlayPreparationStateRawValue = try container.decodeIfPresent(String.self, forKey: .mediaOverlayPreparationStateRawValue)
        mediaOverlayPreparationError = try container.decodeIfPresent(String.self, forKey: .mediaOverlayPreparationError)
        sourceFileSize = try container.decodeIfPresent(Int64.self, forKey: .sourceFileSize)
        sourceFileModifiedAt = try container.decodeIfPresent(Date.self, forKey: .sourceFileModifiedAt)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        lastOpenedAt = try container.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(author, forKey: .author)
        try container.encode(originalFilename, forKey: .originalFilename)
        try container.encode(epubFilePath, forKey: .epubFilePath)
        try container.encodeIfPresent(coverImagePath, forKey: .coverImagePath)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(metadataIdentifier, forKey: .metadataIdentifier)
        try container.encodeIfPresent(lastLocatorJSON, forKey: .lastLocatorJSON)
        try container.encodeIfPresent(lastPlayedTextResourceHref, forKey: .lastPlayedTextResourceHref)
        try container.encodeIfPresent(lastPlayedFragmentID, forKey: .lastPlayedFragmentID)
        try container.encodeIfPresent(lastPlayedClipBegin, forKey: .lastPlayedClipBegin)
        try container.encodeIfPresent(lastPlayedClipEnd, forKey: .lastPlayedClipEnd)
        try container.encodeIfPresent(mediaOverlayJSONPath, forKey: .mediaOverlayJSONPath)
        try container.encodeIfPresent(mediaOverlayActiveClass, forKey: .mediaOverlayActiveClass)
        try container.encodeIfPresent(mediaOverlayDuration, forKey: .mediaOverlayDuration)
        try container.encodeIfPresent(mediaOverlayClipCount, forKey: .mediaOverlayClipCount)
        try container.encodeIfPresent(mediaOverlayPreparationStateRawValue, forKey: .mediaOverlayPreparationStateRawValue)
        try container.encodeIfPresent(mediaOverlayPreparationError, forKey: .mediaOverlayPreparationError)
        try container.encodeIfPresent(sourceFileSize, forKey: .sourceFileSize)
        try container.encodeIfPresent(sourceFileModifiedAt, forKey: .sourceFileModifiedAt)
        try container.encode(importedAt, forKey: .importedAt)
        try container.encodeIfPresent(lastOpenedAt, forKey: .lastOpenedAt)
    }

    static func == (lhs: Book, rhs: Book) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
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

    var normalizedStoragePaths: NormalizedBookStoragePaths {
        NormalizedBookStoragePaths(
            epubFilePath: epubFilePath,
            coverImagePath: coverImagePath,
            mediaOverlayJSONPath: mediaOverlayJSONPath
        )
    }

    func resolvedEPUBFileURL() throws -> URL {
        try AppStorage.bookFileURL(storedPath: normalizedStoragePaths.epubFilePath)
    }

    func resolvedCoverImageURL() throws -> URL? {
        guard let storedPath = normalizedStoragePaths.coverImagePath else {
            return nil
        }
        return try AppStorage.coversDirectory().appendingPathComponent(storedPath, isDirectory: false)
    }

    func resolvedMediaOverlayJSONURL() throws -> URL? {
        guard let storedPath = normalizedStoragePaths.mediaOverlayJSONPath else {
            return nil
        }
        return try AppStorage.mediaOverlaysDirectory().appendingPathComponent(storedPath, isDirectory: false)
    }
}
