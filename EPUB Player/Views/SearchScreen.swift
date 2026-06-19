//
//  SearchScreen.swift
//  EPUB Player
//
//  Created by F2PGOD on 18/6/2026.
//

import Combine
import ReadiumShared
import SwiftUI

/// Drives full-text search within the currently open publication.
///
/// Modeled on Readium's reference `SearchViewModel`: it kicks off a search via
/// `publication.search(query:)` and pages through the resulting iterator,
/// appending locators as they arrive.
@MainActor
final class ReaderSearchViewModel: ObservableObject {
    enum State {
        /// No query has been submitted yet.
        case empty
        /// A search was submitted and we are waiting for the iterator.
        case starting
        /// Waiting state, holding an iterator ready for the next page.
        case idle(SearchIterator)
        /// Loading the next page of results.
        case loadingNext(SearchIterator, Task<Void, Never>)
        /// Reached the end of the results.
        case end
        /// A search error occurred.
        case failure(SearchError)
    }

    @Published private(set) var state: State = .empty
    @Published private(set) var results: [Locator] = []
    @Published private(set) var query: String = ""

    private let publication: Publication

    init(publication: Publication) {
        self.publication = publication
    }

    private var searchJob: Task<Void, Never>? {
        didSet { oldValue?.cancel() }
    }

    /// Starts a new search with the given query (search-on-submit).
    func search(with query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = trimmed

        cancelSearch()

        guard !trimmed.isEmpty else {
            return
        }

        state = .starting

        searchJob = Task { [weak self] in
            guard let self else { return }
            switch await self.publication.search(query: trimmed) {
            case let .success(iterator):
                self.state = .idle(iterator)
                self.loadNextPage()
            case let .failure(error):
                self.state = .failure(error)
            }
        }
    }

    /// Loads the next page of results. Safe to call repeatedly.
    func loadNextPage() {
        guard case let .idle(iterator) = state else {
            return
        }

        state = .loadingNext(iterator, Task { [weak self] in
            guard let self else { return }
            switch await iterator.next() {
            case let .success(collection):
                if let collection {
                    self.results.append(contentsOf: collection.locators)
                    self.state = .idle(iterator)
                } else {
                    self.state = .end
                }
            case let .failure(error):
                self.state = .failure(error)
            }
        })
    }

    /// Cancels any ongoing search and clears results.
    func cancelSearch() {
        if case let .loadingNext(_, task) = state {
            task.cancel()
        }
        searchJob = nil
        results.removeAll()
        state = .empty
    }
}

/// Full-text search UI presented from the reader.
struct SearchScreen: View {
    @ObservedObject var viewModel: ReaderSearchViewModel
    let indicator: (Locator) -> String
    let onSelect: (Locator) -> Void

    @State private var field: String = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField

            Divider()

            content
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            field = viewModel.query
            isFieldFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search in book", text: $field)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFieldFocused)
                .onSubmit {
                    viewModel.search(with: field)
                }

            if !field.isEmpty {
                Button {
                    field = ""
                    viewModel.cancelSearch()
                    isFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .empty:
            if viewModel.query.isEmpty {
                ContentUnavailableView(
                    "Search This Book",
                    systemImage: "magnifyingglass",
                    description: Text("Type a word or phrase to find it in the text.")
                )
            } else {
                resultsList
            }

        case .starting:
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .idle, .loadingNext, .end:
            if viewModel.results.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "text.magnifyingglass",
                    description: Text("No matches found for “\(viewModel.query)”.")
                )
            } else {
                resultsList
            }

        case let .failure(error):
            ContentUnavailableView(
                "Couldn’t Search",
                systemImage: "exclamationmark.triangle",
                description: Text(searchErrorMessage(error))
            )
        }
    }

    private var resultsList: some View {
        List {
            ForEach(Array(viewModel.results.enumerated()), id: \.offset) { index, locator in
                Button {
                    onSelect(locator)
                } label: {
                    SearchResultRow(locator: locator, indicator: indicator(locator))
                }
                .buttonStyle(.plain)
                .onAppear {
                    if index == viewModel.results.count - 1 {
                        viewModel.loadNextPage()
                    }
                }
            }

            if case .loadingNext = viewModel.state {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .listStyle(.plain)
    }

    private func searchErrorMessage(_ error: SearchError) -> String {
        switch error {
        case .publicationNotSearchable:
            return "This book doesn’t support text search."
        case .badQuery:
            return "That search query couldn’t be used."
        case .reading:
            return "Couldn’t read the book’s contents to search."
        }
    }
}

private struct SearchResultRow: View {
    let locator: Locator
    let indicator: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let title = locator.title, !title.isEmpty {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if !indicator.isEmpty {
                    Text(indicator)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            snippet
                .font(.subheadline)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var snippet: Text {
        let text = locator.text.sanitized()
        let highlight = text.highlight ?? ""
        let before = sentenceLead(from: text.before ?? "")
        let after = sentenceTail(from: text.after ?? "")

        guard !highlight.isEmpty || !before.isEmpty || !after.isEmpty else {
            return Text(locator.title ?? "")
        }

        return Text(before).foregroundColor(.primary)
            + Text(highlight).bold().foregroundColor(.orange)
            + Text(after).foregroundColor(.primary)
    }

    /// Sentence terminators. The set is also used to keep a trailing closing
    /// quote attached to the sentence it ends.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]
    private static let closingQuotes: Set<Character> = ["\"", "”", "’", "»"]
    /// Safety cap so a sentence without a terminator can't fill the whole row.
    private static let maxTailLength = 160

    /// Keeps only the text after the last sentence terminator in `before`,
    /// so the snippet starts at the beginning of the matched sentence.
    private func sentenceLead(from before: String) -> String {
        guard let terminatorIndex = before.lastIndex(where: { Self.sentenceTerminators.contains($0) }) else {
            return before
        }

        var start = before.index(after: terminatorIndex)
        // Skip any closing quote that belongs to the previous sentence.
        while start < before.endIndex, Self.closingQuotes.contains(before[start]) {
            start = before.index(after: start)
        }

        let lead = before[start...].drop(while: { $0.isWhitespace })
        return String(lead)
    }

    /// Keeps only the text up to and including the first sentence terminator in
    /// `after`, so the snippet ends at the matched sentence. Falls back to a
    /// capped window with an ellipsis when no terminator is present.
    private func sentenceTail(from after: String) -> String {
        guard let terminatorIndex = after.firstIndex(where: { Self.sentenceTerminators.contains($0) }) else {
            if after.count > Self.maxTailLength {
                let end = after.index(after.startIndex, offsetBy: Self.maxTailLength)
                return String(after[..<end]) + "…"
            }
            return after
        }

        var end = after.index(after: terminatorIndex)
        // Include a trailing closing quote that belongs to this sentence.
        if end < after.endIndex, Self.closingQuotes.contains(after[end]) {
            end = after.index(after: end)
        }

        return String(after[..<end])
    }
}
