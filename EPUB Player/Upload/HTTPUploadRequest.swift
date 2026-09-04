//
//  HTTPUploadRequest.swift
//  EPUB Player
//

import Foundation

struct HTTPUploadRequest {
    let method: String
    let target: String
    let headers: [String: String]

    static func parse(headerData: Data) -> HTTPUploadRequest? {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }

        // Require a well-formed request line: METHOD SP request-target SP
        // HTTP-version. A lenient (>= 2 tokens) parse accepted malformed lines.
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count == 3,
              !requestParts[0].isEmpty,
              !requestParts[1].isEmpty,
              requestParts[2].uppercased().hasPrefix("HTTP/")
        else {
            return nil
        }

        guard let headers = parseHeaders(lines.dropFirst()) else {
            return nil
        }

        return HTTPUploadRequest(
            method: requestParts[0].uppercased(),
            target: requestParts[1],
            headers: headers
        )
    }

    /// The upload endpoint is exactly `/upload`. A prefix match (`hasPrefix`)
    /// treated `/uploadxyz` as an upload target and answered 415 instead of the
    /// correct 404.
    var isUploadTarget: Bool {
        URLComponents(string: "http://localhost\(target)")?.path == "/upload"
    }

    var uploadFilename: String? {
        guard let components = URLComponents(string: "http://localhost\(target)"), components.path == "/upload" else {
            return nil
        }
        return components.queryItems?
            .first(where: { $0.name == "filename" })?
            .value
            .map(AppStorage.sanitizedFilename)
    }

    var renameRequest: (bookId: UUID, filename: String)? {
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

    var deleteBookID: UUID? {
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

    /// Returns nil for a request that must be rejected — currently a duplicate
    /// `Content-Length` (RFC 7230 request-smuggling hardening). A later
    /// duplicate would otherwise silently overwrite the first.
    private static func parseHeaders(_ lines: ArraySlice<String>) -> [String: String]? {
        var headers: [String: String] = [:]
        for line in lines {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "content-length", headers[name] != nil {
                return nil
            }
            headers[name] = value
        }
        return headers
    }
}
