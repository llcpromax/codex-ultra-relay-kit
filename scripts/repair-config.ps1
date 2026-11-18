param(
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.codex\config.toml'),
    [string]$UpstreamPath = (Join-Path $PSScriptRoot 'upstream.txt'),
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot 'repair.log'
$launcher = Join-Path $PSScriptRoot 'start-codex-ultra.ps1'

function Log([string]$m) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [repair] $m" | Out-File -FilePath $log -Append -Encoding utf8
}

try {
    if (-not (Test-Path $ConfigPath)) { Log "config not found: $ConfigPath"; exit }
    $text = [System.IO.File]::ReadAllText($ConfigPath)
    $original = $text
    $changedText = $false
    $changedUpstream = $false
    $wasRunning = [bool](Get-Process ChatGPT -ErrorAction SilentlyContinue)

    # 1) active provider base_url -> local proxy, remember the real upstream
    $provider = $null
    $pm = [regex]::Match($text, '(?m)^\s*model_provider\s*=\s*"([^"]+)"')
    if ($pm.Success) { $provider = $pm.Groups[1].Value }
    Log "active provider: $provider"

    if ($provider) {
        $pattern = '(?ms)^\[model_providers\.' + [regex]::Escape($provider) + '\]\s*\r?\n(.*?)(?=^\[|\z)'
        $sm = [regex]::Match($text, $pattern)
        if ($sm.Success) {
            $body = $sm.Groups[1].Value
            $bm = [regex]::Match($body, 'base_url\s*=\s*"([^"]+)"')
            if ($bm.Success) {
                $base = $bm.Groups[1].Value
                if ($base -match '^https?://' -and $base -notmatch '^https?://(127\.0\.0\.1|localhost)(:\d+)?') {
                    [System.IO.File]::WriteAllText($UpstreamPath, $base + "`r`n")
                    $changedUpstream = $true
                    Log "upstream updated: $base"
                    $newBody = [regex]::Replace($body, 'base_url\s*=\s*"[^"]+"', 'base_url = "http://127.0.0.1:8787"')
                    $text = $text.Substring(0, $sm.Groups[1].Index) + $newBody + $text.Substring($sm.Groups[1].Index + $sm.Groups[1].Length)
                    $changedText = $true
                    Log "base_url -> http://127.0.0.1:8787"
                }
                else {
                    Log "base_url already local/proxy: $base"
                }
            }
            else { Log "base_url not found in provider section" }
        }
        else { Log "provider section not found: model_providers.$provider" }
    }

    # 2) ensure the Ultra slider setting survives config rewrites
    $desktopPattern = '(?ms)^\[desktop\]\s*\r?\n(.*?)(?=^\[|\z)'
    $dm = [regex]::Match($text, $desktopPattern)
    if ($dm.Success) {
        $body = $dm.Groups[1].Value
        if ($body -match '(?m)^\s*show-ultra-in-model-picker-slider\s*=') {
            $newBody = [regex]::Replace($body, '(?m)^\s*show-ultra-in-model-picker-slider\s*=.*$', 'show-ultra-in-model-picker-slider = true')
        }
        else {
            $newBody = "show-ultra-in-model-picker-slider = true`r`n" + $body
        }
        if ($newBody -ne $body) {
            $text = $text.Substring(0, $dm.Groups[1].Index) + $newBody + $text.Substring($dm.Groups[1].Index + $dm.Groups[1].Length)
            $changedText = $true
            Log "desktop setting ensured"
        }
    }
    else {
        $text = $text.TrimEnd() + "`r`n`r`n[desktop]`r`nshow-ultra-in-model-picker-slider = true`r`n"
        $changedText = $true
        Log "desktop section appended"
    }

    # 2b) ensure the custom model catalog is configured
    $catalogPath = Join-Path (Split-Path $ConfigPath -Parent) 'model-catalog-v2.json'
    if (Test-Path $catalogPath) {
        $catalogToml = $catalogPath.Replace('\', '/')
        $catalogLine = 'model_catalog_json = "' + $catalogToml + '"'
        if ($text -match '(?m)^\s*model_catalog_json\s*=') {
            $newText = [regex]::Replace($text, '(?m)^\s*model_catalog_json\s*=.*$', $catalogLine)
        }
        else {
            $newText = $catalogLine + "`r`n" + $text
        }
        if ($newText -ne $text) {
            $text = $newText
            $changedText = $true
            Log "model catalog ensured"
        }
    }

    # 3) write the config only when something changed
    if ($changedText -and $Restart -and $wasRunning) {
        Log "stopping Codex to write config"
        Get-Process ChatGPT, Codex -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 2
    }

    if ($text -ne $original) {
        $tmp = "$ConfigPath.tmp"
        [System.IO.File]::WriteAllText($tmp, $text)
        Move-Item -Path $tmp -Destination $ConfigPath -Force
        Log "config written"
    }
    else {
        Log "config unchanged"
    }

    # 4) restart Codex to apply the desktop setting
    if ($Restart -and ($changedText -or $changedUpstream) -and $wasRunning) {
        Log "restarting Codex to apply config"
        Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $launcher, '-Force' -WindowStyle Hidden
    }
    elseif ($Restart -and ($changedText -or $changedUpstream)) {
        Log "Codex not running; restart skipped"
    }
}
catch {
    Log "ERROR: $($_.Exception.Message)"
}
