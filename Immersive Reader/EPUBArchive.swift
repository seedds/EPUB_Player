//
//  EPUBArchive.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Compression
import Foundation

enum EPUBArchiveError: LocalizedError {
    case invalidArchive
    case invalidEPUB
    case unsupportedCompression(UInt16)
    case unsupportedZip64
    case unsafePath(String)
    case corruptEntry(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            "The file is not a valid ZIP archive."
        case .invalidEPUB:
            "The file is not a valid EPUB package."
        case .unsupportedCompression(let method):
            "This EPUB uses unsupported ZIP compression method \(method)."
        case .unsupportedZip64:
            "ZIP64 EPUB archives are not supported yet."
        case .unsafePath(let path):
            "The EPUB contains an unsafe file path: \(path)."
        case .corruptEntry(let path):
            "The EPUB contains a corrupt ZIP entry: \(path)."
        case .writeFailed(let path):
            "Could not extract EPUB entry: \(path)."
        }
    }
}

struct EPUBArchive {
    private struct Entry {
        let path: String
        let compressionMethod: UInt16
        let flags: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32

        nonisolated var isDirectory: Bool {
            path.hasSuffix("/")
        }
    }

    private let data: Data
    private let entries: [Entry]

    nonisolated init(url: URL) throws {
        data = try Data(contentsOf: url)
        entries = try Self.readCentralDirectory(from: data)
    }

    nonisolated static func validateEPUB(at url: URL) throws {
        let archive = try EPUBArchive(url: url)
        try archive.validateEPUB()
    }

    nonisolated func validateEPUB() throws {
        guard let mimetypeData = try data(for: "mimetype"),
              String(data: mimetypeData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip",
              entries.contains(where: { $0.path == "META-INF/container.xml" })
        else {
            throw EPUBArchiveError.invalidEPUB
        }
    }

    nonisolated func containsEntry(at path: String) -> Bool {
        entries.contains(where: { $0.path == path })
    }

    nonisolated func extract(to destination: URL) throws {
        try validateEPUB()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        for entry in entries {
            let relativePath = try safeRelativePath(entry.path)
            let outputURL = destination.appendingPathComponent(relativePath, isDirectory: entry.isDirectory)

            if entry.isDirectory {
                try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
                continue
            }

            try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let contents = try data(for: entry)
            guard fileManager.createFile(atPath: outputURL.path, contents: contents) else {
                throw EPUBArchiveError.writeFailed(entry.path)
            }
        }
    }

    nonisolated func data(for path: String) throws -> Data? {
        guard let entry = entries.first(where: { $0.path == path }) else {
            return nil
        }
        return try data(for: entry)
    }

    nonisolated private func data(for entry: Entry) throws -> Data {
        if entry.flags & 0x1 == 0x1 {
            throw EPUBArchiveError.corruptEntry(entry.path)
        }

        let localOffset = Int(entry.localHeaderOffset)
        guard localOffset >= 0,
              data.hasBytes(at: localOffset, count: 30),
              data.uint32(at: localOffset) == 0x04034b50
        else {
            throw EPUBArchiveError.corruptEntry(entry.path)
        }

        guard let filenameLength = data.uint16(at: localOffset + 26).map(Int.init),
              let extraLength = data.uint16(at: localOffset + 28).map(Int.init)
        else {
            throw EPUBArchiveError.corruptEntry(entry.path)
        }

        let payloadOffset = localOffset + 30 + filenameLength + extraLength
        let compressedSize = Int(entry.compressedSize)
        guard payloadOffset >= 0,
              data.hasBytes(at: payloadOffset, count: compressedSize)
        else {
            throw EPUBArchiveError.corruptEntry(entry.path)
        }

        let compressedData = data.subdata(in: payloadOffset..<(payloadOffset + compressedSize))

        switch entry.compressionMethod {
        case 0:
            return compressedData
        case 8:
            return try inflate(compressedData, expectedSize: Int(entry.uncompressedSize), path: entry.path)
        default:
            throw EPUBArchiveError.unsupportedCompression(entry.compressionMethod)
        }
    }

    nonisolated private func inflate(_ compressedData: Data, expectedSize: Int, path: String) throws -> Data {
        guard expectedSize >= 0 else {
            throw EPUBArchiveError.corruptEntry(path)
        }

        if expectedSize == 0 {
            return Data()
        }

        return try compressedData.withUnsafeBytes { sourceBuffer in
            guard let sourceAddress = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw EPUBArchiveError.corruptEntry(path)
            }

            var output = Data(count: expectedSize)
            let decodedCount = output.withUnsafeMutableBytes { outputBuffer in
                compression_decode_buffer(
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    expectedSize,
                    sourceAddress,
                    compressedData.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }

            guard decodedCount == expectedSize else {
                throw EPUBArchiveError.corruptEntry(path)
            }

            return output
        }
    }

    nonisolated private func safeRelativePath(_ path: String) throws -> String {
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else {
            throw EPUBArchiveError.unsafePath(path)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw EPUBArchiveError.unsafePath(path)
        }

        return path
    }

    nonisolated private static func readCentralDirectory(from data: Data) throws -> [Entry] {
        guard let eocdOffset = findEndOfCentralDirectory(in: data) else {
            throw EPUBArchiveError.invalidArchive
        }

        guard let totalEntries = data.uint16(at: eocdOffset + 10).map(Int.init),
              let centralDirectoryOffset = data.uint32(at: eocdOffset + 16)
        else {
            throw EPUBArchiveError.invalidArchive
        }

        if totalEntries == 0xffff || centralDirectoryOffset == 0xffffffff {
            throw EPUBArchiveError.unsupportedZip64
        }

        var offset = Int(centralDirectoryOffset)
        var entries: [Entry] = []

        for _ in 0..<totalEntries {
            guard data.hasBytes(at: offset, count: 46),
                  data.uint32(at: offset) == 0x02014b50
            else {
                throw EPUBArchiveError.invalidArchive
            }

            guard let flags = data.uint16(at: offset + 8),
                  let compressionMethod = data.uint16(at: offset + 10),
                  let compressedSize = data.uint32(at: offset + 20),
                  let uncompressedSize = data.uint32(at: offset + 24),
                  let filenameLength = data.uint16(at: offset + 28).map(Int.init),
                  let extraLength = data.uint16(at: offset + 30).map(Int.init),
                  let commentLength = data.uint16(at: offset + 32).map(Int.init),
                  let localHeaderOffset = data.uint32(at: offset + 42)
            else {
                throw EPUBArchiveError.invalidArchive
            }

            if compressedSize == 0xffffffff || uncompressedSize == 0xffffffff || localHeaderOffset == 0xffffffff {
                throw EPUBArchiveError.unsupportedZip64
            }

            let filenameStart = offset + 46
            let filenameEnd = filenameStart + filenameLength
            guard filenameEnd <= data.count,
                  data.hasBytes(at: filenameEnd, count: extraLength + commentLength),
                  let path = String(data: data.subdata(in: filenameStart..<filenameEnd), encoding: .utf8)
            else {
                throw EPUBArchiveError.invalidArchive
            }

            entries.append(Entry(
                path: path,
                compressionMethod: compressionMethod,
                flags: flags,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset
            ))

            offset = filenameEnd + extraLength + commentLength
        }

        return entries
    }

    nonisolated private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }

        let minimumOffset = max(0, data.count - 65_557)
        var offset = data.count - 22

        while offset >= minimumOffset {
            if data.uint32(at: offset) == 0x06054b50 {
                return offset
            }
            offset -= 1
        }

        return nil
    }
}

private extension Data {
    nonisolated func hasBytes(at offset: Int, count: Int) -> Bool {
        offset >= 0 && count >= 0 && offset <= self.count - count
    }

    nonisolated func uint16(at offset: Int) -> UInt16? {
        guard hasBytes(at: offset, count: 2) else {
            return nil
        }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    nonisolated func uint32(at offset: Int) -> UInt32? {
        guard hasBytes(at: offset, count: 4) else {
            return nil
        }
        return UInt32(self[offset]) |
            (UInt32(self[offset + 1]) << 8) |
            (UInt32(self[offset + 2]) << 16) |
            (UInt32(self[offset + 3]) << 24)
    }
}
