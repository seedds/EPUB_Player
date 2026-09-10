//
//  AppStateStore.swift
//  EPUB Player
//
//  Created by OpenCode on 8/5/2026.
//

import Combine
import Foundation

enum BooksSortOption: String, CaseIterable, Codable, Identifiable {
    case recentlyAdded
    case titleAscending
    case titleDescending
    case authorAscending
    case authorDescending

    var id: String {
        rawValue
    }

    var name: String {
        switch self {
        case .recentlyAdded:
            return "Recently Added"
        case .titleAscending:
            return "Title A-Z"
        case .titleDescending:
            return "Title Z-A"
        case .authorAscending:
            return "Author A-Z"
        case .authorDescending:
            return "Author Z-A"
        }
    }
}

private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    func decodeValue<T: Decodable>(_ type: T.Type, forKey key: Key, default defaultValue: T) -> T {
        ((try? decodeIfPresent(type, forKey: key)) ?? nil) ?? defaultValue
    }
}

private struct PersistedAppState: Codable {
    var books: [Book]
    var customFontFamilies: [CustomFontStore.ImportedFontFamily]
    var fontSize: Double
    var lineHeight: Double
    var fontFamilyRawValue: String
    var themeRawValue: String
    var readAloudColorRawValue: String
    var readingBackgroundRawValue: String
    var playbackSpeed: Double
    var playbackJumpInterval: Double
    var autoRewindAfterBackgroundMinutes: Int?
    var uploadServerPort: Int
    var uploadServerRequiresPassword: Bool
    var uploadServerPassword: String
    var booksSortOptionRawValue: String
    /// Records that failed to decode and were dropped (not persisted; not in
    /// `CodingKeys`). Lets `loadState` back the file up before the next save
    /// overwrites the lost records.
    var droppedRecordCount = 0

    private enum CodingKeys: String, CodingKey {
        case books
        case customFontFamilies
        case fontSize
        case lineHeight
        case fontFamilyRawValue
        case themeRawValue
        case readAloudColorRawValue
        case readingBackgroundRawValue
        case playbackSpeed
        case playbackJumpInterval
        case autoRewindAfterBackgroundMinutes
        case uploadServerPort
        case uploadServerRequiresPassword
        case uploadServerPassword
        case booksSortOptionRawValue
    }

    static let `default` = PersistedAppState(
        books: [],
        customFontFamilies: [],
        fontSize: ReaderSettings.defaultFontSize,
        lineHeight: ReaderSettings.defaultLineHeight,
        fontFamilyRawValue: "Literata",
        themeRawValue: AppThemeOption.system.rawValue,
        readAloudColorRawValue: ReaderSettings.defaultReadAloudColorHex,
        readingBackgroundRawValue: ReaderSettings.defaultReadingBackgroundRawValue,
        playbackSpeed: ReaderSettings.defaultPlaybackSpeed,
        playbackJumpInterval: ReaderSettings.defaultPlaybackJumpInterval,
        autoRewindAfterBackgroundMinutes: ReaderSettings.defaultAutoRewindAfterBackgroundMinutes,
        uploadServerPort: ReaderSettings.defaultUploadServerPort,
        uploadServerRequiresPassword: false,
        uploadServerPassword: "",
        booksSortOptionRawValue: BooksSortOption.recentlyAdded.rawValue
    )
}

extension PersistedAppState {
    // Custom decoding lives in an extension so the memberwise initializer stays
    // synthesized. Tolerates missing keys and corrupt entries so a schema change
    // or one bad record never resets the whole library.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PersistedAppState.default
        let decodedBooks = container.decodeValue([FailableDecodable<Book>].self, forKey: .books, default: [])
        books = decodedBooks.compactMap(\.value)
        let decodedFamilies = container.decodeValue(
            [FailableDecodable<CustomFontStore.ImportedFontFamily>].self,
            forKey: .customFontFamilies,
            default: []
        )
        customFontFamilies = decodedFamilies.compactMap(\.value)
        droppedRecordCount = (decodedBooks.count - books.count) + (decodedFamilies.count - customFontFamilies.count)
        fontSize = container.decodeValue(Double.self, forKey: .fontSize, default: defaults.fontSize)
        lineHeight = container.decodeValue(Double.self, forKey: .lineHeight, default: defaults.lineHeight)
        fontFamilyRawValue = container.decodeValue(String.self, forKey: .fontFamilyRawValue, default: defaults.fontFamilyRawValue)
        themeRawValue = container.decodeValue(String.self, forKey: .themeRawValue, default: defaults.themeRawValue)
        readAloudColorRawValue = container.decodeValue(String.self, forKey: .readAloudColorRawValue, default: defaults.readAloudColorRawValue)
        readingBackgroundRawValue = container.decodeValue(String.self, forKey: .readingBackgroundRawValue, default: defaults.readingBackgroundRawValue)
        playbackSpeed = container.decodeValue(Double.self, forKey: .playbackSpeed, default: defaults.playbackSpeed)
        playbackJumpInterval = container.decodeValue(Double.self, forKey: .playbackJumpInterval, default: defaults.playbackJumpInterval)
        autoRewindAfterBackgroundMinutes = (try? container.decodeIfPresent(Int.self, forKey: .autoRewindAfterBackgroundMinutes)) ?? nil
        uploadServerPort = container.decodeValue(Int.self, forKey: .uploadServerPort, default: defaults.uploadServerPort)
        uploadServerRequiresPassword = container.decodeValue(Bool.self, forKey: .uploadServerRequiresPassword, default: defaults.uploadServerRequiresPassword)
        uploadServerPassword = container.decodeValue(String.self, forKey: .uploadServerPassword, default: defaults.uploadServerPassword)
        booksSortOptionRawValue = container.decodeValue(String.self, forKey: .booksSortOptionRawValue, default: defaults.booksSortOptionRawValue)
    }
}

private enum PersistedAppStateLoadResult {
    /// state.json decoded (missing keys tolerated).
    case loaded(PersistedAppState)
    /// No state.json on disk — a fresh install. Defaults, saving enabled.
    case missing
    /// state.json exists but could not be read (locked/permissions). The file
    /// is kept and saving is disabled so a transient failure can't overwrite it.
    case ioError
    /// state.json was read but is not valid app state (non-JSON, or a `books`
    /// value that is not an array). Backed up, then defaults.
    case corrupt
}

/// A user-surfaced persistence problem, shown non-blockingly in Settings.
enum PersistenceFailure: Equatable {
    case loadFailed
    case saveFailed
}

@MainActor
final class AppStateStore: ObservableObject {
    @Published private(set) var books: [Book] = [] { didSet { invalidateSortedBooks() } }
    @Published private(set) var customFontFamilies: [CustomFontStore.ImportedFontFamily] = []
    @Published var fontSize = ReaderSettings.defaultFontSize { didSet { scheduleSave() } }
    @Published var lineHeight = ReaderSettings.defaultLineHeight { didSet { scheduleSave() } }
    @Published var fontFamilyRawValue = "" { didSet { scheduleSave() } }
    @Published var themeRawValue = AppThemeOption.system.rawValue { didSet { scheduleSave() } }
    @Published var readAloudColorRawValue = ReaderSettings.defaultReadAloudColorHex { didSet { scheduleSave() } }
    @Published var readingBackgroundRawValue = ReaderSettings.defaultReadingBackgroundRawValue { didSet { scheduleSave() } }
    @Published var playbackSpeed = ReaderSettings.defaultPlaybackSpeed { didSet { scheduleSave() } }
    @Published var playbackJumpInterval = ReaderSettings.defaultPlaybackJumpInterval { didSet { scheduleSave() } }
    @Published var autoRewindAfterBackgroundMinutes = ReaderSettings.defaultAutoRewindAfterBackgroundMinutes { didSet { scheduleSave() } }
    @Published var uploadServerPort = ReaderSettings.defaultUploadServerPort { didSet { scheduleSave() } }
    @Published var uploadServerRequiresPassword = false { didSet { scheduleSave() } }
    @Published var uploadServerPassword = "" { didSet { scheduleSave() } }
    @Published var booksSortOption = BooksSortOption.recentlyAdded {
        didSet {
            invalidateSortedBooks()
            scheduleSave()
        }
    }

    /// Set when loading or saving state.json fails, so Settings can show a
    /// non-blocking notice. Cleared on the next successful write.
    @Published private(set) var persistenceFailure: PersistenceFailure?

    /// Cached `sortedBooks`, recomputed only when `books`, `booksSortOption`, or
    /// a book's sort fields (title/author/importedAt) change. `BooksView.body`
    /// re-evaluates on every book mutation (each location tick), so sorting the
    /// whole library there — with `localizedCaseInsensitiveCompare` — was
    /// per-scroll-tick work. Invalidating on *every* book publish (as the
    /// observer once did) made the cache dead during reading.
    private var cachedSortedBooks: [Book]?

    private var bookSubscriptions: [UUID: [AnyCancellable]] = [:]
    private var saveTask: Task<Void, Never>?
    private var isHydratingState = false
    private var canPersistState = true
    #if DEBUG
    private var diskWriteCount = 0
    private var sortComputeCount = 0
    #endif

    deinit {
        saveTask?.cancel()
    }

    init() {
        loadState()
        CustomFontStore.registerFontsForUI(in: customFontFamilies)
    }

    func book(withID id: UUID) -> Book? {
        books.first { $0.id == id }
    }

    func firstBook(originalFilename: String) -> Book? {
        books.first { $0.originalFilename == originalFilename }
    }

    var sortedBooks: [Book] {
        if let cachedSortedBooks {
            return cachedSortedBooks
        }
        let sorted = books.sorted { lhs, rhs in
            isOrderedBefore(lhs, rhs, for: booksSortOption)
        }
        cachedSortedBooks = sorted
        #if DEBUG
        sortComputeCount += 1
        #endif
        return sorted
    }

    private func invalidateSortedBooks() {
        cachedSortedBooks = nil
    }

    func addBook(_ book: Book) {
        books.append(book)
        observeBook(book)
        scheduleSave()
    }

    func removeBook(id: UUID) {
        books.removeAll { $0.id == id }
        bookSubscriptions[id] = nil
        scheduleSave()
    }

    func setCustomFontFamilies(_ families: [CustomFontStore.ImportedFontFamily]) {
        customFontFamilies = families
        CustomFontStore.registerFontsForUI(in: families)
        scheduleSave()
    }

    func persistNow() {
        guard canPersistState else {
            return
        }

        saveTask?.cancel()
        saveTask = nil
        writeStateToDisk()
    }

    private func loadState() {
        isHydratingState = true
        defer {
            isHydratingState = false
        }

        switch readPersistedState() {
        case .loaded(let persistedState):
            canPersistState = true
            if persistedState.droppedRecordCount > 0 {
                // The dropped records are gone from memory and will be gone
                // from disk at the next save. Keep a copy so a schema slip or
                // one bad record never destroys bookmarks and progress silently.
                DebugLog.shared.log(
                    "AppStateStore: dropped \(persistedState.droppedRecordCount) undecodable record(s) from state.json; backing it up"
                )
                _ = backUpStateFile(label: "partial", move: false)
            }
            applyPersistedState(persistedState)
        case .missing:
            canPersistState = true
            applyPersistedState(.default)
        case .ioError:
            // The file exists but couldn't be read. Keep it untouched and stop
            // persisting so a transient read failure can't clobber the user's
            // real library with defaults; surface it in Settings.
            canPersistState = false
            persistenceFailure = .loadFailed
            applyPersistedState(.default)
        case .corrupt:
            // The file is unrecoverable as app state. Move it aside for recovery
            // and only allow overwriting once it has been safely backed up.
            canPersistState = backUpStateFile(label: "corrupt", move: true)
            applyPersistedState(.default)
        }

        configureBookSubscriptions()
    }

    /// Copies (or moves) state.json aside as `state-<label>-<timestamp>.json`.
    /// Returns whether the file is now safe to overwrite.
    private func backUpStateFile(label: String, move: Bool) -> Bool {
        guard let stateURL = try? AppStorage.stateURL() else {
            return false
        }

        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return true
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = stateURL
            .deletingLastPathComponent()
            .appendingPathComponent("state-\(label)-\(timestamp).json", isDirectory: false)

        do {
            if move {
                try FileManager.default.moveItem(at: stateURL, to: backupURL)
            } else {
                try FileManager.default.copyItem(at: stateURL, to: backupURL)
            }
            return true
        } catch {
            return false
        }
    }

    private func readPersistedState() -> PersistedAppStateLoadResult {
        guard let stateURL = try? AppStorage.stateURL() else {
            return .ioError
        }

        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return .missing
        }

        guard let data = try? Data(contentsOf: stateURL) else {
            // The file is present but the read failed (locked/permissions): an
            // I/O problem, not corruption. Distinguishing the two decides
            // whether we keep the file or move it aside.
            return .ioError
        }

        // A parseable JSON object whose `books` value is present but not an
        // array is structurally wrong (e.g. a truncated/rewritten file): treat
        // it as corrupt rather than silently loading zero books and letting the
        // next save overwrite the user's real library.
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any],
           let books = dictionary["books"],
           !(books is [Any]) {
            return .corrupt
        }

        guard let persistedState = try? JSONDecoder().decode(PersistedAppState.self, from: data) else {
            return .corrupt
        }

        return .loaded(persistedState)
    }

    private func applyPersistedState(_ persistedState: PersistedAppState) {
        books = persistedState.books
        customFontFamilies = persistedState.customFontFamilies
        fontSize = persistedState.fontSize
        lineHeight = persistedState.lineHeight
        fontFamilyRawValue = persistedState.fontFamilyRawValue
        themeRawValue = persistedState.themeRawValue
        readAloudColorRawValue = persistedState.readAloudColorRawValue
        readingBackgroundRawValue = persistedState.readingBackgroundRawValue
        playbackSpeed = persistedState.playbackSpeed
        playbackJumpInterval = persistedState.playbackJumpInterval
        autoRewindAfterBackgroundMinutes = ReaderSettings.normalizedAutoRewindAfterBackgroundMinutes(
            persistedState.autoRewindAfterBackgroundMinutes ?? ReaderSettings.defaultAutoRewindAfterBackgroundMinutes
        )
        uploadServerPort = persistedState.uploadServerPort
        uploadServerRequiresPassword = persistedState.uploadServerRequiresPassword
        uploadServerPassword = persistedState.uploadServerPassword
        booksSortOption = BooksSortOption(rawValue: persistedState.booksSortOptionRawValue) ?? .recentlyAdded
    }

    private func configureBookSubscriptions() {
        bookSubscriptions = [:]
        for book in books {
            observeBook(book)
        }
    }

    private func observeBook(_ book: Book) {
        // Books are only mutated on the main actor; forwarding synchronously
        // lets SwiftUI coalesce the invalidation with the mutation instead of
        // deferring it a runloop turn.
        let forwardChange = book.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.objectWillChange.send()
                self?.scheduleSave()
            }
        }
        // Only the fields the sort reads may drop the cached order. Hooking
        // `objectWillChange` here instead invalidated on every location tick.
        let invalidateSort = Publishers.Merge3(
            book.$title.map { _ in () },
            book.$author.map { _ in () },
            book.$importedAt.map { _ in () }
        ).sink { [weak self] in
            MainActor.assumeIsolated {
                self?.invalidateSortedBooks()
            }
        }
        bookSubscriptions[book.id] = [forwardChange, invalidateSort]
    }

    /// `books` itself is unordered (insertion order); this is the one place the
    /// library order is decided. Each option is a lazy chain of tie-breaks.
    private func isOrderedBefore(_ lhs: Book, _ rhs: Book, for option: BooksSortOption) -> Bool {
        let title = { lhs.title.localizedCaseInsensitiveCompare(rhs.title) }
        let author = { lhs.author.localizedCaseInsensitiveCompare(rhs.author) }
        let newestFirst = { rhs.importedAt.compare(lhs.importedAt) }
        let stableID = { lhs.id.uuidString.compare(rhs.id.uuidString) }

        let decision: ComparisonResult
        switch option {
        case .recentlyAdded:
            decision = Self.firstDecisive(newestFirst, title, author, stableID)
        case .titleAscending:
            decision = Self.firstDecisive(title, author, newestFirst, stableID)
        case .titleDescending:
            decision = Self.firstDecisive({ title().reversed }, author, newestFirst, stableID)
        case .authorAscending:
            decision = Self.firstDecisive(author, title, newestFirst, stableID)
        case .authorDescending:
            decision = Self.firstDecisive({ author().reversed }, title, newestFirst, stableID)
        }
        return decision == .orderedAscending
    }

    /// The first comparison that is not `.orderedSame`, evaluated lazily so the
    /// localized string compares only run when an earlier key ties.
    private static func firstDecisive(_ comparisons: (() -> ComparisonResult)...) -> ComparisonResult {
        for comparison in comparisons {
            let result = comparison()
            if result != .orderedSame {
                return result
            }
        }
        return .orderedSame
    }

    private func currentPersistedState() -> PersistedAppState {
        PersistedAppState(
            books: books,
            customFontFamilies: customFontFamilies,
            fontSize: fontSize,
            lineHeight: lineHeight,
            fontFamilyRawValue: fontFamilyRawValue,
            themeRawValue: themeRawValue,
            readAloudColorRawValue: readAloudColorRawValue,
            readingBackgroundRawValue: readingBackgroundRawValue,
            playbackSpeed: playbackSpeed,
            playbackJumpInterval: playbackJumpInterval,
            autoRewindAfterBackgroundMinutes: ReaderSettings.normalizedAutoRewindAfterBackgroundMinutes(
                autoRewindAfterBackgroundMinutes
            ),
            uploadServerPort: uploadServerPort,
            uploadServerRequiresPassword: uploadServerRequiresPassword,
            uploadServerPassword: uploadServerPassword,
            booksSortOptionRawValue: booksSortOption.rawValue
        )
    }

    private func scheduleSave() {
        guard !isHydratingState, canPersistState else {
            return
        }

        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            // A superseding mutation cancels this task during the sleep; without
            // this guard `try?` swallows the CancellationError and every
            // cancelled save still writes, defeating the debounce (N mutations
            // -> N full-library encodes + disk writes on the main actor).
            guard !Task.isCancelled else {
                return
            }
            self?.writeStateToDisk()
        }
    }

    private func writeStateToDisk() {
        let persistedState = currentPersistedState()

        do {
            let data = try JSONEncoder().encode(persistedState)
            let stateURL = try AppStorage.stateURL()
            try data.write(to: stateURL, options: .atomic)
            // A previously-failed save (or load) has now succeeded; clear the
            // notice. `canPersistState` was left true so this retry could run.
            if persistenceFailure == .saveFailed {
                persistenceFailure = nil
            }
            #if DEBUG
            diskWriteCount += 1
            #endif
        } catch {
            // Keep persisting enabled so the next mutation retries; a transient
            // failure self-heals rather than silently disabling saves for the
            // rest of the session.
            DebugLog.shared.log("AppStateStore: failed to write state.json: \(error)")
            persistenceFailure = .saveFailed
        }
    }
}

#if DEBUG
extension AppStateStore {
    /// Number of times state has actually been flushed to disk. Lets tests
    /// verify the save debounce coalesces a burst of mutations into one write.
    var test_diskWriteCount: Int { diskWriteCount }

    /// Number of times `sortedBooks` was actually re-sorted. Lets tests verify
    /// that non-sort mutations (reading position, covers) hit the cache.
    var test_sortComputeCount: Int { sortComputeCount }
}
#endif

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: .orderedDescending
        case .orderedDescending: .orderedAscending
        case .orderedSame: .orderedSame
        }
    }
}
