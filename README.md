# NODELOC for iOS

A native SwiftUI client for [nodeloc.com](https://www.nodeloc.com), talking to
the NodeLoc backend's `/api/v1`. Feed, threaded reading, composing, live chat, private messages, search,
notifications and profiles — all drawn natively rather than wrapped around a
web view.

91 Swift files, ~57k lines, **no third-party dependencies**.

---

## Requirements

| | |
|---|---|
| Xcode | 26.x (project was created on 26.6) |
| Swift language mode | 5, with `-default-isolation=MainActor` |
| Minimum iOS | 18.6 |
| Dependencies | none — no SPM packages, no CocoaPods |

## Building

```sh
git clone https://github.com/nodeloc/nodeloc_ios.git
cd nodeloc_ios
open nodeloc.xcodeproj
```

Then **change the signing team**. The project has Nodeloc LLC's team baked in,
so a fresh clone fails to sign:

1. Select the `nodeloc` target → *Signing & Capabilities*
2. Set *Team* to your own
3. Change the bundle identifier from `com.nodeloc.app` to something you own

Sign in with Apple and Universal Links are declared in
`nodeloc/nodeloc.entitlements` and are tied to that team and domain. Both need
your own configuration, or removing, before they will work elsewhere.

### Optional: the GIF picker

The GIF search uses [Klipy](https://klipy.com). Without a key the GIF button
is disabled, so this is not required to build or run. To enable it, create
`nodeloc/Secrets.plist` (gitignored):

```xml
<plist version="1.0">
<dict>
    <key>KlipyAPIKey</key>
    <string>your-key</string>
</dict>
</plist>
```

The app folder is a *filesystem-synchronized group*, so Xcode picks new files
up on its own — you never edit `project.pbxproj` to add a source file.

---

## Backend

Since 2.0 the app talks to the NodeLoc backend (`/api/v1`, bearer-token or
session-cookie auth, server-sent events for live updates) instead of
Discourse. The screens were not rewritten for it:

- `nodeloc/Core/Kit/` is the data layer, Foundation-only. `NodelocHTTP` is the
  transport, `NodelocDTO` the wire types, and `DiscourseClient`
  (`DiscourseAPI.swift`) keeps the method names and model types the screens
  already used, shaping each answer through `DiscourseShape` so it decodes
  with the existing models in `DiscourseModels.swift`.
- `NodelocMarkup` rewrites the backend's post HTML into the vocabulary
  `PostHTMLParser` reads (polls, spoilers, login-gated blocks, videos, node
  and tag references).
- `ChatRealtime.swift` serves the old MessageBus subscriptions from the event
  stream (`/api/v1/notifications/stream`).
- `NodelocFeatures` lists what the backend doesn't have (chat reactions,
  edits, pins, threads and search; topic-style private messages; the posting
  device line); their entry points are hidden.

`DEBUG` builds read `NODELOC_BASE_URL` from the scheme's environment to point
at a local backend.

### Testing without Xcode

`NodelocKit/` is a SwiftPM package that compiles `nodeloc/Core/Kit` (through a
symlink) plus the post HTML parser, so the data layer builds and tests on
macOS or Linux:

```sh
swift test --package-path NodelocKit
# also run the end-to-end tests against a throwaway backend with seed data
NODELOC_IT_BASE_URL=http://127.0.0.1:8180 swift test --package-path NodelocKit
```

`.github/workflows/build.yml` runs those tests and an unsigned simulator build.

---

## Architecture notes

Written down because they are decisions rather than conventions, and each has
a cost that isn't obvious from the code.

**One decoding path.** Everything the server sends is decoded exactly once, by
`Codable` models, and cached copies are stored as *the server's own bytes* so
they re-decode through the same models. `Codable` is all-or-nothing, and this
project has twice lost a whole screen to one field of the wrong type — so a
second path that could drift from the first is treated as a real hazard, not a
tidiness question. `ProfileSnapshot`, `ChatStorage` and `EmojiDiskCache` all
follow it.

**SQLite for chat, nothing else.** `Core/SQLiteDatabase.swift` is a small
hand-written layer (system SQLite, no GRDB, no SwiftData) used only by
`ChatStorage` for message history and a durable send queue. Everywhere else,
persistence is UserDefaults, the Keychain, or a JSON file — because a blob
replaced whole is not a database problem. Chat is, because it needs paging and
an outbox that survives being killed. Schema changes rebuild rather than
migrate: the rows are a cache of the server, so a version bump refetches and
only the outbox is preserved.

**iOS 26 features, with a floor at 18.** The interface is built on Liquid
Glass, which is iOS 26. `Components/GlassCompat.swift` and
`Features/Compose/ComposerCompat.swift` are the only places allowed to name
26-only API; everything else goes through them. Below 26 the chrome falls back
to system materials and the composer's formatting buttons write markdown
tokens instead of styling live.

**`app.overlay` draws inside `MainView`.** So anything opened from a screen
that is itself inside a `fullScreenCover` must be presented locally, or it
renders *underneath* the cover and looks like nothing happened. This has
caused the same bug three times (composer, search, node search); the pattern to
copy is `isComposing` in `NodeDetailOverlay`.

**Hit-testing follows what a view draws.** A `.background` is not hit-testable,
so a custom button or field needs `.contentShape`. Several controls looked
tappable across their whole surface while only the text responded.

---

## Localization

Strings live in `nodeloc/Localizable.xcstrings` (1088 entries, English source,
Simplified Chinese translated). Outside SwiftUI views, use
`AppString("…")` — it takes a `String.LocalizationValue`, so Xcode extracts it.
A literal passed to a plain `String` parameter never reaches the catalogue,
which is the usual reason something appears untranslated.

## Licence

MIT — see `LICENSE`. Icon sets and brand marks are **not** all covered by it;
`NOTICE.md` lists the exceptions and their attribution requirements.
