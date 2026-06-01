#requires -Version 5.1
<#
.SYNOPSIS
  Dotfiles installer for Windows + PowerShell.

.DESCRIPTION
  Windows/PowerShell analogue of install.sh. It installs what it can
  (Node/npm via winget, bun via the official script, the Honcho MCP bridge
  deps, cursor-honcho), copies/links the dotfiles into place, wires up Cursor's
  MCP + hooks with Windows-native commands, and bootstraps the Honcho memory
  server.

  Like install.sh, real failures abort with a clear error so nothing breaks
  silently. Re-running is safe and idempotent.

  Hermes is intentionally skipped on Windows (its installer is a POSIX
  curl|bash script and it expects a *nix ~/.hermes). The hermes-* helpers in
  profile.ps1 still work against a tunneled *nix Hermes if one exists.

.PARAMETER SkipNode
  Do not attempt to install Node via winget (assume it is present or unwanted).

.PARAMETER SkipBun
  Do not attempt to install bun.

.PARAMETER SkipCursorHoncho
  Skip cloning/patching cursor-honcho and writing Cursor hooks.

.PARAMETER SkipHonchoServer
  Skip the Honcho reachability/tunnel/smoke-test/bootstrap phase.

.PARAMETER Symlink
  Create symlinks instead of copies for dotfiles (requires Developer Mode or an
  elevated shell). Defaults to copying, which needs no special privileges.
#>
[CmdletBinding()]
param(
  [switch]$SkipNode,
  [switch]$SkipBun,
  [switch]$SkipCursorHoncho,
  [switch]$SkipHonchoServer,
  [switch]$Symlink
)

$ErrorActionPreference = 'Stop'

# ── paths ───────────────────────────────────────────────────────────
$ScriptDir = $PSScriptRoot
$RepoDir   = Split-Path -Parent $ScriptDir
$HomeDir   = $HOME

$CursorHonchoDir   = Join-Path $HomeDir '.honcho\plugins\cursor-honcho'
$PluginRoot        = Join-Path $CursorHonchoDir 'plugins\honcho'
$CursorHonchoRepo  = 'https://github.com/plastic-labs/cursor-honcho.git'
$CursorHonchoPatch = Join-Path $RepoDir 'scripts\patch_cursor_honcho.py'
$AttributionScript = Join-Path $RepoDir 'scripts\disable_cursor_git_attribution.py'

# Honcho reachability (overridable via env, same knobs as install.sh).
if ($env:HONCHO_PORT) { $HonchoPort = [int]$env:HONCHO_PORT } else { $HonchoPort = 8100 }
if ($env:HONCHO_TUNNEL_HOST) { $TunnelHost = $env:HONCHO_TUNNEL_HOST } else { $TunnelHost = 'ssh.skyler.is' }
if ($env:HONCHO_TUNNEL_USER) { $TunnelUser = $env:HONCHO_TUNNEL_USER } else { $TunnelUser = 'skyler' }
$LanUrl      = "http://orphic-lens:$HonchoPort"
$LoopbackUrl = "http://localhost:$HonchoPort"

# ── logging / helpers ───────────────────────────────────────────────
function Log  { param([string]$Message) Write-Host $Message }
function Die  { param([string]$Message) Write-Host "ERROR  $Message" -ForegroundColor Red; exit 1 }
function Have { param([string]$Name) [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Write-Utf8NoBom {
  param([Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text)
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# Refresh the current session's PATH from the Machine + User registry values so
# tools installed during this run (winget Node, bun) become callable here.
function Update-SessionPath {
  $machine = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user    = [System.Environment]::GetEnvironmentVariable('Path', 'User')
  $parts = @()
  foreach ($p in @($machine, $user)) { if ($p) { $parts += $p } }
  $bunBin = Join-Path $HomeDir '.bun\bin'
  if (Test-Path $bunBin) { $parts = @($bunBin) + $parts }
  $env:Path = ($parts -join ';')
}

# Resolve a real Python 3 interpreter. Returns an object { Exe; Pre } or $null.
# Guards against the Windows Store "python.exe" execution-alias stub, which
# resolves on PATH but only opens the Store when Python isn't actually present.
function Resolve-Python {
  $tries = @(
    @{ Exe = 'py';      Pre = @('-3') },
    @{ Exe = 'python';  Pre = @() },
    @{ Exe = 'python3'; Pre = @() }
  )
  foreach ($t in $tries) {
    if (-not (Have $t.Exe)) { continue }
    try {
      $out = (& $t.Exe @($t.Pre + @('--version')) 2>&1 | Out-String)
    }
    catch { continue }
    if ($out -match 'Python 3') {
      return [pscustomobject]@{ Exe = (Get-Command $t.Exe).Source; Pre = $t.Pre }
    }
  }
  return $null
}

# Run a native (non-PowerShell) command so its stderr is NEVER treated as a
# terminating error. With $ErrorActionPreference = 'Stop', redirecting native
# stderr (2>&1) turns ordinary notices (pip messages, npm/git/bun progress) into
# a fatal NativeCommandError. Localizing EAP to 'Continue' for the call avoids
# that while still surfacing output. Returns the process exit code.
function Invoke-Native {
  param([Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments = @(),
        [switch]$Quiet)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($Quiet) { & $Exe @Arguments 2>&1 | Out-Null }
    else { & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host $_ } }
  }
  finally { $ErrorActionPreference = $prev }
  return $LASTEXITCODE
}

function Invoke-Python {
  param([Parameter(Mandatory = $true)]$Python,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$Quiet)
  return (Invoke-Native -Exe $Python.Exe -Arguments ($Python.Pre + $Arguments) -Quiet:$Quiet)
}

$script:Python = $null

# ── dependencies ────────────────────────────────────────────────────
function Ensure-CoreTools {
  if (-not (Have git)) {
    Die "git not found. Install Git for Windows (winget install Git.Git) and re-run."
  }
  $script:Python = Resolve-Python
  if (-not $script:Python) {
    if (Have winget) {
      Log "INST  Python (winget)"
      $null = Invoke-Native -Exe 'winget' -Arguments @('install', '--id', 'Python.Python.3.12', '--source', 'winget', '--accept-source-agreements', '--accept-package-agreements', '--silent') -Quiet
      Update-SessionPath
      $script:Python = Resolve-Python
    }
  }
  if (-not $script:Python) {
    Die "Python 3 not found. Install it (winget install Python.Python.3.12, or from python.org) and re-run. The cursor-honcho patcher and the disable-attribution step need it."
  }
  Log ("OK    core tools (git, {0})" -f $script:Python.Exe)
}

# PyYAML is only needed by the hermes-* helpers (rare on Windows). Best-effort:
# a failure here is a NOTE, never fatal.
function Ensure-PyYaml {
  if ((Invoke-Python -Python $script:Python -Arguments @('-c', 'import yaml') -Quiet) -eq 0) {
    Log "OK    PyYAML"
    return
  }
  Log "INST  PyYAML (for hermes-* helpers)"
  $null = Invoke-Python -Python $script:Python -Arguments @('-m', 'pip', 'install', '--user', '--disable-pip-version-check', 'pyyaml')
  if ((Invoke-Python -Python $script:Python -Arguments @('-c', 'import yaml') -Quiet) -eq 0) {
    Log "OK    PyYAML"
  }
  else {
    Log "NOTE  PyYAML not installed; hermes-* helpers will warn until 'python -m pip install pyyaml'."
  }
}

function Ensure-Node {
  if ((Have node) -and (Have npm)) {
    Log ("OK    node {0} / npm {1}" -f (node --version), (npm --version))
    return
  }
  if ($SkipNode) {
    Log "SKIP  node (--SkipNode); MCP bridge + cursor-honcho steps need it."
    return
  }
  if (-not (Have winget)) {
    Die "node/npm not found and winget is unavailable. Install Node LTS from https://nodejs.org and re-run (or pass -SkipNode)."
  }
  Log "INST  node + npm (winget OpenJS.NodeJS.LTS)"
  $null = Invoke-Native -Exe 'winget' -Arguments @('install', '--id', 'OpenJS.NodeJS.LTS', '--source', 'winget', '--accept-source-agreements', '--accept-package-agreements', '--silent') -Quiet
  Update-SessionPath
  if (-not (Have node)) {
    # winget often puts node here even before a shell restart.
    $nodeDir = Join-Path $env:ProgramFiles 'nodejs'
    if (Test-Path (Join-Path $nodeDir 'node.exe')) { $env:Path = "$nodeDir;$env:Path" }
  }
  if (-not (Have node) -or -not (Have npm)) {
    Die "Node install via winget did not put node/npm on PATH. Open a new shell and re-run, or install Node LTS manually."
  }
  Log ("OK    node {0} / npm {1}" -f (node --version), (npm --version))
}

function Install-Bun {
  $bunExe = Join-Path $HomeDir '.bun\bin\bun.exe'
  if ((Have bun) -or (Test-Path $bunExe)) {
    Update-SessionPath
    Log ("OK    bun {0}" -f (bun --version))
    return
  }
  if ($SkipBun) {
    Log "SKIP  bun (--SkipBun); cursor-honcho hooks need it."
    return
  }
  Log "INST  bun (official installer)"
  try {
    $installer = Invoke-RestMethod -Uri 'https://bun.sh/install.ps1' -UseBasicParsing
    Invoke-Expression $installer
  }
  catch {
    Die "bun install failed: $_"
  }
  Update-SessionPath
  if (-not (Have bun) -and -not (Test-Path $bunExe)) {
    Die "bun installed but not found on PATH or at $bunExe"
  }
  Log ("OK    bun {0}" -f (bun --version))
}

# ── dotfile install (copy by default, symlink with -Symlink) ────────
function Backup-IfExists {
  param([string]$Dest)
  if (Test-Path -LiteralPath $Dest) {
    $item = Get-Item -LiteralPath $Dest -Force
    if ($item.LinkType -eq 'SymbolicLink') { Remove-Item -LiteralPath $Dest -Force; return }
    $bak = "$Dest.bak"
    if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Recurse -Force }
    Move-Item -LiteralPath $Dest -Destination $bak
    Log "BAK   $Dest -> $bak"
  }
}

function Install-Dotfile {
  param([string]$Src, [string]$Dest, [string]$Label)
  if (-not (Test-Path -LiteralPath $Src)) { Die "expected dotfile missing from repo: $Src" }
  $parent = Split-Path -Parent $Dest
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

  # Already our symlink to the same source? leave it.
  if (Test-Path -LiteralPath $Dest) {
    $item = Get-Item -LiteralPath $Dest -Force
    if ($item.LinkType -eq 'SymbolicLink' -and $item.Target) {
      $target = $item.Target
      if ($target -is [array]) { $target = $target[0] }  # PS 5.1 may give a string; 7+ a string[]
      $resolvedTarget = (Resolve-Path -LiteralPath $target -ErrorAction SilentlyContinue).Path
      if ($resolvedTarget -eq (Resolve-Path -LiteralPath $Src).Path) {
        Log "OK    $Label"
        return
      }
    }
  }

  Backup-IfExists -Dest $Dest

  if ($Symlink) {
    try {
      New-Item -ItemType SymbolicLink -Path $Dest -Target $Src -Force | Out-Null
      Log "LINK  $Label"
      return
    }
    catch {
      Log "NOTE  symlink failed for $Label (need Developer Mode/admin); copying instead."
    }
  }
  Copy-Item -LiteralPath $Src -Destination $Dest -Force
  Log "COPY  $Label"
}

function Link-Dotfiles {
  $map = @(
    @{ Src = (Join-Path $RepoDir '.gitconfig');                          Dest = (Join-Path $HomeDir '.gitconfig') },
    @{ Src = (Join-Path $RepoDir '.vimrc');                              Dest = (Join-Path $HomeDir '.vimrc') },
    @{ Src = (Join-Path $RepoDir '.honcho\config.json');                 Dest = (Join-Path $HomeDir '.honcho\config.json') },
    @{ Src = (Join-Path $RepoDir '.honcho\mcp\server.mjs');              Dest = (Join-Path $HomeDir '.honcho\mcp\server.mjs') },
    @{ Src = (Join-Path $RepoDir '.honcho\mcp\package.json');            Dest = (Join-Path $HomeDir '.honcho\mcp\package.json') },
    @{ Src = (Join-Path $ScriptDir 'node-launcher.cmd');                 Dest = (Join-Path $HomeDir '.honcho\mcp\node-launcher.cmd') },
    @{ Src = (Join-Path $ScriptDir 'honcho-prewarm-cursor.ps1');         Dest = (Join-Path $HomeDir '.local\bin\honcho-prewarm-cursor.ps1') },
    @{ Src = (Join-Path $RepoDir '.cursor\rules\honcho-memory.mdc');     Dest = (Join-Path $HomeDir '.cursor\rules\honcho-memory.mdc') },
    @{ Src = (Join-Path $RepoDir '.cursor\rules\data-safety.mdc');       Dest = (Join-Path $HomeDir '.cursor\rules\data-safety.mdc') },
    @{ Src = (Join-Path $RepoDir '.cursor\settings.json');               Dest = (Join-Path $HomeDir '.cursor\settings.json') }
  )
  foreach ($entry in $map) {
    $label = $entry.Dest.Substring($HomeDir.Length).TrimStart('\')
    Install-Dotfile -Src $entry.Src -Dest $entry.Dest -Label $label
  }

  # Secrets template (PowerShell flavor), copied once.
  $exportsDest = Join-Path $HomeDir '.exports.ps1'
  $exportsSrc  = Join-Path $ScriptDir 'exports.example.ps1'
  if ((-not (Test-Path -LiteralPath $exportsDest)) -and (Test-Path -LiteralPath $exportsSrc)) {
    Copy-Item -LiteralPath $exportsSrc -Destination $exportsDest -Force
    Log "COPY  .exports.ps1 (from template - fill in secrets)"
  }
}

# Inject a marker-delimited block into the all-hosts PowerShell profile so every
# session gets the Honcho env + the shared helpers. Parity with install.sh's
# ensure_zsh_aliases. Idempotent: only appended when the begin-marker is absent.
function Ensure-PowerShellProfile {
  $profilePath = $PROFILE.CurrentUserAllHosts
  $profileDir  = Split-Path -Parent $profilePath
  if (-not (Test-Path -LiteralPath $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }

  $begin = '# >>> dotfiles (managed by install.ps1) >>>'
  $end   = '# <<< dotfiles (managed by install.ps1) <<<'
  $profileScript = Join-Path $ScriptDir 'profile.ps1'

  if ((Test-Path -LiteralPath $profilePath) -and (Select-String -LiteralPath $profilePath -SimpleMatch $begin -Quiet)) {
    Log "OK    PowerShell profile loads profile.ps1 (managed block present)"
    return
  }

  $block = @"
$begin
# PowerShell parity with the Linux/WSL .bashrc: Honcho env + shared helpers
# (honcho-up/down/status/lan/tunnel, hermes-*, ai-* service controls).
`$env:HONCHO_API_KEY = 'local'
`$env:HONCHO_PEER_NAME = 'skyler'
`$__dotfilesProfile = '$profileScript'
if (Test-Path `$__dotfilesProfile) { . `$__dotfilesProfile }
`$__dotfilesExports = Join-Path `$HOME '.exports.ps1'
if (Test-Path `$__dotfilesExports) { . `$__dotfilesExports }
$end
"@

  $existing = ''
  if (Test-Path -LiteralPath $profilePath) { $existing = Get-Content -Raw -LiteralPath $profilePath }
  if ($existing -and -not $existing.EndsWith("`n")) { $existing += "`r`n" }
  if ($existing) { $existing += "`r`n" }
  Write-Utf8NoBom -Path $profilePath -Text ($existing + $block + "`r`n")
  Log "GEN   PowerShell profile managed block -> $profilePath"
}

# ── Honcho MCP bridge + Cursor integration ──────────────────────────
function Install-McpBridgeDeps {
  $mcpDir = Join-Path $HomeDir '.honcho\mcp'
  if (-not (Test-Path (Join-Path $mcpDir 'package.json'))) { Die "$mcpDir\package.json missing (dotfile copy failed?)" }
  if (-not (Have npm)) { Die "npm not found; cannot install the Honcho MCP bridge deps." }
  Log "Installing Honcho MCP bridge dependencies..."
  Push-Location $mcpDir
  try {
    if ((Invoke-Native -Exe 'npm' -Arguments @('install', '--silent')) -ne 0) { Die "npm install failed in $mcpDir" }
  }
  finally { Pop-Location }
  Log "OK    .honcho\mcp\node_modules"
}

function Install-CursorHoncho {
  if (-not (Have bun)) { Die "bun not found; cursor-honcho needs it." }
  if (Test-Path (Join-Path $CursorHonchoDir '.git')) {
    Log "OK    cursor-honcho (updating)"
    $null = Invoke-Native -Exe 'git' -Arguments @('-C', $CursorHonchoDir, 'pull', '--quiet')
  }
  else {
    Log "INST  cursor-honcho -> $CursorHonchoDir"
    $parent = Split-Path -Parent $CursorHonchoDir
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if ((Invoke-Native -Exe 'git' -Arguments @('clone', '--quiet', '--depth', '1', $CursorHonchoRepo, $CursorHonchoDir)) -ne 0) {
      Die "cursor-honcho clone failed (network?)"
    }
  }
  if (-not (Test-Path $PluginRoot)) { Die "cursor-honcho layout unexpected: missing $PluginRoot" }
  Push-Location $PluginRoot
  try {
    if ((Invoke-Native -Exe 'bun' -Arguments @('install', '--silent')) -ne 0) { Die "bun install failed for cursor-honcho" }
  }
  finally { Pop-Location }
  Log "OK    cursor-honcho deps"
}

function Patch-CursorHoncho {
  if (-not (Test-Path $CursorHonchoPatch)) { Die "missing patcher: $CursorHonchoPatch" }
  if (-not (Test-Path $PluginRoot)) { Die "cursor-honcho plugin not installed" }
  if ((Invoke-Python -Python $script:Python -Arguments @($CursorHonchoPatch, $PluginRoot)) -ne 0) {
    Die "cursor-honcho patch failed"
  }
  Log "OK    cursor-honcho local fixes"
}

function Write-CursorMcpJson {
  $dest = Join-Path $HomeDir '.cursor\mcp.json'
  $launcher = Join-Path $HomeDir '.honcho\mcp\node-launcher.cmd'
  $server   = Join-Path $HomeDir '.honcho\mcp\server.mjs'
  $cursorDir = Split-Path -Parent $dest
  if (-not (Test-Path $cursorDir)) { New-Item -ItemType Directory -Force -Path $cursorDir | Out-Null }

  if (Test-Path -LiteralPath $dest) {
    try { $data = Get-Content -Raw -LiteralPath $dest | ConvertFrom-Json }
    catch { $data = [pscustomobject]@{} }
  }
  else { $data = [pscustomobject]@{} }
  if ($null -eq $data.mcpServers) { $data | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) -Force }

  # command=cmd so Cursor can spawn the .cmd launcher reliably on Windows; the
  # launcher resolves Node at spawn time (parity with the POSIX node-nvm entry).
  $honcho = [pscustomobject][ordered]@{
    command = 'cmd'
    args    = @('/c', $launcher, '--preserve-symlinks-main', $server)
    env     = [pscustomobject][ordered]@{
      HONCHO_API_KEY  = 'local'
      HONCHO_HUMAN_PEER = 'skyler'
    }
  }
  $data.mcpServers | Add-Member -NotePropertyName honcho -NotePropertyValue $honcho -Force

  Write-Utf8NoBom -Path $dest -Text (($data | ConvertTo-Json -Depth 10) + "`n")
  Log "GEN   .cursor\mcp.json"
}

function Write-CursorHooksJson {
  $dest = Join-Path $HomeDir '.cursor\hooks.json'
  $hooksDir = Join-Path $PluginRoot 'hooks'
  $prewarm  = Join-Path $HomeDir '.local\bin\honcho-prewarm-cursor.ps1'
  if (-not (Have bun)) { Die "bun not found (required for Cursor hooks)" }
  if (-not (Test-Path $hooksDir)) { Die "cursor-honcho hooks dir missing: $hooksDir" }
  $bunPath = (Get-Command bun).Source
  $cursorDir = Split-Path -Parent $dest
  if (-not (Test-Path $cursorDir)) { New-Item -ItemType Directory -Force -Path $cursorDir | Out-Null }

  # JSON-encode each command string so backslashes/quotes are escaped correctly.
  function J([string]$s) { return ($s | ConvertTo-Json) }
  function HookCmd([string]$ts) { return ('"{0}" run "{1}"' -f $bunPath, (Join-Path $hooksDir $ts)) }
  $prewarmCmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $prewarm

  $json = @"
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      { "command": $(J $prewarmCmd) },
      { "command": $(J (HookCmd 'session-start.ts')) }
    ],
    "sessionEnd": [
      { "command": $(J (HookCmd 'session-end.ts')) }
    ],
    "beforeSubmitPrompt": [
      { "command": $(J (HookCmd 'before-submit-prompt.ts')) }
    ],
    "postToolUse": [
      {
        "command": $(J (HookCmd 'post-tool-use.ts')),
        "matcher": "Write|Edit|Shell|Task|MCP"
      }
    ],
    "preCompact": [
      { "command": $(J (HookCmd 'pre-compact.ts')) }
    ],
    "stop": [
      { "command": $(J (HookCmd 'stop.ts')) }
    ],
    "subagentStop": [
      { "command": $(J (HookCmd 'subagent-stop.ts')) }
    ],
    "afterAgentThought": [
      { "command": $(J (HookCmd 'after-agent-thought.ts')) }
    ],
    "afterAgentResponse": [
      { "command": $(J (HookCmd 'after-agent-response.ts')) }
    ]
  }
}
"@
  Write-Utf8NoBom -Path $dest -Text ($json + "`n")
  Log "GEN   .cursor\hooks.json"
}

function Disable-CursorGitAttribution {
  if (-not (Test-Path $AttributionScript)) { Die "missing $AttributionScript" }
  if ((Invoke-Python -Python $script:Python -Arguments @($AttributionScript)) -ne 0) {
    Die "cursor attribution script failed"
  }
}

# ── Honcho server ───────────────────────────────────────────────────
function Test-HonchoHttp {
  param([string]$BaseUrl)
  try {
    $resp = Invoke-WebRequest -Uri "$BaseUrl/docs" -TimeoutSec 4 -UseBasicParsing
    return ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400)
  }
  catch { return $false }
}

function Get-HonchoTunnelProcess {
  $needle = "-L $HonchoPort`:localhost:$HonchoPort"
  Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$needle*" }
}

function Ensure-HonchoTunnel {
  if (Test-HonchoHttp -BaseUrl $LanUrl) {
    Log "OK    honcho reachable on LAN ($LanUrl)"
    return
  }
  if (Get-HonchoTunnelProcess) {
    if (Test-HonchoHttp -BaseUrl $LoopbackUrl) {
      Log "OK    honcho reachable via existing SSH tunnel ($LoopbackUrl)"
      return
    }
    Die "An SSH tunnel for port $HonchoPort is running but $LoopbackUrl is not answering. Honcho is probably down on $TunnelHost - start it (ai-support-on), or kill the stale tunnel (honcho-down), then re-run."
  }
  if (-not (Have ssh)) { Die "ssh not found - required to tunnel Honcho from $TunnelUser@$TunnelHost" }

  Log "TUN   honcho not on LAN - opening SSH tunnel to $TunnelUser@$TunnelHost (-L $HonchoPort`:localhost:$HonchoPort)"
  $sshArgs = @(
    '-N',
    '-o', 'ConnectTimeout=10',
    '-o', 'ServerAliveInterval=60',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-L', "$HonchoPort`:localhost:$HonchoPort",
    "$TunnelUser@$TunnelHost"
  )
  Start-Process -FilePath 'ssh' -ArgumentList $sshArgs -WindowStyle Hidden | Out-Null

  for ($i = 0; $i -lt 10; $i++) {
    Start-Sleep -Seconds 1
    if (Test-HonchoHttp -BaseUrl $LoopbackUrl) {
      Log "OK    honcho reachable via SSH tunnel ($LoopbackUrl)"
      return
    }
  }
  Die "SSH tunnel to $TunnelHost is up but $LoopbackUrl never answered. Is Honcho running there? Start it with 'ai-support-on', then re-run."
}

function Resolve-HonchoEndpoint {
  $config = Join-Path $HomeDir '.honcho\config.json'
  if (-not (Test-Path $config)) { Die "Honcho config missing: $config" }
  $data = Get-Content -Raw -LiteralPath $config | ConvertFrom-Json
  $urls = @()
  if ($data.endpoint.candidates) { $urls += $data.endpoint.candidates }
  if ($data.endpoint.baseUrl) { $urls += $data.endpoint.baseUrl }
  # Prefer loopback first, then de-dupe preserving order.
  $loop = @(); $rest = @()
  foreach ($u in $urls) {
    if ($u -match 'localhost|127\.0\.0\.1|\[::1\]') { $loop += $u } else { $rest += $u }
  }
  $ordered = @(); foreach ($u in ($loop + $rest)) { if ($ordered -notcontains $u) { $ordered += $u } }
  foreach ($u in $ordered) {
    if (Test-HonchoHttp -BaseUrl $u) { return $u }
  }
  return $null
}

function Bootstrap-HonchoServer {
  $config = Join-Path $HomeDir '.honcho\config.json'
  $endpoint = Resolve-HonchoEndpoint
  if (-not $endpoint) {
    Die "Honcho server not reachable. Start it on the LAN (orphic-lens) or via SSH ($TunnelUser@$TunnelHost, 'ai-support-on'), then re-run."
  }
  $apiBase = "$endpoint/v3/workspaces"
  $data = Get-Content -Raw -LiteralPath $config | ConvertFrom-Json

  $peer = $data.peerName
  $sessions = @()
  if ($data.sessions) {
    foreach ($prop in $data.sessions.PSObject.Properties) {
      if ($sessions -notcontains $prop.Value) { $sessions += $prop.Value }
    }
  }
  if (-not $sessions) { $sessions = @('') }

  function Honcho-Post {
    param([string]$Url, [string]$Id)
    if (-not $Id) { return }
    try {
      Invoke-RestMethod -Uri $Url -Method Post -Body (@{ id = $Id } | ConvertTo-Json) `
        -ContentType 'application/json' -TimeoutSec 3 -UseBasicParsing | Out-Null
    }
    catch { }  # already-exists / transient: idempotent, ignore
  }

  if ($data.hosts) {
    foreach ($prop in $data.hosts.PSObject.Properties) {
      $name = $prop.Name
      $block = $prop.Value
      if ($block.workspace) { $ws = $block.workspace } else { $ws = $name }
      $ai = $block.aiPeer
      Honcho-Post -Url $apiBase -Id $ws
      Honcho-Post -Url "$apiBase/$ws/peers" -Id $peer
      Honcho-Post -Url "$apiBase/$ws/peers" -Id $ai
      foreach ($s in $sessions) { Honcho-Post -Url "$apiBase/$ws/sessions" -Id $s }
      Log "OK    honcho $ws (peer: $peer, ai: $ai)"
    }
  }
}

# Best-effort MCP smoke test: spawn the bridge exactly like Cursor will, send a
# minimal initialize + tools/list handshake, and confirm a tools result comes
# back. Returns $true on success.
function Test-HonchoMcp {
  $dest = Join-Path $HomeDir '.cursor\mcp.json'
  if (-not (Test-Path $dest)) { return $false }
  $cfg = Get-Content -Raw -LiteralPath $dest | ConvertFrom-Json
  $server = $cfg.mcpServers.honcho
  if (-not $server) { return $false }

  $payload = (@(
    (@{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'dotfiles-install'; version = '0' } } } | ConvertTo-Json -Depth 6 -Compress),
    (@{ jsonrpc = '2.0'; method = 'notifications/initialized'; params = @{} } | ConvertTo-Json -Depth 4 -Compress),
    (@{ jsonrpc = '2.0'; id = 2; method = 'tools/list'; params = @{} } | ConvertTo-Json -Depth 4 -Compress)
  ) -join "`n") + "`n"

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $server.command
  # .NET Framework (Windows PowerShell 5.1) has no ProcessStartInfo.ArgumentList,
  # so build a single Arguments string, quoting any token containing whitespace.
  $psi.Arguments = (@($server.args) | ForEach-Object {
      if ($_ -match '\s') { '"' + $_ + '"' } else { [string]$_ }
    }) -join ' '
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  if ($server.env) {
    foreach ($p in $server.env.PSObject.Properties) { $psi.EnvironmentVariables[$p.Name] = [string]$p.Value }
  }

  $proc = $null
  $sawTools = $false
  try {
    $proc = [System.Diagnostics.Process]::Start($psi)
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $handler = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -MessageData $queue -Action {
      if ($EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
    }
    $proc.BeginOutputReadLine()
    $proc.StandardInput.Write($payload)
    $proc.StandardInput.Close()

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 15) {
      $line = $null
      while ($queue.TryDequeue([ref]$line)) {
        if ($line -match '"tools"') { $sawTools = $true; break }
      }
      if ($sawTools -or $proc.HasExited) { break }
      Start-Sleep -Milliseconds 200
    }
  }
  catch { return $false }
  finally {
    if ($handler) { Unregister-Event -SourceIdentifier $handler.Name -ErrorAction SilentlyContinue }
    if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch { } }
  }
  return $sawTools
}

# ── run ─────────────────────────────────────────────────────────────
Log "Platform: windows (PowerShell $($PSVersionTable.PSVersion))"

Log ""
Log "-- Dependencies --"
Ensure-CoreTools
Ensure-PyYaml
Ensure-Node
Install-Bun

Log ""
Log "-- Dotfiles --"
Link-Dotfiles
Ensure-PowerShellProfile

if (-not $SkipCursorHoncho) {
  Log ""
  Log "-- Honcho MCP bridge + Cursor integration --"
  if ((Have node) -and (Have npm)) { Install-McpBridgeDeps } else { Log "SKIP  MCP bridge deps (node/npm missing)" }
  if (Have bun) {
    Install-CursorHoncho
    Patch-CursorHoncho
  }
  else { Log "SKIP  cursor-honcho (bun missing)" }
  Write-CursorMcpJson
  if (Have bun) { Write-CursorHooksJson } else { Log "SKIP  hooks.json (bun missing)" }
  Disable-CursorGitAttribution
}

Log ""
Log "-- Hermes --"
Log "SKIP  Hermes is POSIX-only; the hermes-* helpers still work against a tunneled *nix Hermes."

if (-not $SkipHonchoServer) {
  Log ""
  Log "-- Honcho server --"
  if (Have node) {
    Ensure-HonchoTunnel
    if (Test-HonchoMcp) { Log "OK    Honcho MCP bridge smoke test" }
    else { Die "Honcho MCP smoke test failed - the bridge could not list tools. Confirm Honcho is up (LAN orphic-lens:$HonchoPort or the SSH tunnel), then re-run." }
    Bootstrap-HonchoServer
  }
  else { Log "SKIP  Honcho server phase (node missing; install Node and re-run)" }
}

Log ""
Log "Done. Review any .bak files and remove once verified."
Log "Open a new PowerShell window (or run . `$PROFILE) and restart Cursor to pick up MCP + hooks."
