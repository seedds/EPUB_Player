//
//  TestDocumentsDirectory.swift
//  EPUB PlayerTests
//

import Darwin
import Foundation

enum TestDocumentsDirectory {
    private static let environmentKey = "EPUBPLAYER_DOCUMENTS_DIRECTORY"

    static func activate() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        setenv(environmentKey, rootURL.path, 1)
        return rootURL
    }

    static func deactivate(rootURL: URL?) {
        unsetenv(environmentKey)

        guard let rootURL else {
            return
        }

        try? FileManager.default.removeItem(at: rootURL)
    }
}
