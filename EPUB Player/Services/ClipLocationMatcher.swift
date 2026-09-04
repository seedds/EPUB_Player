//
//  ClipLocationMatcher.swift
//  EPUB Player
//

import Foundation

nonisolated enum ClipLocationMatcher {
    typealias ResourceNormalizer = (String) -> String

    // Every lookup takes `clipResourceHrefs`: the clips' text resource hrefs,
    // already normalized once by the caller (parallel to `clips`). Normalizing
    // each clip href inside every scan was O(clips) string work per lookup on
    // the hot location-change path. The `normalize:` seam is kept only for the
    // caller-supplied query href, which is a single string.

    static func savedPositionIndex(
        textResourceHref: String?,
        fragmentID: String?,
        clipBegin: Double?,
        clipEnd: Double?,
        clips: [EPUBMediaOverlayClip],
        clipResourceHrefs: [String],
        normalize: ResourceNormalizer
    ) -> Int? {
        guard let textResourceHref else {
            return nil
        }

        let resourceHref = normalize(textResourceHref)
        if let exactMatch = index(
            ofFragment: fragmentID,
            inResource: resourceHref,
            clips: clips,
            clipResourceHrefs: clipResourceHrefs,
            where: { $0.clipBegin == clipBegin && $0.clipEnd == clipEnd }
        ) {
            return exactMatch
        }

        return index(ofFragment: fragmentID, inResource: resourceHref, clips: clips, clipResourceHrefs: clipResourceHrefs)
    }

    static func exactIndex(
        resourceHref: String,
        fragmentID: String?,
        clips: [EPUBMediaOverlayClip],
        clipResourceHrefs: [String]
    ) -> Int? {
        guard let fragmentID, !fragmentID.isEmpty else {
            return nil
        }

        return index(ofFragment: fragmentID, inResource: resourceHref, clips: clips, clipResourceHrefs: clipResourceHrefs)
    }

    static func firstIndex(
        resourceHref: String,
        fragmentID: String?,
        clips: [EPUBMediaOverlayClip],
        clipResourceHrefs: [String]
    ) -> Int? {
        guard fragmentID != nil else {
            return firstIndex(resourceHref: resourceHref, clipResourceHrefs: clipResourceHrefs)
        }

        // Clip hrefs are fragment-stripped at creation, so a fragment reference
        // must match on the clip's own fragmentID before falling back to the file.
        if let fragmentMatch = index(ofFragment: fragmentID, inResource: resourceHref, clips: clips, clipResourceHrefs: clipResourceHrefs) {
            return fragmentMatch
        }

        return firstIndex(resourceHref: resourceHref, clipResourceHrefs: clipResourceHrefs)
    }

    static func firstIndex(
        resourceHref: String,
        clipResourceHrefs: [String]
    ) -> Int? {
        clipResourceHrefs.firstIndex(of: resourceHref)
    }

    static func firstIndexAfterResource(
        _ resourceHref: String,
        readingOrderIndex: [String: Int],
        clipResourceHrefs: [String]
    ) -> Int? {
        guard let currentResourceOrder = readingOrderIndex[resourceHref] else {
            return nil
        }

        for (index, clipResourceHref) in clipResourceHrefs.enumerated() {
            guard let clipResourceOrder = readingOrderIndex[clipResourceHref],
                  clipResourceOrder > currentResourceOrder
            else {
                continue
            }

            return index
        }

        return nil
    }

    // MARK: - Helpers

    /// First clip whose (pre-normalized) resource matches `resourceHref` and
    /// that also satisfies `predicate`. The href comparison is the one shape
    /// every lookup shares.
    private static func index(
        inResource resourceHref: String,
        clips: [EPUBMediaOverlayClip],
        clipResourceHrefs: [String],
        where predicate: (EPUBMediaOverlayClip) -> Bool = { _ in true }
    ) -> Int? {
        clipResourceHrefs.indices.first { i in
            clipResourceHrefs[i] == resourceHref && predicate(clips[i])
        }
    }

    /// First clip in `resourceHref` whose `fragmentID` matches, also satisfying
    /// `predicate`. A `nil` `fragmentID` matches clips that have none.
    private static func index(
        ofFragment fragmentID: String?,
        inResource resourceHref: String,
        clips: [EPUBMediaOverlayClip],
        clipResourceHrefs: [String],
        where predicate: (EPUBMediaOverlayClip) -> Bool = { _ in true }
    ) -> Int? {
        index(inResource: resourceHref, clips: clips, clipResourceHrefs: clipResourceHrefs) { clip in
            clip.fragmentID == fragmentID && predicate(clip)
        }
    }
}
