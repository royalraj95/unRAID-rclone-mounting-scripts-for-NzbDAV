#!/usr/bin/env bats
# Smoke tests for scripts/unraid/Plex Mount Monitor (DUMB).

load helpers/setup
load helpers/asserts

STATE() { echo "$BATS_TEST_TMPDIR/plex_state"; }

setup() {
    init_mocks
    prepare_plex_monitor_script
    mkdir -p "$BATS_TEST_TMPDIR/nzb/content"
}

nzb_up()   { mock_mountpoint "$BATS_TEST_TMPDIR/nzb" yes; }
nzb_down() { mock_mountpoint "$BATS_TEST_TMPDIR/nzb" no; }

@test "healthy mount, no prior state: Plex untouched, state up" {
    nzb_up

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_not_called "docker stop"
    assert_not_called "docker start"
    assert_not_called "docker restart"
    assert_state_key "$(STATE)" PLEX_STATE up
    assert_state_key "$(STATE)" FAIL_STREAK 0
}

@test "no Real-Debrid gate: Plex is not stopped when only NzbDAV exists" {
    # v1 stopped Plex whenever decypharr/realdebrid/__all__ was missing.
    nzb_up

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_not_called "docker stop binhex-plex"
    [[ "$output" != *"RD:"* ]]
}

@test "single failed probe is debounced: Plex keeps running" {
    nzb_down

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_not_called "docker stop"
    assert_state_key "$(STATE)" PLEX_STATE up
    assert_state_key "$(STATE)" FAIL_STREAK 1
}

@test "second consecutive failure stops Plex once" {
    nzb_down
    write_state "$(STATE)" "PLEX_STATE=up" "FAIL_STREAK=1"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_called "docker stop binhex-plex" 1
    assert_called "notify -e DUMB Mount Monitor -s Plex Stopped" 1
    assert_state_key "$(STATE)" PLEX_STATE down
}

@test "a recovered probe resets the streak" {
    nzb_up
    write_state "$(STATE)" "PLEX_STATE=up" "FAIL_STREAK=1"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_not_called "docker stop"
    assert_state_key "$(STATE)" FAIL_STREAK 0
}

@test "still down while Plex was started by hand: stop it again" {
    nzb_down
    write_state "$(STATE)" "PLEX_STATE=down" "FAIL_STREAK=3"
    echo "true" > "$MOCK_DIR/docker_inspect_binhex-plex"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_called "docker stop binhex-plex" 1
}

@test "recovery with Plex stopped: start it" {
    nzb_up
    write_state "$(STATE)" "PLEX_STATE=down" "FAIL_STREAK=4"
    echo "false" > "$MOCK_DIR/docker_inspect_binhex-plex"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_called "docker start binhex-plex" 1
    assert_not_called "docker restart"
    assert_called "notify -e DUMB Mount Monitor -s Plex Restored" 1
    assert_state_key "$(STATE)" PLEX_STATE up
}

@test "recovery with Plex already running: restart it to drop stale FUSE handles" {
    nzb_up
    write_state "$(STATE)" "PLEX_STATE=down" "FAIL_STREAK=4"
    echo "true" > "$MOCK_DIR/docker_inspect_binhex-plex"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_called "docker restart binhex-plex" 1
    assert_not_called "docker start"
}

@test "v1 state file (bare 'down') is ignored: no surprise Plex restart on upgrade" {
    nzb_up
    echo "down" > "$(STATE)"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_not_called "docker restart"
    assert_not_called "docker start"
    assert_state_key "$(STATE)" PLEX_STATE up
}
