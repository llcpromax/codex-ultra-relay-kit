param(
    [switch]$KeepConfig,
    [switch]$RemoveFiles
)

$ErrorActionPreference = 'Continue'

$InstallDir = Join-Path $env:USERPROFILE '.codex\relay-proxy'
$ConfigPath = Join-Path $env:USERPROFILE '.codex\config.toml'
$UpstreamPath = Join-Path $InstallDir 'upstream.txt'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Write-Step([string]$m) {
    Write-Host "[*] $m" -ForegroundColor Cyan
}

function Write-Ok([string]$m) {
    Write-Host "[+] $m" -ForegroundColor Green
}

Write-Host '=== Codex Ultra Relay Kit 卸载 ===' -ForegroundColor White

# --- 1. 删除自启项 ---
Write-Step '删除开机自启项'
foreach ($name in @('CodexRelayProxy', 'CodexUltraLauncher', 'CodexUltraWatcher')) {
    $existing = Get-ItemProperty -Path $RunKey -Name $name -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-ItemProperty -Path $RunKey -Name $name -Force -ErrorAction SilentlyContinue
        Write-Ok "已删除 $name"
    }
}

# --- 2. 停止代理与守护进程 ---
Write-Step '停止本地代理与守护进程'
$killed = 0
$procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CommandLine -and
        ($_.CommandLine -like "*$InstallDir*") -and
        (($_.Name -like 'python*' -and $_.CommandLine -like '*proxy.py*') -or
         ($_.Name -like 'powershell*' -and $_.CommandLine -like '*watch-codex.ps1*'))
    }
foreach ($p in $procs) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    $killed++
}
if ($killed -gt 0) { Write-Ok "已停止 $killed 个进程" } else { Write-Ok '没有运行中的代理/守护进程' }

# --- 3. 还原 config.toml ---
if ($KeepConfig) {
    Write-Host '[!] 已指定 -KeepConfig，config.toml 保持不变（仍指向 127.0.0.1:8787，需要手动修改）' -ForegroundColor Yellow
}
elseif (-not (Test-Path $ConfigPath)) {
    Write-Host "[!] 未找到 $ConfigPath，跳过配置还原" -ForegroundColor Yellow
}
else {
    Write-Step '还原 config.toml'
    try {
        $upstream = $null
        if (Test-Path $UpstreamPath) {
            $first = Get-Content -Path $UpstreamPath -TotalCount 1
            if ($first -and $first.Trim().Length -gt 0) { $upstream = $first.Trim() }
        }

        $text = [System.IO.File]::ReadAllText($ConfigPath)
        $original = $text

        if ($upstream) {
            $provider = $null
            $pm = [regex]::Match($text, '(?m)^\s*model_provider\s*=\s*"([^"]+)"')
            if ($pm.Success) { $provider = $pm.Groups[1].Value }

            if ($provider) {
                $pattern = '(?ms)^\[model_providers\.' + [regex]::Escape($provider) + '\]\s*\r?\n(.*?)(?=^\[|\z)'
                $sm = [regex]::Match($text, $pattern)
                if ($sm.Success) {
                    $body = $sm.Groups[1].Value
                    $bm = [regex]::Match($body, 'base_url\s*=\s*"([^"]+)"')
                    if ($bm.Success -and $bm.Groups[1].Value -match '^https?://(127\.0\.0\.1|localhost)(:\d+)?') {
                        $newBody = [regex]::Replace($body, 'base_url\s*=\s*"[^"]+"', 'base_url = "' + $upstream + '"')
                        $text = $text.Substring(0, $sm.Groups[1].Index) + $newBody + $text.Substring($sm.Groups[1].Index + $sm.Groups[1].Length)
                        Write-Ok "base_url 已还原为 $upstream"
                    }
                    else {
                        Write-Ok 'base_url 不是本地代理地址，保持不变'
                    }
                }
            }
        }
        else {
            Write-Host '[!] 未找到 upstream.txt，无法还原上游地址，base_url 保持不变' -ForegroundColor Yellow
        }

        $text = [regex]::Replace($text, '(?m)^\s*show-ultra-in-model-picker-slider\s*=.*\r?\n?', '')
        Write-Ok '已移除 show-ultra-in-model-picker-slider'

        if ($text -ne $original) {
            $tmp = "$ConfigPath.tmp"
            [System.IO.File]::WriteAllText($tmp, $text)
            Move-Item -Path $tmp -Destination $ConfigPath -Force
            Write-Ok 'config.toml 已写入'
        }
        else {
            Write-Ok 'config.toml 无需修改'
        }
    }
    catch {
        Write-Host "[!] 还原 config.toml 失败：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# --- 4. 删除安装目录 ---
if ($RemoveFiles) {
    Write-Step "删除安装目录 $InstallDir"
    try {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction Stop
        Write-Ok '安装目录已删除'
    }
    catch {
        Write-Host "[!] 删除失败（可能有文件被占用）：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}
else {
    Write-Host "[!] 未指定 -RemoveFiles，安装目录保留：$InstallDir" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== 卸载完成 ===' -ForegroundColor White
Write-Host '建议重启 Codex，使配置变更生效。'
