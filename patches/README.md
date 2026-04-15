# Linux Computer Use & Dispatch Patches

This directory contains Python patch scripts that modify the minified Claude
Desktop `index.js` to enable **Computer Use** and **Dispatch** features on
Linux.

These patches are ported verbatim from
[patrickjaja/claude-desktop-bin](https://github.com/patrickjaja/claude-desktop-bin)
and are applied by `build.sh` after the existing shell-based patches.

## Patches

Applied in this order (dependencies matter — see `build.sh`
→ `apply_cu_dispatch_patches`):

| Order | File                          | Purpose                                                                                                       |
|-------|-------------------------------|---------------------------------------------------------------------------------------------------------------|
| 1     | `fix_0_node_host.py`          | Replace `process.resourcesPath + "app.asar"` with `app.getAppPath()` for nodeHost & shellPathWorker.          |
| 2     | `fix_locale_paths.py`         | Redirect locale file lookups to the Linux install layout (`resources/i18n`).                                  |
| 3     | `fix_disable_autoupdate.py`   | Disable Squirrel auto-updater on Linux (prevents stale "update downloaded" toasts).                           |
| 4     | `fix_updater_state_linux.py`  | Add `version:""` to idle updater state so renderer `.includes()` calls don't throw.                           |
| 5     | `enable_local_agent_mode.py`  | **Critical.** Register `computerUse` as supported in the UI, bypass yukonSilver platform gate, spoof navigator / User-Agent. |
| 6     | `fix_computer_use_tcc.py`     | Register stub IPC handlers for `ComputerUseTcc` (macOS permission system).                                    |
| 7     | `fix_computer_use_linux.py`   | Bypass macOS/Windows platform gates, inject Linux executor (xdotool/ydotool/scrot/grim).                      |
| 8     | `fix_dispatch_linux.py`       | Force-enable the Dispatch feature flags, bypass remote-session-control check, auto-wake cold parents.        |
| 9     | `fix_dispatch_outputs_dir.py` | Fall back to child session outputs directory when parent's is empty.                                          |
| 10    | `fix_dispatch_grant_ttl.py`   | Force the `dispatchCuGrantTtlMs` accessor to return `MAX_SAFE_INTEGER` so CU grants never expire (makes unattended Dispatch usable). |

**Why order matters:** `fix_0_node_host` must run before `fix_locale_paths`
(the latter rewrites `process.resourcesPath` globally). `enable_local_agent_mode`
must run before `fix_computer_use_*` because the CU patches rely on
`computerUse:{status:"supported"}` being registered in the feature merger.

## Design

Each patch script follows the same contract:

- Header comments declare `@patch-target: app.asar.contents/.vite/build/index.js`
  and `@patch-type: python`.
- Patterns use `\w+` wildcards to survive minifier variable renames between
  Claude Desktop versions.
- Scripts exit with status 0 on success, 1 on any FAIL message.

## Runtime Dependencies

For Computer Use to work at runtime, the user's system must have:

### X11 (required)
- `xdotool` — mouse/keyboard input
- `scrot` — screenshot capture
- `xclip` — clipboard (falls back to Electron's native API)
- `wmctrl` — window management
- `imagemagick` — image cropping (`convert`/`import`)

### Wayland (additional)
- `ydotool` (+ running `ydotoold` daemon) — input injection
- `grim` — screenshots on wlroots (Sway, Hyprland)
- `spectacle` — KDE screenshots
- `gnome-screenshot` / `gst-launch-1.0` — GNOME screenshots

See the reference project's `wayland.md` for setup details.

## Version Compatibility

The patches target Claude Desktop **1.2.x+**. When `build.sh` is bumped to an
older release, some patches may emit `[WARN]` or `[FAIL]` for patterns that do
not exist in that version. The build wrapper treats these as non-fatal.

## Updating Patches

When a new Claude Desktop version ships, re-extract the app source
(see `CLAUDE.md` → "Setting Up build-reference") and adjust regex patterns
that no longer match. Prefer `\w+` / `[\w$]+` wildcards over hardcoded
minified variable names.
