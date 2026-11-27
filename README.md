# check_ollama

Checks that Ollama is installed and that its daemon is running, compares the local version against the latest stable GitHub release, and — when a newer release exists — offers to install it with the official installer.

**Version:** 1.3 · **Author:** Gino Bogo · **License:** MIT

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

When the answer to (3) is yes and the script is attached to a terminal, it asks whether to update. Saying `y` downloads the official `install.sh`, runs it with `sudo`, and then verifies the result by polling the daemon — because the installer can exit non-zero in an optional post-install step after the new binary is already in place.

The script is read-only until you confirm an update (or pass `-y`).

## Requirements

- **Bash 4.0+** (uses arrays; checked implicitly by the syntax used).
- **curl** for the daemon API, the GitHub release metadata and the installer.
- Standard userland: `sed`, `grep`, `sort`, `head`, `mktemp`, `pgrep`.
- For updating: `sudo` when not already running as root.
- `sort -V` must be available (GNU coreutils, BusyBox, or BSD `sort` with version sort).

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
```

## Usage

```text
check_ollama.sh [options]
```

Options may be given in any order. `--` ends option parsing.

## Options

| Flag | Long form | Description |
| --- | --- | --- |
| `-h` | `--help` | Show usage and exit 0 |
| `-V` | `--version` | Print the script version and exit 0 |
| `-q` | `--quiet` | Suppress the banner and all `[INFO]`/`[NOTE]` lines |
| `-y` | `--yes` | Update without asking for confirmation |
| `-n` | `--no-update` | Never prompt or update; only report |

If both `-y` and `-n` are given, the last one wins.

## Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `OLLAMA_HOST` | `127.0.0.1:11434` | Daemon address; `host:port` or a full URL |
| `OLLAMA_INSTALL_URL` | `https://ollama.com/install.sh` | Installer downloaded and run on update |
| `OLLAMA_RELEASES_API` | GitHub `releases/latest` | Release metadata endpoint (JSON with `tag_name`) |

The two URL variables exist so the update and version-check flows can be exercised with stand-ins; they are not needed in normal use.

## Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | Installed and running, no newer release — or the update succeeded |
| `1` | Ollama is not installed (no `ollama` on `PATH`) |
| `2` | Installed but the daemon is not running (web check skipped) |
| `3` | Version check failed: GitHub unreachable, or the response could not be parsed |
| `4` | A newer release exists but was not installed (declined, `-n`, or no terminal) |
| `5` | An update was attempted but failed, or the daemon did not reach the new version |

## How It Works

1. **Installed?** `command -v ollama`. Missing → exit `1`, nothing else runs.
2. **Running?** `GET $OLLAMA_HOST/api/version`. If the API does not answer but an `ollama` process exists, the script warns and continues; if neither is true, exit `2` and skip the web check.
3. **Local version.** Taken from the API response, falling back to `ollama --version`.
4. **Latest release.** Parsed from `tag_name` of the latest stable GitHub release (`v` prefix stripped). Pre-releases such as `v0.40.19-rc0` are deliberately ignored because `releases/latest` excludes them.

Versions are compared with `sort -V`, so `0.40.9` sorts before `0.40.18`. If the local version is newer than the latest release, the script says so and exits `0`.

## Update Flow

When a newer release is found:

- **Interactive terminal:** prints the two commands that will run, then `Update now? [y/N]` (default **No**).
- **`-y`:** skips the prompt.
- **`-n`, or no terminal** (cron, pipe, CI): reports and exits `4` — an unattended run never blocks.

On confirmation the script:

1. Detects whether it must use `sudo` (skipped when already root) and downloads the installer to a `mktemp` file, removed on exit.
2. Runs the installer, capturing its exit status instead of aborting on it.
3. Polls `/api/version` for up to five seconds for the expected version.
4. Succeeds (`0`) if the daemon reports the new version — even when the installer exited non-zero, with a warning naming that status.
5. Fails (`5`) only when the daemon still reports a different version, and suggests restarting the service.

That last rule matters on Arch-family systems: the official installer's optional GPU/CUDA block runs `OS_VERSION=$VERSION_ID` under `set -eu`, but such distributions have no `VERSION_ID` in `/etc/os-release`. The installer therefore aborts **after** installing the binary and (re)starting the service. The daemon check reports the upgrade correctly where the installer's exit code would not.

## Examples

Check the local daemon and be offered an update:

```sh
check_ollama.sh
```

Report only, suitable for a timer or CI job:

```sh
check_ollama.sh -q -n
```

Update unattended, even though there is no terminal:

```sh
check_ollama.sh -y
```

Check a remote daemon:

```sh
OLLAMA_HOST=10.0.0.5:11434 check_ollama.sh -n
```

## Behavioral Notes

- The banner and `[INFO]`/`[NOTE]` lines are colourised; `[WARN]`, `[FAIL]` and the update prompt are always printed, even with `-q`.
- Colours are emitted unconditionally (no TTY detection), matching the sibling `replace_files` project's style.
- The installer is downloaded to a temp file and executed — never piped into a root shell.
- Updating restarts the Ollama service; running models are unloaded.
- The script performs no cleanup of models or configuration.

## Testing

Run the regression suite:

```sh
bash tests/test_check_ollama.sh          # default
bash tests/test_check_ollama.sh -q       # failures + summary only
bash tests/test_check_ollama.sh -v       # verbose
```

The suite is hermetic: a small Python stub serves the daemon API and the release metadata, while a fake `ollama` binary, a stub `sudo`, a failing `pgrep` and a stand-in installer are placed on `PATH`. It covers the CLI surface, not-installed and not-running paths, up-to-date and update-available reporting, quiet mode, interactive accept/decline through a pty (skipped when `script` is unavailable), installer failures with and without a successful upgrade, temp-file cleanup, and repository immutability.

`python3` is required for the stub server; the pty checks require `script` from util-linux.

## Disclaimer

The update path runs the official Ollama installer with `sudo`. It downloads and executes code from the network, restarts the Ollama service, and may modify system packages (notably the GPU/CUDA step on Debian/Ubuntu). Review the installer first if you need to; use `-n` to keep the script strictly read-only. The software is provided "AS IS", without warranty of any kind, as stated in the LICENSE; the authors are not liable for data loss or any other damage resulting from its use.

## License

MIT — see [LICENSE](LICENSE).
