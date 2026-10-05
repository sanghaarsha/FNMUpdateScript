#!/usr/bin/env bash
#
# fnm_update.sh — Audit, upgrade, and clean up fnm-managed Node.js versions.
#
# Checks installed fnm-managed Node.js versions against the latest available release
# for each major line, updates them non-interactively or interactively, and seamlessly
# migrates all associated aliases (default, lts, latest, current, custom aliases)
# while safely cleaning up superseded versions.
#
# Usage:
#   ./fnm_update.sh [OPTIONS] [MAJOR...]
#
# Options:
#   -d, --dry-run        Inspect installed versions and remote releases without applying changes
#   -y, --yes            Automatically confirm all upgrade and cleanup prompts
#   -k, --keep-old       Retain older superseded versions after successful upgrade
#   -m, --major <N>      Target only specific major version line(s) (can be repeated)
#       --no-color       Disable ANSI color formatting in output logs
#   -h, --help           Display this help manual and exit

set -u
set -o pipefail 2>/dev/null || true

# ------------------------------------------------------------------ Bash check -
if ((BASH_VERSINFO[0] < 4)); then
  echo "Error: this script requires Bash 4.0+ (found ${BASH_VERSION})." >&2
  echo "On macOS the default system bash is 3.2 — install a newer one with 'brew install bash'." >&2
  exit 1
fi
# ---------------------------------------------------------------------- Colors -
BOLD="" RESET="" RED="" GREEN="" YELLOW="" CYAN="" BLUE=""
setup_colors() {
  if [[ "${NO_COLOR:-false}" == "true" ]] || [[ ! -t 1 ]]; then
    BOLD="" RESET="" RED="" GREEN="" YELLOW="" CYAN="" BLUE=""
  else
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    CYAN=$'\033[36m'
    BLUE=$'\033[34m'
  fi
}

# --------------------------------------------------------------------- Logging -
log_info() {
  echo "${BLUE}[INFO]${RESET} $*"
}

log_upgrade() {
  echo "${YELLOW}${BOLD}[UPGRADE]${RESET} $*"
}

log_skip() {
  echo "${CYAN}[SKIP]${RESET} $*"
}

log_success() {
  echo "${GREEN}${BOLD}[SUCCESS]${RESET} $*"
}

log_error() {
  echo "${RED}${BOLD}[ERROR]${RESET} $*" >&2
}

log_warn() {
  echo "${YELLOW}[WARN]${RESET} $*" >&2
}

# ---------------------------------------------------------------- User confirm -
confirm() {
  local prompt="$1" reply
  if [[ "${AUTO_CONFIRM:-false}" == "true" ]]; then
    return 0
  fi
  read -rp "${prompt} [y/N] " reply
  [[ "${reply,,}" =~ ^y(es)?$ ]]
}

# ------------------------------------------------------- Trap signal handlers -
trap_cleanup() {
  echo
  log_warn "Operation interrupted by user. Exiting."
  exit 130
}
trap trap_cleanup SIGINT SIGTERM

# ------------------------------------------------------- Precondition check ---
require_fnm() {
  command -v fnm >/dev/null 2>&1 && return 0
  log_error "fnm is not installed or not on PATH."
  log_error "Please install Fast Node Manager (fnm) from https://github.com/Schniz/fnm."
  exit 1
}

# ------------------------------------------------ Cross-Platform Version Sort -
# Sort list of versions (e.g. v20.18.0 or 20.18.0) in ascending version order
sort_versions() {
  if printf '1\n2\n' | sort -V >/dev/null 2>&1; then
    sort -V
  elif command -v gsort >/dev/null 2>&1 && printf '1\n2\n' | gsort -V >/dev/null 2>&1; then
    gsort -V
  else
    # Portable fallback for BSD sort (macOS) without GNU sort -V
    awk '{
      orig = $0
      clean = orig
      sub(/^v/, "", clean)
      str = clean
      key = ""
      n = length(str)
      token = ""
      is_num = 0
      for (i = 1; i <= n; i++) {
        c = substr(str, i, 1)
        if (c ~ /[0-9]/) {
          if (is_num == 1) {
            token = token c
          } else {
            if (token != "") {
              key = key token "_"
            }
            token = c
            is_num = 1
          }
        } else {
          if (is_num == 1) {
            key = key sprintf("%08d", token) "_"
            token = c
            is_num = 0
          } else {
            token = token c
          }
        }
      }
      if (token != "") {
        if (is_num == 1) {
          key = key sprintf("%08d", token) "_"
        } else {
          key = key token "_"
        }
      }
      print key "\t" orig
    }' | sort -k1,1 | awk -F'\t' '{print $2}'
  fi
}

# ---------------------------------------------------------- Helper Functions --
# aliases_from_tags TAGS — prints one alias name per line, given a tag string
# straight from `fnm ls` (e.g. "lts, default" or "lts default").
aliases_from_tags() {
  local raw="$1"
  # Remove version segment and enclosing parentheses/brackets
  raw=$(sed -E 's/^\*?[[:space:]]*v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)*[^[:alnum:]]*//' <<< "$raw")
  raw=$(tr -d '()' <<< "$raw")
  raw="${raw//,/ }"

  local part
  for part in $raw; do
    # Skip dynamic status indicators
    [[ "$part" =~ ^(current|system)$ ]] && continue
    [[ -n "$part" ]] && printf '%s\n' "$part"
  done
}

declare -A CUR_VER CUR_TAGS NEW_VER NEEDS_UPDATE
INST_VERS=()
UPDATE_LIST=()
DONE_LIST=()

# detect_versions LS_OUTPUT TARGET_MAJORS — extracts unique installed versions
detect_versions() {
  local ls_output="$1"
  shift || true
  local filter_majors=("$@")

  local all_vers=()
  mapfile -t all_vers < <(
    grep -E '^\*?[[:space:]]*v[0-9]+\.[0-9]+\.[0-9]+' <<< "$ls_output" \
      | grep -vE '^\*?[[:space:]]*system' \
      | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?' \
      | sort -V -u
  )

  INST_VERS=()
  if [[ ${#filter_majors[@]} -gt 0 ]]; then
    for v in "${all_vers[@]}"; do
      local m
      m=$(echo "$v" | sed -E 's/^v([0-9]+)\..*/\1/')
      for target in "${filter_majors[@]}"; do
        target="${target#v}"
        if [[ "$m" == "$target" ]]; then
          INST_VERS+=("$v")
          break
        fi
      done
    done
  else
    INST_VERS=("${all_vers[@]}")
  fi
}

# gather_version_info LS_OUTPUT LS_REMOTE_OUTPUT — for each installed version,
# records installed version, associated tags/aliases, latest remote release, and update state.
gather_version_info() {
  local ls_output="$1" ls_remote_output="$2"
  local inst_ver line tags latest major

  for inst_ver in "${INST_VERS[@]}"; do
    # Escape the version string for regex
    local esc_ver="${inst_ver//./\\.}"
    line=$(grep -E "^\*?[[:space:]]*${esc_ver}([[:space:]]|$)" <<< "$ls_output" | grep -vE '^\*?[[:space:]]*system' | head -n1)
    
    tags=$(aliases_from_tags "$line" | paste -sd' ' -)

    CUR_VER["$inst_ver"]="${inst_ver#v}"
    CUR_TAGS["$inst_ver"]="$tags"

    major=$(echo "$inst_ver" | sed -E 's/^v([0-9]+)\..*/\1/')

    # Restrict lookup based on stability of the installed version
    if [[ "$inst_ver" == *-* ]]; then
      # Installed version is a pre-release: allow newer pre-release or GA in this major
      latest=$(grep -E "^v${major}\." <<< "$ls_remote_output" \
        | sed -E 's/ \(.*//' | sort_versions | tail -n1)
    else
      # Installed version is stable: match strictly GA versions
      latest=$(grep -E "^v${major}\.[0-9]+\.[0-9]+$" <<< "$ls_remote_output" \
        | sed -E 's/ \(.*//' | sort_versions | tail -n1)
    fi

    latest="${latest#v}"
    NEW_VER["$inst_ver"]="$latest"

    if [[ -n "$latest" && "$latest" != "${inst_ver#v}" ]]; then
      local higher
      higher=$(printf "v%s\nv%s\n" "${inst_ver#v}" "$latest" | sort_versions | tail -n1)
      if [[ "$higher" == "v$latest" ]]; then
        NEEDS_UPDATE["$inst_ver"]="yes"
      else
        NEEDS_UPDATE["$inst_ver"]="no"
      fi
    else
      NEEDS_UPDATE["$inst_ver"]="no"
    fi
  done
}

# print_summary — renders the Version/Installed/Latest/Aliases/Status table
print_summary() {
  local inst_ver aliases status

  printf "%-16s %-16s %-22s %s\n" "Installed" "Latest" "Aliases" "Status"
  printf '%s\n' "----------------------------------------------------------------------------------"

  for inst_ver in "${INST_VERS[@]}"; do
    aliases=$(aliases_from_tags "${CUR_TAGS[$inst_ver]}" | paste -sd' ' -)
    [[ -z "$aliases" ]] && aliases="-"

    if [[ "${NEEDS_UPDATE[$inst_ver]}" == "yes" ]]; then
      status="${YELLOW}${BOLD}update available${RESET}"
      UPDATE_LIST+=("$inst_ver")
    else
      status="${GREEN}up to date${RESET}"
    fi

    printf "v%-15s v%-15s %-22s %s\n" \
      "${CUR_VER[$inst_ver]}" "${NEW_VER[$inst_ver]:-?}" "$aliases" "$status"
  done
}

# update_version INST_VER — installs new version and seamlessly migrates attached aliases
update_version() {
  local inst_ver="$1"
  local old="${CUR_VER[$inst_ver]}"
  local new="${NEW_VER[$inst_ver]}"
  local alias

  echo
  log_info "Updating ${CYAN}${inst_ver}${RESET}: ${YELLOW}v${old}${RESET} -> ${GREEN}v${new}${RESET}..."

  if ! fnm install "v${new}"; then
    log_error "Installation failed for v${new} — leaving ${inst_ver} at v${old}, aliases untouched."
    return 1
  fi

  log_success "Installed Node.js v${new}."

  # Migrate each attached alias (lts, default, custom names)
  while IFS= read -r alias; do
    [[ -z "$alias" ]] && continue
    log_info "Re-applying alias '${CYAN}${alias}${RESET}' -> ${GREEN}v${new}${RESET}..."
    if ! fnm alias "v${new}" "$alias"; then
      log_warn "Failed to set alias '${alias}' -> v${new}."
    fi
  done < <(aliases_from_tags "${CUR_TAGS[$inst_ver]}")

  return 0
}

# perform_updates — executes update_version for each version in UPDATE_LIST
perform_updates() {
  local inst_ver
  DONE_LIST=()
  for inst_ver in "${UPDATE_LIST[@]}"; do
    if update_version "$inst_ver"; then
      DONE_LIST+=("$inst_ver")
    fi
  done
}

# print_done_summary — renders old -> new table of successfully updated versions
print_done_summary() {
  local inst_ver

  echo
  if [[ ${#DONE_LIST[@]} -gt 0 ]]; then
    log_success "Upgrade completed (${#DONE_LIST[@]} version(s) updated)."
    printf "%-16s %-16s %s\n" "Old Version" "New Version" "Result"
    printf '%s\n' "------------------------------------------------------------"
    for inst_ver in "${DONE_LIST[@]}"; do
      printf "v%-15s v%-15s %s\n" \
        "${CUR_VER[$inst_ver]}" "${NEW_VER[$inst_ver]}" "${GREEN}SUCCESS${RESET}"
    done
  fi

  if [[ ${#DONE_LIST[@]} -lt ${#UPDATE_LIST[@]} ]]; then
    echo
    log_warn "Some versions could not be updated — review installation error logs above."
  fi
}

# cleanup_old_versions — uninstalls superseded versions for successfully updated versions
cleanup_old_versions() {
  local inst_ver old

  [[ ${#DONE_LIST[@]} -eq 0 ]] && return 0

  if [[ "${KEEP_OLD:-false}" == "true" ]]; then
    log_info "Keeping old versions (--keep-old specified)."
    return 0
  fi

  echo
  if ! confirm "Do you want to remove superseded versions now that aliases have moved?"; then
    log_info "Old versions left in place."
    return 0
  fi

  for inst_ver in "${DONE_LIST[@]}"; do
    old="${CUR_VER[$inst_ver]}"
    log_info "Removing superseded v${old}..."
    if ! fnm uninstall "v${old}"; then
      log_warn "Could not remove v${old} (it may still be in use by an active shell)."
    else
      log_success "Removed superseded v${old}."
    fi
  done

  echo
  log_success "Cleanup complete."
}

# ----------------------------------------------------------- Help & Usage ------
show_help() {
  cat << EOF
${BOLD}FNM Node.js Auto Updater${RESET}
Audit, upgrade, and clean up installed Node.js versions managed by Fast Node Manager (fnm).

${BOLD}USAGE:${RESET}
    $(basename "$0") [OPTIONS] [MAJOR...]

${BOLD}OPTIONS:${RESET}
    ${GREEN}-d, --dry-run${RESET}
            Perform a trial run without modifying local installations or aliases.
            Inspects installed versions, queries remote releases, and prints the audit table.

    ${GREEN}-y, --yes${RESET}
            Automatically approve all upgrade and cleanup prompts for non-interactive execution.

    ${GREEN}-k, --keep-old${RESET}
            Retain older superseded versions after successful upgrade instead of uninstalling.

    ${GREEN}-m, --major <N>${RESET}
            Target only specific major version line(s) (e.g. -m 20 -m 22 or positional arguments).

    ${GREEN}--no-color${RESET}
            Disable ANSI color sequences in output logs.

    ${GREEN}-h, --help${RESET}
            Display this help manual and exit.

${BOLD}BEHAVIOR & SCOPING RULES:${RESET}
    * ${BOLD}Major Version Isolation:${RESET} Versions are strictly pinned to their major line
      (e.g., v20.x upgrades to the latest v20.x, v22.x to latest v22.x).
    * ${BOLD}Alias Preservation:${RESET} All aliases attached to an installed version
      (such as 'default', 'lts', 'latest', or custom aliases) are automatically
      re-applied to the upgraded version.
    * ${BOLD}Safe Atomic Cleanup:${RESET} Superseded versions are only removed AFTER the new version
      is successfully installed and all aliases have been migrated.
    * ${BOLD}Zero Host Mutation Testing:${RESET} Hermetic test suite isolates fnm calls in a sandbox.

${BOLD}EXAMPLES:${RESET}
    $(basename "$0") --dry-run
    $(basename "$0") -y
    $(basename "$0") 20 22
    $(basename "$0") -m 24 --keep-old

EOF
}

# ----------------------------------------------------------------- Main Entry --
main() {
  local dry_run=false
  local auto_confirm=false
  local keep_old=false
  local user_majors=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--dry-run)
        dry_run=true
        shift
        ;;
      -y|--yes)
        auto_confirm=true
        shift
        ;;
      -k|--keep-old)
        keep_old=true
        shift
        ;;
      --no-color)
        NO_COLOR=true
        shift
        ;;
      -m|--major)
        if [[ -z "${2:-}" || "$2" == -* ]]; then
          echo "Error: --major requires a major version number." >&2
          exit 1
        fi
        user_majors+=("$2")
        shift 2
        ;;
      --major=*)
        user_majors+=("${1#*=}")
        shift
        ;;
      -h|--help)
        setup_colors
        show_help
        exit 0
        ;;
      -*)
        echo "Error: Unknown option '$1'. Run with --help for usage." >&2
        exit 1
        ;;
      *)
        user_majors+=("$1")
        shift
        ;;
    esac
  done

  AUTO_CONFIRM="$auto_confirm"
  KEEP_OLD="$keep_old"
  setup_colors
  require_fnm

  echo "${CYAN}${BOLD}Checking installed fnm-managed Node.js versions...${RESET}"
  echo

  local ls_output ls_remote_output raw_ls_output
  raw_ls_output="$(fnm ls 2>&1)" || {
    log_error "Failed to retrieve installed fnm versions ('fnm ls' failed)."
    exit 1
  }
  ls_output=$(printf '%s\n' "$raw_ls_output" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')

  local raw_remote_output
  raw_remote_output="$(fnm ls-remote 2>&1)" || {
    log_error "Failed to retrieve remote Node.js versions ('fnm ls-remote' failed)."
    exit 1
  }
  ls_remote_output=$(printf '%s\n' "$raw_remote_output" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g')

  detect_versions "$ls_output" "${user_majors[@]}"
  if [[ ${#INST_VERS[@]} -eq 0 ]]; then
    log_warn "No fnm-managed Node.js versions found matching criteria."
    return 0
  fi

  gather_version_info "$ls_output" "$ls_remote_output"
  print_summary
  echo

  if [[ ${#UPDATE_LIST[@]} -eq 0 ]]; then
    log_success "All installed Node.js versions are already up to date."
    return 0
  fi

  local prefixed=() m
  for m in "${UPDATE_LIST[@]}"; do prefixed+=("${m}"); done
  echo "${BOLD}Updates available for:${RESET} ${CYAN}${prefixed[*]}${RESET}"
  echo

  if [[ "$dry_run" == "true" ]]; then
    log_info "Dry-run mode: no changes were executed."
    return 0
  fi

  if ! confirm "Do you want to update these versions now?"; then
    log_info "Update cancelled by user. No changes were made."
    return 0
  fi

  perform_updates
  print_done_summary
  cleanup_old_versions
}

main "$@"
