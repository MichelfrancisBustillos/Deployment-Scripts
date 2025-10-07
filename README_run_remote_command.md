run_remote_command.sh (original)

This folder contains both a simple bash script and an enhanced version. The original `run_remote_command.sh` is a lightweight script that runs a command on multiple hosts in parallel. It's preserved here for reference.

See `run_remote_command_enhanced.sh` for the full-featured implementation (dry-run, scp support, per-host logs, summary CSV, verbose).

Quick start for the enhanced script:

```bash
chmod +x "Deployment Scripts/run_remote_command_enhanced.sh"
"Deployment Scripts/run_remote_command_enhanced.sh" -h "Deployment Scripts/hosts.txt" -c "uptime" --key "/path/to/id_rsa" --local-file "/path/to/file" --remote-path "/tmp" --parallel 10
```

Notes:
- Run from Git Bash, WSL, or another POSIX-compatible shell on Windows.
- The enhanced script writes logs to `logs/` in the current working directory; change to a folder where you want logs to be created before running.
