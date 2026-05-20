#!/usr/bin/env bash
# Assertions over the mock call log produced by tests/helpers/mocks/*.

# Counts how many lines in $MOCK_CALL_LOG match the substring $1.
calls_matching() {
    local pattern="$1"
    grep -F -- "$pattern" "$MOCK_CALL_LOG" 2>/dev/null | wc -l
}

assert_called() {
    local pattern="$1"
    local expected="${2:-1}"
    local actual
    actual=$(calls_matching "$pattern")
    if [ "$actual" != "$expected" ]; then
        {
            echo "Expected '$pattern' to be called $expected time(s), got $actual."
            echo "--- call log ---"
            cat "$MOCK_CALL_LOG"
        } >&2
        return 1
    fi
}

assert_not_called() {
    assert_called "$1" 0
}

assert_state_key() {
    local file="$1" key="$2" expected="$3"
    local actual
    actual=$(grep -E "^${key}=" "$file" | tail -1 | cut -d= -f2- | tr -d '"')
    if [ "$actual" != "$expected" ]; then
        {
            echo "Expected $key=$expected in $file, got '$actual'."
            echo "--- state file ---"
            cat "$file"
        } >&2
        return 1
    fi
}

# Asserts the script's stdout/stderr (captured into $output by `run`)
# contains the substring $1.
assert_output_contains() {
    local needle="$1"
    if [[ "$output" != *"$needle"* ]]; then
        {
            echo "Expected output to contain: $needle"
            echo "--- output ---"
            echo "$output"
        } >&2
        return 1
    fi
}
