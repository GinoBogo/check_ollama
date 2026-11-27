#!/usr/bin/env bash
# ==============================================================================
# check_ollama.sh – Verify that Ollama is installed and running, compare the
#                   local version against the latest upstream GitHub release,
#                   and optionally update it with the official installer.
#
# Author: Gino Bogo
# Date: 2026-11-27
# Version: see SCRIPT_VERSION
# ==============================================================================

set -euo pipefail

# ==============================================================================
# GLOBAL CONFIGURATION
# ==============================================================================

SCRIPT_VERSION="1.3"

# ANSI colour codes
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'
SEPARATOR="----------------------------------------------------------------------"

# Daemon endpoint. OLLAMA_HOST may be given as "host:port" (Ollama's own
# convention) or as a full URL; a scheme is added when it is missing.
OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
case "$OLLAMA_HOST" in
    http://* | https://*) OLLAMA_URL="$OLLAMA_HOST" ;;
    *) OLLAMA_URL="http://$OLLAMA_HOST" ;;
esac
OLLAMA_URL="${OLLAMA_URL%/}"
API_VERSION_URL="$OLLAMA_URL/api/version"

# Upstream release metadata (no jq dependency: plain grep/sed parsing). The
# endpoint is overridable so the regression suite can run without a network.
RELEASES_API="${OLLAMA_RELEASES_API:-https://api.github.com/repos/ollama/ollama/releases/latest}"
RELEASES_PAGE="https://github.com/ollama/ollama/releases/latest"

# Official installer. The URL is overridable so the update flow can be tested
# with a stand-in script without touching a real Ollama installation.
INSTALL_URL="${OLLAMA_INSTALL_URL:-https://ollama.com/install.sh}"

# Script options initialization
QUIET=false
UPDATE_MODE="ask" # ask | yes | no
TMP_INSTALLER=""

# ==============================================================================
# USER INTERFACE
# ==============================================================================

# Function: log_info
# Description: Prints an informational message in green (suppressed by -q).
# Arguments: $* - message string
log_info() { $QUIET || printf '%b[INFO]%b %s\n' "$GREEN" "$RESET" "$*"; }

# Function: log_note
# Description: Prints a note message in cyan (suppressed by -q).
# Arguments: $* - message string
log_note() { $QUIET || printf '%b[NOTE]%b %s\n' "$CYAN" "$RESET" "$*"; }

# Function: log_warn
# Description: Prints a warning message in yellow.
# Arguments: $* - message string
log_warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$*"; }

# Function: log_err
# Description: Prints an error message in red to stderr.
# Arguments: $* - message string
log_err() { printf '%b[FAIL]%b %s\n' "$RED" "$RESET" "$*" >&2; }

sep() { printf '\n%b%s%b\n' "$CYAN" "$SEPARATOR" "$RESET"; }

print_banner() {
    $QUIET && return 0
    printf '\n%b%bCheck Ollama Utility v%s%b - by Gino Bogo\n' "$BOLD" "$CYAN" "$SCRIPT_VERSION" "$RESET"
    sep
}

# Function: print_usage
# Description: Displays the help menu and usage examples.
# Arguments: $1 - exit code (optional, default 1)
print_usage() {
    local script_name
    if ((${1:-1} != 0)); then
        exec 1>&2
    fi
    script_name=$(basename "${BASH_SOURCE[0]:-$0}")
    print_banner
    echo -e "${CYAN}Description:${RESET}"
    echo -e "  Checks that Ollama is installed and that its daemon is running. When"
    echo -e "  the daemon answers, the local version is compared with the latest"
    echo -e "  stable release published on GitHub. If a newer release exists and the"
    echo -e "  script runs in a terminal, it offers to install it."
    echo
    echo -e "${CYAN}Usage:${RESET}"
    echo -e "  $script_name [options]"
    echo
    echo -e "${CYAN}Options:${RESET}"
    echo -e "  ${GREEN}-h, --help${RESET}       Show this help message and exit"
    echo -e "  ${GREEN}-V, --version${RESET}    Show version and exit"
    echo -e "  ${GREEN}-q, --quiet${RESET}      Suppress the banner and informational lines"
    echo -e "  ${GREEN}-y, --yes${RESET}        Update without asking for confirmation"
    echo -e "  ${GREEN}-n, --no-update${RESET}  Never prompt or update, only report"
    echo
    echo -e "${CYAN}Environment:${RESET}"
    echo -e "  ${GREEN}OLLAMA_HOST${RESET}          Daemon address (default: 127.0.0.1:11434)"
    echo -e "  ${GREEN}OLLAMA_INSTALL_URL${RESET}   Installer script to run on update"
    echo -e "                          (default: https://ollama.com/install.sh)"
    echo -e "  ${GREEN}OLLAMA_RELEASES_API${RESET}  Release metadata endpoint"
    echo -e "                          (default: GitHub releases/latest)"
    echo
    echo -e "${CYAN}Exit codes:${RESET}"
    echo -e "  0  Installed and running, no newer release (or update succeeded)"
    echo -e "  1  Ollama is not installed"
    echo -e "  2  Ollama is installed but not running (web check skipped)"
    echo -e "  3  Version check failed (network or GitHub API problem)"
    echo -e "  4  A newer release is available but was not installed"
    echo -e "  5  Update was attempted but failed or needs a daemon restart"
    echo
    echo -e "${CYAN}Examples:${RESET}"
    echo -e "  Check the default local daemon:"
    echo -e "    ${GREEN}$script_name${RESET}"
    echo
    echo -e "  Check a remote daemon quietly (cron-friendly):"
    echo -e "    ${GREEN}OLLAMA_HOST=10.0.0.5:11434 $script_name -q -n${RESET}"
    echo
    echo -e "  Update without a prompt (unattended):"
    echo -e "    ${GREEN}$script_name -y${RESET}"
    echo
    exit "${1:-1}"
}

# ==============================================================================
# UPDATE SUPPORT
# ==============================================================================

# Function: run_update
# Description: Downloads the installer, runs it with root privileges, then
#              polls the daemon until it reports the expected version.
# Arguments: $1 - version expected after the update
# Returns: 0 when the daemon reports that version, 1 otherwise
run_update() {
    local expected="$1"
    local version=""
    local attempt
    local installer_status=0
    local -a runner=()

    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            runner=(sudo)
        else
            log_err "Updating requires root privileges and 'sudo' is not available."
            return 1
        fi
    fi

    log_note "Downloading the installer from $INSTALL_URL ..."
    if ! curl -fsSL --max-time 60 "$INSTALL_URL" -o "$TMP_INSTALLER"; then
        log_err "Failed to download the installer."
        return 1
    fi

    log_note "Running the installer (this may take a while) ..."
    "${runner[@]}" sh "$TMP_INSTALLER" || installer_status=$?

    # The installer restarts the service itself and can fail in an optional
    # post-install step (the GPU/CUDA block aborts on Arch-family systems where
    # /etc/os-release has no VERSION_ID) after the binary is already in place.
    # Always verify the daemon before trusting the installer's exit code.
    for attempt in 1 2 3 4 5; do
        sleep 1
        version="$(curl -fsS --max-time 3 "$API_VERSION_URL" 2>/dev/null |
            sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
        [ "$version" = "$expected" ] && break
    done

    if [ "$version" = "$expected" ]; then
        if [ "$installer_status" -ne 0 ]; then
            log_warn "Installer exited with status $installer_status (an optional post-install step failed); the daemon already reports v$version."
        fi
        log_info "Update complete; the daemon now reports v$version."
        return 0
    fi

    log_err "Installer exited with status $installer_status; the daemon still reports '${version:-unknown}'."
    log_note "Restart it manually: sudo systemctl restart ollama (or restart 'ollama serve')."
    return 1
}

# ==============================================================================
# OPTION PARSING
# ==============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        -q | --quiet)
            QUIET=true
            shift
            ;;
        -y | --yes)
            UPDATE_MODE="yes"
            shift
            ;;
        -n | --no-update)
            UPDATE_MODE="no"
            shift
            ;;
        -h | --help)
            print_usage 0
            ;;
        -V | --version)
            echo "check_ollama.sh v${SCRIPT_VERSION}"
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            log_err "Unknown option: $1"
            echo
            print_usage 1
            ;;
        *)
            log_err "Unexpected argument: $1"
            echo
            print_usage 1
            ;;
    esac
done

print_banner

# ---- Phase 1: is Ollama installed? ----
log_info "Phase 1/4: checking whether Ollama is installed ..."
OLLAMA_BIN="$(command -v ollama || true)"
if [ -z "$OLLAMA_BIN" ]; then
    log_err "Ollama is not installed (no 'ollama' executable on PATH)."
    exit 1
fi
log_info "Ollama found at $OLLAMA_BIN"

# ---- Phase 2: is the daemon running? ----
log_info "Phase 2/4: checking whether the Ollama daemon is running ..."
RUNNING=false
API_VERSION=""
API_RESPONSE="$(curl -fsS --max-time 5 "$API_VERSION_URL" 2>/dev/null || true)"
if [ -n "$API_RESPONSE" ]; then
    API_VERSION="$(printf '%s' "$API_RESPONSE" |
        sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    [ -n "$API_VERSION" ] && RUNNING=true
fi

# Fall back to the process table: a daemon may be up while the API is not
# reachable from here (different bind address, firewall, permission, ...).
if ! $RUNNING && pgrep -x ollama >/dev/null 2>&1; then
    RUNNING=true
    log_warn "Daemon process is running but $API_VERSION_URL did not answer."
fi

if ! $RUNNING; then
    log_err "Ollama is installed but not running; skipping the version check."
    log_note "Start it with: ollama serve"
    exit 2
fi
log_info "Daemon is running at $OLLAMA_URL"

# ---- Phase 3: determine the local version ----
log_info "Phase 3/4: resolving the local version ..."
LOCAL_VERSION="$API_VERSION"
if [ -z "$LOCAL_VERSION" ]; then
    LOCAL_VERSION="$(ollama --version 2>/dev/null |
        sed -n 's/.*version is[[:space:]]*//p' | head -n 1)"
fi
if [ -z "$LOCAL_VERSION" ]; then
    LOCAL_VERSION="$(ollama --version 2>/dev/null |
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
fi
LOCAL_VERSION="${LOCAL_VERSION#v}"
LOCAL_VERSION="$(printf '%s' "$LOCAL_VERSION" | tr -d '[:space:]')"

if [ -n "$LOCAL_VERSION" ]; then
    log_info "Local version: v$LOCAL_VERSION"
else
    log_warn "Could not determine the local version; reporting upstream only."
fi

# ---- Phase 4: fetch the latest upstream release ----
log_info "Phase 4/4: fetching the latest release from GitHub ..."
RELEASE_JSON="$(curl -fsSL --max-time 10 \
    -H 'Accept: application/vnd.github+json' \
    -H "User-Agent: check_ollama.sh/${SCRIPT_VERSION}" \
    "$RELEASES_API" 2>/dev/null || true)"

LATEST_VERSION="$(printf '%s' "$RELEASE_JSON" |
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)"

if [ -z "$LATEST_VERSION" ]; then
    log_warn "Could not reach GitHub or parse the latest release; version check skipped."
    log_note "Browse the releases manually: $RELEASES_PAGE"
    exit 3
fi

if [ -z "$LOCAL_VERSION" ]; then
    log_note "Latest upstream release is v$LATEST_VERSION."
    exit 0
fi

if [ "$LOCAL_VERSION" = "$LATEST_VERSION" ]; then
    log_info "Ollama is up to date (v$LOCAL_VERSION)."
    $QUIET || printf '%bDone.%b No newer release found.\n' "$GREEN" "$RESET"
    exit 0
fi

# sort -V orders dotted versions correctly (0.40.9 < 0.40.18).
HIGHEST="$(printf '%s\n%s\n' "$LOCAL_VERSION" "$LATEST_VERSION" | sort -V | tail -n 1)"
if [ "$HIGHEST" != "$LATEST_VERSION" ]; then
    log_note "Installed v$LOCAL_VERSION is newer than the latest release (v$LATEST_VERSION)."
    $QUIET || printf '%bDone.%b Nothing to update.\n' "$GREEN" "$RESET"
    exit 0
fi

log_warn "Update available: installed v$LOCAL_VERSION, latest v$LATEST_VERSION."
log_note "Release page: $RELEASES_PAGE"

# Report-only when explicitly disabled or when there is no terminal to answer
# a prompt (cron, pipes, CI): never block an unattended run.
if [ "$UPDATE_MODE" = "no" ]; then
    exit 4
fi
if [ "$UPDATE_MODE" = "ask" ] && [ ! -t 0 ]; then
    log_note "Not a terminal; use -y to update automatically."
    exit 4
fi

if [ "$UPDATE_MODE" = "ask" ]; then
    printf '%b[NOTE]%b Update commands:\n' "$CYAN" "$RESET"
    printf '       curl -fsSL %s -o <temp file>\n' "$INSTALL_URL"
    printf '       sudo sh <temp file>\n'
    printf 'Update now? [y/N] '
    REPLY=""
    read -r REPLY || true
    case "$REPLY" in
        y | Y | yes | YES) ;;
        *)
            log_note "Update skipped."
            exit 4
            ;;
    esac
fi

TMP_INSTALLER="$(mktemp)"
trap 'rm -f "${TMP_INSTALLER:-}"' EXIT

if run_update "$LATEST_VERSION"; then
    $QUIET || printf '%bDone.%b Ollama updated to v%s.\n' "$GREEN" "$RESET" "$LATEST_VERSION"
    exit 0
fi
exit 5
