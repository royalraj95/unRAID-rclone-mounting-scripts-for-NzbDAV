#!/usr/bin/env bats
# Smoke tests for Scripts/Array Stop Script (DUMB).

load helpers/setup
load helpers/asserts

setup() {
    init_mocks
    prepare_array_stop_script
}

@test "DUMB-2026 running: stops with 90s grace, then unmount and remaining-container teardown" {
    # Foundation reports running.
    echo "true" > "$MOCK_DIR/docker_inspect_DUMB-2026"
    # docker ps -q reports two stragglers.
    printf "abc123\ndef456\n" > "$MOCK_DIR/docker_ps"
    # Shared bind reports as a real mountpoint.
    key="mountpoint_$(echo "$BATS_TEST_TMPDIR/rshared" | tr '/' '_')"
    echo "yes" > "$MOCK_DIR/$key"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_called "sync"
    assert_called "docker stop -t 90 DUMB-2026"
    assert_called "umount -l $BATS_TEST_TMPDIR/rshared"
    assert_called "fusermount -uz $BATS_TEST_TMPDIR/rshared"
    # The remaining-container teardown passes both IDs to a single
    # `docker stop` invocation.
    assert_called "docker stop abc123 def456"
    assert_called "notify -e Server Status -s Shutdown Prepared"
}

@test "DUMB-2026 already stopped: skips graceful-stop, still does unmount + teardown" {
    echo "false" > "$MOCK_DIR/docker_inspect_DUMB-2026"
    : > "$MOCK_DIR/docker_ps"   # no remaining containers
    # Shared bind not mounted.

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_called "sync"
    assert_not_called "docker stop -t 90 DUMB-2026"
    assert_output_contains "INFO: $BATS_TEST_TMPDIR/rshared is not mounted. Skipping."
    assert_output_contains "INFO: No other containers running."
}
