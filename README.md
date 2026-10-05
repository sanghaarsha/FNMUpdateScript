# FNM Node.js Auto Updater (`fnm_update`)

[![CI](https://github.com/sanghaarsha/FNMUpdateScript/actions/workflows/ci.yml/badge.svg)](https://github.com/sanghaarsha/FNMUpdateScript/actions/workflows/ci.yml)
[![Bash 4.0+](https://img.shields.io/badge/bash-4.0%2B-blue.svg)](https://www.gnu.org/software/bash/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A robust, POSIX-compliant Bash utility to audit, upgrade, and safely clean up installed Node.js versions managed by [Fast Node Manager (fnm)](https://github.com/Schniz/fnm).

---

## Key Features

- **Strict Major Version Isolation:**
  Preserves existing major series lines. Node.js `v18.x`, `v20.x`, `v22.x`, and `v23.x` each upgrade strictly to the latest patch or minor release within their respective major branch without accidental breaking major bumps.
- **Seamless Alias Migration:**
  Automatically inspects attached tags and aliases (`default`, `lts`, `latest`, custom project aliases) on older versions and reapplies every alias to the newly installed release via `fnm alias`.
- **Safe Atomic Cleanup:**
  Superseded versions are only uninstalled AFTER the new version has installed successfully and all associated aliases have moved. If an installation fails, the existing version and its aliases remain completely untouched.
- **Cross-Platform Version Sorting:**
  Built-in version sorting supports GNU `sort -V`, macOS Homebrew `gsort -V`, and includes an automatic POSIX `awk` semantic token sorting fallback for BSD environments.
- **Interactive & Non-Interactive Execution:**
  Full interactive confirmation with colored tables, plus `-y` / `--yes` for headless CI/CD automation and cron jobs.
- **Dry-Run Inspection:**
  Inspect local installations, query remote releases, and print the upgrade audit table with `--dry-run` without executing any mutations.
- **Hermetic Testing & Zero Host Mutation:**
  Comprehensive [Bats](https://github.com/bats-core/bats-core) test suite with hermetic sandboxing. Tests never touch your host `fnm` or active Node installations.

---

## Installation

### Method 1: Using Make (Recommended)

```bash
# Clone the repository
git clone https://github.com/sanghaarsha/FNMUpdateScript.git
cd FNMUpdateScript

# Install to /usr/local/bin (requires sudo)
sudo make install

# Or install to your user bin directory (~/.local/bin)
make install PREFIX="$HOME/.local"
```

### Method 2: Manual Link

```bash
chmod +x fnm_update.sh
ln -s "$(pwd)/fnm_update.sh" "$HOME/.local/bin/fnm_update"
```

---

## Usage

```text
fnm_update [OPTIONS] [MAJOR...]
```

### Command-Line Options

| Option | Description |
| :--- | :--- |
| `-d`, `--dry-run` | Inspect installed versions and remote releases without modifying local installations or aliases |
| `-y`, `--yes` | Automatically confirm all upgrade and cleanup prompts (non-interactive mode) |
| `-k`, `--keep-old` | Retain older superseded versions after successful upgrade instead of uninstalling |
| `-m`, `--major <N>` | Target only specific major version line(s) (can be repeated or passed positionally) |
| `--no-color` | Disable ANSI color formatting in output logs |
| `-h`, `--help` | Display usage instructions and exit |

### Examples

```bash
# Audit installed Node.js versions without making changes
fnm_update --dry-run

# Audit and upgrade interactively (prompts before applying changes and removing old versions)
fnm_update

# Run non-interactively (ideal for CI/CD or cron maintenance)
fnm_update -y

# Upgrade specific major versions only
fnm_update 20 22
fnm_update -m 22 --keep-old

# Upgrade without uninstalling superseded versions
fnm_update --keep-old
```

---

## Contributing & Testing

### Zero Host Mutation Guarantee

Contributors can safely develop and test this utility without risking their local development environment or host Node.js installations.

The test framework (`test/helpers/mocks.bash`) implements a hermetic sandbox:
1. **Isolated Sandbox Directory:** Each test run generates an ephemeral temporary directory (`mktemp -d`) and points `FNM_DIR` strictly to that sandbox.
2. **Safety Guardrail:** The test runner verifies that the active `fnm` binary is the sandbox mock inside `$TEST_TEMP_DIR/bin`. If host `fnm` is ever detected, execution aborts immediately before executing any commands.
3. **Stubbed `fnm` Engine:** Queries (`fnm ls`, `fnm ls-remote`) return canned fixtures from `test/fixtures/`, while mutations (`fnm install`, `fnm alias`, `fnm uninstall`) operate within the sandbox and record every call to an audit log (`$TEST_TEMP_DIR/fnm_calls.log`) for precise verification.

### Running Tests Locally

Ensure `bats` (version 1.0+) and `shellcheck` are installed:

- **Linux (Ubuntu/Debian):** `sudo apt-get install -y bats shellcheck`
- **Linux (Arch/EndeavourOS):** `sudo pacman -S bats shellcheck`
- **macOS:** `brew install bats-core shellcheck`

Execute the test suite and static analysis:

```bash
# Run ShellCheck analysis
make lint

# Run Bats test suite
make test

# Run both lint and tests
make
```

### Adding New Test Scenarios

1. Place version list fixtures in `test/fixtures/fnm_ls.txt` or `test/fixtures/fnm_ls_remote.txt` (or use `set_installed_versions` / `set_remote_versions` dynamically).
2. Add test assertions in `test/updater.bats` using the sandbox helpers:
   - `assert_fnm_called <regex>`
   - `assert_fnm_not_called <regex>`
   - `assert_call_order <first_regex> <second_regex>`
   - `assert_success`

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
