# check_ollama

Checks that Ollama is installed and that its daemon is running, compares the local version against the latest stable GitHub release, and — when missing or outdated — offers to install or update it with the official Ollama installer.

**Version:** 1.5 · **Author:** Gino Bogo · **License:** MIT

## Contents

- [Purpose](#purpose)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [Options](#options)
- [Environment](#environment)
- [Exit Codes](#exit-codes)
- [How It Works](#how-it-works)
- [Update Flow](#update-flow)
- [Safety](#safety)
- [Examples](#examples)
- [Behavioral Notes](#behavioral-notes)
- [Testing](#testing)
- [Disclaimer](#disclaimer)
- [License](#license)

## Purpose

`check_ollama.sh` answers three questions in one run:

1. Is `ollama` installed (and where)?
2. Is the daemon reachable, and which version does it report?
3. Is that version older than the latest **stable** release on GitHub?

When Ollama is missing, an interactive terminal run can install it using the official Ollama installer. When the answer to (3) is yes, it can update it the same way. The script downloads the official `install.sh`, runs it with `sudo`, and then verifies the result by polling the daemon — because the installer can exit non-zero in an optional post-install step after the new binary/service is already in place.

The script is read-only until you confirm an install/update (or pass `-y`).

## Requirements

- **Bash 4.0+**. The script checks this at startup and exits `6` if unsupported.
- **curl** for the daemon API, release metadata and the installer.
- **sort -V** for version comparison. The script probes this at startup.
- Standard userland: `sed`, `grep`, `head`, `tail`, `tr`, `cut`, `wc`, `mktemp`, `basename`, `id`.
- Optional: `pgrep` (process fallback when the API is unreachable), `sha256sum` (prints the installer digest before execution).
- For updating: `sudo` when not already running as root.

Missing required commands or an unsupported `sort -V` are reported explicitly and cause exit `6`.

Tested on Linux (Manjaro/Arch-family). The update path also works on Debian/Ubuntu, where the installer's optional CUDA step is fully supported.

## Installation

No build step. The script is self-contained and executable.

```sh
chmod +x check_ollama.sh
```

Keep it in this directory and link it onto your `$PATH`:

```sh
ln -s /home/share/Projects/Shell/check_ollama/check_ollama.sh ~/.local/bin/check_ollama.sh
```

Companion files:

- `check_ollama.sh` — the tool itself.
- `tests/test_check_ollama.sh` — the regression suite (hermetic; never writes into the repo).

## Quick Start

```sh
check_ollama.sh             # check, and ask before updating
check_ollama.sh -n          # check only, never prompt
check_ollama.sh -q -n       # cron-friendly: warnings and errors only
check_ollama.sh -y          # unattended update
```

## Usage

```text
check_ollama.sh [options]
```

Options may be given in any order. `--` ends option parsing; unexpected arguments after `--` are rejected.

## Options

| Flag | Long form | Description |
| --- | --- | --- |
| `-h` | `--help` | Show usage and exit 0 |
| `-V` | `--version` | Print the script version and exit 0 |
| `-q` | `--quiet` | Suppress the banner and `[INFO]`/`[NOTE]` lines |
| `-y` | `--yes` | Install or update without asking for confirmation |
| `-n` | `--no-update` | Never prompt, install, or update; only report |

If both `-y` and `-n` are given, the last one wins.

`-q` still prints warnings and errors. After a successful install/update it also prints one verdict line, because state changed.

## Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `OLLAMA_HOST` | `127.0.0.1:11434` | Daemon address: `host:port`, full URL, `unix:///path`, or an absolute socket path |
| `OLLAMA_INSTALL_URL` | `https://ollama.com/install.sh` | Installer downloaded and run on update |
| `OLLAMA_RELEASES_API` | GitHub `releases/latest` | Release metadata endpoint (JSON with `tag_name`) |
| `OLLAMA_RELEASES_PAGE` | GitHub release page, or the API URL when `OLLAMA_RELEASES_API` is overridden | Human-readable release page shown to the user |
| `OLLAMA_UPDATE_TIMEOUT` | `20` | Seconds to wait for the daemon to report the new version after an update |
| `NO_COLOR` | unset | Disable ANSI colours when set to any non-empty value |

The URL and timeout variables are mainly useful for mirrors and tests; they are not needed in normal use.

## Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | Installed and running, no newer release — or the install/update succeeded |
| `1` | Ollama is not installed, and no install was performed (declined, `-n`, no terminal, or remote host) |
| `2` | Installed but the daemon is not running (web check skipped) |
| `3` | Version check failed: network error, HTTP error, rate limit, or malformed response |
| `4` | A newer release exists but was not installed (declined, `-n`, no terminal, or remote daemon) |
| `5` | An install/update was attempted but failed, or the daemon did not reach the expected version |
| `6` | Missing dependency or unsupported environment |

## How It Works

1. **Preflight.** Verifies Bash 4+, required commands and `sort -V`. Missing tools cause exit `6`.
2. **Installed?** `command -v ollama`. Missing → offers the official installer (tty/`-y`), otherwise exits `1`. On successful install it continues with the normal checks.
3. **Running?** `GET $OLLAMA_HOST/api/version`. If the API does not answer but `pgrep -x ollama` sees a process, the script warns and continues; if neither is true, exit `2` and skip the web check.
4. **Local version.** Taken from the API response, falling back to `ollama --version`.
5. **Latest release.** Fetched from the configured release endpoint. HTTP 200 must contain a `tag_name`; 403/429 are reported as rate limits with `Retry-After` when present. Pre-releases such as `v0.40.19-rc0` are ignored by the default GitHub `releases/latest` endpoint.

Versions are compared with `sort -V`. Post-install/update verification accepts the expected version or any newer version, so a suffixed build such as `9.9.9+test` is not a false failure.

## Install / Update Flow

When Ollama is missing, or when a newer release is found:

- **Interactive terminal:** prints the commands that will run, then prompts on `/dev/tty` (default **No**). Accepts `y`, `Y`, `yes`, `YES`.
- **`-y`:** skips the prompt.
- **`-n` or no controlling terminal:** reports and exits `1` (missing install) or `4` (available update). An unattended run never blocks.
- **Remote daemon:** the script refuses to install/update the local machine and exits `1`/`4` with an explanation.

The installer is the official Ollama install script (`OLLAMA_INSTALL_URL`, default `https://ollama.com/install.sh`, from the official Ollama distribution/GitHub project).

On confirmation the script:

1. Detects whether it must use `sudo` (skipped when already root).
2. Downloads the installer to a `mktemp` file, removed on exit.
3. Rejects empty downloads and HTML pages before execution. If `sha256sum` is available, it logs the installer digest.
4. Runs the installer, capturing its exit status instead of aborting on it.
5. Polls `/api/version` until `OLLAMA_UPDATE_TIMEOUT` for the expected version or newer (or any version for a fresh install when release metadata is unavailable).
6. Succeeds (`0`) if the daemon reports an acceptable version — even when the installer exited non-zero, with a warning naming that status.
7. Fails (`5`) only when the daemon still does not report an acceptable version, and suggests the appropriate restart command.

## Safety

- The prompt is written to `/dev/tty`, so redirecting stdout (for example `check_ollama.sh > log`) cannot hide it. Without a controlling terminal, the script reports and exits `4`.
- The installer is downloaded to a temp file and executed — never piped into a root shell.
- Empty and HTML responses are rejected before execution; the SHA-256 digest is logged when `sha256sum` is present.
- Remote daemons are never updated from the local machine by this script.
- Unix sockets are supported via `curl --unix-socket`.
- Updating restarts the Ollama service; running models are unloaded.

## Examples

Check the local daemon and be offered an update:

```sh
check_ollama.sh
```

Report only, suitable for a timer or CI job:

```sh
check_ollama.sh -q -n
```

Update unattended:

```sh
check_ollama.sh -y
```

Check a remote daemon (report only):

```sh
OLLAMA_HOST=10.0.0.5:11434 check_ollama.sh -n
```

Check a Unix-socket daemon:

```sh
OLLAMA_HOST=unix:///var/run/ollama.sock check_ollama.sh -n
```

## Behavioral Notes

- Colours are emitted only when stdout is a TTY and `NO_COLOR` is not set.
- Warnings and errors are always printed, even with `-q`.
- The GitHub release check uses unauthenticated requests by default; a 403/429 is reported clearly, and `OLLAMA_RELEASES_API` can point at a mirror.
- The official installer can exit non-zero in an optional post-install step after the binary is already installed. The daemon version is the source of truth.

## Testing

Run the regression suite:

```sh
bash tests/test_check_ollama.sh          # default
bash tests/test_check_ollama.sh -q       # failures + summary only
bash tests/test_check_ollama.sh -v       # verbose
```

The suite is hermetic: a small Python stub serves daemon and release endpoints (including 403/rate-limit and malformed responses, plus an optional Unix socket), while fake binaries, stub `sudo`, and stand-in installers are placed on `PATH`. It covers CLI parsing, dependency preflight, missing-install flows, not-running daemons, version comparison, rate limits, malformed responses, quiet mode, no-TTY behavior, interactive pty prompts, redirected-stdout prompting, remote-host refusal, Unix sockets, installer sanity checks, timeout handling, temp-file cleanup, and repository immutability.

`python3` is required for the stub server. Pty checks require `script` (util-linux) and are skipped when unavailable; Unix-socket checks are skipped when the platform cannot bind one.

## Disclaimer

The install/update path runs the official Ollama installer with `sudo`. It downloads and executes code from the network, may install or restart the Ollama service, and may modify system packages (notably the GPU/CUDA step on Debian/Ubuntu). Review the installer first if you need to; use `-n` to keep the script strictly read-only. The software is provided "AS IS", without warranty of any kind, as stated in the LICENSE; the authors are not liable for data loss or any other damage resulting from its use.

## License

MIT — see [LICENSE](LICENSE).
