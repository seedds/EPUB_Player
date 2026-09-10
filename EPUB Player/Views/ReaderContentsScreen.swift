//
//  ReaderContentsScreen.swift
//  EPUB Player
//

import ReadiumShared
import SwiftUI

struct ChapterListItem: Identifiable, Equatable {
    let level: Int
    let link: ReadiumShared.Link

    var id: String {
        "\(level)-\(link.href)-\(link.title ?? "")"
    }

    var title: String {
        link.title ?? link.href
    }

    static func == (lhs: ChapterListItem, rhs: ChapterListItem) -> Bool {
        lhs.id == rhs.id
    }
}

enum ChapterBookmarkTab: Hashable {
    case chapters
    case bookmarks
    case history
}

struct ChapterAndBookmarkScreen: View {
    let items: [ChapterListItem]
    let selectedItemID: ChapterListItem.ID?
    let bookmarks: [Bookmark]
    let history: [HistoryEntry]
    let onSelectChapter: (ChapterListItem) -> Void
    let onSelectBookmark: (Bookmark) -> Void
    let onDeleteBookmarks: (Set<Bookmark.ID>) -> Void
    let onSelectHistory: (HistoryEntry) -> Void
    let onDeleteHistory: (Set<HistoryEntry.ID>) -> Void

    @State private var selectedTab: ChapterBookmarkTab = .chapters

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $selectedTab) {
                Text("Chapters").tag(ChapterBookmarkTab.chapters)
                Text("Bookmarks").tag(ChapterBookmarkTab.bookmarks)
                Text("History").tag(ChapterBookmarkTab.history)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch selectedTab {
            case .chapters:
                ChapterListScreen(
                    items: items,
                    selectedItemID: selectedItemID,
                    onSelect: onSelectChapter
                )
            case .bookmarks:
                SavedPositionListScreen(
                    records: bookmarks,
                    emptyTitle: "No Bookmarks",
                    emptySystemImage: "bookmark",
                    emptyDescription: "Tap the bookmark button while reading to save your place.",
                    fallbackPrimaryText: "Bookmark",
                    onSelect: onSelectBookmark,
                    onDelete: onDeleteBookmarks
                )
            case .history:
                SavedPositionListScreen(
                    records: history,
                    emptyTitle: "No History",
                    emptySystemImage: "clock",
                    emptyDescription: "Your reading positions are recorded automatically as you play, pause, and jump.",
                    fallbackPrimaryText: "Reading position",
                    leadingSecondaryParts: { [$0.reason ?? ""] },
                    onSelect: onSelectHistory,
                    onDelete: onDeleteHistory
                )
            }
        }
        .navigationTitle("Contents")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ChapterListScreen: View {
    let items: [ChapterListItem]
    let selectedItemID: ChapterListItem.ID?
    let onSelect: (ChapterListItem) -> Void

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Chapters",
                    systemImage: "list.bullet.rectangle",
                    description: Text("This book doesn't expose a table of contents.")
                )
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(items) { item in
                            let isSelected = selectedItemID == item.id
                            Button {
                                onSelect(item)
                            } label: {
                                HStack(spacing: 12) {
                                    Text(item.title)
                                        .fontWeight(isSelected ? .semibold : .regular)
                                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.leading, CGFloat(item.level * 16))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        }
                    }
                    .listStyle(.plain)
                    .onAppear {
                        guard let selectedItemID else {
                            return
                        }
                        // Defer one runloop so the List has laid out its rows
                        // before scrolling; scrollTo is unreliable during the
                        // initial layout pass when the screen is first presented.
                        DispatchQueue.main.async {
                            proxy.scrollTo(selectedItemID, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

/// Tappable, swipe-to-delete list of saved places. Bookmarks and history render
/// identically apart from their empty state, fallback title, and (for history)
/// the reason prefix on the subtitle line.
struct SavedPositionListScreen<Record: SavedPositionRecord>: View {
    let records: [Record]
    let emptyTitle: String
    let emptySystemImage: String
    let emptyDescription: String
    let fallbackPrimaryText: String
    /// Extra subtitle parts shown ahead of the shared ones.
    var leadingSecondaryParts: (Record) -> [String] = { _ in [] }
    let onSelect: (Record) -> Void
    let onDelete: (Set<Record.ID>) -> Void

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySystemImage,
                    description: Text(emptyDescription)
                )
            } else {
                List {
                    ForEach(records) { record in
                        Button {
                            onSelect(record)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.displayPrimaryText ?? fallbackPrimaryText)
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Text(record.displaySecondaryText(leadingParts: leadingSecondaryParts(record)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        onDelete(Set(offsets.map { records[$0].id }))
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}
