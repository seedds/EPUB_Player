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
        if let exactMatch = clips.firstIndex(where: { clip in
            normalize(clip.textResourceHref) == resourceHref &&
                clip.fragmentID == fragmentID &&
                clip.clipBegin == clipBegin &&
                clip.clipEnd == clipEnd
        }) {
            return exactMatch
        }

        return clips.firstIndex(where: { clip in
            normalize(clip.textResourceHref) == resourceHref &&
                clip.fragmentID == fragmentID
        })
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

        return clips.firstIndex(where: { clip in
            normalize(clip.textResourceHref) == resourceHref &&
                clip.fragmentID == fragmentID
        })
    }

    static func firstIndex(
        resourceHref: String,
        fragmentID: String?,
        clips: [EPUBMediaOverlayClip],
        normalize: ResourceNormalizer
    ) -> Int? {
        if fragmentID == nil {
            return firstIndex(resourceHref: resourceHref, clips: clips, normalize: normalize)
        }

        // Clip hrefs are fragment-stripped at creation, so a fragment reference
        // must match on the clip's own fragmentID before falling back to the file.
        if let fragmentID,
           let fragmentMatch = clips.firstIndex(where: { clip in
               normalize(clip.textResourceHref) == resourceHref &&
                   clip.fragmentID == fragmentID
           }) {
            return fragmentMatch
        }

        return clips.firstIndex(where: { clip in
            normalize(clip.textResourceHref) == resourceHref
        })
    }

    static func firstIndex(
        resourceHref: String,
        clips: [EPUBMediaOverlayClip],
        normalize: ResourceNormalizer
    ) -> Int? {
        clips.firstIndex(where: { clip in
            normalize(clip.textResourceHref) == resourceHref
        })
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
}
