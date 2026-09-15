# Harbor

Native macOS menubar app for developers: **observe** every TCP listener on the
machine (port → PID → command, kill by port) and **manage** project-defined
dev servers (`harbor.toml`) with start/stop/restart, live logs, port-conflict
warnings, health probes, and auto-restart.

SwiftUI + XcodeGen, macOS 13+, menubar-first (`LSUIElement`, no Dock icon by
default), ad-hoc signing, no background daemon — everything runs in-process.

## Build & run

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cd ~/Projects/harbor
xcodegen generate
xcodebuild -project Harbor.xcodeproj -scheme Harbor -configuration Debug build
```

If `xcodebuild` complains about the active developer directory being the
Command Line Tools, either switch permanently (needs sudo):

```bash
sudo xcode-select -s /Applications/Xcode.app
```

or prefix builds with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

After a new Xcode install you may also need to accept the license once:
`sudo xcodebuild -license`.

The built app lands in
`~/Library/Developer/Xcode/DerivedData/Harbor-*/Build/Products/Debug/Harbor.app`.

```bash
open ~/Library/Developer/Xcode/DerivedData/Harbor-*/Build/Products/Debug/Harbor.app
```

You get a ferry icon in the menu bar (no Dock icon). The popover offers
managed projects with status dots, Start/Stop all, a compact listening-ports
list with filter and kill, and "Open Harbor…" for the full main window
(sidebar: **Projects** | **Ports**). "Quit Harbor" stops all managed processes
and exits.

## Registering a project

Each project is a folder containing `harbor.toml` (or `.harbor.toml`). Use
**Add Project…** in the main window toolbar: pick a folder; if it has no
config, Harbor offers to create a template, or to import a draft from a
`Procfile` / `package.json` (which you review before it's written). The list
of registered project roots lives at
`~/Library/Application Support/Harbor/projects.json`; removing a project
unregisters it and deletes nothing on disk. Config files are watched — edits
reload automatically.

### Config schema (`harbor.toml`)

```toml
name = "steward"                 # optional; defaults to the folder name

[[process]]
name = "api"                     # required, unique within the project
command = "uv run uvicorn app.main:app --reload"  # required; run via /bin/zsh -lc
cwd = "backend"                  # optional, relative to project root
port = 8000                      # optional; enables conflict detection + linking
ready_url = "http://127.0.0.1:8000/health"  # optional; "ready" health gate
auto_restart = false             # optional; restart on unexpected exit
env = { "FOO" = "bar" }          # optional env overrides on top of your environment
```

Commands run inside a **login shell** (`/bin/zsh -lc`), so your usual PATH
(homebrew, uv, nvm, …) applies. Invalid TOML shows a readable error in the UI
(with line/column); the project stays registered with a visible error banner
until fixed.

## Ownership & safety rules

- **Manage** (start/stop/restart/logs): only processes Harbor itself spawned,
  tracked per (project, process name).
- **Observe / kill by port**: any listener owned by your user. Killing a PID
  Harbor doesn't manage requires an explicit confirmation dialog; killing
  another user's process fails with a readable error.
- **Stop sequence**: SIGTERM to the whole descendant tree → wait ~2s →
  SIGKILL survivors. Harbor enumerates children via the kernel process table,
  so shells spawning children (npm → node, etc.) are fully cleaned up. On
  quit, all managed trees are stopped the same way.
- Declared `port` already held by a foreign PID → Harbor warns and requires
  confirmation before starting (individually or via Start all).
- Port snapshots come from `lsof -nP -iTCP -sTCP:LISTEN`, polled every ~2s on
  a background queue. Without elevated privileges lsof only shows your own
  listeners — that's an OS constraint, not a bug.

## Fixtures

- `fixtures/sample-harbor.toml` — schema example.
- `fixtures/selftest-project/` — register this folder to exercise everything:
  `logger` streams a line/second into its log pane, `server` is a python
  http.server on port 8123 with a `ready_url`, and `cwd-check` proves working
  directories by writing `pwd` into `sub/harbor-cwd.txt`.

## Development notes

- Layout: `App/Models`, `App/Services` (no SwiftUI), `App/ViewModels`,
  `App/Views` (popover, main window, ports, projects, logs, sheets).
- TOML parsing uses [TOMLKit](https://github.com/LebJe/TOMLKit) (SPM).
- Logs are in-memory ring buffers (~2000 lines per process).
- Manual acceptance checklists: [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)
  (service-level behavior is additionally covered by compiled harnesses; see
  that file for how it was verified and what remains a manual UI check).

## Out of scope for v1

Docker/compose control, remote/SSH hosts, Windows/Linux, editor extensions,
libproc-based port scanning, cloud sync/telemetry.
