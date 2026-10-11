#!/usr/bin/env bats
# Smoke tests for scripts/unraid/Symlink Cleanup (DUMB) — the Sentinel.
# The library is a sandboxed TV tree of symlinks; InfiniDysk's database is a
# throwaway sqlite file with just DavItems.Id.

load helpers/setup
load helpers/asserts

LIB()   { echo "$BATS_TEST_TMPDIR/media/library"; }
AUDIT() { echo "$BATS_TEST_TMPDIR/sentinel_audit.log"; }

setup() {
    init_mocks
    prepare_symlink_cleanup_script
    # Test dumb.conf: Sonarr + Plex credentials for the Test library.
    cat > "$BATS_TEST_TMPDIR/dumb.conf" <<'EOF'
SONARR_HD_URL="http://sonarr.test"
SONARR_HD_API="sonarr-key"
PLEX_URL="http://plex.test"
PLEX_TOKEN="plex-token"
EOF
    export DUMB_CONF="$BATS_TEST_TMPDIR/dumb.conf"
}

# Insert InfiniDysk items. The DB stores ids upper-case, like .NET does.
add_items() {
    local id
    for id in "$@"; do
        sqlite3 "$BATS_TEST_TMPDIR/db.sqlite" "INSERT INTO DavItems VALUES ('$(echo "$id" | tr 'a-f' 'A-F')');"
    done
}

# plant_ids_link <show> <uuid> — Show/Season 01/<uuid>.mkv → .ids/<prefix>/<uuid>
plant_ids_link() {
    local dir
    dir="$(LIB)/$1/Season 01"
    mkdir -p "$dir"
    ln -s "/mnt/debrid/nzbdav/.ids/${2:0:1}/${2:1:1}/${2:2:1}/${2:3:1}/${2:4:1}/$2" "$dir/$2.mkv"
}

UUID_A="aaaa1111-0000-0000-0000-000000000001"
UUID_B="bbbb2222-0000-0000-0000-000000000002"
UUID_C="cccc3333-0000-0000-0000-000000000003"

@test "healthy library: every link's id exists, nothing flagged or called" {
    add_items "$UUID_A"
    plant_ids_link Show1 "$UUID_A"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_not_called "curl"
    ! grep -qE '(MOCK|DELETED)' "$(AUDIT)"
    assert_output_contains "Broken: 0"
}

@test "dry run: missing id is logged as MOCK, link survives, no API calls" {
    add_items "$UUID_A"
    plant_ids_link Show1 "$UUID_A"
    plant_ids_link Show2 "$UUID_B"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    grep -q "MOCK    \[Test\] (missing-id:$UUID_B)" "$(AUDIT)"
    [ -L "$(LIB)/Show2/Season 01/$UUID_B.mkv" ]
    assert_not_called "curl"
}

@test "live: broken link deleted, Plex scans only that show's folder" {
    patch_var "$PREPARED_SCRIPT" DRY_RUN_GLOBAL N
    add_items "$UUID_A"
    plant_ids_link Show1 "$UUID_A"
    plant_ids_link Show2 "$UUID_B"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    [ ! -e "$(LIB)/Show2/Season 01/$UUID_B.mkv" ]
    [ -L "$(LIB)/Show1/Season 01/$UUID_A.mkv" ]
    grep -q "DELETED \[Test\]" "$(AUDIT)"
    assert_called "http://plex.test/library/sections/99/refresh" 1
    assert_called "path=/data/media/library/Show2" 1
}

@test "live with jq: targeted RescanSeries + SeriesSearch for the matched series" {
    command -v jq > /dev/null || skip "jq not installed"
    patch_var "$PREPARED_SCRIPT" DRY_RUN_GLOBAL N
    plant_ids_link Show2 "$UUID_B"
    add_items "$UUID_A"
    echo '[{"id":7,"path":"/data/media/library/Show1"},{"id":42,"path":"/data/media/library/Show2"}]' > "$MOCK_DIR/series.json"
    printf 'api/v3/series\t200\t%s\n' "$MOCK_DIR/series.json" > "$MOCK_DIR/curl_rules"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_called '{"name":"RescanSeries","seriesId":42}' 1
    assert_called '{"name":"SeriesSearch","seriesId":42}' 1
    assert_called "X-Api-Key: sonarr-key" 3
}

@test "live, series not found in the *Arr: one library-wide rescan, no search" {
    patch_var "$PREPARED_SCRIPT" DRY_RUN_GLOBAL N
    add_items "$UUID_A"
    plant_ids_link Show2 "$UUID_B"
    plant_ids_link Show3 "$UUID_C"
    echo '[]' > "$MOCK_DIR/series.json"
    printf 'api/v3/series\t200\t%s\n' "$MOCK_DIR/series.json" > "$MOCK_DIR/curl_rules"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_called '{"name":"RescanSeries"}' 1
    assert_not_called "SeriesSearch"
}

@test "id matching is case-insensitive (DB upper-case, symlink lower-case)" {
    add_items "$UUID_A"   # stored as AAAA1111-...
    plant_ids_link Show1 "$UUID_A"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_output_contains "Broken: 0"
}

@test "legacy Decypharr link with a vanished target is flagged" {
    add_items "$UUID_A"
    mkdir -p "$(LIB)/OldShow/Season 01"
    ln -s "/mnt/debrid/decypharr/realdebrid/__all__/Pack/ep.mkv" "$(LIB)/OldShow/Season 01/ep.mkv"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    grep -q "MOCK    \[Test\] (legacy-target-gone)" "$(AUDIT)"
}

@test "legacy link whose target still exists on the host is kept" {
    add_items "$UUID_A"
    mkdir -p "$BATS_TEST_TMPDIR/rshared/decypharr/realdebrid/__all__/Pack" "$(LIB)/OldShow/Season 01"
    touch "$BATS_TEST_TMPDIR/rshared/decypharr/realdebrid/__all__/Pack/ep.mkv"
    ln -s "/mnt/debrid/decypharr/realdebrid/__all__/Pack/ep.mkv" "$(LIB)/OldShow/Season 01/ep.mkv"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    assert_output_contains "Broken: 0"
}

@test "unrecognised targets are counted and left alone" {
    patch_var "$PREPARED_SCRIPT" DRY_RUN_GLOBAL N
    add_items "$UUID_A"
    mkdir -p "$(LIB)/Other/Season 01"
    ln -s "/somewhere/else/ep.mkv" "$(LIB)/Other/Season 01/ep.mkv"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    [ -L "$(LIB)/Other/Season 01/ep.mkv" ]
    assert_output_contains "1 with unrecognised targets"
}

@test "id floor: too few InfiniDysk items aborts before touching anything" {
    patch_var "$PREPARED_SCRIPT" DRY_RUN_GLOBAL N
    patch_var "$PREPARED_SCRIPT" MIN_IDS 5
    add_items "$UUID_A"
    plant_ids_link Show2 "$UUID_B"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 1 ]

    [ -L "$(LIB)/Show2/Season 01/$UUID_B.mkv" ]
    assert_output_contains "ABORT: InfiniDysk reports only 1 items"
}

@test "id drop guard: item count falling >20% since last run aborts" {
    patch_var "$PREPARED_SCRIPT" DRY_RUN_GLOBAL N
    echo "LAST_ID_COUNT=10" > "$BATS_TEST_TMPDIR/sentinel_meta"
    add_items "$UUID_A"
    plant_ids_link Show2 "$UUID_B"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 1 ]

    [ -L "$(LIB)/Show2/Season 01/$UUID_B.mkv" ]
    assert_output_contains "fell from 10 to 1"
}

@test "circuit breaker: too many broken links writes the hold file, deletes nothing" {
    patch_var "$PREPARED_SCRIPT" DRY_RUN_GLOBAL N
    patch_var "$PREPARED_SCRIPT" MAX_BROKEN_BEFORE_HALT 2
    add_items "$UUID_A"
    for i in 1 2 3; do
        plant_ids_link "Show$i" "dead000$i-0000-0000-0000-000000000000"
    done

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 1 ]

    [ -f "$BATS_TEST_TMPDIR/SENTINEL_HOLD.txt" ]
    [ "$(find "$(LIB)" -type l | wc -l)" -eq 3 ]
}

@test "hold file present: run refuses to start" {
    patch_var "$PREPARED_SCRIPT" DRY_RUN_GLOBAL N
    echo "3948 broken links found. Sentinel Locked." > "$BATS_TEST_TMPDIR/SENTINEL_HOLD.txt"
    add_items "$UUID_A"
    plant_ids_link Show2 "$UUID_B"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 1 ]

    [ -L "$(LIB)/Show2/Season 01/$UUID_B.mkv" ]
    assert_output_contains "ON HOLD"
}

@test "per-run cap: only DELETES_PER_RUN links are removed" {
    patch_var "$PREPARED_SCRIPT" DRY_RUN_GLOBAL N
    patch_var "$PREPARED_SCRIPT" DELETES_PER_RUN 2
    add_items "$UUID_A"
    for i in 1 2 3 4 5; do
        plant_ids_link "Show$i" "dead000$i-0000-0000-0000-000000000000"
    done

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    [ "$(find "$(LIB)" -type l | wc -l)" -eq 3 ]
    assert_output_contains "PACE: deletion cap reached"
}

@test "rolling 24h cap blocks deletion" {
    patch_var "$PREPARED_SCRIPT" DRY_RUN_GLOBAL N
    patch_var "$PREPARED_SCRIPT" ROLLING_24H_LIMIT 2
    local hour_ago=$(( $(date +%s) - 3600 ))
    printf "%s\n%s\n" "$hour_ago" "$hour_ago" > "$BATS_TEST_TMPDIR/sentinel_state.db"
    add_items "$UUID_A"
    plant_ids_link Show2 "$UUID_B"

    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    [ -L "$(LIB)/Show2/Season 01/$UUID_B.mkv" ]
    assert_not_called "curl"
}
