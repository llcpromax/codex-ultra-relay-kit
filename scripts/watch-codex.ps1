$ErrorActionPreference = 'SilentlyContinue'
$dir = $PSScriptRoot
$log = Join-Path $dir 'watcher.log'
$lock = Join-Path $dir 'launch.lock'
$launcher = Join-Path $dir 'start-codex-ultra.ps1'
$repair = Join-Path $dir 'repair-config.ps1'
$configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
$port = 9333

function Log([string]$m) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [watcher] $m" | Out-File -FilePath $log -Append -Encoding utf8
}

# single instance
$mutex = New-Object System.Threading.Mutex($false, 'Local\CodexUltraWatcher')
if (-not $mutex.WaitOne(0)) { exit }

Log "watcher started"
Start-Sleep -Seconds 8
$lastAttempt = (Get-Date).AddMinutes(-5)
$configStamp = $null
$lastRepair = (Get-Date).AddMinutes(-5)

while ($true) {
    try {
        $cfg = Get-Item $configPath -ErrorAction Stop
        $stamp = "$($cfg.LastWriteTimeUtc.Ticks)-$($cfg.Length)"
        if ($null -eq $configStamp) {
            $configStamp = $stamp
        }
        elseif ($stamp -ne $configStamp -and ((Get-Date) - $lastRepair).TotalSeconds -ge 10) {
            Log "config change detected; repairing"
            $lastRepair = Get-Date
            Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $repair, '-Restart' -WindowStyle Hidden
            Start-Sleep -Milliseconds 1500
            try {
                $cfg2 = Get-Item $configPath
                $configStamp = "$($cfg2.LastWriteTimeUtc.Ticks)-$($cfg2.Length)"
            }
            catch { $configStamp = $stamp }
        }
    }
    catch {
        Log "config check error: $($_.Exception.Message)"
    }

    try {
        $app = Get-Process ChatGPT -ErrorAction SilentlyContinue
        if ($null -ne $app) {
            $listening = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
            $lockExists = Test-Path $lock
            if ($lockExists) {
                $age = (Get-Date) - (Get-Item $lock).LastWriteTime
                if ($age.TotalMinutes -gt 3) {
                    Remove-Item $lock -Force -ErrorAction SilentlyContinue
                    $lockExists = $false
                    Log "removed stale lock"
                }
            }
            $launcherRunning = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
                Where-Object { $_.CommandLine -like '*start-codex-ultra.ps1*' }
            if (-not $listening -and -not $lockExists -and -not $launcherRunning -and ((Get-Date) - $lastAttempt).TotalSeconds -ge 30) {
                Log "app without CDP detected; starting ultra launcher"
                $lastAttempt = Get-Date
                Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $launcher -WindowStyle Hidden
                Start-Sleep -Seconds 20
            }
        }
    }
    catch {
        Log "error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 2
}
