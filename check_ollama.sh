#!/usr/bin/env bash
# ==============================================================================
# check_ollama.sh – Verify that Ollama is installed and running, compare the
#                   local version against the latest upstream GitHub release,
#                   and optionally install or update it with the official installer.
#
# Author: Gino Bogo
# Date: 2026-11-27
# Version: see SCRIPT_VERSION
# ==============================================================================

set -euo pipefail

# ==============================================================================
# GLOBAL CONFIGURATION
# ==============================================================================

SCRIPT_VERSION="1.5"

# ANSI colour codes: only on a terminal, and never when NO_COLOR is set.
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BOLD=''
    RESET=''
fi
SEPARATOR="----------------------------------------------------------------------"

# Daemon endpoint. OLLAMA_HOST may be "host:port", a full URL, or a Unix socket
# ("unix:///path" or an absolute path).
OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1:11434}"
CURL_DAEMON=()
DAEMON_HOST=""
DAEMON_IS_LOCAL=false
UNIX_SOCKET=""

case "$OLLAMA_HOST" in
    unix://*) UNIX_SOCKET="${OLLAMA_HOST#unix://}" ;;
    /*) UNIX_SOCKET="$OLLAMA_HOST" ;;
esac

if [ -n "$UNIX_SOCKET" ]; then
    CURL_DAEMON=(--unix-socket "$UNIX_SOCKET")
    OLLAMA_URL="unix:$UNIX_SOCKET"
    API_VERSION_URL="http://localhost/api/version"
    DAEMON_HOST="$UNIX_SOCKET"
    DAEMON_IS_LOCAL=true
else
    case "$OLLAMA_HOST" in
        http://* | https://*) OLLAMA_URL="$OLLAMA_HOST" ;;
        *) OLLAMA_URL="http://$OLLAMA_HOST" ;;
    esac
    OLLAMA_URL="${OLLAMA_URL%/}"
    API_VERSION_URL="$OLLAMA_URL/api/version"
    REST="${OLLAMA_URL#*://}"
    REST="${REST%%/*}"
    if [[ "$REST" =~ ^\[([0-9A-Fa-f:]+)\](:([0-9]+))?$ ]]; then
        DAEMON_HOST="${BASH_REMATCH[1]}"
    elif [[ "$REST" =~ ^([^:]+):([0-9]+)$ ]]; then
        DAEMON_HOST="${BASH_REMATCH[1]}"
    else
        DAEMON_HOST="$REST"
    fi
    case "$DAEMON_HOST" in
        127.0.0.1 | localhost | ::1) DAEMON_IS_LOCAL=true ;;
    esac
fi

# Upstream release metadata. Both endpoints are overridable for mirrors/tests.
RELEASES_API="${OLLAMA_RELEASES_API:-https://api.github.com/repos/ollama/ollama/releases/latest}"
if [ -n "${OLLAMA_RELEASES_PAGE:-}" ]; then
    RELEASES_PAGE="$OLLAMA_RELEASES_PAGE"
elif [ -n "${OLLAMA_RELEASES_API:-}" ]; then
    RELEASES_PAGE="$RELEASES_API"
else
    RELEASES_PAGE="https://github.com/ollama/ollama/releases/latest"
fi

# Official installer. The URL is overridable so the update flow can be tested
# with a stand-in script without touching a real Ollama installation.
INSTALL_URL="${OLLAMA_INSTALL_URL:-https://ollama.com/install.sh}"

# Script options initialization
QUIET=false
UPDATE_MODE="ask" # ask | yes | no
TMP_INSTALLER=""
FRESH_INSTALL=false

# Capability flags, resolved by check_environment().
HAVE_PGREP=false
HAVE_SHA256=false
TTY_AVAILABLE=false

REQUIRED_COMMANDS=(curl sed grep sort head tail tr cut wc mktemp basename id rm sh)

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
    echo -e "  Ollama is missing, a terminal run can install it using the official"
    echo -e "  installer. When the daemon answers, the local version is compared"
    echo -e "  with the latest stable GitHub release and updates can be offered."
    echo
    echo -e "${CYAN}Usage:${RESET}"
    echo -e "  $script_name [options]"
    echo
    echo -e "${CYAN}Options:${RESET}"
    echo -e "  ${GREEN}-h, --help${RESET}       Show this help message and exit"
    echo -e "  ${GREEN}-V, --version${RESET}    Show version and exit"
    echo -e "  ${GREEN}-q, --quiet${RESET}      Suppress the banner, INFO and NOTE lines"
    echo -e "  ${GREEN}-y, --yes${RESET}        Install or update without asking for confirmation"
    echo -e "  ${GREEN}-n, --no-update${RESET}  Never prompt, install, or update; only report"
    echo
    echo -e "${CYAN}Environment:${RESET}"
    echo -e "  ${GREEN}OLLAMA_HOST${RESET}           Daemon address or Unix socket"
    echo -e "                           (default: 127.0.0.1:11434)"
    echo -e "  ${GREEN}OLLAMA_INSTALL_URL${RESET}    Installer script to run on update"
    echo -e "                           (default: https://ollama.com/install.sh)"
    echo -e "  ${GREEN}OLLAMA_RELEASES_API${RESET}   Release metadata endpoint"
    echo -e "                           (default: GitHub releases/latest)"
    echo -e "  ${GREEN}OLLAMA_RELEASES_PAGE${RESET}  Human-readable release page URL"
    echo -e "  ${GREEN}OLLAMA_UPDATE_TIMEOUT${RESET} Seconds to wait for the daemon after"
    echo -e "                           an update (default: 20)"
    echo -e "  ${GREEN}NO_COLOR${RESET}              Disable ANSI colours"
    echo
    echo -e "${CYAN}Exit codes:${RESET}"
    echo -e "  0  Installed and running, no newer release (or install/update succeeded)"
    echo -e "  1  Ollama is not installed (or install was declined/not possible)"
    echo -e "  2  Ollama is installed but not running (web check skipped)"
    echo -e "  3  Version check failed (network, HTTP status or malformed response)"
    echo -e "  4  A newer release is available but was not installed"
    echo -e "  5  Install/update was attempted but failed or needs a daemon restart"
    echo -e "  6  Missing dependency or unsupported environment"
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
# ENVIRONMENT AND VERSION HELPERS
# ==============================================================================

# Function: check_environment
# Description: Verifies the Bash version, required commands and version sort.
# Returns: 0 when usable, 1 otherwise (caller exits 6).
check_environment() {
    local missing=() cmd

    if ((BASH_VERSINFO[0] < 4)); then
        log_err "Bash 4 or newer is required (found $BASH_VERSION)."
        return 1
    fi

    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if ((${#missing[@]} > 0)); then
        log_err "Missing required command(s): ${missing[*]}"
        return 1
    fi

    if [ "$(printf 'x\n' | sed 's/x/y/')" != "y" ]; then
        log_err "'sed' is present but does not work."
        return 1
    fi

    if [ "$(printf '1.0\n1.0.1\n' | sort -V 2>/dev/null | tail -n 1)" != "1.0.1" ]; then
        log_err "This 'sort' does not support -V (version sort)."
        return 1
    fi

    return 0
}

# Function: version_ge
# Description: True when $1 is greater than or equal to $2 (sort -V ordering).
# Arguments: $1 - left version, $2 - right version
version_ge() {
    local a="${1#v}" b="${2#v}" highest

    a="${a//[[:space:]]/}"
    b="${b//[[:space:]]/}"
    [ -n "$a" ] && [ -n "$b" ] || return 1

    highest="$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1)"
    [ "$highest" = "$a" ]
}

# Function: version_gt
# Description: True when $1 is strictly greater than $2.
# Arguments: $1 - left version, $2 - right version
version_gt() {
    version_ge "$1" "$2" && [ "$1" != "$2" ]
}

# Function: api_version
# Description: Queries the daemon and prints its version, or nothing.
api_version() {
    curl -fsS --max-time 3 \
        "${CURL_DAEMON[@]+"${CURL_DAEMON[@]}"}" \
        "$API_VERSION_URL" 2>/dev/null |
        sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
        head -n 1
}

# Function: fetch_release
# Description: Fetches the latest release and sets LATEST_VERSION.
#              Distinguishes rate limiting, transport errors and bad payloads.
# Returns: 0 on success, 1 otherwise.
fetch_release() {
    local body headers code retry

    body="$(mktemp)"
    headers="$(mktemp)"

    code="$(curl -sSL --max-time 10 \
        -D "$headers" -o "$body" -w '%{http_code}' \
        -H 'Accept: application/vnd.github+json' \
        -H "User-Agent: check_ollama.sh/${SCRIPT_VERSION}" \
        "$RELEASES_API" 2>/dev/null || true)"
    [ -n "$code" ] || code="000"

    # Transports without HTTP status (file:// mirrors) still return a body.
    if [ "$code" = "000" ] && [ -s "$body" ]; then
        code="200"
    fi

    case "$code" in
        200)
            LATEST_VERSION="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' "$body" | head -n 1)"
            rm -f "$body" "$headers"
            if [ -z "$LATEST_VERSION" ]; then
                log_err "The release response from $RELEASES_API was malformed."
                return 1
            fi
            return 0
            ;;
        403 | 429)
            retry="$(sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*//p' "$headers" | tr -d '\r' | head -n 1)"
            rm -f "$body" "$headers"
            log_err "Release lookup denied or rate limited (HTTP $code)."
            if [ -n "$retry" ]; then
                log_note "Retry after ${retry}s, or use OLLAMA_RELEASES_API with a mirror."
            else
                log_note "Unauthenticated GitHub allows 60 requests per hour; set OLLAMA_RELEASES_API to use a mirror."
            fi
            return 1
            ;;
        000)
            rm -f "$body" "$headers"
            log_err "Could not reach $RELEASES_API."
            return 1
            ;;
        *)
            rm -f "$body" "$headers"
            log_err "Unexpected HTTP status $code from $RELEASES_API."
            return 1
            ;;
    esac
}

# ==============================================================================
# UPDATE SUPPORT
# ==============================================================================

# Function: run_update
# Description: Downloads the installer, runs it with root privileges, then
#              polls the daemon until it reports the expected version (or any
#              version when expected is empty, for a fresh install).
# Arguments: $1 - expected version (empty means any daemon version)
#            $2 - action label: install or update (default: update)
# Returns: 0 when the daemon reports an acceptable version, 1 otherwise
run_update() {
    local expected="$1"
    local action="${2:-update}"
    local version=""
    local timeout="${OLLAMA_UPDATE_TIMEOUT:-20}"
    local installer_status=0
    local size=""
    local deadline
    local -a runner=()

    if ! [[ "$timeout" =~ ^[0-9]+$ ]] || ((timeout < 1)); then
        log_warn "Invalid OLLAMA_UPDATE_TIMEOUT='$timeout'; using 20 seconds."
        timeout=20
    fi

    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            runner=(sudo)
        else
            log_err "Installing/updating requires root privileges and 'sudo' is not available."
            return 1
        fi
    fi

    log_note "Downloading the official Ollama installer from $INSTALL_URL ..."
    if ! curl -fsSL --max-time 60 "$INSTALL_URL" -o "$TMP_INSTALLER"; then
        log_err "Failed to download the installer."
        return 1
    fi

    size="$(wc -c <"$TMP_INSTALLER" | tr -d '[:space:]')"
    if [ "$size" = "0" ]; then
        log_err "The downloaded installer is empty; nothing was executed."
        return 1
    fi
    if head -c 512 "$TMP_INSTALLER" | grep -qiE '<!doctype[[:space:]]+html|<html'; then
        log_err "The downloaded file looks like an HTML page, not a shell script."
        return 1
    fi

    if $HAVE_SHA256; then
        log_note "Installer SHA-256: $(sha256sum "$TMP_INSTALLER" | cut -d' ' -f 1)"
    fi

    log_note "Running the installer (this may take a while) ..."
    "${runner[@]}" sh "$TMP_INSTALLER" || installer_status=$?

    # The installer restarts the service itself and can fail in an optional
    # post-install step (the GPU/CUDA block aborts on Arch-family systems where
    # /etc/os-release has no VERSION_ID) after the binary is already in place.
    # Always verify the daemon before trusting the installer's exit code.
    deadline=$((SECONDS + timeout))
    while ((SECONDS < deadline)); do
        version="$(api_version || true)"
        if [ -n "$expected" ]; then
            version_ge "$version" "$expected" && break
        elif [ -n "$version" ]; then
            break
        fi
        sleep 1
    done

    if [ -n "$expected" ] && version_ge "$version" "$expected"; then
        if ((installer_status != 0)); then
            log_warn "Installer exited with status $installer_status (an optional post-install step failed); the daemon already reports v$version."
        fi
        if [ "$action" = "install" ]; then
            log_info "Installation complete; the daemon now reports v$version."
            if $QUIET; then
                printf '%bInstalled Ollama v%s.%b\n' "$GREEN" "$version" "$RESET"
            fi
        else
            log_info "Update complete; the daemon now reports v$version."
            if $QUIET; then
                printf '%bUpdated Ollama to v%s.%b\n' "$GREEN" "$version" "$RESET"
            fi
        fi
        return 0
    fi

    if [ -z "$expected" ] && [ -n "$version" ]; then
        if ((installer_status != 0)); then
            log_warn "Installer exited with status $installer_status (an optional post-install step failed); the daemon already reports v$version."
        fi
        log_info "Installation complete; the daemon now reports v$version."
        if $QUIET; then
            printf '%bInstalled Ollama v%s.%b\n' "$GREEN" "$version" "$RESET"
        fi
        return 0
    fi

    if ((installer_status != 0)); then
        log_err "Installer exited with status $installer_status; the daemon still reports '${version:-unknown}'."
    else
        log_err "Installer reported success but the daemon still reports '${version:-unknown}'."
    fi
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        log_note "Restart it manually: sudo systemctl restart ollama"
    else
        log_note "Restart the Ollama service (for example, restart 'ollama serve')."
    fi
    return 1
}

ensure_tmp_installer() {
    if [ -z "$TMP_INSTALLER" ]; then
        TMP_INSTALLER="$(mktemp)"
        trap 'rm -f "${TMP_INSTALLER:-}"' EXIT
    fi
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
            if (($# > 0)); then
                log_err "Unexpected argument: $1"
                echo
                print_usage 1
            fi
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

if ! check_environment; then
    exit 6
fi

if command -v pgrep >/dev/null 2>&1; then HAVE_PGREP=true; fi
if command -v sha256sum >/dev/null 2>&1; then HAVE_SHA256=true; fi

# Prompting must never depend on stdout: open the controlling terminal.
if { exec 3>/dev/tty; } 2>/dev/null; then TTY_AVAILABLE=true; fi

# ---- Phase 1: is Ollama installed? ----
log_info "Phase 1/4: checking whether Ollama is installed ..."
OLLAMA_BIN="$(command -v ollama || true)"
if [ -z "$OLLAMA_BIN" ]; then
    log_err "Ollama is not installed (no 'ollama' executable on PATH)."
    log_note "Official installer: $INSTALL_URL"
    log_note "GitHub repository: https://github.com/ollama/ollama"

    if [ "$UPDATE_MODE" = "no" ]; then
        log_note "Install skipped (-n/--no-update)."
        exit 1
    fi
    if ! $DAEMON_IS_LOCAL; then
        log_warn "OLLAMA_HOST points to a remote daemon ($DAEMON_HOST); refusing to install Ollama on this machine."
        log_note "Run the install on the host that should run Ollama."
        exit 1
    fi
    if [ "$UPDATE_MODE" = "ask" ]; then
        if ! $TTY_AVAILABLE; then
            log_note "No terminal available; use -y to install automatically."
            exit 1
        fi
        if ! $QUIET; then
            printf '%b[NOTE]%b Install command:\n' "$CYAN" "$RESET" >&3
            printf '       curl -fsSL %s -o <temp file>\n' "$INSTALL_URL" >&3
            printf '       sudo sh <temp file>\n' >&3
        fi
        printf 'Install Ollama now using the official installer? [y/N] ' >&3
        REPLY=""
        read -r REPLY </dev/tty || true
        REPLY="$(printf '%s' "$REPLY" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
        case "$REPLY" in
            y | yes) ;;
            *)
                log_note "Install skipped."
                exit 1
                ;;
        esac
    fi

    ensure_tmp_installer
    INSTALL_EXPECTED=""
    if fetch_release; then
        INSTALL_EXPECTED="$LATEST_VERSION"
    else
        log_warn "Could not determine the latest release; the installer will be verified by daemon startup only."
    fi

    if ! run_update "$INSTALL_EXPECTED" install; then
        exit 5
    fi

    hash -r 2>/dev/null || true
    OLLAMA_BIN="$(command -v ollama || true)"
    if [ -z "$OLLAMA_BIN" ]; then
        log_err "Installer completed but 'ollama' is still not on PATH."
        log_note "Open a new shell or check /usr/local/bin/ollama."
        exit 5
    fi
    FRESH_INSTALL=true
fi
log_info "Ollama found at $OLLAMA_BIN"

# ---- Phase 2: is the daemon running? ----
log_info "Phase 2/4: checking whether the Ollama daemon is running ..."
RUNNING=false
API_VERSION=""
API_RESPONSE="$(curl -fsS --max-time 5 \
    "${CURL_DAEMON[@]+"${CURL_DAEMON[@]}"}" \
    "$API_VERSION_URL" 2>/dev/null || true)"
if [ -n "$API_RESPONSE" ]; then
    API_VERSION="$(printf '%s' "$API_RESPONSE" |
        sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
    [ -n "$API_VERSION" ] && RUNNING=true
fi

# Fall back to the process table: a daemon may be up while the API is not
# reachable from here (different bind address, firewall, permission, ...).
if ! $RUNNING && $HAVE_PGREP && pgrep -x ollama >/dev/null 2>&1; then
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
        sed -n 's/.*version is[[:space:]]*//p' | head -n 1 || true)"
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
if ! fetch_release; then
    log_note "Release page: $RELEASES_PAGE"
    exit 3
fi

if [ -z "$LOCAL_VERSION" ]; then
    log_note "Latest upstream release is v$LATEST_VERSION."
    exit 0
fi

if version_gt "$LATEST_VERSION" "$LOCAL_VERSION"; then
    log_warn "Update available: installed v$LOCAL_VERSION, latest v$LATEST_VERSION."
    log_note "Release page: $RELEASES_PAGE"
elif version_gt "$LOCAL_VERSION" "$LATEST_VERSION"; then
    log_note "Installed v$LOCAL_VERSION is newer than the latest release (v$LATEST_VERSION)."
    if $FRESH_INSTALL; then
        $QUIET || printf '%bDone.%b Ollama is installed and up to date.\n' "$GREEN" "$RESET"
    else
        $QUIET || printf '%bDone.%b Nothing to update.\n' "$GREEN" "$RESET"
    fi
    exit 0
else
    log_info "Ollama is up to date (v$LOCAL_VERSION)."
    if $FRESH_INSTALL; then
        $QUIET || printf '%bDone.%b Ollama is installed and up to date.\n' "$GREEN" "$RESET"
    else
        $QUIET || printf '%bDone.%b No newer release found.\n' "$GREEN" "$RESET"
    fi
    exit 0
fi

# Report-only when explicitly disabled or when there is no terminal to answer
# a prompt (cron, pipes, CI): never block an unattended run.
if [ "$UPDATE_MODE" = "no" ]; then
    exit 4
fi

if ! $DAEMON_IS_LOCAL; then
    log_warn "OLLAMA_HOST points to a remote daemon ($DAEMON_HOST); refusing to update this machine."
    log_note "Run the update on the host that runs the daemon, or update it manually."
    exit 4
fi

if [ "$UPDATE_MODE" = "ask" ]; then
    if ! $TTY_AVAILABLE; then
        log_note "No terminal available; use -y to update automatically."
        exit 4
    fi
    if ! $QUIET; then
        printf '%b[NOTE]%b Update commands:\n' "$CYAN" "$RESET" >&3
        printf '       curl -fsSL %s -o <temp file>\n' "$INSTALL_URL" >&3
        printf '       sudo sh <temp file>\n' >&3
    fi
    printf 'Update now? [y/N] ' >&3
    REPLY=""
    read -r REPLY </dev/tty || true
    REPLY="$(printf '%s' "$REPLY" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    case "$REPLY" in
        y | yes) ;;
        *)
            log_note "Update skipped."
            exit 4
            ;;
    esac
fi

ensure_tmp_installer

if run_update "$LATEST_VERSION" update; then
    exit 0
fi
exit 5
