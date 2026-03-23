#!/usr/bin/env bats
#
# cowork-bwrap-config.bats
# Tests for configurable bwrap mount points (issue #339)
#

NODE_PREAMBLE='
const path = require("path");
const os = require("os");
const fs = require("fs");

function log() {}

// --- Functions under test ---

const FORBIDDEN_MOUNT_PATHS = new Set(["/", "/proc", "/dev", "/sys"]);

function validateMountPath(mountPath, opts) {
    opts = opts || {};
    if (!mountPath || !path.isAbsolute(mountPath)) {
        return { valid: false, reason: "Path must be absolute" };
    }

    const normalized = path.resolve(mountPath);

    if (FORBIDDEN_MOUNT_PATHS.has(normalized)) {
        return { valid: false, reason: "Path is forbidden: " + normalized };
    }

    for (const forbidden of FORBIDDEN_MOUNT_PATHS) {
        if (forbidden !== "/" && normalized.startsWith(forbidden + "/")) {
            return { valid: false, reason: "Path is under forbidden path: " + forbidden };
        }
    }

    if (opts.readWrite) {
        const home = os.homedir();
        if (normalized !== home && !normalized.startsWith(home + "/")) {
            return { valid: false, reason: "Read-write mounts must be under $HOME" };
        }
    }

    return { valid: true };
}

function loadBwrapMountsConfig(configPath, logFn) {
    const warn = logFn || log;
    const empty = {
        additionalROBinds: [],
        additionalBinds: [],
        disabledDefaultBinds: [],
    };

    if (!configPath) {
        configPath = path.join(
            process.env.HOME || os.homedir(),
            ".config", "Claude", "claude_desktop_linux_config.json"
        );
    }

    let raw;
    try {
        raw = JSON.parse(fs.readFileSync(configPath, "utf8"));
    } catch (_) {
        return empty;
    }

    const mounts = raw && raw.preferences && raw.preferences.coworkBwrapMounts;
    if (!mounts || typeof mounts !== "object") {
        return empty;
    }

    function filterPaths(arr, readWrite) {
        if (!Array.isArray(arr)) return [];
        return arr.filter(function(p) {
            if (typeof p !== "string") return false;
            const result = validateMountPath(p, { readWrite: readWrite });
            if (!result.valid) {
                warn("BwrapConfig: rejected path \"" + p + "\": " + result.reason);
            }
            return result.valid;
        });
    }

    return {
        additionalROBinds: filterPaths(mounts.additionalROBinds, false),
        additionalBinds: filterPaths(mounts.additionalBinds, true),
        disabledDefaultBinds: Array.isArray(mounts.disabledDefaultBinds)
            ? mounts.disabledDefaultBinds.filter(function(p) { return typeof p === "string"; })
            : [],
    };
}

function loadBwrapMountsConfigWithLog(configPath, logFn) {
    return loadBwrapMountsConfig(configPath, logFn);
}

const CRITICAL_MOUNTS = new Set(["/", "/dev", "/proc"]);

function mergeBwrapArgs(defaultArgs, config) {
    const result = [];
    const disabled = new Set(
        config.disabledDefaultBinds.filter(function(p) { return !CRITICAL_MOUNTS.has(p); })
    );

    const TWO_ARG_FLAGS = new Set(["--tmpfs", "--dev", "--proc", "--dir"]);
    const THREE_ARG_FLAGS = new Set(["--ro-bind", "--bind", "--symlink"]);

    let i = 0;
    while (i < defaultArgs.length) {
        const flag = defaultArgs[i];

        if (THREE_ARG_FLAGS.has(flag) && i + 2 < defaultArgs.length) {
            const dest = defaultArgs[i + 2];
            if (disabled.has(dest)) {
                i += 3;
                continue;
            }
            result.push(defaultArgs[i], defaultArgs[i + 1], defaultArgs[i + 2]);
            i += 3;
        } else if (TWO_ARG_FLAGS.has(flag) && i + 1 < defaultArgs.length) {
            const dest = defaultArgs[i + 1];
            if (disabled.has(dest)) {
                i += 2;
                continue;
            }
            result.push(defaultArgs[i], defaultArgs[i + 1]);
            i += 2;
        } else {
            result.push(defaultArgs[i]);
            i++;
        }
    }

    for (const p of config.additionalROBinds) {
        result.push("--ro-bind", p, p);
    }
    for (const p of config.additionalBinds) {
        result.push("--bind", p, p);
    }

    return result;
}

// Helper assertions
function assert(condition, msg) {
    if (!condition) {
        process.stderr.write("ASSERTION FAILED: " + msg + "\n");
        process.exit(1);
    }
}

function assertEqual(actual, expected, msg) {
    assert(actual === expected,
        msg + " expected=" + JSON.stringify(expected) +
        " actual=" + JSON.stringify(actual));
}

function assertDeepEqual(actual, expected, msg) {
    const a = JSON.stringify(actual);
    const e = JSON.stringify(expected);
    assert(a === e, msg + " expected=" + e + " actual=" + a);
}
'

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# validateMountPath
# =============================================================================

@test "validateMountPath: rejects non-absolute paths" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('relative/path');
assertDeepEqual(result, { valid: false, reason: 'Path must be absolute' }, 'relative');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects forbidden path /" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/');
assertDeepEqual(result, { valid: false, reason: 'Path is forbidden: /' }, 'root');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects forbidden path /proc" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/proc');
assertDeepEqual(result, { valid: false, reason: 'Path is forbidden: /proc' }, 'proc');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects forbidden path /dev" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/dev');
assertDeepEqual(result, { valid: false, reason: 'Path is forbidden: /dev' }, 'dev');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects forbidden path /sys" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/sys');
assertDeepEqual(result, { valid: false, reason: 'Path is forbidden: /sys' }, 'sys');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects subpaths of forbidden paths" {
	run node -e "${NODE_PREAMBLE}
const r1 = validateMountPath('/proc/self');
assertDeepEqual(r1, { valid: false, reason: 'Path is under forbidden path: /proc' }, 'proc/self');
const r2 = validateMountPath('/dev/shm');
assertDeepEqual(r2, { valid: false, reason: 'Path is under forbidden path: /dev' }, 'dev/shm');
const r3 = validateMountPath('/sys/class');
assertDeepEqual(r3, { valid: false, reason: 'Path is under forbidden path: /sys' }, 'sys/class');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects RW paths outside HOME" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/opt/tools', { readWrite: true });
assertDeepEqual(result,
    { valid: false, reason: 'Read-write mounts must be under \$HOME' },
    'rw outside home');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: accepts RW paths under HOME" {
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const result = validateMountPath(home + '/projects/data', { readWrite: true });
assertDeepEqual(result, { valid: true }, 'rw under home');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: accepts RO paths anywhere (not forbidden)" {
	run node -e "${NODE_PREAMBLE}
const r1 = validateMountPath('/opt/my-tools');
assertDeepEqual(r1, { valid: true }, 'opt ro');
const r2 = validateMountPath('/nix/store');
assertDeepEqual(r2, { valid: true }, 'nix ro');
const r3 = validateMountPath('/media/shared');
assertDeepEqual(r3, { valid: true }, 'media ro');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: rejects empty string" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('');
assertDeepEqual(result, { valid: false, reason: 'Path must be absolute' }, 'empty');
"
	[[ "$status" -eq 0 ]]
}

@test "validateMountPath: normalizes path before checking" {
	run node -e "${NODE_PREAMBLE}
const result = validateMountPath('/opt/../proc');
assertDeepEqual(result, { valid: false, reason: 'Path is forbidden: /proc' }, 'traversal to proc');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# loadBwrapMountsConfig
# =============================================================================

@test "loadBwrapMountsConfig: returns empty config when file does not exist" {
	run node -e "${NODE_PREAMBLE}
const result = loadBwrapMountsConfig('/nonexistent/path/config.json');
assertDeepEqual(result, {
    additionalROBinds: [],
    additionalBinds: [],
    disabledDefaultBinds: []
}, 'missing file');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: returns empty config when JSON has no preferences" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({ mcpServers: {} }));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result, {
    additionalROBinds: [],
    additionalBinds: [],
    disabledDefaultBinds: []
}, 'no preferences');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: returns empty config when coworkBwrapMounts is absent" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({ preferences: {} }));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result, {
    additionalROBinds: [],
    additionalBinds: [],
    disabledDefaultBinds: []
}, 'no coworkBwrapMounts');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: parses valid configuration" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: ['/opt/tools', '/nix/store'],
            additionalBinds: [os.homedir() + '/shared-data'],
            disabledDefaultBinds: ['/etc']
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result, {
    additionalROBinds: ['/opt/tools', '/nix/store'],
    additionalBinds: [os.homedir() + '/shared-data'],
    disabledDefaultBinds: ['/etc']
}, 'valid config');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: returns empty config on invalid JSON" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, '{ invalid json }');
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result, {
    additionalROBinds: [],
    additionalBinds: [],
    disabledDefaultBinds: []
}, 'invalid json');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: filters out invalid paths from additionalROBinds" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: ['/opt/tools', '/proc', 'relative', '/dev', '/nix/store']
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalROBinds, ['/opt/tools', '/nix/store'],
    'filtered ro binds');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: filters out RW paths outside HOME" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
const home = os.homedir();
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalBinds: [home + '/valid', '/opt/invalid', home + '/also-valid']
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalBinds, [home + '/valid', home + '/also-valid'],
    'filtered rw binds');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: ignores non-array values" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: 'not-an-array',
            additionalBinds: 42,
            disabledDefaultBinds: { bad: true }
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result, {
    additionalROBinds: [],
    additionalBinds: [],
    disabledDefaultBinds: []
}, 'non-array values');
"
	[[ "$status" -eq 0 ]]
}

@test "loadBwrapMountsConfig: filters non-string entries from arrays" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: ['/opt/tools', 42, null, '/nix/store', true]
        }
    }
}));
const result = loadBwrapMountsConfig(configPath);
assertDeepEqual(result.additionalROBinds, ['/opt/tools', '/nix/store'],
    'non-string entries filtered');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# mergeBwrapArgs — disabled default binds
# =============================================================================

@test "mergeBwrapArgs: returns default args when config is empty" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr', '--ro-bind', '/etc', '/etc',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [], additionalBinds: [], disabledDefaultBinds: []
});
assertDeepEqual(result, defaults, 'unchanged');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: removes disabled default ro-bind" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr', '--ro-bind', '/etc', '/etc',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [], additionalBinds: [], disabledDefaultBinds: ['/etc']
});
const expected = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
assertDeepEqual(result, expected, 'etc removed');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: refuses to disable --tmpfs /, --dev /dev, --proc /proc" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [], additionalBinds: [],
    disabledDefaultBinds: ['/', '/dev', '/proc']
});
assertDeepEqual(result, defaults, 'critical mounts preserved');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: can disable /tmp and /run" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [], additionalBinds: [],
    disabledDefaultBinds: ['/tmp', '/run']
});
const expected = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc'];
assertDeepEqual(result, expected, 'tmp and run removed');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: appends additional RO binds" {
	run node -e "${NODE_PREAMBLE}
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: ['/opt/tools', '/nix/store'],
    additionalBinds: [],
    disabledDefaultBinds: []
});
const expected = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--ro-bind', '/opt/tools', '/opt/tools',
    '--ro-bind', '/nix/store', '/nix/store'];
assertDeepEqual(result, expected, 'ro appended');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: appends additional RW binds" {
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: [],
    additionalBinds: [home + '/data'],
    disabledDefaultBinds: []
});
const expected = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--bind', home + '/data', home + '/data'];
assertDeepEqual(result, expected, 'rw appended');
"
	[[ "$status" -eq 0 ]]
}

@test "mergeBwrapArgs: combined disable + add" {
	run node -e "${NODE_PREAMBLE}
const home = os.homedir();
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr', '--ro-bind', '/etc', '/etc',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run'];
const result = mergeBwrapArgs(defaults, {
    additionalROBinds: ['/opt/tools'],
    additionalBinds: [home + '/shared'],
    disabledDefaultBinds: ['/etc']
});
const expected = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp', '--tmpfs', '/run',
    '--ro-bind', '/opt/tools', '/opt/tools',
    '--bind', home + '/shared', home + '/shared'];
assertDeepEqual(result, expected, 'combined');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# buildBwrapArgsWithConfig (integration)
# =============================================================================

@test "buildBwrapArgsWithConfig: includes user mounts in final args" {
	run node -e "${NODE_PREAMBLE}
const configPath = '${TEST_TMP}/config.json';
const home = os.homedir();
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: ['/opt/my-sdk'],
            additionalBinds: [home + '/workspace'],
            disabledDefaultBinds: []
        }
    }
}));
const config = loadBwrapMountsConfig(configPath);
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr',
    '--dev', '/dev', '--proc', '/proc'];
const result = mergeBwrapArgs(defaults, config);

const roIdx = result.indexOf('--ro-bind', result.indexOf('/usr') + 1);
assertEqual(result[roIdx + 1], '/opt/my-sdk', 'ro-bind src');
assertEqual(result[roIdx + 2], '/opt/my-sdk', 'ro-bind dest');

const rwIdx = result.indexOf('--bind');
assertEqual(result[rwIdx + 1], home + '/workspace', 'bind src');
assertEqual(result[rwIdx + 2], home + '/workspace', 'bind dest');
"
	[[ "$status" -eq 0 ]]
}

@test "buildBwrapArgsWithConfig: user RO mounts come before session mounts" {
	run node -e "${NODE_PREAMBLE}
const config = {
    additionalROBinds: ['/opt/tools'],
    additionalBinds: [],
    disabledDefaultBinds: []
};
const defaults = ['--tmpfs', '/', '--ro-bind', '/usr', '/usr'];
const merged = mergeBwrapArgs(defaults, config);

const fullArgs = [...merged, '--bind', '/home/user/project', '/sessions/s/mnt/project',
    '--unshare-pid', '--die-with-parent', '--new-session'];

const optIdx = fullArgs.indexOf('/opt/tools');
const sessionBindIdx = fullArgs.indexOf('--bind');
assert(optIdx < sessionBindIdx,
    'user RO mount (' + optIdx + ') before session bind (' + sessionBindIdx + ')');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# loadBwrapMountsConfig: logging
# =============================================================================

@test "loadBwrapMountsConfig: logs rejected paths" {
	run node -e "${NODE_PREAMBLE}
const warnings = [];
function logWarn() { warnings.push(Array.from(arguments).join(' ')); }

const configPath = '${TEST_TMP}/config.json';
fs.writeFileSync(configPath, JSON.stringify({
    preferences: {
        coworkBwrapMounts: {
            additionalROBinds: ['/proc', '/opt/ok'],
            additionalBinds: ['/outside/home']
        }
    }
}));
const result = loadBwrapMountsConfigWithLog(configPath, logWarn);
assertEqual(result.additionalROBinds.length, 1, 'one valid ro');
assertEqual(warnings.length, 2, 'two warnings logged');
assert(warnings[0].includes('/proc'), 'warns about /proc');
assert(warnings[1].includes('/outside/home'), 'warns about rw outside home');
"
	[[ "$status" -eq 0 ]]
}

# =============================================================================
# --doctor integration (bash)
# =============================================================================

@test "doctor: reports custom bwrap mounts" {
	mkdir -p "${TEST_TMP}/.config/Claude"
	local home_tmp="${TEST_TMP}"
	local config_file="${TEST_TMP}/.config/Claude/claude_desktop_linux_config.json"
	cat > "$config_file" <<-ENDJSON
	{
	    "preferences": {
	        "coworkBwrapMounts": {
	            "additionalROBinds": ["/opt/tools"],
	            "additionalBinds": ["${home_tmp}/data"],
	            "disabledDefaultBinds": ["/etc"]
	        }
	    }
	}
	ENDJSON

	# Source launcher-common.sh and run the doctor check function
	# shellcheck source=scripts/launcher-common.sh
	source "scripts/launcher-common.sh"
	# Override HOME for config path resolution
	HOME="${TEST_TMP}" run _doctor_check_bwrap_mounts
	[[ "$output" == *"/opt/tools"* ]]
	[[ "$output" == *"data"* ]]
	[[ "$output" == *"/etc"* ]]
	[[ "$output" == *"WARN"* ]]
}

@test "doctor: warns about disabled critical mount /usr" {
	mkdir -p "${TEST_TMP}/.config/Claude"
	local config_file="${TEST_TMP}/.config/Claude/claude_desktop_linux_config.json"
	cat > "$config_file" <<-ENDJSON
	{
	    "preferences": {
	        "coworkBwrapMounts": {
	            "disabledDefaultBinds": ["/usr"]
	        }
	    }
	}
	ENDJSON

	# shellcheck source=scripts/launcher-common.sh
	source "scripts/launcher-common.sh"
	HOME="${TEST_TMP}" run _doctor_check_bwrap_mounts
	[[ "$output" == *"WARN"* ]]
	[[ "$output" == *"/usr"* ]]
}

@test "doctor: no output when no custom mounts configured" {
	mkdir -p "${TEST_TMP}/.config/Claude"
	local config_file="${TEST_TMP}/.config/Claude/claude_desktop_linux_config.json"
	echo '{}' > "$config_file"

	# shellcheck source=scripts/launcher-common.sh
	source "scripts/launcher-common.sh"
	HOME="${TEST_TMP}" run _doctor_check_bwrap_mounts
	# Should just show info that no custom mounts are configured
	[[ "$output" != *"FAIL"* ]]
}
