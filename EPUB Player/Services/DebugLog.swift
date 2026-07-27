//
//  DebugLog.swift
//  EPUB Player
//
//  Created by F2PGOD on 8/7/2026.
//

import Combine
import Foundation

/// Lightweight in-app diagnostic log.
///
/// Keeps a bounded, in-memory ring buffer of timestamped lines that the UI can
/// observe (e.g. Settings shows a live count and a copy-to-clipboard button) and
/// mirrors every line to a file under `Documents/Cache` so logs survive an app
/// relaunch or crash. Confined to the main actor because its only writers
/// (`MediaOverlayPlaybackController` and `ReaderView`) already run there, which
/// avoids any locking.
///
/// Both the in-memory buffer and the on-disk file are bounded. `Documents/Cache`
/// is a user document directory, not the system caches directory, so iOS never
/// purges it — an unbounded log file would grow until it filled the device and
/// made launch (which reads the file back) fail.
@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    /// Maximum number of lines retained in memory. Oldest lines are dropped.
    private let capacity: Int

    /// Size at which the on-disk log is rewritten from the in-memory ring
    /// buffer, discarding everything older. Bounds the file to roughly this
    /// much plus one buffer's worth of lines.
    private let maxFileBytes: Int

    /// How much of the tail to read back at launch. Larger than `maxFileBytes`
    /// would be pointless; smaller keeps the launch-time allocation small.
    private let tailReadBytes: Int

    @Published private(set) var entries: [String] = []

    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private lazy var fileURL: URL? = {
        do {
            return try AppStorage.cacheDirectory().appendingPathComponent("debug-log.txt", isDirectory: false)
        } catch {
            return nil
        }
    }()

    /// Held open for the process lifetime. Reopening per line cost four
    /// syscalls on the main actor for every logged line, and playback logs
    /// several lines per second.
    private var fileHandle: FileHandle?
    private var fileByteCount = 0

    private init() {
        capacity = 1000
        maxFileBytes = 1024 * 1024
        tailReadBytes = 256 * 1024
        loadFromFile()
    }

    #if DEBUG
    /// Test-only initializer. The shared instance is a singleton with a
    /// process-lifetime file handle, which tests cannot reset; this lets them
    /// exercise rotation and tail-reading against a temporary file.
    init(capacity: Int, maxFileBytes: Int, tailReadBytes: Int) {
        self.capacity = capacity
        self.maxFileBytes = maxFileBytes
        self.tailReadBytes = tailReadBytes
        loadFromFile()
    }
    #endif

    /// Appends a timestamped line to the log, trims the buffer to `capacity`,
    /// and mirrors the line to disk.
    func log(_ message: String) {
        let line = "\(timestampFormatter.string(from: Date())) \(message)"
        entries.append(line)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        appendToFile(line)
    }

    func clear() {
        entries.removeAll()
        rewriteFileFromEntries()
    }

    /// The full log as newline-joined plain text, for the clipboard.
    func exportText() -> String {
        entries.joined(separator: "\n")
    }

    // MARK: - File persistence

    /// Reads back only the tail of the log file. Reading the whole file would
    /// allocate its full size as a `String` on the main actor at launch.
    private func loadFromFile() {
        guard let fileURL,
              let handle = try? FileHandle(forReadingFrom: fileURL)
        else {
            return
        }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else {
            return
        }
        fileByteCount = Int(size)

        let readLength = min(Int(size), tailReadBytes)
        let offset = size - UInt64(readLength)
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: readLength),
              let contents = String(data: data, encoding: .utf8)
        else {
            return
        }

        var lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // Seeking to a byte offset usually lands mid-line; drop that fragment.
        if offset > 0, !lines.isEmpty {
            lines.removeFirst()
        }
        entries = Array(lines.suffix(capacity))
    }

    private func appendToFile(_ line: String) {
        let data = Data((line + "\n").utf8)

        guard let handle = openFileHandleIfNeeded() else {
            return
        }

        try? handle.write(contentsOf: data)
        fileByteCount += data.count

        if fileByteCount > maxFileBytes {
            rewriteFileFromEntries()
        }
    }

    private func openFileHandleIfNeeded() -> FileHandle? {
        if let fileHandle {
            return fileHandle
        }

        guard let fileURL else {
            return nil
        }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            fileByteCount = 0
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return nil
        }

        fileByteCount = Int((try? handle.seekToEnd()) ?? 0)
        fileHandle = handle
        return handle
    }

    /// Truncates the file back down to the bounded in-memory buffer. This is
    /// the only thing that stops the log growing without limit.
    private func rewriteFileFromEntries() {
        guard let fileURL else {
            return
        }

        try? fileHandle?.close()
        fileHandle = nil

        let contents = entries.isEmpty ? "" : entries.joined(separator: "\n") + "\n"
        let data = Data(contents.utf8)
        try? data.write(to: fileURL, options: .atomic)
        fileByteCount = data.count
    }
}
