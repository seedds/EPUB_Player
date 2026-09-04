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
    case corruptEntry(String)
    case entryTooLarge(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            "The file is not a valid ZIP archive."
        case .invalidEPUB:
            "The file is not a valid EPUB package."
        case .corruptEntry(let path):
            "The EPUB contains a corrupt ZIP entry: \(path)."
        case .entryTooLarge(let path):
            "The EPUB contains an unreasonably large file: \(path)."
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
        // if the actual stream runs past the limit. The consumer throws the
        // moment it does, which aborts the extract instead of decompressing the
        // whole bomb to completion (memory was already bounded; this bounds CPU
        // and time too).
        let accumulator = DataAccumulator(byteLimit: Int(Self.maxEntryBytes))
        do {
            _ = try await archive.extract(entry, skipCRC32: true) { chunk in
                try accumulator.append(chunk)
            }
        } catch is DataAccumulator.LimitExceeded {
            throw EPUBArchiveError.entryTooLarge(path)
        } catch {
            throw EPUBArchiveError.corruptEntry(path)
        }

        return accumulator.take()
    }

    // The extract consumer is @Sendable, so chunk accumulation needs a
    // lock-guarded box rather than a captured var.
    private nonisolated final class DataAccumulator: @unchecked Sendable {
        /// Thrown by `append` when the accumulated bytes would exceed the limit,
        /// so the caller can abort the extract stream.
        struct LimitExceeded: Error {}

        private let lock = NSLock()
        private var buffer = Data()
        private let byteLimit: Int

        init(byteLimit: Int) {
            self.byteLimit = byteLimit
        }

        /// Throws `LimitExceeded` once the buffer would pass the limit, aborting
        /// the extract rather than letting a bomb keep decompressing.
        func append(_ chunk: Data) throws {
            lock.lock()
            defer { lock.unlock() }

            guard buffer.count + chunk.count <= byteLimit else {
                buffer.removeAll(keepingCapacity: false)
                throw LimitExceeded()
            }
            buffer.append(chunk)
        }

        func take() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }
}
