//
//  MediaOverlayPlaybackBar.swift
//  EPUB Player
//

import SwiftUI
import UIKit

struct MediaOverlayPlaybackBar: View {
    @ObservedObject var playback: MediaOverlayPlaybackController
    @Binding var playbackSpeed: Double
    let playbackJumpInterval: Double
    @Binding var fontSize: Double
    @Binding var lineHeight: Double
    @Binding var fontFamilyRawValue: String
    @Binding var readingBackgroundRawValue: String
    let customFontFamilies: [CustomFontStore.ImportedFontFamily]
    @Binding var isSpeedControlPresented: Bool
    @Binding var isReaderSettingsControlPresented: Bool
    let toggleSpeedControl: () -> Void
    let toggleReaderSettingsControl: () -> Void
    let playPause: () -> Void
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isSpeedControlPresented || isReaderSettingsControlPresented {
                Group {
                    if isSpeedControlPresented {
                        PlaybackSpeedControlPanel(playbackSpeed: $playbackSpeed)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if isReaderSettingsControlPresented {
                        ReaderTypographyControlPanel(
                            fontSize: $fontSize,
                            lineHeight: $lineHeight,
                            fontFamilyRawValue: $fontFamilyRawValue,
                            readingBackgroundRawValue: $readingBackgroundRawValue,
                            customFontFamilies: customFontFamilies
                        )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
            }

            HStack(spacing: 0) {
                Button(action: toggleSpeedControl) {
                    Text(ReaderSettings.playbackSpeedText(playbackSpeed))
                        .font(.body.weight(.medium))
                        .frame(width: 48, height: 48)
                        .background(Color(uiColor: .secondarySystemFill), in: Circle())
                }
                .accessibilityLabel("Playback speed")
                .accessibilityValue(ReaderSettings.playbackSpeedText(playbackSpeed))
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Button(action: previous) {
                    Image(systemName: ReaderSettings.playbackJumpSymbolName(playbackJumpInterval, direction: .backward))
                        .font(.title3.weight(.medium))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(.blue)
                }
                .accessibilityLabel(ReaderSettings.playbackJumpAccessibilityLabel(playbackJumpInterval, direction: .backward))
                .buttonStyle(.plain)
                .disabled(!playback.canJumpBackward)
                .frame(maxWidth: .infinity)

                Button(action: playPause) {
                    Image(systemName: playback.state.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 48, height: 48)
                        .background(.blue, in: Circle())
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(playback.state.isPlaying ? "Pause read-aloud" : "Play read-aloud")
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                Button(action: next) {
                    Image(systemName: ReaderSettings.playbackJumpSymbolName(playbackJumpInterval, direction: .forward))
                        .font(.title3.weight(.medium))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(.blue)
                }
                .accessibilityLabel(ReaderSettings.playbackJumpAccessibilityLabel(playbackJumpInterval, direction: .forward))
                .buttonStyle(.plain)
                .disabled(!playback.canJumpForward)
                .frame(maxWidth: .infinity)

                Button(action: toggleReaderSettingsControl) {
                    Image(systemName: "textformat.size")
                        .font(.body.weight(.medium))
                        .frame(width: 48, height: 48)
                        .background(Color(uiColor: .secondarySystemFill), in: Circle())
                }
                .accessibilityLabel("Reader settings")
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .animation(.easeInOut(duration: 0.2), value: isSpeedControlPresented)
        .animation(.easeInOut(duration: 0.2), value: isReaderSettingsControlPresented)
    }
}

struct PlaybackSpeedControlPanel: View {
    @Binding var playbackSpeed: Double

    var body: some View {
        ReaderControlPanel {
            ReaderSettingSliderRow(
                title: "Playback Speed",
                valueText: ReaderSettings.playbackSpeedText(playbackSpeed),
                value: Binding(
                    get: { ReaderSettings.normalizedPlaybackSpeed(playbackSpeed) },
                    set: { playbackSpeed = ReaderSettings.normalizedPlaybackSpeed($0) }
                ),
                range: ReaderSettings.playbackSpeedRange,
                step: ReaderSettings.playbackSpeedStep
            )
        }
    }
}

struct ReaderTypographyControlPanel: View {
    private enum PanelMode {
        case typography
        case fontFamilySelection
    }

    @Binding var fontSize: Double
    @Binding var lineHeight: Double
    @Binding var fontFamilyRawValue: String
    @Binding var readingBackgroundRawValue: String
    let customFontFamilies: [CustomFontStore.ImportedFontFamily]
    @State private var panelMode: PanelMode = .typography

    var body: some View {
        ReaderControlPanel {
            switch panelMode {
            case .typography:
                VStack(spacing: 10) {
                    ReaderSettingSliderRow(
                        title: "Font Size",
                        valueText: ReaderSettings.fontSizeText(fontSize),
                        value: Binding(
                            get: { ReaderSettings.normalizedFontSize(fontSize) },
                            set: { fontSize = ReaderSettings.normalizedFontSize($0) }
                        ),
                        range: ReaderSettings.fontSizeRange,
                        step: ReaderSettings.fontSizeStep
                    )

                    Divider()

                    ReaderSettingSliderRow(
                        title: "Line Height",
                        valueText: ReaderSettings.lineHeightText(lineHeight),
                        value: Binding(
                            get: { ReaderSettings.normalizedLineHeight(lineHeight) },
                            set: { lineHeight = ReaderSettings.normalizedLineHeight($0) }
                        ),
                        range: ReaderSettings.lineHeightRange,
                        step: ReaderSettings.lineHeightStep
                    )

                    Divider()

                    Button {
                        panelMode = .fontFamilySelection
                    } label: {
                        HStack(spacing: 12) {
                            Text("Font Family")
                                .font(.subheadline.weight(.semibold))

                            Spacer(minLength: 12)

                            Text(ReaderSettings.fontFamilyName(from: fontFamilyRawValue, customFontFamilies: customFontFamilies))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()

                    HStack(spacing: 12) {
                        Text("Background")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 12)

                        HStack(spacing: 10) {
                            ForEach(ReadingBackgroundOption.allCases) { option in
                                Button {
                                    readingBackgroundRawValue = option.rawValue
                                } label: {
                                    Circle()
                                        .fill(option.swatchColor)
                                        .frame(width: 26, height: 26)
                                        .overlay {
                                            Circle()
                                                .stroke(
                                                    isSelected(option) ? Color.primary : Color.black.opacity(0.12),
                                                    lineWidth: isSelected(option) ? 3 : 1
                                                )
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(option.name) background")
                                .accessibilityAddTraits(isSelected(option) ? .isSelected : [])
                            }
                        }
                    }
                }

            case .fontFamilySelection:
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        panelMode = .typography
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            FontFamilySelectionList(
                                customFontFamilies: customFontFamilies,
                                selectedFontFamilyRawValue: $fontFamilyRawValue,
                                showsSeparators: true
                            )
                        }
                    }
                    .frame(maxHeight: 260)
                }
            }
        }
    }

    private func isSelected(_ option: ReadingBackgroundOption) -> Bool {
        option.rawValue == readingBackgroundRawValue
    }
}

struct ReaderControlPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.black.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}
