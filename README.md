# Harbor

Native macOS dev-tool companion: **observe** every TCP listener on the machine
(port → PID → command, kill by port) and **manage** project-defined dev
servers with start/stop/restart, live logs, port-conflict warnings, health
probes, and auto-restart. Ships in two forms that share one core: a SwiftUI
menubar app and a terminal UI (`harbor-tui`).

State lives in a hidden `~/.harbor` folder — the single source of truth
(since **1.3.0**): one config TOML per project under `~/.harbor/projects/`
(the directory listing IS the registry), plus the port pool — together the
Port Allocation Convention. The companion **harbor-pilot** skill owns
registration: it drafts the config and installs it into the central store;
both frontends only read (and watch) those files, so registration works
whether or not Harbor is running. Harbor never reads project roots for
config — a project folder is just where the commands run.

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
managed projects with status dots, Start/Stop all, a **Keep Awake** switch
that blocks idle sleep so long tasks can run to completion (released when
Harbor quits), a compact listening-ports
list with kill, and "Open Harbor…" for the full main window (sidebar:
**Projects** | **Port Convention** | **Listening Ports** — filter lives here).
"Quit Harbor" stops all managed processes and exits.

## Registering a project

Harbor has no "Add Project" flow. Each project is one config TOML in the
central store, drafted and **registered by the harbor-pilot skill**: it
discovers the dev commands, plans ports against the pool and your other
projects, then installs the config as `~/.harbor/projects/<name>.toml`
(`register_project.py <root> --config <draft>`, atomic and idempotent).
Every central config declares `root = "/absolute/path"` — the folder Harbor
runs the commands in. Both frontends watch the central directory — a
registered project appears within ~1s while Harbor runs, or at next launch.

```
~/.harbor/projects/*.toml  # one config per project; the listing IS the registry
~/.harbor/projects.json    # derived mirror of roots for pre-1.3 consumers
~/.harbor/port-pool.json   # { "ranges": [{ "from": 8100, "to": 8199 }] }
```

Unregistering = deleting the central config file (by hand or via
`unregister_project.py`); nothing inside the project root is ever touched.
Config files are watched — edits reload automatically. First launch migrates
older state into the central store: pre-1.2 stores from
`~/Library/Application Support/Harbor/`, and pre-1.3 registrations by
importing each registered root's `harbor.toml` (existing central files win;
the root files are then ignored and safe to `git rm`).

### Config schema (`~/.harbor/projects/<name>.toml`)

```toml
root = "/Users/joey/Projects/steward"  # required; the folder commands run in
name = "steward"                       # optional; defaults to the root folder name

[[process]]
name = "api"                     # required, unique within the project
command = "uv run uvicorn app.main:app --reload"  # required; run via /bin/zsh -lc
cwd = "backend"                  # optional, relative to project root
port = 8000                      # optional integer 1–65535; Harbor injects $PORT
ready_url = "http://127.0.0.1:8000/health"  # optional; "ready" health gate; ${port} ok
auto_restart = false             # optional; restart on unexpected exit
env = { "FOO" = "bar" }          # optional env overrides on top of your environment

[[port_claim]]
port = 5432                      # port the project relies on (database, broker, …)
note = "postgres"                # optional, shown in the ports overview
process = "api"                  # optional, must match a [[process]] name above
```

Commands run inside a **login shell** (`/bin/zsh -lc`), so your usual PATH
(homebrew, uv, nvm, …) applies. Invalid TOML shows a readable error in the UI
(with line/column); the project stays registered with a visible error banner
until fixed.

### Port pool and sticky `$PORT`

Harbor no longer assigns a new port at every start. Declare `port = N` (an
integer 1–65535). At start Harbor injects that number as the `PORT` environment
variable (override the name with `port_env`) so commands can keep using `$PORT`.
`${port}` in `ready_url` is substituted with `N`.

The **port pool** is an app setting — which ports Harbor may hand out when a
project is registered. It lives at:

`~/.harbor/port-pool.json`

```json
{ "ranges": [{ "from": 8100, "to": 8199 }] }
```

Missing file → default **8100–8199**. Edit the ranges from the main window's
**Port Convention** sidebar (**Edit pool…**). The companion harbor-pilot skill
reads the same file and writes the next free pool port into the project's
central config.

```toml
[[process]]
name = "api"
command = "uv run uvicorn app.main:app --reload --port $PORT"
port = 8100
ready_url = "http://127.0.0.1:${port}/health"
```

`port = "auto"` is a parse error. Out-of-pool numbers stay legal (Vite's 5173,
`[[port_claim]]` 5432, …) — they show under **Other claims**, not as Harbor
convention leases. After ~5s Harbor checks that the process tree is listening
on the declared port; if it bound somewhere else, an orange badge appears.
A soft lint appears when `port` is set but the command mentions neither
`$PORT` / `${PORT}` nor the decimal `N`.

The **Port Allocation Convention** screen lists leased pool ports (Port,
Project, Process, Status), the pool summary (`8100–8199 · 3 / 100 allocated`)
and the next free port. Unused pool ports are omitted. Overlap banners and
kill/copy actions still apply.

### Generating configs with the `harbor-pilot` skill

Harbor has a companion **Cursor agent skill**
[**harbor-pilot**](https://github.com/z1joey/harbor-pilot) that drafts
central configs from your repo layout, plans ports against other registered
projects, and validates the result against Harbor's parser. Install once:

```bash
mkdir -p ~/.agents/skills
git clone https://github.com/z1joey/harbor-pilot.git ~/.agents/skills/harbor-pilot
```

**In Cursor chat**, attach or invoke the skill and ask in plain language. The
agent reads `package.json`, `compose.yaml`, framework configs, and
`~/.harbor/projects/*.toml` before writing anything — it never adds files to
your project.

Example prompts:

| Goal | Example prompt |
|---|---|
| New project | *"Add my `~/Projects/shop` repo to Harbor — discover the dev commands and register it."* |
| Port collisions | *"I already have a Vite app on 5173 in Harbor. Register this Next.js project without overlapping ports."* |
| Pool ports | *"Register this server from Harbor's port pool; keep the API on the port the Vite proxy already uses."* |
| Fix / review | *"My Harbor config fails to parse — fix it to match Harbor's schema."* |
| Chinese | *"接入 harbor，帮我配置一下"* |

The skill follows a fixed workflow: discover processes → read the Harbor pool
(`~/.harbor/port-pool.json`) and other projects' claimed ports → assign the
**next free pool port** to each managed server that is not already hardcoded
elsewhere → draft TOML → validate → **register** the project
(`register_project.py` validates the draft, injects the `root` key, and
installs `~/.harbor/projects/<name>.toml` atomically).

Validate a draft yourself (no app required):

```bash
python3 ~/.agents/skills/harbor-pilot/scripts/validate_harbor_toml.py \
  /tmp/shop-harbor.toml \
  ~/.harbor/projects/other-app.toml
```

See the [harbor-pilot repo](https://github.com/z1joey/harbor-pilot) for the full
skill schema (`open_process`, pool `port = N`, Docker `port_claim`s, etc.).

`OK` means parser rules pass and no static port overlap between the listed
configs. `OVERLAP` flags two projects claiming the same port; `ERROR`
is a schema violation (e.g. `port = "auto"`, or `port_env` / `${port}` without
a declared `port`). `WARN` means `port` is set but the command does not
reference `$PORT` or the decimal port number.

**Skill output vs Harbor UI:** the skill installs the config under
`~/.harbor/projects/`; any running Harbor
frontend picks the project up within ~1s. Edits hot-reload; Harbor does not
rewrite your app's `vite.config`, `.env`, or Docker files. Production deploys
are unaffected; `$PORT` injection applies only to processes Harbor starts
locally.

## harbor-tui (terminal UI)

The same engine — same config schema, same parsing, planning and stop
semantics — in a terminal. Runs against the shared registry, so the TUI and
the menubar app see the same projects; each supervises only the processes it
spawned itself. Quitting the TUI stops its managed trees, exactly like
"Quit Harbor" in the app.

Build & run from source:

```bash
cd Core
swift build
.build/debug/harbor-tui
```

Or grab `harbor-tui-X.Y.Z.macos-universal.tar.gz` from a release and put the
binary on your `PATH`.

Keys:

| Key | Action |
|---|---|
| `1` / `2` / `3` / `Tab` | Switch Projects / Logs / Ports panels |
| `j` / `k` or arrows, PgUp/PgDn | Move selection (log scroll in Logs) |
| `s` / `S` | Start process / start all for the project |
| `x` / `X` | Stop process / stop all for the project (`x` kills a listener in Ports) |
| `r` | Restart selected process |
| `⏎` / `l` | Open the selected process's logs |
| `f` / `c` | Logs: toggle follow / clear |
| `v` / `m` / `/` | Ports: toggle overview, mine-only, filter |
| `:` | Command bar — `refresh`, `q` (registration lives in `~/.harbor`, via the skill) |
| `q` / `Ctrl+C` | Quit (stops managed trees; confirms when something is running) |

Ports panel and all start/stop/confirm semantics match the GUI; the shared
registry means the TUI and the menubar app see the same projects, each
supervising only the processes it spawned itself.

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
- Declared `[[process]]` `port` already held by a foreign PID → Harbor warns
  and requires confirmation before starting (individually or via Start all).
  The confirmation also offers to free the port first: stop the managed
  holder, or kill the foreign process tree, then start.
- `[[port_claim]]` ports are planning metadata: they never block starts (the
  holder is usually infrastructure like brew-services postgres or a
  Docker-published port, which can never look "managed"). They drive static
  overlap warnings and the Port Allocation Convention instead.
- Held by *another project's managed process* → same warning (this collision
  is invisible to plain lsof-vs-config checks). Two projects claiming the
  same port with nothing running is flagged as a static overlap — see the
  **Port Convention** sidebar item and start-time warnings (the harbor-pilot
  skill plans ports to avoid this when registering).
- Port snapshots come from `lsof -nP -iTCP -sTCP:LISTEN`, polled every ~2s on
  a background queue. Without elevated privileges lsof only shows your own
  listeners — that's an OS constraint, not a bug.

## Fixtures

- `fixtures/sample-config.toml` — schema example (as installed in
  `~/.harbor/projects/`).
- `fixtures/selftest-project/` — register this folder to exercise everything
  (`python3 ~/.agents/skills/harbor-pilot/scripts/register_project.py
  <abs-path-to>/fixtures/selftest-project --config <abs-path-to>/fixtures/selftest-project/harbor.toml`
  — the draft ships in the fixture; no root file is needed after that):
  `logger` streams a line/second into its log pane, `server` is a python
  http.server on port 8123 with a `ready_url`, `auto-server` uses sticky pool
  port **8100** with `$PORT` and `${port}` in `ready_url`, and `cwd-check`
  proves working directories by writing `pwd` into `sub/harbor-cwd.txt`.

## Testing

Core logic (config parsing, registry, ports, process supervision) lives in the
local SwiftPM package `Core/` (`HarborCore`), shared by the GUI app and the
TUI. The `HarborCoreTests` target covers the TOML parser (incl. `[[port_claim]]` and
rejecting `port = "auto"`), the port-pool store (default 8100–8199, validation),
the read-only project registry (loads `~/.harbor/projects/*.toml`, never
rewrites it, picks up skill writes and deletions via the directory watcher,
lists broken configs and duplicate roots with a visible error), the legacy
store migrations (App Support → `~/.harbor`, per-root `harbor.toml` →
central configs), lsof
output parsing and dedupe, the port planner (runtime conflicts — foreign and
managed holders —, static overlaps, pool-port allocation), convention vs
other-claim rows, the SIGTERM→SIGKILL tree kill, log
ring buffers, and the process supervisor lifecycle (cwd/env, stop, restart,
auto-restart, failed state, PID→process lookup, sticky `PORT` inject).

```bash
cd Core && swift test
```

The GUI app itself is a compile gate (no UI tests):

```bash
xcodegen generate
xcodebuild build -project Harbor.xcodeproj -scheme Harbor \
  -configuration Debug -destination 'platform=macOS'
```

## CI & releases

`.github/workflows/ci.yml` runs on GitHub Actions macOS runners:

- **Pull requests** — `swift test` in `Core/` plus an app compile build;
  PRs must pass before merge.
- **Push to `main`** — the same checks run as a merge safety net.
- **Releases** — pushing a version tag (`git tag v1.0.3 && git push origin
  v1.0.3`) runs the tests, then builds a Release `Harbor.app`, packages
  `Harbor-X.Y.Z.zip` and a drag-to-install `Harbor-X.Y.Z.dmg`, and publishes
  both as a GitHub release with auto-generated notes. Two guards apply: the
  tag must point at a commit on `main`, and the tag must match
  `MARKETING_VERSION` in `project.yml` (bump the version *before* tagging).
  No other event produces a release.

## Development notes

- Layout: `Core/Sources/HarborCore` (Models + Services, no SwiftUI, shared with
  the TUI), `App/ViewModels`, `App/Views` (popover, main window, ports,
  projects, logs, sheets), `Core/Tests/HarborCoreTests` (XCTest for HarborCore).
- TOML parsing uses [TOMLKit](https://github.com/LebJe/TOMLKit) (SPM, declared
  in `Core/Package.swift`).
- Logs are in-memory ring buffers (~2000 lines per process).

## Out of scope for v1

Docker/compose control, remote/SSH hosts, Windows/Linux, editor extensions,
libproc-based port scanning, cloud sync/telemetry.
