#!/usr/bin/env bash
# Common setup loaded by every .bats file via `load helpers/setup`.
# Initializes the mock environment, PATH, and provides script-prep helpers.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/Scripts"
MOCKS_DIR="$BATS_TEST_DIRNAME/helpers/mocks"

# Each test gets its own MOCK_DIR (canned responses) and MOCK_CALL_LOG
# (every mock invocation appended). Tests assert on the call log; they
# pre-populate MOCK_DIR with response files (e.g. docker_inspect_X=false).
init_mocks() {
    export MOCK_DIR="$BATS_TEST_TMPDIR/mock"
    export MOCK_CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
    mkdir -p "$MOCK_DIR"
    : > "$MOCK_CALL_LOG"
    # Mocks must come first so they shadow real binaries.
    export PATH="$MOCKS_DIR:$PATH"
}

# Patch a hardcoded `KEY="value"` line at the top of $1 to a sandboxed
# value. Uses | as the sed delimiter so paths don't need escaping.
patch_var() {
    local script="$1" key="$2" value="$3"
    sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$script"
}

# Copy a script to a temp file and patch its hardcoded paths/vars to
# point inside $BATS_TEST_TMPDIR. Returns the patched-script path on
# stdout via $PREPARED_SCRIPT.
prepare_mount_script() {
    PREPARED_SCRIPT="$BATS_TEST_TMPDIR/mount_script"
    cp "$SCRIPTS_DIR/Mount Script (DUMB)" "$PREPARED_SCRIPT"
    patch_var "$PREPARED_SCRIPT" STATE_FILE       "$BATS_TEST_TMPDIR/prime_state.db"
    patch_var "$PREPARED_SCRIPT" LOG_FILE         "$BATS_TEST_TMPDIR/heartbeat.log"
    patch_var "$PREPARED_SCRIPT" NZB_MOUNT        "$BATS_TEST_TMPDIR/nzb"
    patch_var "$PREPARED_SCRIPT" DEC_MOUNT        "$BATS_TEST_TMPDIR/dec"
    patch_var "$PREPARED_SCRIPT" LOCAL_MEDIA_PATH "$BATS_TEST_TMPDIR/media"
    patch_var "$PREPARED_SCRIPT" RCLONE_CACHE_DIR "$BATS_TEST_TMPDIR/rclone-cache"
    # Rewrite the absolute notify path to the mock.
    sed -i "s|/usr/local/emhttp/webGui/scripts/notify|$MOCKS_DIR/notify|g" "$PREPARED_SCRIPT"
    mkdir -p "$BATS_TEST_TMPDIR/media"
}

prepare_plex_monitor_script() {
    PREPARED_SCRIPT="$BATS_TEST_TMPDIR/plex_monitor"
    cp "$SCRIPTS_DIR/Plex Mount Monitor (DUMB)" "$PREPARED_SCRIPT"
    patch_var "$PREPARED_SCRIPT" STATE_FILE     "$BATS_TEST_TMPDIR/plex_state"
    patch_var "$PREPARED_SCRIPT" LOG_FILE       "$BATS_TEST_TMPDIR/plex.log"
    patch_var "$PREPARED_SCRIPT" RD_MOUNT_PATH  "$BATS_TEST_TMPDIR/rd_all"
    patch_var "$PREPARED_SCRIPT" NZB_MOUNT_PATH "$BATS_TEST_TMPDIR/nzb"
    sed -i "s|/usr/local/emhttp/webGui/scripts/notify|$MOCKS_DIR/notify|g" "$PREPARED_SCRIPT"
}

prepare_array_stop_script() {
    PREPARED_SCRIPT="$BATS_TEST_TMPDIR/array_stop"
    cp "$SCRIPTS_DIR/Array Stop Script (DUMB)" "$PREPARED_SCRIPT"
    patch_var "$PREPARED_SCRIPT" LOG_FILE     "$BATS_TEST_TMPDIR/shutdown.log"
    patch_var "$PREPARED_SCRIPT" LOCK_DIR     "$BATS_TEST_TMPDIR/locks"
    patch_var "$PREPARED_SCRIPT" RSHARED_BIND "$BATS_TEST_TMPDIR/rshared"
    sed -i "s|/usr/local/emhttp/webGui/scripts/notify|$MOCKS_DIR/notify|g" "$PREPARED_SCRIPT"
    mkdir -p "$BATS_TEST_TMPDIR/locks"
}

prepare_symlink_cleanup_script() {
    PREPARED_SCRIPT="$BATS_TEST_TMPDIR/symlink_cleanup"
    cp "$SCRIPTS_DIR/Symlink Cleanup (DUMB)" "$PREPARED_SCRIPT"
    patch_var "$PREPARED_SCRIPT" STATE_DB             "$BATS_TEST_TMPDIR/sentinel_state.db"
    patch_var "$PREPARED_SCRIPT" AUDIT_LOG            "$BATS_TEST_TMPDIR/sentinel_audit.log"
    patch_var "$PREPARED_SCRIPT" HOLD_FILE            "$BATS_TEST_TMPDIR/SENTINEL_HOLD.txt"
    patch_var "$PREPARED_SCRIPT" PRIME_STATE          "$BATS_TEST_TMPDIR/prime_state.db"
    patch_var "$PREPARED_SCRIPT" RSHARED_HOST         "$BATS_TEST_TMPDIR/rshared"
    patch_var "$PREPARED_SCRIPT" RSHARED_CONTAINER    "/mnt/debrid"
    # Drop maturity gate and pack-sanity floor for tests.
    patch_var "$PREPARED_SCRIPT" UPTIME_MATURITY_REQUIRED 0
    patch_var "$PREPARED_SCRIPT" MIN_PACKS_SANITY    1
    # Replace the production LIBRARIES array with a single sandboxed
    # entry. Tests populate $BATS_TEST_TMPDIR/library with symlinks.
    awk -v lib="$BATS_TEST_TMPDIR/library" '
        /^LIBRARIES=\(/ {
            print
            print "    \"" lib "|Test|SONARR_HD|LIVE|PLEX|99|3|4\""
            skip=1; next
        }
        skip && /^\)/ { skip=0; print; next }
        skip { next }
        { print }
    ' "$PREPARED_SCRIPT" > "$PREPARED_SCRIPT.new"
    mv "$PREPARED_SCRIPT.new" "$PREPARED_SCRIPT"
    # Pre-create the indexed mount dirs the pre-scan touches.
    mkdir -p "$BATS_TEST_TMPDIR/rshared/decypharr/realdebrid/__all__"
    mkdir -p "$BATS_TEST_TMPDIR/rshared/nzbdav/completed-symlinks"
}

# Helper: write a state-file value (pre-existing state for the test).
write_state() {
    local file="$1"; shift
    : > "$file"
    for kv in "$@"; do
        echo "$kv" >> "$file"
    done
}

# Helper: read a single key from a state file (bash key=value format).
read_state_key() {
    local file="$1" key="$2"
    grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2- | tr -d '"'
}
