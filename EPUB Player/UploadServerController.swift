//
//  UploadServerController.swift
//  EPUB Player
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation
import Darwin
import Combine

enum LocalLibraryError: LocalizedError {
    case bookNotFound
    case duplicateFilename(String)
    case invalidFilename

    var errorDescription: String? {
        switch self {
        case .bookNotFound:
            "The selected book could not be found."
        case .duplicateFilename(let filename):
            "A book named \(filename) already exists."
        case .invalidFilename:
            "Enter a valid EPUB filename."
        }
    }
}

@MainActor
final class UploadServerController: ObservableObject {
    private struct PendingImport {
        enum Kind {
            case book
            case customFont
        }

        enum Source {
            case upload(UUID)
            case manual
        }

        let sourceURL: URL
        let filename: String
        let kind: Kind
        let source: Source
        let existingBookStrategy: BookImportService.ExistingBookStrategy
    }

    enum Status: Equatable {
        case stopped
        case running
        case failed(String)

        var title: String {
            switch self {
            case .stopped: "Stopped"
            case .running: "Running"
            case .failed: "Failed"
            }
        }
    }

    struct UploadRecord: Identifiable {
        let id = UUID()
        let filename: String
        let date: Date
    }

    struct ActiveUpload: Identifiable {
        enum Phase {
            case uploading
            case importing
            case failed(String)
        }

        let id: UUID
        var filename: String
        var startedAt: Date
        var receivedBytes: Int64
        var totalBytes: Int64
        var phase: Phase

        var progress: Double {
            guard totalBytes > 0 else { return 0 }
            return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
        }

        var speedBytesPerSecond: Double {
            guard isUploading else { return 0 }
            let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
            return Double(receivedBytes) / elapsed
        }

        var isUploading: Bool {
            if case .uploading = phase {
                return true
            }
            return false
        }

        var isImporting: Bool {
            if case .importing = phase {
                return true
            }
            return false
        }

        var failureMessage: String? {
            if case .failed(let message) = phase {
                return message
            }
            return nil
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var activeUploads: [ActiveUpload] = []
    @Published private(set) var recentUploads: [UploadRecord] = []
    @Published var port: UInt16
    @Published private(set) var isImportingBooks = false
    @Published private(set) var importProgress = 0.0
    @Published private(set) var importStatus = ""
    @Published private(set) var currentImportFilename: String?
    @Published private(set) var completedImportCount = 0
    @Published private(set) var totalImportCount = 0
    @Published var manualImportErrorMessage: String?

    private var server: LocalUploadServer?
    private var pendingImports: [PendingImport] = []
    private var importTask: Task<Void, Never>?

    init(port: UInt16 = ReaderSettings.uploadServerPort(from: ReaderSettings.defaultUploadServerPort)) {
        self.port = port
    }

    var serverURL: URL? {
        guard case .running = status, let ipAddress = Self.localIPAddress() else {
            return nil
        }
        return URL(string: "http://\(ipAddress):\(port)")
    }

    func start(store: AppStateStore) {
        guard server == nil else { return }

        let server = LocalUploadServer(port: port)
        server.onUploadStarted = { [weak self] snapshot in
            Task { @MainActor in
                self?.upsertActiveUpload(from: snapshot, phase: .uploading)
            }
        }
        server.onUploadProgress = { [weak self] snapshot in
            Task { @MainActor in
                self?.upsertActiveUpload(from: snapshot, phase: .uploading)
            }
        }
        server.onUploadFinished = { [weak self] uploadID, fileURL, filename in
            Task { @MainActor in
                guard let self else {
                    return
                }

                self.setPhase(.importing, forUploadID: uploadID)
                self.enqueueImports(
                    [PendingImport(
                        sourceURL: fileURL,
                        filename: filename,
                        kind: self.pendingImportKind(for: filename),
                        source: .upload(uploadID),
                        existingBookStrategy: .overwrite
                    )],
                    store: store
                )
            }
        }
        server.onUploadFailed = { [weak self] uploadID, filename, message in
            Task { @MainActor in
                self?.markUploadFailed(id: uploadID, filename: filename, message: message)
            }
        }
        server.onBooksRequested = { [weak self] completion in
            Task { @MainActor in
                do {
                    guard let self else { throw LocalLibraryError.bookNotFound }
                    completion(.success(try self.booksJSON(store: store)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        server.onRenameRequested = { [weak self] bookId, filename, completion in
            Task { @MainActor in
                do {
                    guard let self else { throw LocalLibraryError.bookNotFound }
                    try self.renameBook(id: bookId, to: filename, store: store)
                    completion(.success(try self.booksJSON(store: store)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        server.onDeleteRequested = { [weak self] bookId, completion in
            Task { @MainActor in
                do {
                    guard let self else { throw LocalLibraryError.bookNotFound }
                    try self.deleteBook(id: bookId, store: store)
                    completion(.success(try self.booksJSON(store: store)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        server.onError = { [weak self, weak server] message in
            Task { @MainActor in
                self?.handleServerFailure(message, from: server)
            }
        }

        do {
            try server.start()
            self.server = server
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        server?.stop()
        server = nil
        activeUploads = []
        status = .stopped
    }

    func importBooks(from urls: [URL], store: AppStateStore) {
        let imports = urls.map {
            PendingImport(
                sourceURL: $0,
                filename: AppStorage.sanitizedFilename($0.lastPathComponent),
                kind: .book,
                source: .manual,
                existingBookStrategy: .skip
            )
        }

        manualImportErrorMessage = nil
        enqueueImports(imports, store: store)
    }

    func clearManualImportError() {
        manualImportErrorMessage = nil
    }

    var currentImportCountText: String? {
        guard totalImportCount > 0, isImportingBooks else {
            return nil
        }
        return "File \(min(completedImportCount + 1, totalImportCount)) of \(totalImportCount)"
    }

    private func enqueueImports(_ imports: [PendingImport], store: AppStateStore) {
        guard !imports.isEmpty else {
            return
        }

        if !isImportingBooks, pendingImports.isEmpty {
            completedImportCount = 0
            totalImportCount = 0
            importProgress = 0
            importStatus = ""
            currentImportFilename = nil
        }

        pendingImports.append(contentsOf: imports)
        totalImportCount += imports.count
        startImportProcessing(store: store)
    }

    private func startImportProcessing(store: AppStateStore) {
        guard importTask == nil else {
            return
        }

        importTask = Task { @MainActor [weak self] in
            await self?.processPendingImports(store: store)
        }
    }

    private func processPendingImports(store: AppStateStore) async {
        defer {
            importTask = nil
            isImportingBooks = false
            importProgress = 0
            importStatus = ""
            currentImportFilename = nil
            completedImportCount = 0
            totalImportCount = 0
        }

        while !pendingImports.isEmpty {
            let pendingImport = pendingImports.removeFirst()
            isImportingBooks = true
            currentImportFilename = pendingImport.filename
            importProgress = overallImportProgress(for: 0)
            importStatus = "Preparing import..."

            do {
                switch pendingImport.kind {
                case .book:
                    _ = try await BookImportService.importBook(
                        from: pendingImport.sourceURL,
                        filename: pendingImport.filename,
                        store: store,
                        existingBookStrategy: pendingImport.existingBookStrategy
                    ) { [weak self] progress in
                        guard let self else { return }
                        self.importProgress = self.overallImportProgress(for: progress.fractionCompleted)
                        self.importStatus = progress.message
                    }

                case .customFont:
                    importStatus = "Importing font..."
                    _ = try CustomFontStore.importFonts(from: [pendingImport.sourceURL], store: store)
                    importProgress = overallImportProgress(for: 1)
                    importStatus = "Import complete"
                }

                if case .upload(let uploadID) = pendingImport.source {
                    removeActiveUpload(id: uploadID)
                    recentUploads.insert(UploadRecord(filename: pendingImport.filename, date: Date()), at: 0)
                }
            } catch {
                if case .upload(let uploadID) = pendingImport.source {
                    markUploadFailed(id: uploadID, filename: pendingImport.filename, message: error.localizedDescription)
                } else if manualImportErrorMessage == nil {
                    manualImportErrorMessage = error.localizedDescription
                }
            }

            if case .upload = pendingImport.source {
                try? FileManager.default.removeItem(at: pendingImport.sourceURL)
            }

            completedImportCount += 1
            importProgress = overallImportProgress(for: 0)
        }
    }

    private func overallImportProgress(for currentBookProgress: Double) -> Double {
        guard totalImportCount > 0 else {
            return currentBookProgress
        }

        let completed = Double(completedImportCount)
        return min(max((completed + currentBookProgress) / Double(totalImportCount), 0), 1)
    }

    private func upsertActiveUpload(from snapshot: LocalUploadServer.UploadTransferSnapshot, phase: ActiveUpload.Phase) {
        let upload = ActiveUpload(
            id: snapshot.id,
            filename: snapshot.filename,
            startedAt: snapshot.startedAt,
            receivedBytes: snapshot.receivedBytes,
            totalBytes: snapshot.totalBytes,
            phase: phase
        )

        if let index = activeUploads.firstIndex(where: { $0.id == snapshot.id }) {
            activeUploads[index] = upload
        } else {
            activeUploads.insert(upload, at: 0)
        }
    }

    private func setPhase(_ phase: ActiveUpload.Phase, forUploadID uploadID: UUID) {
        guard let index = activeUploads.firstIndex(where: { $0.id == uploadID }) else {
            return
        }

        activeUploads[index].phase = phase
        if case .importing = phase {
            activeUploads[index].receivedBytes = activeUploads[index].totalBytes
        }
    }

    private func markUploadFailed(id: UUID, filename: String, message: String) {
        if let index = activeUploads.firstIndex(where: { $0.id == id }) {
            activeUploads[index].phase = .failed(message)
            activeUploads[index].filename = filename
            return
        }

        activeUploads.insert(
            ActiveUpload(
                id: id,
                filename: filename,
                startedAt: Date(),
                receivedBytes: 0,
                totalBytes: 0,
                phase: .failed(message)
            ),
            at: 0
        )
    }

    private func removeActiveUpload(id: UUID) {
        activeUploads.removeAll { $0.id == id }
    }

    private func handleServerFailure(_ message: String, from failedServer: LocalUploadServer?) {
        if let failedServer, let server, server !== failedServer {
            return
        }

        server = nil
        activeUploads = []
        status = .failed(message)
    }

    private func booksJSON(store: AppStateStore) throws -> Data {
        let books = store.books
        let fileManager = FileManager.default
        let dateFormatter = ISO8601DateFormatter()

        let payload = books.map { book -> [String: Any] in
            let attributes = (try? book.resolvedEPUBFileURL()).flatMap {
                try? fileManager.attributesOfItem(atPath: $0.path)
            }
            let fileSize = attributes?[.size] as? Int64 ?? 0
            return [
                "id": book.id.uuidString,
                "title": book.title,
                "author": book.author,
                "filename": book.originalFilename,
                "importedAt": dateFormatter.string(from: book.importedAt),
                "fileSize": fileSize,
                "hasMediaOverlay": (book.mediaOverlayClipCount ?? 0) > 0,
                "mediaOverlayClipCount": book.mediaOverlayClipCount ?? 0,
            ]
        }

        return try JSONSerialization.data(withJSONObject: ["books": payload], options: [])
    }

    private func renameBook(id: UUID, to requestedFilename: String, store: AppStateStore) throws {
        let book = try findBook(id: id, store: store)
        let filename = try epubFilename(from: requestedFilename)

        let fileManager = FileManager.default
        let libraryDirectory = try AppStorage.booksDirectory()
        let destinationURL = libraryDirectory.appendingPathComponent(filename, isDirectory: false)
        let sourceURL = try book.resolvedEPUBFileURL()

        if destinationURL.path != sourceURL.path, fileManager.fileExists(atPath: destinationURL.path) {
            throw LocalLibraryError.duplicateFilename(filename)
        }

        // Another book record may hold this filename even if its file is gone
        // from disk; two records with one filename crashes the next refresh.
        if store.books.contains(where: { $0.id != book.id && $0.originalFilename == filename }) {
            throw LocalLibraryError.duplicateFilename(filename)
        }

        if destinationURL.path != sourceURL.path {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }

        let previousDisplayTitle = displayTitle(for: book.originalFilename)
        book.originalFilename = filename
        if book.title == previousDisplayTitle {
            book.title = displayTitle(for: filename)
        }
        book.epubFilePath = AppStorage.storedBookPath(for: filename)
        store.sortBooksByImportedAt()
        store.persistNow()
    }

    private func deleteBook(id: UUID, store: AppStateStore) throws {
        let book = try findBook(id: id, store: store)
        if let epubURL = try? book.resolvedEPUBFileURL() {
            try? FileManager.default.removeItem(at: epubURL)
        }
        try? BookAssetCacheService.removeAllCachedAssets(for: book.id)
        store.removeBook(id: book.id)
        store.persistNow()
    }

    private func findBook(id: UUID, store: AppStateStore) throws -> Book {
        guard let book = store.book(withID: id) else {
            throw LocalLibraryError.bookNotFound
        }
        return book
    }

    private func epubFilename(from filename: String) throws -> String {
        let trimmedFilename = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFilename.isEmpty,
              !trimmedFilename.contains("/"),
              !trimmedFilename.contains("\\"),
              let sanitized = AppStorage.sanitizedFilenameOrNil(trimmedFilename)
        else {
            throw LocalLibraryError.invalidFilename
        }

        if sanitized.lowercased().hasSuffix(".epub") {
            return sanitized
        }
        return "\(sanitized).epub"
    }

    private func displayTitle(for filename: String) -> String {
        URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
    }

    private func pendingImportKind(for filename: String) -> PendingImport.Kind {
        let pathExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        switch pathExtension {
        case "ttf", "otf":
            return .customFont
        default:
            return .book
        }
    }

    private static func localIPAddress() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        for interface in sequence(first: firstInterface, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            guard isUp, !isLoopback else { continue }

            // getifaddrs can return entries with no address (e.g. interfaces
            // mid-configuration); ifa_addr is NULL for those.
            guard let interfaceAddress = interface.pointee.ifa_addr else { continue }
            let addr = interfaceAddress.pointee
            guard addr.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.pointee.ifa_name)
            guard name == "en0" || name.hasPrefix("en") else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var socketAddress = addr
            let result = getnameinfo(
                &socketAddress,
                socklen_t(socketAddress.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                address = String(cString: hostname)
                break
            }
        }

        return address
    }
}
