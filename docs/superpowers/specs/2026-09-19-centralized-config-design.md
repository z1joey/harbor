# Design: centralized configs — `~/.harbor` as the only source of truth (no `harbor.toml`)

Date: 2026-09-19 · Version: 1.3.0 · Status: draft

## Problem

v1.2 moved the registry and pool into `~/.harbor`, but each project's process
definitions still live in a `harbor.toml` / `.harbor.toml` inside the project
root. That leaves two sources of truth and forces agents (and humans) to write
into project repos:

- The harbor-pilot skill must create a file in the repo before it can register
  (`register_project.py` refuses roots without one).
- The file's life in the repo is awkward: `wordlist-fullstack` commits it
  (machine-specific ports and paths under version control), `steward` keeps it
  untracked (invisible to teammates and to git).
- "Where is this project's config?" has two answers depending on the field.

## Goal

`~/.harbor` holds everything. A project root is just a folder Harbor runs
commands in; Harbor never adds a file to it.

## Decisions

1. **One config file per project under `~/.harbor/projects/`** — e.g.
   `~/.harbor/projects/steward.toml`. Same TOML schema as today's
   `harbor.toml`, plus one new required key:

   ```toml
   root = "/Users/joey/Projects/steward"   # absolute; `~` allowed
   ```

   Filename = sanitized project `name` (fallback: root folder name);
   collisions get `-2`, `-3`, … suffixes. The directory listing **is** the
   registry: `projects.json` is retired as a source (kept as a derived
   mirror during transition, see 6).

2. **Harbor never reads project roots for config.** `HarborConfigParser`
   gains `parse(configAt:root:)`; `locateConfig(in:)` survives only inside
   the one-time migration. A missing root folder at load → same error-banner
   row as today (path shown, nothing crashes).

3. **Directory watcher on `~/.harbor/projects/`** (same pattern as v1.2's
   `~/.harbor` watcher): create/rename/rewrite/delete of a `.toml`
   adds/updates/removes the project live in both frontends. Deleting the
   file **is** unregistering — this restores a removal path after v1.2
   deleted the in-app Remove Project UI, now as
   `unregister_project.py <root>` or deleting the file by hand.

4. **Registration moves fully into the skill's central store.**
   `register_project.py <root>` no longer requires a config in the root; it
   accepts `--config <file>` (or a stdin draft), injects/updates `root`,
   validates (existing validator + cross-project port scan over
   `~/.harbor/projects/*.toml`), and writes the central file atomically
   (tmp + rename). Drafting a `harbor.toml` inside the repo is gone from
   the workflow; `next_pool_port.py` scans the central directory instead of
   walking roots.

5. **One-time migration, both writers, idempotent** (v1.2 pattern):
   `migrateLegacyConfigsIfNeeded()` runs at app/TUI startup and before skill
   registration. For each root in legacy `~/.harbor/projects.json` (and
   legacy App Support copies, if only those exist): if no central TOML
   declares that `root` and the root still contains a `harbor.toml` /
   `.harbor.toml`, copy it into `~/.harbor/projects/` with `root` injected.
   Existing central files win; racing writers make one side a silent no-op.
   Legacy `projects.json` is left on disk untouched.

6. **Transition mirror for older consumers.** The skill (the only writer)
   keeps `~/.harbor/projects.json` in sync (same array-of-roots schema) so a
   v1.2 frontend or older skill script keeps working against a newer store;
   slated for removal in 1.4.

7. **Root `harbor.toml` afterlife: ignored, not deleted.** Harbor never
   deletes user files. A stale root config is invisible to the app; the
   validator flags it ("no longer read — safe to `git rm`") and SKILL.md
   documents the deprecation.

## Why per-project files instead of one big store

A single `configs.json` would need a new schema, new editors, and would
orphan the existing TOML machinery (parser, validator, docs). One TOML per
project keeps every existing tool working on files, stays hand-editable,
and diffs cleanly. The cost is slug uniqueness handling, which is bounded
and testable.

## Trade-off: configs leave the repo

Configs are per-machine anyway (absolute paths, pool ports, local service
layout), but one project legitimately commits its `harbor.toml` today
(wordlist-fullstack). After 1.3 that file stops being read and should be
removed from the repo. If sharing starter configs across machines or a team
ever matters, add an explicit `export`/`import` pair to the skill later —
not silently via the project repo.

## Failure modes

- Bad TOML in a central file → error-banner row, other projects unaffected
  (same as today).
- Two files declaring the same `root` → the second (sorted by filename)
  errors; both stay listed so the conflict is discoverable.
- Missing/invalid `root` → error row explaining the required key.
- Root deleted → error row with the stale path (unchanged behavior).
- Hand edit in place (no rename) may not fire the watcher until window
  focus or a store rewrite; acceptable hand-edit path (same as v1.2).

## Testing

- Parser: `root` required/expanded; parse from explicit path.
- Registry (rewritten): dir-watcher add/update/remove; duplicate-root
  collision; no project-root reads.
- Migration: import/move/win/no-op matrix, incl. legacy App Support and
  `projects.json`-only stores.
- Skill `test_port_pool.py`: registration without a root config, mirror
  sync, central-store port scan.
- `swift test` green; app + TUI compile; after migration the two existing
  projects show up with no root files touched.

## Out of scope

- Multi-machine sync, config sharing/export, per-project pool overrides.
