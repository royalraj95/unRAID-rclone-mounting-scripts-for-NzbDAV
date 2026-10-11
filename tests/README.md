# Tests

Smoke tests for the four DUMB scripts in `scripts/unraid/`. Each script is run as a
subprocess with `tests/helpers/mocks/` injected at the front of `$PATH`, so
calls to `docker`, `curl`, `notify`, `umount`, `fusermount`, `mountpoint`,
`sync`, `sleep`, and `date` are intercepted by tiny shell stubs that record
invocations and return canned responses.

## Running locally

```bash
sudo apt install -y bats shellcheck sqlite3 jq     # one-time
bats tests/
shellcheck scripts/unraid/*\(DUMB\) tests/helpers/mocks/*
```

On macOS the mocks and scripts need GNU tools and bash ≥ 4 (the stock bash 3.2 has no
associative arrays):

```bash
brew install bats-core shellcheck bash gnu-sed coreutils findutils
PATH="/opt/homebrew/bin:$(brew --prefix gnu-sed)/libexec/gnubin:$(brew --prefix coreutils)/libexec/gnubin:$(brew --prefix findutils)/libexec/gnubin:$PATH" bats tests/
```

CI runs both on every push/PR via `.github/workflows/ci.yml`.

## What's mocked vs. real

| Concern | How it's handled |
|---|---|
| `docker` | Mock records every call. `inspect` returns canned values from `$MOCK_DIR/docker_inspect_<name>` (static) or `<name>.seq` (one-per-line, consumed on each call). `ps` returns `$MOCK_DIR/docker_ps`. `restart`/`stop`/`start` are no-ops. |
| `curl` | Mock records the call. Responses come from `$MOCK_DIR/curl_rules` (tab-separated `substring  http_code  body-file`; first match wins). Default: HTTP 200, empty body. Honors `-o` and `-w '%{http_code}'`. |
| `date` | When `$MOCK_NOW` (epoch seconds) is set, returns that virtual time for every form (`+%s`, `+%Y-%m-%d %H:%M:%S`). Otherwise passes through. |
| `sleep` | No-op (records the call). Keeps tests fast. |
| `notify` (Unraid `/usr/local/emhttp/...`) | Absolute path is rewritten by `prepare_*_script` helpers to point at `tests/helpers/mocks/notify`. |
| `umount` / `fusermount` / `sync` | No-op recorders — destructive on real systems. |
| `mountpoint` | Returns 0/1 based on `$MOCK_DIR/mountpoint_<munged_path>` (`yes`/`no`). A `.seq` file of the same name is consumed one line per call, so a mount can come back mid-run. Use `mock_mountpoint <path> yes`. |
| `find`, `ls`, `mkdir`, `rm`, `awk`, `grep`, `cat`, `wc`, `sqlite3`, `jq`, etc. | Real. Operate on the sandboxed `$BATS_TEST_TMPDIR` tree. The Sentinel's InfiniDysk DB is a throwaway sqlite file with only `DavItems.Id`. |

## Helpers

- `helpers/setup.bash` — `init_mocks`, `prepare_*_script`, `patch_var`, `mock_mountpoint`, `write_state`, `read_state_key`. `init_mocks` points `DUMB_CONF` at a nonexistent file so a real `dumb.conf` never leaks into tests.
- `helpers/asserts.bash` — `assert_called`, `assert_not_called`, `assert_state_key`, `assert_output_contains`.

The `prepare_*_script` helpers copy each script to `$BATS_TEST_TMPDIR` and
`sed`-patch its config lines (`STATE_FILE`, `NZB_MOUNT`, `INFINIDYSK_DB`,
`LOG_FILE`, etc.) to point inside the sandbox. The scripts themselves are
never modified by tests.

## Adding a new test

```bash
@test "my scenario description" {
    # Arrange: stage canned mock responses, write state file, plant
    # filesystem fixtures.
    mock_mountpoint "$BATS_TEST_TMPDIR/nzb" no
    write_state "$BATS_TEST_TMPDIR/prime_state.db" "N_FAIL_COUNT=1"

    # Act: run the prepared script.
    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 1 ]

    # Assert: check the call log and resulting state file.
    assert_called "docker restart DUMB-2026" 1
    assert_state_key "$BATS_TEST_TMPDIR/prime_state.db" N_FAIL_COUNT 2
    assert_output_contains "Failed: NzbDAV is DOWN"
}
```

## Time mocking

To control the clock, set `MOCK_NOW` to an epoch second:
```bash
export MOCK_NOW=1700000000
```
The mock `date` then returns this value for `+%s` and reformats it for any
other format string. Useful for testing cooldown windows: write a state file
with `FOUNDATION_LAST_RESTART_TS=$((MOCK_NOW - 300))` to simulate "5 minutes ago"
and verify the cooldown gate engages.

## Sequenced docker inspect

When a single test needs different `docker inspect` results across multiple
calls (e.g. "container is down at the foundation check, but up afterward"),
write a `.seq` file:
```bash
printf "false\ntrue\ntrue\ntrue\n" > "$MOCK_DIR/docker_inspect_DUMB-2026.seq"
```
Each call consumes one line in order. Static `docker_inspect_<name>` files
are still used as a fallback when no `.seq` exists.

## Limitations

- The `HARD_RESET="Y"` branch of `Mount Script (DUMB)` (which `rm -rf`s the
  rclone cache) is intentionally not exercised — destructive even when
  sandboxed. The automatic hard reset (no cache wipe) is covered.
- `scripts/unraid/Mount Script` (the original, non-DUMB version) is not covered;
  per the README it is reference-only.
- These are smoke tests treating each script as a black box; they catch
  state-machine and orchestration regressions, not low-level bash bugs
  (those are caught by shellcheck).
