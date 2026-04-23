'use strict';

// Unit tests for scripts/tray-icon-settings.js persistence and
// mode-to-bool mapping.
//
// Run with:  node --test tests/tray-icon-settings.test.js

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const TrayIconSettings = require(
  path.join(__dirname, '..', 'scripts', 'tray-icon-settings.js'),
);
const {
  VALID_MODES,
  DEFAULT_MODE,
  MODE_MIGRATIONS,
  modeToDark,
} = TrayIconSettings;

function mkTmp() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'tray-settings-'));
}

function cleanup(tmp) {
  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (_) {}
}

// ---------------------------------------------------------------
// modeToDark (label = icon colour, not theme)
// ---------------------------------------------------------------

test('modeToDark: white → true (white icon shown on dark panels)', () => {
  assert.equal(modeToDark('white'), true);
});

test('modeToDark: black → false (black icon shown on light panels)', () => {
  assert.equal(modeToDark('black'), false);
});

test('modeToDark: auto → null (caller falls back to nativeTheme)', () => {
  assert.equal(modeToDark('auto'), null);
});

test('modeToDark: unknown values → null', () => {
  assert.equal(modeToDark('invalid'), null);
  assert.equal(modeToDark(undefined), null);
  assert.equal(modeToDark(null), null);
  // Legacy names are intentionally NOT resolved by modeToDark — they
  // are migrated on load (see MODE_MIGRATIONS tests below).
  assert.equal(modeToDark('dark'), null);
  assert.equal(modeToDark('light'), null);
});

// ---------------------------------------------------------------
// VALID_MODES / DEFAULT_MODE / MODE_MIGRATIONS
// ---------------------------------------------------------------

test('VALID_MODES: matches submenu radios', () => {
  assert.deepEqual([...VALID_MODES], ['auto', 'black', 'white']);
});

test('DEFAULT_MODE: auto (preserves existing behaviour)', () => {
  assert.equal(DEFAULT_MODE, 'auto');
});

test('MODE_MIGRATIONS: old dark/light map to new icon-colour names', () => {
  // old "dark" meant "white icon" (meant for dark panels) → "white"
  // old "light" meant "black icon" (meant for light panels) → "black"
  assert.equal(MODE_MIGRATIONS.dark, 'white');
  assert.equal(MODE_MIGRATIONS.light, 'black');
});

// ---------------------------------------------------------------
// Initial load — no settings file yet
// ---------------------------------------------------------------

test('fresh instance with missing file returns DEFAULT_MODE', () => {
  const tmp = mkTmp();
  try {
    const s = new TrayIconSettings({
      path: path.join(tmp, 'absent.json'),
    });
    assert.equal(s.get(), DEFAULT_MODE);
  } finally { cleanup(tmp); }
});

test('fresh instance with corrupt JSON falls back to DEFAULT_MODE', () => {
  const tmp = mkTmp();
  try {
    const p = path.join(tmp, 'corrupt.json');
    fs.writeFileSync(p, '{ not valid JSON');
    const s = new TrayIconSettings({ path: p });
    assert.equal(s.get(), DEFAULT_MODE);
  } finally { cleanup(tmp); }
});

test('fresh instance with unknown mode falls back to DEFAULT_MODE', () => {
  const tmp = mkTmp();
  try {
    const p = path.join(tmp, 'garbage-mode.json');
    fs.writeFileSync(p, JSON.stringify({ iconMode: 'rainbow' }));
    const s = new TrayIconSettings({ path: p });
    assert.equal(s.get(), DEFAULT_MODE);
  } finally { cleanup(tmp); }
});

test('fresh instance loads saved mode', () => {
  const tmp = mkTmp();
  try {
    const p = path.join(tmp, 'persisted.json');
    fs.writeFileSync(p, JSON.stringify({ iconMode: 'black' }));
    const s = new TrayIconSettings({ path: p });
    assert.equal(s.get(), 'black');
  } finally { cleanup(tmp); }
});

test('fresh instance migrates legacy "dark" → "white" and rewrites file', () => {
  const tmp = mkTmp();
  try {
    const p = path.join(tmp, 'legacy-dark.json');
    fs.writeFileSync(p, JSON.stringify({ iconMode: 'dark' }));
    const s = new TrayIconSettings({ path: p });
    assert.equal(s.get(), 'white');
    // File should be rewritten with the new name.
    const disk = JSON.parse(fs.readFileSync(p, 'utf8'));
    assert.equal(disk.iconMode, 'white');
  } finally { cleanup(tmp); }
});

test('fresh instance migrates legacy "light" → "black" and rewrites file', () => {
  const tmp = mkTmp();
  try {
    const p = path.join(tmp, 'legacy-light.json');
    fs.writeFileSync(p, JSON.stringify({ iconMode: 'light' }));
    const s = new TrayIconSettings({ path: p });
    assert.equal(s.get(), 'black');
    const disk = JSON.parse(fs.readFileSync(p, 'utf8'));
    assert.equal(disk.iconMode, 'black');
  } finally { cleanup(tmp); }
});

// ---------------------------------------------------------------
// set()
// ---------------------------------------------------------------

test('set: persists value to disk', () => {
  const tmp = mkTmp();
  try {
    const p = path.join(tmp, 'persist.json');
    const s = new TrayIconSettings({ path: p });
    assert.equal(s.set('white'), true);
    const disk = JSON.parse(fs.readFileSync(p, 'utf8'));
    assert.equal(disk.iconMode, 'white');
  } finally { cleanup(tmp); }
});

test('set: creates parent directory if missing', () => {
  const tmp = mkTmp();
  try {
    const p = path.join(tmp, 'nested', 'deeper', 'tray.json');
    const s = new TrayIconSettings({ path: p });
    s.set('black');
    assert.ok(fs.existsSync(p));
  } finally { cleanup(tmp); }
});

test('set: rejects invalid values (returns false, no emit)', () => {
  const tmp = mkTmp();
  try {
    const s = new TrayIconSettings({
      path: path.join(tmp, 'reject.json'),
    });
    const events = [];
    s.on('change', (v) => events.push(v));
    assert.equal(s.set('not-a-mode'), false);
    assert.equal(s.get(), DEFAULT_MODE);
    assert.deepEqual(events, []);
  } finally { cleanup(tmp); }
});

test('set: duplicate value is a no-op (no change event, no write)', () => {
  const tmp = mkTmp();
  try {
    const p = path.join(tmp, 'dup.json');
    fs.writeFileSync(p, JSON.stringify({ iconMode: 'black' }));
    const s = new TrayIconSettings({ path: p });

    const mtimeBefore = fs.statSync(p).mtimeMs;
    const events = [];
    s.on('change', (v) => events.push(v));

    assert.equal(s.set('black'), false);
    assert.deepEqual(events, []);
    // File mtime unchanged (no rewrite)
    assert.equal(fs.statSync(p).mtimeMs, mtimeBefore);
  } finally { cleanup(tmp); }
});

test('set: emits change event with new value', () => {
  const tmp = mkTmp();
  try {
    const s = new TrayIconSettings({
      path: path.join(tmp, 'emit.json'),
    });
    const events = [];
    s.on('change', (v) => events.push(v));

    s.set('black');
    s.set('white');
    s.set('auto');

    assert.deepEqual(events, ['black', 'white', 'auto']);
  } finally { cleanup(tmp); }
});

// ---------------------------------------------------------------
// Round-trip across instances
// ---------------------------------------------------------------

test('round-trip: second instance sees the first instance\'s changes', () => {
  const tmp = mkTmp();
  try {
    const p = path.join(tmp, 'shared.json');
    const a = new TrayIconSettings({ path: p });
    a.set('white');

    const b = new TrayIconSettings({ path: p });
    assert.equal(b.get(), 'white');
  } finally { cleanup(tmp); }
});
