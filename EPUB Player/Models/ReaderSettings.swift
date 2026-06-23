//
//  ReaderSettings.swift
//  EPUB Player
//
//  Created by OpenCode on 26/4/2026.
//

import Foundation
import ReadiumNavigator
import SwiftUI
import UIKit

nonisolated enum ReaderSettings {
    static let defaultFontSize = 1.2
    static let defaultLineHeight = 1.2
    static let defaultReadAloudColorHex = "#34C759"
    static let defaultReadingBackgroundRawValue = ReadingBackgroundOption.white.rawValue
    static let defaultPlaybackSpeed = 1.0
    static let defaultPlaybackJumpInterval = 15.0
    static let defaultAutoRewindAfterBackgroundMinutes = 1
    static let defaultUploadServerPort = 8080
    static let fontSizeRange = 0.8 ... 2.0
    static let lineHeightRange = 1.0 ... 2.0
    static let playbackSpeedRange = 0.5 ... 2.0
    static let fontSizeStep = 0.1
    static let lineHeightStep = 0.1
    static let playbackSpeedStep = 0.1
    static let playbackJumpIntervalOptions = [15.0, 30.0, 45.0, 60.0]
    static let autoRewindAfterBackgroundMinuteOptions = [1, 2, 5, 10]
    static let fontSizeOptions = [0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0]
    static let lineHeightOptions = [1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 2.0]

    static let builtInFontFamilyOptions: [FontFamilyOption] = [
        FontFamilyOption(name: "Default", value: nil),
        FontFamilyOption(name: "Literata", value: FontFamily(rawValue: "Literata")),
        FontFamilyOption(name: "Palatino", value: .palatino),
        FontFamilyOption(name: "Georgia", value: .georgia),
        FontFamilyOption(name: "Seravek", value: .seravek),
    ]

    static func fontFamilyOptions(customFontFamilies: [CustomFontStore.ImportedFontFamily]) -> [FontFamilyOption] {
        builtInFontFamilyOptions + customFontFamilies.map {
            FontFamilyOption(name: $0.displayName, value: FontFamily(rawValue: $0.fontFamily))
        }
    }

    static func fontFamilyName(from rawValue: String, customFontFamilies: [CustomFontStore.ImportedFontFamily]) -> String {
        fontFamilyOptions(customFontFamilies: customFontFamilies)
            .first(where: { $0.id == rawValue })?
            .name
            ?? builtInFontFamilyOptions[0].name
    }

    static func fontFamily(from rawValue: String) -> FontFamily? {
        guard !rawValue.isEmpty else {
            return nil
        }
        return FontFamily(rawValue: rawValue)
    }

    static func appTheme(from rawValue: String) -> AppThemeOption {
        AppThemeOption(rawValue: rawValue) ?? .system
    }

    static func readingBackground(from rawValue: String) -> ReadingBackgroundOption {
        ReadingBackgroundOption(rawValue: rawValue) ?? .white
    }

    /// Reading background that pairs with the given theme. System resolves
    /// light/dark via the supplied color scheme.
    static func defaultBackground(forTheme theme: AppThemeOption, colorScheme: ColorScheme) -> ReadingBackgroundOption {
        theme.readiumTheme(for: colorScheme) == .dark ? .black : .white
    }

    static func normalizedFontSize(_ value: Double) -> Double {
        min(max(value, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    static func normalizedLineHeight(_ value: Double) -> Double {
        min(max(value, lineHeightRange.lowerBound), lineHeightRange.upperBound)
    }

    static func normalizedPlaybackSpeed(_ value: Double) -> Double {
        min(max(value, playbackSpeedRange.lowerBound), playbackSpeedRange.upperBound)
    }

    static func normalizedPlaybackJumpInterval(_ value: Double) -> Double {
        playbackJumpIntervalOptions.min(by: { abs($0 - value) < abs($1 - value) }) ?? defaultPlaybackJumpInterval
    }

    static func normalizedAutoRewindAfterBackgroundMinutes(_ value: Int) -> Int {
        autoRewindAfterBackgroundMinuteOptions.min(by: { abs($0 - value) < abs($1 - value) }) ?? defaultAutoRewindAfterBackgroundMinutes
    }

    static func normalizedUploadServerPort(_ value: Int) -> Int {
        min(max(value, 1), Int(UInt16.max))
    }

    static func uploadServerPort(from value: Int) -> UInt16 {
        UInt16(normalizedUploadServerPort(value))
    }

    static func playbackSpeedText(_ value: Double) -> String {
        let normalized = normalizedPlaybackSpeed(value)
        let roundedValue = normalized.rounded()
        let numberText = roundedValue == normalized
            ? roundedValue.formatted(.number.precision(.fractionLength(0)))
            : normalized.formatted(.number.precision(.fractionLength(1)))
        return "\(numberText)x"
    }

    static func playbackJumpIntervalText(_ value: Double) -> String {
        let normalized = normalizedPlaybackJumpInterval(value)
        let wholeSeconds = Int(normalized.rounded())
        return "\(wholeSeconds)s"
    }

    static func autoRewindAfterBackgroundText(_ value: Int) -> String {
        let normalized = normalizedAutoRewindAfterBackgroundMinutes(value)
        return normalized == 1 ? "1 min" : "\(normalized) min"
    }

    static func playbackJumpLabel(_ value: Double, direction: PlaybackJumpDirection) -> String {
        let prefix = direction == .backward ? "-" : "+"
        return "\(prefix)\(playbackJumpIntervalText(value))"
    }

    static func playbackJumpSymbolName(_ value: Double, direction: PlaybackJumpDirection) -> String {
        let wholeSeconds = Int(normalizedPlaybackJumpInterval(value).rounded())
        switch direction {
        case .backward:
            return "gobackward.\(wholeSeconds)"
        case .forward:
            return "goforward.\(wholeSeconds)"
        }
    }

    static func playbackJumpAccessibilityLabel(_ value: Double, direction: PlaybackJumpDirection) -> String {
        let wholeSeconds = Int(normalizedPlaybackJumpInterval(value).rounded())
        switch direction {
        case .backward:
            return "Back \(wholeSeconds) seconds"
        case .forward:
            return "Forward \(wholeSeconds) seconds"
        }
    }

    static func fontSizeText(_ value: Double) -> String {
        normalizedFontSize(value)
            .formatted(.number.precision(.fractionLength(1)))
    }

    static func lineHeightText(_ value: Double) -> String {
        normalizedLineHeight(value)
            .formatted(.number.precision(.fractionLength(1)))
    }

    static func uiColor(from rawValue: String) -> UIColor {
        ReadAloudColor.uiColor(from: rawValue)
    }

    static func color(from rawValue: String) -> SwiftUI.Color {
        ReadAloudColor.color(from: rawValue)
    }

    static func readAloudColorHex(from color: SwiftUI.Color) -> String {
        ReadAloudColor.hex(from: color)
    }

    static func readAloudColorText(from rawValue: String) -> String {
        ReadAloudColor.text(from: rawValue)
    }

    static func normalizedReadAloudColorText(_ value: String) -> String {
        ReadAloudColor.normalizedText(value)
    }

    static func readAloudColorHex(from text: String) -> String? {
        ReadAloudColor.hex(from: text)
    }

    static func readAloudColorHSB(from rawValue: String) -> ReadAloudColorHSB {
        ReadAloudColor.hsb(from: rawValue)
    }

    static func readAloudColorHex(hue: Double, saturation: Double, brightness: Double) -> String {
        ReadAloudColor.hex(hue: hue, saturation: saturation, brightness: brightness)
    }
}

enum ReadingBackgroundOption: String, CaseIterable, Identifiable {
    case white
    case sepia
    case gray
    case darkGray
    case black

    var id: String {
        rawValue
    }

    var name: String {
        switch self {
        case .white:
            return "White"
        case .sepia:
            return "Sepia"
        case .gray:
            return "Gray"
        case .darkGray:
            return "Dark Gray"
        case .black:
            return "Black"
        }
    }

    /// Background hex applied to the rendered page.
    var backgroundHex: String {
        switch self {
        case .white:
            return "#FFFFFF"
        case .sepia:
            return "#FAF4E8"
        case .gray:
            return "#EDEDED"
        case .darkGray:
            return "#2B2B2B"
        case .black:
            return "#000000"
        }
    }

    /// Text hex paired with the background for readability.
    var textHex: String {
        switch self {
        case .white:
            return "#121212"
        case .sepia:
            return "#5B4636"
        case .gray:
            return "#1A1A1A"
        case .darkGray:
            return "#E8E8E8"
        case .black:
            return "#FEFEFE"
        }
    }

    /// Swatch color shown in selection UI.
    var swatchColor: SwiftUI.Color {
        ReaderSettings.color(from: backgroundHex)
    }
}

nonisolated enum AppThemeOption: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String {
        rawValue
    }

    var name: String {
        switch self {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    func readiumTheme(for colorScheme: ColorScheme) -> Theme {
        switch self {
        case .system:
            return colorScheme == .dark ? .dark : .light
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

nonisolated enum PlaybackJumpDirection {
    case backward
    case forward
}
