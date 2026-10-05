#!/usr/bin/env bash
#
# test/helpers/mocks.bash — Hermetic Test Harness & Mocking Framework for FNM Updater
#
# Guarantees Zero Host Mutation by isolating execution to a temporary sandbox,
# stubbing 'fnm' CLI calls, and recording all actions to an audit log.

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$HELPERS_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
export PROJECT_ROOT
FIXTURES_DIR="$TEST_DIR/fixtures"

ORIGINAL_PATH="$PATH"

setup() {
  # 1. Create isolated sandbox directory
  TEST_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fnm_test_sandbox.XXXXXX")"
  export TEST_TEMP_DIR

  # Zero Host Mutation Guardrail: Ensure fnm operations never hit host user environment
  export FNM_DIR="$TEST_TEMP_DIR/fnm_data"
  mkdir -p "$TEST_TEMP_DIR/bin" "$FNM_DIR"

  # 2. Setup audit log for recording fnm calls
  export FNM_CALLS_LOG="$TEST_TEMP_DIR/fnm_calls.log"
  touch "$FNM_CALLS_LOG"

  # Failure simulation switches (0 = normal, 1 = failure)
  export SIMULATE_INSTALL_FAILURE="0"
  export SIMULATE_REMOTE_FAILURE="0"
  export SIMULATE_LS_FAILURE="0"
  export FIXTURES_DIR

  # 3. Create mock fnm CLI executable
  cat << 'MOCK_EOF' > "$TEST_TEMP_DIR/bin/fnm"
#!/usr/bin/env bash
cmd="${1:-}"
shift || true

# Audit log recording
if [[ -n "${FNM_CALLS_LOG:-}" ]]; then
  echo "fnm $cmd $*" >> "$FNM_CALLS_LOG"
fi

case "$cmd" in
  ls|list)
    if [[ "${SIMULATE_LS_FAILURE:-0}" == "1" ]]; then
      echo "Error: Failed to read local installations" >&2
      exit 1
    fi
    if [[ -f "$TEST_TEMP_DIR/custom_fnm_ls.txt" ]]; then
      cat "$TEST_TEMP_DIR/custom_fnm_ls.txt"
    elif [[ -f "$FIXTURES_DIR/fnm_ls.txt" ]]; then
      cat "$FIXTURES_DIR/fnm_ls.txt"
    else
      echo "No installed versions found"
    fi
    exit 0
    ;;

  ls-remote)
    if [[ "${SIMULATE_REMOTE_FAILURE:-0}" == "1" ]]; then
      echo "Error: Failed to connect to nodejs.org" >&2
      exit 1
    fi
    if [[ -f "$TEST_TEMP_DIR/custom_fnm_ls_remote.txt" ]]; then
      cat "$TEST_TEMP_DIR/custom_fnm_ls_remote.txt"
    elif [[ -f "$FIXTURES_DIR/fnm_ls_remote.txt" ]]; then
      cat "$FIXTURES_DIR/fnm_ls_remote.txt"
    else
      exit 1
    fi
    exit 0
    ;;

  install)
    v="${1:-}"
    if [[ "${SIMULATE_INSTALL_FAILURE:-0}" == "1" ]]; then
      echo "Error: Failed to install $v" >&2
      exit 1
    fi
    echo "Installing Node.js $v"
    exit 0
    ;;

  alias)
    v="${1:-}"
    a="${2:-}"
    echo "Aliased $v as $a"
    exit 0
    ;;

  uninstall)
    v="${1:-}"
    echo "Uninstalled $v"
    exit 0
    ;;

  --version|-V)
    echo "fnm 1.38.1 (mock sandbox)"
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
MOCK_EOF

  chmod +x "$TEST_TEMP_DIR/bin/fnm"

  # Prepend mock bin to PATH so fnm resolves to the mock executable
  export PATH="$TEST_TEMP_DIR/bin:$PATH"

  # Safety verification
  local active_fnm
  active_fnm="$(command -v fnm)"
  if [[ "$active_fnm" != "$TEST_TEMP_DIR/bin/fnm" ]]; then
    echo "FATAL: Mock fnm is not first in PATH! Refusing to run tests on host fnm ($active_fnm)." >&2
    exit 1
  fi
}

teardown() {
  export PATH="$ORIGINAL_PATH"
  if [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]]; then
    rm -rf "$TEST_TEMP_DIR"
  fi
}

# -------------------------------------------------------- Sandbox Test Helpers -

# set_installed_versions <multiline string>
set_installed_versions() {
  printf '%s\n' "$1" > "$TEST_TEMP_DIR/custom_fnm_ls.txt"
}

# set_remote_versions <multiline string>
set_remote_versions() {
  printf '%s\n' "$1" > "$TEST_TEMP_DIR/custom_fnm_ls_remote.txt"
}

# assert_success (checks Bats $status and $output)
# shellcheck disable=SC2154
assert_success() {
  if [[ "$status" -ne 0 ]]; then
    echo "ASSERTION FAILED: Command failed with exit status $status." >&2
    echo "--- Command Output ---" >&2
    echo "$output" >&2
    echo "----------------------" >&2
    return 1
  fi
}

# assert_fnm_called <pattern>
assert_fnm_called() {
  local pattern="$1"
  grep -q -E "$pattern" "$FNM_CALLS_LOG" || {
    echo "ASSERTION FAILED: Expected call matching '$pattern' was not found in audit log." >&2
    echo "--- Actual FNM Calls Log ---" >&2
    cat "$FNM_CALLS_LOG" >&2
    echo "----------------------------" >&2
    return 1
  }
}

# assert_fnm_not_called <pattern>
assert_fnm_not_called() {
  local pattern="$1"
  if grep -q -E "$pattern" "$FNM_CALLS_LOG"; then
    echo "ASSERTION FAILED: Unexpected call matching '$pattern' was found in audit log." >&2
    echo "--- Actual FNM Calls Log ---" >&2
    cat "$FNM_CALLS_LOG" >&2
    echo "----------------------------" >&2
    return 1
  fi
}

# assert_call_order <first_pattern> <second_pattern>
assert_call_order() {
  local first="$1"
  local second="$2"

  local first_line second_line
  first_line="$(grep -n -m 1 -E "$first" "$FNM_CALLS_LOG" | cut -d: -f1)"
  second_line="$(grep -n -m 1 -E "$second" "$FNM_CALLS_LOG" | cut -d: -f1)"

  if [[ -z "$first_line" ]]; then
    echo "ASSERTION FAILED: First call matching '$first' was not made." >&2
    cat "$FNM_CALLS_LOG" >&2
    return 1
  fi

  if [[ -z "$second_line" ]]; then
    echo "ASSERTION FAILED: Second call matching '$second' was not made." >&2
    cat "$FNM_CALLS_LOG" >&2
    return 1
  fi

  if (( first_line >= second_line )); then
    echo "ASSERTION FAILED: '$first' (line $first_line) was expected before '$second' (line $second_line)." >&2
    cat "$FNM_CALLS_LOG" >&2
    return 1
  fi
}
