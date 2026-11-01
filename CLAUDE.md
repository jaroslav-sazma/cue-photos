# Cue: Pick & Place (for Google Photos) — instructions for AI executors

"Cue: Pick & Place (for Google Photos)", short form "Cue Photos": a native macOS app for working
with the user's own Google Photos library — sorting backlogs into albums and picking photos
across albums for download (photo books). It drives the internal photos.google.com web API
through a hidden WebKit `WebPage` whose session the user logs into themselves; the bridge runs in
a private `WKContentWorld` and the API layer is vendored from the MIT-licensed GPTK project as a
pinned git submodule. The app is App Sandboxed. SwiftUI, bundle id
`app.cue.photos`, GPL-3.0-or-later; Debug builds are `app.cue.photos.debug`. Part of the owner's
Cue: family of apps (sibling: "Cue: Relay & Reply" at `../Bridge`).
`CONTRIBUTING.md` carries the architecture and the contributor workflows — read it first;
`README.md` is the user documentation, `PRIVACY.md` the privacy policy. Keep all three true
after every change that touches what they describe.

## Naming
- The `.app` file name never contains a colon, which Finder cannot show: the product is
  `Cue Photos.app`; "Cue: Pick & Place" lives only in `CFBundleDisplayName`.
- Prose names the product in full ("Cue: Pick & Place") or by the short form "Cue Photos"; a bare
  "Cue:" stays only where it quotes what a screen shows.
- The Swift module is `CuePhotos` (never `Photos` — that collides with Apple's Photos framework);
  targets and source folders are `Photos` / `PhotosModel` / `PhotosTests`.
- The JS bridge global is `window.cuePhotos`; the progress message handler is `cuePhotosLog`.

## Hard rules
- macOS 27 is the deployment target and Apple silicon the only architecture (`ARCHS = arm64`). No
  legacy fallbacks, no availability checks below the floor. Use the newest available APIs.
- Design is current-generation native Apple: SwiftUI with the Liquid Glass material system. The
  app must speak the same design language as macOS itself. No custom lookalike controls where a
  system control exists.
- Privacy is absolute: no telemetry, no analytics, no data collection of any kind. Data flows only
  between the user's Mac and Google's servers inside the user's own session. Nothing else, ever.
- No background activity: every flow starts from a user action. The single exception is a running
  download/task the user started, which may hold a sleep assertion while it runs and must release
  it the moment it finishes or fails.
- Third-party code is exactly one thing: the GPTK submodule at `third_party/gptk`, pinned to a
  release tag, consumed only through `webbridge/` (its raw `src/api/api.ts` client; never its
  `src/ui`, `gptk-core.ts` or the error-swallowing `api-utils.ts` bulk helpers — the webbridge
  build fails if they resolve). Every bridge call is a single RPC; paging, chunking, cancellation
  and progress live on the Swift side. No
  other dependencies — system frameworks only on the Swift side; the Node toolchain in `webbridge/`
  is dev-only and never ships.
- A few RPCs are not covered by gptk (album rename, rpcid `SVP9Xd`; shared-album rename,
  rpcid `uF3Orb`; share album with invites, rpcid `SFKp8c`). They live ONLY in
  `webbridge/src/bridge.ts`, built on gptk's raw `api.makeApiRequest`, each with a comment
  citing the devtools capture (owner, date, payload shape) that sourced the rpcid. When such a
  call misbehaves, debug it there — not in `third_party/gptk`. Two calls bypass makeApiRequest
  via a single-shot request builder in bridge.ts, because the server answers error 8 unless the
  request carries its page context (source-path, hl locale, soc parameters, no pageId) which
  gptk's client cannot set: shared-album item removal (`LjmOue`, /share context) and
  share-with-invites (`SFKp8c`, /album context — also single-shot so gptk's internal retries
  cannot mail duplicate invitations).
- `Photos/Resources/WebBridge.js` is a generated, committed artifact. Never edit it by hand:
  change `webbridge/src/*` and run `tools/build-webbridge.sh`. GPTK updates go through
  `tools/update-gptk.sh` (checkout release tag → rebuild → typecheck → review diff → commit bump
  and bundle together).
- The native UI never scrapes or overlays Google's DOM. All data crosses the bridge as JSON.
- Logging goes through `os.Logger`, subsystem `app.cue.photos`. Media metadata (filenames, album
  names) is `privacy: .private` by default and never logged above debug.
- Comments are kept to a minimum: only workarounds, traps and non-obvious contracts. No
  descriptive doc comments.
- A change to the bridge protocol, the session/login handling, or a hard-to-reverse architectural
  choice is not decided alone: stop and ask the owner.

## Language
Everything is in English, with no exception: code, identifiers, comments, UI text, commit
messages, docs, test names and assertion messages. (Conversation with the owner is Czech; the
repository is English.)

## Build
```bash
xcodebuild -scheme Photos -configuration Debug -derivedDataPath build build
xcodebuild -scheme Photos -configuration Debug -derivedDataPath build test
tools/build-webbridge.sh   # regenerate Photos/Resources/WebBridge.js (Node 24+)
```
DerivedData stays in `build/` inside the repo. Inside the sandbox xcrun prints `couldn't create
cache file` warnings; they are harmless, `** BUILD SUCCEEDED **` decides — but xcodebuild also
needs write access to the user temp under `/var/folders`, which the default sandbox denies
(`sandbox.filesystem.allowWrite` in the Claude Code settings fixes it; otherwise builds need the
sandbox bypass). `Photos/`, `PhotosModel/` and `PhotosTests/` are file-system-synchronized
groups: adding a file needs no `project.pbxproj` edit, a new target does. `PhotosModel/` compiles
into both the app and the tests. `PhotosTests` (Swift Testing) runs without the app as host and
never touches the network or the webview. Launching the built app goes through Launch Services,
which the sandbox blocks — hand the `open` command to the owner instead.

Debug builds are signed ad hoc (`app.cue.photos.debug`); nothing in Debug claims entitlements
that need a provisioning profile. A build for anyone else comes only from `tools/release.sh`,
run by the owner in Terminal: it needs the owner's Developer ID certificate and notary
credentials, so an agent never runs it. `MARKETING_VERSION` is the version,
`CURRENT_PROJECT_VERSION` the build number; every published build gets a new build number.

Commits: Conventional Commits, in English, ending with the trailer
`Co-Authored-By: Claude <noreply@anthropic.com>` — no model name. The project will be public on
GitHub, so every commit goes into public history. Push only when the owner asks.

## Docs
`README.md` is the user documentation, written for someone using the app, with the labels the
app shows. `CONTRIBUTING.md` is the contributor documentation: architecture, building, tests,
the Toolkit submodule workflow, the beyond-gptk RPC policy and the release process.
`PRIVACY.md` is the privacy policy. **Every change ends with a review of these three**: a
behaviour change is not finished until README matches it, a change to building, testing,
architecture or workflows not until CONTRIBUTING does, and a change to what is stored or sent
not until PRIVACY does. Prose in every `.md` file is hard-wrapped at 100 characters; tables,
fenced blocks and ASCII diagrams stay on one line however long they get. What a change needs
checked on real hardware (login flows, Google-side behaviour) goes into the handover to the
owner, never into a new file.
