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
# Version: 1.3
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
# fixtures: fake ollama, stub sudo, failing pgrep, stub API server
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

cat >"$WORKDIR/server.py" <<'EOF'
import http.server
import json
import os
import sys

ROOT = sys.argv[1]


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        def read(name, default):
            try:
                with open(os.path.join(ROOT, name)) as handle:
                    return handle.read().strip()
            except OSError:
                return default

        if self.path == "/api/version":
            self._send({"version": read("api_version", "0.0.1")})
        elif self.path == "/releases":
            self._send({"tag_name": "v" + read("latest", "9.9.9")})
        else:
            self.send_error(404)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(ROOT, "port"), "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
EOF

python3 "$WORKDIR/server.py" "$WORKDIR" &
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
    echo 'export PATH='"'$BIN:$PATH'"
    echo '# Default to a harmless stand-in: no test may reach the real installer.'
    echo '[[ -n "${OLLAMA_INSTALL_URL:-}" ]] || export OLLAMA_INSTALL_URL="file://'"$WORKDIR"'/install_fail.sh"'
    echo '[[ -n "${OLLAMA_INSTALL_URL:-}" ]] && export OLLAMA_INSTALL_URL'
    echo '[[ -n "${TMPDIR:-}" ]] && export TMPDIR'
    echo "exec '$BASH' '$SUT' \"\$@\""
} >"$RUNNER"
chmod +x "$RUNNER"

# Stand-in installers. "ok" writes the new version then exits cleanly, "buggy"
# reproduces the Arch-family installer abort (binary in place, exit non-zero),
# "fail" changes nothing.
cat >"$WORKDIR/install_ok.sh" <<EOF
#!/bin/sh
printf '9.9.9\n' > '$WORKDIR/api_version'
echo 'fake install complete'
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
chmod +x "$WORKDIR"/install_*.sh

PTY=false
command -v script >/dev/null 2>&1 && PTY=true

# Snapshot used to prove the suite never writes into the repository.
snapshot_paths() {
    find "$SUT_DIR" -path "$SUT_DIR/.git" -prune -o -print | sort
}
SUT_SUM="$(cksum <"$SUT")"
TEST_SUM="$(cksum <"$SOURCE")"
DIR_SNAPSHOT="$(snapshot_paths)"

mkdir -p "$WORKDIR/empty"

# ==============================================================================
section "CLI surface"
# ==============================================================================

ran_code "-V exits 0" 0 "$BASH" "$RUNNER" -V
says "-V prints the script version" "check_ollama.sh v1.3"

ran_code "-h exits 0" 0 "$BASH" "$RUNNER" -h
says "-h prints usage" "Usage:"
says "-h documents the update flags" "--no-update"

ran_code "an unknown option exits 1" 1 "$BASH" "$RUNNER" --bogus
says "the unknown option is reported" "Unknown option: --bogus"

ran_code "a positional argument exits 1" 1 "$BASH" "$RUNNER" somefile
says "the stray argument is reported" "Unexpected argument: somefile"

# ==============================================================================
section "not installed"
# ==============================================================================

ran_code "no ollama on PATH exits 1" 1 \
    env PATH="$WORKDIR/empty" "$BASH" "$SUT"
says "the missing install is reported" "Ollama is not installed"

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

ran_code "an unreadable release endpoint exits 3" 3 \
    env OLLAMA_HOST="$API_BASE" OLLAMA_RELEASES_API="http://$API_BASE/missing" \
    PATH="$BIN:$PATH" "$BASH" "$SUT"
says "the failed check is reported" "version check skipped"

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

set_versions 0.0.1 9.9.9
ran_code "a piped run exits 4" 4 "$BASH" "$RUNNER"
says "the missing terminal is explained" "Not a terminal; use -y"
says_not "a piped run never prompts" "Update now? [y/N]"

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
    says "the summary names the new version" "Ollama updated to v9.9.9"
    says_not "a clean installer produces no warning" "Installer exited with status"

    set_versions 0.0.1 9.9.9
    run_pty y 0 "a late installer failure still counts as success" \
        env OLLAMA_INSTALL_URL="file://$WORKDIR/install_buggy.sh" "$BASH" "$RUNNER"
    says "the installer status is surfaced" "Installer exited with status 3"
    says "the daemon version wins" "Update complete; the daemon now reports v9.9.9"
else
    SKIPPED=$((SKIPPED + 3))
    note "    (script(1) not found: 3 interactive checks skipped)"
fi

# ==============================================================================
section "installer failures"
# ==============================================================================

set_versions 0.0.1 9.9.9
ran_code "an installer that changes nothing exits 5" 5 \
    env OLLAMA_INSTALL_URL="file://$WORKDIR/install_fail.sh" "$BASH" "$RUNNER" -y
says "the failure names the exit status" "Installer exited with status 1"
says "the unchanged daemon is reported" "still reports '0.0.1'"

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
    env TMPDIR="$TT" OLLAMA_INSTALL_URL="file://$WORKDIR/install_buggy.sh" "$BASH" "$RUNNER" -y
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
