<#
.SYNOPSIS
Run a command via SSH on a list of hosts using key-based authentication, with logging and a summary CSV.

.DESCRIPTION
This script reads a hosts file (one host per line, supports user@host), runs a command via the system OpenSSH client (ssh.exe), captures stdout/stderr into per-host log files, and writes a summary CSV. It uses PowerShell runspaces to run multiple SSH sessions in parallel.

.PARAMETER HostsFile
Path to the hosts file (one host per line). Lines starting with # or blank are ignored.
.PARAMETER Command
The command to run remotely (required).
.PARAMETER KeyFile
Path to the private key to use for SSH (optional). If omitted, the default ssh agent or keys are used.
.PARAMETER User
Default SSH user to use if a host line doesn't include user@.
.PARAMETER Parallel
Max parallel connections (default 10).
.PARAMETER Timeout
SSH ConnectTimeout in seconds (default 10).
.PARAMETER OutputDir
Directory for logs (default: ./logs).
.PARAMETER SkipHostKeyChecking
If set, passes StrictHostKeyChecking=no to ssh (use carefully).
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)][string]$HostsFile,
	[Parameter(Mandatory=$true)][string]$Command,
	[string]$KeyFile = $null,
	[string]$User = $null,
	[int]$Parallel = 10,
	[int]$Timeout = 10,
	[string]$OutputDir = "$PSScriptRoot\logs",
	[int]$Retries = 3,
	[double]$BaseBackoff = 1.0,
	[double]$MaxBackoff = 30.0,
	[switch]$Collect,
	[string]$CollectFiles = $null,
	[ValidateSet('tar-scp','rsync','scp')][string]$CollectMethod = 'tar-scp',
	[string]$CollectDest = $null,
	[switch]$SkipHostKeyChecking,
	[switch]$DryRun,
	[string]$LocalFile = $null,
	[string]$RemotePath = "~",
	[switch]$Verbose
)

# Ensure OpenSSH ssh.exe is available
# Locate ssh and scp
$sshPath = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
$scpPath = Get-Command scp -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
if (-not $sshPath) {
	Write-Error "ssh.exe not found in PATH. Install OpenSSH client or add it to PATH."
	exit 1
}

# Validate hosts file
if (-not (Test-Path $HostsFile)) {
	Write-Error "Hosts file '$HostsFile' not found."
	exit 1
}

# Create output dir
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# Read hosts
$hosts = Get-Content $HostsFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not ($_ -match '^#') }
if ($hosts.Count -eq 0) {
	Write-Error "No hosts found in $HostsFile"
	exit 1
}

# Prepare runspace pool
$maxThreads = [int]$Parallel
$sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$pool = [runspacefactory]::CreateRunspacePool(1, $maxThreads, $sessionState, $host)
$pool.Open()

$jobs = @()
$summary = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()

foreach ($entry in $hosts) {
	$entryCopy = $entry
	$runspace = [powershell]::Create()
	$runspace.RunspacePool = $pool

	$scriptBlock = {
	param($entry, $Command, $KeyFile, $User, $Timeout, $OutputDir, $SkipHostKeyChecking, $sshPath, $scpPath, $DryRun, $LocalFile, $RemotePath, $DoVerbose, $Retries, $BaseBackoff, $MaxBackoff)

		# parse user@host
		$user = $null
		$host = $entry
		if ($entry -match '^(?<u>[^@]+)@(?<h>.+)$') {
			$user = $matches['u']
			$host = $matches['h']
		}
		if (-not $user) { $user = $User }
		$target = if ($user) { "$user@$host" } else { $host }

		$safeHost = $host -replace '[^a-zA-Z0-9_.-]', '_'
		$timeStamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
		$outFile = Join-Path $OutputDir "$safeHost`_$timeStamp.out.log"
		$errFile = Join-Path $OutputDir "$safeHost`_$timeStamp.err.log"

		$sshArgs = @('-o','ConnectTimeout=' + $Timeout, '-o','BatchMode=yes')
		if ($SkipHostKeyChecking) {
			$sshArgs += ('-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
		}
		if ($KeyFile) { $sshArgs += ('-i',$KeyFile) }
		$sshArgs += $target
		# remote command should be passed as a single argument
		$sshArgs += ($Command)

		$startInfo = New-Object System.Diagnostics.ProcessStartInfo
		$startInfo.FileName = $sshPath
		$startInfo.Arguments = $sshArgs -join ' '
		$startInfo.RedirectStandardOutput = $true
		$startInfo.RedirectStandardError = $true
		$startInfo.UseShellExecute = $false

		$proc = New-Object System.Diagnostics.Process
		$proc.StartInfo = $startInfo

		$result = [pscustomobject]@{
			Host = $host
			Target = $target
			StartTime = Get-Date
			ExitCode = $null
			Success = $false
			OutFile = $outFile
			ErrFile = $errFile
			DurationSeconds = $null
		}

		function Get-BackoffSeconds {
			param($attempt, $base, $max)
			# exponential backoff with full jitter
			$exp = [math]::Min($max, $base * [math]::Pow(2, $attempt - 1))
			$jitter = Get-Random -Minimum 0 -Maximum $exp
			return $jitter
		}

		try {
			# Optional: copy a local file to remote before executing
			if ($LocalFile) {
				if (-not $scpPath) {
					throw "scp not found in PATH but -LocalFile was provided. Install scp or omit -LocalFile."
				}
				$remoteDest = "$target:`$RemotePath".Replace('`$RemotePath',$RemotePath)
				$scpArgs = @()
				if ($KeyFile) { $scpArgs += ('-i',$KeyFile) }
				$scpArgs += ('-o','ConnectTimeout=' + $Timeout)
				if ($SkipHostKeyChecking) { $scpArgs += ('-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null') }
				$scpArgs += @($LocalFile, "$target:$RemotePath")

				if ($DoVerbose) { Write-Output "[scp] scp $($scpArgs -join ' ')" }
				if (-not $DryRun) {
					$attempt = 0
					$scpSuccess = $false
					while ($attempt -lt $Retries -and -not $scpSuccess) {
						$attempt++
						$scpStart = New-Object System.Diagnostics.ProcessStartInfo
						$scpStart.FileName = $scpPath
						$scpStart.Arguments = $scpArgs -join ' '
						$scpStart.RedirectStandardOutput = $true
						$scpStart.RedirectStandardError = $true
						$scpStart.UseShellExecute = $false

						$scpProc = New-Object System.Diagnostics.Process
						$scpProc.StartInfo = $scpStart
						$scpProc.Start() | Out-Null
						$scpOutTask = $scpProc.StandardOutput.ReadToEndAsync()
						$scpErrTask = $scpProc.StandardError.ReadToEndAsync()
						$scpProc.WaitForExit()
						$scpOut = $scpOutTask.Result
						$scpErr = $scpErrTask.Result
						$scpOut | Out-File -FilePath ($outFile + '.scp') -Encoding UTF8
						$scpErr | Out-File -FilePath ($errFile + '.scp') -Encoding UTF8
						if ($scpProc.ExitCode -eq 0) { $scpSuccess = $true }
						else {
							if ($attempt -lt $Retries) {
								$sleep = Get-BackoffSeconds -attempt $attempt -base $BaseBackoff -max $MaxBackoff
								if ($DoVerbose) { Write-Output "[scp] attempt $attempt failed, retrying after $sleep seconds" }
								Start-Sleep -Seconds $sleep
							} else {
								throw "scp failed after $attempt attempts. Last error: $scpErr"
							}
						}
					}
				} else {
					Write-Output "[DryRun] would scp: $LocalFile -> $target:$RemotePath"
				}
			}

			if ($DoVerbose) { Write-Output "[ssh] ssh $($sshArgs -join ' ')" }

			if (-not $DryRun) {
				$attempt = 0
				$sshSuccess = $false
				while ($attempt -lt $Retries -and -not $sshSuccess) {
					$attempt++
					$proc.Start() | Out-Null

					$stdOut = $proc.StandardOutput.ReadToEndAsync()
					$stdErr = $proc.StandardError.ReadToEndAsync()

					$proc.WaitForExit()
					$stdOut = $stdOut.Result
					$stdErr = $stdErr.Result

					$result.ExitCode = $proc.ExitCode
					$result.Success = ($proc.ExitCode -eq 0)
					$result.DurationSeconds = (Get-Date - $result.StartTime).TotalSeconds

					# write logs
					$stdOut | Out-File -FilePath $outFile -Encoding UTF8
					$stdErr | Out-File -FilePath $errFile -Encoding UTF8

					if ($proc.ExitCode -eq 0) { $sshSuccess = $true }
					else {
						if ($attempt -lt $Retries) {
							$sleep = Get-BackoffSeconds -attempt $attempt -base $BaseBackoff -max $MaxBackoff
							if ($DoVerbose) { Write-Output "[ssh] attempt $attempt failed(exit=$($proc.ExitCode)), retrying after $sleep seconds" }
							Start-Sleep -Seconds $sleep
						} else {
							if ($DoVerbose) { Write-Output "[ssh] failed after $attempt attempts" }
							break
						}
					}
				}
				Write-Output "--- [$target] exit=$($result.ExitCode) duration=$([math]::Round($result.DurationSeconds,2))s ---"
			}
			else {
				Write-Output "[DryRun] would run ssh: $($sshArgs -join ' ')"
				$result.ExitCode = 0
				$result.Success = $true
				$result.DurationSeconds = 0
				"[DryRun] logs would be: Out=$outFile Err=$errFile" | Out-File -FilePath $outFile -Encoding UTF8
			}
		}
		catch {
			$err = $_ | Out-String
			$result.ExitCode = -1
			$result.Success = $false
			$stdErr = $err
			$stdErr | Out-File -FilePath $errFile -Encoding UTF8
			Write-Output "--- [$target] exception: $err ---"
		}

		return $result
	}

		# After command (or dry-run), attempt to collect files if requested
		try {
			$collectDestActual = if ($CollectDest) { $CollectDest } else { Join-Path $OutputDir 'collected' }
			$collectedFiles = Invoke-Collect -target $target -host $host -CollectFiles $CollectFiles -CollectMethod $CollectMethod -CollectDest $collectDestActual -KeyFile $KeyFile -Timeout $Timeout -SkipHostKeyChecking $SkipHostKeyChecking -scpPath $scpPath -sshPath $sshPath -Retries $Retries -BaseBackoff $BaseBackoff -MaxBackoff $MaxBackoff -DoVerbose $DoVerbose -OutDir $OutputDir
			if ($collectedFiles.Count -gt 0) {
				$result | Add-Member -NotePropertyName CollectedFiles -NotePropertyValue ($collectedFiles -join ';') -Force
				if ($DoVerbose) { Write-Output "[collect] collected: $($collectedFiles -join ', ')" }
			}
		}
		catch {
			if ($DoVerbose) { Write-Output "[collect] collection failed: $_" }
		}

		# Collect phase: run after remote command completes (always try, even on failure)
		function Invoke-Collect {
			param($target, $host, $CollectFiles, $CollectMethod, $CollectDest, $KeyFile, $Timeout, $SkipHostKeyChecking, $scpPath, $sshPath, $Retries, $BaseBackoff, $MaxBackoff, $DoVerbose, $OutDir)

			if (-not $CollectFiles) { return @() }
			$destRoot = if ($CollectDest) { $CollectDest } else { Join-Path $OutDir "collected" }
			$hostDir = Join-Path $destRoot $host
			New-Item -ItemType Directory -Path $hostDir -Force | Out-Null
			$collected = @()

			switch ($CollectMethod) {
				'tar-scp' {
					# Create a tarball on remote containing the requested files, then scp it back
					$tarCmd = "tar -czf /tmp/collect_$($env:COMPUTERNAME)_$([guid]::NewGuid().ToString()).tar.gz $CollectFiles"
					if ($DoVerbose) { Write-Output "[collect] remote tar cmd: $tarCmd" }
					$sshArgs = @('-o','ConnectTimeout=' + $Timeout)
					if ($SkipHostKeyChecking) { $sshArgs += ('-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null') }
					if ($KeyFile) { $sshArgs += ('-i',$KeyFile) }
					$sshArgs += $target

					# run tar remotely
					$startInfo = New-Object System.Diagnostics.ProcessStartInfo
					$startInfo.FileName = $sshPath
					$startInfo.Arguments = ($sshArgs + $tarCmd) -join ' '
					$startInfo.RedirectStandardOutput = $true
					$startInfo.RedirectStandardError = $true
					$startInfo.UseShellExecute = $false

					$proc = New-Object System.Diagnostics.Process
					$proc.StartInfo = $startInfo
					$proc.Start() | Out-Null
					$proc.WaitForExit()

					if ($proc.ExitCode -ne 0) { Write-Output "[collect] remote tar failed" }
					# scp the resulting tarball back
					$remoteTar = "/tmp/collect_*.tar.gz"
					$scpArgs = @()
					if ($KeyFile) { $scpArgs += ('-i',$KeyFile) }
					$scpArgs += ('-o','ConnectTimeout=' + $Timeout)
					if ($SkipHostKeyChecking) { $scpArgs += ('-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null') }
					$scpArgs += @("$target:$remoteTar", $hostDir)

					# retry scp
					$attempt = 0
					$got= $false
					while ($attempt -lt $Retries -and -not $got) {
						$attempt++
						$scpStart = New-Object System.Diagnostics.ProcessStartInfo
						$scpStart.FileName = $scpPath
						$scpStart.Arguments = $scpArgs -join ' '
						$scpStart.RedirectStandardOutput = $true
						$scpStart.RedirectStandardError = $true
						$scpStart.UseShellExecute = $false
						$scpProc = New-Object System.Diagnostics.Process
						$scpProc.StartInfo = $scpStart
						$scpProc.Start() | Out-Null
						$scpProc.WaitForExit()
						if ($scpProc.ExitCode -eq 0) { $got = $true } else {
							if ($attempt -lt $Retries) { Start-Sleep -Seconds (Get-BackoffSeconds -attempt $attempt -base $BaseBackoff -max $MaxBackoff) }
							else { Write-Output "[collect] scp failed after $attempt attempts" }
						}
					}
					# add collected files
					Get-ChildItem -Path $hostDir -Filter "collect_*.tar.gz" -ErrorAction SilentlyContinue | ForEach-Object { $collected += $_.FullName }
				}
				'rsync' {
					# use rsync if available on controller
					$rsync = Get-Command rsync -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue
					if (-not $rsync) { Write-Output "[collect] rsync not available, skipping"; break }
					$remote = "$target:" + ($CollectFiles -split '\s+' | Select-Object -First 1)
					$cmd = "$rsync -e 'ssh' -avz --rsync-path='mkdir -p $hostDir && rsync' $remote $hostDir"
					if ($DoVerbose) { Write-Output "[collect] $cmd" }
					Invoke-Expression $cmd
					Get-ChildItem -Path $hostDir -Recurse | ForEach-Object { $collected += $_.FullName }
				}
				'scp' {
					# scp each file/pattern - may be slow
					$parts = $CollectFiles -split '\s+'
					foreach ($p in $parts) {
						$scpArgs = @()
						if ($KeyFile) { $scpArgs += ('-i',$KeyFile) }
						$scpArgs += ('-o','ConnectTimeout=' + $Timeout)
						if ($SkipHostKeyChecking) { $scpArgs += ('-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null') }
						$scpArgs += @("$target:$p", $hostDir)
						$attempt = 0; $got = $false
						while ($attempt -lt $Retries -and -not $got) {
							$attempt++
							$scpStart = New-Object System.Diagnostics.ProcessStartInfo
							$scpStart.FileName = $scpPath
							$scpStart.Arguments = $scpArgs -join ' '
							$scpStart.RedirectStandardOutput = $true
							$scpStart.RedirectStandardError = $true
							$scpStart.UseShellExecute = $false
							$scpProc = New-Object System.Diagnostics.Process
							$scpProc.StartInfo = $scpStart
							$scpProc.Start() | Out-Null
							$scpProc.WaitForExit()
							if ($scpProc.ExitCode -eq 0) { $got = $true } else {
								if ($attempt -lt $Retries) { Start-Sleep -Seconds (Get-BackoffSeconds -attempt $attempt -base $BaseBackoff -max $MaxBackoff) }
								else { Write-Output "[collect] scp $p failed after $attempt attempts" }
							}
						}
					}
					Get-ChildItem -Path $hostDir -Recurse | ForEach-Object { $collected += $_.FullName }
				}
			}

			return $collected
		}


	$runspace.AddScript($scriptBlock).AddArgument($entryCopy).AddArgument($Command).AddArgument($KeyFile).AddArgument($User).AddArgument($Timeout).AddArgument($OutputDir).AddArgument($SkipHostKeyChecking.IsPresent).AddArgument($sshPath).AddArgument($scpPath).AddArgument($DryRun).AddArgument($LocalFile).AddArgument($RemotePath).AddArgument($Verbose.IsPresent).AddArgument($Retries).AddArgument($BaseBackoff).AddArgument($MaxBackoff).AddArgument($Collect.IsPresent).AddArgument($CollectFiles).AddArgument($CollectMethod).AddArgument($CollectDest) | Out-Null
	$job = @{ PowerShell = $runspace; AsyncResult = $runspace.BeginInvoke() }
	$jobs += $job
}

# Wait for jobs to complete and collect results
foreach ($job in $jobs) {
	$ps = $job.PowerShell
	$async = $job.AsyncResult
	$results = $ps.EndInvoke($async)
	foreach ($r in $results) { $summary.Add($r) }
	$ps.Dispose()
}

# Close pool
$pool.Close()
$pool.Dispose()

# Write summary CSV
$summaryFile = Join-Path $OutputDir "summary_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$summary | Select-Object Host,Target,StartTime,DurationSeconds,ExitCode,Success,OutFile,ErrFile | Export-Csv -Path $summaryFile -NoTypeInformation -Encoding UTF8

Write-Host "Summary written to $summaryFile"
$failCount = ($summary | Where-Object { -not $_.Success }).Count
if ($failCount -gt 0) {
	Write-Host "Completed with $failCount failures. See per-host logs in $OutputDir" -ForegroundColor Yellow
	exit 2
} else {
	Write-Host "All hosts completed successfully." -ForegroundColor Green
	exit 0
}
