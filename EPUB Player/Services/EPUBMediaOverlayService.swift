//
//  EPUBMediaOverlayService.swift
//  EPUB Player
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation

nonisolated struct EPUBMediaOverlayProgress: Sendable {
    var fractionCompleted: Double
    var message: String

    nonisolated init(fractionCompleted: Double, message: String) {
        self.fractionCompleted = fractionCompleted
        self.message = message
    }
}

nonisolated struct EPUBMediaOverlayManifest: Codable {
    var duration: Double?
    var documents: [EPUBMediaOverlayDocument]

    nonisolated init(
        duration: Double? = nil,
        documents: [EPUBMediaOverlayDocument]
    ) {
        self.duration = duration
        self.documents = documents
    }

    nonisolated var clipCount: Int {
        documents.reduce(0) { $0 + $1.clips.count }
    }
}

nonisolated struct EPUBMediaOverlayDocument: Codable {
    var clips: [EPUBMediaOverlayClip]

    nonisolated init(clips: [EPUBMediaOverlayClip]) {
        self.clips = clips
    }
}

nonisolated struct EPUBMediaOverlayClip: Codable, Equatable {
    var textResourceHref: String
    var fragmentID: String?
    var audioPath: String
    var clipBegin: Double
    var clipEnd: Double?

    // The one canonical identity; ad-hoc field subsets compared at different
    // call sites had already drifted (one omitted audioPath).
    var identityKey: String {
        [
            audioPath,
            textResourceHref,
            fragmentID ?? "",
            String(clipBegin),
            String(clipEnd ?? -1)
        ].joined(separator: "|")
    }

    nonisolated init(
        textResourceHref: String,
        fragmentID: String?,
        audioPath: String,
        clipBegin: Double,
        clipEnd: Double?
    ) {
        self.textResourceHref = textResourceHref
        self.fragmentID = fragmentID
        self.audioPath = audioPath
        self.clipBegin = clipBegin
        self.clipEnd = clipEnd
    }
}

nonisolated struct EPUBMediaOverlayParseResult {
    var manifest: EPUBMediaOverlayManifest
    var jsonURL: URL

    nonisolated init(manifest: EPUBMediaOverlayManifest, jsonURL: URL) {
        self.manifest = manifest
        self.jsonURL = jsonURL
    }
}

enum EPUBMediaOverlayService {
    nonisolated static func parseAndWrite(
        at epubURL: URL,
        bookID: UUID,
        destinationURL: URL? = nil,
        progressHandler: ((EPUBMediaOverlayProgress) -> Void)? = nil
    ) async throws -> EPUBMediaOverlayParseResult? {
        reportProgress(
            EPUBMediaOverlayProgress(fractionCompleted: 0.05, message: "Opening EPUB..."),
            using: progressHandler
        )
        let archive = try await EPUBArchive(url: epubURL)
        reportProgress(
            EPUBMediaOverlayProgress(fractionCompleted: 0.15, message: "Reading package metadata..."),
            using: progressHandler
        )
        guard let package = try await EPUBMetadataService.packageInfo(in: archive) else {
            reportProgress(
                EPUBMediaOverlayProgress(fractionCompleted: 1, message: "Read-aloud unavailable"),
                using: progressHandler
            )
            return nil
        }
        reportProgress(
            EPUBMediaOverlayProgress(fractionCompleted: 0.25, message: "Scanning media overlays..."),
            using: progressHandler
        )
        guard let manifest = try await parse(in: archive, package: package, progressHandler: progressHandler), manifest.clipCount > 0 else {
            reportProgress(
                EPUBMediaOverlayProgress(fractionCompleted: 1, message: "Read-aloud unavailable"),
                using: progressHandler
            )
            return nil
        }

        let jsonURL = try destinationURL ?? AppStorage.mediaOverlayManifestURL(for: bookID)
        let encoder = JSONEncoder()
        reportProgress(
            EPUBMediaOverlayProgress(fractionCompleted: 0.95, message: "Writing read-aloud data..."),
            using: progressHandler
        )
        // Cancellation here means the book was deleted mid-parse; writing the
        // manifest would orphan it in the cache directory.
        guard !Task.isCancelled else {
            return nil
        }
        let data = try encoder.encode(manifest)
        try data.write(to: jsonURL, options: .atomic)
        reportProgress(
            EPUBMediaOverlayProgress(fractionCompleted: 1, message: "Read-aloud ready"),
            using: progressHandler
        )
        return EPUBMediaOverlayParseResult(manifest: manifest, jsonURL: jsonURL)
    }

    nonisolated private static func parse(
        in archive: EPUBArchive,
        package: EPUBPackageInfo,
        progressHandler: ((EPUBMediaOverlayProgress) -> Void)? = nil
    ) async throws -> EPUBMediaOverlayManifest? {
        let virtualRoot = URL(fileURLWithPath: "/virtual-epub-root", isDirectory: true)
        return try await parseInternal(root: virtualRoot, package: package, progressHandler: progressHandler) { smilURL in
            guard let smilPath = AppStorage.relativePath(from: smilURL.path, under: virtualRoot.path),
                  let smilData = try await archive.data(for: smilPath)
            else {
                return []
            }

            return SMILParser(
                rootURL: virtualRoot,
                smilURL: smilURL,
                smilData: smilData
            ).parse()
        }
    }

    nonisolated private static func parseInternal(
        root: URL,
        package: EPUBPackageInfo,
        progressHandler: ((EPUBMediaOverlayProgress) -> Void)? = nil,
        clipLoader: (URL) async throws -> [EPUBMediaOverlayClip]
    ) async throws -> EPUBMediaOverlayManifest? {
        let packageDirectory = package.packageURL.deletingLastPathComponent()
        var smilItemsById: [String: EPUBPackageInfo.ManifestItem] = [:]
        for item in package.manifestItems where isSMIL(item) {
            if smilItemsById[item.id] == nil {
                smilItemsById[item.id] = item
            }
        }

        var candidates: [(contentItem: EPUBPackageInfo.ManifestItem?, smilItem: EPUBPackageInfo.ManifestItem)] = []

        for item in package.manifestItems {
            guard let mediaOverlay = item.mediaOverlay, let smilItem = smilItemsById[mediaOverlay] else {
                continue
            }
            candidates.append((item, smilItem))
        }

        if candidates.isEmpty {
            // Dictionary values are unordered; emit SMIL documents in manifest
            // order so the flattened clip timeline follows reading order.
            var seenSMILIds: Set<String> = []
            candidates = package.manifestItems.compactMap { item in
                guard isSMIL(item), seenSMILIds.insert(item.id).inserted else {
                    return nil
                }
                return (nil, item)
            }
        }

        candidates = orderedBySpine(candidates, spineItemRefs: package.spineItemRefs)

        var documents: [EPUBMediaOverlayDocument] = []
        let candidateCount = max(candidates.count, 1)
        for (index, candidate) in candidates.enumerated() {
            // Bail early on cancellation instead of parsing every remaining SMIL
            // document (a cancelled preparation means the book was deleted).
            try Task.checkCancellation()

            let progressFraction = 0.25 + (Double(index) / Double(candidateCount)) * 0.65
            reportProgress(
                EPUBMediaOverlayProgress(
                    fractionCompleted: progressFraction,
                    message: "Parsing read-aloud \(index + 1) of \(candidates.count)..."
                ),
                using: progressHandler
            )

            let smilItem = candidate.smilItem
            guard let smilURL = EPUBMetadataService.resolvedURL(
                for: smilItem.href,
                relativeTo: packageDirectory,
                root: root
            ) else {
                continue
            }

            let clips = try await clipLoader(smilURL)
            guard !clips.isEmpty else {
                continue
            }

            documents.append(EPUBMediaOverlayDocument(clips: clips))
        }

        reportProgress(
            EPUBMediaOverlayProgress(fractionCompleted: 0.9, message: "Finalizing read-aloud data..."),
            using: progressHandler
        )

        guard !documents.isEmpty else {
            return nil
        }

        return EPUBMediaOverlayManifest(
            duration: package.mediaDuration,
            documents: documents
        )
    }

    nonisolated private static func isSMIL(_ item: EPUBPackageInfo.ManifestItem) -> Bool {
        item.mediaType == "application/smil+xml" || item.href.lowercased().hasSuffix(".smil")
    }

    /// Reorders media-overlay candidates to follow `<spine>` reading order. The
    /// EPUB spec only guarantees reading order via the spine; the manifest may
    /// be declared in a different order (some tools alphabetize it), which made
    /// auto-advance jump between chapters out of order. Candidates whose content
    /// item is absent from the spine (or all candidates, when the OPF has no
    /// spine) keep their original relative order.
    nonisolated private static func orderedBySpine(
        _ candidates: [(contentItem: EPUBPackageInfo.ManifestItem?, smilItem: EPUBPackageInfo.ManifestItem)],
        spineItemRefs: [String]
    ) -> [(contentItem: EPUBPackageInfo.ManifestItem?, smilItem: EPUBPackageInfo.ManifestItem)] {
        guard !spineItemRefs.isEmpty else {
            return candidates
        }

        let spinePosition = Dictionary(
            spineItemRefs.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        // Items not in the spine sort after spine items, preserving their
        // original order via the enumeration index tiebreaker.
        let fallbackPosition = spineItemRefs.count

        return candidates.enumerated().sorted { lhs, rhs in
            let lhsSpine = lhs.element.contentItem.flatMap { spinePosition[$0.id] } ?? fallbackPosition
            let rhsSpine = rhs.element.contentItem.flatMap { spinePosition[$0.id] } ?? fallbackPosition
            if lhsSpine != rhsSpine {
                return lhsSpine < rhsSpine
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    nonisolated private static func reportProgress(
        _ progress: EPUBMediaOverlayProgress,
        using progressHandler: ((EPUBMediaOverlayProgress) -> Void)?
    ) {
        progressHandler?(EPUBMediaOverlayProgress(
            fractionCompleted: min(max(progress.fractionCompleted, 0), 1),
            message: progress.message
        ))
    }
}

enum EPUBMediaOverlayTimeParser {
    nonisolated static func seconds(from value: String?) -> Double? {
        guard var text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        // Strip an RFC 2326 "npt=" (normal play time) prefix. Without this a
        // value like "npt=0:00:05.5" parses to nil (and clipBegin coalesces to
        // 0), so a clip never advances at its intended time.
        if text.lowercased().hasPrefix("npt=") {
            text = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
        }

        text = text.replacingOccurrences(of: ",", with: ".")

        if text.hasSuffix("ms") {
            let number = text.dropLast(2)
            return Double(number).map { $0 / 1000 }
        }

        if text.hasSuffix("s") {
            let number = text.dropLast()
            return Double(number)
        }

        if text.hasSuffix("min") {
            let number = text.dropLast(3)
            return Double(number).map { $0 * 60 }
        }

        if text.hasSuffix("h") {
            let number = text.dropLast()
            return Double(number).map { $0 * 3600 }
        }

        let parts = text.split(separator: ":").map(String.init)
        switch parts.count {
        case 1:
            return Double(parts[0])
        case 2:
            guard let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
            return minutes * 60 + seconds
        case 3:
            guard let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        default:
            return nil
        }
    }
}

nonisolated private final class SMILParser: NSObject, XMLParserDelegate {
    private struct ParBuilder {
        var textSource: String?
        var audioSource: String?
        var clipBegin: Double = 0
        var clipEnd: Double?
    }

    private let rootURL: URL
    private let smilURL: URL
    private let smilData: Data
    private var parStack: [ParBuilder] = []
    private var clips: [EPUBMediaOverlayClip] = []

    nonisolated init(rootURL: URL, smilURL: URL, smilData: Data) {
        self.rootURL = rootURL
        self.smilURL = smilURL
        self.smilData = smilData
    }

    nonisolated func parse() -> [EPUBMediaOverlayClip] {
        let parser = makeHardenedXMLParser(data: smilData)
        parser.delegate = self
        parser.parse()
        return clips
    }

    nonisolated func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch localName(elementName) {
        case "par":
            parStack.append(ParBuilder())
        case "text":
            guard !parStack.isEmpty else { return }
            parStack[parStack.count - 1].textSource = attributeDict["src"]
        case "audio":
            guard !parStack.isEmpty else { return }
            parStack[parStack.count - 1].audioSource = attributeDict["src"]
            parStack[parStack.count - 1].clipBegin = EPUBMediaOverlayTimeParser.seconds(
                from: attributeDict["clipBegin"] ?? attributeDict["clip-begin"]
            ) ?? 0
            parStack[parStack.count - 1].clipEnd = EPUBMediaOverlayTimeParser.seconds(
                from: attributeDict["clipEnd"] ?? attributeDict["clip-end"]
            )
        default:
            break
        }
    }

    nonisolated func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard localName(elementName) == "par", let builder = parStack.popLast(), let clip = makeClip(from: builder) else {
            return
        }
        clips.append(clip)
    }

    nonisolated private func makeClip(from builder: ParBuilder) -> EPUBMediaOverlayClip? {
        guard let textSource = builder.textSource,
              let audioSource = builder.audioSource,
              let textReference = resolveReference(textSource),
              let audioReference = resolveReference(audioSource)
        else {
            return nil
        }

        return EPUBMediaOverlayClip(
            textResourceHref: textReference.resourceHref,
            fragmentID: textReference.fragmentID,
            audioPath: audioReference.resourceHref,
            clipBegin: builder.clipBegin,
            clipEnd: builder.clipEnd
        )
    }

    nonisolated private func resolveReference(_ href: String) -> (resourceHref: String, fragmentID: String?)? {
        let fragmentID = fragment(from: href)
        let smilDirectory = smilURL.deletingLastPathComponent()
        guard let fileURL = EPUBMetadataService.resolvedURL(
            for: hrefWithoutFragment(href),
            relativeTo: smilDirectory,
            root: rootURL
        ), let resourceHref = AppStorage.relativePath(from: fileURL.path, under: rootURL.path) else {
            return nil
        }

        return (resourceHref, fragmentID)
    }

    nonisolated private func fragment(from href: String) -> String? {
        if let hashIndex = href.lastIndex(of: "#") {
            return String(href[href.index(after: hashIndex)...])
        }

        if let encodedRange = href.range(of: "%23", options: .backwards) {
            return String(href[encodedRange.upperBound...])
        }

        return nil
    }

    // resolvedURL only strips literal '#'; a '%23'-encoded fragment would
    // otherwise percent-decode into the file path.
    nonisolated private func hrefWithoutFragment(_ href: String) -> String {
        if let hashIndex = href.lastIndex(of: "#") {
            return String(href[..<hashIndex])
        }

        if let encodedRange = href.range(of: "%23", options: .backwards) {
            return String(href[..<encodedRange.lowerBound])
        }

        return href
    }
}
