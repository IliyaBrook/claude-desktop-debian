# Tray Icon Colour — User Choice via Context-Menu Submenu

Why auto-detection isn't enough, and how the "Icon color" submenu
works.

## The problem

The minified Claude Desktop app picks its Linux tray icon from the
pair bundled with the Windows build: `TrayIconTemplate.png` (black,
for light panels) and `TrayIconTemplate-Dark.png` (white, for dark
panels). `scripts/patches/tray.sh`'s `patch_tray_icon_selection`
inserts `nativeTheme.shouldUseDarkColors ? …Dark.png : …png` into the
ternary so the icon follows the desktop colour scheme.

That works on desktops where the panel colour matches the global
theme (GNOME, most of XFCE). On KDE Plasma it's routinely wrong:
Plasma lets users pick the panel's Plasma Style independently from
the global colour scheme, so a light desktop can have a dark panel
(and vice versa). `nativeTheme.shouldUseDarkColors` only sees the
global setting and misses that divergence.

We tried detecting the panel colour ourselves (reading `plasmarc` →
Plasma theme's `colors` file → kdeglobals fallback). It worked for
about 90% of real setups but:

- per-panel colour overrides in Plasma 6 aren't covered;
- third-party themes without a `dark`/`light` keyword in their name
  and no `colors` file regress to the global scheme;
- users with niche setups still saw the wrong icon.

So we added an explicit user choice to the tray context menu. Auto
detection remains the default and behaves exactly as before; the
`Black` and `White` overrides cover the edge cases directly. Pattern
borrowed from a sister Electron-repackaging project that adds tray
toggles the same way.

## UX

Right-click the tray icon:

```
Show App
Icon color ▶
  ● Auto      (default — Electron's detection, current behaviour)
    Black     (forces the black icon)
    White     (forces the white icon)
Quit
```

The submenu sits between `Show App` and `Quit`. Radio labels
describe the ICON'S colour (what the user sees), not the desktop
theme the icon is meant for — naming was reworked after users found
"Dark / Light" confusing (a "Dark" icon means white in the SNI
world because it's meant for dark panels).

Selecting a different radio triggers an app relaunch
(`app.relaunch(); app.exit(0)`). An earlier attempt to hot-swap the
icon via `nativeTheme.emit('updated')` worked on the first click but
then left a second StatusNotifierItem registered on KDE — the user
ended up with two tray icons and two independent radio groups. The
relaunch approach sidesteps that entirely for one line of code.

### Label spacing

The submenu item label is `"Icon color\u00A0"` (trailing non-breaking
space). Without it, Plasma's SNI renderer glues its own submenu
indicator glyph directly onto the final letter. A regular trailing
space can be trimmed by some dbusmenu renderers; NBSP is always
preserved.

## Implementation

### Persistence (`scripts/tray-icon-settings.js`)

A tiny `EventEmitter` subclass loads/saves
`~/.config/Claude/linux-tray.json` (`{ "iconMode": "auto" | "black"
| "white" }`) synchronously. Corrupt / unreadable / missing files
fall back to `"auto"`. `set(mode)` is a no-op when `mode` matches the
current value.

The helper `modeToDark(mode)` maps the user choice to the boolean
`shouldUseDarkColors` value our wrapper returns:

| mode    | `modeToDark` | meaning                                              |
|---------|--------------|------------------------------------------------------|
| `auto`  | `null`       | caller falls back to `nativeTheme.shouldUseDarkColors` |
| `black` | `false`      | force `TrayIconTemplate.png` (black icon)             |
| `white` | `true`       | force `TrayIconTemplate-Dark.png` (white icon)        |

#### Migration of legacy names

The first iteration used `dark` and `light` as mode names describing
the *panel theme* the icon was for. That inverted the mental model
users had (picking "Dark" produced a white icon), so the names were
renamed in-place:

| legacy | replacement |
|--------|-------------|
| `dark` | `white`     |
| `light`| `black`     |

`MODE_MIGRATIONS` maps old → new on load and rewrites the settings
file in the new format on first access, so users who ran the earlier
build don't lose their choice.

### Wiring (`scripts/frame-fix-wrapper.js`)

On first `require('electron')` the wrapper builds a Proxy over
`result.nativeTheme` that intercepts `shouldUseDarkColors` and
returns the user-chosen value when the settings module resolves to
a non-null boolean. On mode change the wrapper calls
`result.app.relaunch(); result.app.exit(0)` instead of trying to
re-templatise the tray in place (see UX section above for why).

`nativeTheme` is C++-backed so the Proxy has to be careful:

- read properties via `target[prop]` (no `receiver`) so native
  getters see the native object as `this`;
- bind any returned function to `target`, or `.on(...)` and friends
  throw `TypeError: Illegal invocation`;
- explicit `set` trap writes to `target` for setters (e.g.
  `nativeTheme.themeSource = 'dark'`).

The wrapper publishes `globalThis.__claudeTrayIcon = { get, set }`
so the injected submenu's click handlers can read/write the mode
without a require cycle inside the minified bundle.

### Submenu injection (`scripts/patches/tray.sh`)

`patch_tray_icon_submenu` uses Node to regex-replace the Quit menu
item (anchored on its i18n ID `dKX0bpR+a2`, which is much more
stable across releases than the minified function/variable names)
with:

```
<icon-color-submenu>,<original-quit-item>
```

Each radio's `checked` and `click` reference
`globalThis.__claudeTrayIcon` with optional-chaining (`?.`) so the
menu still builds safely if the wrapper somehow didn't load.

Two guards around the injection:

1. **New-format idempotency:** `grep -q '"Black".*"White"'` — if the
   current submenu is already present, re-running the patch is a
   no-op.
2. **Legacy strip:** `grep -q '"Icon color".*"Dark".*"Light"'`
   detects the first-iteration submenu (`Dark`/`Light` labels) and
   removes it via a Node regex before the new injection, so users
   running `--clean no` over an already-patched asar don't end up
   with two submenus side-by-side.

### Flow on a click

1. User right-clicks the tray, picks "White".
2. Click handler calls `globalThis.__claudeTrayIcon.set("white")`.
3. Settings module writes `~/.config/Claude/linux-tray.json` and
   emits `change`.
4. Wrapper's change listener calls `app.relaunch(); app.exit(0)`.
5. The relaunched process reads `"white"` from disk at startup.
6. Our Proxy returns `true` from `shouldUseDarkColors` → the
   sed-patched ternary picks `TrayIconTemplate-Dark.png` (white
   icon) → the new tray comes up with the correct icon and the
   "White" radio checked.

## Testing manually

```bash
# Inspect / force a mode without the UI
cat ~/.config/Claude/linux-tray.json
echo '{"iconMode":"dark"}' > ~/.config/Claude/linux-tray.json

# Watch the wrapper's state log
tail -f ~/.cache/claude-desktop-debian/launcher.log \
  | grep '[Frame Fix].*tray\|Tray icon'
```

The wrapper logs `[Frame Fix] Tray icon mode = <mode>` at startup
and `[Frame Fix] Tray icon mode changed to <mode>` on each transition.

## Related: duplicate tray icon on OS theme change

The same StatusNotifierItem re-registration race that motivated the
relaunch on icon-mode change also bites on OS theme changes — an
independent pre-existing bug even on main. The minified
`tray_func()` destroys the current tray, waits 250 ms, then creates
a new one so the icon PNG switches. On KDE the new SNI appears
before Plasma processes the old one's unregister signal → two
icons in the tray side by side until the stale one ages out (often
requires logout / relogin).

`patch_tray_inplace_update` (in `scripts/patches/tray.sh`) injects a
fast-path at the top of the tray rebuild:

```js
if (Nh && e !== false) {
  Nh.setImage(pA.nativeImage.createFromPath(t));
  process.platform !== 'darwin' && Nh.setContextMenu(wAt());
  return;
}
```

When the tray already exists and isn't being disabled, we just
update its image and context menu on the existing SNI object — no
destroy, no re-registration, no DBus race. The original destroy-
and-recreate path is retained for initial creation and the tray-
disable case, where it's unavoidable.

Name extraction: the menu-builder function name (`wAt` in the
current release) is pulled at build time via
`grep -oP "${tray_var}\.setContextMenu\(\K\w+(?=\(\))"`, so the patch
tracks minifier rename churn.

## Pitfalls to watch for

- **Relaunch window.** Clicking a different icon colour closes the
  app immediately (`app.exit(0)`) and asks it to reopen
  (`app.relaunch()`). Any unsaved in-process state in other windows
  is lost. In practice Claude Desktop persists its per-window state
  so this is invisible to users, but if we add more in-memory-only
  state in the future, revisit this.
- **Localisation.** The submenu labels are hardcoded English (`Icon
  color`, `Auto`, `Black`, `White`) — the same convention as every
  other patch in this tree. `he.formatMessage` would require wiring
  into Claude's i18n catalogue, which is out of scope here.
- **i18n-ID rename.** We anchor the injection on Claude Desktop's
  internal stringtable ID `dKX0bpR+a2` (Quit). If upstream rotates
  that ID the patch becomes a no-op and the build surfaces
  `[FAIL] Quit anchor not found`. Pull the latest IDs from
  `resources/i18n/en-US.json` in the same release and swap in the
  new one.
