# Deployment Scripts

This folder contains two scripts to run commands on multiple remote hosts via SSH:

- `run_remote_command.ps1` — PowerShell implementation (Windows native). Requires `ssh`/`scp` in PATH.
- `run_remote_command_enhanced.sh` — Bash implementation (WSL, Git Bash or POSIX shell). Requires `ssh`/`scp`.
- `hosts.txt` — Example hosts file (one host per line; supports `user@host`).

Both scripts provide the same feature set:

- Key-based authentication (`-KeyFile` for PowerShell, `--key` for bash).
- Optional file transfer: copy a local file to each host before executing the command (`-LocalFile`/`--local-file`) and specify the remote destination (`-RemotePath`/`--remote-path`).
- Dry-run mode to preview scp/ssh commands without executing them.
- Verbose mode to print command lines being executed.
- Per-host stdout/stderr logs written into a `logs/` folder in the working directory.
- Summary CSV with Host, Target, StartTime, DurationSeconds, ExitCode, Success, OutFile, ErrFile.
- Retries with exponential backoff and full jitter for transient failures on scp/ssh.
---

## Readme structure

1. Flags and parameters for both scripts
2. Examples
3. Expected log output and summary CSV format
4. Security notes and tips
5. Next steps / improvements

---

## 1) Flags and parameters

# Deployment Scripts

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Shell](https://img.shields.io/badge/shell-Bash%20%7C%20PowerShell-orange.svg)

Provisioning helpers to run a single command (and optional file transfer) across multiple remote hosts using OpenSSH (ssh / scp).

Files in this folder

- `run_remote_command.ps1` — PowerShell implementation (Windows PowerShell / PowerShell Core). Uses the system OpenSSH client (`ssh`/`scp`).
- `run_remote_command_enhanced.sh` — POSIX-compatible Bash implementation (WSL, Git Bash, Linux). Uses `ssh`/`scp`/`rsync` where available.
- `hosts.txt` — Example hosts file (one host per line). Supports `user@host` per line.

Why this repo

These small scripts aim to be a pragmatic, dependency-light way to run simple commands or copy a single file to many hosts in parallel. They include retries with exponential backoff and full jitter, per-host logs, and a CSV summary for automation.

Table of contents

- Features
- Prerequisites
- Hosts file format
- Flags / parameters (PowerShell)
- Flags / parameters (Bash)
- Examples
- Logs and summary CSV
- Security
- Troubleshooting
- Contributing & License

## Features

- Run arbitrary commands on many hosts in parallel (configurable concurrency).
- Optional file transfer (scp) before executing the command.
- Dry-run and verbose modes to preview actions.
- Retries with exponential backoff + jitter for transient SSH/SCP failures.
- Per-host stdout/stderr logs and a single summary CSV.
- Optional collect/pull phase to retrieve artifacts after the remote command runs.

## Prerequisites

- OpenSSH client (ssh and scp) available in PATH on the machine running the scripts.
- For the Bash script: Bash (with common utilities: grep, awk, bc). Works well in WSL, Git Bash, Cygwin, or native Linux/macOS.
- For PowerShell: PowerShell 5+ or PowerShell Core and the system `ssh`/`scp` binaries.
- A hosts file (one host per line). See next section.

## Hosts file format

One host per non-empty line. Lines starting with `#` are ignored.

Examples:

- host1.example.com
- admin@host2.example.com
- 10.0.1.5

When a line contains `user@host` the explicit user is used; otherwise the scripts use the default user (if provided) or fall back to the SSH client defaults.

## Flags / parameters (PowerShell)

Script: `run_remote_command.ps1`

- `-HostsFile` (string, required): Path to the hosts file.
- `-Command` (string, required): Command to run on each host. Quote complex commands.
- `-KeyFile` (string): Path to private key for ssh/scp (passes `-i`). If omitted, ssh agent or default keys are used.
- `-LocalFile` (string): Local file path to copy to each host before execution.
- `-RemotePath` (string, default `~`): Destination path on the remote host where `LocalFile` will be placed.
- `-DryRun` (switch): Show scp/ssh commands and log actions without executing network calls.
- `-Verbose` (switch): Print extra progress and retry messages.
- `-Parallel` (int, default 10): Max concurrent sessions (runspaces).
- `-Timeout` (int, default 10): SSH ConnectTimeout seconds.
- `-Retries` (int, default 3): Number of attempts for scp/ssh (1 = no retry).
- `-BaseBackoff` (double, default 1.0): Base backoff seconds for exponential growth.
- `-MaxBackoff` (double, default 30.0): Maximum backoff cap in seconds.
- `-SkipHostKeyChecking` (switch): Adds `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` to ssh/scp (use with caution).
- `-Collect` (switch): Enable a collect phase to pull artifacts after the remote command completes.
- `-CollectFiles` (string): Files or glob patterns to collect from each host (quoted, space-separated).
- `-CollectMethod` (tar-scp|rsync|scp, default `tar-scp`): How to collect remote files.
- `-CollectDest` (string): Local directory root for collected files (defaults to `<OutputDir>/collected`).

Notes:

- When `-LocalFile` is provided the script will attempt to `scp` that file to each host before running the command. The scp step uses the same `-KeyFile` / `-Timeout` / `-SkipHostKeyChecking` settings.

## Flags / parameters (Bash)

Script: `run_remote_command_enhanced.sh`

- `-h|--hosts` (string, required): Hosts file path.
- `-c|--command` (string, required): Command to run remotely.
- `-u|--user` (string): Default SSH user (optional). Per-host `user@host` lines override this.
- `--key` (string): SSH private key (passed to `ssh`/`scp` via `-i`).
- `--local-file` (string): Local file to copy to each host before running the command.
- `--remote-path` (string, default `~`): Remote destination for the copied file.
- `--dry-run` (flag): Show actions without executing network calls.
- `--verbose` (flag): Print scp/ssh commands and retry messages.
- `--parallel` (int, default 10): Number of parallel sessions.
- `--timeout` (int, default 5): SSH connect timeout (seconds).
- `--retries` (int, default 3): Number of attempts for scp/ssh.
- `--base-backoff` (float, default 1.0): Base backoff seconds.
- `--max-backoff` (float, default 30.0): Max backoff seconds.
- `-k|--skip-host-key-check` (flag): Skip strict host key checking (adds `-o StrictHostKeyChecking=no`).
- `-s|--ssh-extra` (string): Extra arguments to append to `ssh` invocations.
- `--collect`, `--collect-files`, `--collect-method`, `--collect-dest` — same semantics as PowerShell script.

## Examples

PowerShell — dry-run (preview actions):

```powershell
.\run_remote_command.ps1 \
  -HostsFile .\hosts.txt \
  -Command "uptime" \
  -KeyFile C:\keys\id_rsa \
  -LocalFile C:\tmp\config.json \
  -RemotePath /tmp/config.json \
  -DryRun -Verbose -Retries 4 -BaseBackoff 1 -MaxBackoff 20
```

PowerShell — real run:

```powershell
.\run_remote_command.ps1 \
  -HostsFile .\hosts.txt \
  -Command "hostname" \
  -KeyFile C:\keys\id_rsa \
  -Parallel 8 -Retries 5 -BaseBackoff 1 -MaxBackoff 30
```

Bash — dry-run (example using WSL/Git-Bash paths):

```bash
cd "/c/Users/bustilm/Documents/Deployment Scripts"
./run_remote_command_enhanced.sh -h hosts.txt -c "uptime" \
  --key "/home/user/.ssh/id_rsa" --local-file "/home/user/config.json" \
  --remote-path "/tmp/config.json" --dry-run --verbose --retries 4 \
  --base-backoff 1 --max-backoff 20
```

Bash — real run (restart a service):

```bash
cd "/c/Users/bustilm/Documents/Deployment Scripts"
./run_remote_command_enhanced.sh -h hosts.txt -c "sudo systemctl restart myservice" \
  --key "/home/user/.ssh/id_rsa" --local-file "/home/user/config.json" \
  --remote-path "/etc/myapp/config.json" --parallel 10 --retries 5 \
  --base-backoff 1 --max-backoff 30
```

Tips for quoting:

- On PowerShell, wrap complex remote commands in single quotes if they contain double-quotes, or vice-versa. Example: `-Command 'bash -lc "echo \"hello\""'`.
- On Bash, prefer single quotes to avoid local shell interpolation: `-c 'echo "$HOSTNAME"'`.

## Logs and summary CSV

- Both scripts create a `logs/` folder in the working directory (or the configured output directory).
- Per-host logs: `<host>_YYYYMMDD_HHMMSS.out.log` and `<host>_YYYYMMDD_HHMMSS.err.log`.
- If an scp transfer occurs a `.scp` variant of the out/err logs is created for the transfer step (PowerShell: `.scp` appended to filenames).
- Summary CSV: `logs/summary_YYYYMMDD_HHMMSS.csv` with these columns:
  - Host — short host string (hostname or IP)
  - Target — user@host used for SSH
  - StartTime — ISO timestamp when the run began
  - DurationSeconds — total duration (seconds)
  - ExitCode — exit code of the ssh command
  - Success — `True`/`False`
  - OutFile — path to stdout log
  - ErrFile — path to stderr log

Example CSV row:

```
host1.example.com,admin@host1,2025-10-07T12:34:56+00:00,3,0,True,logs/host1_20251007_123456.out.log,logs/host1_20251007_123456.err.log
```

## Security

- Use SSH keys and protect your private key files (file system permissions, ssh-agent).
- Avoid `SkipHostKeyChecking`/`--skip-host-key-check` unless in throwaway labs — it disables host key verification and opens you to MITM attacks.
- Prefer running these scripts from a bastion/jump host or secure CI runner rather than a personal laptop when operating at scale.

## Troubleshooting

- "ssh/scp not found": ensure OpenSSH client is installed and on PATH. On Windows you can install the OpenSSH client optional feature or use WSL.
- Permission denied: check key file permissions, ensure the key matches what the remote `authorized_keys` expects, and confirm the remote username.
- If many failures occur, try `--dry-run`/`-DryRun` to validate the scp/ssh command lines before running.

Common edge-cases handled by the scripts

- Empty or commented hosts file lines are ignored.
- Per-host failures do not stop the whole run — a summary CSV and exit code indicate success/failure count.
- Retries use exponential backoff with jitter to reduce thundering herd retries.

## Contributing

Small fixes, README improvements, or test additions are welcome. Create a branch and open a PR with a clear description. Keep changes small and focused.

## License

This repository is provided under the MIT license. See LICENSE file if present.

---

