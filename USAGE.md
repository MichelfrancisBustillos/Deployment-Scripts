Deployment Scripts - Unified Usage

This folder contains two scripts to run commands on multiple remote hosts via SSH:

- run_remote_command.ps1 — PowerShell implementation (Windows native). Requires `ssh`/`scp` in PATH.
- run_remote_command_enhanced.sh — Bash implementation (WSL, Git Bash or POSIX shell). Requires `ssh`/`scp`.

Common features (both scripts):
- Key-based authentication via `-KeyFile` (PowerShell) or `--key` (bash).
- Per-host stdout/stderr logs in `logs/`.
- Summary CSV with Host, Target, StartTime, DurationSeconds, ExitCode, Success, OutFile, ErrFile.
- Dry-run mode to preview actions without executing.
- Verbose mode to display full scp/ssh command lines.
- File transfer: copy a local file to each host before running the command.
- Retries with exponential backoff and full jitter.

PowerShell usage (example):

```powershell
# Dry-run showing scp and ssh commands (no network actions)
C:\Users\bustilm\Documents\Deployment Scripts\run_remote_command.ps1 -HostsFile C:\Users\bustilm\Documents\Deployment Scripts\hosts.txt -Command "uptime" -KeyFile C:\keys\id_rsa -LocalFile C:\tmp\config.json -RemotePath /tmp/config.json -DryRun -Verbose -Retries 4 -BaseBackoff 1 -MaxBackoff 20

# Real run with retries
C:\Users\bustilm\Documents\Deployment Scripts\run_remote_command.ps1 -HostsFile C:\Users\bustilm\Documents\Deployment Scripts\hosts.txt -Command "hostname" -KeyFile C:\keys\id_rsa -Parallel 8 -Retries 5 -BaseBackoff 1 -MaxBackoff 30
```

Bash usage (example):

```bash
cd "/c/Users/bustilm/Documents/Deployment Scripts"
# Dry-run
./run_remote_command_enhanced.sh -h hosts.txt -c "uptime" --key "/home/user/.ssh/id_rsa" --local-file "/home/user/config.json" --remote-path "/tmp/config.json" --dry-run --verbose --retries 4 --base-backoff 1 --max-backoff 20

# Real run
./run_remote_command_enhanced.sh -h hosts.txt -c "sudo systemctl restart myservice" --key "/home/user/.ssh/id_rsa" --local-file "/home/user/config.json" --remote-path "/etc/myapp/config.json" --parallel 10 --retries 5 --base-backoff 1 --max-backoff 30
```

Parameters (PowerShell)
- -HostsFile (required)
- -Command (required)
- -KeyFile (optional)
- -LocalFile (optional)
- -RemotePath (default `~`)
- -DryRun (switch)
- -Verbose (switch)
- -Parallel (default 10)
- -Timeout (default 10)
- -Retries (default 3)
- -BaseBackoff (default 1.0)
- -MaxBackoff (default 30.0)
- -SkipHostKeyChecking (switch)

Parameters (Bash)
- -h|--hosts (required)
- -c|--command (required)
- --key (optional)
- --local-file (optional)
- --remote-path (default `~`)
- --dry-run (flag)
- --verbose (flag)
- --parallel (default 10)
- --timeout (default 5)
- --retries (default 3)
- --base-backoff (default 1.0)
- --max-backoff (default 30.0)
- -k|--skip-host-key-check (flag)

Security notes
- Use key-based auth and protect private keys.
- Avoid `SkipHostKeyChecking` unless you understand the trade-offs.

Next steps (optional enhancements)
- Add per-host retry limits and backoff tuning per command.
- Collect results back to the controller and produce JSON reports.
- Integrate with orchestration tooling (Ansible, Salt, etc.) for larger fleets.

