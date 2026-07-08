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
@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    /// Maximum number of lines retained in memory. Oldest lines are dropped.
    private let capacity = 1000

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

    private init() {
        loadFromFile()
    }

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
        clearFile()
    }

    /// The full log as newline-joined plain text, for the clipboard.
    func exportText() -> String {
        entries.joined(separator: "\n")
    }

    // MARK: - File persistence

    private func loadFromFile() {
        guard let fileURL,
              let contents = try? String(contentsOf: fileURL, encoding: .utf8)
        else {
            return
        }

        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        entries = Array(lines.suffix(capacity))
    }

    private func appendToFile(_ line: String) {
        guard let fileURL else {
            return
        }

        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func clearFile() {
        guard let fileURL else {
            return
        }
        try? Data().write(to: fileURL, options: .atomic)
    }
}
