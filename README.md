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

PowerShell (`run_remote_command.ps1`)

- `-HostsFile` (string, required): Path to the hosts file.
- `-Command` (string, required): Command to run on each host. Quote complex commands.
- `-KeyFile` (string): Path to private key for ssh/scp (`-i`). If omitted, ssh agent or default keys are used.
- `-LocalFile` (string): Local file path to copy to each host before execution.
- `-RemotePath` (string, default `~`): Destination path on the remote host where `LocalFile` will be placed.
- `-DryRun` (switch): If set, shows the scp/ssh commands that would run but does not execute them.
- `-Verbose` (switch): Print verbose information (shows scp/ssh command lines, retry messages).
- `-Parallel` (int, default 10): Max concurrent sessions.
- `-Timeout` (int, default 10): SSH `ConnectTimeout` seconds.
- `-Retries` (int, default 3): Number of attempts for scp/ssh (1 = no retry).
- `-BaseBackoff` (float, default 1.0): Base backoff seconds for exponential growth.
- `-MaxBackoff` (float, default 30.0): Maximum backoff seconds cap.
- `-SkipHostKeyChecking` (switch): Adds `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` to ssh/scp.

Bash (`run_remote_command_enhanced.sh`)

- `-h|--hosts` (string, required): Hosts file path.
- `-c|--command` (string, required): Command to run remotely.
- `--key` (string): SSH private key (used with `-i`).
- `--local-file` (string): Local file to copy to hosts.
- `--remote-path` (string, default `~`): Destination path on the remote host.
- `--dry-run` (flag): Show actions; do not execute network calls.
- `--verbose` (flag): Print scp/ssh commands and retry messages.
- `--parallel` (int, default 10): Parallel sessions.
- `--timeout` (int, default 5): SSH connect timeout.
- `--retries` (int, default 3): Number of attempts for scp/ssh.
- `--base-backoff` (float, default 1.0): Base backoff seconds.
- `--max-backoff` (float, default 30.0): Max backoff seconds.
- `-k|--skip-host-key-check` (flag): Skip strict host key checking.

---

## 2) Examples

PowerShell dry-run (preview actions):

```powershell
C:\Users\bustilm\Documents\Deployment Scripts\run_remote_command.ps1 \
  -HostsFile C:\Users\bustilm\Documents\Deployment Scripts\hosts.txt \
  -Command "uptime" \
  -KeyFile C:\keys\id_rsa \
  -LocalFile C:\tmp\config.json \
  -RemotePath /tmp/config.json \
  -DryRun -Verbose -Retries 4 -BaseBackoff 1 -MaxBackoff 20
```

PowerShell real run:

```powershell
C:\Users\bustilm\Documents\Deployment Scripts\run_remote_command.ps1 \
  -HostsFile C:\Users\bustilm\Documents\Deployment Scripts\hosts.txt \
  -Command "hostname" \
  -KeyFile C:\keys\id_rsa \
  -Parallel 8 -Retries 5 -BaseBackoff 1 -MaxBackoff 30
```

Bash dry-run:

```bash
cd "/c/Users/bustilm/Documents/Deployment Scripts"
./run_remote_command_enhanced.sh -h hosts.txt -c "uptime" \
  --key "/home/user/.ssh/id_rsa" --local-file "/home/user/config.json" \
  --remote-path "/tmp/config.json" --dry-run --verbose --retries 4 \
  --base-backoff 1 --max-backoff 20
```

Bash real run:

```bash
cd "/c/Users/bustilm/Documents/Deployment Scripts"
./run_remote_command_enhanced.sh -h hosts.txt -c "sudo systemctl restart myservice" \
  --key "/home/user/.ssh/id_rsa" --local-file "/home/user/config.json" \
  --remote-path "/etc/myapp/config.json" --parallel 10 --retries 5 \
  --base-backoff 1 --max-backoff 30
```

---

## 3) Expected log output and summary CSV

Logs:

- Per-host logs are written to the `logs/` directory created in whatever working directory you run the script from.
- For each host, two files are created:
  - `<host>_YYYYMMDD_HHMMSS.out.log` — stdout from scp/ssh (scp writes to `.scp` variants when used)
  - `<host>_YYYYMMDD_HHMMSS.err.log` — stderr from scp/ssh (scp writes to `.scp` variants when used)

When `--local-file`/`-LocalFile` is used, the script also writes scp-specific logs with `.scp` appended to the out/err filenames (PowerShell uses the same pattern).

Summary CSV:

- A summary CSV is written into the same `logs/` folder with filename `summary_YYYYMMDD_HHMMSS.csv`.
- CSV columns: Host,Target,StartTime,DurationSeconds,ExitCode,Success,OutFile,ErrFile

Example CSV row:

```
host1.example.com,admin@host1,2025-10-07T12:34:56+00:00,3,0,True,logs/host1_20251007_123456.out.log,logs/host1_20251007_123456.err.log
```

---

## 4) Security notes and tips

- Use SSH key-based authentication and secure your private keys (file permissions, SSH agent).
- Avoid `SkipHostKeyChecking` unless you control the environment and understand the risks; it disables host key verification and can expose you to man-in-the-middle attacks.
- `DryRun` is helpful for validating commands and transfer paths before executing.

---

## 5) Next steps / optional enhancements

- Add JSON output for programmatic consumption.
- Add collect/pull step to retrieve artifacts or logs after execution.
- Integrate with an orchestration tool for large fleets (Ansible, Salt, etc.).

---

Disclaimer

This software was "vibe-coded" with the help of Copilot AI.
