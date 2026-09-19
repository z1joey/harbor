# Design: `~/.harbor` home + skill-side registration

Date: 2026-09-18 · Version: 1.2.0 · Status: implemented

## Problem

Registration required the app: the harbor-pilot skill could only write
`harbor.toml` and then tell the user to click **Add Project…**. The project
list and pool lived in `~/Library/Application Support/Harbor/`, a location
agents don't naturally look at, and the app owned a 4-step add wizard
(folder picker, template creation, Procfile/package.json import, overlap
review) that duplicated what the skill already does better.

## Decisions

1. **One global hidden folder `~/.harbor`** holds the Port Allocation
   Convention: `projects.json` (JSON array of absolute project roots) and
   `port-pool.json` (`{ "ranges": [...] }`). Same schemas as before — only
   the location changes. Pool "leases" stay **derived** from each project's
   `harbor.toml` (`[[process]].port` inside the pool); no new persisted
   lease state exists.
2. **The app never registers projects.** The harbor-pilot skill writes
   `harbor.toml`, then appends the root to `~/.harbor/projects.json`
   (atomic tmp+rename). Both frontends read and watch that file; a running
   frontend shows a new project within ~1s, a cold one at next launch.
3. **All in-app registration UI is removed**: Add Project menu/sheet,
   template creation, Procfile/package.json importers, pre-add overlap
   review, Remove Project, TUI `:add`/`:remove`. Config drafting is
   exclusively the skill's job.
4. **One-time migration** moves legacy App Support stores into `~/.harbor`
   (existing `~/.harbor` files win; racing frontends make one side a silent
   no-op). The skill performs the same migration on first registration, so
   order of first-run doesn't matter.

## Why a directory watcher

Both stores previously opened a DispatchSource on the store *file*, with a
comment "re-armed on first write" — the app was the only writer, so the file
always existed by the time watching mattered. With the skill as writer:

- `~/.harbor/projects.json` may not exist when the app starts (fresh
  install; the app never creates it), so a file watcher can't even arm.
- The skill replaces the file via atomic rename; watching the inode would
  miss it.

Both stores now watch the **directory** (`~/.harbor`), which catches file
creation and rename-replacement. Spurious events (the other store changing)
are absorbed by the existing load-diff guards. Verified by
`ProjectRegistryTests.testWatcherPicksUpSkillStoreRewrite`.

## App changes

- `HarborCore/Services/HarborStoreLocation.swift` (new): canonical URLs +
  `migrateLegacyStoresIfNeeded()` (injectable for tests). Called at startup
  by `AppState` and `TuiApp`.
- `ProjectRegistry`: read-only — `add`/`remove`/`createTemplate`/store
  writes/flock deleted; `load()` never writes back (normalization is
  in-memory). Per-config watchers unchanged.
- `PortPoolStore`: same path move; keeps flock + `save` (the GUI **Edit
  pool…** sheet stays the one app-side writer); directory watcher.
- Deleted: `ConfigImporter`, `HarborConfigParser.templateText`,
  `HarborCoordinator.suggestedFreePorts`, both `PortPlanner.suggestFreePorts`
  variants (no remaining callers; `allocatePort`/`nextFreePoolPort` stay).
- GUI: `AddProjectSheet` / `ImportDraftEditor` / `HarborCommands` deleted;
  sidebar/popover empty states point at the skill; project-detail config
  banner keeps its error text, drops the template/import buttons.
- TUI: `:add`/`:remove` removed; `:` bar keeps `refresh`/`q`.

## Skill contract (github.com/z1joey/harbor-pilot)

- Reads `~/.harbor/port-pool.json` + `~/.harbor/projects.json`; falls back
  to the legacy App Support paths while only those exist; performs the same
  migration before first registration.
- New `register_project.py <root>` (wraps `harbor_pool.register_project`):
  validates a config exists, rejects relative/`..` paths, normalizes
  entries, idempotent atomic append.
- SKILL.md/README updated: workflow ends with registration (no "Add
  Project"), stale `port = "auto"` prose fixed.

## Failure modes

- Skill appends a root without a config → project lists with a visible
  error banner (same as invalid TOML today); SKILL.md mandates
  config-before-register.
- Hand edit in place (no rename) may not fire the directory watcher until
  window focus (`reloadAll` on window-key) or a store rewrite; acceptable
  for a hand-edit path.

## Testing

- `HarborStoreLocationTests` — migration moves/wins/no-op, default URLs.
- `ProjectRegistryTests` (rewritten) — read-only load, no rewrite, watcher
  picks up atomic skill rewrite, broken/missing configs list with errors.
- Skill `test_port_pool.py` — 28 checks incl. registration, fallback,
  migration, CLI.
- `swift test` 98/98 green; app `xcodebuild` Debug green.
