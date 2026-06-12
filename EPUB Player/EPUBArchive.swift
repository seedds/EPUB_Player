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
        }
    }
}

/// Thin EPUB-aware wrapper over ZIPFoundation. Entries are read on demand
/// from disk instead of loading the whole archive into memory.
struct EPUBArchive {
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

        for entry in try await archive.entries() {
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

            case .symlink:
                // EPUBs have no business containing symlinks; skipping is
                // safer than following one out of the destination.
                continue
            }
        }
    }

    func data(for path: String) async throws -> Data? {
        guard let entry = ((try? await archive.get(path)) ?? nil), entry.type == .file else {
            return nil
        }

        let accumulator = DataAccumulator()
        do {
            _ = try await archive.extract(entry, skipCRC32: true) { chunk in
                accumulator.append(chunk)
            }
        } catch {
            throw EPUBArchiveError.corruptEntry(path)
        }
        return accumulator.take()
    }

    // The extract consumer is @Sendable, so chunk accumulation needs a
    // lock-guarded box rather than a captured var.
    private final class DataAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(chunk)
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
