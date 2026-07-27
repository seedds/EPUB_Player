//
//  AppStorage.swift
//  EPUB Player
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation

enum AppStorageError: Error {
    /// A stored relative path escaped (or tried to escape) its intended base
    /// directory — e.g. via `..` components in an attacker-edited state.json.
    case pathEscapesBaseDirectory(storedPath: String)
}

enum AppStorage {
    nonisolated static func documentsDirectory() throws -> URL {
        #if DEBUG
        // Test-only override so the suite can redirect storage to a temp
        // directory. Never compiled into release builds.
        if let overridePath = ProcessInfo.processInfo.environment["EPUBPLAYER_DOCUMENTS_DIRECTORY"],
           !overridePath.isEmpty {
            return try ensureDirectory(URL(fileURLWithPath: overridePath, isDirectory: true))
        }
        #endif

        return try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private static let booksDirectoryName = "Books"

    nonisolated static func booksDirectory() throws -> URL {
        try ensureDirectory(documentsDirectory().appendingPathComponent(booksDirectoryName, isDirectory: true))
    }

    /// Whether the library directory is present, *without* creating it.
    ///
    /// `booksDirectory()` creates the directory on demand, so callers that need
    /// to distinguish "the library is empty" from "the library directory is
    /// gone" must ask before touching it. Refresh depends on this: an empty
    /// scan of a recreated directory would otherwise look like proof that the
    /// user deleted every book.
    nonisolated static func booksDirectoryExists() -> Bool {
        guard let documentsDirectory = try? documentsDirectory() else {
            return false
        }

        let libraryDirectory = documentsDirectory.appendingPathComponent(booksDirectoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: libraryDirectory.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    nonisolated static func cacheDirectory() throws -> URL {
        try ensureDirectory(documentsDirectory().appendingPathComponent("Cache", isDirectory: true))
    }

    nonisolated static func uploadsDirectory() throws -> URL {
        try ensureDirectory(cacheDirectory().appendingPathComponent("Uploads", isDirectory: true))
    }

    nonisolated static func customFontsDirectory() throws -> URL {
        try ensureDirectory(cacheDirectory().appendingPathComponent("Fonts", isDirectory: true))
    }

    nonisolated static func coversDirectory() throws -> URL {
        try ensureDirectory(cacheDirectory().appendingPathComponent("Covers", isDirectory: true))
    }

    nonisolated static func mediaOverlaysDirectory() throws -> URL {
        try ensureDirectory(cacheDirectory().appendingPathComponent("MediaOverlays", isDirectory: true))
    }

    nonisolated static func audioCacheDirectory() throws -> URL {
        try ensureDirectory(cacheDirectory().appendingPathComponent("AudioCache", isDirectory: true))
    }

    nonisolated static func stateURL() throws -> URL {
        try cacheDirectory().appendingPathComponent("state.json", isDirectory: false)
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

    nonisolated static func storedBookPath(for filename: String) -> String {
        "Books/\(sanitizedFilename(filename))"
    }

    nonisolated static func bookFileURL(storedPath: String) throws -> URL {
        try containedFileURL(base: documentsDirectory(), storedPath: storedPath)
    }

    /// Joins a stored, potentially attacker-controlled relative path onto a
    /// trusted base directory, rejecting any `.`/`..` traversal and verifying
    /// the resolved URL stays inside `base`. `state.json` is user-editable via
    /// the Files app, so stored paths must never be trusted to stay contained.
    nonisolated static func containedFileURL(base: URL, storedPath: String) throws -> URL {
        let pathComponents = storedPath.split(separator: "/").map(String.init)
        guard !pathComponents.isEmpty else {
            return base
        }

        for component in pathComponents where component == "." || component == ".." {
            throw AppStorageError.pathEscapesBaseDirectory(storedPath: storedPath)
        }

        var fileURL = base
        for component in pathComponents.dropLast() {
            fileURL.appendPathComponent(component, isDirectory: true)
        }
        fileURL.appendPathComponent(pathComponents[pathComponents.count - 1], isDirectory: false)

        // Defense in depth: even with component filtering, confirm the resolved
        // path is contained by the base (guards symlink/normalization surprises).
        let resolvedBase = base.standardizedFileURL.path
        let resolved = fileURL.standardizedFileURL.path
        guard resolved == resolvedBase || resolved.hasPrefix(resolvedBase + "/") else {
            throw AppStorageError.pathEscapesBaseDirectory(storedPath: storedPath)
        }

        return fileURL
    }

    nonisolated static func sanitizedFilename(_ filename: String) -> String {
        sanitizedFilenameOrNil(filename) ?? "upload.epub"
    }

    nonisolated static func sanitizedFilenameOrNil(_ filename: String) -> String? {
        let basename = URL(fileURLWithPath: filename).lastPathComponent
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-()[]"))
        let sanitized = basename.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : "-"
        }
        let result = String(sanitized).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
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
