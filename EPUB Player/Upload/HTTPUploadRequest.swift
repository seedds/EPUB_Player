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

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            return nil
        }

        return HTTPUploadRequest(
            method: requestParts[0].uppercased(),
            target: requestParts[1],
            headers: parseHeaders(lines.dropFirst())
        )
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

    private static func parseHeaders(_ lines: ArraySlice<String>) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return headers
    }
}
