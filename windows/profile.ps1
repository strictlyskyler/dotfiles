#requires -Version 5.1
<#
  profile.ps1 - PowerShell parity for the POSIX .bashrc + .aliases.

  This is the Windows analogue of the Linux/WSL .bashrc tail that exports the
  Honcho environment and sources ~/.aliases. It defines the same daily-driver
  helpers so PowerShell reaches parity with bash/zsh:

    ai-on / ai-off / ai-support-on / ai-support-off   service control over SSH
    honcho-up / honcho-down / honcho-lan / honcho-tunnel / honcho-status
    hermes-up / hermes-down / hermes-lan / hermes-tunnel / hermes-status

  It is dot-sourced from your $PROFILE by the managed block that install.ps1
  adds. Re-sourcing is safe (idempotent).

  Compatible with Windows PowerShell 5.1 (no pwsh-only syntax).
#>

# ── Honcho environment (parity with .bashrc) ────────────────────────
# Endpoint selection lives in the MCP server / config.json candidate list;
# these are just the identity vars the bridge and helpers expect.
$env:HONCHO_API_KEY  = 'local'
$env:HONCHO_PEER_NAME = 'skyler'

# ── shared constants ────────────────────────────────────────────────
$script:DotfilesTunnelHost = 'ssh.skyler.is'
$script:DotfilesHonchoHome = Join-Path $HOME '.honcho'
$script:DotfilesHermesHome = Join-Path $HOME '.hermes'

# Service lists mirror the _AI_SERVICES / _AI_SUPPORT vars in .aliases.
$script:DotfilesAiServices = 'ollama open-webui honcho honcho-deriver honcho-db honcho-redis firecrawl firecrawl-playwright firecrawl-postgres firecrawl-rabbitmq firecrawl-redis harbor-cat'
$script:DotfilesAiSupport  = 'honcho honcho-deriver honcho-db honcho-redis firecrawl firecrawl-playwright firecrawl-postgres firecrawl-rabbitmq firecrawl-redis'

# Put bun on PATH for this session if it is installed (the installer also adds
# it to the persistent user PATH).
$bunBin = Join-Path $HOME '.bun\bin'
if ((Test-Path $bunBin) -and (($env:Path -split ';') -notcontains $bunBin)) {
  $env:Path = "$bunBin;$env:Path"
}

# ── low-level helpers ───────────────────────────────────────────────

# Write text as UTF-8 WITHOUT a BOM. PowerShell 5.1's Set-Content/Out-File add a
# BOM with -Encoding UTF8, which would make Node's JSON.parse choke on
# config.json. .NET's WriteAllText with an explicit UTF8Encoding($false) avoids
# that.
function Write-DotfilesUtf8NoBom {
  param([Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text)
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Resolve-DotfilesPython {
  foreach ($candidate in 'python', 'python3') {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

# Match the detached ssh.exe processes that hold a given local port forward.
function Get-DotfilesTunnelProcess {
  param([Parameter(Mandatory = $true)][int]$Port)
  $needle = "-L $Port`:localhost:$Port"
  Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$needle*" }
}

function Stop-DotfilesTunnel {
  param([Parameter(Mandatory = $true)][int]$Port)
  foreach ($proc in @(Get-DotfilesTunnelProcess -Port $Port)) {
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
  }
}

# Open a detached, hidden SSH port-forward. Windows OpenSSH does not support the
# POSIX `-f` (fork into background), so we background it with Start-Process.
function Start-DotfilesTunnel {
  param([Parameter(Mandatory = $true)][int]$Port)
  if (Get-DotfilesTunnelProcess -Port $Port) { return }
  $sshArgs = @(
    '-N',
    '-o', 'ServerAliveInterval=60',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-L', "$Port`:localhost:$Port",
    $script:DotfilesTunnelHost
  )
  Start-Process -FilePath 'ssh' -ArgumentList $sshArgs -WindowStyle Hidden | Out-Null
}

# ── AI service control (parity with ai-* aliases) ───────────────────
function ai-on          { ssh $script:DotfilesTunnelHost "cd ~/services && podman-compose start $script:DotfilesAiServices" }
function ai-off         { ssh $script:DotfilesTunnelHost "cd ~/services && podman-compose stop $script:DotfilesAiServices" }
function ai-support-on  { ssh $script:DotfilesTunnelHost "cd ~/services && podman-compose start $script:DotfilesAiSupport" }
function ai-support-off { ssh $script:DotfilesTunnelHost "cd ~/services && podman-compose stop $script:DotfilesAiSupport" }

# ── Honcho endpoint + tunnel (parity with honcho-* helpers) ─────────
function Set-HonchoEndpoint {
  param([Parameter(Mandatory = $true)][string]$BaseUrl)
  $cfg = Join-Path $script:DotfilesHonchoHome 'config.json'
  if (-not (Test-Path $cfg)) {
    Write-Warning "Honcho config not found: $cfg"
    return
  }
  try {
    $data = Get-Content -Raw -LiteralPath $cfg | ConvertFrom-Json
  }
  catch {
    Write-Warning "Could not parse ${cfg}: $_"
    return
  }

  if ($BaseUrl -match 'localhost|127\.0\.0\.1') { $fallback = 'http://orphic-lens:8100' }
  else { $fallback = 'http://localhost:8100' }
  $candidates = @($BaseUrl)
  if ($candidates -notcontains $fallback) { $candidates += $fallback }

  if ($null -eq $data.endpoint) {
    $data | Add-Member -NotePropertyName endpoint -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  $data.endpoint | Add-Member -NotePropertyName baseUrl    -NotePropertyValue $BaseUrl -Force
  $data.endpoint | Add-Member -NotePropertyName candidates -NotePropertyValue ([string[]]$candidates) -Force

  Write-DotfilesUtf8NoBom -Path $cfg -Text (($data | ConvertTo-Json -Depth 20) + "`n")
}

function honcho-up {
  Start-DotfilesTunnel -Port 8100
  Start-Sleep -Milliseconds 500
  Set-HonchoEndpoint 'http://localhost:8100'
  Write-Host 'Honcho tunnel up (localhost:8100)'
}

function honcho-down {
  Stop-DotfilesTunnel -Port 8100
  Set-HonchoEndpoint 'http://orphic-lens:8100'
  Write-Host 'Honcho tunnel down; Honcho endpoint set to LAN (orphic-lens)'
}

function honcho-lan {
  Set-HonchoEndpoint 'http://orphic-lens:8100'
  Write-Host 'Honcho endpoint set to LAN (orphic-lens)'
}

function honcho-tunnel {
  Set-HonchoEndpoint 'http://localhost:8100'
  Write-Host 'Honcho endpoint set to tunnel (localhost:8100)'
}

function honcho-status {
  $procs = @(Get-DotfilesTunnelProcess -Port 8100)
  if ($procs.Count -gt 0) {
    $ids = ($procs | ForEach-Object { $_.ProcessId }) -join ','
    Write-Host "Honcho tunnel: UP (pid $ids)"
  }
  else {
    Write-Host 'Honcho tunnel: DOWN'
  }
  $cfg = Join-Path $script:DotfilesHonchoHome 'config.json'
  if (Test-Path $cfg) {
    try {
      $data = Get-Content -Raw -LiteralPath $cfg | ConvertFrom-Json
      if ($data.endpoint.baseUrl) { $base = $data.endpoint.baseUrl } else { $base = 'unset' }
      if ($data.endpoint.candidates) { $cand = ($data.endpoint.candidates -join ', ') } else { $cand = '' }
      Write-Host "Honcho endpoint: $base"
      Write-Host "Honcho candidates: $cand"
    }
    catch { }
  }
}

# ── Hermes endpoint + tunnel (parity with hermes-* helpers) ─────────
# Hermes' config is YAML, which Windows PowerShell can't parse natively, so the
# edit is delegated to python+PyYAML exactly like the bash helper. Hermes is
# rarely set up on Windows; these degrade gracefully when ~/.hermes is absent.
function Set-HermesEndpoint {
  param([Parameter(Mandatory = $true)][string]$LlmBaseUrl,
        [Parameter(Mandatory = $true)][string]$HonchoBaseUrl)
  $cfg = Join-Path $script:DotfilesHermesHome 'config.yaml'
  $honcho = Join-Path $script:DotfilesHermesHome 'honcho.json'
  if (-not (Test-Path $cfg) -and -not (Test-Path $honcho)) {
    Write-Warning 'Hermes config not found (~/.hermes). Hermes is not set up on this machine.'
    return
  }
  $py = Resolve-DotfilesPython
  if (-not $py) {
    Write-Warning 'python not found; cannot edit Hermes YAML config.'
    return
  }
  $script = @'
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("PyYAML not installed; run: python -m pip install pyyaml", file=sys.stderr)
    raise SystemExit(1)

config_path = Path(sys.argv[1])
honcho_path = Path(sys.argv[2])
llm_base_url = sys.argv[3]
honcho_base_url = sys.argv[4]

if config_path.exists():
    data = yaml.safe_load(config_path.read_text()) or {}
    for block in (data.get("model"), data.get("delegation")):
        if isinstance(block, dict):
            block["base_url"] = llm_base_url
    compression = data.get("compression")
    if isinstance(compression, dict):
        compression["summary_base_url"] = llm_base_url
    auxiliary = data.get("auxiliary")
    if isinstance(auxiliary, dict):
        for block in auxiliary.values():
            if isinstance(block, dict) and "base_url" in block:
                block["base_url"] = llm_base_url
    providers = data.get("custom_providers")
    if isinstance(providers, list):
        for provider in providers:
            if isinstance(provider, dict) and provider.get("name") == "orphic-lens":
                provider["base_url"] = llm_base_url
    config_path.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True))

if honcho_path.exists():
    data = json.loads(honcho_path.read_text())
    data["baseUrl"] = honcho_base_url
    honcho_path.write_text(json.dumps(data, indent=2) + "\n")
'@
  $script | & $py - $cfg $honcho $LlmBaseUrl $HonchoBaseUrl
}

function hermes-tunnel {
  Set-HermesEndpoint 'http://127.0.0.1:11434/v1' 'http://127.0.0.1:8100'
  Write-Host 'Hermes endpoint set to tunnel (127.0.0.1)'
}

function hermes-lan {
  Set-HermesEndpoint 'http://orphic-lens:11434/v1' 'http://orphic-lens:8100'
  Write-Host 'Hermes endpoint set to LAN (orphic-lens)'
}

function hermes-up {
  honcho-up
  Start-DotfilesTunnel -Port 11434
  hermes-tunnel
  Write-Host 'Hermes tunnel up (localhost:11434)'
}

function hermes-down {
  Stop-DotfilesTunnel -Port 11434
  hermes-lan
  Write-Host 'Hermes tunnel down'
}

function hermes-status {
  $procs = @(Get-DotfilesTunnelProcess -Port 11434)
  if ($procs.Count -gt 0) {
    $ids = ($procs | ForEach-Object { $_.ProcessId }) -join ','
    Write-Host "Hermes LLM tunnel: UP (pid $ids)"
  }
  else {
    Write-Host 'Hermes LLM tunnel: DOWN'
  }
  $cfg = Join-Path $script:DotfilesHermesHome 'config.yaml'
  $honcho = Join-Path $script:DotfilesHermesHome 'honcho.json'
  $py = Resolve-DotfilesPython
  if ($py -and ((Test-Path $cfg) -or (Test-Path $honcho))) {
    $script = @'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
honcho_path = Path(sys.argv[2])
if config_path.exists():
    try:
        import yaml
        data = yaml.safe_load(config_path.read_text()) or {}
        print(f"Hermes LLM endpoint: {data.get('model', {}).get('base_url', 'unset')}")
    except ImportError:
        print("Hermes LLM endpoint: (install PyYAML to read)")
if honcho_path.exists():
    data = json.loads(honcho_path.read_text())
    print(f"Hermes Honcho endpoint: {data.get('baseUrl', 'unset')}")
'@
    $script | & $py - $cfg $honcho
  }
}

# ── terminal title (parity with the Tabby OSC title hook) ───────────
# Sets the window title to the current directory (with $HOME shown as ~). Opt
# out with $env:DOTFILES_NO_TITLE = '1' before the profile loads.
if ($env:DOTFILES_NO_TITLE -ne '1' -and -not $global:__DotfilesTitleHook) {
  $global:__DotfilesOriginalPrompt = $function:prompt
  function global:prompt {
    try {
      $loc = (Get-Location).Path
      $disp = $loc -replace [regex]::Escape($HOME), '~'
      $Host.UI.RawUI.WindowTitle = $disp
    }
    catch { }
    if ($global:__DotfilesOriginalPrompt) { & $global:__DotfilesOriginalPrompt }
    else { "PS $((Get-Location).Path)> " }
  }
  $global:__DotfilesTitleHook = $true
}
