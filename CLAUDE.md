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

Keep this table in sync with `../Bluesky-Migration/Issues.md`. File new issues there first, then add a row here.

## Issue workflow

When a bug is spotted: file it in `../Bluesky-Migration/` rather than fixing it immediately (see the workflow in `../Bluesky-Migration/CLAUDE.md`), then add a row to the table above.

When an issue is fixed: update `Status` in both `../Bluesky-Migration/issues/NNNN.md` and the table above.

## Architecture constraints

Strict layer ordering — lower layers never import higher ones:

- **Layer 0 `BlueskyCore`** — plain Swift value types, no actor isolation, no dependencies
- **Layer 1 `BlueskyKit`** — protocols + DI bootstrap; depends on Core
- **Layer 2** (`BlueskyAuth`, `BlueskyDataStore`, `BlueskyUI`, `BlueskyNetworking`) — implementations; depend on Kit + Core
- **Layer 3** (feature modules: `BlueskyFeed`, `BlueskyProfile`, etc.) — depend on Layer 2 as needed

All UI/ViewModel targets use `.defaultIsolation(MainActor.self)`. I/O targets (`AccountStore`, `NetworkClient`, `PreferencesStore`) use explicit actors with `nonisolated` protocol requirements so they satisfy protocols without inheriting `@MainActor`.
