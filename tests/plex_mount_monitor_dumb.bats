#!/usr/bin/env bats
# Smoke tests for Scripts/Plex Mount Monitor (DUMB).

load helpers/setup
load helpers/asserts

setup() {
    init_mocks
    prepare_plex_monitor_script
}

# is_mounted() probes a path with `find -mindepth 1` and considers it
# alive if anything is returned. Sandboxed dirs with a sentinel file
# satisfy that probe.
make_rd_mounted() {
    mkdir -p "$BATS_TEST_TMPDIR/rd_all"
    touch "$BATS_TEST_TMPDIR/rd_all/.alive"
}

make_rd_unmounted() {
    rm -rf "$BATS_TEST_TMPDIR/rd_all"
}

make_nzb_mounted() {
    mkdir -p "$BATS_TEST_TMPDIR/nzb"
    touch "$BATS_TEST_TMPDIR/nzb/.alive"
}

@test "both mounts up, no state change: no docker action" {
    make_rd_mounted
    make_nzb_mounted
    echo "up" > "$BATS_TEST_TMPDIR/plex_state"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_not_called "docker stop binhex-plex"
    assert_not_called "docker start binhex-plex"
    [ "$(cat "$BATS_TEST_TMPDIR/plex_state")" = "up" ]
}

@test "decypharr drops while previous=up: stop plex once, state→down" {
    make_rd_unmounted
    make_nzb_mounted
    echo "up" > "$BATS_TEST_TMPDIR/plex_state"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_called "docker stop binhex-plex" 1
    assert_called "notify -e DUMB Mount Monitor -s Plex Stopped"
    [ "$(cat "$BATS_TEST_TMPDIR/plex_state")" = "down" ]
}

@test "decypharr recovers from previous=down: start plex once, state→up" {
    make_rd_mounted
    make_nzb_mounted
    echo "down" > "$BATS_TEST_TMPDIR/plex_state"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_called "docker start binhex-plex" 1
    assert_called "notify -e DUMB Mount Monitor -s Plex Restored"
    [ "$(cat "$BATS_TEST_TMPDIR/plex_state")" = "up" ]
}
