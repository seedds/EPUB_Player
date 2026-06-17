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

    // Tolerates missing keys and corrupt entries so a schema change or one bad
    // record never resets the whole library.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PersistedAppState.default
        books = container.decodeValue([FailableDecodable<Book>].self, forKey: .books, default: [])
            .compactMap(\.value)
        customFontFamilies = container.decodeValue(
            [FailableDecodable<CustomFontStore.ImportedFontFamily>].self,
            forKey: .customFontFamilies,
            default: []
        ).compactMap(\.value)
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

    init(
        books: [Book],
        customFontFamilies: [CustomFontStore.ImportedFontFamily],
        fontSize: Double,
        lineHeight: Double,
        fontFamilyRawValue: String,
        themeRawValue: String,
        readAloudColorRawValue: String,
        readingBackgroundRawValue: String,
        playbackSpeed: Double,
        playbackJumpInterval: Double,
        autoRewindAfterBackgroundMinutes: Int?,
        uploadServerPort: Int,
        uploadServerRequiresPassword: Bool,
        uploadServerPassword: String,
        booksSortOptionRawValue: String
    ) {
        self.books = books
        self.customFontFamilies = customFontFamilies
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.fontFamilyRawValue = fontFamilyRawValue
        self.themeRawValue = themeRawValue
        self.readAloudColorRawValue = readAloudColorRawValue
        self.readingBackgroundRawValue = readingBackgroundRawValue
        self.playbackSpeed = playbackSpeed
        self.playbackJumpInterval = playbackJumpInterval
        self.autoRewindAfterBackgroundMinutes = autoRewindAfterBackgroundMinutes
        self.uploadServerPort = uploadServerPort
        self.uploadServerRequiresPassword = uploadServerRequiresPassword
        self.uploadServerPassword = uploadServerPassword
        self.booksSortOptionRawValue = booksSortOptionRawValue
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

private enum PersistedAppStateLoadResult {
    case loaded(PersistedAppState)
    case missing
    case unreadable
}

@MainActor
final class AppStateStore: ObservableObject {
    @Published private(set) var books: [Book] = []
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
    @Published var booksSortOption = BooksSortOption.recentlyAdded { didSet { scheduleSave() } }

    private var bookSubscriptions: [UUID: AnyCancellable] = [:]
    private var saveTask: Task<Void, Never>?
    private var isHydratingState = false
    private var canPersistState = true

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
        books.sorted { lhs, rhs in
            isOrderedBefore(lhs, rhs, for: booksSortOption)
        }
    }

    func replaceBooks(_ books: [Book]) {
        self.books = booksSortedByImportedAt(books)
        configureBookSubscriptions()
        scheduleSave()
    }

    func addBook(_ book: Book) {
        books.append(book)
        books = booksSortedByImportedAt(books)
        observeBook(book)
        scheduleSave()
    }

    func removeBook(id: UUID) {
        books.removeAll { $0.id == id }
        bookSubscriptions[id] = nil
        scheduleSave()
    }

    func sortBooksByImportedAt() {
        books = booksSortedByImportedAt(books)
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
            applyPersistedState(persistedState)
        case .missing:
            canPersistState = true
            applyPersistedState(.default)
        case .unreadable:
            // Keep the unreadable file around for recovery; only allow
            // overwriting it once it has been safely moved aside.
            canPersistState = backUpUnreadableStateFile()
            applyPersistedState(.default)
        }

        configureBookSubscriptions()
    }

    private func backUpUnreadableStateFile() -> Bool {
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
            .appendingPathComponent("state-corrupt-\(timestamp).json", isDirectory: false)

        do {
            try FileManager.default.moveItem(at: stateURL, to: backupURL)
            return true
        } catch {
            return false
        }
    }

    private func readPersistedState() -> PersistedAppStateLoadResult {
        guard let stateURL = try? AppStorage.stateURL() else {
            return .unreadable
        }

        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return .missing
        }

        guard let data = try? Data(contentsOf: stateURL) else {
            return .unreadable
        }

        guard let persistedState = try? JSONDecoder().decode(PersistedAppState.self, from: data) else {
            return .unreadable
        }

        return .loaded(persistedState)
    }

    private func applyPersistedState(_ persistedState: PersistedAppState) {
        books = booksSortedByImportedAt(persistedState.books)
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
        bookSubscriptions[book.id] = book.objectWillChange.sink { [weak self] _ in
            // Books are only mutated on the main actor; forwarding
            // synchronously lets SwiftUI coalesce the invalidation with the
            // mutation instead of deferring it a runloop turn.
            MainActor.assumeIsolated {
                self?.objectWillChange.send()
                self?.scheduleSave()
            }
        }
    }

    private func isOrderedBefore(_ lhs: Book, _ rhs: Book, for option: BooksSortOption) -> Bool {
        switch option {
        case .recentlyAdded:
            return compareRecentlyAdded(lhs, rhs)
        case .titleAscending:
            return compareTitle(lhs, rhs, ascending: true)
        case .titleDescending:
            return compareTitle(lhs, rhs, ascending: false)
        case .authorAscending:
            return compareAuthor(lhs, rhs, ascending: true)
        case .authorDescending:
            return compareAuthor(lhs, rhs, ascending: false)
        }
    }

    private func compareRecentlyAdded(_ lhs: Book, _ rhs: Book) -> Bool {
        if let decision = descendingDecision(lhs.importedAt, rhs.importedAt) {
            return decision
        }
        if let decision = ascendingDecision(lhs.title, rhs.title) {
            return decision
        }
        if let decision = ascendingDecision(lhs.author, rhs.author) {
            return decision
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func compareTitle(_ lhs: Book, _ rhs: Book, ascending: Bool) -> Bool {
        if let decision = stringDecision(lhs.title, rhs.title, ascending: ascending) {
            return decision
        }
        if let decision = ascendingDecision(lhs.author, rhs.author) {
            return decision
        }
        if let decision = descendingDecision(lhs.importedAt, rhs.importedAt) {
            return decision
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func compareAuthor(_ lhs: Book, _ rhs: Book, ascending: Bool) -> Bool {
        if let decision = stringDecision(lhs.author, rhs.author, ascending: ascending) {
            return decision
        }
        if let decision = ascendingDecision(lhs.title, rhs.title) {
            return decision
        }
        if let decision = descendingDecision(lhs.importedAt, rhs.importedAt) {
            return decision
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func stringDecision(_ lhs: String, _ rhs: String, ascending: Bool) -> Bool? {
        let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
        switch comparison {
        case .orderedAscending:
            return ascending
        case .orderedDescending:
            return !ascending
        case .orderedSame:
            return nil
        }
    }

    private func ascendingDecision(_ lhs: String, _ rhs: String) -> Bool? {
        stringDecision(lhs, rhs, ascending: true)
    }

    private func descendingDecision(_ lhs: Date, _ rhs: Date) -> Bool? {
        if lhs > rhs {
            return true
        }
        if lhs < rhs {
            return false
        }
        return nil
    }

    private func booksSortedByImportedAt(_ books: [Book]) -> [Book] {
        books.sorted { $0.importedAt > $1.importedAt }
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
            self?.writeStateToDisk()
        }
    }

    private func writeStateToDisk() {
        let persistedState = currentPersistedState()

        guard let data = try? JSONEncoder().encode(persistedState),
              let stateURL = try? AppStorage.stateURL()
        else {
            return
        }

        try? data.write(to: stateURL, options: .atomic)
    }
}
