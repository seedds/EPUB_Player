//
//  BookPositionValidator.swift
//  EPUB Player
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation

/// Validates a book's saved reading positions (resume point, bookmarks, and
/// history) against freshly (re)imported content.
///
/// Re-importing an updated file regenerates the EPUB extraction and media
/// overlay clips, so positions saved against the old content can dangle. This
/// helper keeps the positions that still resolve and prunes the ones that do
/// not, applied consistently to the resume point, bookmarks, and history.
///
/// Validation happens in two passes because the new data becomes available at
/// different times:
///   - Resource-href validation runs at import, when the new EPUB's manifest
///     hrefs are already parsed.
///   - Clip validation runs after media overlays finish preparing, when the new
///     clip set exists.
nonisolated enum BookPositionValidator {
    /// A book's saved positions, decoupled from `Book` so the validator stays
    /// pure and testable.
    struct Positions: Equatable {
        var lastLocatorJSON: String?
        var lastPlayedTextResourceHref: String?
        var lastPlayedFragmentID: String?
        var lastPlayedClipBegin: Double?
        var lastPlayedClipEnd: Double?
        var bookmarks: [Bookmark]
        var history: [HistoryEntry]
    }

    /// Prunes positions whose resource is no longer present in the new EPUB.
    ///
    /// Matching is by filename (last path component) because manifest hrefs are
    /// OPF-relative while stored hrefs are publication-root-relative; the
    /// filename is the stable common denominator across both bases.
    ///
    /// A record is kept when it has no resource reference at all (nothing to
    /// invalidate) or when its referenced resource still exists.
    static func validatedAgainstResourceHrefs(
        _ positions: Positions,
        resourceHrefs: [String]
    ) -> Positions {
        let validFilenames = Set(resourceHrefs.compactMap(resourceFilename(from:)))

        func resourceExists(_ href: String?) -> Bool {
            guard let filename = href.flatMap(resourceFilename(from:)) else {
                // No resource reference to check; nothing to invalidate.
                return true
            }
            return validFilenames.contains(filename)
        }

        var result = positions

        if let locatorJSON = positions.lastLocatorJSON,
           !resourceExists(resourceHref(fromLocatorJSON: locatorJSON)) {
            result.lastLocatorJSON = nil
        }

        if !resourceExists(positions.lastPlayedTextResourceHref) {
            result.lastPlayedTextResourceHref = nil
            result.lastPlayedFragmentID = nil
            result.lastPlayedClipBegin = nil
            result.lastPlayedClipEnd = nil
        }

        result.bookmarks = positions.bookmarks.filter {
            resourceExists($0.textResourceHref ?? $0.resourceHref)
        }
        result.history = positions.history.filter {
            resourceExists($0.textResourceHref ?? $0.resourceHref)
        }

        return result
    }

    /// Prunes and refreshes clip-based positions against the new clip set.
    ///
    /// A clip-bearing record is kept when a new clip exists with the same
    /// resource and fragment; its `clipBegin`/`clipEnd` are refreshed from the
    /// matched clip so it points at valid audio times even if timings shifted.
    /// A clip-bearing record with no match is dropped (the resume point is
    /// nulled). Records without clip fields are left untouched here.
    static func validatedAgainstClips(
        _ positions: Positions,
        clips: [EPUBMediaOverlayClip]
    ) -> Positions {
        // Map (resourceFilename, fragmentID) -> matched clip times. When several
        // clips share a fragment, the first wins (matches selection fallback).
        var clipByKey: [ClipKey: (clipBegin: Double, clipEnd: Double?)] = [:]
        for clip in clips {
            guard let key = clipKey(resourceHref: clip.textResourceHref, fragmentID: clip.fragmentID) else {
                continue
            }
            if clipByKey[key] == nil {
                clipByKey[key] = (clip.clipBegin, clip.clipEnd)
            }
        }

        var result = positions

        if hasClipFields(
            textResourceHref: positions.lastPlayedTextResourceHref,
            clipBegin: positions.lastPlayedClipBegin
        ) {
            if let key = clipKey(
                resourceHref: positions.lastPlayedTextResourceHref,
                fragmentID: positions.lastPlayedFragmentID
            ), let match = clipByKey[key] {
                result.lastPlayedClipBegin = match.clipBegin
                result.lastPlayedClipEnd = match.clipEnd
            } else {
                result.lastPlayedTextResourceHref = nil
                result.lastPlayedFragmentID = nil
                result.lastPlayedClipBegin = nil
                result.lastPlayedClipEnd = nil
            }
        }

        result.bookmarks = positions.bookmarks.compactMap { revalidated($0, against: clipByKey) }
        result.history = positions.history.compactMap { revalidated($0, against: clipByKey) }

        return result
    }

    /// Drops every clip-based position. Used when the new file failed to prepare
    /// or yielded no clips, so no clip reference can be validated.
    static func droppingClipPositions(_ positions: Positions) -> Positions {
        var result = positions
        result.lastPlayedTextResourceHref = nil
        result.lastPlayedFragmentID = nil
        result.lastPlayedClipBegin = nil
        result.lastPlayedClipEnd = nil
        result.bookmarks = positions.bookmarks.filter { !hasClipFields($0) }
        result.history = positions.history.filter { !hasClipFields($0) }
        return result
    }

    // MARK: - Helpers

    /// Keeps a record without clip fields as-is, refreshes a matched record's
    /// clip times, and drops a clip-bearing record with no match.
    private static func revalidated<Record: SavedPositionRecord>(
        _ record: Record,
        against clipByKey: [ClipKey: (clipBegin: Double, clipEnd: Double?)]
    ) -> Record? {
        guard hasClipFields(record) else {
            return record
        }
        guard let key = clipKey(resourceHref: record.textResourceHref, fragmentID: record.fragmentID),
              let match = clipByKey[key]
        else {
            return nil
        }
        var updated = record
        updated.clipBegin = match.clipBegin
        updated.clipEnd = match.clipEnd
        return updated
    }

    private struct ClipKey: Hashable {
        let resourceFilename: String
        let fragmentID: String
    }

    private static func clipKey(resourceHref: String?, fragmentID: String?) -> ClipKey? {
        guard let resourceHref,
              let filename = resourceFilename(from: resourceHref),
              let fragmentID, !fragmentID.isEmpty
        else {
            return nil
        }
        return ClipKey(resourceFilename: filename, fragmentID: fragmentID)
    }

    private static func hasClipFields(textResourceHref: String?, clipBegin: Double?) -> Bool {
        textResourceHref != nil && clipBegin != nil
    }

    private static func hasClipFields(_ record: some SavedPositionRecord) -> Bool {
        hasClipFields(textResourceHref: record.textResourceHref, clipBegin: record.clipBegin)
    }

    // Book bridging lives in an extension so the memberwise initializer stays
    // synthesized.

    /// Extracts the resource href from a Readium locator JSON string. Returns
    /// `nil` when the JSON can't be parsed, in which case the caller treats the
    /// resume point as unverifiable-but-kept (no resource to invalidate).
    private static func resourceHref(fromLocatorJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let href = object["href"] as? String
        else {
            return nil
        }
        return href
    }

    /// Reduces an href to its decoded, fragment-stripped filename for matching
    /// across differing href bases.
    private static func resourceFilename(from href: String) -> String? {
        let withoutFragment = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        let decoded = withoutFragment.removingPercentEncoding ?? withoutFragment
        let filename = decoded
            .split(separator: "/")
            .last
            .map(String.init) ?? decoded
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension BookPositionValidator.Positions {
    /// Snapshots the positions currently held by `book`.
    @MainActor
    init(_ book: Book) {
        self.init(
            lastLocatorJSON: book.lastLocatorJSON,
            lastPlayedTextResourceHref: book.lastPlayedTextResourceHref,
            lastPlayedFragmentID: book.lastPlayedFragmentID,
            lastPlayedClipBegin: book.lastPlayedClipBegin,
            lastPlayedClipEnd: book.lastPlayedClipEnd,
            bookmarks: book.bookmarks,
            history: book.history
        )
    }

    /// Writes these positions back onto `book`.
    @MainActor
    func apply(to book: Book) {
        book.lastLocatorJSON = lastLocatorJSON
        book.lastPlayedTextResourceHref = lastPlayedTextResourceHref
        book.lastPlayedFragmentID = lastPlayedFragmentID
        book.lastPlayedClipBegin = lastPlayedClipBegin
        book.lastPlayedClipEnd = lastPlayedClipEnd
        book.bookmarks = bookmarks
        book.history = history
    }
}
