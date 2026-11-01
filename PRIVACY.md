# Privacy policy — Cue: Pick & Place (for Google Photos)

Short version: the app has no servers, no telemetry, no analytics and no accounts of its own.
Your data flows exclusively between your Mac and Google, inside the Google session you sign in
to yourself.

## What talks to whom

- The embedded system web view signs in to photos.google.com exactly like a browser would; the
  session cookies live in the system web storage of this app, sandboxed on your Mac.
- Every photo operation (listing, album changes, sharing invitations, trash, downloads) is a
  request from your Mac directly to Google's servers inside that session. There is no third
  party, proxy or backend. Email addresses you type to invite someone to an album go only to
  Google as part of that request; the app does not keep them.
- Thumbnails and originals are fetched from Google's media servers with the same session.

## What the app stores locally

- **The web view's site data** in the app's sandboxed web storage: session cookies plus
  whatever the photos.google.com page itself caches (its page cache, local storage and the
  like). Sign Out wipes all of it.
- **The app's own thumbnail cache** in memory only; it does not persist to disk.
- **Your current selection** (photo identifiers and thumbnail URLs) in the app's sandboxed
  Application Support folder, so it survives restarts.
- **View preferences** (sort order, columns, grouping) and a salted hash of the signed-in
  account identifier — used only to detect an account switch and reset local state — in the
  app's preferences.
- Downloads go only to the folder you pick.

## What the app never does

- It never sends anything to anyone other than Google within your own session.
- It never reads your photos from the web page or modifies it; it reads only the page's session
  tokens and browser identification, and talks to the same internal API endpoints the page
  uses, nothing else.
- It never stores your Google password; sign-in happens in the web view, with Google directly.

Error messages (no photo content) can persist in the macOS unified log like any app's errors.
Signing out wipes the web session; deleting the app (and its container under
`~/Library/Containers`) removes everything else.
