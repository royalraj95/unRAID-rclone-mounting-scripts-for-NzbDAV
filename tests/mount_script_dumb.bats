#!/usr/bin/env bats
# Smoke tests for scripts/unraid/Mount Script (DUMB) — the NzbDAV Heartbeat.
# Each test runs the real script with PATH-mocked docker/curl/sleep/notify/date/
# mountpoint, a sandboxed mount path, and asserts on the state file + call log.

load helpers/setup
load helpers/asserts

STATE() { echo "$BATS_TEST_TMPDIR/prime_state.db"; }

setup() {
    init_mocks
    prepare_mount_script
    export MOCK_NOW=1700000000
    mkdir -p "$BATS_TEST_TMPDIR/nzb/completed-symlinks"
}

nzb_up()   { mock_mountpoint "$BATS_TEST_TMPDIR/nzb" yes; }
nzb_down() { mock_mountpoint "$BATS_TEST_TMPDIR/nzb" no; }

# Mount reads "no" for the initial probe attempts, then "yes" for good.
nzb_down_then_up() {
    nzb_up
    local seq="$MOCK_DIR/mountpoint_$(echo "$BATS_TEST_TMPDIR/nzb" | tr '/' '_').seq"
    printf 'no\nno\nno\n' > "$seq"
}

enable_api() {
    patch_var "$PREPARED_SCRIPT" DUMB_API_USERNAME "admin"
    patch_var "$PREPARED_SCRIPT" DUMB_API_PASSWORD "secret"
    echo '{"access_token":"tok123","refresh_token":"r","token_type":"bearer"}' > "$MOCK_DIR/login.json"
    printf 'auth/login\t200\t%s\nrestart-service\t200\t\n' "$MOCK_DIR/login.json" > "$MOCK_DIR/curl_rules"
}

@test "happy path: mount up, no recovery, state UP with zero failures" {
    nzb_up

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_not_called "docker restart"
    assert_not_called "docker stop"
    assert_not_called "restart-service"
    assert_state_key "$(STATE)" N_FAIL_COUNT 0
    assert_state_key "$(STATE)" NZB_STATE UP
    assert_output_contains "Passed: NzbDAV is UP"
}

@test "no Decypharr: a v1 state file with Decypharr keys is read and dropped" {
    nzb_up
    write_state "$(STATE)" "D_FAIL_COUNT=4" 'DEC_STATE="DOWN"' "TOTAL_LMP_PRIMED=500938" 'NZB_STATE="UP"'

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_not_called "docker restart"
    ! grep -q 'D_FAIL_COUNT\|DEC_STATE\|TOTAL_LMP_PRIMED' "$(STATE)"
}

@test "mount down, no API credentials: container restart, failure counted" {
    nzb_down

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 1 ]

    assert_called "docker restart DUMB-2026" 1
    assert_not_called "auth/login"
    assert_state_key "$(STATE)" N_FAIL_COUNT 1
    assert_state_key "$(STATE)" NZB_STATE DOWN
    assert_state_key "$(STATE)" LAST_RECOVERY_ACTION container
    assert_state_key "$(STATE)" FOUNDATION_LAST_RESTART_TS "$MOCK_NOW"
    assert_called "notify -e Rclone Heartbeat -s Mount Down" 2
}

@test "mount comes back after container restart: failures reset, state UP" {
    nzb_down_then_up
    write_state "$(STATE)" "N_FAIL_COUNT=2" 'NZB_STATE="DOWN"'

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_called "docker restart DUMB-2026" 1
    assert_state_key "$(STATE)" N_FAIL_COUNT 0
    assert_state_key "$(STATE)" NZB_STATE UP
    assert_called "notify -e Rclone Heartbeat -s Mount Restored" 1
}

@test "container cooldown: recent restart blocks another, failure not counted" {
    nzb_down
    write_state "$(STATE)" "FOUNDATION_LAST_RESTART_TS=$((MOCK_NOW - 300))" "N_FAIL_COUNT=2"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 1 ]

    assert_not_called "docker restart"
    assert_state_key "$(STATE)" N_FAIL_COUNT 2
    assert_output_contains "COOLDOWN"
}

@test "API rung 1: first failure restarts only the rclone process" {
    nzb_down_then_up
    enable_api

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_called "auth/login" 1
    assert_called '"process_name":"rclone w/ InfiniDysk"' 1
    assert_called '"process_name":"InfiniDysk"' 0
    assert_called "Authorization: Bearer tok123" 1
    assert_not_called "docker restart"
    assert_state_key "$(STATE)" N_FAIL_COUNT 0
}

@test "API rung 2: second failure restarts InfiniDysk then rclone" {
    nzb_down
    enable_api
    write_state "$(STATE)" "N_FAIL_COUNT=1" 'NZB_STATE="DOWN"'

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 1 ]

    assert_called '"process_name":"InfiniDysk"' 1
    assert_called '"process_name":"rclone w/ InfiniDysk"' 1
    # InfiniDysk must be restarted before rclone.
    grep -n 'restart-service' "$MOCK_CALL_LOG" | head -1 | grep -q '"process_name":"InfiniDysk"'
    assert_not_called "docker restart"
    assert_state_key "$(STATE)" N_FAIL_COUNT 2
    assert_state_key "$(STATE)" LAST_RECOVERY_ACTION infinidysk
}

@test "API rung 3: third failure escalates to a container restart" {
    nzb_down
    enable_api
    write_state "$(STATE)" "N_FAIL_COUNT=2" 'NZB_STATE="DOWN"'

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 1 ]

    assert_not_called "restart-service"
    assert_called "docker restart DUMB-2026" 1
    assert_state_key "$(STATE)" N_FAIL_COUNT 3
}

@test "API login failure falls back to a container restart" {
    nzb_down
    patch_var "$PREPARED_SCRIPT" DUMB_API_USERNAME "admin"
    patch_var "$PREPARED_SCRIPT" DUMB_API_PASSWORD "wrong"
    printf 'auth/login\t401\t\n' > "$MOCK_DIR/curl_rules"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 1 ]

    assert_called "auth/login" 1
    assert_not_called "restart-service"
    assert_called "docker restart DUMB-2026" 1
    assert_output_contains "login to"
}

@test "dead backend with a live mount skips straight to restarting InfiniDysk" {
    nzb_up
    enable_api
    patch_var "$PREPARED_SCRIPT" NZB_WEBDAV_URL "http://127.0.0.1:8089/"
    printf '127.0.0.1:8089\t000\t\nauth/login\t200\t%s\nrestart-service\t200\t\n' "$MOCK_DIR/login.json" > "$MOCK_DIR/curl_rules"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 1 ]

    assert_called '"process_name":"InfiniDysk"' 1
    assert_output_contains "backend=false"
}

@test "MAX_FAILURES reached: hard reset stops and starts the container, counter resets" {
    nzb_down
    write_state "$(STATE)" "N_FAIL_COUNT=5" "FOUNDATION_LAST_RESTART_TS=$((MOCK_NOW - 1000))"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 1 ]

    assert_called "docker stop DUMB-2026" 1
    assert_called "docker start DUMB-2026" 1
    assert_not_called "docker restart"
    assert_state_key "$(STATE)" N_FAIL_COUNT 0
    assert_state_key "$(STATE)" LAST_RECOVERY_ACTION hard-reset
    # Automatic hard reset never wipes the cache.
    assert_output_contains "HARD RESET"
    [[ "$output" != *"Wiping rclone VFS cache"* ]]
}

@test "foundation cold start anchors the cooldown: no second restart in the same run" {
    nzb_down
    printf 'false\ntrue\n' > "$MOCK_DIR/docker_inspect_DUMB-2026.seq"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 1 ]

    assert_called "docker start DUMB-2026" 1
    assert_not_called "docker restart"
    assert_state_key "$(STATE)" FOUNDATION_LAST_RESTART_TS "$MOCK_NOW"
    assert_output_contains "COOLDOWN"
}

@test "backup in progress: run is skipped entirely" {
    nzb_down
    touch "$BATS_TEST_TMPDIR/pause"
    patch_var "$PREPARED_SCRIPT" BACKUP_PAUSE_FILE "$BATS_TEST_TMPDIR/pause"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_not_called "docker"
    assert_output_contains "[PAUSED]"
}
