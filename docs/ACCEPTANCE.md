# Harbor acceptance checklist

Manual verification checklist for Harbor milestones. See the project plan for full task descriptions.

## Task 0 — Scaffold

- [ ] AC0.1 Repo exists at `~/Projects/harbor` with git initialized.
- [ ] AC0.2 `xcodegen generate` produces a project that builds with `xcodebuild` Debug without errors.
- [ ] AC0.3 Running the app shows a menu bar extra (no Dock icon).
- [ ] AC0.4 Popover opens with placeholder content and an “Open Harbor…” action that shows the main window.
- [ ] AC0.5 Quit from the popover terminates the app.

## Task 1 — Port observe + kill (M1)

- [ ] AC1.1 Listening ports appear within ~3s.
- [ ] AC1.2 Ports disappear when processes exit.
- [ ] AC1.3 Kill from UI terminates the listener.
- [ ] AC1.4 Kill confirmation appears before sending signals.
- [ ] AC1.5 Copy port and Copy PID work.
- [ ] AC1.6 Filter narrows the list.
- [ ] AC1.7 App remains responsive while polling.
- [ ] AC1.8 Manual test steps documented here.

## Task 2 — Config + registry (M2a)

- [ ] AC2.1 Valid `harbor.toml` registers project and processes.
- [ ] AC2.2 `.harbor.toml` works the same.
- [ ] AC2.3 Invalid TOML shows an error.
- [ ] AC2.4 Remove Project leaves files on disk.
- [ ] AC2.5 Relaunch restores registered projects.
- [ ] AC2.6 Template config creation works.

## Task 3 — Process supervisor + logs (M2b)

- [ ] AC3.1 Start uses correct working directory.
- [ ] AC3.2 Logs appear in the UI.
- [ ] AC3.3 Stop kills process tree.
- [ ] AC3.4 Restart works.
- [ ] AC3.5 Start all / Stop all work.
- [ ] AC3.6 Port conflict UI works.
- [ ] AC3.7 Menubar running count is accurate.
- [ ] AC3.8 Logs retained after failure.
- [ ] AC3.9 Harbor only manages processes it started.

## Task 4 — Polish (M3)

- [ ] AC4.1 `ready_url` health gate works.
- [ ] AC4.2 Open in Browser works.
- [ ] AC4.3 Auto-restart works; user Stop does not restart.
- [ ] AC4.4 Procfile / package.json import works.
- [ ] AC4.5 Launch at Login toggle works.
- [ ] AC4.6 Notifications work or fail soft.

## Cross-cutting

- [ ] ACX.1 No force-unwrap crashes in happy path.
- [ ] ACX.2 README documents build, config, ownership rules.
- [ ] ACX.3 This file lists all AC items.
- [ ] ACX.4 Services have no SwiftUI imports.
- [ ] ACX.5 Killing another user's process shows a readable error.
