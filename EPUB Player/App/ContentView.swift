//
//  ContentView.swift
//  EPUB Player
//
//  Created by F2PGOD on 25/4/2026.
//

import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ReadiumShared

struct ContentView: View {
    @EnvironmentObject private var store: AppStateStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var uploadServer = UploadServerController()
    @State private var hasResumedPendingMediaOverlayPreparation = false

    var body: some View {
        TabView {
            BooksView(controller: uploadServer)
                .tabItem {
                    Label("Books", systemImage: "books.vertical")
                }

            UploadView(controller: uploadServer)
                .tabItem {
                    Label("Upload", systemImage: "network")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
        .preferredColorScheme(ReaderSettings.appTheme(from: store.themeRawValue).preferredColorScheme)
        .task {
            guard !hasResumedPendingMediaOverlayPreparation else {
                return
            }
            hasResumedPendingMediaOverlayPreparation = true
            MediaOverlayPreparationCoordinator.shared.resumePendingBooks(store: store)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                return
            }

            await BookImportService.restoreMissingCovers(store: store)
        }
    }
}

private struct BooksView: View {
    @EnvironmentObject private var store: AppStateStore
    @ObservedObject var controller: UploadServerController

    @State private var isImporting = false
    @State private var isRefreshing = false
    @State private var refreshProgress = 0.0
    @State private var refreshStatus = ""
    @State private var importError: String?
    @State private var selectedBook: Book?

    private var books: [Book] {
        store.sortedBooks
    }

    var body: some View {
        NavigationStack {
            booksContent
            .allowsHitTesting(!isBusy)
            .toolbar {
                sortToolbarItem
                refreshToolbarItem
                importToolbarItem
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.epub],
                allowsMultipleSelection: true,
                onCompletion: handleImport
            )
            .alert(
                "Import Failed",
                isPresented: Binding(
                    get: { isShowingImportError },
                    set: { isPresented in
                        if !isPresented {
                            importError = nil
                            controller.clearManualImportError()
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrorMessage)
            }
            .navigationDestination(item: $selectedBook) { book in
                ReaderView(book: book)
            }
            .overlay {
                if isRefreshing {
                    refreshOverlay
                } else if controller.isImportingBooks {
                    importOverlay
                }
            }
        }
    }

    @ViewBuilder
    private var booksContent: some View {
        if books.isEmpty {
            emptyBooksState
        } else {
            booksList
        }
    }

    private var emptyBooksState: some View {
        ContentUnavailableView {
            Label("No EPUB Books", systemImage: "book.closed")
        } description: {
            Text("Import EPUB3 books to start building your read-aloud library.")
        } actions: {
            Button("Import EPUB") {
                isImporting = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var booksList: some View {
        List {
            ForEach(books) { book in
                BookRow(book: book, showsTopSeparator: book.id == books.first?.id)
                    .contentShape(Rectangle())
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .onTapGesture {
                        selectedBook = book
                    }
            }
            .onDelete { offsets in
                deleteBooks(at: offsets, from: books)
            }
        }
        .listStyle(.plain)
    }

    private var isShowingImportError: Bool {
        importError != nil || controller.manualImportErrorMessage != nil
    }

    private var importErrorMessage: String {
        controller.manualImportErrorMessage ?? importError ?? "Unknown error"
    }

    private var sortToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Sort Books", selection: $store.booksSortOption) {
                    ForEach(BooksSortOption.allCases) { option in
                        Text(option.name)
                            .tag(option)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .disabled(store.books.isEmpty)
            .accessibilityLabel("Sort Books")
        }
    }

    private var refreshToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                refreshBooks()
            } label: {
                if isRefreshing {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(isBusy)
            .accessibilityLabel("Refresh Books")
        }
    }

    private var importToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                isImporting = true
            } label: {
                Label("Import EPUB", systemImage: "plus")
            }
            .disabled(isBusy)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            controller.importBooks(from: urls, store: store)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func deleteBooks(at offsets: IndexSet, from books: [Book]) {
        let fileManager = FileManager.default

        for index in offsets {
            guard books.indices.contains(index) else {
                continue
            }
            let book = books[index]
            MediaOverlayPreparationCoordinator.shared.cancelPreparation(for: book.id)
            // Remove the store record regardless of disk-cleanup success, but
            // log failures so orphaned files are diagnosable.
            do {
                if let epubURL = try? book.resolvedEPUBFileURL() {
                    try fileManager.removeItem(at: epubURL)
                }
                try BookAssetCacheService.removeAllCachedAssets(for: book.id)
            } catch {
                print("ContentView: failed to remove files for \(book.originalFilename): \(error)")
            }
            store.removeBook(id: book.id)
        }

        store.persistNow()
    }

    private func refreshBooks() {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        refreshProgress = 0
        refreshStatus = "Starting refresh..."

        Task {
            defer {
                isRefreshing = false
                refreshStatus = ""
            }

            do {
                try await BookImportService.refreshBooksFromDocuments(store: store) { progress in
                    refreshProgress = progress.fractionCompleted
                    refreshStatus = progress.message
                }
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var refreshOverlay: some View {
        progressOverlay(
            primaryText: refreshStatus,
            secondaryText: nil,
            progress: refreshProgress
        )
    }

    @ViewBuilder
    private var importOverlay: some View {
        progressOverlay(
            primaryText: controller.currentImportFilename ?? "Importing EPUB...",
            secondaryText: [controller.importStatus, controller.currentImportCountText]
                .compactMap { $0 }
                .joined(separator: "\n"),
            progress: controller.importProgress
        )
    }

    @ViewBuilder
    private func progressOverlay(primaryText: String, secondaryText: String?, progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView(value: progress)
                    .tint(.accentColor)

                Text(primaryText)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                if let secondaryText, !secondaryText.isEmpty {
                    Text(secondaryText)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                Text("\(Int(progress * 100))%")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 320)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.14), radius: 24, y: 10)
            }
            .padding(.horizontal, 24)
        }
    }

    private var isBusy: Bool {
        isRefreshing || controller.isImportingBooks
    }

}

private struct BookRow: View {
    @ObservedObject var book: Book
    let showsTopSeparator: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsTopSeparator {
                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(height: 1)
            }

            HStack(spacing: 14) {
                BookCoverView(book: book)

                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.headline)

                    Text(book.author)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let audioDurationText {
                        Text(audioDurationText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    if (book.mediaOverlayClipCount ?? 0) > 0 {
                        Image(systemName: "waveform")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                            .accessibilityLabel("Read aloud ready")
                    } else if book.mediaOverlayPreparationState == .pending || book.mediaOverlayPreparationState == .processing {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Preparing read aloud")
                    } else if book.mediaOverlayPreparationState == .failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Read aloud unavailable")
                    }

                    BookProgressRing(progress: readingProgress)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(rowAccessibilityLabel)

            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowAccessibilityLabel: String {
        var parts = [book.title, "by \(book.author)"]
        if let audioDurationText {
            parts.append("read-aloud duration \(audioDurationText)")
        }
        if (book.mediaOverlayClipCount ?? 0) > 0 {
            parts.append("read-aloud ready")
        } else if book.mediaOverlayPreparationState == .pending || book.mediaOverlayPreparationState == .processing {
            parts.append("preparing read-aloud")
        } else if book.mediaOverlayPreparationState == .failed {
            parts.append("read-aloud unavailable")
        }
        parts.append("\(Int((readingProgress * 100).rounded())) percent read")
        return parts.joined(separator: ", ")
    }

    private var readingProgress: Double {
        guard let lastLocatorJSON = book.lastLocatorJSON,
              let locator = try? Locator(jsonString: lastLocatorJSON)
        else {
            return 0
        }

        let progress = locator.locations.totalProgression ?? locator.locations.progression ?? 0
        return min(max(progress, 0), 1)
    }

    private var audioDurationText: String? {
        guard let duration = book.mediaOverlayDuration, duration > 0 else {
            return nil
        }

        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours == 0 {
            return "\(minutes)m \(seconds)s"
        }

        return "\(hours)h \(minutes)m \(seconds)s"
    }
}

private struct BookProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            ProgressPieSlice(progress: progress)
                .fill(Color.accentColor)
        }
        .frame(width: 18, height: 18)
        .overlay {
            Circle()
                .stroke(Color.accentColor, lineWidth: 1)
        }
        .accessibilityElement()
        .accessibilityLabel("Reading progress")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }
}

private struct ProgressPieSlice: Shape {
    let progress: Double

    func path(in rect: CGRect) -> Path {
        let clampedProgress = min(max(progress, 0), 1)
        guard clampedProgress > 0 else {
            return Path()
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let startAngle = Angle.degrees(-90)
        let endAngle = Angle.degrees(-90 + (360 * clampedProgress))

        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.closeSubpath()
        return path
    }
}

private struct BookCoverView: View {
    // 44x56pt at 3x, with headroom; decoding covers at full resolution in a
    // list row spikes memory and hitches scrolling.
    nonisolated private static let maxThumbnailPixelSize: CGFloat = 180

    let book: Book

    @State private var coverImage: UIImage?

    init(book: Book) {
        self.book = book
        if let coverImageURL = try? book.resolvedCoverImageURL() {
            _coverImage = State(initialValue: CoverThumbnailLoader.cachedThumbnail(
                atPath: coverImageURL.path,
                maxPixelSize: Self.maxThumbnailPixelSize
            ))
        }
    }

    var body: some View {
        Group {
            if let image = coverImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.blue.gradient)
                    .overlay {
                        Image(systemName: "book.closed.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: 44, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        }
        .task(id: book.coverImagePath) {
            guard let coverImageURL = try? book.resolvedCoverImageURL() else {
                coverImage = nil
                return
            }

            let path = coverImageURL.path
            coverImage = await Task.detached(priority: .userInitiated) {
                CoverThumbnailLoader.thumbnail(atPath: path, maxPixelSize: Self.maxThumbnailPixelSize)
            }.value
        }
    }
}

private enum CoverThumbnailLoader {
    // NSCache is documented thread-safe.
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    nonisolated static func cachedThumbnail(atPath path: String, maxPixelSize: CGFloat) -> UIImage? {
        cache.object(forKey: cacheKey(for: path, maxPixelSize: maxPixelSize))
    }

    nonisolated static func thumbnail(atPath path: String, maxPixelSize: CGFloat) -> UIImage? {
        let key = cacheKey(for: path, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            return nil
        }

        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }

    nonisolated private static func cacheKey(for path: String, maxPixelSize: CGFloat) -> NSString {
        "\(path)#\(Int(maxPixelSize))" as NSString
    }
}

private struct UploadView: View {
    @EnvironmentObject private var store: AppStateStore
    @ObservedObject var controller: UploadServerController
    @FocusState private var isPortFieldFocused: Bool
    @FocusState private var isPasswordFieldFocused: Bool
    @State private var portText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Server") {
                    LabeledContent("Status", value: controller.status.title)

                    HStack {
                        Text("Port")

                        Spacer()

                        TextField("80", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 88)
                            .focused($isPortFieldFocused)
                            .disabled(controller.status == .running)
                    }

                    Toggle("Require Password", isOn: $store.uploadServerRequiresPassword)
                        .disabled(controller.status == .running)

                    if store.uploadServerRequiresPassword {
                        HStack {
                            Text("Password")

                            Spacer()

                            TextField("Password", text: $store.uploadServerPassword)
                                .multilineTextAlignment(.trailing)
                                .focused($isPasswordFieldFocused)
                                .disabled(controller.status == .running)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }

                    if let serverURL = controller.serverURL {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(serverURL.absoluteString)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    } else if case .running = controller.status {
                        Text("Server is running, but no Wi-Fi IP address was found. Make sure this device is connected to the same network as the computer uploading EPUB or font files.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        isPasswordFieldFocused = false
                        commitPortText()
                        switch controller.status {
                        case .running:
                            controller.stop()
                        case .stopped, .failed:
                            controller.port = ReaderSettings.uploadServerPort(from: store.uploadServerPort)
                            controller.start(store: store)
                        }
                    } label: {
                        Text(controller.status == .running ? "Stop Server" : "Start Server")
                    }

                }

                if case .failed(let message) = controller.status {
                    Section("Error") {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }

                Section("Storage") {
                    Text("The server accepts .epub, .ttf, and .otf files. EPUBs are stored in the app's Documents/Books folder and should appear in Files under On My iPhone/EPUBPlayer/Books. Covers, read-aloud cache, uploaded fonts, and app state are stored in Documents/Cache.")
                }

                if !controller.activeUploads.isEmpty {
                    Section("Upload Activity") {
                        ForEach(controller.activeUploads) { upload in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(upload.filename)
                                        .font(.headline)
                                        .lineLimit(2)

                                    Spacer()

                                    Text(uploadStatusText(upload))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(upload.failureMessage == nil ? Color.secondary : Color.red)
                                }

                                if let failureMessage = upload.failureMessage {
                                    Text(failureMessage)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                } else {
                                    ProgressView(value: upload.isImporting ? 1 : upload.progress)

                                    HStack(spacing: 12) {
                                        Text(uploadProgressText(upload))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        Spacer()

                                        if upload.isUploading {
                                            Text(formattedTransferRate(upload.speedBytesPerSecond))
                                                .font(.caption)
                                                .monospacedDigit()
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Recent Uploads") {
                    if controller.recentUploads.isEmpty {
                        Text("No uploads yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(controller.recentUploads) { upload in
                            VStack(alignment: .leading) {
                                Text(upload.filename)
                                Text(upload.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Upload")
            .onAppear {
                syncPortText()
            }
            .onChange(of: isPortFieldFocused) { _, isFocused in
                if !isFocused {
                    commitPortText()
                }
            }
            .onChange(of: store.uploadServerPort) { _, _ in
                syncPortText()
            }
            .onChange(of: isPasswordFieldFocused) { _, isFocused in
                if !isFocused {
                    store.uploadServerPassword = store.uploadServerPassword.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }

    private func syncPortText() {
        let normalizedPort = ReaderSettings.normalizedUploadServerPort(store.uploadServerPort)
        if store.uploadServerPort != normalizedPort {
            store.uploadServerPort = normalizedPort
        }
        portText = "\(normalizedPort)"
        if controller.status != .running {
            controller.port = ReaderSettings.uploadServerPort(from: normalizedPort)
        }
    }

    private func commitPortText() {
        let digits = String(portText.filter(\.isNumber))
        let normalizedPort = ReaderSettings.normalizedUploadServerPort(Int(digits) ?? ReaderSettings.defaultUploadServerPort)
        store.uploadServerPort = normalizedPort
        portText = "\(normalizedPort)"
        if controller.status != .running {
            controller.port = ReaderSettings.uploadServerPort(from: normalizedPort)
        }
    }

    private func uploadStatusText(_ upload: UploadServerController.ActiveUpload) -> String {
        if upload.isImporting {
            return "Importing..."
        }

        if upload.failureMessage != nil {
            return "Failed"
        }

        return "\(Int(upload.progress * 100))%"
    }

    private func uploadProgressText(_ upload: UploadServerController.ActiveUpload) -> String {
        let received = ByteCountFormatter.string(fromByteCount: upload.receivedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: upload.totalBytes, countStyle: .file)
        return "\(received) / \(total)"
    }

    private func formattedTransferRate(_ bytesPerSecond: Double) -> String {
        let roundedRate = Int64(bytesPerSecond.rounded())
        let value = ByteCountFormatter.string(fromByteCount: roundedRate, countStyle: .file)
        return "\(value)/s"
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var store: AppStateStore
    @State private var customFontFamilies: [CustomFontStore.ImportedFontFamily] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Reader") {
                    NavigationLink {
                        SkipIntervalSettingView(playbackJumpInterval: $store.playbackJumpInterval)
                            .toolbar(.hidden, for: .tabBar)
                    } label: {
                        SettingsNavigationRow(title: "Skip Interval") {
                            Text(ReaderSettings.playbackJumpIntervalText(store.playbackJumpInterval))
                        }
                    }

                    NavigationLink {
                        AutoRewindSettingView(autoRewindAfterBackgroundMinutes: $store.autoRewindAfterBackgroundMinutes)
                            .toolbar(.hidden, for: .tabBar)
                    } label: {
                        SettingsNavigationRow(title: "Auto Rewind") {
                            Text(ReaderSettings.autoRewindAfterBackgroundText(store.autoRewindAfterBackgroundMinutes))
                        }
                    }

                    NavigationLink {
                        FontFamilySelectionView(
                            selectedFontFamilyRawValue: $store.fontFamilyRawValue,
                            customFontFamilies: customFontFamilies
                        )
                        .toolbar(.hidden, for: .tabBar)
                    } label: {
                        SettingsNavigationRow(title: "Font Family") {
                            Text(selectedFontFamilyName)
                        }
                    }

                    NavigationLink {
                        FontSizeSettingView(fontSize: $store.fontSize)
                            .toolbar(.hidden, for: .tabBar)
                    } label: {
                        SettingsNavigationRow(title: "Font Size") {
                            Text(ReaderSettings.fontSizeText(store.fontSize))
                        }
                    }

                    NavigationLink {
                        LineHeightSettingView(lineHeight: $store.lineHeight)
                            .toolbar(.hidden, for: .tabBar)
                    } label: {
                        SettingsNavigationRow(title: "Line Height") {
                            Text(ReaderSettings.lineHeightText(store.lineHeight))
                        }
                    }

                    NavigationLink {
                        CustomFontsView(onFontsChanged: loadCustomFonts)
                            .toolbar(.hidden, for: .tabBar)
                    } label: {
                        SettingsNavigationRow(title: "Custom Fonts") {
                            Text(customFontStatusText)
                        }
                    }
                }

                Section("Appearance") {
                    NavigationLink {
                        ThemeSelectionView(selectedThemeRawValue: $store.themeRawValue)
                            .toolbar(.hidden, for: .tabBar)
                    } label: {
                        SettingsNavigationRow(title: "Theme") {
                            Text(selectedThemeName)
                        }
                    }

                    NavigationLink {
                        ReadAloudColorEditor(colorHex: $store.readAloudColorRawValue)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 16)
                            .navigationTitle("Highlight Color")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar(.hidden, for: .tabBar)
                    } label: {
                        SettingsNavigationRow(title: "Highlight Color") {
                            Circle()
                                .fill(ReaderSettings.color(from: store.readAloudColorRawValue))
                                .frame(width: 22, height: 22)
                                .overlay {
                                    Circle()
                                        .stroke(.black.opacity(0.08), lineWidth: 1)
                                }
                        }
                    }

                    NavigationLink {
                        ReadingBackgroundSelectionView(selectedReadingBackgroundRawValue: $store.readingBackgroundRawValue)
                            .toolbar(.hidden, for: .tabBar)
                    } label: {
                        SettingsNavigationRow(title: "Reading Background") {
                            Circle()
                                .fill(selectedReadingBackground.swatchColor)
                                .frame(width: 22, height: 22)
                                .overlay {
                                    Circle()
                                        .stroke(.black.opacity(0.12), lineWidth: 1)
                                }
                        }
                    }
                }

            }
            .environment(\.defaultMinListRowHeight, 28)
            .navigationTitle("Settings")
            .onAppear(perform: loadCustomFonts)
        }
    }

    private var customFontStatusText: String {
        guard !customFontFamilies.isEmpty else {
            return "None"
        }

        return customFontFamilies.count == 1 ? "1 family" : "\(customFontFamilies.count) families"
    }

    private var selectedFontFamilyName: String {
        ReaderSettings.fontFamilyName(from: store.fontFamilyRawValue, customFontFamilies: customFontFamilies)
    }

    private var selectedThemeName: String {
        ReaderSettings.appTheme(from: store.themeRawValue).name
    }

    private var selectedReadingBackground: ReadingBackgroundOption {
        ReaderSettings.readingBackground(from: store.readingBackgroundRawValue)
    }

    private func loadCustomFonts() {
        customFontFamilies = CustomFontStore.allFamilies(store: store)
    }
}

private struct SettingsNavigationRow<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)

            Spacer(minLength: 12)

            trailing
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
    }
}

private struct SkipIntervalSettingView: View {
    @Binding var playbackJumpInterval: Double

    var body: some View {
        Form {
            Section {
                ForEach(ReaderSettings.playbackJumpIntervalOptions, id: \.self) { interval in
                    SettingsSelectionRow(
                        title: ReaderSettings.playbackJumpIntervalText(interval),
                        isSelected: interval == ReaderSettings.normalizedPlaybackJumpInterval(playbackJumpInterval)
                    ) {
                        playbackJumpInterval = interval
                    }
                }
            }
        }
        .navigationTitle("Skip Interval")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FontSizeSettingView: View {
    @Binding var fontSize: Double

    var body: some View {
        Form {
            Section {
                ForEach(ReaderSettings.fontSizeOptions, id: \.self) { size in
                    SettingsSelectionRow(
                        title: ReaderSettings.fontSizeText(size),
                        isSelected: ReaderSettings.fontSizeText(size) == ReaderSettings.fontSizeText(fontSize)
                    ) {
                        fontSize = size
                    }
                }
            }
        }
        .navigationTitle("Font Size")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LineHeightSettingView: View {
    @Binding var lineHeight: Double

    var body: some View {
        Form {
            Section {
                ForEach(ReaderSettings.lineHeightOptions, id: \.self) { height in
                    SettingsSelectionRow(
                        title: ReaderSettings.lineHeightText(height),
                        isSelected: ReaderSettings.lineHeightText(height) == ReaderSettings.lineHeightText(lineHeight)
                    ) {
                        lineHeight = height
                    }
                }
            }
        }
        .navigationTitle("Line Height")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ThemeSelectionView: View {
    @EnvironmentObject private var store: AppStateStore
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selectedThemeRawValue: String

    var body: some View {
        Form {
            Section {
                ForEach(AppThemeOption.allCases) { option in
                    SettingsSelectionRow(
                        title: option.name,
                        isSelected: option.rawValue == selectedThemeRawValue
                    ) {
                        selectedThemeRawValue = option.rawValue
                        // For `.system`, resolve against the DEVICE scheme, not
                        // the environment's — the latter reflects the outgoing
                        // theme's forced scheme (e.g. Light on a dark device),
                        // which would pick a white background right before the
                        // app flips to dark.
                        let effectiveScheme = option == .system ? Self.deviceColorScheme : colorScheme
                        store.readingBackgroundRawValue = ReaderSettings.defaultBackground(
                            forTheme: option,
                            colorScheme: effectiveScheme
                        ).rawValue
                    }
                }
            }
        }
        .navigationTitle("Theme")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The device's actual light/dark setting, independent of any per-view
    /// `preferredColorScheme` override the active theme applies. Reads the
    /// window scene's trait collection (the app-level override is applied at the
    /// SwiftUI view level, not the scene, so the scene still reflects the
    /// system setting).
    private static var deviceColorScheme: ColorScheme {
        let style = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .traitCollection
            .userInterfaceStyle
        return style == .dark ? .dark : .light
    }
}

private struct ReadingBackgroundSelectionView: View {
    @Binding var selectedReadingBackgroundRawValue: String

    var body: some View {
        Form {
            Section {
                ForEach(ReadingBackgroundOption.allCases) { option in
                    Button {
                        selectedReadingBackgroundRawValue = option.rawValue
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(option.swatchColor)
                                .frame(width: 22, height: 22)
                                .overlay {
                                    Circle()
                                        .stroke(.black.opacity(0.12), lineWidth: 1)
                                }

                            Text(option.name)

                            Spacer(minLength: 12)

                            if option.rawValue == selectedReadingBackgroundRawValue {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Recolors the page and text while reading. Changing your Theme resets this to White (Light) or Black (Dark).")
            }
        }
        .navigationTitle("Reading Background")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AutoRewindSettingView: View {
    @Binding var autoRewindAfterBackgroundMinutes: Int

    var body: some View {
        Form {
            Section {
                ForEach(ReaderSettings.autoRewindAfterBackgroundMinuteOptions, id: \.self) { minutes in
                    SettingsSelectionRow(
                        title: ReaderSettings.autoRewindAfterBackgroundText(minutes),
                        isSelected: minutes == ReaderSettings.normalizedAutoRewindAfterBackgroundMinutes(autoRewindAfterBackgroundMinutes)
                    ) {
                        autoRewindAfterBackgroundMinutes = minutes
                    }
                }
            } footer: {
                Text("When you return after the selected time away, playback rewinds 10 seconds to the start of that sentence.")
            }
        }
        .navigationTitle("Auto Rewind")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsSelectionRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)

                Spacer(minLength: 12)

                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CustomFontsView: View {
    @EnvironmentObject private var store: AppStateStore
    let onFontsChanged: () -> Void

    @State private var importedFamilies: [CustomFontStore.ImportedFontFamily] = []
    @State private var expandedFamilyIDs: Set<UUID> = []
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var familyPendingDeletion: CustomFontStore.ImportedFontFamily?

    var body: some View {
        Form {
            Section {
                Button {
                    isImporting = true
                } label: {
                    Label("Add Fonts", systemImage: "plus")
                }
            } footer: {
                Text("Imported fonts appear in Reader > Font Family. Reopen the current book after adding a font to use it in the reader.")
            }

            if importedFamilies.isEmpty {
                Section {
                    Text("No custom fonts imported yet.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Imported Font Families")
                }
            } else {
                ForEach(importedFamilies) { family in
                    Section {
                        DisclosureGroup(isExpanded: expansionBinding(for: family.id)) {
                            ForEach(family.files) { file in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.originalFilename)
                                        Text(file.style.label)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                .swipeActions {
                                    Button("Delete File", role: .destructive) {
                                        removeFiles(withIDs: [file.id])
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(family.displayName)

                                Spacer()

                                Text(family.fileCount == 1 ? "1 file" : "\(family.fileCount) files")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .swipeActions {
                            Button("Delete Family", role: .destructive) {
                                familyPendingDeletion = family
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Custom Fonts")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.ttf, .otf],
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        .alert(
            "Font Import Failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .alert(
            "Delete Font Family?",
            isPresented: Binding(
                get: { familyPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        familyPendingDeletion = nil
                    }
                }
            ),
            presenting: familyPendingDeletion
        ) { family in
            Button("Delete", role: .destructive) {
                removeFamilies(withIDs: [family.id])
            }
            Button("Cancel", role: .cancel) {}
        } message: { family in
            Text("Delete \(family.displayName) and all of its imported font files?")
        }
        .onAppear(perform: reloadFonts)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            let importedFamilies = try CustomFontStore.importFonts(from: urls, store: store)
            reloadFonts()
            onFontsChanged()
            if let registrationWarning = CustomFontStore.registrationFailureMessage(for: importedFamilies) {
                errorMessage = registrationWarning
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeFamilies(withIDs ids: [UUID]) {
        do {
            try CustomFontStore.removeFamilies(withIDs: ids, store: store)
            familyPendingDeletion = nil
            reloadFonts()
            onFontsChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeFiles(withIDs ids: [UUID]) {
        do {
            try CustomFontStore.removeFiles(withIDs: ids, store: store)
            reloadFonts()
            onFontsChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadFonts() {
        importedFamilies = CustomFontStore.allFamilies(store: store)
        expandedFamilyIDs.formIntersection(Set(importedFamilies.map(\.id)))
    }

    private func expansionBinding(for familyID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedFamilyIDs.contains(familyID) },
            set: { isExpanded in
                if isExpanded {
                    expandedFamilyIDs.insert(familyID)
                } else {
                    expandedFamilyIDs.remove(familyID)
                }
            }
        )
    }
}

private struct ReadAloudColorEditor: View {
    @Binding var colorHex: String
    @State private var hexText = ""

    private let swatchColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 6)
    private let presetHexValues = [
        "#FF3B30", "#FF6B6B", "#FF2D55", "#D63384", "#AF52DE", "#7C3AED",
        "#5856D6", "#3B82F6", "#0A84FF", "#06B6D4", "#14B8A6", "#10B981",
        "#34C759", "#84CC16", "#A3E635", "#FACC15", "#FF9F0A", "#F97316",
        "#8B5E3C", "#A2845E", "#636366", "#8E8E93", "#C7C7CC", "#E5E5EA",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ReadAloudSpectrumView(
                hue: colorHSB.hue,
                saturation: colorHSB.saturation,
                brightness: colorHSB.brightness,
                onChange: updateSpectrumColor
            )

            VStack(alignment: .leading, spacing: 10) {
                ReadAloudHueSlider(
                    hue: colorHSB.hue,
                    onChange: { updateSpectrumColor(hue: $0, saturation: colorHSB.saturation, brightness: colorHSB.brightness) }
                )
            }

            LazyVGrid(columns: swatchColumns, spacing: 10) {
                ForEach(presetHexValues, id: \.self) { presetHex in
                    Button {
                        colorHex = presetHex
                    } label: {
                        Circle()
                            .fill(ReaderSettings.color(from: presetHex))
                            .frame(width: 30, height: 30)
                            .overlay {
                                Circle()
                                    .stroke(isSelectedSwatch(presetHex) ? Color.primary : Color.black.opacity(0.08), lineWidth: isSelectedSwatch(presetHex) ? 3 : 1)
                            }
                            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Highlight color \(presetHex)")
                    .accessibilityAddTraits(isSelectedSwatch(presetHex) ? .isSelected : [])
                }
            }

            HStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(ReaderSettings.color(from: colorHex))
                    .frame(width: 72, height: 56)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.black.opacity(0.08), lineWidth: 1)
                    }

                HStack(spacing: 0) {
                    Text("#")
                        .font(.system(size: 28, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.primary)

                    TextField("685C39", text: $hexText)
                        .font(.system(size: 28, weight: .medium, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onChange(of: hexText) { _, newValue in
                            let normalized = ReaderSettings.normalizedReadAloudColorText(newValue)
                            if normalized != newValue {
                                hexText = normalized
                                return
                            }

                            if let hex = ReaderSettings.readAloudColorHex(from: normalized) {
                                colorHex = hex
                            }
                        }
                        .onSubmit {
                            hexText = ReaderSettings.readAloudColorText(from: colorHex)
                        }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.black.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
            .accessibilityLabel("sRGB Hex")
            .accessibilityValue(readAloudHexDisplay)
            .onTapGesture {
                hexText = ReaderSettings.readAloudColorText(from: colorHex)
            }
            Spacer(minLength: 0)
        }
        .onAppear {
            hexText = ReaderSettings.readAloudColorText(from: colorHex)
        }
        .onChange(of: colorHex) { _, newValue in
            let normalized = ReaderSettings.readAloudColorText(from: newValue)
            if normalized != hexText {
                hexText = normalized
            }
        }
    }

    private var colorHSB: ReadAloudColorHSB {
        ReaderSettings.readAloudColorHSB(from: colorHex)
    }

    private func updateSpectrumColor(hue: Double, saturation: Double, brightness: Double) {
        colorHex = ReaderSettings.readAloudColorHex(
            hue: hue,
            saturation: saturation,
            brightness: brightness
        )
    }

    private func isSelectedSwatch(_ presetHex: String) -> Bool {
        presetHex == colorHex
    }

    private var readAloudHexDisplay: String {
        "#\(ReaderSettings.readAloudColorText(from: colorHex))"
    }
}

private struct ReadAloudSpectrumView: View {
    let hue: Double
    let saturation: Double
    let brightness: Double
    let onChange: (Double, Double, Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let height = max(geometry.size.height, 1)

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white)

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white, hueColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .background(Circle().fill(currentColor))
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .position(
                        x: saturation * width,
                        y: (1 - brightness) * height
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let newSaturation = min(max(value.location.x / width, 0), 1)
                        let newBrightness = 1 - min(max(value.location.y / height, 0), 1)
                        onChange(hue, newSaturation, newBrightness)
                    }
            )
        }
        .frame(height: 220)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        }
    }

    private var hueColor: Color {
        Color(uiColor: UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1))
    }

    private var currentColor: Color {
        Color(uiColor: UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1))
    }
}

private struct ReadAloudHueSlider: View {
    let hue: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)

            ZStack {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .background(
                        Circle()
                            .fill(Color(uiColor: UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1)))
                    )
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .position(x: hue * width, y: geometry.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onChange(min(max(value.location.x / width, 0), 1))
                    }
            )
        }
        .frame(height: 28)
        .overlay {
            Capsule(style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        }
    }
}

private extension UTType {
    static let epub = UTType(filenameExtension: "epub") ?? .data
    static let ttf = UTType(filenameExtension: "ttf") ?? .data
    static let otf = UTType(filenameExtension: "otf") ?? .data
}

#Preview {
    ContentView()
        .environmentObject(AppStateStore())
}
