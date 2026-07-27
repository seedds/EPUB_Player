//
//  ZIPFixtureBuilder.swift
//  EPUB PlayerTests
//
//  Builds minimal ZIP archives byte-by-byte so tests can exercise edge cases
//  (legacy name encodings, EOCD signatures inside comments) that no zip tool
//  produces on demand.
//

import Foundation

struct ZIPFixtureEntry {
    let nameBytes: Data
    let data: Data
    let utf8Flag: Bool
    /// Overrides the uncompressed size written into the headers. A real
    /// compression bomb declares a huge size backed by a few bytes of data;
    /// this reproduces that without needing a DEFLATE encoder.
    let declaredUncompressedSize: UInt32?

    init(name: String, data: Data, declaredUncompressedSize: UInt32? = nil) {
        self.nameBytes = Data(name.utf8)
        self.data = data
        self.utf8Flag = true
        self.declaredUncompressedSize = declaredUncompressedSize
    }

    init(nameBytes: Data, data: Data, utf8Flag: Bool) {
        self.nameBytes = nameBytes
        self.data = data
        self.utf8Flag = utf8Flag
        self.declaredUncompressedSize = nil
    }
}

enum ZIPFixtureBuilder {
    static func makeArchive(entries: [ZIPFixtureEntry], comment: Data = Data()) -> Data {
        var archive = Data()
        var centralDirectory = Data()

        for entry in entries {
            let localHeaderOffset = UInt32(archive.count)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let declaredSize = entry.declaredUncompressedSize ?? size
            let flags: UInt16 = entry.utf8Flag ? 0x0800 : 0

            // Local file header (stored, method 0)
            archive.appendUInt32(0x04034b50)
            archive.appendUInt16(20)            // version needed
            archive.appendUInt16(flags)
            archive.appendUInt16(0)             // method: stored
            archive.appendUInt16(0)             // mod time
            archive.appendUInt16(0x21)          // mod date
            archive.appendUInt32(crc)
            archive.appendUInt32(size)          // compressed size
            archive.appendUInt32(declaredSize)  // uncompressed size
            archive.appendUInt16(UInt16(entry.nameBytes.count))
            archive.appendUInt16(0)             // extra length
            archive.append(entry.nameBytes)
            archive.append(entry.data)

            // Central directory header
            centralDirectory.appendUInt32(0x02014b50)
            centralDirectory.appendUInt16(20)   // version made by
            centralDirectory.appendUInt16(20)   // version needed
            centralDirectory.appendUInt16(flags)
            centralDirectory.appendUInt16(0)    // method
            centralDirectory.appendUInt16(0)    // mod time
            centralDirectory.appendUInt16(0x21) // mod date
            centralDirectory.appendUInt32(crc)
            centralDirectory.appendUInt32(size)
            centralDirectory.appendUInt32(declaredSize)
            centralDirectory.appendUInt16(UInt16(entry.nameBytes.count))
            centralDirectory.appendUInt16(0)    // extra length
            centralDirectory.appendUInt16(0)    // comment length
            centralDirectory.appendUInt16(0)    // disk number start
            centralDirectory.appendUInt16(0)    // internal attributes
            centralDirectory.appendUInt32(0)    // external attributes
            centralDirectory.appendUInt32(localHeaderOffset)
            centralDirectory.append(entry.nameBytes)
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)

        // End of central directory
        archive.appendUInt32(0x06054b50)
        archive.appendUInt16(0)                            // disk number
        archive.appendUInt16(0)                            // central directory disk
        archive.appendUInt16(UInt16(entries.count))        // entries on disk
        archive.appendUInt16(UInt16(entries.count))        // total entries
        archive.appendUInt32(UInt32(centralDirectory.count))
        archive.appendUInt32(centralDirectoryOffset)
        archive.appendUInt16(UInt16(comment.count))
        archive.append(comment)

        return archive
    }

    /// Standard EPUB scaffolding (mimetype + container.xml) plus the given
    /// package-relative entries.
    static func makeEPUB(opfPath: String = "OEBPS/content.opf", entries: [ZIPFixtureEntry]) -> Data {
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        var allEntries = [
            ZIPFixtureEntry(name: "mimetype", data: Data("application/epub+zip".utf8)),
            ZIPFixtureEntry(name: "META-INF/container.xml", data: Data(containerXML.utf8))
        ]
        allEntries.append(contentsOf: entries)
        return makeArchive(entries: allEntries)
    }

    static func write(_ archiveData: Data, named filename: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try archiveData.write(to: url)
        return url
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1
            }
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
