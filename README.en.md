# DSH Launcher (macOS)

macOS desktop GUI for starting, stopping, restarting and updating the DeepSeek Harness (DSH) web service, with the ability to disable problematic plugins. All core logic lives in `launcher.sh`.

[中文说明](README.md)

## Files

| File | Purpose |
| --- | --- |
| `main.swift` | AppKit GUI (status text, action buttons, update-track dropdown); window and background dispatch only |
| `launcher.sh` | Core logic: start/stop/restart DSH, version-track query and update, plugin disable, startup-failure diagnosis |
| `build.sh` | One-shot packaging script; output goes to `~/Applications/DSH Launcher.app` |
| `icon.icns` | App icon |

## Build

```bash
bash build.sh
```

The app bundle is written to `~/Applications/DSH Launcher.app`. The build script locates its sources from its own directory, so the repo folder's name and location do not matter.

## Install

Run in a terminal:

```bash
git clone https://github.com/sci-zyf/dsh-launcher-macOS.git
cd dsh-launcher-macOS
bash build.sh
```

The result is `~/Applications/DSH Launcher.app` — double-click to run. Build prerequisites are listed under "Runtime dependencies" below.

## Runtime dependencies

1. macOS with its built-in Swift toolchain (`swiftc`) — nothing extra to install.
2. Node.js via nvm:

```bash
brew install nvm
nvm install 24
```

3. Install the dsh package globally (launcher.sh needs the dsh CLI and everything required to run it):

```bash
npm install -g @deepseek-ai/dsh
```

`launcher.sh` auto-detects an installed nvm version that provides the `dsh` command — no manual path configuration needed.

## CLI usage

`launcher.sh` also works standalone, without the GUI:

```bash
launcher.sh status                     show status/version/PID
launcher.sh dist-tags                  list available version tracks
launcher.sh update <tag>               update to the given track
launcher.sh start                      start DSH (background, port 3080)
launcher.sh stop                       stop DSH
launcher.sh restart                    restart DSH
launcher.sh disable-plugin @scope/name   disable a third-party plugin (no reinstall)
```

## Notes

- Double-clicking the .app runs in a non-interactive shell that does not read `~/.zshrc`. `launcher.sh` handles this itself: it scans installed nvm versions, finds the one exposing the `dsh` command, and prepends it to `PATH`.
- The shipped .app reads `launcher.sh` from inside the bundle (`Contents/Resources/launcher.sh`). For unpackaged debug runs (e.g. running from Xcode), set the `DSH_LAUNCHER_SH` environment variable to point at `launcher.sh`. This is independent of the source folder's location, so moving the repo folder requires no code changes.
- On startup failure, `~/.dsh/launcher.log` is analyzed and reported as “problem plugins” and “failure reason”.
- Disabling a plugin follows the market semantics: the `/dsh-market/toggle` API is tried first; if DSH is not running, local state files are patched directly (backed up first).
- Core bundles (`@deepseek-ai/dsh-base`, `@deepseek-ai/dsh-web-app`) are protected and cannot be disabled.
