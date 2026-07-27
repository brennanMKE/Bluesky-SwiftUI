# CLAUDE.md

## What this repository is

Xcode app target for the Bluesky SwiftUI rewrite. **Always open via `Bluesky.xcworkspace`**, not the `.xcodeproj`.

Related sibling repos:

- `../BlueskyKit/` — Swift package with all library modules (`Package.swift`, `Sources/`, `Tests/`)
- `../Bluesky-Migration/` — planning and tracking documents only (no code); the source of truth for work status, issues, and architecture decisions
- `../Bluesky-ReactNative/` — original React Native app (reference for migration)

## Planning and coordination

All planning docs live in `../Bluesky-Migration/`. Start there when resuming work.

| File | Purpose |
|------|---------|
| `../Bluesky-Migration/Progress.md` | Current phase, active module, up-next checklist, completion log — read this first |
| `../Bluesky-Migration/CHANGELOG.md` | Append-only history of completed work |
| `../Bluesky-Migration/Strategy.md` | 4-phase breakdown, risk register, deferred decisions |
| `../Bluesky-Migration/Migrate-ReactNative-to-SwiftUI.md` | Authoritative per-module checklists and validation gates |
| `../Bluesky-Migration/ModularArchitecture.md` | Layered Swift package design, protocol-first DI, dependency graph |
| `../Bluesky-Migration/ProjectStructure.md` | Four sibling repos, workspace setup, how to add a library module |
| `../Bluesky-Migration/Issues.md` | Index of open bugs and regressions |
| `../Bluesky-Migration/issues/NNNN.md` | Individual issue files |

## Open issues

| # | Title | Module | Status |
|---|-------|--------|--------|
| [0001](../Bluesky-Migration/issues/0001.md) | Account session not persisted across app launches | BlueskyAuth | resolved |
| [0002](../Bluesky-Migration/issues/0002.md) | Home feed posts not loaded after sign-in | BlueskyFeed | open |
| [0235](../Bluesky-Migration/issues/0235.md) | DM conversation list fails to load: `chat.bsky.convo.listConvos` returns `MethodNotImplemented` | BlueskyMessages / BlueskyNetworking | resolved |
| [0242](../Bluesky-Migration/issues/0242.md) | DM compose bar on iPhone has no option to attach an image | BlueskyMessages | open |
| [0243](../Bluesky-Migration/issues/0243.md) | Sending an image in a DM does not work on macOS | BlueskyMessages | open |
| [0244](../Bluesky-Migration/issues/0244.md) | Incoming DMs do not appear until the conversation is reloaded: add getLog polling while messages UI is visible | BlueskyMessages | open |
| [0245](../Bluesky-Migration/issues/0245.md) | macOS top bar: trailing buttons crammed on the right; only the Feeds (`#`) button should remain | Bluesky-SwiftUI | resolved |
| [0246](../Bluesky-Migration/issues/0246.md) | macOS: post button should be a floating button at the bottom right, as in the RN app | Bluesky-SwiftUI | resolved |
| [0247](../Bluesky-Migration/issues/0247.md) | macOS: replace the sidebar with a hamburger-toggled menu drawer, as in the RN app | Bluesky-SwiftUI | resolved |
| [0248](../Bluesky-Migration/issues/0248.md) | macOS Feeds screen shows placeholder "Feed" rows: `#` button routes to the bare SavedFeedsScreen instead of MyFeedsScreen | BlueskyFeed / Bluesky-SwiftUI | resolved |
| [0249](../Bluesky-Migration/issues/0249.md) | Remove dead `SavedFeedsScreen` from BlueskyFeed (unreachable after #0248) | BlueskyFeed | open |

> Issue numbers #0186 and #0193–#0200 were re-homed to #0235 and #0242–#0249 in the 2026-07-26 history merge (Bluesky-Migration `e8503d4`) to resolve a two-machine numbering collision. The `issue/0196`–`issue/0199` branches in this repo, and the `#0186`/`#0196`–`#0200` prefixes on their squash commits, keep their original numbers — each re-homed issue carries a provenance note mapping them.

Keep this table in sync with `../Bluesky-Migration/Issues.md`. File new issues there first, then add a row here.

## Issue workflow

When a bug is spotted: file it in `../Bluesky-Migration/` rather than fixing it immediately (see the workflow in `../Bluesky-Migration/CLAUDE.md`), then add a row to the table above.

Working an issue follows the review-gated branch workflow in `../Bluesky-Migration/Issues.md` (authoritative): code changes go on an `issue/NNNN` branch in this repo and/or `../BlueskyKit/`, implemented by a Sonnet subagent, reviewed by an Opus subagent, with token usage logged per round on the issue. After approval the branch is squash-merged to `main` as one `#NNNN` commit and the branch is kept, not deleted.

When an issue is resolved (review approved): update `Status` in both `../Bluesky-Migration/issues/NNNN.md` and the table above — the table row update rides the issue branch when one exists in this repo. Only the user moves an issue to `closed`.

## Architecture constraints

Strict layer ordering — lower layers never import higher ones:

- **Layer 0 `BlueskyCore`** — plain Swift value types, no actor isolation, no dependencies
- **Layer 1 `BlueskyKit`** — protocols + DI bootstrap; depends on Core
- **Layer 2** (`BlueskyAuth`, `BlueskyDataStore`, `BlueskyUI`, `BlueskyNetworking`) — implementations; depend on Kit + Core
- **Layer 3** (feature modules: `BlueskyFeed`, `BlueskyProfile`, etc.) — depend on Layer 2 as needed

All UI/ViewModel targets use `.defaultIsolation(MainActor.self)`. I/O targets (`AccountStore`, `NetworkClient`, `PreferencesStore`) use explicit actors with `nonisolated` protocol requirements so they satisfy protocols without inheriting `@MainActor`.
