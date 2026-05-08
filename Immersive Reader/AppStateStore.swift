//
//  AppStateStore.swift
//  Immersive Reader
//
//  Created by OpenCode on 8/5/2026.
//

import Combine
import Foundation

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
    var uploadServerPort: Int

    static let `default` = PersistedAppState(
        books: [],
        customFontFamilies: [],
        fontSize: ReaderSettings.defaultFontSize,
        lineHeight: ReaderSettings.defaultLineHeight,
        fontFamilyRawValue: "",
        themeRawValue: AppThemeOption.system.rawValue,
        readAloudColorRawValue: ReaderSettings.defaultReadAloudColorHex,
        playbackSpeed: ReaderSettings.defaultPlaybackSpeed,
        playbackJumpInterval: ReaderSettings.defaultPlaybackJumpInterval,
        uploadServerPort: ReaderSettings.defaultUploadServerPort
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
    @Published var uploadServerPort = ReaderSettings.defaultUploadServerPort { didSet { scheduleSave() } }

    private var bookSubscriptions: [UUID: AnyCancellable] = [:]
    private var saveTask: Task<Void, Never>?

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

    func replaceBooks(_ books: [Book]) {
        self.books = books.sorted { $0.importedAt > $1.importedAt }
        configureBookSubscriptions()
        scheduleSave()
    }

    func addBook(_ book: Book) {
        books.append(book)
        books.sort { $0.importedAt > $1.importedAt }
        observeBook(book)
        scheduleSave()
    }

    func removeBook(id: UUID) {
        books.removeAll { $0.id == id }
        bookSubscriptions[id] = nil
        scheduleSave()
    }

    func sortBooksByImportedAt() {
        books.sort { $0.importedAt > $1.importedAt }
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
        let persistedState: PersistedAppState
        if let data = try? Data(contentsOf: try AppStorage.stateURL()),
           let decodedState = try? JSONDecoder().decode(PersistedAppState.self, from: data) {
            persistedState = decodedState
        } else {
            persistedState = .default
        }

        books = persistedState.books.sorted { $0.importedAt > $1.importedAt }
        customFontFamilies = persistedState.customFontFamilies
        fontSize = persistedState.fontSize
        lineHeight = persistedState.lineHeight
        fontFamilyRawValue = persistedState.fontFamilyRawValue
        themeRawValue = persistedState.themeRawValue
        readAloudColorRawValue = persistedState.readAloudColorRawValue
        playbackSpeed = persistedState.playbackSpeed
        playbackJumpInterval = persistedState.playbackJumpInterval
        uploadServerPort = persistedState.uploadServerPort
        configureBookSubscriptions()
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
                self?.scheduleSave()
            }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self?.writeStateToDisk()
        }
    }

    private func writeStateToDisk() {
        let persistedState = PersistedAppState(
            books: books,
            customFontFamilies: customFontFamilies,
            fontSize: fontSize,
            lineHeight: lineHeight,
            fontFamilyRawValue: fontFamilyRawValue,
            themeRawValue: themeRawValue,
            readAloudColorRawValue: readAloudColorRawValue,
            playbackSpeed: playbackSpeed,
            playbackJumpInterval: playbackJumpInterval,
            uploadServerPort: uploadServerPort
        )

        guard let data = try? JSONEncoder().encode(persistedState),
              let stateURL = try? AppStorage.stateURL()
        else {
            return
        }

        try? data.write(to: stateURL, options: .atomic)
    }
}
