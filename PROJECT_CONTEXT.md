# Project Context File

## 1. Project Overview

### What This Project Is
- `EPUBPlayer` is an iOS/iPadOS EPUB reader built with SwiftUI and Readium.
- It focuses on EPUB3 reading, especially media-overlay-driven read-aloud playback with active text highlighting.
- The app includes a local network upload server, custom font import, persistent reading progress, theme and typography controls, and a document-backed library.

### Main Goal
- Provide a reliable EPUB reading experience with synchronized read-aloud playback and simple file-based library management.
- Keep all user-persistent state inside the app `Documents` container so deleting `Documents` fully resets the app.

### Who It Is For
- End users who want to read EPUB books on iPhone or iPad.
- Especially useful for users who want read-aloud playback, local file ownership, and simple import workflows.

### Why It Matters
- The project is designed around user-visible file storage and deterministic reset behavior.
- The app treats EPUB files as user-owned documents rather than opaque app-internal data.
- The recent persistence refactor deliberately removed hidden state in SwiftData and `UserDefaults`.

## 2. Current Status

### Completed
- Replaced SwiftData persistence with a custom document-backed `AppStateStore`.
- Removed persistent `UserDefaults` / `@AppStorage` usage for reader settings and upload port.
- Moved EPUB storage to `Documents/Books/`.
- Moved all other persisted state and cache-like artifacts to `Documents/Cache/`.
- Added `Documents/Cache/state.json` as the single persisted state file for:
  - library metadata
  - reading progress
  - reader settings
  - custom font metadata
- Converted `Book` from a SwiftData model to a codable `ObservableObject`.
- Rewired library import, refresh, upload, reader state, and custom font management to use `AppStateStore`.
- Updated the upload/storage messaging in the UI and README to reflect `Documents/Books` and `Documents/Cache`.
- Built successfully after the refactor.
- Changes have been committed and pushed to GitHub.
- Added an XCTest suite (140 tests across 20 files in `EPUB PlayerTests/`) covering
  persistence, storage paths, import/refresh, position validation, archive and XML
  hardening, the upload server, playback, and reader logic. CI runs it on every
  push and PR to `main` (`.github/workflows/ci.yml`).
- Added bookmarks and automatic reading history, surfaced on the Contents screen.
- Added a bounded in-app debug log at `Documents/Cache/debug-log.txt`.
- Hardened untrusted EPUB handling: bounded decompression, pinned XML entity
  resolution, and path-traversal checks on stored paths.

### Currently In Progress
- Fresh-install runtime validation is still needed.
- The highest-value manual checks are:
  - import EPUBs
  - reopen the app and verify state restoration
  - refresh the library
  - import/remove custom fonts
  - delete the app `Documents` folder and verify full reset behavior

### Blocked or Uncertain
- No hard engineering blocker is known.
- Runtime behavior on a fresh install has not yet been fully validated after the persistence cutover.

## 3. Key Requirements

### Functional Requirements
- Import and manage EPUB books.
- Open EPUB books in a SwiftUI/Readium-based reader.
- Support media-overlay read-aloud playback when the EPUB contains valid overlay data.
- Highlight currently spoken text and allow tap-to-play behavior.
- Persist reading progress and last played clip.
- Support custom font import from `.ttf` and `.otf` files.
- Provide a local network upload server for `.epub`, `.ttf`, and `.otf` files.
- Allow library refresh from the `Documents/Books` directory.
- Allow delete and rename operations for stored books.

### Non-Functional Requirements
- Persistent state must live under `Documents` only.
- Deleting the app `Documents` folder must reset the app to a like-new state.
- File operations should be deterministic and user-visible in Files where possible.
- The app should remain responsive during imports and media overlay preparation.
- Writes to persisted state should be atomic.

### User Expectations
- EPUBs should appear in Files under `On My iPhone/EPUBPlayer/Books`.
- Reader settings, covers, custom fonts, and playback-related cache should persist across app launches.
- Refresh should not silently destroy the library when stored EPUBs are still present.
- If state is deleted intentionally, the app should reset cleanly without hidden leftovers.

### Constraints and Limitations
- No migration or backward-compatibility layer was requested for old persisted installs.
- No persistent user state should live outside `Documents`.
- Do not reintroduce SwiftData default storage or `UserDefaults` persistence without explicit approval.
- HTTP upload only supports `.epub`, `.ttf`, and `.otf`.
- Chunked HTTP uploads are explicitly not supported.
- Read-aloud only works when the EPUB has usable media overlays and parsing succeeds.

## 4. Architecture / Structure

### Main Components
- `EPUB Player/App/EPUBPlayerApp.swift`
  - App entry point.
  - Creates and injects a shared `AppStateStore`.

- `EPUB Player/Persistence/AppStateStore.swift`
  - Central persisted app state.
  - Stores books, custom font metadata, and reader/upload settings.
  - Reads/writes `Documents/Cache/state.json`.
  - Observes each `Book` and debounces saves.

- `EPUB Player/Persistence/AppStorage.swift`
  - Defines storage layout and path helpers.
  - This is the app's own type, unrelated to SwiftUI's `@AppStorage`.
  - Key directories:
    - `Documents/Books/`
    - `Documents/Cache/`
    - `Documents/Cache/Covers/`
    - `Documents/Cache/MediaOverlays/`
    - `Documents/Cache/AudioCache/`
    - `Documents/Cache/Uploads/`
    - `Documents/Cache/Fonts/`

- `EPUB Player/Models/Book.swift`
  - Plain codable observable model for a library book.
  - Holds library metadata, progress state, and media overlay preparation state.
  - Also defines `SavedPositionRecord`, the shared shape behind `Bookmark` and
    `HistoryEntry`, which carries their position fields and row-rendering text.

- `EPUB Player/App/ContentView.swift`
  - Top-level tab UI.
  - Contains the Books, Upload, and Settings flows.
  - Starts/resumes media overlay preparation and restores missing covers when app becomes active.

- `EPUB Player/Views/ReaderView.swift`
  - EPUB reading UI built around Readium navigator.
  - Applies theme/typography settings from `AppStateStore`.
  - Coordinates playback, location persistence, chapter navigation, and highlight rendering.

- `EPUB Player/Services/BookImportService.swift`
  - Handles EPUB import, library refresh, cover regeneration, and overlay preparation scheduling.
  - Contains `BookAssetCacheService` and `MediaOverlayPreparationCoordinator`.

- `EPUB Player/Upload/UploadServerController.swift`
  - Owns the upload server state machine and import queue.
  - Handles manual imports and server-driven imports.
  - Exposes library listing, rename, and delete via server callbacks.

- `EPUB Player/Upload/LocalUploadServer.swift`
  - Lightweight HTTP server built on `Network.framework`.
  - Serves upload page and simple library API endpoints.

- `EPUB Player/Upload/HTTPUploadRequest.swift`
  - Parses incoming multipart upload requests.

- `EPUB Player/Services/CustomFontStore.swift`
  - Imports custom fonts into `Documents/Cache/Fonts`.
  - Stores font family metadata in `AppStateStore`.
  - Registers fonts for UI and produces Readium font declarations.

- `EPUB Player/Services/ReadiumBookService.swift`
  - Opens stored EPUBs using Readium Streamer.

- `EPUB Player/Services/EPUBMetadataService.swift`
  - Extracts package metadata and cover references from EPUB archives.

- `EPUB Player/Services/EPUBMediaOverlayService.swift`
  - Parses EPUB media overlay content and writes normalized overlay manifests.

- `EPUB Player/Services/EPUBArchive.swift`
  - Bounded ZIP extraction for untrusted EPUB files.

- `EPUB Player/Services/BookPositionValidator.swift`
  - Revalidates saved positions (resume point, bookmarks, history) after a re-import,
    against the new resource hrefs and then the new clip set.

- `EPUB Player/Services/ClipLocationMatcher.swift`
  - Resolves a resource/fragment reference to an index in the clip list.

- `EPUB Player/Services/DebugLog.swift`
  - Bounded in-app debug log written to `Documents/Cache/debug-log.txt`.

- `EPUB Player/Playback/MediaOverlayPlaybackController.swift`
  - Loads overlay clip manifests.
  - Materializes audio assets into cache.
  - Controls `AVPlayer` playback, jumping, resume, and auto-advance.

### How Components Interact
- `EPUBPlayerApp` creates `AppStateStore` and injects it into the SwiftUI hierarchy.
- `ContentView` reads shared state and hosts the three primary tabs.
- `BooksView` uses `UploadServerController` for manual import requests and `BookImportService` for refresh.
- `BookImportService` copies EPUBs into `Documents/Books`, extracts metadata, caches covers, updates `AppStateStore`, and schedules overlay preparation.
- `ReaderView` opens a `Book` through `ReadiumBookService`, applies settings from `AppStateStore`, and uses `MediaOverlayPlaybackController` for audio.
- `UploadServerController` wraps `LocalUploadServer`, receives uploaded files into `Documents/Cache/Uploads`, then routes them into either `BookImportService` or `CustomFontStore`.
- `CustomFontStore` updates `AppStateStore`; `ReaderView` reads those families and passes them into Readium font declarations.

### Important Files, Folders, Modules, Services, or Systems
- Repo root:
  - `EPUB Player.xcodeproj/`
  - `EPUB Player/`
  - `README.md`
  - `build_unsigned.sh`
  - `docs/images/`

- Storage model inside app sandbox `Documents`:
  - `Books/` for imported EPUBs
  - `Cache/` for all persisted non-EPUB artifacts and state

- Persisted state file:
  - `Documents/Cache/state.json`

- Build command:
  - `xcodebuild -project "EPUB Player.xcodeproj" -scheme "EPUB Player" -destination 'generic/platform=iOS Simulator' build`

- Test command:
  - `xcodebuild test -scheme "EPUB Player" -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO`
  - Tests redirect storage via the `EPUBPLAYER_DOCUMENTS_DIRECTORY` environment variable (see `TestDocumentsDirectory.swift`).

### Dependencies and Integrations
- SwiftUI for app UI.
- Readium Swift Toolkit packages:
  - `ReadiumShared`
  - `ReadiumStreamer`
  - `ReadiumNavigator`
  - `ReadiumAdapterGCDWebServer` is linked in the project, though the current upload server implementation uses `Network.framework` directly.
- `AVFoundation` for read-aloud playback.
- `Network.framework` for the local HTTP upload server.
- `CoreText` for custom font registration and metadata inspection.

## 5. Important Decisions

### Major Decisions Made So Far
- Replace SwiftData persistence with a custom JSON-backed `AppStateStore`.
- Remove persistent `UserDefaults` / `@AppStorage` state.
- Store EPUB files in `Documents/Books/`.
- Store all other app-owned state and caches under `Documents/Cache/`.
- Make `epubFilePath` the source of truth for locating EPUBs.
- Use relative stored paths such as `Books/<filename>` rather than absolute paths.
- Accept fresh-install-only behavior instead of building migration code.

### Why Those Decisions Were Made
- The user explicitly wanted all persistent app state under `Documents`.
- Hidden persistence in SwiftData and `UserDefaults` violated the desired reset semantics.
- Relative document paths are safer than absolute sandbox paths across reinstalls and environment changes.
- A custom state store makes persistence behavior visible and auditable.

### Alternatives Considered or Implicitly Rejected
- Keeping SwiftData but relocating its store: rejected because the user explicitly wanted no SwiftData default store.
- Keeping settings in `UserDefaults`: rejected because user state must not persist outside `Documents`.
- Adding migration logic for older installs: rejected because the user accepted fresh-install-only behavior.

## 6. Detailed Notes

### Easy-to-Forget Details
- `Book` is no longer a SwiftData `@Model`; it is now a codable `ObservableObject`.
- `AppStateStore` debounces writes with a short delay, but `persistNow()` forces an immediate save.
- `AppStateStore` writes state using `Data.write(..., options: .atomic)`.
- `AppStateStore` decodes each key independently, so one bad field cannot reset the whole library.
- If `state.json` is entirely unreadable, it is moved aside to
  `Documents/Cache/state-corrupt-<timestamp>.json` before defaults are used, so the
  original is never silently overwritten.
- `Book.coverImagePath` and `Book.mediaOverlayJSONPath` are stored as filenames relative to cache directories, not full paths.
- `Book.epubFilePath` should be treated as a stored relative path under `Documents`, typically `Books/<filename>`.

### Edge Cases and Recovery Logic
- Library refresh first scans `Documents/Books/`.
- If directory scanning fails or returns empty while existing books are still known, refresh falls back to saved book paths.
- If neither scanning nor fallback can verify the library, refresh throws `BookImportError.libraryFilesUnavailable` with the message:
  - `Could not verify the imported EPUB files. Your library was left unchanged.`
- Missing cached covers can be regenerated from the EPUB on app activation.
- Missing or invalid overlay cache can trigger overlay regeneration.
- If a selected custom font family disappears, `CustomFontStore` resets the selected font back to default.

### Special Rules
- Do not introduce persistence outside `Documents` unless the user explicitly changes the requirement.
- Do not add compatibility shims or migration code by default.
- Do not change `epubFilePath` semantics casually; multiple systems rely on it.
- Renaming a book through the upload server updates the display title only if the title was previously derived from the filename.

### Known Assumptions
- A fresh install is acceptable after the persistence refactor.
- Files in `Documents/Books` are the authoritative library source.
- Media overlay preparation can happen asynchronously after initial import.
- Uploaded files arrive over local network from devices on the same network.

### Relevant Terminology
- `AppStateStore`: the current persistence backbone.
- `state.json`: the single persisted app-state document.
- `Media overlay`: EPUB synchronized text/audio timing data.
- `Overlay manifest`: normalized JSON representation of parsed media overlay clips.
- `Book asset cache`: cached cover image, overlay manifest, and extracted audio assets for a book.

## 7. Problems and Open Questions

### Known Bugs
- No currently confirmed reproducible bug is documented after the latest refactor.
- Previously fixed problem chain:
  - cover cache loss caused missing covers
  - refresh could collapse the visible library when files could not be verified safely

### Risks
- Fresh-install runtime behavior has not yet been fully validated end-to-end.
- A wholly unreadable `state.json` is preserved as `state-corrupt-<timestamp>.json`, but
  there is still no user-visible recovery UI and the backups are never pruned.
- The local HTTP server's rename and delete endpoints are unauthenticated when no
  upload password is set.
- Network upload depends on same-network connectivity and the availability of a Wi-Fi IP address.

### Unresolved Design or Technical Questions
- Should a corrupted `state.json` surface a user-visible recovery warning, and should old `state-corrupt-*.json` backups be pruned?
- Should the upload server's rename/delete endpoints require a password rather than defaulting to open?
- Is additional runtime validation needed for Files app visibility and deletion/reset behavior on real devices?

## 8. Next Steps

### Immediate Tasks
- Perform fresh-install runtime validation.
- Verify EPUB import places files in `Documents/Books/` and exposes them in Files as expected.
- Verify app relaunch restores:
  - library entries
  - covers
  - reading progress
  - reader settings
  - custom fonts
- Verify refresh works without deleting valid library records.
- Verify deleting `Documents` fully resets the app.

### Later Tasks
- Consider a user-visible recovery path (and backup pruning) for a corrupted `state.json`.
- Consider requiring the upload password for the server's rename/delete endpoints.

### Suggested Priorities
1. Fresh-install runtime verification.
2. Upload server authorization for destructive endpoints.
3. Optional resilience improvements around corrupted persisted state.

## 9. How Future AI Should Help

### What the AI Should Understand Before Answering
- The project recently changed persistence architecture in a major way.
- The current source of truth is the code, not older assumptions about SwiftData.
- The storage contract is important: EPUBs in `Documents/Books`, everything else in `Documents/Cache`.
- The user prefers small, pragmatic changes over abstraction-heavy rewrites.

### Preferred Coding / Writing / Design Style
- Prefer minimal, targeted code changes.
- Keep logic in existing structures unless extraction has a clear payoff.
- Preserve established SwiftUI patterns already used in the app.
- Write concise technical explanations with concrete file references when helpful.

### Things the AI Should Avoid
- Do not reintroduce SwiftData persistence or `UserDefaults` persistence for app state without explicit approval.
- Do not add migration layers, backward-compatibility shims, or duplicate persistence systems unless explicitly requested.
- Do not change file-path semantics or storage locations casually.
- Do not remove or overwrite unrelated user changes in the worktree.
- Do not land changes without running the test suite; it is wired into CI.

### Context to Preserve Across Future Conversations
- The persistence refactor is complete in code and pushed, but runtime validation is still pending.
- The app should behave like new if the `Documents` folder is deleted.
- `BookImportError.libraryFilesUnavailable` is an intentional guard against destructive refresh behavior.
- Covers, overlays, audio cache, uploads, fonts, and app state all intentionally live under `Documents/Cache`.
- Any future feature work should continue respecting the document-only persistence model unless the user explicitly changes that requirement.

## Reference Snapshot
- Repository: `https://github.com/seedds/EPUB_Player.git`
- Primary branch: `main`
- Persistence-refactor commit: `0d9253e` (`Move app persistence into Documents`)
- Current state when this file was last updated:
  - code changes committed and pushed
  - simulator build succeeded
  - 140 tests passing
  - manual fresh-install runtime verification still pending

Section 4's file paths, section 7's risks, and this snapshot are the parts most likely
to drift. Verify them against the code before relying on them.
