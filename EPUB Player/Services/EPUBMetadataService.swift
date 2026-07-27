//
//  EPUBMetadataService.swift
//  EPUB Player
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation

struct EPUBMetadata {
    var title: String?
    var author: String?
    var language: String?
    var identifier: String?
    var coverImagePath: String?

    nonisolated init(
        title: String? = nil,
        author: String? = nil,
        language: String? = nil,
        identifier: String? = nil,
        coverImagePath: String? = nil
    ) {
        self.title = title
        self.author = author
        self.language = language
        self.identifier = identifier
        self.coverImagePath = coverImagePath
    }
}

struct EPUBPackageInfo {
    struct ManifestItem {
        let id: String
        let href: String
        let mediaType: String?
        let mediaOverlay: String?
        let properties: Set<String>

        nonisolated init(id: String, href: String, mediaType: String?, mediaOverlay: String?, properties: Set<String>) {
            self.id = id
            self.href = href
            self.mediaType = mediaType
            self.mediaOverlay = mediaOverlay
            self.properties = properties
        }
    }

    var packageURL: URL
    var title: String?
    var creator: String?
    var language: String?
    var identifier: String?
    var coverItemId: String?
    var mediaActiveClass: String?
    var mediaPlaybackActiveClass: String?
    var mediaDuration: Double?
    var mediaNarrator: String?
    var manifestItems: [ManifestItem] = []
    /// Manifest item ids in `<spine>` (`itemref`) order. The spine — not the
    /// manifest — defines reading order, so this drives media-overlay document
    /// ordering. Empty when the OPF declares no spine.
    var spineItemRefs: [String] = []

    nonisolated init(
        packageURL: URL,
        title: String? = nil,
        creator: String? = nil,
        language: String? = nil,
        identifier: String? = nil,
        coverItemId: String? = nil,
        mediaActiveClass: String? = nil,
        mediaPlaybackActiveClass: String? = nil,
        mediaDuration: Double? = nil,
        mediaNarrator: String? = nil,
        manifestItems: [ManifestItem] = [],
        spineItemRefs: [String] = []
    ) {
        self.packageURL = packageURL
        self.title = title
        self.creator = creator
        self.language = language
        self.identifier = identifier
        self.coverItemId = coverItemId
        self.mediaActiveClass = mediaActiveClass
        self.mediaPlaybackActiveClass = mediaPlaybackActiveClass
        self.mediaDuration = mediaDuration
        self.mediaNarrator = mediaNarrator
        self.manifestItems = manifestItems
        self.spineItemRefs = spineItemRefs
    }
}

struct EPUBArchiveAsset {
    let path: String
    let mediaType: String?
    let data: Data

    nonisolated var pathExtension: String {
        let fileExtension = URL(fileURLWithPath: path).pathExtension
        if !fileExtension.isEmpty {
            return fileExtension
        }

        switch mediaType?.lowercased() {
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/svg+xml":
            return "svg"
        default:
            return "img"
        }
    }
}

enum EPUBMetadataService {
    nonisolated private static var virtualRootURL: URL {
        URL(fileURLWithPath: "/virtual-epub-root", isDirectory: true)
    }

    nonisolated static func metadata(at epubURL: URL) async throws -> EPUBMetadata {
        let archive = try await EPUBArchive(url: epubURL)
        guard let package = try await packageInfo(in: archive) else {
            return EPUBMetadata()
        }

        return metadata(from: package)
    }

    nonisolated static func metadata(from package: EPUBPackageInfo) -> EPUBMetadata {
        EPUBMetadata(
            title: clean(package.title),
            author: clean(package.creator),
            language: clean(package.language),
            identifier: clean(package.identifier),
            coverImagePath: nil
        )
    }

    nonisolated static func packageInfo(in archive: EPUBArchive) async throws -> EPUBPackageInfo? {
        guard let containerData = try await archive.data(for: "META-INF/container.xml") else {
            return nil
        }

        let parser = ContainerParser()
        guard let fullPath = parser.parse(data: containerData),
              let packageURL = resolvedURL(for: fullPath, relativeTo: virtualRootURL, root: virtualRootURL),
              let packagePath = AppStorage.relativePath(from: packageURL.path, under: virtualRootURL.path),
              let packageData = try await archive.data(for: packagePath)
        else {
            return nil
        }

        return OPFParser(packageURL: packageURL).parse(data: packageData)
    }

    nonisolated static func coverImageAsset(in archive: EPUBArchive, package: EPUBPackageInfo) async throws -> EPUBArchiveAsset? {
        guard let coverItem = coverManifestItem(in: package),
              let coverURL = resolvedURL(
                for: coverItem.href,
                relativeTo: package.packageURL.deletingLastPathComponent(),
                root: virtualRootURL
              ),
              let coverPath = AppStorage.relativePath(from: coverURL.path, under: virtualRootURL.path),
              let coverData = try await archive.data(for: coverPath)
        else {
            return nil
        }

        return EPUBArchiveAsset(path: coverPath, mediaType: coverItem.mediaType, data: coverData)
    }

    nonisolated static func resolvedURL(for href: String, relativeTo baseURL: URL, root: URL) -> URL? {
        let stripped = href.components(separatedBy: "#").first?.components(separatedBy: "?").first ?? href
        guard !stripped.isEmpty, !stripped.hasPrefix("/"), !stripped.hasPrefix("~") else {
            return nil
        }

        let decoded = stripped.removingPercentEncoding ?? stripped
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        let url = components.reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else {
            return nil
        }
        return url
    }

    nonisolated private static func coverManifestItem(in package: EPUBPackageInfo) -> EPUBPackageInfo.ManifestItem? {
        package.manifestItems.first { item in
            item.properties.contains("cover-image")
        } ?? package.manifestItems.first { item in
            package.coverItemId != nil && item.id == package.coverItemId
        }
    }

    nonisolated private static func clean(_ value: String?) -> String? {
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == false ? cleaned : nil
    }

    #if DEBUG
    /// Test-only access to container.xml parsing, so the XML hardening can be
    /// exercised without building a full archive around the document.
    nonisolated static func test_parseContainerRootPath(data: Data) -> String? {
        ContainerParser().parse(data: data)
    }
    #endif
}

nonisolated private final class ContainerParser: NSObject, XMLParserDelegate {
    private var fullPath: String?

    nonisolated override init() {
        super.init()
    }

    nonisolated func parse(data: Data) -> String? {
        // A malformed container.xml must surface as a parse failure, not a
        // silently-nil rootfile that looks like a valid-but-empty container.
        guard parse(makeHardenedXMLParser(data: data)) else {
            return nil
        }
        return fullPath
    }

    nonisolated private func parse(_ parser: XMLParser) -> Bool {
        fullPath = nil
        parser.delegate = self
        return parser.parse()
    }

    nonisolated func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard localName(elementName) == "rootfile", fullPath == nil else {
            return
        }
        fullPath = attributeDict["full-path"]
    }
}

nonisolated private final class OPFParser: NSObject, XMLParserDelegate {
    private var package: EPUBPackageInfo
    private var currentMetadataElement: String?
    private var currentText = ""

    nonisolated init(packageURL: URL) {
        package = EPUBPackageInfo(packageURL: packageURL)
    }

    nonisolated func parse(data: Data) -> EPUBPackageInfo? {
        // A malformed OPF must fail rather than yield a partially-parsed
        // package: a truncated manifest would wrongly prune valid bookmarks on
        // reimport (they'd appear to reference missing resources).
        guard parse(makeHardenedXMLParser(data: data)) else {
            return nil
        }
        return package
    }

    nonisolated private func parse(_ parser: XMLParser) -> Bool {
        parser.delegate = self
        return parser.parse()
    }

    nonisolated func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)

        switch name {
        case "title", "creator", "language", "identifier":
            currentMetadataElement = name
            currentText = ""

        case "meta":
            if attributeDict["name"] == "cover", let content = attributeDict["content"] {
                package.coverItemId = content
            }
            if attributeDict["property"] == "media:active-class" {
                currentMetadataElement = "media:active-class"
                currentText = ""
            } else if attributeDict["property"] == "media:playback-active-class" {
                currentMetadataElement = "media:playback-active-class"
                currentText = ""
            } else if attributeDict["property"] == "media:duration" {
                // A refines-scoped duration belongs to one SMIL document; only
                // the unrefined meta is the publication total.
                if attributeDict["refines"] == nil {
                    currentMetadataElement = "media:duration"
                    currentText = ""
                }
            } else if attributeDict["property"] == "media:narrator" {
                currentMetadataElement = "media:narrator"
                currentText = ""
            }

        case "item":
            guard let id = attributeDict["id"], let href = attributeDict["href"] else {
                return
            }
            let properties = Set((attributeDict["properties"] ?? "").split(separator: " ").map(String.init))
            package.manifestItems.append(EPUBPackageInfo.ManifestItem(
                id: id,
                href: href,
                mediaType: attributeDict["media-type"],
                mediaOverlay: attributeDict["media-overlay"],
                properties: properties
            ))

        case "itemref":
            // Spine reading order. `idref` points at a manifest item id.
            if let idref = attributeDict["idref"] {
                package.spineItemRefs.append(idref)
            }

        default:
            break
        }
    }

    nonisolated func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentMetadataElement != nil else {
            return
        }
        currentText += string
    }

    nonisolated func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        guard currentMetadataElement == name || (name == "meta" && currentMetadataElement?.hasPrefix("media:") == true) else {
            return
        }

        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            switch currentMetadataElement {
            case "title" where package.title == nil:
                package.title = text
            case "creator" where package.creator == nil:
                package.creator = text
            case "language" where package.language == nil:
                package.language = text
            case "identifier" where package.identifier == nil:
                package.identifier = text
            case "media:active-class":
                package.mediaActiveClass = text
            case "media:playback-active-class":
                package.mediaPlaybackActiveClass = text
            case "media:duration":
                package.mediaDuration = EPUBMediaOverlayTimeParser.seconds(from: text)
            case "media:narrator":
                package.mediaNarrator = text
            default:
                break
            }
        }

        currentMetadataElement = nil
        currentText = ""
    }
}

// Shared by the OPF and SMIL parsers ("smil:par" -> "par").
nonisolated func localName(_ elementName: String) -> String {
    elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? elementName.lowercased()
}

/// Builds an `XMLParser` for untrusted EPUB content.
///
/// Every XML document the importer reads (container.xml, the OPF, SMIL
/// overlays) comes from an EPUB, and EPUBs arrive over an unauthenticated LAN
/// upload server. Foundation already refuses to resolve external entities by
/// default; setting the policy explicitly makes that guarantee local to the
/// code that depends on it rather than an inherited default, so a future
/// change cannot silently opt into file disclosure. See `XMLHardeningTests`.
nonisolated func makeHardenedXMLParser(data: Data) -> XMLParser {
    let parser = XMLParser(data: data)
    parser.externalEntityResolvingPolicy = .never
    parser.shouldResolveExternalEntities = false
    return parser
}
