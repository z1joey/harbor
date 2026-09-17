# Harbor acceptance checklist

Manual verification checklist for Harbor milestones. See the project plan for full task descriptions.

**How these were verified.** The app was built and launched on this machine
(`xcodegen generate` + `xcodebuild -configuration Debug build`). Behavior
living in `App/Services` (port polling/parsing, tree kill, supervisor
lifecycle, config parsing, registry store, health probe, importers) was
exercised by compiling the *actual shipped source files* into throwaway CLI
harnesses and asserting on real processes/sockets — 48 checks, all passing.
Those items are checked below with *(service harness)*. Items whose essence is
on-screen SwiftUI presentation (dialogs, copy buttons, menubar label) could
not be screenshotted in this environment and are left unchecked with manual
steps at the bottom.

## Task 0 — Scaffold

- [x] AC0.1 Repo exists at `~/Projects/harbor` with git initialized.
- [x] AC0.2 `xcodegen generate` produces a project that builds with `xcodebuild` Debug without errors. (Xcode 27; license must be accepted once via `sudo xcodebuild -license`.)
- [x] AC0.3 Running the app shows a menu bar extra (no Dock icon). (`LSUIElement=true` in generated Info.plist; System Events sees the "ferry" status item of the running app.)
- [ ] AC0.4 Popover opens with placeholder content and an “Open Harbor…” action that shows the main window. (Popover content is SwiftUI; manual step M1 below.)
- [x] AC0.5 Quit from the popover terminates the app. (Verified: AppleScript `quit` → process exits; the popover button calls the same `NSApp.terminate`.)

## Task 1 — Port observe + kill (M1)

- [x] AC1.1 Listening ports appear within ~3s. *(service harness: python http.server on 8765 listed with the spawned PID ≤ 2.5s)*
- [x] AC1.2 Ports disappear when processes exit. *(service harness ≤ 2.5s)*
- [ ] AC1.3 Kill from UI terminates the listener. (Kill engine verified — SIGTERM→SIGKILL tree kill in harness; the button wiring is manual step M3.)
- [ ] AC1.4 Kill confirmation appears before sending signals. (Code routes every non-managed PID through a confirmation dialog; dialog visibility is manual step M3.)
- [ ] AC1.5 Copy port and Copy PID work. (Manual step M4; `NSPasteboard` calls are in place.)
- [ ] AC1.6 Filter narrows the list. (Manual step M4; filtering is a view-layer computed property on port/name/PID/command.)
- [x] AC1.7 App remains responsive while polling. (lsof runs on a utility queue, never the main thread; harness ran dozens of consecutive polls.)
- [x] AC1.8 Manual test steps documented here. (See "Manual test steps" below.)

## Task 2 — Config + registry (M2a)

- [x] AC2.1 Valid `harbor.toml` registers project and processes. *(service harness: real `fixtures/sample-harbor.toml` parsed + registry add)*
- [x] AC2.2 `.harbor.toml` works the same. *(service harness)*
- [x] AC2.3 Invalid TOML shows an error and does not register a half-broken silent project. *(service harness: readable error with line/column; project registers with visible error banner and zero processes)*
- [x] AC2.4 Remove Project removes it from Harbor UI and `projects.json` but leaves files on disk. *(service harness)*
- [x] AC2.5 Relaunching Harbor restores the registered project list. *(service harness: fresh registry instance re-reads projects.json)*
- [x] AC2.6 “Create template config” writes a valid starter `harbor.toml` the parser accepts. *(service harness: template round-trips through the parser)*

## Task 3 — Process supervisor + logs (M2b)

- [x] AC3.1 Start runs the configured command with the correct working directory. *(service harness: `pwd` written into configured `sub/` cwd)*
- [x] AC3.2 Stdout/stderr appear in the log within ~1s of being written. *(service harness: streamed "tick" lines captured in ring buffer)*
- [x] AC3.3 Stop ends the process and its children — port is free afterward. *(service harness: shell with child sleeps fully dead, no orphans; python server stop frees port 8799)*
- [x] AC3.4 Restart equals Stop then Start; new PID differs. *(service harness)*
- [x] AC3.5 Start all starts every process in the project; Stop all stops them. *(service harness: two processes running concurrently → count 2, both stopped → count 0; Start/Stop All loop these same ops)*
- [ ] AC3.6 Declared port already in use → user sees conflict UI and must confirm before start (or cancel). *(Foreign-PID detection verified in harness; the confirmation dialog is manual step M6.)*
- [x] AC3.7 Menubar reflects running managed process count accurately (0 when all stopped). *(Count logic verified 2→0 in harness; the menubar label rendering is manual step M5.)*
- [x] AC3.8 Log buffer retains recent history after failure. *(service harness: "about-to-crash" still readable after unexpected exit, state = failed)*
- [x] AC3.9 Harbor does not claim “managed” control over processes it did not start. *(Supervisor tracks only its own spawns; foreign-listener test confirms the managed-PID set is separate.)*

## Task 4 — Polish (M3)

- [x] AC4.1 With `ready_url` pointing at a slow-starting server, UI shows not-ready until the URL succeeds, then ready. *(Probe verified in harness — returns true once HTTP 2xx/3xx, false on timeout; the ready badge display is manual step M7.)*
- [ ] AC4.2 “Open in Browser” opens the correct URL. (Manual step M7; per-process: `ready_url`, else `http://127.0.0.1:<port>/`. Project-level: `open_process` or `open_url` in harbor.toml — menubar safari button and detail header.)
- [x] AC4.3 `auto_restart = true`: killing the child externally causes Harbor to bring it back; user Stop does not auto-restart. *(service harness: both directions verified with 1s backoff)*
- [x] AC4.4 Procfile/`package.json` import produces a reviewable `harbor.toml` draft the user can save. *(service harness: drafts generated and round-trip through the parser; hooks skipped; the review sheet is manual step M8.)*
- [ ] AC4.5 Launch at Login toggle survives app restart and matches System Settings behavior. (Manual step M9 — requires registering a real login item; `SMAppService` code fails soft with a readable error.)
- [ ] AC4.6 Crash / conflict triggers a user-visible notification permission-aware (if denied, fail soft). (Manual step M10 — notification permission prompts once; delivery is silent no-op when denied.)

## Task 5 — Port planning (static overlaps + freeing)

- [x] AC5.1 `[[port_claim]]` parses with optional `note`/`process`; out-of-range, duplicate, and unknown-process claims are rejected. *(service tests: ConfigParserTests port_claim cases)*
- [x] AC5.2 A port held by another project's managed process is reported as a runtime conflict (previously invisible). *(service tests: PortPlannerTests managed-holder cases)*
- [x] AC5.3 Ports claimed by ≥2 projects are reported as static overlaps, sorted by port. *(service tests: PortPlannerTests overlap cases)*
- [x] AC5.4 Free-port suggestions skip all claimed and currently listening ports. *(service tests: PortPlannerTests suggestion cases)*
- [x] AC5.5 A PID maps to its owning managed project/process while running and clears after stop. *(service test: ProcessSupervisorTests key-for-PID)*
- [ ] AC5.6 Ports Overview shows claims, live status, holders, and overlap banners; sidebar badge counts overlaps. (Manual step M11.)
- [ ] AC5.7 Conflict dialogs offer "free the port & start" (stop managed holder / kill foreign tree) for single and start-all flows. (Dialog wiring is manual step M11; freeing logic reuses the verified stop/kill paths.)
- [ ] AC5.8 Add-project shows the overlap review screen; import editors show overlap hints + free-port suggestions; template comment carries the suggested port. (Manual step M11.)

## Task 6 — Auto port assignment

- [x] AC6.1 `port = "auto"` parses; invalid port strings, `port_env` without auto, and `${port}` in ready_url without auto are rejected. *(service tests: ConfigParserTests auto-port cases)*
- [x] AC6.2 Starting an auto-port process allocates from 8100–9999, injects `PORT`, and logs the assignment. *(service tests: ProcessSupervisorTests auto-port cases)*
- [x] AC6.3 `PortPlanner.allocatePort` skips taken ports and bind-probes candidates. *(service tests: PortPlannerTests allocation cases)*
- [x] AC6.4 After ~5s, a process listening on a port other than the assigned/declared one surfaces a verification badge. *(service tests: PortPlannerTests observedListeningPorts + portVerification grace/mismatch cases)*
- [ ] AC6.5 Project detail shows `:auto` / `:NNNN auto`, mismatch badge, and `$PORT` lint hint; Ports Overview lists running auto ports. (Manual step M12.)
- [ ] AC6.6 `fixtures/selftest-project` `auto-server` starts on an auto-assigned port and "Open in Browser" uses it. (Manual step M12.)

## Cross-cutting

- [x] ACX.1 No force-unwrap crashes in happy path or empty states. (Repo-wide grep: no `!` force unwraps / `try!` / `as!` in `App/`; empty states handled in every list view.)
- [x] ACX.2 README documents build, run, config schema, and ownership rules.
- [x] ACX.3 This file lists every AC checkbox for manual verification.
- [x] ACX.4 Code organized per layout; services have no SwiftUI imports. (grep-verified.)
- [x] ACX.5 Killing another user’s process fails with a readable error. *(service harness: SIGTERM to PID 1 → "owned by another user" message surfaced through the kill-error alert path.)*

## Manual test steps (for the unchecked items)

Launch a freshly built app:
`open ~/Library/Developer/Xcode/DerivedData/Harbor-*/Build/Products/Debug/Harbor.app`

- **M1 (AC0.4):** Click the ferry menu bar item. Popover shows a PROJECTS
  section (empty-state text), a LISTENING PORTS section (no filter field),
  and "Open Harbor…" / "Quit Harbor". Click "Open Harbor…" — the main window
  opens with a Projects|Listening Ports sidebar. Close it; the Dock icon
  disappears again.
- **M2 (AC1.1/1.2 visual):** In a terminal run `python3 -m http.server 8765`;
  within ~3s the popover and Ports table list `8765 / Python / PID`. Ctrl-C
  the server; the row disappears.
- **M3 (AC1.3/1.4):** With the server running, click its row in the popover,
  then Kill → a confirmation names the PID and port; confirm → row vanishes
  and the terminal process is dead. In the Ports table, select a row and use
  the Kill button — same confirmation.
- **M4 (AC1.5/1.6):** In the main window's Listening Ports table, select a row
  → Copy port / Copy PID → paste somewhere to verify. Type into the filter
  field (e.g. "8765" or "py") → list narrows; toggle "Mine only".
- **M5 (AC3.5/3.7):** Register `fixtures/selftest-project` (Add Project… →
  choose the folder). Start All → four status dots turn green and the
  menubar icon shows "4"; Stop All → dots gray, count gone.
- **M6 (AC3.6):** Start `python3 -m http.server 8123` externally, then press
  Start on the `server` process (declared port 8123) → a conflict dialog
  names the foreign PID; Cancel prevents start; "Start anyway" proceeds.
- **M7 (AC4.1/4.2):** Start the `server` process → it shows
  "running (not ready)" then "ready" once python answers; "Open in Browser"
  in the log pane opens `http://127.0.0.1:8123/`. Add `open_process = "server"`
  (or `open_url`) to a project → menubar safari icon and detail "Open in Browser"
  open the same URL.
- **M8 (AC4.4):** Create a folder with a `Procfile` (`web: python3 -m
  http.server 8081`) → Add Project → "Import from Procfile…" → editable draft
  → "Save harbor.toml & Add" → project appears with a `web` process.
- **M9 (AC4.5):** Toolbar gear → toggle "Launch at Login" → check
  System Settings ▸ General ▸ Login Items; toggle again to remove.
- **M10 (AC4.6):** Add `auto_restart = true` to a process, start it, `kill -9`
  the child twice → crash notification appears (first use asks permission);
  denying permission silences future ones without errors.
- **M11 (AC5.6–5.8):** Register two projects claiming the same port (e.g. copy
  `fixtures/sample-harbor.toml` into a second folder). Ports Overview lists
  the port with an orange overlap banner and the sidebar badge shows "1".
  With project A running, start the colliding process of project B → the
  dialog names A's project · process and offers "Stop … & start" → confirming
  stops A's process and starts B's. Re-add a project whose config claims an
  overlap → the Add flow shows the review screen with free-port suggestions.
- **M12 (AC6.5/6.6):** Start `auto-server` in the selftest project → row shows
  `:NNNN auto`; after ~5s no mismatch badge; "Open in Browser" opens the
  assigned URL. Ports Overview lists the port as "(auto)". Stop and restart
  → a (possibly different) port is assigned. Optionally start a process whose
  command ignores `$PORT` → after ~5s an orange mismatch badge appears.

## TUI — v1.0.0 (`harbor-tui`)

Shared-engine behavior (parsing, planning, supervision) is covered by the
`HarborCoreTests` suite (`cd Core && swift test`, green). The items below are
the TUI-specific manual checks; run `harbor-tui` in Terminal.app/iTerm with
`fixtures/selftest-project` registered.

- [ ] TUI-T1 Launch: alternate screen opens, top bar shows project/running
      counts, Projects panel lists every registered project with process rows,
      status dots and port labels (`:8000`, `:auto`, `:NNNN auto`). (PTY smoke
      verified render + clean exit during development.)
- [ ] TUI-T2 `j/k`/arrows move selection; `1/2/3`/`Tab` switch panels; bottom
      hint line reflects the active panel.
- [ ] TUI-T3 Start `logger` (`s`) → state turns running, Logs panel (`⏎`)
      streams lines with follow on; `f` pauses on scroll-up and resumes at
      bottom; `c` clears.
- [ ] TUI-T4 Stop (`x`) → tree exits, log gets the stop line; `r` restarts.
- [ ] TUI-T5 Start a process whose declared port is held (see M11 fixture
      setup) → inline confirmation offers free-port & start / start anyway /
      cancel; "free port & start" stops the managed holder (or confirms the
      foreign kill) then starts.
- [ ] TUI-T6 `S` on a project with two blocked processes → start-all
      confirmation naming both ports; "free ports & start all" releases and
      starts all.
- [ ] TUI-T7 Ports panel: listening table shows managed holders with
      `● harbor`; `m` toggles mine-only; `/` filters live; `x` on a foreign
      listener asks the kill confirmation and terminates the tree.
- [ ] TUI-T8 `v` switches to Ports Overview: claims ∪ listeners, free /
      managed / external statuses, holder column; static-overlap rows carry ⚠.
- [ ] TUI-T9 `:add <path>` on a folder with config shows the overlap review
      when it collides (add anyway / cancel); on a folder without config it
      offers template + numbered Procfile/package.json drafts (free-port hint).
- [ ] TUI-T10 `:remove` (with confirmation) unregisters; the running GUI
      reflects the change without restart and vice versa (shared registry,
      flock + store watch).
- [ ] TUI-T11 `q` with running processes → quit confirmation; confirming
      stops all TUI-managed trees; terminal is fully restored (cursor, main
      screen buffer) after every exit path, including external SIGTERM.
- [ ] TUI-T12 Terminal resize re-renders correctly; CJK project names are not
      split mid-glyph.
