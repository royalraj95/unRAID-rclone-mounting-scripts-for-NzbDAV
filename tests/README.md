# Tests

Smoke tests for the four DUMB scripts in `Scripts/`. Each script is run as a
subprocess with `tests/helpers/mocks/` injected at the front of `$PATH`, so
calls to `docker`, `curl`, `notify`, `umount`, `fusermount`, `mountpoint`,
`sync`, `sleep`, and `date` are intercepted by tiny shell stubs that record
invocations and return canned responses.

## Running locally

```bash
sudo apt install -y bats shellcheck     # one-time
bats tests/
shellcheck Scripts/*\(DUMB\)
```

CI runs both on every push/PR via `.github/workflows/ci.yml`.

## What's mocked vs. real

| Concern | How it's handled |
|---|---|
| `docker` | Mock records every call. `inspect` returns canned values from `$MOCK_DIR/docker_inspect_<name>` (static) or `<name>.seq` (one-per-line, consumed on each call). `ps` returns `$MOCK_DIR/docker_ps`. `restart`/`stop`/`start` are no-ops. |
| `curl` | Mock records the call, exits 0. No response body. |
| `date` | When `$MOCK_NOW` (epoch seconds) is set, returns that virtual time for every form (`+%s`, `+%Y-%m-%d %H:%M:%S`). Otherwise passes through. |
| `sleep` | No-op (records the call). Keeps tests fast. |
| `notify` (Unraid `/usr/local/emhttp/...`) | Absolute path is rewritten by `prepare_*_script` helpers to point at `tests/helpers/mocks/notify`. |
| `umount` / `fusermount` / `sync` | No-op recorders — destructive on real systems. |
| `mountpoint` | Returns 0/1 based on `$MOCK_DIR/mountpoint_<munged_path>`. |
| `find`, `ls`, `mkdir`, `rm`, `awk`, `grep`, `cat`, `wc`, etc. | Real. Operate on the sandboxed `$BATS_TEST_TMPDIR` tree. |

## Helpers

- `helpers/setup.bash` — `init_mocks`, `prepare_*_script`, `patch_var`, `write_state`, `read_state_key`.
- `helpers/asserts.bash` — `assert_called`, `assert_not_called`, `assert_state_key`, `assert_output_contains`.

The `prepare_*_script` helpers copy each script to `$BATS_TEST_TMPDIR` and
`sed`-patch its hardcoded paths (`STATE_FILE`, `NZB_MOUNT`, `DEC_MOUNT`,
`LOG_FILE`, etc.) to point inside the sandbox. The scripts themselves are
never modified by tests.

## Adding a new test

```bash
@test "my scenario description" {
    # Arrange: stage canned mock responses, write state file, plant
    # filesystem fixtures.
    echo "false" > "$MOCK_DIR/docker_inspect_DUMB-2026"
    write_state "$BATS_TEST_TMPDIR/prime_state.db" "D_FAIL_COUNT=3"

    # Act: run the prepared script.
    run bash "$PREPARED_SCRIPT"
    [ "$status" -eq 0 ]

    # Assert: check the call log and resulting state file.
    assert_called "docker restart DUMB-2026" 1
    assert_state_key "$BATS_TEST_TMPDIR/prime_state.db" D_FAIL_COUNT 4
    assert_output_contains "Entering Recovery..."
}
```

## Time mocking

To control the clock, set `MOCK_NOW` to an epoch second:
```bash
export MOCK_NOW=1700000000
```
The mock `date` then returns this value for `+%s` and reformats it for any
other format string. Useful for testing cooldown windows: write a state file
with `DEC_LAST_RECOVERY_TS=$((MOCK_NOW - 300))` to simulate "5 minutes ago"
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
  sandboxed.
- `Scripts/Mount Script` (the original, non-DUMB version) is not covered;
  per the README it is reference-only.
- These are smoke tests treating each script as a black box; they catch
  state-machine and orchestration regressions, not low-level bash bugs
  (those are caught by shellcheck).
