# Claude Code Monitor — macOS Desktop App

The dashboard ships with an optional **native macOS application** that wraps the existing server + client into a single `.app` you install once and forget. Everything you see in the browser at `localhost:4820` lives inside this window, with macOS-native lifecycle on top: menu-bar icon, application menu, Login Items integration, and a single quit button that cleans up the server.

> **Status:** v1, macOS only. Windows and Linux are tracked as follow-ups — Electron makes them straightforward but each needs its own QA.

## Why this exists in addition to the PWA

The PWA (added in #144) makes the dashboard installable in Chromium-based browsers, which is great for users who already keep the server running. The desktop app solves the orthogonal problem: **starting and keeping the server running** without a terminal window. Concretely:

| Capability | PWA | Desktop App |
|---|---|---|
| Installs to dock / Applications | ✅ | ✅ |
| Manages the Express server | ❌ — user must `npm start` separately | ✅ — embedded in-process |
| Auto-starts at login (macOS) | ❌ | ✅ via native Login Items |
| Menu-bar (tray) icon for always-on status | ❌ | ✅ |
| Native application menu (⌘ shortcuts, etc.) | ❌ | ✅ |
| Survives browser restart | ⚠️ depends on browser | ✅ |

The two coexist — install whichever fits your workflow.

## Quick install

**Option A — download a pre-built DMG** (from the latest CI run or release):

1. Download `ClaudeCodeMonitor-<version>-universal.dmg` from the GitHub release page (or from the `ClaudeCodeMonitor-dmg` artifact on the latest passing CI run).
2. Double-click → drag `Claude Code Monitor.app` into your `Applications` folder.
3. Open it. macOS may show a Gatekeeper warning the first time — see [Gatekeeper](#gatekeeper-first-launch) below.

**Option B — build locally:**

```bash
# In the project root, after `git clone`:
npm run setup                # installs root + client + vscode-extension deps
npm run build                # builds the React client
npm run desktop:install      # installs Electron + electron-builder
npm run desktop:dmg          # produces desktop/release/ClaudeCodeMonitor-*.dmg
open desktop/release/ClaudeCodeMonitor-*-universal.dmg
```

## What happens when you launch the app

1. The Electron main process picks a free port — preferring **4820**, falling back to 4821–4829, then a random high port if all those are taken.
2. If something already answers `/api/health` on port 4820 (e.g. you ran `npm start` in a terminal), the app **adopts that server** and skips starting a second one. No double-binding, no SQLite contention.
3. Otherwise it `require()`s `server/index.js` directly in-process — same Node runtime as the main process, same memory. Boot is typically under two seconds.
4. The dashboard window opens (unless macOS launched the app at login, in which case it stays tray-only).
5. A menu-bar icon appears with: *Open Dashboard, Open in Browser, Restart Server, Show Logs, Open at Login (toggle), Quit*.

## Lifecycle semantics

- **Closing the window hides it.** The server keeps running, the tray icon stays. Click the tray to bring the window back.
- **Quit (⌘Q, or tray → Quit)** shuts the embedded server down gracefully and exits.
- **Login Items toggle:** flip *Open at Login* in the tray menu (or the app menu). It registers via macOS's `SMAppService` API — you'll see the entry under  → *System Settings → General → Login Items*.
- **Single-instance:** double-launching just focuses the existing window. No second server, no port collision.
- **Logs** live at `~/Library/Logs/Claude Code Monitor/desktop.log` (use *Show Logs* in the menu to open the folder).

## File layout (for contributors)

```
desktop/
├── package.json                # Electron + electron-builder
├── tsconfig.json
├── electron-builder.yml        # DMG config; signing/notarization hooks
├── assets/                     # icon.svg + generated icon.icns + tray PNGs
├── src/
│   ├── main.ts                 # main process entry, lifecycle
│   ├── server-host.ts          # in-process Express boot, port discovery, adopt
│   ├── window.ts               # BrowserWindow + persisted state
│   ├── tray.ts                 # menu-bar icon + context menu
│   ├── menu.ts                 # native application menu
│   ├── login-item.ts           # macOS Login Items toggle
│   ├── preload.ts              # (empty — kept for future renderer bridges)
│   ├── logger.ts               # file logger
│   └── constants.ts
├── scripts/
│   ├── prebuild.js             # ensures root + client are built before tsc
│   ├── build-icons.sh          # SVG → PNG/ICNS via qlmanage/sips/iconutil
│   └── notarize.js             # electron-builder afterSign hook (opt-in)
└── tests/
    └── smoke.test.mjs          # spawn-and-probe /api/health
```

**The diff in every other directory is zero.** `server/`, `client/`, `scripts/`, `mcp/`, and `vscode-extension/` are untouched by this feature. The Electron main process is just a host for the same code.

## Gatekeeper (first launch)

The DMG is **ad-hoc signed** by default — that's all the project can offer without a paid Apple Developer ID. macOS will warn the first time you open it: *"Apple could not verify…"*.

Two ways past it:

```bash
# Easiest: strip the quarantine attribute from the DMG before opening.
xattr -cr ~/Downloads/ClaudeCodeMonitor-*.dmg
```

Or open  → *System Settings → Privacy & Security*, scroll to the blocked DMG, click *Open Anyway*.

### Notarization (for the maintainer)

When you're ready to make this go away for everyone, add these three repository secrets:

| Secret | Where it comes from |
|---|---|
| `APPLE_ID` | Your Apple ID email |
| `APPLE_TEAM_ID` | Your Apple Developer team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | An app-specific password created at appleid.apple.com |

Optionally, also `CSC_LINK` (base64-encoded `.p12`) and `CSC_KEY_PASSWORD` to provide an explicit Developer ID certificate from outside the runner keychain. The CI workflow picks them up automatically — no code change required. See [`desktop/scripts/notarize.js`](desktop/scripts/notarize.js) for the hook.

## Development workflow

```bash
# Hot-iterate on the main process (rebuilds tsc on save would be next steps;
# v1 ships without watch mode — just re-run desktop:dev after changes):
npm run desktop:dev

# Smoke test (also runs in CI on macOS):
npm run desktop:test

# Full DMG (slow — invokes electron-builder, universal binary):
npm run desktop:dmg
```

The smoke test does not exercise the BrowserWindow (no display on headless CI). It spawns Electron, waits for the embedded server to answer `/api/health`, then shuts down. Anything that depends on the renderer is part of the manual QA checklist on the PR.

## Known caveats

- **Bundle size** ≈ 80 MB DMG, ≈ 250 MB on disk. The standard Electron tax. Tauri would cut this dramatically but at the cost of a sidecar-process model and a Rust toolchain dependency — fair to revisit in a follow-up PR if bundle size becomes a real complaint.
- **Native modules**: `better-sqlite3` is rebuilt against Electron's Node version automatically via `electron-builder install-app-deps` in the desktop workspace's `postinstall`. If that fails for any reason, the server falls back to `node:sqlite` (per #37), so the app still boots.
- **Universal binary**: the DMG contains both x64 and arm64 slices. Use `arch` in `electron-builder.yml` to switch to a single architecture if you want to halve the size.
- **Auto-update**: not wired in v1. The current update path is *re-download the latest DMG*. `electron-updater` + GitHub Releases is the natural follow-up.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| "Apple could not verify…" on first launch | Unnotarized DMG | `xattr -cr ~/Downloads/ClaudeCodeMonitor-*.dmg` |
| Window shows but content is blank | Server didn't boot — check `~/Library/Logs/Claude Code Monitor/desktop.log` | Restart from tray → *Restart Server* |
| Tray icon missing | The OS hides tray icons when the menu bar is full | Move other menu-bar items aside, or look in the overflow chevron |
| App didn't auto-start at login | Login Items entry got revoked by macOS | Toggle *Open at Login* off and on again from the tray menu |
| Port 4820 already in use, app refuses to start | Something other than the dashboard is on 4820 and it doesn't answer `/api/health` | The app will pick a fallback (4821–4829, then a random high port) — check the tray menu's port indicator |
