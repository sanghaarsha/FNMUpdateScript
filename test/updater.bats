#!/usr/bin/env bats
#
# test/updater.bats — Hermetic Bats Test Suite for fnm_update.sh
#
# Tests version discovery, major pinning, alias migration, atomic rollback,
# dry-run mode, and error handling inside an isolated mock sandbox.

load "helpers/mocks"

@test "Major Line Upgrades: updates each installed major version to the latest remote release" {
  run "$PROJECT_ROOT/fnm_update.sh" -y
  assert_success

  # Verify install called for each major line's latest remote
  assert_fnm_called "fnm install v18.20.1"
  assert_fnm_called "fnm install v20.18.1"
  assert_fnm_called "fnm install v22.13.0"
  assert_fnm_called "fnm install v23.5.0"

  # Verify cleanup called for each old version
  assert_fnm_called "fnm uninstall v18.19.0"
  assert_fnm_called "fnm uninstall v20.15.0"
  assert_fnm_called "fnm uninstall v22.11.0"
  assert_fnm_called "fnm uninstall v23.1.0"
}

@test "Alias Migration: preserves multiple and single aliases (default, lts, custom)" {
  run "$PROJECT_ROOT/fnm_update.sh" -y -m 22
  assert_success

  # Node 22 fixture has "lts, default"
  assert_fnm_called "fnm install v22.13.0"
  assert_fnm_called "fnm alias v22.13.0 lts"
  assert_fnm_called "fnm alias v22.13.0 default"

  # Verify order: install happens BEFORE alias migration, and alias happens BEFORE uninstall
  assert_call_order "fnm install v22.13.0" "fnm alias v22.13.0 default"
  assert_call_order "fnm alias v22.13.0 default" "fnm uninstall v22.11.0"
}

@test "Major Version Scoping: -m/--major restricts upgrade strictly to target major line" {
  run "$PROJECT_ROOT/fnm_update.sh" -y --major 20
  assert_success

  # Major 20 should be upgraded
  assert_fnm_called "fnm install v20.18.1"
  assert_fnm_called "fnm alias v20.18.1 lts-iron"
  assert_fnm_called "fnm uninstall v20.15.0"

  # Other majors must NOT be touched
  assert_fnm_not_called "fnm install v18"
  assert_fnm_not_called "fnm install v22"
  assert_fnm_not_called "fnm install v23"
}

@test "Major Version Scoping: positional arguments target multiple specific major lines" {
  run "$PROJECT_ROOT/fnm_update.sh" -y 18 23
  assert_success

  # Specified majors must be upgraded
  assert_fnm_called "fnm install v18.20.1"
  assert_fnm_called "fnm install v23.5.0"

  # Non-targeted majors must remain untouched
  assert_fnm_not_called "fnm install v20"
  assert_fnm_not_called "fnm install v22"
}

@test "Dry-Run: inspects versions and displays upgrade table without executing mutations" {
  run "$PROJECT_ROOT/fnm_update.sh" --dry-run
  assert_success

  [[ "$output" =~ "Dry-run mode: no changes were executed." ]]

  # Must not execute any mutations
  assert_fnm_not_called "fnm install"
  assert_fnm_not_called "fnm alias"
  assert_fnm_not_called "fnm uninstall"
}

@test "Keep-Old: retains superseded versions without calling fnm uninstall" {
  run "$PROJECT_ROOT/fnm_update.sh" -y --keep-old -m 22
  assert_success

  assert_fnm_called "fnm install v22.13.0"
  assert_fnm_called "fnm alias v22.13.0 default"

  # Verify uninstall was never invoked
  assert_fnm_not_called "fnm uninstall"
}

@test "Atomic Cleanup: aborts alias migration and old version removal if install fails" {
  export SIMULATE_INSTALL_FAILURE="1"

  run "$PROJECT_ROOT/fnm_update.sh" -y -m 22
  assert_success

  [[ "$output" =~ "Installation failed for v22.13.0" ]]

  # fnm install was attempted
  assert_fnm_called "fnm install v22.13.0"

  # But alias migration and uninstall must be aborted
  assert_fnm_not_called "fnm alias v22.13.0"
  assert_fnm_not_called "fnm uninstall v22.11.0"
}

@test "Interactive Prompt: declining update prompt aborts before performing mutations" {
  run bash -c "echo 'n' | '$PROJECT_ROOT/fnm_update.sh' -m 22"
  assert_success

  [[ "$output" =~ "Update cancelled by user" ]]

  assert_fnm_not_called "fnm install"
  assert_fnm_not_called "fnm alias"
  assert_fnm_not_called "fnm uninstall"
}

@test "Edge Case: all installed versions already up to date" {
  set_installed_versions "* v22.13.0 default"
  set_remote_versions "v22.13.0"

  run "$PROJECT_ROOT/fnm_update.sh" -y
  assert_success

  [[ "$output" =~ "All installed Node.js versions are already up to date." ]]
  assert_fnm_not_called "fnm install"
  assert_fnm_not_called "fnm uninstall"
}

@test "Edge Case: no matching versions when filtering non-existent major line" {
  run "$PROJECT_ROOT/fnm_update.sh" -y -m 99
  assert_success

  [[ "$output" =~ "No fnm-managed Node.js versions found matching criteria." ]]
  assert_fnm_not_called "fnm install"
}

@test "Edge Case: remote listing failure is handled gracefully with error exit" {
  export SIMULATE_REMOTE_FAILURE="1"

  run "$PROJECT_ROOT/fnm_update.sh"
  [ "$status" -ne 0 ]

  [[ "$output" =~ "Failed to retrieve remote Node.js versions" ]]
}

@test "Edge Case: local listing failure is handled gracefully with error exit" {
  export SIMULATE_LS_FAILURE="1"

  run "$PROJECT_ROOT/fnm_update.sh"
  [ "$status" -ne 0 ]

  [[ "$output" =~ "Failed to retrieve installed fnm versions" ]]
}

@test "CLI Flags: --help displays usage manual and exits cleanly" {
  run "$PROJECT_ROOT/fnm_update.sh" --help
  assert_success

  [[ "$output" =~ "FNM Node.js Auto Updater" ]]
  [[ "$output" =~ "USAGE:" ]]
}

@test "CLI Flags: unknown option reports error and exits with non-zero code" {
  run "$PROJECT_ROOT/fnm_update.sh" --unknown-flag
  [ "$status" -ne 0 ]

  [[ "$output" =~ "Unknown option '--unknown-flag'" ]]
}

@test "Bug 1: Version Collisions - Supports multiple installed versions on the same major line" {
  set_installed_versions "* v20.10.0 legacy
* v20.17.0 testing"
  set_remote_versions "v20.10.0
v20.17.0
v20.18.2"

  run "$PROJECT_ROOT/fnm_update.sh" -y
  assert_success

  # Verify BOTH versions are updated independently
  assert_fnm_called "fnm install v20.18.2"
  assert_fnm_called "fnm uninstall v20.10.0"
  assert_fnm_called "fnm uninstall v20.17.0"
  
  # Check alias migration
  assert_fnm_called "fnm alias v20.18.2 legacy"
  assert_fnm_called "fnm alias v20.18.2 testing"
}

@test "Bug 2: Unintentional Stable-to-RC Upgrades are prevented" {
  set_installed_versions "* v22.11.0 default"
  set_remote_versions "v22.11.0
v22.12.0-rc.1"

  run "$PROJECT_ROOT/fnm_update.sh" -y
  assert_success

  # Target resolves to up-to-date rather than RC
  [[ "$output" =~ "All installed Node.js versions are already up to date" ]]
  assert_fnm_not_called "fnm install"
}

@test "RC-to-RC Promotion: RC upgrades to latest RC or Stable" {
  set_installed_versions "* v23.0.0-rc.1 testing"
  set_remote_versions "v23.0.0-rc.1
v23.0.0-rc.2
v23.0.0"

  run "$PROJECT_ROOT/fnm_update.sh" -y
  assert_success

  # Target upgrades to v23.0.0
  assert_fnm_called "fnm install v23.0.0"
}

@test "Bug 3 & 4: Punctuation is stripped and dynamic markers (current/system) are ignored" {
  set_installed_versions "* v20.18.0 (default, lts-iron, current, system)"
  set_remote_versions "v20.18.0
v20.18.2"

  run "$PROJECT_ROOT/fnm_update.sh" -y
  assert_success

  assert_fnm_called "fnm install v20.18.2"
  
  # Valid aliases are applied cleanly
  assert_fnm_called "fnm alias v20.18.2 default"
  assert_fnm_called "fnm alias v20.18.2 lts-iron"

  # Dynamic markers and parentheses are stripped/ignored
  assert_fnm_not_called "fnm alias v20.18.2 current"
  assert_fnm_not_called "fnm alias v20.18.2 system"
  assert_fnm_not_called "fnm alias v20.18.2 (default"
}

@test "Edge Case: Prevents downgrade if locally installed version is newer than remote latest" {
  set_installed_versions "* v20.20.2 archived
* v22.23.3 prev_lts
* v24.21.0 lts, default"
  
  set_remote_versions "v20.8.1
v22.10.0
v24.10.0"

  run "$PROJECT_ROOT/fnm_update.sh" -y
  assert_success

  # Output should explicitly state that all versions are up to date
  [[ "$output" =~ "All installed Node.js versions are already up to date." ]]
  
  # Ensure no install or uninstall attempts were made
  assert_fnm_not_called "fnm install"
  assert_fnm_not_called "fnm uninstall"
}
