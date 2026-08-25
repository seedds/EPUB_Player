//
//  Book.swift
//  EPUB Player
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

/// A saved place in a book, shared by `Bookmark` (saved deliberately) and
/// `HistoryEntry` (recorded automatically). The two records carry the same
/// position and display fields, so anything that resolves, prunes, or renders a
/// saved place works against this protocol rather than either concrete type.
nonisolated protocol SavedPositionRecord: Identifiable, Codable, Hashable {
    var id: UUID { get }
    var chapterTitle: String? { get }
    var locatorJSON: String? { get }
    var resourceHref: String? { get }
    var chapterProgress: Double? { get }
    var clipText: String? { get }
    var textResourceHref: String? { get }
    var fragmentID: String? { get }
    var clipBegin: Double? { get set }
    var clipEnd: Double? { get set }
    var clipNumberInChapter: Int? { get }
    var clipCountInChapter: Int? { get }
    var createdAt: Date { get }
}

extension SavedPositionRecord {
    /// The record's own text if it has any. Callers supply the fallback label,
    /// which differs per record kind.
    var displayPrimaryText: String? {
        if let clipText, !clipText.isEmpty {
            return clipText
        }
        if let chapterTitle, !chapterTitle.isEmpty {
            return chapterTitle
        }
        return nil
    }

    /// The subtitle line: `leadingParts`, then chapter (only when the primary
    /// line already showed clip text), clip position, progress, and timestamp.
    func displaySecondaryText(leadingParts: [String] = []) -> String {
        var parts = leadingParts.filter { !$0.isEmpty }

        if clipText?.isEmpty == false,
           let chapterTitle,
           !chapterTitle.isEmpty {
            parts.append(chapterTitle)
        }

        if let clipNumberInChapter, let clipCountInChapter {
            parts.append("Clip \(clipNumberInChapter)/\(clipCountInChapter)")
        }

        if let chapterProgress {
            parts.append("\(Int((chapterProgress * 100).rounded()))%")
        }

        parts.append(createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}

// Both records rely on the synthesized memberwise initializer. `id` and
// `createdAt` are declared `var` with a default so callers can omit them; the
// remaining optionals default to `nil`. Codable, Hashable, and Identifiable are
// all synthesized through `SavedPositionRecord`.
nonisolated struct Bookmark: SavedPositionRecord {
    var id: UUID = UUID()
    var chapterTitle: String?
    var locatorJSON: String?
    var resourceHref: String?
    var chapterProgress: Double?
    var totalProgress: Double?
    var clipText: String?
    var textResourceHref: String?
    var fragmentID: String?
    var clipBegin: Double?
    var clipEnd: Double?
    var clipNumberInChapter: Int?
    var clipCountInChapter: Int?
    var createdAt: Date = Date()
}

nonisolated struct HistoryEntry: SavedPositionRecord {
    var id: UUID = UUID()
    var reason: String?
    var chapterTitle: String?
    var locatorJSON: String?
    var resourceHref: String?
    var chapterProgress: Double?
    var totalProgress: Double?
    var clipText: String?
    var textResourceHref: String?
    var fragmentID: String?
    var clipBegin: Double?
    var clipEnd: Double?
    var clipNumberInChapter: Int?
    var clipCountInChapter: Int?
    var createdAt: Date = Date()
}

nonisolated final class Book: ObservableObject, Identifiable, Codable, Hashable {
    static let defaultHistoryEntryLimit = 30

    let id: UUID
    @Published var title: String
    @Published var author: String
    @Published var originalFilename: String
    @Published var epubFilePath: String
    @Published var coverImagePath: String?
    @Published var language: String?
    @Published var metadataIdentifier: String?
    @Published var lastLocatorJSON: String?
    @Published var bookmarks: [Bookmark]
    @Published var history: [HistoryEntry]
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
    /// Set when the file was re-imported and clip-based positions are awaiting
    /// validation against the freshly prepared media overlay clips.
    @Published var pendingClipPositionRevalidation: Bool

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
        bookmarks: [Bookmark] = [],
        history: [HistoryEntry] = [],
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
        lastOpenedAt: Date? = nil,
        pendingClipPositionRevalidation: Bool = false
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
        self.bookmarks = bookmarks
        self.history = history
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
        self.pendingClipPositionRevalidation = pendingClipPositionRevalidation
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
        case bookmarks
        case history
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
        case pendingClipPositionRevalidation
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
        bookmarks = try container.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        history = try container.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
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
        pendingClipPositionRevalidation = try container.decodeIfPresent(Bool.self, forKey: .pendingClipPositionRevalidation) ?? false
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
        try container.encode(bookmarks, forKey: .bookmarks)
        try container.encode(history, forKey: .history)
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
        try container.encode(pendingClipPositionRevalidation, forKey: .pendingClipPositionRevalidation)
    }

    static func == (lhs: Book, rhs: Book) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func updateLastLocation(_ locatorJSON: String?, openedAt: Date = Date()) {
        self.lastLocatorJSON = locatorJSON
        self.lastOpenedAt = openedAt
    }

    func updateLastPlayedClip(
        textResourceHref: String,
        fragmentID: String?,
        clipBegin: Double,
        clipEnd: Double?
    ) {
        lastPlayedTextResourceHref = textResourceHref
        lastPlayedFragmentID = fragmentID
        lastPlayedClipBegin = clipBegin
        lastPlayedClipEnd = clipEnd
    }

    func clearLastPlayedClip() {
        lastPlayedTextResourceHref = nil
        lastPlayedFragmentID = nil
        lastPlayedClipBegin = nil
        lastPlayedClipEnd = nil
    }

    func addBookmark(_ bookmark: Bookmark) {
        bookmarks.append(bookmark)
    }

    func removeBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
    }

    func removeBookmarks(ids: Set<UUID>) {
        bookmarks.removeAll { ids.contains($0.id) }
    }

    func removeHistoryEntries(ids: Set<UUID>) {
        history.removeAll { ids.contains($0.id) }
    }

    func recordHistory(
        _ entry: HistoryEntry,
        limit: Int = Book.defaultHistoryEntryLimit,
        isSamePosition: (HistoryEntry, HistoryEntry) -> Bool,
        dropPriorMatchingSameReason: Bool = false
    ) {
        if let newest = history.first, isSamePosition(newest, entry) {
            history.removeFirst()
        }

        // Collapse repeated breadcrumbs for the same origin: when requested,
        // drop any earlier entry sharing this entry's reason and position so
        // only the most recent one remains (the newest-match above only covers
        // index 0, which interleaved entries can defeat).
        if dropPriorMatchingSameReason, let reason = entry.reason {
            history.removeAll { $0.reason == reason && isSamePosition($0, entry) }
        }

        history.insert(entry, at: 0)
        if history.count > limit {
            history.removeLast(history.count - limit)
        }
    }

    func renameStoredFile(
        to filename: String,
        storedPath: String,
        displayTitle: (String) -> String
    ) {
        let previousDisplayTitle = displayTitle(originalFilename)
        originalFilename = filename
        if title == previousDisplayTitle {
            title = displayTitle(filename)
        }
        epubFilePath = storedPath
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
        return try AppStorage.containedFileURL(base: AppStorage.coversDirectory(), storedPath: storedPath)
    }

    func resolvedMediaOverlayJSONURL() throws -> URL? {
        guard let storedPath = normalizedStoragePaths.mediaOverlayJSONPath else {
            return nil
        }
        return try AppStorage.containedFileURL(base: AppStorage.mediaOverlaysDirectory(), storedPath: storedPath)
    }
}
