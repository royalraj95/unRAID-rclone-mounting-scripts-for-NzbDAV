#!/usr/bin/env bats
# Smoke tests for Scripts/Symlink Cleanup (DUMB).
# Build a sandboxed library + indexed mount structure, plant broken or
# healthy symlinks, then assert on AUDIT_LOG entries, rm calls, and
# circuit-breaker behavior.

load helpers/setup
load helpers/asserts

setup() {
    init_mocks
    prepare_symlink_cleanup_script
    # Ground-truth pack the script's PACK_LIST will contain.
    mkdir -p "$BATS_TEST_TMPDIR/rshared/decypharr/realdebrid/__all__/ExistingPack"
    # Library tree at depth 3 (LIB_MIN/MAX matches show/season/file.mkv).
    mkdir -p "$BATS_TEST_TMPDIR/library/show1/season01"
    mkdir -p "$BATS_TEST_TMPDIR/library/show2/season01"
}

# Plant a symlink whose target points at the named pack inside the
# CONTAINER-side path (/mnt/debrid/decypharr/realdebrid/__all__/...).
# The script reads only the link string, never follows it.
plant_link() {
    local link="$1" pack="$2"
    ln -sf "/mnt/debrid/decypharr/realdebrid/__all__/$pack/file.mkv" "$link"
}

@test "DRY_RUN_GLOBAL=Y: broken symlink logged as MOCK, no rm fires" {
    plant_link "$BATS_TEST_TMPDIR/library/show1/season01/episode.mkv" MissingPack

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_not_called "rm"
    assert_not_called "curl"
    grep -q "^\[.*\] MOCK    \[Test\]:" "$BATS_TEST_TMPDIR/sentinel_audit.log"
    # Symlink must still be present (test it as a symlink — `-f` follows
    # the link and would return false on a broken target).
    [ -L "$BATS_TEST_TMPDIR/library/show1/season01/episode.mkv" ]
}

@test "per-library cap clamps deletion count below DELETES_PER_RUN" {
    # In LIVE mode, the per-library scan loop breaks at
    # MAX_BROKEN_BEFORE_HALT — even if more broken links exist and
    # DELETES_PER_RUN is higher. Verifies the in-memory damage cap.
    patch_var "$PREPARED_SCRIPT" DRY_RUN_GLOBAL N
    patch_var "$PREPARED_SCRIPT" MAX_BROKEN_BEFORE_HALT 2
    patch_var "$PREPARED_SCRIPT" DELETES_PER_RUN 10

    for i in 1 2 3 4 5; do
        mkdir -p "$BATS_TEST_TMPDIR/library/show$i/season01"
        plant_link "$BATS_TEST_TMPDIR/library/show$i/season01/episode.mkv" "Pack$i"
    done

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    # Only 2 candidates were collected, so only 2 curls fire (one per
    # delete: the *Arr API command). Plex refresh adds one more, but the
    # rm path also fires once per delete — that's 2 rm invocations.
    # Note: rm is real (not mocked), so we count via the symlink survivors.
    local survived=0
    for i in 1 2 3 4 5; do
        if [ -L "$BATS_TEST_TMPDIR/library/show$i/season01/episode.mkv" ]; then
            survived=$((survived + 1))
        fi
    done
    [ "$survived" -eq 3 ]
    assert_output_contains "Broken: 2"
}

@test "rolling 24h cap blocks deletion: stale tally is enforced" {
    patch_var "$PREPARED_SCRIPT" DRY_RUN_GLOBAL N
    patch_var "$PREPARED_SCRIPT" ROLLING_24H_LIMIT 2
    patch_var "$PREPARED_SCRIPT" DELETES_PER_RUN 10

    # Pre-load STATE_DB with 2 timestamps from 1 hour ago — at the cap.
    local now hour_ago
    now=$(date +%s)
    hour_ago=$((now - 3600))
    printf "%s\n%s\n" "$hour_ago" "$hour_ago" > "$BATS_TEST_TMPDIR/sentinel_state.db"

    plant_link "$BATS_TEST_TMPDIR/library/show1/season01/episode.mkv" MissingPack

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    # rm must NOT have been called for the broken link — cap blocked it.
    assert_not_called "curl"
    [ -L "$BATS_TEST_TMPDIR/library/show1/season01/episode.mkv" ]
}

@test "healthy library: no broken links, no rm, no curl" {
    plant_link "$BATS_TEST_TMPDIR/library/show1/season01/episode.mkv" ExistingPack

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_not_called "rm"
    assert_not_called "curl"
    # AUDIT_LOG should have no MOCK or DELETED entry from this run.
    if [ -s "$BATS_TEST_TMPDIR/sentinel_audit.log" ]; then
        ! grep -qE '^\[.*\] (MOCK|DELETED)' "$BATS_TEST_TMPDIR/sentinel_audit.log"
    fi
}
