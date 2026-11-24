# Contributing to Cue: Pick & Place

Thanks for looking under the hood. This file is the contributor documentation: how the app is
put together, how to build and test it, and the rules that keep it safe to change. User-facing
documentation lives in `README.md`, the privacy picture in `PRIVACY.md`.

## Architecture in five minutes

```
┌─ SwiftUI window (fully native, Liquid Glass design) ────────┐
│  NSCollectionView photo grid    │  sidebar, bars, sheets    │
└───────────────▲─────────────────┴──────────▲────────────────┘
                │ Codable DTOs via PhotosService (async)      │
        WebRuntime: hidden WebKit WebPage @ photos.google.com
                │ callJavaScript ⇄ window.cuePhotos.* in a   │
                │ private WKContentWorld ("cuePhotos")        │
        WebBridge.js = Toolkit's raw api client (+ thin bridge, esbuild)
```

- **WebRuntime** (`Photos/WebRuntime.swift`) owns the hidden `WebPage`. The user signs in to
  Google in it like in a browser; a session exists when the page global `WIZ_global_data`
  carries the `SNlM0e` RPC token. The bridge bundle is then injected into a private content
  world (page scripts cannot see or touch it) with `WIZ_global_data` seeded across. The web
  view stays mounted at 0.02 alpha behind an opaque shield — a fully transparent page gets its
  DOM timers throttled by WebKit, which once stalled RPC retries forever.
- **The bridge** (`webbridge/src/bridge.ts`) exposes raw page-wise calls only; every call is a
  single RPC returning a JSON envelope `{ok, value}` / `{ok:false, error, stack, diag}`.
  Paging, chunking, cancellation and progress all live on the Swift side. Every RPC
  races a 60-second timeout; idempotent calls get one silent retry (a timed-out `createAlbum`
  does not — it may have landed, and a retry could duplicate the album). The Toolkit's client
  additionally retries each request up to three times internally; the bridge-built `LjmOue`
  and `SFKp8c` requests send exactly once.
- **PhotosService** (`Photos/PhotosService.swift`) is the typed Swift face of the bridge. All
  traffic flows through a 3-slot `RPCLimiter`. Bulk writes go in 250-item chunks and report the
  exact dedupKeys that succeeded and failed — never bare counts.
- **Stores** (`Photos/Stores.swift`) hold the library timeline, album contents, trash and the
  album-membership index (the "Not in album" filter) in memory (about 500 B per photo, so 300k
  photos take ~150 MB), generation-guarded against stale tasks, with `revision` counters driving UI
  updates. Library and album stores also keep an `epoch` that bumps on every change other than
  growth at the end; an unchanged epoch is what lets the grid extend instead of rebuilding.
  Progressive loads show the first page at once and then publish at most once a second
  (`PublishThrottle`), because every publish copies the growing list on the main actor; a page held
  back that way is still published once the interval passes, so a slow next RPC never hides it. The
  membership index keeps per-album key sets, so confirmed writes (add, trash, remove from album)
  update it in place; the full network rebuild runs only at bootstrap, on a library/selection
  refresh and after a restore from trash, whose album destinations Google does not report. The
  album list sorts locally: Google's list carries each album's photo date range
  (`timestampRange`), so "Most recent photo" costs no extra RPC, and `AlbumsStore` caches each
  sorted order until the next revision, so a sidebar redraw only filters.
- **SelectionStore** (`PhotosModel/SelectionStore.swift`) is the core contract: the cross-album
  selection, keyed by `dedupKey` (stable across albums; album pages return album-scoped
  `mediaKey`s for the same photo), persisted to Application Support with serialized atomic
  writes and a synchronous flush on quit. It empties only through fully successful bulk actions
  (chunk by chunk, as chunks confirm) or an explicit, undoable clear.
- **Album labels** (`PhotosModel/AlbumLabels.swift`) are local only: an emoji plus a name in
  `labels.json` next to the selection. Google knows nothing about them — an album "has" a label
  when its title starts with that emoji (compared without U+FE0F), so a label survives anywhere
  the title does, and the album list filters on the title alone.
- **PhotoGrid** (`PhotosModel/PhotoGrid.swift`) is what a grid shows: positions into the source list
  in display order, cut into day or month sections, sharing the source array instead of copying
  items. `PhotoGridBuilder` builds it off the main actor (about 30 ms for 300k photos) and extends
  it by a streamed page without re-sorting what is already shown when the page sorts after
  everything shown — the newest-first timeline always does. Anything else (oldest first, an
  out-of-order page) falls back to a full build; a test checks that both paths give the same grid.
- **PhotoGridView** (`Photos/PhotoGridView.swift`) wraps `NSCollectionView` with a classic data
  source over the `PhotoGrid` and its own `PhotoGridLayout`: square cells and pinned section
  headers, with the frame math in `PhotosModel/PhotoGridGeometry.swift` (prefix sums over the
  section counts, so a rect query is a binary search; unit-tested). Diffable snapshots and the
  compositional layout were dropped after measuring 9 s per snapshot and ~0.2 s per layout pass at
  270k photos; the replacement stays in single milliseconds. A grown grid (same `buildID`) is
  applied as a tail insert that leaves visible cells and headers alone, anything else as a
  `reloadData`. Cells are recycled and layer-backed, prefetch is native, and selection changes touch
  only the cells AppKit has instantiated. The `ThumbnailLoader` actor does authenticated fetches
  through `GoogleSession`, ImageIO downsampling off the main thread and keeps a cost-limited
  `NSCache` that cells read synchronously, so a reload never blanks a photo that is already loaded.
- **The map** (`Photos/PhotoMapView.swift`) is a modal over the window like the lightbox, wrapping
  `MKMapView` because SwiftUI's `Map` cannot cluster annotations. Coordinates come from the
  Toolkit's `geoLocation` on library timeline items (integer degrees × 10⁷, latitude first).
  Album and trash pages carry none, so album and selection photos borrow the library's location
  by `dedupKey`; the trash has no map. The location rides on every photo in the wire format
  (two `Int32`, +8 B per photo). `PhotoMapBuilder` (`PhotosModel/PhotoMap.swift`, unit-tested)
  builds seven levels of detail off the main actor (~90 ms for 300k photos): photos merge into
  cells of 0.01° (~1 km) and each further level merges four times coarser cells. Nodes hold grid
  positions, never photo copies. On every region change the map hands MapKit only the level
  whose cells are at least a pin wide, around the visible region — at most a few hundred
  annotations on screen whatever the library size, since MapKit creates a view per visible
  annotation; MapKit's clustering only resolves the pins that still collide. Pins are system
  markers carrying the photo count, never thumbnails: a photo would hide the place it marks.
  Rotation and pitch are off: a rotated map's `visibleMapRect` is a bounding box that both the
  level choice and the zoom-or-open decision on a group click would misread. The map's state
  lives in a view keyed per opening and goes away on close.
- **Downloads** (`Photos/DownloadManager.swift`) stream `=d`/`=dv` originals through the
  cookie-bridged session into a security-scoped folder, hold a sleep assertion for exactly the
  run, and release each photo from the selection as its file lands.

## The Toolkit submodule

`third_party/gptk` is [Google Photos Toolkit](https://github.com/xob0t/Google-Photos-Toolkit)
(MIT), pinned to a release tag, consumed only through `webbridge/` and only its raw
`src/api/api.ts` client — never its UI, `gptk-core.ts`, or the `api-utils.ts` bulk helpers
(they swallow chunk errors; the webbridge build fails if they ever resolve).

- Regenerate the committed bundle after changing `webbridge/src/*`:
  `tools/build-webbridge.sh` (Node 24+). Never edit `Photos/Resources/WebBridge.js` by hand.
- Update the Toolkit: `tools/update-gptk.sh [tag]` → review the `WebBridge.js` diff → run the
  app → commit the submodule bump and the bundle together.
- A few RPCs are **not** covered by the Toolkit (album rename, rpcid `SVP9Xd`; shared-album
  rename, rpcid `uF3Orb`; share album with invites, rpcid `SFKp8c`). They live only
  in `webbridge/src/bridge.ts` on top of the raw `api.makeApiRequest`, each with a comment
  citing the devtools capture (who, when, payload shape) that sourced the rpcid. When such a
  call misbehaves, debug it there — not in `third_party/gptk`. Two calls go further and use a
  single-shot batchexecute builder in `bridge.ts`, because the server answers error 8 unless the
  request carries its originating page context (the `source-path`, `hl` locale and `soc`
  parameters, and no `pageId`), which the Toolkit's client cannot express: removing items from a
  shared album (`LjmOue`, `/share` context) and sharing with invitations (`SFKp8c`, `/album`
  context — also single-shot, so the Toolkit's internal retries cannot mail duplicate invites).

## Building and testing

```bash
git clone --recurse-submodules https://github.com/jaroslav-sazma/cue-photos.git
cd cue-photos
xcodebuild -scheme Photos -configuration Debug -derivedDataPath build build
xcodebuild -scheme Photos -configuration Debug -derivedDataPath build test
```

Xcode 27+, macOS 27+, Apple silicon only — no availability checks below that floor. The source
folders `Photos/`, `PhotosModel/` and `PhotosTests/` are file-system-synchronized groups:
adding a file needs no project edit. `PhotosModel/` compiles into both the app and the tests;
`PhotosTests` (Swift Testing) runs without the app as host and never touches the network or the
web view. Debug builds sign ad hoc as `app.cue.photos.debug`.

Diagnostics: errors and index-build milestones persist in the unified log
(`/usr/bin/log show --predicate 'subsystem == "app.cue.photos"'`); per-RPC breadcrumbs are
`.info` (in-memory only, add `--info --last 15m` right after a problem). In Debug builds the
hidden page is inspectable from Safari's Develop menu.

## Rules that are not negotiable

- Privacy: no telemetry, no analytics, nothing leaves the user's Mac except their own Google
  session. The single exception is the map tiles MapKit loads from Apple while the map is open;
  they reveal the area on screen, which follows the photos, but photo coordinates themselves
  never leave the Mac. Media metadata is `privacy: .private` in logs and never logged above
  debug.
- No background activity beyond a user-started task; a running download may hold a sleep
  assertion and must release it when it ends.
- The native UI never scrapes or overlays Google's DOM; everything crosses the bridge as JSON.
- System frameworks only on the Swift side; the Node toolchain in `webbridge/` is dev-only.
- UI strings are localizable (English base + Czech) via `Photos/Localizable.xcstrings`; counts
  use plural variations.

## Release (maintainer only)

`tools/release.sh` builds a Release configuration signed with a Developer ID Application
certificate, notarizes and staples the app (`notarytool` keychain profile, default name
`cue-photos-notary`), packs it with LICENSE and NOTICE into a disk image, signs, notarizes and
staples that too, and writes `Cue-Photos-<version>.dmg` plus a `.sha256` checksum under
`build/release/<version>-<build>/`. It needs the maintainer's certificate and notary
credentials, so only the maintainer runs it.
Versioning: `MARKETING_VERSION` (semver) and `CURRENT_PROJECT_VERSION` (monotonic build
number), set in the Xcode project; every published build gets a new build number.

## Commits

Conventional Commits, in English. The repository is public; every commit goes into public
history.
