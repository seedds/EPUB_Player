//
//  ReadAloudColor.swift
//  EPUB Player
//

import Foundation
import SwiftUI
import UIKit

nonisolated enum ReadAloudColor {
    static func uiColor(from rawValue: String) -> UIColor {
        colorHex(from: rawValue)
            .flatMap(uiColor(hex:))
            ?? uiColor(hex: ReaderSettings.defaultReadAloudColorHex)
            ?? .systemGreen
    }

    static func color(from rawValue: String) -> SwiftUI.Color {
        SwiftUI.Color(uiColor: uiColor(from: rawValue))
    }

    static func hex(from color: SwiftUI.Color) -> String {
        hexString(for: UIColor(color))
    }

    static func text(from rawValue: String) -> String {
        String(colorHex(from: rawValue)?.dropFirst() ?? ReaderSettings.defaultReadAloudColorHex.dropFirst())
    }

    static func normalizedText(_ value: String) -> String {
        String(value.uppercased().filter(\.isHexDigit).prefix(6))
    }

    static func hex(from text: String) -> String? {
        let normalized = normalizedText(text)
        guard normalized.count == 6 else {
            return nil
        }
        return "#\(normalized)"
    }

    static func hsb(from rawValue: String) -> ReadAloudColorHSB {
        let color = uiColor(from: rawValue)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .default
        }

        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue

        let hue: CGFloat
        if delta == 0 {
            hue = 0
        } else if maxValue == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxValue == green {
            hue = ((blue - red) / delta) + 2
        } else {
            hue = ((red - green) / delta) + 4
        }

        let normalizedHue = hue < 0 ? (hue + 6) / 6 : hue / 6
        let saturation = maxValue == 0 ? 0 : delta / maxValue

        return ReadAloudColorHSB(
            hue: clamp(Double(normalizedHue)),
            saturation: clamp(Double(saturation)),
            brightness: clamp(Double(maxValue))
        )
    }

    static func hex(hue: Double, saturation: Double, brightness: Double) -> String {
        hexString(
            for: UIColor(
                hue: clamp(hue),
                saturation: clamp(saturation),
                brightness: clamp(brightness),
                alpha: 1
            )
        )
    }

    private static func colorHex(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 7, trimmed.hasPrefix("#") else {
            return nil
        }

        let hex = trimmed.dropFirst()
        guard hex.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }

        return trimmed.uppercased()
    }

    private static func uiColor(hex: String) -> UIColor? {
        guard let hex = colorHex(from: hex) else {
            return nil
        }

        let scanner = Scanner(string: String(hex.dropFirst()))
        var hexNumber: UInt64 = 0
        guard scanner.scanHexInt64(&hexNumber) else {
            return nil
        }

        return UIColor(
            red: CGFloat((hexNumber & 0xFF0000) >> 16) / 255,
            green: CGFloat((hexNumber & 0x00FF00) >> 8) / 255,
            blue: CGFloat(hexNumber & 0x0000FF) / 255,
            alpha: 1
        )
    }

    private static func hexString(for color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return ReaderSettings.defaultReadAloudColorHex
        }

        let rgb = (Int(round(red * 255)) << 16)
            | (Int(round(green * 255)) << 8)
            | Int(round(blue * 255))
        return String(format: "#%06X", rgb)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

nonisolated struct ReadAloudColorHSB: Equatable {
    let hue: Double
    let saturation: Double
    let brightness: Double

    static let `default` = ReadAloudColorHSB(hue: 0.4, saturation: 0.74, brightness: 0.78)
}
