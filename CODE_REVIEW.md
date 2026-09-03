# Code Review and Ablation — EPUB Player (2026-09-04)

## Context

The user asked for a code review of the whole app (bugs and improvements) plus an
"ablation experiment" (消融实验): find abstractions and design elements that can be removed
without changing behaviour. Scope: ~11k lines of app Swift in 22 files, ~6k lines of tests
(147 tests, green in CI). Build uses Swift 5 mode with `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor`, so anything not marked `nonisolated` is main-actor.

PROJECT_CONTEXT.md records a standing preference for small pragmatic changes and against
abstraction-heavy rewrites. The ablation list below only *removes* layers; it introduces
none. Every finding was verified against the source (file:line given). Where a
sub-reviewer's claim did not hold up it is either dropped or downgraded and noted.

Uncommitted worktree change: `project.pbxproj` adds `DEVELOPMENT_TEAM` and bumps
`MARKETING_VERSION` 1.0.31 → 1.0.35. Unrelated to this review; leave it alone.

---

## Part A — Bugs and improvements

### HIGH (user-visible data problems or main-thread stalls)

**A1. Library refresh drops every cover it (re)imports and leaks the staged cover file.**
`preparedBookImport` stages the cover and sets `metadata.coverImagePath = nil`
(`BookImportService.swift:589-591`); the staged file is only promoted in
`applyPreparedImport` (`:372-381`), which is called only from `importBook` (`:143`). The
refresh path calls `upsertBook` directly (`:303`), so the book gets `coverImagePath = nil`
and `Cache/Covers/<id>.import-<uuid>.<ext>` is orphaned. Covers stay blank until
`restoreMissingCovers` runs on the next scene-phase change.

**A2. Refresh sanitises the on-disk filename but never renames the file; the record points
at a file that does not exist.** `:235` computes `sanitizedFilename(sourceURL.lastPathComponent)`
and `:597` stores `Books/<sanitised>`, but `prepareRefreshImport` (`:694-711`) stages
`fileURL == destinationURL == sourceURL` and nothing moves the file. Any Files-app drop
whose name contains `'`, `,`, `#`, `&`, `!`, `+` … (anything outside alphanumerics and
` ._-()[]`, `AppStorage.swift:213`) yields a book that cannot be opened. On the *next*
refresh it is treated as missing and removed (`:200-217`), then re-scanned; because
`existingBooksByFilename` (`:196`) was built before the removals, `upsertBook` takes the
existing-book branch on the already-removed object and never calls `store.addBook`
(`:416-441`) → the book vanishes from the library for one refresh, then reappears with a
new UUID and no bookmarks/history/position.

*Fix for A1+A2 (one change):* route refresh through `applyPreparedImport` instead of
`upsertBook`, with `prepareRefreshImport` producing `StagedLibraryFile(fileURL: sourceURL,
destinationURL: Books/<sanitised>)`. `finalizeStagedLibraryFile` then renames the file and
`commitStagedCover` promotes the cover. Guard: if the sanitised destination already exists
and is a different file, skip that file with an error rather than `replaceItemAt` (two
distinct names can sanitise to the same string). Build `existingBooksByFilename` from
`store.books` *after* the removal loop.

**A3. Every `Book` mutation re-renders the whole app, and the Books list does file-system
work inside `body`.** `AppStateStore.observeBook` forwards each book's `objectWillChange` to
the store's (`AppStateStore.swift:355-365`). `saveLocation` mutates the book on every
navigator location change (`ReaderView.swift:729-734`) and `updateLastLocation` also
stamps `lastOpenedAt` each time (`Book.swift:311-314`, two publishes). Every view holding
`@EnvironmentObject store` re-evaluates per scroll tick, including the still-mounted
`BooksView`, whose body: re-sorts the library with `localizedCaseInsensitiveCompare`
(`ContentView.swift:66-68`, `AppStateStore.swift:216-220`), parses locator JSON per row
(`ContentView.swift:437-445`), and calls `book.resolvedCoverImageURL()` in
`BookCoverView.init` (`:515-522`), which goes through `coversDirectory()` →
`FileManager.createDirectory` (`AppStorage.swift:72-74, 255-258`) — a syscall per visible
row per body pass.
*Fix:* stop stamping `lastOpenedAt` on every save (only on open); cache `sortedBooks` and
invalidate on `books`/`booksSortOption` change; cache `readingProgress` and the resolved
cover URL per book (or resolve without `ensureDirectory`).

**A4. Debug log does a synchronous file write on the main actor on every location change and
clip change.** `ReaderView.swift:819` and `:1465-1469`; `DebugLog.log` writes to the file
handle inline (`DebugLog.swift:83-90, 136-149`). The message argument is a plain `String`,
so the interpolation (four `String(describing:)` + URL normalisations at `:1465-1469`) is
paid even when nothing reads the log.
*Fix:* `@autoclosure` message; buffer lines and flush off-main (serial queue) or on a
timer; keep the in-memory ring.

**A5. `persistNow()` on every play, pause, tap-to-play, chapter select and jump.**
`recordHistory` ends with `store.persistNow()` (`ReaderView.swift:1022`), reached from
`:387-390, :397, :1076, :1121, :1213`; also `:901, :924` for bookmarks. Each is a full
library JSON encode plus atomic write on the main actor, bypassing the debounce that exists
for exactly this. There are 21 `persistNow()` call sites in the app.
*Fix:* keep `persistNow()` only at lifecycle edges (scene background, `onDisappear`,
import/delete completion, rename). Everything else relies on the 150 ms debounce.

### MEDIUM

**A6. `state.json` handling conflates I/O failure with corruption, and swallows write
errors.** `readPersistedState` returns `.unreadable` for a `Data(contentsOf:)` failure
(`AppStateStore.swift:317`) and `.unreadable` moves the file aside and shows an empty
library (`:278-279`). Separately, any JSON *object* decodes as `.loaded` because only
`decoder.container` can throw (`:89-112`): `{}` or `"books": {}` → zero books, no backup,
and the next settings change overwrites the file. `writeStateToDisk` swallows every error
(`:492-505`); if `backUpUnreadableStateFile` fails (`:303-305`, e.g. same-second timestamp
collision) `canPersistState` stays `false` for the session and every save is a silent no-op.
*Fix:* four load results (loaded / missing / ioError / corrupt); `ioError` → keep file,
`canPersistState = false`; treat "books key present but not an array" as corrupt; log
write failures to `DebugLog` and expose a `@Published persistenceFailure` for Settings.

**A7. Overlay manifest committed by reading the whole file into memory on the main actor.**
`BookImportService.swift:1279-1281` inside the `@MainActor` task at `:1214`. Use
`FileManager.replaceItemAt`/`moveItem`.

**A8. Seamless auto-advance is gated on a log string.** `isAutomaticAdvanceReason` does
`reason.hasPrefix("boundaryObserver") || hasPrefix("itemEndObserver")`
(`MediaOverlayPlaybackController.swift:984, 1015-1017`); producers are the literals at
`:889, :915`. Renaming a log string silently disables seamless advance with no test failure.
*Fix:* `enum AdvanceTrigger { case boundary, endOfItem, manual }` parameter; derive the log
text from it.

**A9. Bookmark/history snapshot mixes the visible page with the playing clip.**
`currentPositionSnapshot` takes chapter/href/progress/locator from `navigator.currentLocation`
but clip identity from `playback.currentClipIndex` (`ReaderView.swift:948-977`);
`goToSavedPosition` prefers the clip (`:1078-1093`). Scroll to chapter 8 while chapter 3
narrates, bookmark → record says chapter 8, resolves to chapter 3.
*Fix:* when a clip is active and its resource differs from the visible resource, either
snapshot everything from the clip or omit the clip fields.

**A10. Upload connection state is touched from two queues; idle timer keeps running during
API round-trips; `cleanup()` runs twice.** `HTTPUploadConnection` is queue-confined
(`LocalUploadServer.swift:322`) but the library-API completions are invoked from `Task {
@MainActor }` (`UploadServerController.swift:188-219`) and call `finishWithJSON` → `finish`
→ `cleanup` (`:533-541, 666-706`) while the idle timer (`:344-355`) may fire
`finishWithError` on `queue`. A >60 s main-actor stall yields a spurious 500 plus a second
response on the same connection. `cancel()` calls `cleanup()` and the `.cancelled` state
handler calls it again (`:336-339, 328-329`) → `onComplete` twice.
*Fix:* hop to `queue` at the top of the completion; cancel the idle timer once the request
is dispatched; make `cleanup` idempotent.

**A11. Upload request validation gaps.** No `Content-Type` check, so a multipart body (any
`<form enctype="multipart/form-data">` or `curl -F`) is stored verbatim as `x.epub` with a
200 (`:439-488`). `Content-Length: 0` accepted → zero-byte file, 200 (`:483`).
`Transfer-Encoding: gzip, chunked` bypasses the chunked guard (`:449`). No `Host` check, so
with the default no-password config the rename/delete endpoints are reachable via DNS
rebinding. `507` has no reason phrase (`:722-735`). `HEAD` returns a body (`:413-427`).
*Fix:* reject non-`application/epub+zip`/`font/*`/`application/octet-stream` content types
and zero length with 4xx; `contains("chunked")`; require `Host` to be an IP literal or
`.local`; add `507`; drop body for HEAD.

**A12. Completed-but-unimported uploads leak forever.** `finishUpload` moves the file to an
un-prefixed name (`:641-642`); `stop()` drops `pendingImports` without touching disk
(`UploadServerController.swift:242-244`); the sweep only matches `.upload-`
(`LocalUploadServer.swift:200`). *Fix:* delete `pendingImports` sources in `stop()`, or
sweep the whole `Uploads` directory at start.

**A13. Renaming a book to a dot-prefixed name hides it and then deletes it.**
`epubFilename(from:)` allows a leading `.` (`UploadServerController.swift:519-533`); the
scan uses `.skipsHiddenFiles` (`BookImportService.swift:890`) and `removeStalePartialImports`
deletes `.import-*` after 5 min (`:984`). *Fix:* reject filenames starting with `.`.

**A14. Refresh's per-file catch discards the error and mislabels cancellation.**
`:309-311` appends to `skippedFilenames` for any error including `CancellationError`; the
message is an unbounded filename list (`:339-341`). *Fix:* rethrow `CancellationError`;
log the error; cap the list.

**A15. Half-applied import on cover-commit failure.** `applyPreparedImport` moves the EPUB
first (`:365`), then `commitStagedCover` can throw (`:373`); the catch (`:159-162`) calls
`cleanupPreparedImport`, which removes `stagedLibraryFile.fileURL`, a path that no longer
exists. Disk has the new bytes, overlay artifacts are gone (`:370`), the store has the old
record, and the import reports failure. *Fix:* commit cover before moving the EPUB, or
treat cover failure as non-fatal (`try?`, log).

**A16. Bounded decompression can be bypassed by a lying ZIP header.** `data(for:)` checks the
declared size then streams into `DataAccumulator`, whose `append` silently drops chunks past
the limit because the comment claims the consumer "has no way to abort the stream"
(`EPUBArchive.swift:160-207`). ZIPFoundation's `Consumer` is `@Sendable (Data) async throws
-> Void` (`Data+Compression.swift:31`), so it *can* throw. Memory is bounded but CPU/time is
not. *Fix:* throw a sentinel from `append`; in the catch at `:171`, check
`didExceedLimit` before mapping to `.corruptEntry`.

**A17. `containedFileURL` returns the base *directory* for an empty stored path.**
`AppStorage.swift:151-155`; `Book.resolvedCoverImageURL()` with `coverImagePath == ""`
returns `Cache/Covers/`, and `fileExists` is true for a directory. *Fix:* throw
`invalidStoredFilePath`; add a test.

**A18. `ClipLocationMatcher` re-normalises every clip href on every lookup; one entry point is
O(clips × readingOrder).** `ClipLocationMatcher.swift:111-113, 87-97`; production always
passes `normalizedResourceHref(for:)` (`AnyURL` parse + trimming) and `savedPositionIndex`
runs on location changes (`ReaderView.swift:805`). *Fix:* normalise clip hrefs once when the
manifest loads and store them on the clip; index `readingOrderResourceHrefs` into a
`[String: Int]`.

**A19. `narratedTimeline()` can cache a timeline from the previous book.** It awaits per-clip
durations (`MediaOverlayPlaybackController.swift:776-801`); `load()` clears the cache
(`:250`) but an in-flight computation writes it back afterwards (`:799`). *Fix:* capture
`loadGeneration` at start and only write if unchanged (pattern already used at `:289-291`).

**A20. Upload progress: main-actor hop + `@Published` array replace per 64 KB chunk.**
`LocalUploadServer.swift:625-627`, `UploadServerController.swift:152-156, 375-390`.
*Fix:* throttle to ~10 Hz or a 1 % byte delta.

**A21. Idle timer can stay disabled after the reader is gone.** `onDisappear` skips both
resets when `isChapterListPresented && isPlaying` (`ReaderView.swift:148-172`), and the
`.onChange(of: playback.state)` at `:381` dies with the view. Popping two levels at once
(back-button long-press) reproduces it. *Fix:* own the idle-timer flag in one place keyed
off `playback.state`, reset in the controller's `stop()`.

**A22 (plausible, needs runtime confirmation). `shouldClearSavedClip` can clear the resume
point after a *successful* mid-session overlay reload.** `overlayReloadDepth` is released
by `defer` when `load` returns (`ReaderView.swift:571-573`), but `.onChange(of:
playback.currentClipIndex)` is delivered on the next render pass; on success `load` sets
non-empty `clips` and `currentClipIndex = nil` (`MediaOverlayPlaybackController.swift:292-293`),
so the triple is `(true, false, true)` → clear (`:745-751, 776-782`).
`ReaderViewLogicTests.testClearsOnGenuineUserStop` locks in exactly that combination.
*Fix:* have `load` return the previous selection's identity and re-resolve it, instead of
inferring intent from a nil index. Verify on device first.

### LOW

- `sanitizedFilename` falls back to the literal `"upload.epub"` for any name; it is used
  for cover extensions (`AppStorage.swift:89`) and font import (`CustomFontStore.swift:110`),
  producing "upload.epub can't be imported" for a font. Use `sanitizedFilenameOrNil` +
  caller fallback.
- `uniqueFileURL` is TOCTOU-racy under concurrent uploads (`AppStorage.swift:229-233`).
- `applyPersistedState` clamps only `autoRewindAfterBackgroundMinutes` (`AppStateStore.swift:328-346`).
  Not exploitable (playback rate is clamped in `setPlaybackRate`, font sizes at use sites);
  consistency only. *(A sub-reviewer reported this as a bug; that was wrong.)*
- `javaScriptStringLiteral` does not escape U+2028/U+2029 (`ReaderView.swift:2047-2054`).
  Safe on current WebKit; build the payload with `JSONSerialization` to make it obviously so.
- `addBook` assigns `books` twice → two publishes (`AppStateStore.swift:228-233`).
- `audioCacheFileURL` maps `a/b.mp3` and `a__b.mp3` to the same file (`AppStorage.swift:105-106`).
- `allFamilies` stats every font file three times per view appearance
  (`CustomFontStore.swift:87-91, 259, 294, 308`).
- Server: `POST /uploadxyz` → 415 not 404; no `X-Content-Type-Options: nosniff` on
  error bodies echoing filenames; `/api/auth` has no rate limit; upload password stored in
  cleartext in `state.json`; `recentUploads` unbounded; new `DispatchSourceTimer` per chunk
  (`:344-355`); `.waiting` permanently stops the listener (`:115-119`); stale staged
  manifests in `Cache/MediaOverlays` are never swept; three `print()` error sinks
  (`BookImportService.swift:779`, `UploadServerController.swift:506`, `ContentView.swift:231`).
- `.skip` strategy is decided after the full copy (`BookImportService.swift:507-532`).
- `DebugLog` `#if DEBUG` test init never closes its handle.
- Docs drift: PROJECT_CONTEXT says "140 tests across 20 files" (147 tests, 17 test files +
  3 helpers) and describes `EPUBArchive` as extraction (production never extracts);
  `.github/workflows/build-unsigned-ipa.yml:27` hashes a non-existent
  `Immersive Reader.xcodeproj/...Package.resolved` path for its cache key.

---

## Part B — Ablation (消融实验)

Each item: what, evidence (call sites), replacement. Tests referenced are the only ones
that would need to change.

### B1. Dead code — delete, zero behaviour change

| Item | Evidence | Lines |
|---|---|---|
| `EPUBArchive.extract(to:)`, `extractEntries`, `actualFileSize`, `safeRelativePath`, error cases `.unsafePath/.writeFailed/.archiveTooLarge`, `maxTotalExtractedBytes`, `maxEntryCount` | Only callers are `EPUBArchiveTests.swift:109,183,207`. Production reads entries on demand and hands the `.epub` to Readium. | ~75 + 3 tests |
| `EPUBMetadataService.metadata(at:)` | 0 call sites | `:127-134` |
| `ReaderSettings.playbackJumpLabel`, `readAloudColorHex(hue:saturation:brightness:)`, `defaultBackground(forTheme:colorScheme:)` | 0 app call sites (last one is test-only, 7 refs in `ReaderSettingsTests`) | `:123-126, 186-188, 71-73` |
| `DebugLog.clear()` | only `DebugLogTests.swift:90`; no Clear button exists | `:92-95` |
| `CustomFontStore.pathExtension(for:fallbackFilename:)` fallback param | never supplied; `:464-467` unreachable | |
| `PlaybackSignposter` + 5 `measure` wrappers | profiling scaffolding for one investigation | `MediaOverlayPlaybackController.swift:20-33, 349-372, 1306` |
| `reason:` on `removeObservers`, `addObservers`, `deactivateAudioSession`, `applyPlaybackRateIfNeeded`, `scheduleAudioSessionIdleDeactivation` | parameter never read in body; call sites build `"selectClip[\(reason)]"` strings on the hot path | `:874-974, 1303-1348` |
| `ReadiumAdapterGCDWebServer` product link | 0 imports; Readium 3.8 deprecates the `httpServer:` init | `project.pbxproj:13,53,109,573-576` (also drops `gcdwebserver` from Package.resolved) |
| `ContentView.hasResumedPendingMediaOverlayPreparation` | `.task {}` on a root view already runs once | `:18, 38-44` |
| `FontFamilySelectionList.onSelect` | both callers pass `nil` | `FontFamilySelectionView.swift:39,49,164`; `ReaderView.swift:2567` |
| `LocalUploadServer.init(port: = 80)` default, `LocalUploadServerError.invalidPort` | port always passed; `normalizedUploadServerPort` clamps to 1…65535 so `.invalidPort` is unreachable | `:12, 95, 104` |
| `performLibraryRequest` `Void?` return trick + 3 `unavailableMessage` strings | all handlers wired before `start()` at the single construction site | `:509-547` |
| Six always-constant `PreparedBookImport` fields (`mediaOverlay*`) | single construction site passes nil/nil/nil/nil/.pending/nil | `BookImportService.swift:593-609, 424-429, 453-458` |
| `cleanupPreparedImport(_:bookID:)` `bookID` + `throws` | param unused; body cannot throw | `:947-960` |
| `SMILParser.resolveReference` tuple member `fileURL` | never read by sole caller `makeClip` | `EPUBMediaOverlayService.swift:454-477` |
| `MediaOverlayPreparationState: CaseIterable` | `.allCases` unused | `Book.swift:11` |
| Write-only persisted fields: `Book.mediaOverlayActiveClass`, `.language`, `.metadataIdentifier`; `Bookmark/HistoryEntry.totalProgress`; manifest `activeClass/playbackActiveClass/narrator`; `EPUBMediaOverlayDocument.smilHref/smilPath/associatedContentHref`; clip `textHref/audioHref/duration`; `EPUBPackageInfo.mediaActiveClass/mediaPlaybackActiveClass/mediaNarrator` + 3 OPF parser branches (`EPUBMetadataService.swift:288-302, 353-359`) | written, never read in production (`audioHref` is set to the same value as `audioPath`) | ~120 across 5 files; each `Book` field also costs CodingKey + decode + encode + init param |

Persisted-format note: dropping `Book` fields is backward compatible (lenient
`decodeIfPresent`); the manifest is a regenerable cache and unknown keys are ignored on
decode, so old manifests still load.

### B2. Pass-through indirection — collapse

| Item | Evidence | Replacement |
|---|---|---|
| `NormalizedBookStoragePaths` + `Book.normalizedStoragePaths` | verbatim 3-field copy; 4 reads (`Book.swift:411,415,422`, `BookImportService.swift:912`) | read the stored properties |
| `ReaderSettings` → `ReadAloudColor` 9 one-line forwarders (`:158-188`) | 11 call sites in `ContentView`/`ReaderView`; both are `nonisolated enum` | call `ReadAloudColor.*` directly, delete 31 lines |
| `EPUBMediaOverlayService.relativePath(for:root:)` (`:321-323`) | codebase already calls `AppStorage.relativePath` directly at `:177` and in `EPUBMetadataService` | one spelling |
| `BookImportService.existingBook(originalFilename:store:)`, `bookForID(_:store:)`, `MediaOverlayPreparationCoordinator.fetchBook(id:store:)`, `UploadServerController.displayTitle(for:)` | one-line store/service forwards, 1 call site each | call the store |
| `clipIdentity(for:)` (`MediaOverlayPlaybackController.swift:1092`, 3 uses) and `ReaderView.playbackStartClipKey(for:)` (`:1423`, 7 uses) | both are `clip.identityKey`; two names for one value | `.identityKey` |
| `PendingImport.Kind`, `ImportProgress`, `RefreshProgress` typealiases | 1 use / aliases of the same struct | drop |
| `FontFamilySelectionView` (`:155-170`) | 1 call site (`ContentView.swift:838-841`); body is `List { FontFamilySelectionList }` + 2 modifiers | inline |
| `applyPlaybackRateIfNeeded(player:shouldUpdateActiveRate:reason:transitionID:)` (`:639-656`) | 2 of 4 params unused; pitch algorithm already set at item creation (`:604`) | `if state.isPlaying { player.rate = Float(playbackRate) }` at 2 sites |

### B3. Duplicates — unify

- **Three identical progress structs** `BookOperationProgress`, `PreparationProgress`,
  `EPUBMediaOverlayProgress` (`{fractionCompleted, message}`) plus `preparationProgress(from:)`
  converter (`BookImportService.swift:25-28, 1143-1146, 1472-1477`; `EPUBMediaOverlayService.swift:10-18`)
  → one `OperationProgress`.
- **Six "is this an EPUB" predicates** (`BookImportService.swift:95, 238, 892`;
  `LocalUploadServer.swift:281-283`; `AppStorage.swift:122`; `UploadServerController.swift:529`)
  → `UploadFileKind`, which already claims to be the single source of truth.
- **Sanitisation applied 2–3× per path** (`BookImportService.swift:94` → `AppStorage.storedBookPath`
  `:112` → `uniqueFileURL` `:222`; hand-rolled `/`,`\` checks in `epubFilename(from:)`
  `UploadServerController.swift:519-533` that `sanitizedFilenameOrNil` already guarantees)
  → sanitise once at the trust boundary.
- **Two stale-file sweeps** (`BookImportService.swift:971-994`, `LocalUploadServer.swift:189-203`)
  with a missing third for `Cache/MediaOverlays` → `AppStorage.sweepStagingFiles(in:prefix:olderThan:)`.
- **Delete-a-book** duplicated (`ContentView.swift:222-235`, `UploadServerController.swift:494-510`)
  → one function.
- **Cover regeneration** duplicated (`BookImportService.swift:248-265`, `:752-796`) → `ensureCover(for:)`.
- **`Task.detached` + `withTaskCancellationHandler` incantation ×5** (`:105-121, 250-258,
  288-296, 769-777, 1256-1268`) with the same comment four times → one generic helper.
- **`fontSizeOptions`/`lineHeightOptions` vs `range + step`** (`ReaderSettings.swift:22-31`) → `stride`.
- **`ReadAloudColor.hsb`** hand-rolls RGB→HSB (`:47-75`) → `UIColor.getHue(_:saturation:brightness:alpha:)`.
- **`test_reset` ⊂ `test_cancelAllPreparations`** (`BookImportService.swift:1499-1524`), called
  back-to-back in tests → keep the draining one.
- **`"/virtual-epub-root"` literal ×2** (`EPUBMetadataService.swift:124`, `EPUBMediaOverlayService.swift:175`).
- **Per-function `nonisolated`**: 25 in `AppStorage`, 27 in `EPUBMetadataService`, 29 in
  `EPUBMediaOverlayService`, 26 in `BookImportService`; `FontFamilyOption` annotates the
  struct *and* every member. `ReaderSettings` already shows the pattern: one type-level
  `nonisolated enum`. Mechanical.

### B4. Structural — recommended, but judgment calls

- **Explicit memberwise inits that only exist because a custom init lives in the type
  body**: `PersistedAppState.init(...)` (`AppStateStore.swift:114-146`, 33 lines) and
  `BookPositionValidator.Positions.init(...)` (`:36-52`). Move `init(from:)` / `init(_ book:)`
  + `apply(to:)` into extensions and the synthesized memberwise init comes back.
- **`PersistedAppStateLoadResult.missing` ≡ `.loaded(.default)`** (`:167-171, 268-280`). Fold
  into the four-case enum from A6.
- **Sort comparator ladder** (`AppStateStore.swift:367-449`, 7 private funcs, ~83 lines) →
  sort-key tuple per option, ~20 lines; also enables the cached `sortedBooks` from A3.
- **`Bookmark` / `HistoryEntry` / `SavedPositionRecord`**: the two structs are identical
  except `reason`; the protocol restates 13 fields and omits `totalProgress`. A single
  `SavedPosition` struct removes the protocol and ~40 lines. Counter-argument: the arrays are
  type-distinct on `Book`, and the protocol was introduced deliberately two commits ago.
  **Recommendation: leave it** unless the user wants the collapse.
- **`store:` threaded through 10 `MediaOverlayPreparationCoordinator` methods** while the
  coordinator is already a singleton → inject once.
- **`BookImportService.swift` is 1 526 lines holding 3 unrelated top-level types** → split
  into three files. No code change.
- **`Book` is `nonisolated` + `MainActor.assumeIsolated` in the observer** (`Book.swift:120`,
  `AppStateStore.swift:360`). Today every mutation is on main (verified), so it is correct;
  marking `Book` `@MainActor` makes the compiler enforce it and removes the crash path.
- **Five `*CommandTarget` fields + 5 teardown branches** (`MediaOverlayPlaybackController.swift:194-213, 57-73`) → `[MPRemoteCommand: Any]`.
- **`seamlessAutoAdvanceTolerance`** used for two unrelated things (clip gap `:990,997`; player
  offset slack `:767-768`) → two constants.
- **Global `UISegmentedControl.appearance()`** in `EPUBPlayerApp.init` for one picker
  (`ReaderView.swift:2171-2176`) → local `.font`.

### Earns its keep — verified and deliberately left alone

`FailableDecodable`; `BookPositionValidator.Positions` (pure/testable seam);
`AppStorage.containedFileURL` + `booksDirectoryExists()`; `makeHardenedXMLParser`;
`EPUBArchive.DataAccumulator` (fix A16, keep the class); `FontFamilyOption`;
`ClipLocationMatcher` (keep `normalize:` injection, fix A18 by normalising once);
`PlaybackResources` (nonisolated deinit teardown); `WeakScriptMessageHandler`;
`transitionID` double guard; `overlayReloadDepth` counter; `cachedActiveChapterItemID`/
`sortedBookmarks`/`sortedHistory` caches; `MediaOverlayPreparationCoordinator`
(`clearTaskEntryIfCurrent` + `contentGeneration` guard are real invariants with tests);
`UploadServerAuthConfig`, `UploadFileKind`, `HTTPUploadRequest`, `UploadRequestLimits`;
`ExistingBookSnapshot`/`SourceFileFingerprint` (`Sendable` boundaries);
`UploadServerController.Status`/`ActiveUpload.Phase` (no unreachable cases);
`Book.contentGeneration`/`pendingClipPositionRevalidation`.

---

## Suggested first pass (High bugs + B1 + B2 + two low-risk B4 items)

Each step is a separate commit that leaves the 147 tests green (minus the tests deleted
with the code they covered).

1. **A1+A2** — `prepareRefreshImport` produces `StagedLibraryFile(fileURL: sourceURL,
   destinationURL: Books/<sanitised>)`; refresh calls `applyPreparedImport` instead of
   `upsertBook` (`BookImportService.swift:298-303`); guard in `finalizeStagedLibraryFile`'s
   caller: if the sanitised destination exists and is not the source, skip the file with an
   error instead of `replaceItemAt`; build `existingBooksByFilename` from `store.books`
   after the removal loop (`:196-217`). Tests in `BookImportServiceTests`: refresh of a
   Files-dropped `Don't Panic.epub` renames the file, opens via `resolvedEPUBFileURL`, keeps
   the record ID, has a committed cover and no `.import-` leftover; a second refresh changes
   nothing; two files sanitising to one name → one imported, one skipped.
2. **A3 + B4 sort ladder** — `Book.updateLastLocation` stops stamping `lastOpenedAt`
   (stamp it in `openBook` only); `AppStateStore.sortedBooks` becomes a stored array
   recomputed when `books` or `booksSortOption` change (sort-key tuple replaces the 7
   comparator functions, `AppStateStore.swift:367-449`); `BookRow.readingProgress` and
   `BookCoverView`'s resolved URL are computed once per book change, not per body pass
   (`ContentView.swift:437-445, 515-522`); `resolvedCoverImageURL` must not call
   `ensureDirectory`. Existing `AppStateStoreTests` sorting tests must still pass unchanged.
3. **A4** — `DebugLog.log(_ message: @autoclosure () -> String)`; file writes batched onto
   a serial `DispatchQueue` with flush on `persistNow`/background; ring buffer unchanged.
   `DebugLogTests` rotation/tail tests must pass; add a flush call where they read the file.
4. **A5** — delete `store.persistNow()` at `ReaderView.swift:141, 196, 901, 924, 1022`
   and the per-step calls inside `BookImportService`/`MediaOverlayPreparationCoordinator`
   that are followed by another `persistNow()` in the same flow (`:794, 1176, 1222, 1238,
   1298, 1323, 1395`); keep `EPUBPlayerApp` scene-background, `ReaderView.onDisappear`
   (`:740`), import/refresh completion (`:328, 390`), rename/delete (`UploadServerController.swift:491, 509`),
   `ContentView.swift:237`. `AppStateStoreTests.testDebouncedSave` covers the debounce.
5. **B1 dead code** — one commit per the B1 table. Delete `EPUBArchiveTests` cases at
   `:91, :164, :191` and the `defaultBackground` cases in `ReaderSettingsTests`; remove
   `ReadiumAdapterGCDWebServer` from the target's Frameworks and package products in
   `project.pbxproj` (resolve `Package.resolved` on next build). For the write-only
   persisted fields, also drop their `CodingKeys`/decode/encode/init lines in `Book` and the
   three OPF parser branches.
6. **B2 pass-throughs + B4 memberwise inits** — one mechanical commit: delete
   `NormalizedBookStoragePaths`, the 9 `ReaderSettings` colour forwarders (rename 11 call
   sites to `ReadAloudColor.*`), `relativePath(for:root:)`, the four one-line store
   forwarders, `clipIdentity(for:)` / `playbackStartClipKey(for:)` → `.identityKey`, the
   three typealiases, `FontFamilySelectionView`, `applyPlaybackRateIfNeeded`; move
   `PersistedAppState.init(from:)` and `Positions.init(_ book:)`/`apply(to:)` into
   extensions and delete the hand-written memberwise inits.
7. **Docs** — PROJECT_CONTEXT: test counts, `EPUBArchive` description ("reads entries on
   demand", no extraction), remove the GCDWebServer note; fix the
   `build-unsigned-ipa.yml:27` cache-key path to `EPUB Player.xcodeproj/...`; add the
   deferred Medium/Low items and A22 to §7 "Problems and Open Questions".

## Verification

- Build: `xcodebuild -project "EPUB Player.xcodeproj" -scheme "EPUB Player" -destination 'generic/platform=iOS Simulator' build`
- Tests: `xcodebuild test -scheme "EPUB Player" -destination 'platform=iOS Simulator,name=<device>' CODE_SIGNING_ALLOWED=NO`
  (tests redirect storage via `EPUBPLAYER_DOCUMENTS_DIRECTORY`).
- After step 1: on a simulator, drop `Don't Panic.epub` into `Documents/Books` via Files,
  pull-to-refresh, confirm the file is renamed, opens, and shows a cover; refresh again and
  confirm nothing changes.
- After steps 2–4: Instruments Time Profiler while scrolling a chapter with read-aloud on;
  main-thread `FileManager.createDirectory`, `JSONEncoder.encode`, and `FileHandle.write`
  should no longer appear in the scroll path.
- After step 5/6: `git diff --stat` should be net negative with no test edits beyond
  deletions; grep for each removed symbol returns nothing.
- After step 8: `curl -F file=@x.epub` returns 4xx; `curl -H 'Content-Length: 0'` returns 4xx;
  `HEAD /` returns no body.
