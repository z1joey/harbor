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
list with kill, and "Open Harbor…" for the full main window (sidebar:
**Projects** | **Ports Overview** | **Listening Ports** — filter lives here).
"Quit Harbor" stops all managed processes and exits.

## Registering a project

Each project is a folder containing `harbor.toml` (or `.harbor.toml`). Use
**Project → Add Project…** (⌘N) in the menu bar: pick a folder; if it has no
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

[[port_claim]]
port = 5432                      # port the project relies on (database, broker, …)
note = "postgres"                # optional, shown in the ports overview
process = "api"                  # optional, must match a [[process]] name above
```

Commands run inside a **login shell** (`/bin/zsh -lc`), so your usual PATH
(homebrew, uv, nvm, …) applies. Invalid TOML shows a readable error in the UI
(with line/column); the project stays registered with a visible error banner
until fixed.

### Automatic ports

Set `port = "auto"` to let Harbor pick a free port from **8100–9999** on each
start (nothing is persisted — the number changes every run). Harbor injects the
chosen port as the `PORT` environment variable (override the name with
`port_env`). Reference it in your command via `$PORT`:

```toml
[[process]]
name = "api"
command = "uv run uvicorn app.main:app --reload --port $PORT"
port = "auto"
ready_url = "http://127.0.0.1:${port}/health"
```

`${port}` in `ready_url` is only allowed with `port = "auto"`. After ~5s,
Harbor checks that the process tree is listening on the assigned port; if it
bound somewhere else (e.g. the command ignored `$PORT`), an orange badge appears
on the process row. Auto ports do not participate in pre-start conflict checks —
Harbor always scans for a free port at start time.

### Generating configs with the `harbor-toml` skill

Harbor has a companion **Cursor agent skill**
[**harbor-toml**](https://github.com/z1joey/harbor-toml) that drafts
`harbor.toml` files from your repo layout, plans ports against other registered
projects, and validates the result against Harbor's parser. Install once:

```bash
mkdir -p ~/.agents/skills
git clone https://github.com/z1joey/harbor-toml.git ~/.agents/skills/harbor-toml
```

**In Cursor chat**, attach or invoke the skill and ask in plain language. The
agent reads `package.json`, `compose.yaml`, framework configs, and
`~/Library/Application Support/Harbor/projects.json` before writing anything.

Example prompts:

| Goal | Example prompt |
|---|---|
| New project | *"Add my `~/Projects/shop` repo to Harbor — discover the dev commands and write a `harbor.toml`."* |
| Port collisions | *"I already have a Vite app on 5173 in Harbor. Write `harbor.toml` for this Next.js project without overlapping ports."* |
| Auto ports | *"Use `port = \"auto\"` for the frontend; keep the API on a fixed port the Vite proxy can reach."* |
| Fix / review | *"My `harbor.toml` fails to parse — fix it to match Harbor's schema."* |
| Chinese | *"接入 harbor，帮我写个 harbor 配置"* |

The skill follows a fixed workflow: discover processes → collect claimed ports
from other projects → choose **auto vs fixed** per process (APIs that another
dev server proxies to should stay **fixed**; standalone servers can use
`port = "auto"`) → draft TOML → validate → tell you to **Add Project…** in
Harbor.

Validate a draft yourself (no app required):

```bash
python3 ~/.agents/skills/harbor-toml/scripts/validate_harbor_toml.py \
  ~/Projects/shop/harbor.toml \
  ~/Projects/other-app/harbor.toml
```

See the [harbor-toml repo](https://github.com/z1joey/harbor-toml) for the full
skill schema (`open_process`, `port = "auto"`, Docker `port_claim`s, etc.).

`OK` means parser rules pass and no static port overlap between the listed
configs. `OVERLAP` flags two projects claiming the same fixed port; `ERROR`
is a schema violation (e.g. `port_env` without `port = "auto"`, or `${port}`
in `ready_url` on a fixed port). `WARN` means `port = "auto"` but the command
does not reference `$PORT`.

**Skill output vs Harbor UI:** the skill only writes `harbor.toml` on disk —
it does not register the folder. After saving, open Harbor → **Add Project…**
→ pick the project root. Edits hot-reload; Harbor does not rewrite your app's
`vite.config`, `.env`, or Docker files. Production deploys are unaffected;
`port = "auto"` and `$PORT` apply only to processes Harbor starts locally.

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
  overlap warnings and the Ports Overview instead.
- Held by *another project's managed process* → same warning (this collision
  is invisible to plain lsof-vs-config checks). Two projects claiming the
  same port with nothing running is flagged as a static overlap — see the
  **Ports Overview** sidebar item, and warnings when adding/importing a
  project (which also suggest currently free ports).
- Port snapshots come from `lsof -nP -iTCP -sTCP:LISTEN`, polled every ~2s on
  a background queue. Without elevated privileges lsof only shows your own
  listeners — that's an OS constraint, not a bug.

## Fixtures

- `fixtures/sample-harbor.toml` — schema example.
- `fixtures/selftest-project/` — register this folder to exercise everything:
  `logger` streams a line/second into its log pane, `server` is a python
  http.server on port 8123 with a `ready_url`, `auto-server` uses
  `port = "auto"` with `$PORT`, and `cwd-check` proves working directories
  by writing `pwd` into `sub/harbor-cwd.txt`.

## Testing

The `HarborTests` target (84 XCTests) compiles the real service sources
(`App/Models`, `App/Services`) unhosted, so tests run fast without launching
the app. They cover the TOML parser (incl. `[[port_claim]]`), project
registry store, lsof output parsing and dedupe, the port planner (runtime
conflicts — foreign and managed holders —, static overlaps, free-port
suggestions), the SIGTERM→SIGKILL tree kill, log ring buffers, the process
supervisor lifecycle (cwd/env, stop, restart, auto-restart, failed state,
PID→process lookup), and the Procfile/package.json importers.

```bash
xcodebuild test -project Harbor.xcodeproj -scheme Harbor \
  -configuration Debug -destination 'platform=macOS'
```

## CI & releases

`.github/workflows/ci.yml` runs on GitHub Actions macOS runners:

- **Pull requests** — `xcodegen generate` + the unit-test suite above; PRs must
  pass before merge.
- **Push to `main`** — the unit-test suite runs as a merge safety net.
- **Releases** — pushing a version tag (`git tag v0.1.0 && git push origin
  v0.1.0`) runs the tests, then builds a Release `Harbor.app`, packages it
  with `ditto`, and publishes it as a GitHub release with auto-generated
  notes. Two guards apply: the tag must point at a commit on `main`, and the
  tag must match `MARKETING_VERSION` in `project.yml` (bump the version
  *before* tagging). No other event produces a release.

## Development notes

- Layout: `App/Models`, `App/Services` (no SwiftUI), `App/ViewModels`,
  `App/Views` (popover, main window, ports, projects, logs, sheets),
  `Tests/` (XCTest for models + services).
- TOML parsing uses [TOMLKit](https://github.com/LebJe/TOMLKit) (SPM).
- Logs are in-memory ring buffers (~2000 lines per process).
- Manual acceptance checklists: [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)
  (service-level ACs are also covered by the unit-test target; that file
  records what was verified and which UI checks remain manual).

## Out of scope for v1

Docker/compose control, remote/SSH hosts, Windows/Linux, editor extensions,
libproc-based port scanning, cloud sync/telemetry.
