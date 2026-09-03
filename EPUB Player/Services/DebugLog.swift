//
//  DebugLog.swift
//  EPUB Player
//
//  Created by F2PGOD on 8/7/2026.
//

import Combine
import Foundation

/// Off-main file sink for `DebugLog`. Owns the file handle, byte counter, and a
/// serial queue so that writing (and rotation) never touches the main actor.
/// `@unchecked Sendable` because every mutable field is confined to `queue`.
private final class DebugLogFileSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.epubplayer.debuglog.file", qos: .utility)
    private let fileURL: URL
    private let maxFileBytes: Int
    private var fileHandle: FileHandle?
    private var byteCount = 0

    init(fileURL: URL, maxFileBytes: Int) {
        self.fileURL = fileURL
        self.maxFileBytes = maxFileBytes
    }

    /// Reads back only the tail of the log file at launch. Reading the whole
    /// file would allocate its full size as a `String`.
    func loadTail(tailReadBytes: Int, capacity: Int) -> [String] {
        queue.sync {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                return []
            }
            defer { try? handle.close() }

            guard let size = try? handle.seekToEnd() else {
                return []
            }
            byteCount = Int(size)

            let readLength = min(Int(size), tailReadBytes)
            let offset = size - UInt64(readLength)
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: readLength),
                  let contents = String(data: data, encoding: .utf8)
            else {
                return []
            }

            var lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            // Seeking to a byte offset usually lands mid-line; drop that fragment.
            if offset > 0, !lines.isEmpty {
                lines.removeFirst()
            }
            return Array(lines.suffix(capacity))
        }
    }

    func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        queue.async { [self] in
            guard let handle = openFileHandleIfNeeded() else {
                return
            }
            try? handle.write(contentsOf: data)
            byteCount += data.count
            if byteCount > maxFileBytes {
                rotate()
            }
        }
    }

    /// Blocks until every queued write has landed. Used by tests and at
    /// lifecycle edges (background/persist) so the on-disk log is current.
    func flush() {
        queue.sync {}
    }

    private func openFileHandleIfNeeded() -> FileHandle? {
        if let fileHandle {
            return fileHandle
        }

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            byteCount = 0
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            return nil
        }

        byteCount = Int((try? handle.seekToEnd()) ?? 0)
        fileHandle = handle
        return handle
    }

    /// Truncates the file to its last `maxFileBytes`, dropping the leading
    /// partial line. This is the only thing that stops the log growing without
    /// limit. Runs on `queue`, so reading the (bounded) file here is off-main.
    private func rotate() {
        try? fileHandle?.close()
        fileHandle = nil

        guard let data = try? Data(contentsOf: fileURL) else {
            byteCount = 0
            return
        }

        var tail = Data(data.suffix(maxFileBytes))
        if data.count > maxFileBytes,
           let newlineIndex = tail.firstIndex(of: 0x0A) {
            tail = tail.subdata(in: tail.index(after: newlineIndex)..<tail.endIndex)
        }

        try? tail.write(to: fileURL, options: .atomic)
        byteCount = tail.count
    }
}

/// Lightweight in-app diagnostic log.
///
/// Keeps a bounded, in-memory ring buffer of timestamped lines that the UI can
/// observe (e.g. Settings shows a live count and a copy-to-clipboard button) and
/// mirrors every line to a file under `Documents/Cache` so logs survive an app
/// relaunch or crash. The ring buffer is confined to the main actor because its
/// only writers (`MediaOverlayPlaybackController` and `ReaderView`) already run
/// there; the file writes are handed to an off-main serial queue so nothing
/// blocks the main thread on the playback hot path.
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

    @Published private(set) var entries: [String] = []

    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private let tailReadBytes: Int
    private let sink: DebugLogFileSink?

    private init() {
        capacity = 1000
        tailReadBytes = 256 * 1024
        sink = DebugLog.makeSink(maxFileBytes: 1024 * 1024)
        loadFromFile()
    }

    #if DEBUG
    /// Test-only initializer. The shared instance is a singleton with a
    /// process-lifetime sink, which tests cannot reset; this lets them exercise
    /// rotation and tail-reading against a temporary file.
    init(capacity: Int, maxFileBytes: Int, tailReadBytes: Int) {
        self.capacity = capacity
        self.tailReadBytes = tailReadBytes
        sink = DebugLog.makeSink(maxFileBytes: maxFileBytes)
        loadFromFile()
    }
    #endif

    private static func makeSink(maxFileBytes: Int) -> DebugLogFileSink? {
        guard let fileURL = try? AppStorage.cacheDirectory().appendingPathComponent("debug-log.txt", isDirectory: false) else {
            return nil
        }
        return DebugLogFileSink(fileURL: fileURL, maxFileBytes: maxFileBytes)
    }

    /// Appends a timestamped line to the log, trims the buffer to `capacity`,
    /// and mirrors the line to disk off-main.
    ///
    /// The message is an `@autoclosure` so its interpolation — often several
    /// `String(describing:)` calls on the location-change hot path — is only
    /// paid when a line is actually logged.
    func log(_ message: @autoclosure () -> String) {
        let line = "\(timestampFormatter.string(from: Date())) \(message())"
        entries.append(line)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        sink?.append(line)
    }

    /// The full log as newline-joined plain text, for the clipboard.
    func exportText() -> String {
        entries.joined(separator: "\n")
    }

    /// Blocks until buffered lines have been written. Called at lifecycle edges
    /// (app background / explicit persist) and by tests before reading the file.
    func flush() {
        sink?.flush()
    }

    private func loadFromFile() {
        guard let sink else {
            return
        }
        entries = sink.loadTail(tailReadBytes: tailReadBytes, capacity: capacity)
    }
}
