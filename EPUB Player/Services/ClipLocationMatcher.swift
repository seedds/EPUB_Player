//
//  ClipLocationMatcher.swift
//  EPUB Player
//

import Foundation

nonisolated enum ClipLocationMatcher {
    typealias ResourceNormalizer = (String) -> String

    static func savedPositionIndex(
        textResourceHref: String?,
        fragmentID: String?,
        clipBegin: Double?,
        clipEnd: Double?,
        clips: [EPUBMediaOverlayClip],
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
            normalize: normalize,
            where: { $0.clipBegin == clipBegin && $0.clipEnd == clipEnd }
        ) {
            return exactMatch
        }

        return index(ofFragment: fragmentID, inResource: resourceHref, clips: clips, normalize: normalize)
    }

    static func exactIndex(
        resourceHref: String,
        fragmentID: String?,
        clips: [EPUBMediaOverlayClip],
        normalize: ResourceNormalizer
    ) -> Int? {
        guard let fragmentID, !fragmentID.isEmpty else {
            return nil
        }

        return index(ofFragment: fragmentID, inResource: resourceHref, clips: clips, normalize: normalize)
    }

    static func firstIndex(
        resourceHref: String,
        fragmentID: String?,
        clips: [EPUBMediaOverlayClip],
        normalize: ResourceNormalizer
    ) -> Int? {
        guard fragmentID != nil else {
            return firstIndex(resourceHref: resourceHref, clips: clips, normalize: normalize)
        }

        // Clip hrefs are fragment-stripped at creation, so a fragment reference
        // must match on the clip's own fragmentID before falling back to the file.
        if let fragmentMatch = index(ofFragment: fragmentID, inResource: resourceHref, clips: clips, normalize: normalize) {
            return fragmentMatch
        }

        return firstIndex(resourceHref: resourceHref, clips: clips, normalize: normalize)
    }

    static func firstIndex(
        resourceHref: String,
        clips: [EPUBMediaOverlayClip],
        normalize: ResourceNormalizer
    ) -> Int? {
        index(inResource: resourceHref, clips: clips, normalize: normalize)
    }

    static func firstIndexAfterResource(
        _ resourceHref: String,
        readingOrderResourceHrefs: [String],
        clips: [EPUBMediaOverlayClip],
        normalize: ResourceNormalizer
    ) -> Int? {
        guard let currentResourceOrder = readingOrderResourceHrefs.firstIndex(of: resourceHref) else {
            return nil
        }

        for (index, clip) in clips.enumerated() {
            let clipResourceHref = normalize(clip.textResourceHref)
            guard let clipResourceOrder = readingOrderResourceHrefs.firstIndex(of: clipResourceHref),
                  clipResourceOrder > currentResourceOrder
            else {
                continue
            }

            return index
        }

        return nil
    }

    // MARK: - Helpers

    /// First clip in `resourceHref` (already normalized) also satisfying
    /// `predicate`. The href comparison is the one shape every lookup shares.
    private static func index(
        inResource resourceHref: String,
        clips: [EPUBMediaOverlayClip],
        normalize: ResourceNormalizer,
        where predicate: (EPUBMediaOverlayClip) -> Bool = { _ in true }
    ) -> Int? {
        clips.firstIndex { clip in
            normalize(clip.textResourceHref) == resourceHref && predicate(clip)
        }
    }

    /// First clip in `resourceHref` whose `fragmentID` matches, also satisfying
    /// `predicate`. A `nil` `fragmentID` matches clips that have none.
    private static func index(
        ofFragment fragmentID: String?,
        inResource resourceHref: String,
        clips: [EPUBMediaOverlayClip],
        normalize: ResourceNormalizer,
        where predicate: (EPUBMediaOverlayClip) -> Bool = { _ in true }
    ) -> Int? {
        index(inResource: resourceHref, clips: clips, normalize: normalize) { clip in
            clip.fragmentID == fragmentID && predicate(clip)
        }
    }
}
