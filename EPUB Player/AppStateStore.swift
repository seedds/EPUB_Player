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

private struct PersistedAppState: Codable {
    var books: [Book]
    var customFontFamilies: [CustomFontStore.ImportedFontFamily]
    var fontSize: Double
    var lineHeight: Double
    var fontFamilyRawValue: String
    var themeRawValue: String
    var readAloudColorRawValue: String
    var playbackSpeed: Double
    var playbackJumpInterval: Double
    var autoRewindAfterBackgroundMinutes: Int?
    var uploadServerPort: Int
    var booksSortOptionRawValue: String

    static let `default` = PersistedAppState(
        books: [],
        customFontFamilies: [],
        fontSize: ReaderSettings.defaultFontSize,
        lineHeight: ReaderSettings.defaultLineHeight,
        fontFamilyRawValue: "Literata",
        themeRawValue: AppThemeOption.system.rawValue,
        readAloudColorRawValue: ReaderSettings.defaultReadAloudColorHex,
        playbackSpeed: ReaderSettings.defaultPlaybackSpeed,
        playbackJumpInterval: ReaderSettings.defaultPlaybackJumpInterval,
        autoRewindAfterBackgroundMinutes: ReaderSettings.defaultAutoRewindAfterBackgroundMinutes,
        uploadServerPort: ReaderSettings.defaultUploadServerPort,
        booksSortOptionRawValue: BooksSortOption.recentlyAdded.rawValue
    )
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
    @Published var playbackSpeed = ReaderSettings.defaultPlaybackSpeed { didSet { scheduleSave() } }
    @Published var playbackJumpInterval = ReaderSettings.defaultPlaybackJumpInterval { didSet { scheduleSave() } }
    @Published var autoRewindAfterBackgroundMinutes = ReaderSettings.defaultAutoRewindAfterBackgroundMinutes { didSet { scheduleSave() } }
    @Published var uploadServerPort = ReaderSettings.defaultUploadServerPort { didSet { scheduleSave() } }
    @Published var booksSortOption = BooksSortOption.recentlyAdded { didSet { scheduleSave() } }

    private var bookSubscriptions: [UUID: AnyCancellable] = [:]
    private var saveTask: Task<Void, Never>?

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
        saveTask?.cancel()
        saveTask = nil
        writeStateToDisk()
    }

    private func loadState() {
        applyPersistedState(readPersistedState())
        configureBookSubscriptions()
    }

    private func readPersistedState() -> PersistedAppState {
        guard let data = try? Data(contentsOf: try AppStorage.stateURL()),
              let persistedState = try? JSONDecoder().decode(PersistedAppState.self, from: data)
        else {
            return .default
        }

        return persistedState
    }

    private func applyPersistedState(_ persistedState: PersistedAppState) {
        books = booksSortedByImportedAt(persistedState.books)
        customFontFamilies = persistedState.customFontFamilies
        fontSize = persistedState.fontSize
        lineHeight = persistedState.lineHeight
        fontFamilyRawValue = persistedState.fontFamilyRawValue
        themeRawValue = persistedState.themeRawValue
        readAloudColorRawValue = persistedState.readAloudColorRawValue
        playbackSpeed = persistedState.playbackSpeed
        playbackJumpInterval = persistedState.playbackJumpInterval
        autoRewindAfterBackgroundMinutes = ReaderSettings.normalizedAutoRewindAfterBackgroundMinutes(
            persistedState.autoRewindAfterBackgroundMinutes ?? ReaderSettings.defaultAutoRewindAfterBackgroundMinutes
        )
        uploadServerPort = persistedState.uploadServerPort
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
            Task { @MainActor in
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
            playbackSpeed: playbackSpeed,
            playbackJumpInterval: playbackJumpInterval,
            autoRewindAfterBackgroundMinutes: ReaderSettings.normalizedAutoRewindAfterBackgroundMinutes(
                autoRewindAfterBackgroundMinutes
            ),
            uploadServerPort: uploadServerPort,
            booksSortOptionRawValue: booksSortOption.rawValue
        )
    }

    private func scheduleSave() {
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
