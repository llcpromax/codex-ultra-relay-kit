param([switch]$Force)

$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$port = 9333
$proxyPort = 8787
$log = Join-Path $dir 'launcher.log'
$lock = Join-Path $dir 'launch.lock'
$config = Join-Path $env:USERPROFILE '.codex\config.toml'
$proxyScript = Join-Path $dir 'proxy.py'
$repair = Join-Path $dir 'repair-config.ps1'

function Log([string]$m) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [launcher] $m" | Out-File -FilePath $log -Append -Encoding utf8
}

function Resolve-Pythonw {
    $exe = Get-Command pythonw.exe -ErrorAction SilentlyContinue
    if ($exe) { return $exe.Source }
    $exe = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($exe) { return $exe.Source }
    throw '未找到 Python。请先安装 Python 3.9+ 并确保 pythonw.exe 在 PATH 中。'
}

function Get-CodexAumid {
    $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pkg) {
        throw '未找到 OpenAI.Codex 应用包。请先安装 Codex 桌面版（MSIX）。'
    }
    $manifest = Get-AppxPackageManifest -Package $pkg.PackageFullName
    $appId = $manifest.Package.Applications.Application.Id
    if ($appId -is [array]) { $appId = $appId[0] }
    if (-not $appId) {
        $appId = $manifest.Package.Applications.Application[0].Id
    }
    return "$($pkg.PackageFamilyName)!$appId"
}

# --- 0. take the launch lock (watcher uses it to avoid double launches) ---
try {
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
    Set-Content -Path $lock -Value (Get-Date -Format 'o') -Encoding utf8 -ErrorAction SilentlyContinue
}
catch { }

# --- 0b. make sure the relay proxy is running ---
if (-not (Get-NetTCPConnection -LocalPort $proxyPort -State Listen -ErrorAction SilentlyContinue)) {
    $pythonw = Resolve-Pythonw
    Start-Process -FilePath $pythonw -ArgumentList $proxyScript -WindowStyle Hidden
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Get-NetTCPConnection -LocalPort $proxyPort -State Listen -ErrorAction SilentlyContinue) { break }
    }
    Log "started relay proxy"
}

# --- 0c. skip when an Ultra-enabled instance is already running ---
if (-not $Force -and (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)) {
    Log "ultra instance already running; skip"
    Remove-Item $lock -Force -ErrorAction SilentlyContinue
    exit
}

# --- 1. close any running Codex desktop instance ---
Get-Process ChatGPT, Codex -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# --- 1b. repair config.toml after closing Codex (avoids file lock) ---
& $repair -ConfigPath $config *> $null

# --- 2. activate the packaged app with a remote debugging port ---
$code = @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.CompilerServices;

[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IApplicationActivationManager {
    [PreserveSig] int ActivateApplication([In, MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, [In, MarshalAs(UnmanagedType.LPWStr)] string arguments, [In] uint options, [Out] out uint processId);
    [PreserveSig] int ActivateForFile([In, MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, [In] IntPtr itemArray, [In, MarshalAs(UnmanagedType.LPWStr)] string verb, [Out] out uint processId);
    [PreserveSig] int ActivateForProtocol([In, MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, [In] IntPtr itemArray, [Out] out uint processId);
}

[ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
public class ApplicationActivationManager : IApplicationActivationManager {
    [MethodImpl(MethodImplOptions.InternalCall, MethodCodeType = MethodCodeType.Runtime)]
    public extern int ActivateApplication(string appUserModelId, string arguments, uint options, out uint processId);
    [MethodImpl(MethodImplOptions.InternalCall, MethodCodeType = MethodCodeType.Runtime)]
    public extern int ActivateForFile(string appUserModelId, IntPtr itemArray, string verb, out uint processId);
    [MethodImpl(MethodImplOptions.InternalCall, MethodCodeType = MethodCodeType.Runtime)]
    public extern int ActivateForProtocol(string appUserModelId, IntPtr itemArray, out uint processId);
}
'@
Add-Type -TypeDefinition $code
$mgr = New-Object ApplicationActivationManager
$appUserModelId = Get-CodexAumid
[uint32]$procId = 0
$hr = $mgr.ActivateApplication($appUserModelId, "--remote-debugging-port=$port", 0, [ref]$procId)
Log "activate aumid=$appUserModelId hr=$hr pid=$procId"

# --- 3. wait for the renderer target ---
$target = $null
for ($i = 0; $i -lt 120; $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $targets = Invoke-RestMethod "http://127.0.0.1:$port/json" -TimeoutSec 2
        $target = $targets | Where-Object { $_.type -eq 'page' -and $_.url -like 'app://*' } | Select-Object -First 1
        if ($null -ne $target) { break }
    }
    catch { }
}
if ($null -eq $target) {
    Log "no CDP target"
    throw 'no CDP target'
}
Log "target: $($target.title) $($target.url)"

# --- 4. connect to CDP ---
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = [Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, $ct).Wait()

function Eval([string]$expr) {
    $payload = @{ id = 1; method = 'Runtime.evaluate'; params = @{ expression = $expr; returnByValue = $true; awaitPromise = $true } } |
        ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $bytes)
    $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()
    $buf = New-Object byte[] 262144
    $seg2 = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $buf)
    $r = $ws.ReceiveAsync($seg2, $ct).Result
    return [Text.Encoding]::UTF8.GetString($buf, 0, $r.Count)
}

# --- 5. wait for Statsig client ---
$ready = $false
for ($i = 0; $i -lt 120; $i++) {
    $resp = Eval "(()=>{const g=window.__STATSIG__;return (g&&g.instances&&Object.keys(g.instances).length)?'ready':'no';})()"
    if ($resp -match '"value":"ready"') { $ready = $true; break }
    Start-Sleep -Milliseconds 500
}
Log "statsig ready=$ready"
if (-not $ready) { $ws.Dispose(); throw 'statsig not ready' }

# --- 6. inject the ultra gate ---
$inject = @'
(()=>{
  const GATE='1186680773';
  const clients=()=>Object.values(window.__STATSIG__?.instances||{});
  const build=()=>({has_updates:true,time:Date.now(),feature_gates:{[GATE]:{name:GATE,value:true,rule_id:'local',secondary_exposures:[],id_type:null}},dynamic_configs:{},layer_configs:{},param_stores:{},response_format:'init-v1'});
  const applyGate=(c)=>{
    if(!c) return 'no-client';
    try{
      const st=c._store;
      st.setValues({data:JSON.stringify(build()),source:'LocalOverride',receivedAt:Date.now()},null,Date.now());
      for(const k of Object.keys(c._memoCache||{})){ if(k.indexOf(GATE)>=0) delete c._memoCache[k]; }
      c.$emt && c.$emt('values_updated');
      return 'ok:'+c.getFeatureGate(GATE,{disableExposureLog:true}).value;
    }catch(e){ return 'err:'+e.message; }
  };
  const applyAll=()=>{ const out=[]; for(const c of clients()){ out.push(applyGate(c)); } return out.join('|'); };
  const first=applyAll();
  if(window.__ultraGateTimer) clearInterval(window.__ultraGateTimer);
  window.__ultraGateTimer=setInterval(()=>{
    for(const c of clients()){
      try{ if(!c.getFeatureGate(GATE,{disableExposureLog:true}).value) applyGate(c); }catch(e){}
    }
  },5000);
  return first;
})()
'@
$resp = Eval $inject
Log "inject: $resp"
$ws.Dispose()
Remove-Item $lock -Force -ErrorAction SilentlyContinue

# --- 7. make sure the watcher is running (detached from any terminal) ---
try {
    $watcher = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*watch-codex.ps1*' }
    if (-not $watcher) {
        $wpath = Join-Path $PSScriptRoot 'watch-codex.ps1'
        $wvbs = Join-Path $PSScriptRoot 'watch-codex-hidden.vbs'
        if (Test-Path $wvbs) {
            $wcmd = "wscript.exe `"$wvbs`""
        }
        else {
            $wcmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$wpath`""
        }
        Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{CommandLine=$wcmd} | Out-Null
        Log "started watcher"
    }
}
catch { Log "watcher start failed: $($_.Exception.Message)" }

Write-Output "ULTRA_LAUNCH_RESULT $resp"
