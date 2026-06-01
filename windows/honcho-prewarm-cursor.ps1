#requires -Version 5.1
<#
.SYNOPSIS
  Detached Honcho dialectic warmup for Cursor sessionStart (Windows port).

.DESCRIPTION
  Windows/PowerShell analogue of .local/bin/honcho-prewarm-cursor.sh. On a
  Cursor sessionStart hook this kicks a single, fire-and-forget dialectic chat
  so the local model is warm by the time the first real query lands. It is
  rate-limited per working directory by a stamp file (default 15 min TTL) and
  exits 0 quickly no matter what so it never blocks Cursor startup.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

try {
  $homeDir = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }

  $bun = $env:BUN_BIN
  if (-not $bun -or -not (Test-Path $bun)) {
    $bun = Join-Path $homeDir '.bun\bin\bun.exe'
  }
  if (-not (Test-Path $bun)) {
    $cmd = Get-Command bun -ErrorAction SilentlyContinue
    if ($cmd) { $bun = $cmd.Source } else { exit 0 }
  }

  $pluginRoot = $env:HONCHO_CURSOR_PLUGIN_ROOT
  if (-not $pluginRoot) {
    $pluginRoot = Join-Path $homeDir '.honcho\plugins\cursor-honcho\plugins\honcho'
  }
  $configPath = Join-Path $homeDir '.honcho\config.json'
  if (-not (Test-Path $pluginRoot) -or -not (Test-Path $configPath)) { exit 0 }

  $ttl = 900
  if ($env:HONCHO_PREWARM_TTL_SECONDS) { $ttl = [int]$env:HONCHO_PREWARM_TTL_SECONDS }

  $stampDir = Join-Path $homeDir '.honcho\prewarm'
  New-Item -ItemType Directory -Force -Path $stampDir | Out-Null

  $cwd = if ($env:CURSOR_PROJECT_DIR) { $env:CURSOR_PROJECT_DIR } else { (Get-Location).Path }

  $sha1 = [System.Security.Cryptography.SHA1]::Create()
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($cwd)
  $key = ([System.BitConverter]::ToString($sha1.ComputeHash($bytes)) -replace '-', '').ToLower()
  $stamp = Join-Path $stampDir "$key.stamp"

  if (Test-Path $stamp) {
    $age = (New-TimeSpan -Start (Get-Item $stamp).LastWriteTimeUtc -End ([DateTime]::UtcNow)).TotalSeconds
    if ($age -lt $ttl) { exit 0 }
  }
  New-Item -ItemType File -Force -Path $stamp | Out-Null

  $script = @'
import { Honcho } from "@honcho-ai/sdk";
import { loadConfig, getHonchoClientOptions, getSessionName } from "./src/config.ts";

const cwd = process.env.HONCHO_WARMUP_CWD;
const config = loadConfig();
if (!config || !cwd) process.exit(0);

const timeout = Number(process.env.HONCHO_TIMEOUT_MS || "90000");
const honcho = new Honcho({ ...getHonchoClientOptions(config), timeout });
const sessionName = getSessionName(cwd);

const run = async () => {
  const session = await honcho.session(sessionName);
  const peer = await honcho.peer(config.peerName);
  await peer.chat(
    "Summarize the user's current working style in one short sentence.",
    { session, reasoningLevel: "minimal" }
  );
};

run().catch(() => process.exit(0));
'@

  $env:HONCHO_WARMUP_CWD = $cwd
  if (-not $env:HONCHO_TIMEOUT_MS) { $env:HONCHO_TIMEOUT_MS = '90000' }

  # Detached, no window, fully fire-and-forget.
  Start-Process -FilePath $bun `
    -ArgumentList @('--cwd', $pluginRoot, '-e', $script) `
    -WindowStyle Hidden | Out-Null
}
catch { }

exit 0
