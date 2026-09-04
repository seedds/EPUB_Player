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
    case invalidStoredFilePath(storedPath: String)
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

    /// The covers directory URL *without* creating it. Read paths (resolving a
    /// stored cover URL) run per visible library row per `body` pass; forcing a
    /// `createDirectory` syscall there was a per-row main-thread cost.
    nonisolated static func coversDirectoryURL() throws -> URL {
        try documentsDirectoryURL()
            .appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("Covers", isDirectory: true)
    }

    /// The documents directory URL without creating it (release build).
    private nonisolated static func documentsDirectoryURL() throws -> URL {
        #if DEBUG
        if let overridePath = ProcessInfo.processInfo.environment["EPUBPLAYER_DOCUMENTS_DIRECTORY"],
           !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath, isDirectory: true)
        }
        #endif

        return try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
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

    /// Deletes files in `directory` whose name starts with `prefix`. When
    /// `olderThan` is given, only files last modified before that date are
    /// removed (and files with no readable modification date are treated as
    /// stale); when nil, every matching file is removed. One implementation for
    /// the import-staging and upload-staging sweeps.
    nonisolated static func sweepStagingFiles(in directory: URL, prefix: String, olderThan cutoff: Date? = nil) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: cutoff == nil ? nil : [.contentModificationDateKey],
            options: []
        ) else {
            return
        }

        for fileURL in contents where fileURL.lastPathComponent.hasPrefix(prefix) {
            if let cutoff {
                let modifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard modifiedAt == nil || modifiedAt! < cutoff else {
                    continue
                }
            }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    nonisolated static func bookFileURL(storedPath: String) throws -> URL {
        let components = storedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.contains(where: { $0 == "." || $0 == ".." }) {
            throw AppStorageError.pathEscapesBaseDirectory(storedPath: storedPath)
        }
        guard components.count == 2,
              components[0] == booksDirectoryName,
              isValidStoredFilename(components[1], extensions: ["epub"])
        else {
            throw AppStorageError.invalidStoredFilePath(storedPath: storedPath)
        }

        return try validatedStoredFileURL(
            base: booksDirectory(),
            storedFilename: components[1],
            originalStoredPath: storedPath
        )
    }

    nonisolated static func customFontFileURL(storedFilename: String) throws -> URL {
        let stem = URL(fileURLWithPath: storedFilename).deletingPathExtension().lastPathComponent
        guard isValidStoredFilename(storedFilename, extensions: ["ttf", "otf"]), UUID(uuidString: stem) != nil else {
            throw AppStorageError.invalidStoredFilePath(storedPath: storedFilename)
        }

        return try validatedStoredFileURL(
            base: customFontsDirectory(),
            storedFilename: storedFilename,
            originalStoredPath: storedFilename
        )
    }

    /// Joins a stored, potentially attacker-controlled relative path onto a
    /// trusted base directory, rejecting any `.`/`..` traversal and verifying
    /// the resolved URL stays inside `base`. `state.json` is user-editable via
    /// the Files app, so stored paths must never be trusted to stay contained.
    nonisolated static func containedFileURL(base: URL, storedPath: String) throws -> URL {
        let pathComponents = storedPath.split(separator: "/").map(String.init)
        guard !pathComponents.isEmpty else {
            // An empty stored path used to resolve to `base` itself, so callers
            // like `resolvedCoverImageURL` saw the covers *directory* pass
            // `fileExists` and treated it as a valid file. Reject it instead.
            throw AppStorageError.invalidStoredFilePath(storedPath: storedPath)
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

    private nonisolated static func isValidStoredFilename(_ filename: String, extensions: Set<String>) -> Bool {
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              !filename.contains("/"),
              !filename.contains("\\"),
              URL(fileURLWithPath: filename).lastPathComponent == filename,
              extensions.contains(URL(fileURLWithPath: filename).pathExtension.lowercased())
        else {
            return false
        }
        return true
    }

    private nonisolated static func validatedStoredFileURL(
        base: URL,
        storedFilename: String,
        originalStoredPath: String
    ) throws -> URL {
        let fileURL = try containedFileURL(base: base, storedPath: storedFilename)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isDirectory != true, values.isSymbolicLink != true else {
                throw AppStorageError.invalidStoredFilePath(storedPath: originalStoredPath)
            }
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
