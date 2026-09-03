//
//  FontFamilySelectionView.swift
//  EPUB Player
//

import SwiftUI
import UIKit

struct ReaderSettingSliderRow: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Spacer(minLength: 12)

                Text(valueText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }
}

struct FontFamilySelectionList: View {
    let customFontFamilies: [CustomFontStore.ImportedFontFamily]
    @Binding var selectedFontFamilyRawValue: String
    var showsSeparators = false

    var body: some View {
        let options = ReaderSettings.fontFamilyOptions(customFontFamilies: customFontFamilies)

        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
            VStack(spacing: 0) {
                Button {
                    selectedFontFamilyRawValue = option.id
                } label: {
                    HStack(spacing: 12) {
                        Text(option.name)
                            .font(previewFont(for: option))

                        Spacer(minLength: 12)

                        if option.id == selectedFontFamilyRawValue {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .frame(minHeight: 24)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showsSeparators && index < options.count - 1 {
                    Divider()
                }
            }
        }
    }

    private func previewFont(for option: FontFamilyOption) -> Font {
        let fontSize = previewFontSize(for: option)

        if let customFamily = customFontFamilies.first(where: { $0.fontFamily == option.id }),
           let fontName = previewFontName(forFamilyName: customFamily.displayName) {
            return .custom(fontName, size: fontSize)
        }

        if let fontName = previewFontName(forFamilyName: option.name) {
            return .custom(fontName, size: fontSize)
        }

        return .body
    }

    private func previewFontSize(for option: FontFamilyOption) -> CGFloat {
        let baseSize = UIFont.preferredFont(forTextStyle: .body).pointSize

        guard let previewUIFont = previewUIFont(for: option, baseSize: baseSize) else {
            return baseSize
        }

        let baseFont = UIFont.preferredFont(forTextStyle: .body)
        let previewXHeight = max(previewUIFont.xHeight, 1)
        let previewCapHeight = max(previewUIFont.capHeight, 1)
        let blendedScale = ((baseFont.xHeight / previewXHeight) * 0.7) + ((baseFont.capHeight / previewCapHeight) * 0.3)

        let previewFamilyName = resolvedPreviewFamilyName(for: option)
        let tunedScale: CGFloat
        switch option.name {
        case "Palatino":
            tunedScale = blendedScale * 0.86
        case "Georgia":
            tunedScale = blendedScale * 0.88
        case "Seravek":
            tunedScale = blendedScale * 0.92
        default:
            if previewFamilyName == "Bookerly" {
                tunedScale = blendedScale * 0.82
            } else if customFontFamilies.contains(where: { $0.fontFamily == option.id }) {
                tunedScale = blendedScale * 0.88
            } else {
                tunedScale = blendedScale * 0.9
            }
        }

        let scale = min(max(tunedScale, 0.76), 1.0)
        return baseSize * scale
    }

    private func previewUIFont(for option: FontFamilyOption, baseSize: CGFloat) -> UIFont? {
        if let customFamily = customFontFamilies.first(where: { $0.fontFamily == option.id }),
           let fontName = previewFontName(forFamilyName: customFamily.displayName) {
            return UIFont(name: fontName, size: baseSize)
        }

        if let fontName = previewFontName(forFamilyName: option.name) {
            return UIFont(name: fontName, size: baseSize)
        }

        return nil
    }

    private func resolvedPreviewFamilyName(for option: FontFamilyOption) -> String {
        if let customFamily = customFontFamilies.first(where: { $0.fontFamily == option.id }) {
            return customFamily.displayName
        }

        return option.name
    }

    private func previewFontName(forFamilyName familyName: String) -> String? {
        if let exactFont = UIFont(name: familyName, size: 17) {
            return exactFont.fontName
        }

        return UIFont.fontNames(forFamilyName: familyName).first
    }
}
