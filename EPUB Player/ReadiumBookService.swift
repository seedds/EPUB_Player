//
//  ReadiumBookService.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation
import ReadiumShared
import ReadiumStreamer

enum ReadiumBookError: LocalizedError {
    case invalidFilePath(String)
    case notEPUB
    case openFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidFilePath(let path):
            "The EPUB file path is invalid: \(path)"
        case .notEPUB:
            "Readium opened the file, but it is not an EPUB publication."
        case .openFailed(let error):
            "Readium could not open this EPUB. \(error.localizedDescription)"
        }
    }
}

@MainActor
final class ReadiumBookService {
    static let shared = ReadiumBookService()

    private lazy var httpClient: HTTPClient = DefaultHTTPClient()
    private lazy var assetRetriever = AssetRetriever(httpClient: httpClient)
    private lazy var publicationOpener = PublicationOpener(
        parser: DefaultPublicationParser(
            httpClient: httpClient,
            assetRetriever: assetRetriever,
            pdfFactory: DefaultPDFDocumentFactory()
        ),
        contentProtections: []
    )

    private init() {}

    func openPublication(for book: Book, sender: Any? = nil) async throws -> Publication {
        let resolvedEPUBURL: URL
        do {
            resolvedEPUBURL = try book.resolvedEPUBFileURL()
        } catch {
            throw ReadiumBookError.invalidFilePath(book.epubFilePath)
        }

        guard let fileURL = FileURL(path: resolvedEPUBURL.path, isDirectory: false) else {
            throw ReadiumBookError.invalidFilePath(resolvedEPUBURL.path)
        }

        do {
            let asset = try await assetRetriever.retrieve(url: fileURL).get()
            let publication = try await publicationOpener.open(
                asset: asset,
                allowUserInteraction: true,
                sender: sender
            ).get()

            guard publication.conforms(to: .epub) else {
                throw ReadiumBookError.notEPUB
            }

            return publication
        } catch let error as ReadiumBookError {
            throw error
        } catch {
            throw ReadiumBookError.openFailed(error)
        }
    }
}
