//
//  AppStorage.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation

enum AppStorage {
    nonisolated static func documentsDirectory() throws -> URL {
        try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    nonisolated static func applicationSupportDirectory() throws -> URL {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try ensureDirectory(supportDirectory.appendingPathComponent("Immersive Reader", isDirectory: true))
    }

    nonisolated static func uploadsDirectory() throws -> URL {
        try ensureDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("Immersive Reader", isDirectory: true)
                .appendingPathComponent("Uploads", isDirectory: true)
        )
    }

    nonisolated static func customFontsDirectory() throws -> URL {
        try ensureDirectory(applicationSupportDirectory().appendingPathComponent("CustomFonts", isDirectory: true))
    }

    nonisolated static func coversDirectory() throws -> URL {
        try ensureDirectory(applicationSupportDirectory().appendingPathComponent("Covers", isDirectory: true))
    }

    nonisolated static func mediaOverlaysDirectory() throws -> URL {
        try ensureDirectory(applicationSupportDirectory().appendingPathComponent("MediaOverlays", isDirectory: true))
    }

    nonisolated static func audioCacheDirectory() throws -> URL {
        try ensureDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("Immersive Reader", isDirectory: true)
                .appendingPathComponent("AudioCache", isDirectory: true)
        )
    }

    nonisolated static func customFontsMetadataURL() throws -> URL {
        try applicationSupportDirectory().appendingPathComponent("custom-fonts.json", isDirectory: false)
    }

    nonisolated static func coverImageURL(for bookID: UUID, pathExtension: String) throws -> URL {
        let ext = pathExtension.isEmpty ? "img" : sanitizedFilename(pathExtension).lowercased()
        return try coversDirectory().appendingPathComponent("\(bookID.uuidString).\(ext)", isDirectory: false)
    }

    nonisolated static func mediaOverlayManifestURL(for bookID: UUID) throws -> URL {
        try mediaOverlaysDirectory().appendingPathComponent("\(bookID.uuidString).json", isDirectory: false)
    }

    nonisolated static func audioCacheDirectory(for bookID: UUID) throws -> URL {
        try ensureDirectory(audioCacheDirectory().appendingPathComponent(bookID.uuidString, isDirectory: true))
    }

    nonisolated static func audioCacheFileURL(for bookID: UUID, resourcePath: String) throws -> URL {
        let resourceURL = URL(fileURLWithPath: resourcePath)
        let ext = resourceURL.pathExtension
        let stem = resourceURL.deletingPathExtension().path
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: "\\", with: "__")
        let filename = ext.isEmpty ? sanitizedFilename(stem) : "\(sanitizedFilename(stem)).\(ext)"
        return try audioCacheDirectory(for: bookID).appendingPathComponent(filename, isDirectory: false)
    }

    nonisolated static func bookFileURL(named filename: String) throws -> URL {
        try documentsDirectory().appendingPathComponent(sanitizedFilename(filename), isDirectory: false)
    }

    nonisolated static func sanitizedFilename(_ filename: String) -> String {
        let fallback = "upload.epub"
        let basename = URL(fileURLWithPath: filename).lastPathComponent
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-()[]"))
        let sanitized = basename.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : "-"
        }
        let result = String(sanitized).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }

    nonisolated static func uniqueFileURL(named filename: String, in directory: URL) -> URL {
        let sanitized = sanitizedFilename(filename)
        let base = URL(fileURLWithPath: sanitized).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: sanitized).pathExtension
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent(sanitized)
        var index = 2

        while fileManager.fileExists(atPath: candidate.path) {
            let indexedName = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(indexedName)
            index += 1
        }

        return candidate
    }

    nonisolated static func relativePath(from absolutePath: String, under directoryPath: String) -> String? {
        guard absolutePath.hasPrefix("/"), directoryPath.hasPrefix("/") else {
            return nil
        }

        let absoluteURL = URL(fileURLWithPath: absolutePath).standardizedFileURL
        let directoryURL = URL(fileURLWithPath: directoryPath).standardizedFileURL
        let absolute = absoluteURL.path
        let directory = directoryURL.path

        guard absolute != directory, absolute.hasPrefix(directory + "/") else {
            return nil
        }

        return String(absolute.dropFirst(directory.count + 1))
    }

    nonisolated private static func ensureDirectory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
