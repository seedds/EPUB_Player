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
}
