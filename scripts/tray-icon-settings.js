'use strict';

// Persists the Linux tray-icon colour choice to
// ~/.config/Claude/linux-tray.json as {iconMode: "auto"|"black"|"white"}.
// Default "auto" preserves pre-existing behaviour (Electron picks).
// See docs/learnings/tray-icon-theme.md for the why.

const EventEmitter = require('events');
const fs = require('fs');
const os = require('os');
const path = require('path');

const VALID_MODES = Object.freeze(['auto', 'black', 'white']);
const DEFAULT_MODE = 'auto';

// Legacy names from the first iteration: map old → new on load.
const MODE_MIGRATIONS = Object.freeze({
  dark: 'white',   // old "dark"  meant white icon (for dark panels)
  light: 'black',  // old "light" meant black icon (for light panels)
});

const SETTINGS_FILE = path.join(
  os.homedir(), '.config', 'Claude', 'linux-tray.json',
);

class TrayIconSettings extends EventEmitter {
  constructor(options) {
    super();
    const opts = options || {};
    this._path = opts.path || SETTINGS_FILE;
    this._mode = this._load();
  }

  get() {
    return this._mode;
  }

  // No-op and returns false when mode is invalid or already set.
  set(mode) {
    if (!VALID_MODES.includes(mode)) {
      console.warn('[Tray Icon] Rejecting invalid mode:', mode);
      return false;
    }
    if (mode === this._mode) return false;
    this._mode = mode;
    this._save();
    this.emit('change', mode);
    return true;
  }

  _load() {
    let raw;
    try {
      raw = fs.readFileSync(this._path, 'utf8');
    } catch (e) {
      // ENOENT on first launch is the common path — silent.
      if (e && e.code !== 'ENOENT') {
        console.warn('[Tray Icon] Read failed:', e.message);
      }
      return DEFAULT_MODE;
    }
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (e) {
      console.warn('[Tray Icon] Parse failed:', e.message);
      return DEFAULT_MODE;
    }

    const stored = parsed && parsed.iconMode;
    const migrated = MODE_MIGRATIONS[stored] || stored;
    if (!VALID_MODES.includes(migrated)) return DEFAULT_MODE;

    // Write back in the new format so subsequent reads are clean.
    if (migrated !== stored) {
      this._mode = migrated;
      this._save();
    }
    return migrated;
  }

  _save() {
    try {
      fs.mkdirSync(path.dirname(this._path), { recursive: true });
      fs.writeFileSync(
        this._path,
        JSON.stringify({ iconMode: this._mode }, null, 2) + '\n',
        'utf8',
      );
    } catch (e) {
      console.warn('[Tray Icon] Write failed:', e.message);
    }
  }
}

// Mode → shouldUseDarkColors. Null means "let caller fall through to
// Electron's native value". Names describe the icon's colour.
function modeToDark(mode) {
  if (mode === 'white') return true;
  if (mode === 'black') return false;
  return null;
}

module.exports = TrayIconSettings;
module.exports.VALID_MODES = VALID_MODES;
module.exports.DEFAULT_MODE = DEFAULT_MODE;
module.exports.MODE_MIGRATIONS = MODE_MIGRATIONS;
module.exports.modeToDark = modeToDark;
module.exports.SETTINGS_FILE = SETTINGS_FILE;
