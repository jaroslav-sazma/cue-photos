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
  album-membership index (the "Not in album" filter) in memory, generation-guarded against
  stale tasks, with `revision` counters driving UI updates. The membership index keeps
  per-album key sets, so confirmed writes (add, trash, remove from album) update it in place;
  the full network rebuild runs only at bootstrap, on a library/selection refresh and after a
  restore from trash, whose album destinations Google does not report.
- **SelectionStore** (`PhotosModel/SelectionStore.swift`) is the core contract: the cross-album
  selection, keyed by `dedupKey` (stable across albums; album pages return album-scoped
  `mediaKey`s for the same photo), persisted to Application Support with serialized atomic
  writes and a synchronous flush on quit. It empties only through fully successful bulk actions
  (chunk by chunk, as chunks confirm) or an explicit, undoable clear.
- **Album labels** (`PhotosModel/AlbumLabels.swift`) are local only: an emoji plus a name in
  `labels.json` next to the selection. Google knows nothing about them — an album "has" a label
  when its title starts with that emoji (compared without U+FE0F), so a label survives anywhere
  the title does, and the album list filters on the title alone.
- **PhotoGridView** (`Photos/PhotoGridView.swift`) wraps `NSCollectionView`: diffable
  snapshots, recycled layer-backed cells, pinned section headers, native prefetch wired to the
  `ThumbnailLoader` actor (authenticated fetches through `GoogleSession`, ImageIO downsampling
  off the main thread, cost-limited `NSCache`).
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
  session. Media metadata is `privacy: .private` in logs and never logged above debug.
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
