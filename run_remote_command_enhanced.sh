#!/usr/bin/env bash
# run_remote_command_enhanced.sh
# Enhanced version: supports key-based auth, dry-run, verbose, file transfer (scp), per-host logs, and summary CSV.
# Usage: ./run_remote_command_enhanced.sh -h hosts.txt -c "uptime" [--local-file /path/to/file --remote-path /tmp] [-u user] [--key /path/to/key] [--parallel 10] [--timeout 5] [--dry-run] [--verbose]

set -euo pipefail
IFS=$'\n\t'

print_usage() {
  cat <<EOF
Usage: $0 -h hosts.txt -c "command" [options]

Required:
  -h|--hosts FILE         Hosts file (one host per line). Use user@host per-line to override default user.
  -c|--command CMD        Command to run on each host.

Options:
  -u|--user USER          Default SSH user (optional)
  --key KEYFILE           Path to SSH private key (for scp/ssh -i)
  --parallel N            Parallelism (default: 10)
  --timeout S             SSH connect timeout seconds (default: 5)
  --local-file PATH       Local file to copy to each host before running the command (requires scp)
  --remote-path PATH      Remote destination path for copied file (default: ~)
  --dry-run               Show actions without executing
  --verbose               Verbose output (shows scp/ssh commands)
  --retries N             Number of retries for scp/ssh (default: 3)
  --base-backoff S        Base backoff seconds (default: 1.0)
  --max-backoff S         Max backoff seconds (default: 30.0)
  --collect               Enable collect/pull phase after command completes
  --collect-files STR     Files or patterns to collect (quoted, space-separated)
  --collect-method ARG    Collection method: tar-scp|rsync|scp (default: tar-scp)
  --collect-dest PATH     Local destination base for collected files (default: logs/collected)
  -k|--skip-host-key-check  Skip strict host key checking
  -s|--ssh-extra OPTS     Extra ssh options (quoted)
  --help                  Show this message
EOF
}

HOSTS_FILE=""
COMMAND=""
DEFAULT_USER=""
KEYFILE=""
PARALLEL=10
TIMEOUT=5
RETRIES=3
BASE_BACKOFF=1.0
MAX_BACKOFF=30.0
LOCAL_FILE=""
REMOTE_PATH="~"
DRY_RUN=0
VERBOSE=0
SKIP_KEYS=0
SSH_EXTRA=""
COLLECT=0
COLLECT_FILES=""
COLLECT_METHOD="tar-scp"
COLLECT_DEST=""

# Simple arg parser
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--hosts) HOSTS_FILE="$2"; shift 2;;
    -c|--command) COMMAND="$2"; shift 2;;
    -u|--user) DEFAULT_USER="$2"; shift 2;;
    --key) KEYFILE="$2"; shift 2;;
    --parallel) PARALLEL="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
  --local-file) LOCAL_FILE="$2"; shift 2;;
  --remote-path) REMOTE_PATH="$2"; shift 2;;
  --retries) RETRIES="$2"; shift 2;;
  --base-backoff) BASE_BACKOFF="$2"; shift 2;;
  --max-backoff) MAX_BACKOFF="$2"; shift 2;;
  --collect) COLLECT=1; shift 1;;
  --collect-files) COLLECT_FILES="$2"; shift 2;;
  --collect-method) COLLECT_METHOD="$2"; shift 2;;
  --collect-dest) COLLECT_DEST="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift 1;;
    --verbose) VERBOSE=1; shift 1;;
    -k|--skip-host-key-check) SKIP_KEYS=1; shift 1;;
    -s|--ssh-extra) SSH_EXTRA="$2"; shift 2;;
    --help) print_usage; exit 0;;
    *) echo "Unknown argument: $1"; print_usage; exit 1;;
  esac
done

if [[ -z "$HOSTS_FILE" || -z "$COMMAND" ]]; then
  echo "hosts file and command are required" >&2
  print_usage
  exit 1
fi

if [[ ! -f "$HOSTS_FILE" ]]; then
  echo "Hosts file '$HOSTS_FILE' not found" >&2
  exit 1
fi

# Read hosts
mapfile -t HOSTS < <(grep -Ev '^\s*(#|$)' "$HOSTS_FILE")
if [[ ${#HOSTS[@]} -eq 0 ]]; then
  echo "No hosts found in $HOSTS_FILE" >&2
  exit 1
fi

# Find ssh and scp
SSH_BIN=$(command -v ssh || true)
SCP_BIN=$(command -v scp || true)
if [[ -z "$SSH_BIN" ]]; then
  echo "ssh not found in PATH" >&2
  exit 1
fi
if [[ -n "$LOCAL_FILE" && -z "$SCP_BIN" ]]; then
  echo "scp not found in PATH but --local-file was specified" >&2
  exit 1
fi

OUTDIR="$(pwd)/logs"
mkdir -p "$OUTDIR"
SUMMARY_CSV="$OUTDIR/summary_$(date +%Y%m%d_%H%M%S).csv"
echo "Host,Target,StartTime,DurationSeconds,ExitCode,Success,OutFile,ErrFile" > "$SUMMARY_CSV"

run_on_host() {
  local hostspec="$1"
  local user=""
  local host=""
  if [[ "$hostspec" == *"@"* ]]; then
    user="${hostspec%%@*}"
    host="${hostspec#*@}"
  else
    host="$hostspec"
    user="$DEFAULT_USER"
  fi
  local target
  if [[ -n "$user" ]]; then target="$user@$host"; else target="$host"; fi

  local safeHost
  safeHost=$(echo "$host" | sed 's/[^A-Za-z0-9_.-]/_/g')
  local ts
  ts=$(date +%Y%m%d_%H%M%S)
  local outFile="$OUTDIR/${safeHost}_${ts}.out.log"
  local errFile="$OUTDIR/${safeHost}_${ts}.err.log"
  local startTime
  startTime=$(date +%s)

  # Build scp and ssh options
  local sshOpts=("-o" "ConnectTimeout=${TIMEOUT}" "-o" "BatchMode=yes")
  if [[ $SKIP_KEYS -eq 1 ]]; then
    sshOpts+=("-o" "StrictHostKeyChecking=no" "-o" "UserKnownHostsFile=/dev/null")
  fi
  if [[ -n "$KEYFILE" ]]; then
    sshOpts+=("-i" "$KEYFILE")
  fi
  if [[ -n "$SSH_EXTRA" ]]; then
    sshOpts+=("$SSH_EXTRA")
  fi

  # Transfer file if requested
  if [[ -n "$LOCAL_FILE" ]]; then
    local scpCmd=("$SCP_BIN")
    if [[ -n "$KEYFILE" ]]; then scpCmd+=("-i" "$KEYFILE"); fi
    scpCmd+=("-o" "ConnectTimeout=${TIMEOUT}")
    if [[ $SKIP_KEYS -eq 1 ]]; then scpCmd+=("-o" "StrictHostKeyChecking=no" "-o" "UserKnownHostsFile=/dev/null"); fi
    scpCmd+=("$LOCAL_FILE" "${target}:$REMOTE_PATH")
    if [[ $VERBOSE -eq 1 ]]; then echo "[scp] ${scpCmd[*]}"; fi
    if [[ $DRY_RUN -eq 0 ]]; then
      attempt=0
      scp_success=0
      while [[ $attempt -lt $RETRIES && $scp_success -eq 0 ]]; do
        attempt=$((attempt+1))
        if "${scpCmd[@]}" > "$outFile" 2> "$errFile"; then
          scp_success=1
          break
        else
          if [[ $attempt -lt $RETRIES ]]; then
            # exponential backoff with full jitter
            exp=$(awk -v base="$BASE_BACKOFF" -v a="$attempt" 'BEGIN{print base * (2^(a-1))}')
            if (( $(echo "$exp > $MAX_BACKOFF" | bc -l) )); then exp=$MAX_BACKOFF; fi
            sleep_sec=$(awk -v e="$exp" 'BEGIN{srand(); print rand()*e}')
            if [[ $VERBOSE -eq 1 ]]; then echo "[scp] attempt $attempt failed, retrying after $sleep_sec seconds"; fi
            sleep $sleep_sec
          else
            echo "scp failed for $target after $attempt attempts" >> "$errFile"
            echo "$host,$target,$(date -Iseconds),0,1,false,$outFile,$errFile" >> "$SUMMARY_CSV"
            return 1
          fi
        fi
      done
    else
      echo "[DryRun] would scp: ${scpCmd[*]}"
      echo "[DryRun] scp logs: out=$outFile err=$errFile" > "$outFile"
    fi
  fi

  # Run ssh command
  local sshCmd=("$SSH_BIN")
  sshCmd+=("${sshOpts[@]}")
  sshCmd+=("$target")
  sshCmd+=("$COMMAND")
  if [[ $VERBOSE -eq 1 ]]; then echo "[ssh] ${sshCmd[*]}"; fi
  if [[ $DRY_RUN -eq 0 ]]; then
    attempt=0
    ssh_success=0
    exitCode=0
    while [[ $attempt -lt $RETRIES && $ssh_success -eq 0 ]]; do
      attempt=$((attempt+1))
      if "${sshCmd[@]}" > "$outFile" 2> "$errFile"; then
        ssh_success=1
        exitCode=0
        success=true
        break
      else
        exitCode=$?
        success=false
        if [[ $attempt -lt $RETRIES ]]; then
          exp=$(awk -v base="$BASE_BACKOFF" -v a="$attempt" 'BEGIN{print base * (2^(a-1))}')
          if (( $(echo "$exp > $MAX_BACKOFF" | bc -l) )); then exp=$MAX_BACKOFF; fi
          sleep_sec=$(awk -v e="$exp" 'BEGIN{srand(); print rand()*e}')
          if [[ $VERBOSE -eq 1 ]]; then echo "[ssh] attempt $attempt failed (exit=$exitCode), retrying after $sleep_sec seconds"; fi
          sleep $sleep_sec
        else
          if [[ $VERBOSE -eq 1 ]]; then echo "[ssh] failed after $attempt attempts"; fi
          break
        fi
      fi
    done
  else
    echo "[DryRun] would run: ${sshCmd[*]}" > "$outFile"
    exitCode=0
    success=true
  fi

  # Collect phase: attempt to pull artifacts from host
  if [[ $COLLECT -eq 1 && -n "$COLLECT_FILES" ]]; then
    local collectDestRoot
    if [[ -n "$COLLECT_DEST" ]]; then collectDestRoot="$COLLECT_DEST"; else collectDestRoot="$OUTDIR/collected"; fi
    local hostDir="$collectDestRoot/$host"
    mkdir -p "$hostDir"

    case "$COLLECT_METHOD" in
      tar-scp)
        # remote tar to /tmp then scp back
        remote_tar="/tmp/collect_${host}_$(date +%s).tar.gz"
        tar_cmd="tar -czf $remote_tar $COLLECT_FILES"
        if [[ $VERBOSE -eq 1 ]]; then echo "[collect] ssh ${sshOpts[*]} $target $tar_cmd"; fi
        if [[ $DRY_RUN -eq 0 ]]; then
          "${SSH_BIN}" "${sshOpts[@]}" "$target" "$tar_cmd"
          scpCmd=("$SCP_BIN")
          if [[ -n "$KEYFILE" ]]; then scpCmd+=("-i" "$KEYFILE"); fi
          scpCmd+=("-o" "ConnectTimeout=${TIMEOUT}")
          if [[ $SKIP_KEYS -eq 1 ]]; then scpCmd+=("-o" "StrictHostKeyChecking=no" "-o" "UserKnownHostsFile=/dev/null"); fi
          scpCmd+=("$target:$remote_tar" "$hostDir/")
          attempt=0; got=0
          while [[ $attempt -lt $RETRIES && $got -eq 0 ]]; do
            attempt=$((attempt+1))
            if "${scpCmd[@]}"; then got=1; break; else
              if [[ $attempt -lt $RETRIES ]]; then
                exp=$(awk -v base="$BASE_BACKOFF" -v a="$attempt" 'BEGIN{print base * (2^(a-1))}')
                if (( $(echo "$exp > $MAX_BACKOFF" | bc -l) )); then exp=$MAX_BACKOFF; fi
                sleep_sec=$(awk -v e="$exp" 'BEGIN{srand(); print rand()*e}')
                sleep $sleep_sec
              else
                echo "collect scp failed for $target" >&2
              fi
            fi
          done
        else
          echo "[DryRun] would tar on remote: $tar_cmd and scp $target:$remote_tar -> $hostDir"
        fi
        ;;
      rsync)
        if ! command -v rsync >/dev/null 2>&1; then echo "rsync not available on controller"; else
          if [[ $DRY_RUN -eq 0 ]]; then
            mkdir -p "$hostDir"
            rsync -e "ssh" -avz --rsync-path="mkdir -p $hostDir && rsync" "$target:$COLLECT_FILES" "$hostDir/"
          else
            echo "[DryRun] would rsync $target:$COLLECT_FILES -> $hostDir"
          fi
        fi
        ;;
      scp)
        IFS=' ' read -r -a parts <<< "$COLLECT_FILES"
        for p in "${parts[@]}"; do
          scpCmd=("$SCP_BIN")
          if [[ -n "$KEYFILE" ]]; then scpCmd+=("-i" "$KEYFILE"); fi
          scpCmd+=("-o" "ConnectTimeout=${TIMEOUT}")
          if [[ $SKIP_KEYS -eq 1 ]]; then scpCmd+=("-o" "StrictHostKeyChecking=no" "-o" "UserKnownHostsFile=/dev/null"); fi
          scpCmd+=("$target:$p" "$hostDir/")
          if [[ $DRY_RUN -eq 0 ]]; then
            attempt=0; got=0
            while [[ $attempt -lt $RETRIES && $got -eq 0 ]]; do
              attempt=$((attempt+1))
              if "${scpCmd[@]}"; then got=1; break; else
                if [[ $attempt -lt $RETRIES ]]; then
                  exp=$(awk -v base="$BASE_BACKOFF" -v a="$attempt" 'BEGIN{print base * (2^(a-1))}')
                  if (( $(echo "$exp > $MAX_BACKOFF" | bc -l) )); then exp=$MAX_BACKOFF; fi
                  sleep_sec=$(awk -v e="$exp" 'BEGIN{srand(); print rand()*e}')
                  sleep $sleep_sec
                else
                  echo "collect scp $p failed for $target" >&2
                fi
              fi
            done
          else
            echo "[DryRun] would scp $target:$p -> $hostDir"
          fi
        done
        ;;
    esac
  fi

  local endTime
  endTime=$(date +%s)
  local duration
  duration=$((endTime - startTime))

  echo "$host,$target,$(date -Iseconds),$duration,$exitCode,$success,$outFile,$errFile" >> "$SUMMARY_CSV"

  if [[ "$success" == "true" ]]; then
    echo "--- [$target] success ---"
    return 0
  else
    echo "--- [$target] FAILED (exit=$exitCode) ---" >&2
    return 1
  fi
}

# Parallel runner
pids=()
for h in "${HOSTS[@]}"; do
  run_on_host "$h" &
  pids+=("$!")
  while [[ $(jobs -r | wc -l) -ge $PARALLEL ]]; do sleep 0.2; done
done

failures=0
for pid in "${pids[@]}"; do
  if wait "$pid"; then :; else ((failures++)); fi
done

if [[ $failures -gt 0 ]]; then
  echo "Completed with $failures failures. See $OUTDIR for logs and $SUMMARY_CSV for summary." >&2
  exit 2
else
  echo "All hosts completed successfully. Summary: $SUMMARY_CSV"
  exit 0
fi
