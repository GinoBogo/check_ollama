#!/usr/bin/env bash
# ==============================================================================
# test_check_ollama.sh – Regression tests for Shell/check_ollama/check_ollama.sh.
#
# Run from anywhere:  Shell/check_ollama/tests/test_check_ollama.sh [-q] [-v] [-h]
#
#   -q   only the failures and the summary
#   -v   show each check as it runs
#   -h   this help
#
# Every check runs against a stub API server and fake binaries created under a
# temporary directory, so the repository is only ever read. Nothing here writes
# into it, and no network access is required.
#
# Exit status: 0 when every check passes, 1 otherwise.
#
# Author: Gino Bogo
# Date: 2026-11
# Version: 1.5
# ==============================================================================

set -uo pipefail

# Matching on command output assumes the C locale.
export LC_ALL=C

# --- locate the script under test from here, following symlinks ---------------

SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
    SOURCE_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" == /* ]] || SOURCE="$SOURCE_DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
SUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SUT="$SUT_DIR/check_ollama.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

QUIET=false
VERBOSE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -q) QUIET=true ;;
        -v) VERBOSE=true ;;
        -h | --help)
            sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            printf 'unknown option: %s (try --help)\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

if ! command -v python3 >/dev/null 2>&1; then
    printf 'python3 is required to run this suite.\n' >&2
    exit 2
fi

WORKDIR="$(mktemp -d)"
SRV_PID=""
# shellcheck disable=SC2329  # only invoked indirectly, by the EXIT trap below
cleanup() {
    [[ -n "$SRV_PID" ]] && kill "$SRV_PID" 2>/dev/null
    rm -rf -- "$WORKDIR"
}
trap cleanup EXIT

OUT="$WORKDIR/output"
BIN="$WORKDIR/bin"
mkdir -p "$BIN" "$WORKDIR/tmp"

PASSED=0
FAILED=0
SKIPPED=0

note() { $QUIET || printf '%s\n' "$*"; }

section() {
    note ""
    note "----------------------------------------------------------------------"
    note "$*"
}

pass() {
    PASSED=$((PASSED + 1))
    $VERBOSE && printf '  %bok%b   %s\n' "$GREEN" "$RESET" "$*"
    return 0
}

fail() {
    FAILED=$((FAILED + 1))
    printf '  %bFAIL%b %s\n' "$RED" "$RESET" "$*"
    return 0
}

check_code() {
    local desc="$1" want="$2"
    if [ "$ACTUAL" -eq "$want" ]; then
        pass "$desc"
    else
        fail "$desc (exit $ACTUAL, wanted $want)"
        sed 's/^/        /' "$OUT" | tail -n 15
    fi
}

cond() {
    local desc="$1"
    shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# ran_code <desc> <expected-exit> <command...>
ran_code() {
    local desc="$1" want="$2"
    shift 2
    ACTUAL=0
    "$@" >"$OUT" 2>&1 </dev/null || ACTUAL=$?
    check_code "$desc" "$want"
}

# run_pty <answer|-> <expected-exit> <desc> <command...>
run_pty() {
    local answer="$1" want="$2" desc="$3"
    shift 3
    ACTUAL=0
    if [ "$answer" = "-" ]; then
        script -qec "$*" /dev/null >"$OUT" 2>&1 || ACTUAL=$?
    else
        printf '%s\n' "$answer" | script -qec "$*" /dev/null >"$OUT" 2>&1
        ACTUAL=${PIPESTATUS[1]}
    fi
    check_code "$desc" "$want"
}

says() {
    local desc="$1" text="$2"
    if grep -qF -- "$text" "$OUT"; then
        pass "$desc"
    else
        fail "$desc (missing: $text)"
    fi
}

says_not() {
    local desc="$1" text="$2"
    if grep -qF -- "$text" "$OUT"; then
        fail "$desc (unexpected: $text)"
    else
        pass "$desc"
    fi
}

# ------------------------------------------------------------------------------
# fixtures: fake ollama, stub sudo, pgrep variants, stub API server
# ------------------------------------------------------------------------------

cat >"$BIN/ollama" <<'EOF'
#!/bin/sh
echo "ollama version is ${FAKE_OLLAMA_VERSION:-0.0.1}"
EOF

cat >"$BIN/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF

cat >"$BIN/pgrep" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$BIN/ollama" "$BIN/sudo" "$BIN/pgrep"

# A pgrep that claims a daemon is running (used for the remote-host check).
PGBIN="$WORKDIR/pgok"
mkdir -p "$PGBIN"
printf '#!/bin/sh\nexit 0\n' >"$PGBIN/pgrep"
chmod +x "$PGBIN/pgrep"

cat >"$WORKDIR/server.py" <<'EOF'
import http.server
import json
import os
import socketserver
import sys
import threading

ROOT = sys.argv[1]
PORT_FILE = sys.argv[2]
SOCK = sys.argv[3] if len(sys.argv) > 3 else ""


def read(name, default):
    try:
        with open(os.path.join(ROOT, name)) as handle:
            return handle.read().strip()
    except OSError:
        return default


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, obj, extra=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/version":
            self._send(200, {"version": read("api_version", "0.0.1")})
        elif self.path == "/releases":
            self._send(200, {"tag_name": "v" + read("latest", "9.9.9")})
        elif self.path == "/ratelimited":
            self._send(403, {"message": "rate limited"}, {"Retry-After": "60"})
        elif self.path == "/malformed":
            self._send(200, {})
        else:
            self.send_error(404)

    def log_message(self, *args):
        pass


httpd = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as handle:
    handle.write(str(httpd.server_address[1]))

if SOCK:
    class UnixHTTPServer(socketserver.UnixStreamServer):
        allow_reuse_address = True
        server_name = "localhost"
        server_port = 0

    try:
        if os.path.exists(SOCK):
            os.unlink(SOCK)
        unixd = UnixHTTPServer(SOCK, Handler)
        threading.Thread(target=unixd.serve_forever, daemon=True).start()
    except OSError:
        pass

httpd.serve_forever()
EOF

UNIX_SOCK="$WORKDIR/ollama.sock"
python3 "$WORKDIR/server.py" "$WORKDIR" "$WORKDIR/port" "$UNIX_SOCK" &
SRV_PID=$!

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$WORKDIR/port" ] && break
    sleep 0.1
done

PORT=""
[ -s "$WORKDIR/port" ] && PORT="$(cat "$WORKDIR/port")"
if [ -z "$PORT" ]; then
    printf 'stub server failed to start\n' >&2
    exit 2
fi

API_BASE="127.0.0.1:$PORT"
RELEASES_URL="http://$API_BASE/releases"

# set_versions <daemon-version> <latest-release>
set_versions() {
    printf '%s\n' "$1" >"$WORKDIR/api_version"
    printf '%s\n' "$2" >"$WORKDIR/latest"
}

# Wrapper so every run gets the stub environment without repeating it.
RUNNER="$WORKDIR/run_sut.sh"
{
    echo '#!/usr/bin/env bash'
    echo "export OLLAMA_HOST='$API_BASE'"
    echo "export OLLAMA_RELEASES_API='$RELEASES_URL'"
    echo "export PATH='$BIN:$PATH'"
    echo '# Default to a harmless stand-in: no test may reach the real installer.'
    echo '[[ -n "${OLLAMA_INSTALL_URL:-}" ]] || export OLLAMA_INSTALL_URL="file://'"$WORKDIR"'/install_fail.sh"'
    echo '[[ -n "${OLLAMA_INSTALL_URL:-}" ]] && export OLLAMA_INSTALL_URL'
    echo '[[ -n "${TMPDIR:-}" ]] && export TMPDIR'
    echo "exec '$BASH' '$SUT' \"\$@\""
} >"$RUNNER"
chmod +x "$RUNNER"

# Stand-in installers.
cat >"$WORKDIR/install_ok.sh" <<EOF
#!/bin/sh
printf '9.9.9\n' > '$WORKDIR/api_version'
echo 'fake install complete'
exit 0
EOF
cat >"$WORKDIR/install_suffix.sh" <<EOF
#!/bin/sh
printf '9.9.9+test\n' > '$WORKDIR/api_version'
echo 'fake install complete (suffix build)'
exit 0
EOF
cat >"$WORKDIR/install_buggy.sh" <<EOF
#!/bin/sh
printf '9.9.9\n' > '$WORKDIR/api_version'
echo 'fake install complete, optional step failed'
exit 3
EOF
cat >"$WORKDIR/install_fail.sh" <<'EOF'
#!/bin/sh
echo 'fake install failed early'
exit 1
EOF
: >"$WORKDIR/install_empty.sh"
cat >"$WORKDIR/install_html.sh" <<'EOF'
<!DOCTYPE html>
<html><body>not an installer</body></html>
EOF
chmod +x "$WORKDIR"/install_*.sh

INSTALLBIN="$WORKDIR/installbin"
mkdir -p "$INSTALLBIN"
cat >"$WORKDIR/install_fresh.sh" <<EOF
#!/bin/sh
cat > '$INSTALLBIN/ollama' <<'SCRIPT'
#!/bin/sh
echo "ollama version is \${FAKE_OLLAMA_VERSION:-9.9.9}"
SCRIPT
chmod +x '$INSTALLBIN/ollama'
printf '9.9.9\n' > '$WORKDIR/api_version'
echo 'fake fresh install complete'
exit 0
EOF
chmod +x "$WORKDIR/install_fresh.sh"

PTY=false
command -v script >/dev/null 2>&1 && PTY=true
SETSID=false
if command -v setsid >/dev/null 2>&1 && setsid -w true >/dev/null 2>&1; then
    SETSID=true
fi

# Build a PATH containing only the required tools (optionally omitting some).
make_path() {
    local dir="$1" c omit skip
    shift
    mkdir -p "$dir"
    for c in curl sed grep sort head tail tr cut wc mktemp basename id rm sh cat chmod printf ollama; do
        skip=false
        for omit in "$@"; do
            if [ "$c" = "$omit" ]; then skip=true; fi
        done
        $skip && continue
        if [ "$c" = "ollama" ]; then
            ln -sf "$BIN/ollama" "$dir/ollama"
        else
            ln -sf "$(command -v "$c")" "$dir/$c"
        fi
    done
}

NOOLLAMA="$WORKDIR/noollama"
make_path "$NOOLLAMA" ollama
ln -sf "$BIN/sudo" "$NOOLLAMA/sudo"

NOCURL="$WORKDIR/nocurl"
make_path "$NOCURL" curl

BADSED="$WORKDIR/badsed"
mkdir -p "$BADSED"
printf '#!/bin/sh\nexit 1\n' >"$BADSED/sed"
chmod +x "$BADSED/sed"

# Snapshot used to prove the suite never writes into the repository.
snapshot_paths() {
    find "$SUT_DIR" -path "$SUT_DIR/.git" -prune -o -print | sort
}
SUT_SUM="$(cksum <"$SUT")"
TEST_SUM="$(cksum <"$SOURCE")"
DIR_SNAPSHOT="$(snapshot_paths)"

# ==============================================================================
section "CLI surface"
# ==============================================================================

ran_code "-V exits 0" 0 "$BASH" "$RUNNER" -V
says "-V prints the script version" "check_ollama.sh v1.5"

ran_code "-h exits 0" 0 "$BASH" "$RUNNER" -h
says "-h prints usage" "Usage:"
says "-h documents the update flags" "--no-update"
says "-h documents exit code 6" "Missing dependency"

ran_code "an unknown option exits 1" 1 "$BASH" "$RUNNER" --bogus
says "the unknown option is reported" "Unknown option: --bogus"

ran_code "a positional argument exits 1" 1 "$BASH" "$RUNNER" somefile
says "the stray argument is reported" "Unexpected argument: somefile"

ran_code "an argument after -- exits 1" 1 "$BASH" "$RUNNER" -- somefile
says "the trailing argument is reported" "Unexpected argument: somefile"

# ==============================================================================
section "environment preflight"
# ==============================================================================

ran_code "a missing curl exits 6" 6 env PATH="$NOCURL" "$BASH" "$SUT"
says "the missing command is named" "Missing required command(s): curl"

ran_code "a broken sed exits 6" 6 env PATH="$BADSED:$PATH" "$BASH" "$SUT"
says "the broken parser is reported" "does not work"

# ==============================================================================
section "not installed"
# ==============================================================================

ran_code "no ollama on PATH with -n exits 1" 1 env PATH="$NOOLLAMA" "$BASH" "$SUT" -n
says "the missing install is reported" "Ollama is not installed"
says "the official installer is mentioned" "Official installer:"
says "-n skips install" "Install skipped (-n/--no-update)"

if $SETSID; then
    ran_code "no ollama on PATH with no terminal exits 1" 1 \
        env PATH="$NOOLLAMA" "$(command -v setsid)" -w "$BASH" "$SUT"
    says "no terminal install hint is shown" "No terminal available; use -y to install automatically"
else
    SKIPPED=$((SKIPPED + 2))
    note "    (setsid not usable: no-terminal install check skipped)"
fi

ran_code "remote host refuses local install" 1 \
    env PATH="$NOOLLAMA" OLLAMA_HOST="10.0.0.5:11434" "$BASH" "$SUT" -y
says "remote install refusal is explained" "refusing to install Ollama on this machine"

set_versions 9.9.9 9.9.9
ran_code "fresh install with -y succeeds" 0 \
    env PATH="$INSTALLBIN:$NOOLLAMA" OLLAMA_HOST="$API_BASE" \
        OLLAMA_RELEASES_API="$RELEASES_URL" \
        OLLAMA_INSTALL_URL="file://$WORKDIR/install_fresh.sh" \
        "$BASH" "$SUT" -y
says "fresh install completes" "Installation complete; the daemon now reports v9.9.9"
says "post-install check runs" "Ollama is up to date (v9.9.9)"
rm -f "$INSTALLBIN/ollama"

set_versions 0.0.1 9.9.9
ran_code "fresh install failure exits 5" 5 \
    env PATH="$INSTALLBIN:$NOOLLAMA" OLLAMA_HOST="$API_BASE" \
        OLLAMA_RELEASES_API="$RELEASES_URL" \
        OLLAMA_INSTALL_URL="file://$WORKDIR/install_fail.sh" \
        "$BASH" "$SUT" -y
says "fresh install failure is reported" "Installer exited with status 1"

if $PTY; then
    set_versions 9.9.9 9.9.9
    # Ensure no leftover ollama in INSTALLBIN from previous test? install_fresh creates it; install_fail did not.
    rm -f "$INSTALLBIN/ollama"
    run_pty y 0 "accepting install prompt succeeds" \
        env PATH="$INSTALLBIN:$NOOLLAMA" OLLAMA_HOST="$API_BASE" \
            OLLAMA_RELEASES_API="$RELEASES_URL" \
            OLLAMA_INSTALL_URL="file://$WORKDIR/install_fresh.sh" \
            "$BASH" "$SUT"
    says "install prompt is shown" "Install Ollama now using the official installer? [y/N]"
    rm -f "$INSTALLBIN/ollama"
    set_versions 9.9.9 9.9.9
    run_pty n 1 "declining install prompt exits 1" \
        env PATH="$INSTALLBIN:$NOOLLAMA" OLLAMA_HOST="$API_BASE" \
            OLLAMA_RELEASES_API="$RELEASES_URL" \
            "$BASH" "$SUT"
    says "install decline is reported" "Install skipped."
else
    SKIPPED=$((SKIPPED + 4))
    note "    (script(1) not found: install prompt checks skipped)"
fi

# ==============================================================================
section "daemon not running"
# ==============================================================================

set_versions 0.0.1 9.9.9
ran_code "a dead API and no process exits 2" 2 \
    env OLLAMA_HOST="127.0.0.1:1" OLLAMA_RELEASES_API="$RELEASES_URL" \
    PATH="$BIN:$PATH" "$BASH" "$SUT"
says "the stopped daemon is reported" "skipping the version check"

# ==============================================================================
section "version reporting"
# ==============================================================================

set_versions 1.2.3 1.2.3
ran_code "matching versions exit 0" 0 "$BASH" "$RUNNER"
says "the up-to-date state is reported" "Ollama is up to date (v1.2.3)"
says "the summary is printed" "Done."

set_versions 0.0.1 9.9.9
ran_code "an older local version exits 4 with -n" 4 "$BASH" "$RUNNER" -n
says "both versions are reported" "Update available: installed v0.0.1, latest v9.9.9"
says "the release page is offered" "Release page:"
says_not "-n never prompts" "Update now? [y/N]"
says_not "-n never downloads" "Downloading the installer"

set_versions 9.9.9 1.0.0
ran_code "a locally newer version exits 0" 0 "$BASH" "$RUNNER" -n
says "the newer-local state is reported" "is newer than the latest release"

ran_code "a malformed release exits 3" 3 \
    env OLLAMA_HOST="$API_BASE" OLLAMA_RELEASES_API="http://$API_BASE/malformed" \
    PATH="$BIN:$PATH" "$BASH" "$SUT"
says "the malformed response is reported" "was malformed"

ran_code "a rate-limited release exits 3" 3 \
    env OLLAMA_HOST="$API_BASE" OLLAMA_RELEASES_API="http://$API_BASE/ratelimited" \
    PATH="$BIN:$PATH" "$BASH" "$SUT"
says "the rate limit is named" "rate limited"
says "the retry delay is surfaced" "Retry after 60s"

ran_code "an unreachable release exits 3" 3 \
    env OLLAMA_HOST="$API_BASE" OLLAMA_RELEASES_API="http://127.0.0.1:1/releases" \
    PATH="$BIN:$PATH" "$BASH" "$SUT"
says "the unreachable endpoint is reported" "Could not reach"

# ==============================================================================
section "quiet mode"
# ==============================================================================

set_versions 0.0.1 9.9.9
ran_code "-q -n exits 4" 4 "$BASH" "$RUNNER" -q -n
says_not "the banner is suppressed" "Check Ollama Utility"
says_not "INFO lines are suppressed" "[INFO]"
says "warnings are still printed" "[WARN]"

# ==============================================================================
section "no terminal"
# ==============================================================================

if $SETSID; then
    set_versions 0.0.1 9.9.9
    ran_code "a detached run exits 4" 4 \
        env OLLAMA_HOST="$API_BASE" OLLAMA_RELEASES_API="$RELEASES_URL" \
        PATH="$BIN:$PATH" setsid -w "$BASH" "$SUT"
    says "the missing terminal is explained" "No terminal available; use -y"
    says_not "a detached run never prompts" "Update now? [y/N]"
else
    SKIPPED=$((SKIPPED + 1))
    note "    (setsid not usable: no-terminal check skipped)"
fi

# ==============================================================================
section "interactive prompt"
# ==============================================================================

if $PTY; then
    set_versions 0.0.1 9.9.9
    run_pty n 4 "declining the prompt exits 4" "$BASH" "$RUNNER"
    says "the prompt is shown" "Update now? [y/N]"
    says "the decline is reported" "Update skipped."

    set_versions 0.0.1 9.9.9
    run_pty y 0 "accepting the prompt updates" \
        env OLLAMA_INSTALL_URL="file://$WORKDIR/install_ok.sh" "$BASH" "$RUNNER"
    says "the update is confirmed" "Update complete; the daemon now reports v9.9.9"

    set_versions 0.0.1 9.9.9
    run_pty "Yes" 0 "a capitalised answer is accepted" \
        env OLLAMA_INSTALL_URL="file://$WORKDIR/install_ok.sh" "$BASH" "$RUNNER"

    set_versions 0.0.1 9.9.9
    run_pty y 0 "a late installer failure still counts as success" \
        env OLLAMA_INSTALL_URL="file://$WORKDIR/install_buggy.sh" "$BASH" "$RUNNER"
    says "the installer status is surfaced" "Installer exited with status 3"
    says "the daemon version wins" "Update complete; the daemon now reports v9.9.9"

    set_versions 0.0.1 9.9.9
    run_pty y 0 "a suffixed build still counts as success" \
        env OLLAMA_INSTALL_URL="file://$WORKDIR/install_suffix.sh" "$BASH" "$RUNNER"
    says "the suffixed version is reported" "now reports v9.9.9+test"

    # Redirected stdout must not hide the prompt, and must not contain it.
    set_versions 0.0.1 9.9.9
    ACTUAL=0
    printf 'n\n' | env OLLAMA_HOST="$API_BASE" OLLAMA_RELEASES_API="$RELEASES_URL" \
        PATH="$BIN:$PATH" script -qec \
        "'$BASH' '$SUT' > '$WORKDIR/redir.out'" /dev/null >"$OUT" 2>&1
    ACTUAL=${PIPESTATUS[1]}
    check_code "a redirected run still exits 4" 4
    says "the prompt reaches the terminal" "Update now? [y/N]"
    cond "the redirected log has no prompt" \
        bash -c '! grep -qF "Update now? [y/N]" "$1"' _ "$WORKDIR/redir.out"

    # Quiet update still prints one verdict.
    set_versions 0.0.1 9.9.9
    run_pty y 0 "quiet accept exits 0" \
        env OLLAMA_INSTALL_URL="file://$WORKDIR/install_ok.sh" "$BASH" "$RUNNER" -q
    says "quiet mode still reports the update" "Updated Ollama to v9.9.9"
    says_not "quiet mode suppresses INFO" "[INFO]"

    # NO_COLOR is honoured on a real terminal.
    set_versions 1.2.3 1.2.3
    run_pty - 0 "a NO_COLOR run exits 0" \
        env NO_COLOR=1 "$BASH" "$RUNNER" -n
    says_not "NO_COLOR removes escape codes" $'\033'
else
    SKIPPED=$((SKIPPED + 9))
    note "    (script(1) not found: 9 interactive checks skipped)"
fi

# ==============================================================================
section "remoteness and sockets"
# ==============================================================================

set_versions 0.0.1 9.9.9
ran_code "a remote daemon refuses to update" 4 \
    env OLLAMA_HOST="127.0.0.2:11434" OLLAMA_RELEASES_API="$RELEASES_URL" \
    PATH="$PGBIN:$BIN:$PATH" "$BASH" "$SUT" -y
says "the refusal is explained" "refusing to update this machine"

if [ -S "$UNIX_SOCK" ]; then
    set_versions 1.2.3 1.2.3
    ran_code "a Unix socket daemon is supported" 0 \
        env OLLAMA_HOST="unix://$UNIX_SOCK" OLLAMA_RELEASES_API="$RELEASES_URL" \
        PATH="$BIN:$PATH" "$BASH" "$SUT" -n
    says "the socket endpoint is shown" "Daemon is running at unix:"
else
    SKIPPED=$((SKIPPED + 1))
    note "    (cannot bind a Unix socket: check skipped)"
fi

# ==============================================================================
section "installer failures"
# ==============================================================================

set_versions 0.0.1 9.9.9
ran_code "an installer that changes nothing exits 5" 5 \
    env OLLAMA_UPDATE_TIMEOUT=2 OLLAMA_INSTALL_URL="file://$WORKDIR/install_fail.sh" \
    "$BASH" "$RUNNER" -y
says "the failure names the exit status" "Installer exited with status 1"
says "the unchanged daemon is reported" "still reports '0.0.1'"

set_versions 0.0.1 9.9.9
ran_code "an empty installer exits 5" 5 \
    env OLLAMA_INSTALL_URL="file://$WORKDIR/install_empty.sh" "$BASH" "$RUNNER" -y
says "the empty download is reported" "installer is empty"

set_versions 0.0.1 9.9.9
ran_code "an HTML download exits 5" 5 \
    env OLLAMA_INSTALL_URL="file://$WORKDIR/install_html.sh" "$BASH" "$RUNNER" -y
says "the HTML page is rejected" "looks like an HTML page"

set_versions 1.2.3 1.2.3
ran_code "-y with nothing to do exits 0" 0 "$BASH" "$RUNNER" -y
says_not "no installer is downloaded when current" "Downloading the installer"

# ==============================================================================
section "temporary files"
# ==============================================================================

TT="$WORKDIR/tmpdir"
mkdir -p "$TT"
set_versions 0.0.1 9.9.9
ran_code "an update run exits 0" 0 \
    env TMPDIR="$TT" OLLAMA_INSTALL_URL="file://$WORKDIR/install_buggy.sh" \
    "$BASH" "$RUNNER" -y
cond "TMPDIR is empty after the run" test -z "$(ls -A "$TT")"

# ==============================================================================
section "the repository is left alone"
# ==============================================================================

cond "the script under test is unchanged" \
    test "$SUT_SUM" = "$(cksum <"$SUT")"
cond "this suite is unchanged" \
    test "$TEST_SUM" = "$(cksum <"$SOURCE")"
cond "the repository file list is unchanged" \
    test "$DIR_SNAPSHOT" = "$(snapshot_paths)"

# ==============================================================================
note ""
note "----------------------------------------------------------------------"

if ((FAILED > 0)); then
    printf '%b  %d passed, %d FAILED%b' "$RED" "$PASSED" "$FAILED" "$RESET"
    ((SKIPPED > 0)) && printf ', %d skipped' "$SKIPPED"
    printf '\n'
    exit 1
fi
printf '%b  %d passed%b' "$GREEN" "$PASSED" "$RESET"
((SKIPPED > 0)) && printf ', %d skipped' "$SKIPPED"
printf '\n'
exit 0
