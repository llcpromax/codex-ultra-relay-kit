param(
    [string]$Upstream,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

$SourceDir = Join-Path $PSScriptRoot 'scripts'
$InstallDir = Join-Path $env:USERPROFILE '.codex\relay-proxy'
$ConfigPath = Join-Path $env:USERPROFILE '.codex\config.toml'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Write-Step([string]$m) {
    Write-Host "[*] $m" -ForegroundColor Cyan
}

function Write-Ok([string]$m) {
    Write-Host "[+] $m" -ForegroundColor Green
}

function Resolve-Pythonw {
    $exe = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if ($exe) { return $exe.Source }
    $exe = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($exe) { return $exe.Source }
    throw '未找到 Python。请先安装 Python 3.9+（安装时勾选 Add to PATH），然后重新运行本脚本。'
}

Write-Host '=== Codex Ultra Relay Kit 安装 ===' -ForegroundColor White

if (-not (Test-Path $SourceDir)) {
    throw "未找到 scripts 目录：$SourceDir（请在仓库根目录运行 install.ps1）"
}

$pythonw = Resolve-Pythonw
Write-Ok "Python: $pythonw"

# --- 1. 复制脚本 ---
Write-Step "安装到 $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item -Path (Join-Path $SourceDir '*.ps1') -Destination $InstallDir -Force
Copy-Item -Path (Join-Path $SourceDir 'proxy.py') -Destination $InstallDir -Force
Write-Ok '脚本已复制'

# --- 2. upstream.txt ---
$upstreamPath = Join-Path $InstallDir 'upstream.txt'
if (-not (Test-Path $upstreamPath)) {
    if ($Upstream) {
        $value = $Upstream.Trim()
    }
    else {
        $example = Join-Path $SourceDir 'upstream.txt.example'
        $value = (Get-Content -Path $example -TotalCount 1).Trim()
        Write-Host "    未指定 -Upstream，使用示例值：$value" -ForegroundColor Yellow
        Write-Host "    稍后可编辑 $upstreamPath 改成你的中转站地址。" -ForegroundColor Yellow
    }
    [System.IO.File]::WriteAllText($upstreamPath, $value + "`r`n")
    Write-Ok "已创建 upstream.txt -> $value"
}
else {
    Write-Ok "保留已有 upstream.txt -> $((Get-Content -Path $upstreamPath -TotalCount 1).Trim())"
}

# --- 3. 关闭 Codex，修复 config.toml ---
$running = Get-Process ChatGPT, Codex -ErrorAction SilentlyContinue
if ($running) {
    Write-Host '[!] 将关闭正在运行的 ChatGPT/Codex 以修改 config.toml' -ForegroundColor Yellow
    $running | Stop-Process -Force
    Start-Sleep -Seconds 2
}
Write-Step '修复 config.toml（它必须存在，且包含 model_provider 配置）'
if (Test-Path $ConfigPath) {
    & (Join-Path $InstallDir 'repair-config.ps1') -ConfigPath $ConfigPath | Out-Null
    Write-Ok 'config.toml 已指向本地代理，并启用 Ultra 选项'
}
else {
    Write-Host "[!] 未找到 $ConfigPath，请先在 Codex 客户端配置好中转站，再运行 repair-config.ps1" -ForegroundColor Yellow
}

# --- 4. 自启动项 ---
Write-Step '注册开机自启项（HKCU Run）'
$proxyPath = Join-Path $InstallDir 'proxy.py'
$launcherPath = Join-Path $InstallDir 'start-codex-ultra.ps1'
$watcherPath = Join-Path $InstallDir 'watch-codex.ps1'

New-Item -Path $RunKey -Force | Out-Null
Set-ItemProperty -Path $RunKey -Name 'CodexRelayProxy' -Value "`"$pythonw`" `"$proxyPath`""
Set-ItemProperty -Path $RunKey -Name 'CodexUltraLauncher' -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherPath`""
Set-ItemProperty -Path $RunKey -Name 'CodexUltraWatcher' -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watcherPath`""
Write-Ok '自启项已注册：CodexRelayProxy / CodexUltraLauncher / CodexUltraWatcher'

# --- 5. 启动代理与守护 ---
Write-Step '启动本地代理与守护进程'
if (-not (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue)) {
    $pcmd = "`"$pythonw`" `"$proxyPath`""
    Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$pcmd} | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue) { break }
    }
}
if (Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue) {
    Write-Ok '代理已在 127.0.0.1:8787 监听'
}
else {
    Write-Host '[!] 代理未能在 8787 端口监听，见 proxy.log' -ForegroundColor Yellow
}

$watcherRunning = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*watch-codex.ps1*' }
if (-not $watcherRunning) {
    $wcmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watcherPath`""
    Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$wcmd} | Out-Null
    Write-Ok '守护进程已启动'
}
else {
    Write-Ok '守护进程已在运行'
}

# --- 6. 启动器 VBS ---
Write-Step '生成隐藏启动脚本'
$vbsPath = Join-Path $InstallDir 'Launch Codex Ultra.vbs'
$vbs = @"
Option Explicit
Dim sh
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$launcherPath""", 0, False
"@
[System.IO.File]::WriteAllText($vbsPath, $vbs, [System.Text.Encoding]::Default)
Write-Ok "已生成 $vbsPath"

# --- 7. 桌面快捷方式 ---
$shortcutCreated = $false
try {
    $shell = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desktop 'Codex Ultra.lnk'
    $sc = $shell.CreateShortcut($lnk)
    $sc.TargetPath = $vbsPath
    $sc.WorkingDirectory = $InstallDir
    $sc.Description = '以 Ultra 模式启动 Codex'
    $sc.Save()
    $shortcutCreated = $true
    Write-Ok "桌面快捷方式已创建：$lnk"
}
catch {
    Write-Host "[!] 创建桌面快捷方式失败：$($_.Exception.Message)" -ForegroundColor Yellow
}

# --- 8. 启动 Codex ---
if (-not $NoStart) {
    Write-Step '启动 Codex（Ultra）'
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $launcherPath -WindowStyle Hidden
    Write-Ok '启动器已在后台运行，等待 Codex 窗口出现'
}

Write-Host ''
Write-Host '=== 安装完成 ===' -ForegroundColor White
Write-Host "安装目录：$InstallDir"
Write-Host "上游地址：$upstreamPath"
Write-Host ''
Write-Host '下一步：'
Write-Host '  1. 等待 Codex 启动完成，打开模型选择器应能看到 Ultra 选项'
Write-Host '  2. 之后请用桌面快捷方式 "Codex Ultra" 启动；直接点官方图标时守护进程会自动接管'
Write-Host '  3. 更换中转站：编辑 upstream.txt 后重启代理，或让 CC Switch 覆盖 config.toml 触发自动修复'
Write-Host '  4. 日志：proxy.log / launcher.log / watcher.log / repair.log（都在安装目录）'
if (-not $shortcutCreated) {
    Write-Host ''
    Write-Host "未能自动创建桌面快捷方式，请右键 $vbsPath -> 发送到 -> 桌面快捷方式" -ForegroundColor Yellow
}
