//
//  CustomFontStore.swift
//  EPUB Player
//
//  Created by OpenCode on 30/4/2026.
//

import CoreText
import Foundation
import ReadiumNavigator
import ReadiumShared

enum CustomFontStoreError: LocalizedError {
    case unsupportedFile(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let filename):
            "Only .ttf and .otf font files are supported. \(filename) can't be imported."
        }
    }
}

enum CustomFontStore {
    private static var registeredFontURLs: Set<URL> = []
    private static let registrationLock = NSLock()

    struct ImportedFontFamily: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        let displayName: String
        let fontFamily: String
        let importedAt: Date
        var files: [ImportedFontFile]

        var fileCount: Int {
            files.count
        }
    }

    struct ImportedFontFile: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        let storedFilename: String
        let originalFilename: String
        let style: ImportedFontStyle
        let importedAt: Date
    }

    enum ImportedFontStyle: String, Codable, Hashable, Sendable {
        case normal
        case italic

        var cssStyle: CSSFontStyle {
            switch self {
            case .normal:
                .normal
            case .italic:
                .italic
            }
        }

        var label: String {
            switch self {
            case .normal:
                "Regular"
            case .italic:
                "Italic"
            }
        }

        var sortOrder: Int {
            switch self {
            case .normal:
                0
            case .italic:
                1
            }
        }
    }

    private struct DetectedFontMetadata {
        let familyDisplayName: String
        let style: ImportedFontStyle
    }

    @MainActor
    static func allFamilies(store: AppStateStore) -> [ImportedFontFamily] {
        let families = synchronizedFamilies(store: store)
        registerFontsForUI(in: families)
        return families
    }

    @MainActor
    @discardableResult
    static func importFonts(from urls: [URL], store: AppStateStore) throws -> [ImportedFontFamily] {
        let directory = try AppStorage.customFontsDirectory()
        let fileManager = FileManager.default
        var snapshot = synchronizedFamilies(store: store)
        var changedFamilyIDs = Set<UUID>()

        for sourceURL in urls {
            let originalFilename = AppStorage.sanitizedFilename(sourceURL.lastPathComponent)
            guard isSupportedFontFilename(originalFilename) else {
                throw CustomFontStoreError.unsupportedFile(originalFilename)
            }

            let fileID = UUID()
            let destinationURL = directory.appendingPathComponent(
                internalStoredFilename(for: fileID, pathExtension: pathExtension(for: originalFilename)),
                isDirectory: false
            )

            do {
                let hasAccess = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }

                try fileManager.copyItem(at: sourceURL, to: destinationURL)

                let metadata = detectedFontMetadata(for: destinationURL, fallbackFilename: originalFilename)
                let importedFile = ImportedFontFile(
                    id: fileID,
                    storedFilename: destinationURL.lastPathComponent,
                    originalFilename: originalFilename,
                    style: metadata.style,
                    importedAt: Date()
                )

                if let familyIndex = snapshot.firstIndex(where: { normalizedFamilyKey($0.displayName) == normalizedFamilyKey(metadata.familyDisplayName) }) {
                    snapshot[familyIndex].files.append(importedFile)
                    changedFamilyIDs.insert(snapshot[familyIndex].id)
                } else {
                    let family = ImportedFontFamily(
                        id: UUID(),
                        displayName: metadata.familyDisplayName,
                        fontFamily: customFontFamilyName(),
                        importedAt: Date(),
                        files: [importedFile]
                    )
                    snapshot.append(family)
                    changedFamilyIDs.insert(family.id)
                }
            } catch {
                try? fileManager.removeItem(at: destinationURL)
                throw error
            }
        }

        snapshot = sortedFamilies(snapshot)
        store.setCustomFontFamilies(snapshot)
        synchronizeSelectedFontFamily(with: snapshot, store: store)
        return snapshot.filter { changedFamilyIDs.contains($0.id) }
    }

    @MainActor
    static func removeFamilies(withIDs ids: some Sequence<UUID>, store: AppStateStore) throws {
        let idsToRemove = Set(ids)
        guard !idsToRemove.isEmpty else {
            return
        }

        let snapshot = synchronizedFamilies(store: store)
        let removedFiles = snapshot
            .filter { idsToRemove.contains($0.id) }
            .flatMap(\.files)

        try removeStoredFiles(removedFiles)
        unregisterFontsFromCache(removedFiles)

        let remainingFamilies = snapshot.filter { !idsToRemove.contains($0.id) }
        store.setCustomFontFamilies(remainingFamilies)
        synchronizeSelectedFontFamily(with: remainingFamilies, store: store)
    }

    @MainActor
    static func removeFiles(withIDs ids: some Sequence<UUID>, store: AppStateStore) throws {
        let idsToRemove = Set(ids)
        guard !idsToRemove.isEmpty else {
            return
        }

        let snapshot = synchronizedFamilies(store: store)
        let removedFiles = snapshot
            .flatMap(\.files)
            .filter { idsToRemove.contains($0.id) }

        try removeStoredFiles(removedFiles)
        unregisterFontsFromCache(removedFiles)

        let remainingFamilies = snapshot.compactMap { family -> ImportedFontFamily? in
            let remainingFiles = family.files.filter { !idsToRemove.contains($0.id) }
            guard !remainingFiles.isEmpty else {
                return nil
            }

            var updatedFamily = family
            updatedFamily.files = remainingFiles
            return updatedFamily
        }

        let sortedRemainingFamilies = sortedFamilies(remainingFamilies)
        store.setCustomFontFamilies(sortedRemainingFamilies)
        synchronizeSelectedFontFamily(with: sortedRemainingFamilies, store: store)
    }

    static func fontFamilyDeclarations(customFontFamilies: [ImportedFontFamily]) -> [AnyHTMLFontFamilyDeclaration] {
        let directory = try? AppStorage.customFontsDirectory()
        return customFontFamilies.compactMap { family in
            guard let directory else {
                return nil
            }

            let fontFaces = family.files.compactMap { file -> CSSFontFace? in
                let fileURL = directory.appendingPathComponent(file.storedFilename, isDirectory: false)
                guard let readiumFileURL = FileURL(url: fileURL) else {
                    return nil
                }

                return CSSFontFace(file: readiumFileURL, style: file.style.cssStyle)
            }

            guard !fontFaces.isEmpty else {
                return nil
            }

            return CSSFontFamilyDeclaration(
                fontFamily: FontFamily(rawValue: family.fontFamily),
                fontFaces: fontFaces
            )
            .eraseToAnyHTMLFontFamilyDeclaration()
        }
    }

    static func registerFontsForUI(in families: [ImportedFontFamily]) {
        guard let directory = try? AppStorage.customFontsDirectory() else {
            return
        }

        registrationLock.lock()
        defer { registrationLock.unlock() }

        for family in families {
            for file in family.files {
                let fileURL = directory.appendingPathComponent(file.storedFilename, isDirectory: false)

                guard !registeredFontURLs.contains(fileURL) else {
                    continue
                }

                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    continue
                }

                var registrationError: Unmanaged<CFError>?
                let success = CTFontManagerRegisterFontsForURL(fileURL as CFURL, .process, &registrationError)

                if success {
                    registeredFontURLs.insert(fileURL)
                }
            }
        }
    }

    @MainActor
    private static func synchronizedFamilies(store: AppStateStore) -> [ImportedFontFamily] {
        let loadedFamilies = store.customFontFamilies
        guard let directory = try? AppStorage.customFontsDirectory() else {
            if !loadedFamilies.isEmpty {
                store.setCustomFontFamilies([])
            }
            return []
        }

        let filteredFamilies = loadedFamilies.compactMap { family -> ImportedFontFamily? in
            let remainingFiles = family.files.filter { file in
                let fileURL = directory.appendingPathComponent(file.storedFilename, isDirectory: false)
                return FileManager.default.fileExists(atPath: fileURL.path)
            }

            guard !remainingFiles.isEmpty else {
                return nil
            }

            var updatedFamily = family
            updatedFamily.files = remainingFiles
            return updatedFamily
        }

        let sortedFilteredFamilies = sortedFamilies(filteredFamilies)
        if sortedFilteredFamilies != loadedFamilies {
            store.setCustomFontFamilies(sortedFilteredFamilies)
        }
        synchronizeSelectedFontFamily(with: sortedFilteredFamilies, store: store)
        return sortedFilteredFamilies
    }

    /// Extracts font family name and style from a font file using CoreText.
    ///
    /// The detection strategy:
    /// 1. Try to load font descriptors from the file using CTFontManager
    /// 2. Extract family name from kCTFontFamilyNameAttribute
    /// 3. Determine italic style by checking:
    ///    - CTFontSymbolicTraits for .traitItalic flag
    ///    - Style name for "italic" or "oblique" keywords (case-insensitive)
    /// 4. Fall back to filename parsing if CoreText fails
    ///
    /// - Parameters:
    ///   - fileURL: Path to the .ttf or .otf font file
    ///   - fallbackFilename: Original filename to parse if CoreText fails
    /// - Returns: Detected family name and style, or filename-based fallback
    private static func detectedFontMetadata(for fileURL: URL, fallbackFilename: String) -> DetectedFontMetadata {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fileURL as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first
        else {
            return DetectedFontMetadata(
                familyDisplayName: fallbackFamilyDisplayName(for: fallbackFilename),
                style: fallbackStyle(for: fallbackFilename)
            )
        }

        let rawFamilyDisplayName = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
        let familyDisplayName = rawFamilyDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let styleName = (CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String) ?? ""
        let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
        let symbolicTraitsValue = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
        let symbolicTraits = CTFontSymbolicTraits(rawValue: symbolicTraitsValue)
        let isItalic = symbolicTraits.contains(.traitItalic)
            || styleName.localizedCaseInsensitiveContains("italic")
            || styleName.localizedCaseInsensitiveContains("oblique")

        return DetectedFontMetadata(
            familyDisplayName: (familyDisplayName?.isEmpty == false ? familyDisplayName : fallbackFamilyDisplayName(for: fallbackFilename))
                ?? fallbackFamilyDisplayName(for: fallbackFilename),
            style: isItalic ? .italic : .normal
        )
    }

    private static func fallbackFamilyDisplayName(for filename: String) -> String {
        let baseName = URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
        let suffixes = ["-regular", " regular", "-italic", " italic", "-oblique", " oblique"]

        for suffix in suffixes where baseName.lowercased().hasSuffix(suffix) {
            let trimmed = String(baseName.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return baseName
    }

    private static func fallbackStyle(for filename: String) -> ImportedFontStyle {
        let baseName = URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()

        if baseName.contains("italic") || baseName.contains("oblique") {
            return .italic
        }
        return .normal
    }

    private static func sortedFamilies(_ families: [ImportedFontFamily]) -> [ImportedFontFamily] {
        families
            .map { family in
                var sortedFamily = family
                sortedFamily.files = family.files.sorted { lhs, rhs in
                    if lhs.style.sortOrder != rhs.style.sortOrder {
                        return lhs.style.sortOrder < rhs.style.sortOrder
                    }
                    return lhs.originalFilename.localizedStandardCompare(rhs.originalFilename) == .orderedAscending
                }
                return sortedFamily
            }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    private static func removeStoredFiles(_ files: [ImportedFontFile]) throws {
        let directory = try AppStorage.customFontsDirectory()
        let fileManager = FileManager.default

        for file in files {
            let fileURL = directory.appendingPathComponent(file.storedFilename, isDirectory: false)
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private static func unregisterFontsFromCache(_ files: [ImportedFontFile]) {
        guard let directory = try? AppStorage.customFontsDirectory() else {
            return
        }

        registrationLock.lock()
        defer { registrationLock.unlock() }

        for file in files {
            let fileURL = directory.appendingPathComponent(file.storedFilename, isDirectory: false)
            registeredFontURLs.remove(fileURL)
        }
    }

    private static func normalizedFamilyKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pathExtension(for filename: String, fallbackFilename: String? = nil) -> String {
        let filenameExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        if !filenameExtension.isEmpty {
            return filenameExtension
        }

        guard let fallbackFilename else {
            return ""
        }
        return URL(fileURLWithPath: fallbackFilename).pathExtension.lowercased()
    }

    private static func internalStoredFilename(for fileID: UUID, pathExtension: String) -> String {
        let normalizedExtension = pathExtension.lowercased()
        let basename = fileID.uuidString.lowercased()
        guard !normalizedExtension.isEmpty else {
            return basename
        }
        return "\(basename).\(normalizedExtension)"
    }

    private static func customFontFamilyName() -> String {
        "custom-font-\(UUID().uuidString.lowercased())"
    }

    private static func isSupportedFontFilename(_ filename: String) -> Bool {
        let pathExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return pathExtension == "ttf" || pathExtension == "otf"
    }

    @MainActor
    private static func synchronizeSelectedFontFamily(with families: [ImportedFontFamily], store: AppStateStore) {
        guard store.fontFamilyRawValue.hasPrefix("custom-font-") else {
            return
        }

        if families.contains(where: { $0.fontFamily == store.fontFamilyRawValue }) {
            return
        }

        store.fontFamilyRawValue = ""
    }
}
