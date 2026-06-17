//
//  LocalUploadServer.swift
//  EPUB Player
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation
import Network

enum LocalUploadServerError: LocalizedError {
    case invalidPort
    case portInUse(UInt16)
    case failedToStart(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "The upload server port is invalid."
        case .portInUse(let port):
            "Port \(port) is already in use. Stop the other app using it or choose a different port in the Upload tab."
        case .failedToStart(let reason):
            "The upload server failed to start: \(reason)"
        }
    }
}

// Immutable auth configuration passed to each connection.
struct UploadServerAuthConfig {
    let requiresPassword: Bool
    let password: String
    // Random token generated at server start; valid for the lifetime of
    // this server instance.  Cleared implicitly when the server stops.
    let sessionToken: String

    static let open = UploadServerAuthConfig(requiresPassword: false, password: "", sessionToken: "")

    static func makeProtected(password: String) -> UploadServerAuthConfig {
        let token = UUID().uuidString + UUID().uuidString
        return UploadServerAuthConfig(requiresPassword: true, password: password, sessionToken: token)
    }

    // Pure function so it is easily unit-tested without spinning up a server.
    func isAuthorized(token: String?) -> Bool {
        guard requiresPassword else { return true }
        guard let token, !token.isEmpty else { return false }
        return token == sessionToken
    }
}

final class LocalUploadServer {
    typealias APICompletion = (Result<Data, Error>) -> Void

    struct UploadTransferSnapshot {
        let id: UUID
        let filename: String
        let receivedBytes: Int64
        let totalBytes: Int64
        let startedAt: Date
    }

    let port: UInt16
    let authConfig: UploadServerAuthConfig
    var onUploadStarted: ((UploadTransferSnapshot) -> Void)?
    var onUploadProgress: ((UploadTransferSnapshot) -> Void)?
    var onUploadFinished: ((UUID, URL, String) -> Void)?
    var onUploadFailed: ((UUID, String, String) -> Void)?
    var onBooksRequested: (((@escaping APICompletion) -> Void))?
    var onRenameRequested: ((UUID, String, @escaping APICompletion) -> Void)?
    var onDeleteRequested: ((UUID, @escaping APICompletion) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "EPUBPlayer.LocalUploadServer")
    private let queueKey = DispatchSpecificKey<Void>()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPUploadConnection] = [:]

    init(port: UInt16 = 80, authConfig: UploadServerAuthConfig = .open) {
        self.port = port
        self.authConfig = authConfig
        queue.setSpecific(key: queueKey, value: ())
    }

    func start() throws {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw LocalUploadServerError.invalidPort
        }

        Self.removeStalePartialUploads()

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let configuredPort = port
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .waiting(let error), .failed(let error):
                    self?.onError?(Self.startupError(from: error, port: configuredPort).localizedDescription)
                    self?.stop()

                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            throw Self.startupError(from: error, port: port)
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopOnQueue()
        } else {
            queue.sync {
                stopOnQueue()
            }
        }
    }

    private func stopOnQueue() {
        listener?.cancel()
        listener = nil
        let activeConnections = Array(connections.values)
        connections.removeAll()
        activeConnections.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let uploadConnection = HTTPUploadConnection(connection: connection, authConfig: authConfig)
        let id = ObjectIdentifier(uploadConnection)
        connections[id] = uploadConnection

        uploadConnection.onUploadStarted = { [weak self] snapshot in
            self?.onUploadStarted?(snapshot)
        }
        uploadConnection.onUploadProgress = { [weak self] snapshot in
            self?.onUploadProgress?(snapshot)
        }
        uploadConnection.onUploadFinished = { [weak self] uploadID, url, filename in
            self?.onUploadFinished?(uploadID, url, filename)
        }
        uploadConnection.onUploadFailed = { [weak self] uploadID, filename, message in
            self?.onUploadFailed?(uploadID, filename, message)
        }
        uploadConnection.onBooksRequested = onBooksRequested
        uploadConnection.onRenameRequested = onRenameRequested
        uploadConnection.onDeleteRequested = onDeleteRequested
        uploadConnection.onComplete = { [weak self] in
            self?.connections.removeValue(forKey: id)
        }

        uploadConnection.start(queue: queue)
    }

    // Partial uploads left behind by a crash or force-quit are never picked up
    // again; no live connections exist before the listener starts.
    private static func removeStalePartialUploads() {
        guard let uploadsDirectory = try? AppStorage.uploadsDirectory(),
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: uploadsDirectory,
                  includingPropertiesForKeys: nil,
                  options: []
              )
        else {
            return
        }

        for fileURL in contents where fileURL.lastPathComponent.hasPrefix(".upload-") {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func startupError(from error: Error, port: UInt16) -> LocalUploadServerError {
        if isPortInUse(error) {
            return .portInUse(port)
        }

        return .failedToStart(error.localizedDescription)
    }

    private static func isPortInUse(_ error: Error) -> Bool {
        if let networkError = error as? NWError,
           case .posix(let code) = networkError,
           code == .EADDRINUSE {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EADDRINUSE) {
            return true
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPortInUse(underlyingError)
        }

        return false
    }
}

// Single source of truth for which file types the upload pipeline accepts;
// the server's 415 check and the controller's import routing must agree.
enum UploadFileKind {
    case book
    case customFont

    init?(filename: String) {
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "epub":
            self = .book
        case "ttf", "otf":
            self = .customFont
        default:
            return nil
        }
    }
}

private final class HTTPUploadConnection {
    typealias APICompletion = LocalUploadServer.APICompletion

    var onUploadStarted: ((LocalUploadServer.UploadTransferSnapshot) -> Void)?
    var onUploadProgress: ((LocalUploadServer.UploadTransferSnapshot) -> Void)?
    var onUploadFinished: ((UUID, URL, String) -> Void)?
    var onUploadFailed: ((UUID, String, String) -> Void)?
    var onBooksRequested: (((@escaping APICompletion) -> Void))?
    var onRenameRequested: ((UUID, String, @escaping APICompletion) -> Void)?
    var onDeleteRequested: ((UUID, @escaping APICompletion) -> Void)?
    var onComplete: (() -> Void)?

    private let connection: NWConnection
    private let authConfig: UploadServerAuthConfig
    private var headerData = Data()
    private var uploadFileHandle: FileHandle?
    private var uploadTempURL: URL?
    private var uploadID = UUID()
    private var uploadFilename: String?
    private var uploadStartedAt: Date?
    private var expectedBodyLength: Int64 = 0
    private var receivedBodyLength: Int64 = 0

    init(connection: NWConnection, authConfig: UploadServerAuthConfig) {
        self.connection = connection
        self.authConfig = authConfig
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.finishWithError(error.localizedDescription)
            } else if case .cancelled = state {
                self?.cleanup()
            }
        }
        connection.start(queue: queue)
        receiveHeader()
    }

    func cancel() {
        connection.cancel()
        cleanup()
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                finishWithError(error.localizedDescription)
                return
            }

            if let data, !data.isEmpty {
                headerData.append(data)
                if let range = headerData.range(of: Data("\r\n\r\n".utf8)) {
                    let header = headerData[..<range.lowerBound]
                    let bodyStart = range.upperBound
                    let initialBody = headerData[bodyStart...]
                    handleRequest(headerData: Data(header), initialBody: Data(initialBody))
                    return
                }
            }

            if isComplete {
                finishWithHTTP(status: 400, body: "Bad Request")
            } else {
                receiveHeader()
            }
        }
    }

    private func handleRequest(headerData: Data, initialBody: Data) {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            finishWithHTTP(status: 400, body: "Bad Request")
            return
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            finishWithHTTP(status: 400, body: "Bad Request")
            return
        }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            finishWithHTTP(status: 400, body: "Bad Request")
            return
        }

        let method = requestParts[0].uppercased()
        let target = requestParts[1]
        let headers = parseHeaders(lines.dropFirst())

        // Auth: POST /api/auth is the one unauthenticated route (besides the
        // login page served below). Everything else requires a valid token when
        // a password is configured.
        if method == "POST", target == "/api/auth" {
            handleAuthRequest(headers: headers)
            return
        }

        // GET / is always served — it contains both the login card and the
        // upload UI; the page itself decides which to show based on the token
        // stored in sessionStorage.  All data-bearing routes still require a
        // valid token via X-EPUBPlayer-Token.
        if method == "GET" || method == "HEAD", target == "/" {
            finishWithHTML(uploadPageHTML)
            return
        }

        let token = headers["x-epubplayer-token"]
        if !authConfig.isAuthorized(token: token) {
            finishWithHTTP(status: 401, body: "Unauthorized")
            return
        }

        if method == "GET" || method == "HEAD", target == "/api/books" {
            requestBooks()
            return
        }

        if method == "POST", let renameRequest = renameRequest(from: target) {
            requestRename(bookId: renameRequest.bookId, filename: renameRequest.filename)
            return
        }

        if method == "DELETE", let bookId = deleteBookId(from: target) {
            requestDelete(bookId: bookId)
            return
        }

        guard target.hasPrefix("/upload") else {
            finishWithHTTP(status: 404, body: "Not Found")
            return
        }

        guard method == "POST" else {
            finishWithHTTP(status: 405, body: "Method Not Allowed")
            return
        }

        guard headers["transfer-encoding"]?.lowercased() != "chunked" else {
            finishWithHTTP(status: 411, body: "Chunked uploads are not supported")
            return
        }

        guard let lengthText = headers["content-length"], let contentLength = Int64(lengthText), contentLength >= 0 else {
            finishWithHTTP(status: 411, body: "Content-Length is required")
            return
        }

        guard let filename = filename(from: target), UploadFileKind(filename: filename) != nil else {
            finishWithHTTP(status: 415, body: "Only .epub, .ttf, and .otf uploads are supported")
            return
        }

        do {
            try beginUpload(filename: filename, contentLength: contentLength)
            try writeBody(initialBody)
        } catch {
            finishWithError(error.localizedDescription)
            return
        }

        if receivedBodyLength >= expectedBodyLength {
            finishUpload()
        } else {
            receiveBody()
        }
    }

    private func handleAuthRequest(headers: [String: String]) {
        guard authConfig.requiresPassword else {
            // No password configured — any request succeeds and returns an
            // empty token (the client will include it but the server ignores it).
            let payload = Data("{\"token\":\"\"}".utf8)
            finishWithJSON(payload)
            return
        }

        let provided = headers["x-epubplayer-password"] ?? ""
        guard provided == authConfig.password else {
            finishWithHTTP(status: 401, body: "Incorrect password")
            return
        }

        let tokenJSON = "{\"token\":\"\(authConfig.sessionToken)\"}"
        finishWithJSON(Data(tokenJSON.utf8))
    }

    private func requestBooks() {
        performLibraryRequest(unavailableMessage: "Book listing is not available") { completion in
            onBooksRequested?(completion)
        }
    }

    private func requestRename(bookId: UUID, filename: String) {
        performLibraryRequest(unavailableMessage: "Rename is not available") { completion in
            onRenameRequested?(bookId, filename, completion)
        }
    }

    private func requestDelete(bookId: UUID) {
        performLibraryRequest(unavailableMessage: "Delete is not available") { completion in
            onDeleteRequested?(bookId, completion)
        }
    }

    // One place owns the API response policy: JSON on success, 400 on
    // failure, 500 when no handler is wired up (invoke returns nil then).
    private func performLibraryRequest(
        unavailableMessage: String,
        invoke: (@escaping APICompletion) -> Void?
    ) {
        let completion: APICompletion = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                self.finishWithJSON(data)
            case .failure(let error):
                self.finishWithHTTP(status: 400, body: error.localizedDescription)
            }
        }

        guard invoke(completion) != nil else {
            finishWithHTTP(status: 500, body: unavailableMessage)
            return
        }
    }

    private func receiveBody() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                finishWithError(error.localizedDescription)
                return
            }

            do {
                if let data, !data.isEmpty {
                    try writeBody(data)
                }
            } catch {
                finishWithError(error.localizedDescription)
                return
            }

            if receivedBodyLength >= expectedBodyLength {
                finishUpload()
            } else if isComplete {
                finishWithHTTP(status: 400, body: "Upload ended before all bytes were received")
            } else {
                receiveBody()
            }
        }
    }

    private func beginUpload(filename: String, contentLength: Int64) throws {
        let uploadsDirectory = try AppStorage.uploadsDirectory()
        let tempURL = AppStorage.uniqueFileURL(named: ".upload-\(UUID().uuidString)-\(filename)", in: uploadsDirectory)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        uploadFileHandle = try FileHandle(forWritingTo: tempURL)
        uploadTempURL = tempURL
        uploadID = UUID()
        uploadFilename = filename
        uploadStartedAt = Date()
        expectedBodyLength = contentLength
        receivedBodyLength = 0

        if let snapshot = currentUploadSnapshot() {
            onUploadStarted?(snapshot)
        }
    }

    private func writeBody(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let remaining = expectedBodyLength - receivedBodyLength
        guard remaining > 0 else { return }

        let dataToWrite: Data
        if Int64(data.count) > remaining {
            dataToWrite = data.prefix(Int(remaining))
        } else {
            dataToWrite = data
        }

        try uploadFileHandle?.write(contentsOf: dataToWrite)
        receivedBodyLength += Int64(dataToWrite.count)

        if let snapshot = currentUploadSnapshot() {
            onUploadProgress?(snapshot)
        }
    }

    private func finishUpload() {
        do {
            try uploadFileHandle?.close()
            uploadFileHandle = nil

            guard let uploadTempURL, let uploadFilename else {
                finishWithHTTP(status: 500, body: "Upload state was lost")
                return
            }

            let uploadsDirectory = try AppStorage.uploadsDirectory()
            let finalURL = AppStorage.uniqueFileURL(named: uploadFilename, in: uploadsDirectory)
            try FileManager.default.moveItem(at: uploadTempURL, to: finalURL)
            self.uploadTempURL = nil
            if let snapshot = currentUploadSnapshot() {
                onUploadProgress?(snapshot)
            }
            onUploadFinished?(uploadID, finalURL, uploadFilename)
            finishWithHTTP(status: 200, body: "Uploaded \(uploadFilename)")
        } catch {
            finishWithError(error.localizedDescription)
        }
    }

    private func finishWithHTML(_ html: String) {
        finish(status: 200, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    private func finishWithJSON(_ data: Data) {
        finish(status: 200, contentType: "application/json; charset=utf-8", body: data)
    }

    private func finishWithHTTP(status: Int, body: String) {
        finish(status: status, contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
    }

    private func finish(status: Int, contentType: String, body: Data) {
        let reason = reasonPhrase(for: status)
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            self?.cleanup()
        })
    }

    private func finishWithError(_ message: String) {
        if let snapshot = currentUploadSnapshot() {
            onUploadFailed?(snapshot.id, snapshot.filename, message)
        }
        try? uploadFileHandle?.close()
        uploadFileHandle = nil
        if let uploadTempURL {
            try? FileManager.default.removeItem(at: uploadTempURL)
        }
        finishWithHTTP(status: 500, body: message)
    }

    private func cleanup() {
        try? uploadFileHandle?.close()
        uploadFileHandle = nil
        // A temp URL still set here means the upload never completed (the
        // success path nils it after moving the file); delete the partial.
        if let uploadTempURL {
            try? FileManager.default.removeItem(at: uploadTempURL)
        }
        uploadTempURL = nil
        uploadFilename = nil
        uploadStartedAt = nil
        expectedBodyLength = 0
        receivedBodyLength = 0
        onComplete?()
    }

    private func currentUploadSnapshot() -> LocalUploadServer.UploadTransferSnapshot? {
        guard let uploadFilename, let uploadStartedAt else {
            return nil
        }

        return LocalUploadServer.UploadTransferSnapshot(
            id: uploadID,
            filename: uploadFilename,
            receivedBytes: receivedBodyLength,
            totalBytes: expectedBodyLength,
            startedAt: uploadStartedAt
        )
    }

    private func parseHeaders(_ lines: ArraySlice<String>) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return headers
    }

    private func filename(from target: String) -> String? {
        guard let components = URLComponents(string: "http://localhost\(target)"), components.path == "/upload" else {
            return nil
        }
        return components.queryItems?
            .first(where: { $0.name == "filename" })?
            .value
            .map(AppStorage.sanitizedFilename)
    }

    private func renameRequest(from target: String) -> (bookId: UUID, filename: String)? {
        guard let components = URLComponents(string: "http://localhost\(target)") else {
            return nil
        }

        let pathParts = components.path.split(separator: "/").map(String.init)
        guard pathParts.count == 4,
              pathParts[0] == "api",
              pathParts[1] == "books",
              pathParts[3] == "rename",
              let bookId = UUID(uuidString: pathParts[2]),
              let filename = components.queryItems?.first(where: { $0.name == "filename" })?.value
        else {
            return nil
        }

        return (bookId, filename)
    }

    private func deleteBookId(from target: String) -> UUID? {
        guard let components = URLComponents(string: "http://localhost\(target)") else {
            return nil
        }

        let pathParts = components.path.split(separator: "/").map(String.init)
        guard pathParts.count == 3,
              pathParts[0] == "api",
              pathParts[1] == "books"
        else {
            return nil
        }

        return UUID(uuidString: pathParts[2])
    }

    private func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 415: "Unsupported Media Type"
        case 500: "Internal Server Error"
        default: "HTTP Response"
        }
    }

    private var uploadPageHTML: String {
        let requiresPasswordLiteral = authConfig.requiresPassword ? "true" : "false"
        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>EPUB Player Files</title>
          <style>
            :root { color-scheme: light; }
            * { box-sizing: border-box; }
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; min-height: 100vh; background: #f5f1e8; color: #211a12; }
            /* Login view */
            #login-view { display: none; min-height: 100vh; align-items: center; justify-content: center; }
            #login-view.visible { display: flex; }
            .login-card { background: white; border-radius: 24px; padding: 32px 28px; box-shadow: 0 24px 80px rgba(60,38,15,.14); width: min(380px, calc(100vw - 32px)); }
            .login-card h1 { margin: 0 0 6px; font-size: 26px; letter-spacing: -.03em; }
            .login-card p { color: #6b6258; line-height: 1.5; margin: 0 0 20px; font-size: 15px; }
            .login-card label { display: block; font-weight: 700; margin-bottom: 6px; font-size: 15px; }
            .login-card input { width: 100%; border: 1.5px solid #d8c7ad; border-radius: 10px; padding: 10px 12px; font-size: 17px; outline: none; background: #fffaf1; }
            .login-card input:focus { border-color: #1e5bff; }
            .login-card button { margin-top: 14px; width: 100%; border: 0; border-radius: 999px; padding: 12px; background: #1e5bff; color: white; font-weight: 700; font-size: 16px; cursor: pointer; }
            .login-card button:disabled { opacity: .45; cursor: not-allowed; }
            #login-error { margin-top: 12px; color: #c93528; font-weight: 700; min-height: 20px; font-size: 14px; }
            /* App view */
            #app-view { display: none; }
            #app-view.visible { display: block; }
            main { width: min(980px, calc(100vw - 32px)); margin: 32px auto; }
            header { margin-bottom: 22px; }
            h1 { margin: 0 0 8px; font-size: clamp(32px, 7vw, 56px); letter-spacing: -.04em; }
            h2 { margin: 0 0 14px; font-size: 22px; }
            p { color: #6b6258; line-height: 1.5; }
            section { background: white; border-radius: 24px; padding: 24px; box-shadow: 0 24px 80px rgba(60, 38, 15, .14); margin-bottom: 18px; }
            .page-drop-overlay { position: fixed; inset: 16px; border-radius: 28px; border: 3px dashed #1e5bff; background: rgba(30, 91, 255, .08); color: #1c3d92; display: none; align-items: center; justify-content: center; text-align: center; padding: 24px; font-size: clamp(22px, 4vw, 34px); font-weight: 800; letter-spacing: -.03em; pointer-events: none; z-index: 10; }
            body.drag-active .page-drop-overlay { display: flex; }
            body.drag-active .drop { border-color: #1e5bff; background: #eef4ff; box-shadow: inset 0 0 0 1px rgba(30, 91, 255, .12); }
            .drop { border: 2px dashed #b88a44; border-radius: 18px; padding: 26px; text-align: center; background: #fffaf1; transition: background .15s ease, border-color .15s ease, box-shadow .15s ease; }
            input { max-width: 100%; }
            button { border: 0; border-radius: 999px; padding: 10px 14px; background: #1e5bff; color: white; font-weight: 700; cursor: pointer; }
            button.secondary { background: #eadfce; color: #33261a; }
            button.danger { background: #c93528; }
            button:disabled { opacity: .45; cursor: not-allowed; }
            #status { min-height: 24px; margin-top: 14px; font-weight: 700; }
            #status.error { color: #c93528; }
            #status.success { color: #20764c; }
            .queue { display: grid; gap: 12px; margin-top: 18px; }
            .upload-item { border: 1px solid #eee4d3; border-radius: 18px; padding: 16px; background: #fffdf8; }
            .upload-head { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; }
            .upload-item .title { font-weight: 800; font-size: 17px; overflow-wrap: anywhere; }
            .badge { display: inline-flex; align-items: center; justify-content: center; border-radius: 999px; padding: 6px 10px; font-size: 12px; font-weight: 800; white-space: nowrap; }
            .badge.queued { background: #eadfce; color: #5e4a33; }
            .badge.uploading { background: #dce7ff; color: #1c3d92; }
            .badge.done { background: #dff3e8; color: #20764c; }
            .badge.failed { background: #fde4e1; color: #c93528; }
            .progress-track { margin-top: 12px; height: 10px; border-radius: 999px; overflow: hidden; background: #efe5d7; }
            .progress-fill { height: 100%; width: 0; background: linear-gradient(90deg, #6a40ff, #1e5bff); transition: width .12s linear; }
            .upload-item.failed .progress-fill { background: #c93528; }
            .error-text { color: #c93528; }
            .toolbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
            .books { display: grid; gap: 12px; }
            .book { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 16px; align-items: center; padding: 16px; border: 1px solid #eee4d3; border-radius: 18px; background: #fffdf8; }
            .title { font-weight: 800; font-size: 17px; }
            .meta { margin-top: 4px; color: #786f66; font-size: 13px; overflow-wrap: anywhere; }
            .actions { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
            .empty { color: #786f66; padding: 18px; border: 1px dashed #d8c7ad; border-radius: 18px; background: #fffaf1; }
            @media (max-width: 640px) {
              main { width: min(100vw - 20px, 980px); margin: 18px auto; }
              section { padding: 18px; border-radius: 20px; }
              .book { grid-template-columns: 1fr; }
              .actions { justify-content: flex-start; }
            }
          </style>
        </head>
        <body>
          <!-- Login view (shown when password is required and not yet authenticated) -->
          <div id="login-view">
            <div class="login-card">
              <h1>EPUB Player Files</h1>
              <p>This server is password-protected. Enter the password set in the EPUB Player app to continue.</p>
              <label for="password-input">Password</label>
              <input id="password-input" type="password" autocomplete="current-password">
              <button id="login-submit">Connect</button>
              <div id="login-error"></div>
            </div>
          </div>

          <!-- App view (shown when authenticated or no password required) -->
          <div id="app-view">
            <div class="page-drop-overlay">Drop EPUB or font files to start uploading</div>
            <main>
              <header>
                <h1>EPUB Player Files</h1>
                <p>Upload EPUB books or custom font files. Keep EPUB Player open while managing files.</p>
              </header>

              <section>
                <h2>Upload Files</h2>
                <div class="drop" id="drop-zone">
                  <strong>Drop .epub, .ttf, or .otf files anywhere on this page</strong>
                  <p>EPUBs are imported into your library. Fonts are imported into Reader &gt; Custom Fonts.</p>
                  <input id="file" type="file" accept=".epub,.ttf,.otf,application/epub+zip,font/ttf,font/otf,font/sfnt" multiple>
                  <div id="status"></div>
                </div>
                <div id="queue" class="queue">
                  <div class="empty">No uploads queued yet.</div>
                </div>
              </section>

              <section>
                <div class="toolbar">
                  <h2>Files on iPhone</h2>
                  <button class="secondary" id="refresh">Refresh</button>
                </div>
                <div id="books" class="books"></div>
              </section>
            </main>
          </div>

          <script>
            const REQUIRES_PASSWORD = \(requiresPasswordLiteral);

            // View switching — no page reloads needed.
            function showLogin() {
              document.getElementById('login-view').classList.add('visible');
              document.getElementById('app-view').classList.remove('visible');
              const input = document.getElementById('password-input');
              input.value = '';
              document.getElementById('login-error').textContent = '';
              input.focus();
            }

            function showApp() {
              document.getElementById('login-view').classList.remove('visible');
              document.getElementById('app-view').classList.add('visible');
            }

            // Token helpers.
            function getToken() {
              return sessionStorage.getItem('epubplayer-token') || '';
            }

            // Called when a data request receives 401 (stale/invalid token).
            function handleUnauthorized() {
              sessionStorage.removeItem('epubplayer-token');
              if (REQUIRES_PASSWORD) {
                showLogin();
              }
            }

            // Login form.
            const loginSubmit = document.getElementById('login-submit');
            const passwordInput = document.getElementById('password-input');
            const loginError = document.getElementById('login-error');

            async function attemptLogin() {
              const password = passwordInput.value;
              if (!password) {
                loginError.textContent = 'Enter a password.';
                return;
              }

              loginSubmit.disabled = true;
              loginError.textContent = '';

              try {
                const response = await fetch('/api/auth', {
                  method: 'POST',
                  headers: { 'X-EPUBPlayer-Password': password }
                });
                if (response.ok) {
                  const payload = await response.json();
                  sessionStorage.setItem('epubplayer-token', payload.token || '');
                  showApp();
                  renderQueue();
                  loadBooks();
                } else {
                  loginError.textContent = 'Incorrect password. Try again.';
                  passwordInput.select();
                }
              } catch {
                loginError.textContent = 'Could not reach the server. Make sure the app is open.';
              } finally {
                loginSubmit.disabled = false;
              }
            }

            loginSubmit.addEventListener('click', attemptLogin);
            passwordInput.addEventListener('keydown', event => {
              if (event.key === 'Enter') attemptLogin();
            });

            // App state.
            const input = document.getElementById('file');
            const refresh = document.getElementById('refresh');
            const queue = document.getElementById('queue');
            const status = document.getElementById('status');
            const books = document.getElementById('books');
            const queueItems = [];
            let nextQueueID = 1;
            let isUploading = false;
            let dragDepth = 0;

            function setStatus(message, type = '') {
              status.textContent = message;
              status.className = type;
            }

            function escapeHTML(value) {
              return String(value).replace(/[&<>'"]/g, character => ({
                '&': '&amp;',
                '<': '&lt;',
                '>': '&gt;',
                "'": '&#39;',
                '"': '&quot;'
              }[character]));
            }

            function formatBytes(bytes) {
              const numericBytes = Math.max(0, Number(bytes) || 0);
              if (!numericBytes) return '0 B';
              const units = ['B', 'KB', 'MB', 'GB'];
              let value = numericBytes;
              let unit = 0;
              while (value >= 1024 && unit < units.length - 1) {
                value /= 1024;
                unit += 1;
              }
              return `${value.toFixed(value >= 10 || unit === 0 ? 0 : 1)} ${units[unit]}`;
            }

            function formatSpeed(bytesPerSecond) {
              return `${formatBytes(bytesPerSecond)}/s`;
            }

            function progressValue(item) {
              const totalBytes = item.totalBytes || item.size || 0;
              if (!totalBytes) return item.status === 'done' ? 1 : 0;
              return Math.min(Math.max(item.uploadedBytes / totalBytes, 0), 1);
            }

            function statusLabel(item) {
              switch (item.status) {
                case 'queued': return 'Queued';
                case 'uploading': return `Uploading ${Math.round(progressValue(item) * 100)}%`;
                case 'done': return 'Uploaded';
                case 'failed': return 'Failed';
                default: return item.status;
              }
            }

            function renderQueue() {
              if (!queueItems.length) {
                queue.innerHTML = '<div class="empty">No uploads queued yet.</div>';
                return;
              }

              queue.innerHTML = queueItems.map(item => {
                const totalBytes = item.totalBytes || item.size || 0;
                const details = [];
                details.push(statusLabel(item));

                if (item.status === 'queued') {
                  details.push(formatBytes(item.size));
                } else if (totalBytes || item.uploadedBytes) {
                  details.push(`${formatBytes(item.uploadedBytes)} / ${formatBytes(totalBytes)}`);
                }

                if (item.status === 'uploading') {
                  details.push(formatSpeed(item.speedBytesPerSecond));
                }

                return `
                  <article class="upload-item ${escapeHTML(item.status)}">
                    <div class="upload-head">
                      <div>
                        <div class="title">${escapeHTML(item.name)}</div>
                        <div class="meta">${details.map(escapeHTML).join(' &middot; ')}</div>
                      </div>
                      <span class="badge ${escapeHTML(item.status)}">${escapeHTML(statusLabel(item))}</span>
                    </div>
                    <div class="progress-track" aria-hidden="true">
                      <div class="progress-fill" style="width: ${Math.round(progressValue(item) * 100)}%"></div>
                    </div>
                    ${item.message ? `<div class="meta ${item.status === 'failed' ? 'error-text' : ''}">${escapeHTML(item.message)}</div>` : ''}
                  </article>
                `;
              }).join('');
            }

            function enqueueFiles(fileList) {
              const files = Array.from(fileList || []);
              if (!files.length) return;

              let queuedCount = 0;
              let rejectedCount = 0;

              files.forEach(file => {
                const kind = supportedUploadKind(file.name);
                if (!kind) {
                  rejectedCount += 1;
                  queueItems.push({
                    id: `upload-${nextQueueID++}`,
                    file: null,
                    name: file.name,
                    size: file.size || 0,
                    uploadedBytes: 0,
                    totalBytes: file.size || 0,
                    speedBytesPerSecond: 0,
                    status: 'failed',
                    message: 'Only .epub, .ttf, and .otf files are supported.'
                  });
                  return;
                }

                queuedCount += 1;
                queueItems.push({
                  id: `upload-${nextQueueID++}`,
                  file,
                  kind,
                  name: file.name,
                  size: file.size || 0,
                  uploadedBytes: 0,
                  totalBytes: file.size || 0,
                  speedBytesPerSecond: 0,
                  status: 'queued',
                  message: 'Queued for upload.'
                });
              });

              renderQueue();

              if (queuedCount && rejectedCount) {
                setStatus(`${queuedCount} file${queuedCount === 1 ? '' : 's'} queued. ${rejectedCount} skipped.`, 'error');
              } else if (queuedCount) {
                setStatus(`${queuedCount} file${queuedCount === 1 ? '' : 's'} queued for upload.`, 'success');
              } else if (rejectedCount) {
                setStatus(`Only .epub, .ttf, and .otf files are supported. ${rejectedCount} skipped.`, 'error');
              }

              processQueue();
            }

            async function processQueue() {
              if (isUploading) return;

              isUploading = true;
              try {
                let nextItem = queueItems.find(item => item.status === 'queued');
                while (nextItem) {
                  await uploadFile(nextItem);
                  nextItem = queueItems.find(item => item.status === 'queued');
                }
              } finally {
                isUploading = false;
                renderQueue();
              }
            }

            function uploadFile(item) {
              return new Promise(resolve => {
                item.status = 'uploading';
                item.uploadedBytes = 0;
                item.totalBytes = item.size || item.totalBytes;
                item.speedBytesPerSecond = 0;
                item.message = 'Uploading now...';
                item.startedAt = performance.now();
                renderQueue();

                const request = new XMLHttpRequest();
                request.open('POST', '/upload?filename=' + encodeURIComponent(item.name));
                request.setRequestHeader('Content-Type', contentTypeForKind(item.kind));
                request.setRequestHeader('X-EPUBPlayer-Token', getToken());

                request.upload.onprogress = event => {
                  item.uploadedBytes = event.loaded || 0;
                  if (event.lengthComputable && event.total) {
                    item.totalBytes = event.total;
                  }

                  const elapsedSeconds = Math.max((performance.now() - item.startedAt) / 1000, 0.001);
                  item.speedBytesPerSecond = item.uploadedBytes / elapsedSeconds;
                  item.message = `${Math.round(progressValue(item) * 100)}% uploaded.`;
                  renderQueue();
                };

                request.onload = async () => {
                  item.speedBytesPerSecond = 0;
                  item.uploadedBytes = item.totalBytes || item.size || item.uploadedBytes;

                  if (request.status === 401) {
                    handleUnauthorized();
                    resolve();
                    return;
                  }

                  if (request.status >= 200 && request.status < 300) {
                    item.status = 'done';
                    item.message = request.responseText || 'Uploaded.';
                    item.file = null;
                    setStatus(`Uploaded ${item.name}.`, 'success');
                    renderQueue();

                    if (item.kind === 'book') {
                      try {
                        await new Promise(resolveDelay => setTimeout(resolveDelay, 200));
                        await loadBooks();
                      } catch (error) {
                        setStatus(`Uploaded ${item.name}, but could not refresh files: ${error.message}`, 'error');
                      }
                    }
                  } else {
                    item.status = 'failed';
                    item.message = request.responseText || `Upload failed (${request.status}).`;
                    item.file = null;
                    setStatus(`Upload failed for ${item.name}: ${item.message}`, 'error');
                    renderQueue();
                  }

                  resolve();
                };

                request.onerror = () => {
                  item.speedBytesPerSecond = 0;
                  item.status = 'failed';
                  item.message = 'Network error while uploading.';
                  item.file = null;
                  setStatus(`Upload failed for ${item.name}: ${item.message}`, 'error');
                  renderQueue();
                  resolve();
                };

                request.onabort = () => {
                  item.speedBytesPerSecond = 0;
                  item.status = 'failed';
                  item.message = 'Upload was canceled.';
                  item.file = null;
                  setStatus(`Upload canceled for ${item.name}.`, 'error');
                  renderQueue();
                  resolve();
                };

                request.send(item.file);
              });
            }

            function supportedUploadKind(filename) {
              const lowercasedName = String(filename || '').toLowerCase();
              if (lowercasedName.endsWith('.epub')) return 'book';
              if (lowercasedName.endsWith('.ttf') || lowercasedName.endsWith('.otf')) return 'font';
              return null;
            }

            function contentTypeForKind(kind) {
              if (kind === 'font') {
                return 'font/sfnt';
              }
              return 'application/epub+zip';
            }

            function dragContainsFiles(event) {
              return Array.from(event.dataTransfer?.types || []).includes('Files');
            }

            function activateDragState() {
              document.body.classList.add('drag-active');
            }

            function clearDragState() {
              dragDepth = 0;
              document.body.classList.remove('drag-active');
            }

            async function requestText(url, options = {}) {
              const mergedHeaders = Object.assign({ 'X-EPUBPlayer-Token': getToken() }, options.headers || {});
              const response = await fetch(url, Object.assign({}, options, { headers: mergedHeaders }));
              if (response.status === 401) {
                handleUnauthorized();
                throw new Error('Session expired. Please reconnect.');
              }
              if (!response.ok) {
                throw new Error(await response.text());
              }
              return response;
            }

            async function loadBooks() {
              books.innerHTML = '<div class="empty">Loading files...</div>';
              try {
                const response = await requestText('/api/books');
                const payload = await response.json();
                renderBooks(payload.books || []);
              } catch (error) {
                books.innerHTML = `<div class="empty">Could not load files: ${escapeHTML(error.message)}</div>`;
              }
            }

            function renderBooks(items) {
              if (!items.length) {
                books.innerHTML = '<div class="empty">No EPUB files are imported yet.</div>';
                return;
              }

              books.innerHTML = items.map(book => `
                <article class="book" data-id="${escapeHTML(book.id)}" data-filename="${escapeHTML(book.filename)}">
                  <div>
                    <div class="title">${escapeHTML(book.title)}</div>
                  <div class="meta">${escapeHTML(book.filename)} &middot; ${formatBytes(book.fileSize)}${book.hasMediaOverlay ? ` &middot; Read-aloud ready (${book.mediaOverlayClipCount} clips)` : ''}</div>
                  </div>
                  <div class="actions">
                    <button class="secondary" data-action="rename">Rename</button>
                    <button class="danger" data-action="delete">Delete</button>
                  </div>
                </article>
              `).join('');
            }

            books.onclick = async event => {
              const action = event.target.dataset.action;
              if (!action) return;

              const row = event.target.closest('.book');
              const id = row.dataset.id;
              const currentFilename = row.dataset.filename;

              try {
                if (action === 'rename') {
                  const filename = prompt('Rename EPUB file:', currentFilename);
                  if (!filename) return;
                  const response = await requestText(`/api/books/${encodeURIComponent(id)}/rename?filename=${encodeURIComponent(filename)}`, { method: 'POST' });
                  const payload = await response.json();
                  renderBooks(payload.books || []);
                  setStatus('Renamed file.', 'success');
                }

                if (action === 'delete') {
                  if (!confirm(`Delete ${currentFilename} from this iPhone?`)) return;
                  const response = await requestText(`/api/books/${encodeURIComponent(id)}`, { method: 'DELETE' });
                  const payload = await response.json();
                  renderBooks(payload.books || []);
                  setStatus('Deleted file.', 'success');
                }
              } catch (error) {
                setStatus(error.message, 'error');
              }
            };

            input.onchange = () => {
              enqueueFiles(input.files);
              input.value = '';
            };

            document.addEventListener('dragenter', event => {
              if (!dragContainsFiles(event)) return;
              event.preventDefault();
              dragDepth += 1;
              activateDragState();
            });

            document.addEventListener('dragover', event => {
              if (!dragContainsFiles(event)) return;
              event.preventDefault();
              event.dataTransfer.dropEffect = 'copy';
              activateDragState();
            });

            document.addEventListener('dragleave', event => {
              if (!dragContainsFiles(event)) return;
              event.preventDefault();
              dragDepth = Math.max(dragDepth - 1, 0);
              if (dragDepth === 0) {
                document.body.classList.remove('drag-active');
              }
            });

            document.addEventListener('drop', event => {
              if (!dragContainsFiles(event)) return;
              event.preventDefault();
              clearDragState();
              enqueueFiles(event.dataTransfer.files);
            });

            refresh.onclick = loadBooks;

            // Initial view selection.
            if (REQUIRES_PASSWORD && !getToken()) {
              showLogin();
            } else {
              showApp();
              renderQueue();
              loadBooks();
            }
          </script>
        </body>
        </html>
        """
    }

}
