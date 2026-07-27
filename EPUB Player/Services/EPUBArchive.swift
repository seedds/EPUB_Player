//
//  EPUBArchive.swift
//  EPUB Player
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation
import ReadiumZIPFoundation

enum EPUBArchiveError: LocalizedError {
    case invalidArchive
    case invalidEPUB
    case unsafePath(String)
    case corruptEntry(String)
    case writeFailed(String)
    case entryTooLarge(String)
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            "The file is not a valid ZIP archive."
        case .invalidEPUB:
            "The file is not a valid EPUB package."
        case .unsafePath(let path):
            "The EPUB contains an unsafe file path: \(path)."
        case .corruptEntry(let path):
            "The EPUB contains a corrupt ZIP entry: \(path)."
        case .writeFailed(let path):
            "Could not extract EPUB entry: \(path)."
        case .entryTooLarge(let path):
            "The EPUB contains an unreasonably large file: \(path)."
        case .archiveTooLarge:
            "The EPUB expands to more content than this app will extract."
        }
    }
}

/// Thin EPUB-aware wrapper over ZIPFoundation. Entries are read on demand
/// from disk instead of loading the whole archive into memory.
struct EPUBArchive {
    /// Ceiling on a single entry read fully into memory by `data(for:)`. The
    /// largest thing read this way is an audio clip for the media-overlay
    /// cache; 256 MB is far above any real one, and low enough that a
    /// compression bomb cannot exhaust RAM.
    static let maxEntryBytes: UInt64 = 256 * 1024 * 1024

    /// Ceiling on the total uncompressed content extracted from one archive,
    /// so a bomb cannot fill the device's disk.
    static let maxTotalExtractedBytes: UInt64 = 2 * 1024 * 1024 * 1024

    /// Ceiling on entry count, bounding the per-entry syscall overhead of a
    /// archive built from millions of empty files.
    static let maxEntryCount = 50_000

    private let archive: Archive

    init(url: URL) async throws {
        do {
            // pathEncoding nil follows the ZIP spec: UTF-8 when flag bit 11
            // is set, CP437 otherwise (legacy Windows tools).
            archive = try await Archive(url: url, accessMode: .read, pathEncoding: nil)
        } catch {
            throw EPUBArchiveError.invalidArchive
        }
    }

    static func validateEPUB(at url: URL) async throws {
        let archive = try await EPUBArchive(url: url)
        try await archive.validateEPUB()
    }

    func validateEPUB() async throws {
        guard let mimetypeData = try await data(for: "mimetype"),
              String(data: mimetypeData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip",
              await containsEntry(at: "META-INF/container.xml")
        else {
            throw EPUBArchiveError.invalidEPUB
        }
    }

    func containsEntry(at path: String) async -> Bool {
        ((try? await archive.get(path)) ?? nil) != nil
    }

    func extract(to destination: URL) async throws {
        try await validateEPUB()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            try await extractEntries(to: destination, fileManager: fileManager)
        } catch {
            // Leave no partial tree behind: a caller that sees a throw must not
            // find a half-extracted book on disk.
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func extractEntries(to destination: URL, fileManager: FileManager) async throws {
        let entries = try await archive.entries()
        guard entries.count <= Self.maxEntryCount else {
            throw EPUBArchiveError.archiveTooLarge
        }

        // Check the declared total before writing anything, so a bomb is
        // rejected up front rather than after filling the disk.
        let declaredTotal = entries.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        guard declaredTotal <= Self.maxTotalExtractedBytes else {
            throw EPUBArchiveError.archiveTooLarge
        }

        var extractedBytes: UInt64 = 0
        for entry in entries {
            let relativePath = try safeRelativePath(entry.path)

            switch entry.type {
            case .directory:
                let outputURL = destination.appendingPathComponent(relativePath, isDirectory: true)
                try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

            case .file:
                let outputURL = destination.appendingPathComponent(relativePath, isDirectory: false)
                try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    _ = try await archive.extract(entry, to: outputURL, skipCRC32: true)
                } catch {
                    throw EPUBArchiveError.writeFailed(entry.path)
                }

                // Measure what landed on disk rather than trusting the header,
                // so an entry understating its size is still caught.
                extractedBytes += actualFileSize(at: outputURL, fileManager: fileManager)
                guard extractedBytes <= Self.maxTotalExtractedBytes else {
                    throw EPUBArchiveError.archiveTooLarge
                }

            case .symlink:
                // EPUBs have no business containing symlinks; skipping is
                // safer than following one out of the destination.
                continue
            }
        }
    }

    private func actualFileSize(at url: URL, fileManager: FileManager) -> UInt64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    func data(for path: String) async throws -> Data? {
        guard let entry = ((try? await archive.get(path)) ?? nil), entry.type == .file else {
            return nil
        }

        // Reject on the declared size first: a compression bomb is cheap to
        // spot here and expensive to discover by decompressing it.
        guard entry.uncompressedSize <= Self.maxEntryBytes else {
            throw EPUBArchiveError.entryTooLarge(path)
        }

        // The declared size is attacker-controlled, so also stop accumulating
        // if the actual stream runs past the limit.
        let accumulator = DataAccumulator(byteLimit: Int(Self.maxEntryBytes))
        do {
            _ = try await archive.extract(entry, skipCRC32: true) { chunk in
                accumulator.append(chunk)
            }
        } catch {
            throw EPUBArchiveError.corruptEntry(path)
        }

        guard !accumulator.didExceedLimit else {
            throw EPUBArchiveError.entryTooLarge(path)
        }
        return accumulator.take()
    }

    // The extract consumer is @Sendable, so chunk accumulation needs a
    // lock-guarded box rather than a captured var.
    private nonisolated final class DataAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private let byteLimit: Int
        private var exceededLimit = false

        init(byteLimit: Int) {
            self.byteLimit = byteLimit
        }

        /// Stops buffering once the limit is passed. The extract consumer has
        /// no way to abort the stream, so the alternative to dropping chunks is
        /// letting a bomb allocate without bound.
        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !exceededLimit else { return }

            if buffer.count + chunk.count > byteLimit {
                exceededLimit = true
                buffer.removeAll(keepingCapacity: false)
                return
            }
            buffer.append(chunk)
        }

        var didExceedLimit: Bool {
            lock.lock()
            defer { lock.unlock() }
            return exceededLimit
        }

        func take() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }

    private func safeRelativePath(_ path: String) throws -> String {
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else {
            throw EPUBArchiveError.unsafePath(path)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw EPUBArchiveError.unsafePath(path)
        }

        return path
    }
}
