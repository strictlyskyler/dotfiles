#!/usr/bin/env bash
#
# Dotfiles installer for macOS, Linux, and WSL.
#
# This installs everything it needs (Homebrew/apt packages, PyYAML, Node/npm,
# bun, Hermes, cursor-honcho), symlinks the dotfiles, wires up Cursor's MCP +
# hooks, patches Hermes, and bootstraps the Honcho memory server.
#
# Steps are NOT best-effort: a real failure aborts the install with a clear
# error (so nothing breaks silently). Re-running is safe and idempotent.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── logging / helpers ───────────────────────────────────────────────
log()  { printf '%s\n' "$*"; }
die()  { printf 'ERROR  %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Detect platform: macos | linux | wsl
platform() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)
      if [[ -f /proc/version ]] && grep -qi microsoft /proc/version; then
        echo wsl
      else
        echo linux
      fi
      ;;
    *) echo linux ;;
  esac
}
PLATFORM="$(platform)"

# sudo prefix (empty when root or when sudo is unavailable)
SUDO=""
if [[ "$(id -u)" -ne 0 ]] && have sudo; then
  SUDO="sudo"
fi

# Portable readlink -f (macOS lacks GNU readlink)
realpath_() {
  if have realpath; then
    realpath "$1"
  elif have python3; then
    python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1"
  else
    readlink -f "$1"
  fi
}

CURSOR_HONCHO_DIR="$HOME/.honcho/plugins/cursor-honcho"
PLUGIN_ROOT="$CURSOR_HONCHO_DIR/plugins/honcho"
CURSOR_HONCHO_REPO="https://github.com/plastic-labs/cursor-honcho.git"
CURSOR_HONCHO_PATCHER="$DOTFILES_DIR/scripts/patch_cursor_honcho.py"
HERMES_PATCHER="$DOTFILES_DIR/scripts/patch_hermes_config.py"
HERMES_SOURCE_PATCHER="$DOTFILES_DIR/scripts/patch_hermes_agent_sources.py"
HERMES_INSTALLER_URL="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"

# ── package management ──────────────────────────────────────────────
ensure_homebrew() {
  have brew && return 0
  log "INST  Homebrew"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || die "Homebrew install failed"
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
  have brew || die "Homebrew installed but not on PATH"
}

# Install OS packages by their platform-appropriate names.
pkg_install() {
  case "$PLATFORM" in
    macos)
      ensure_homebrew
      brew install "$@" || die "brew install failed: $*"
      ;;
    *)
      have apt-get || die "apt-get not found. Install these manually: $*"
      $SUDO apt-get update -y >/dev/null 2>&1 || true
      $SUDO apt-get install -y "$@" || die "apt-get install failed: $*"
      ;;
  esac
}

ensure_core_tools() {
  have git     || pkg_install git
  have curl    || pkg_install curl
  have python3 || pkg_install python3
  if ! python3 -m pip --version >/dev/null 2>&1; then
    case "$PLATFORM" in
      macos) python3 -m ensurepip --upgrade >/dev/null 2>&1 || true ;;
      *)     pkg_install python3-pip ;;
    esac
  fi
  log "OK    core tools (git, curl, python3)"
}

# PyYAML is required by the Hermes patcher and by the hermes-* shell aliases.
ensure_pyyaml() {
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    log "OK    PyYAML"
    return 0
  fi
  log "INST  PyYAML"
  # Debian/Ubuntu ship it as a system package; tolerate failure here (apt-get
  # directly, not pkg_install, which would die) and fall back to pip — covers
  # macOS and PEP-668 "externally managed" Pythons.
  if [[ "$PLATFORM" != macos ]] && have apt-get; then
    $SUDO apt-get install -y python3-yaml >/dev/null 2>&1 || true
  fi
  if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -m pip install --user pyyaml >/dev/null 2>&1 \
      || python3 -m pip install --user --break-system-packages pyyaml >/dev/null 2>&1 \
      || true
  fi
  python3 -c 'import yaml' >/dev/null 2>&1 \
    || die "PyYAML install failed — try manually: python3 -m pip install pyyaml"
  log "OK    PyYAML"
}

ensure_node() {
  if have node && have npm; then
    log "OK    node $(node --version) / npm $(npm --version)"
    return 0
  fi
  log "INST  node + npm"
  case "$PLATFORM" in
    macos) pkg_install node ;;
    *)     pkg_install nodejs npm ;;
  esac
  have node || die "node install failed"
  have npm  || die "npm install failed"
  log "OK    node $(node --version) / npm $(npm --version)"
}

install_bun() {
  # If bun is already installed, just ensure it's on PATH and return. Checking
  # ~/.bun/bin/bun (not only `have bun`) avoids re-running the official installer
  # in non-login shells where bun isn't yet on PATH; each re-run re-appends a
  # "# bun" block to the (symlinked) shell profiles.
  if have bun || [[ -x "$HOME/.bun/bin/bun" ]]; then
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    log "OK    bun $(bun --version)"
    return 0
  fi
  log "INST  bun"
  curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || die "bun install failed"
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
  have bun || die "bun installed but not on PATH"
  log "OK    bun $(bun --version)"
}

# ── dotfile symlinks ────────────────────────────────────────────────
link_dotfiles() {
  local targets=(
    .aliases
    .vimrc
    .gitconfig
    .local/bin/agent
    .local/bin/cursor-agent
    .local/bin/honcho-prewarm-cursor.sh
    .cursor/rules/honcho-memory.mdc
    .cursor/rules/data-safety.mdc
    .cursor/settings.json
    .honcho/config.json
    .honcho/mcp/server.mjs
    .honcho/mcp/package.json
    .honcho/mcp/node-nvm
  )
  # Shell init files only on Linux/WSL (macOS uses zsh; manage separately)
  if [[ "$PLATFORM" != macos ]]; then
    targets+=( .bashrc .bash_profile .profile )
  fi

  local target src dest existing
  for target in "${targets[@]}"; do
    src="$DOTFILES_DIR/$target"
    dest="$HOME/$target"
    [[ -f "$src" ]] || die "expected dotfile missing from repo: $target"

    mkdir -p "$(dirname "$dest")"

    if [[ -L "$dest" ]]; then
      existing="$(realpath_ "$dest" 2>/dev/null || true)"
      if [[ "$existing" == "$src" ]]; then
        log "OK    $target"
        continue
      fi
      rm "$dest"
    elif [[ -e "$dest" ]]; then
      mv "$dest" "$dest.bak"
      log "BAK   $target → $dest.bak"
    fi

    ln -s "$src" "$dest"
    case "$target" in .local/bin/*|.honcho/mcp/node-nvm) chmod +x "$src" ;; esac
    log "LINK  $target"
  done

  if [[ ! -f "$HOME/.exports" ]] && [[ -f "$DOTFILES_DIR/.exports.example" ]]; then
    cp "$DOTFILES_DIR/.exports.example" "$HOME/.exports"
    log "COPY  .exports (from template — fill in secrets)"
  fi
}

install_mcp_bridge_deps() {
  [[ -f "$HOME/.honcho/mcp/package.json" ]] \
    || die "~/.honcho/mcp/package.json missing (symlink step failed?)"
  log "Installing Honcho MCP bridge dependencies..."
  (cd "$HOME/.honcho/mcp" && npm install --silent) \
    || die "npm install failed in ~/.honcho/mcp"
  log "OK    .honcho/mcp/node_modules"
}

# ── cursor-honcho plugin (MCP server + hooks) ───────────────────────
install_cursor_honcho() {
  if [[ -d "$CURSOR_HONCHO_DIR/.git" ]]; then
    log "OK    cursor-honcho (updating)"
    git -C "$CURSOR_HONCHO_DIR" pull --quiet 2>/dev/null || true
  else
    log "INST  cursor-honcho → $CURSOR_HONCHO_DIR"
    mkdir -p "$(dirname "$CURSOR_HONCHO_DIR")"
    git clone --quiet --depth 1 "$CURSOR_HONCHO_REPO" "$CURSOR_HONCHO_DIR" \
      || die "cursor-honcho clone failed (network?)"
  fi
  [[ -d "$PLUGIN_ROOT" ]] || die "cursor-honcho layout unexpected: missing $PLUGIN_ROOT"
  (cd "$PLUGIN_ROOT" && bun install --silent 2>/dev/null) \
    || die "bun install failed for cursor-honcho"
  log "OK    cursor-honcho deps"
}

patch_cursor_honcho() {
  [[ -f "$CURSOR_HONCHO_PATCHER" ]] || die "missing patcher: $CURSOR_HONCHO_PATCHER"
  [[ -d "$PLUGIN_ROOT" ]] || die "cursor-honcho plugin not installed"
  python3 "$CURSOR_HONCHO_PATCHER" "$PLUGIN_ROOT" || die "cursor-honcho patch failed"
  log "OK    cursor-honcho local fixes"
}

write_cursor_mcp_json() {
  local dest="$HOME/.cursor/mcp.json"
  local server="$HOME/.honcho/mcp/server.mjs"
  local launcher="$HOME/.honcho/mcp/node-nvm"
  mkdir -p "$HOME/.cursor"

  # Merge: preserve any existing servers, then upsert honcho entry.
  # Base URL is resolved at runtime from config.json (kept current by the
  # honcho-up / honcho-down aliases).
  python3 - "$dest" "$server" "$launcher" <<'PY' || die "failed to write .cursor/mcp.json"
import json, sys
from pathlib import Path

dest, server, launcher = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
data = json.loads(dest.read_text()) if dest.exists() else {}
data.setdefault("mcpServers", {})["honcho"] = {
    # node-nvm resolves nvm's current default node at spawn time, so the entry
    # survives node upgrades (a pinned absolute path would dangle) and does not
    # depend on node being on the spawning process's PATH (the My Machines
    # worker runs with a minimal PATH that omits nvm).
    "command": launcher,
    # server.mjs is symlinked from the dotfiles repo, while node_modules is
    # installed under ~/.honcho/mcp. Keep Node's main-module lookup at the
    # symlink path so dependency resolution uses the installed dependencies.
    "args": ["--preserve-symlinks-main", server],
    "env": {
        "HONCHO_API_KEY": "local",
        "HONCHO_HUMAN_PEER": "skyler",
    },
}
dest.write_text(json.dumps(data, indent=2) + "\n")
PY
  log "GEN   .cursor/mcp.json"
}

smoke_test_honcho_mcp() {
  [[ -f "$HOME/.cursor/mcp.json" ]] || die "mcp.json missing before smoke test"
  if ! python3 - "$HOME/.cursor/mcp.json" <<'PY'
import json
import os
import select
import subprocess
import sys
import time
from pathlib import Path

dest = Path(sys.argv[1])
data = json.loads(dest.read_text())
server = data.get("mcpServers", {}).get("honcho")
if not server:
    print("FAIL  no honcho server in mcp.json", file=sys.stderr)
    raise SystemExit(1)

cmd = [server["command"], *server.get("args", [])]
env = os.environ.copy()
env.update(server.get("env", {}))
payload = "\n".join([
    json.dumps({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "dotfiles-install", "version": "0"},
        },
    }),
    json.dumps({
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
        "params": {},
    }),
    json.dumps({
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/list",
        "params": {},
    }),
    "",
])

try:
    proc = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
except FileNotFoundError as exc:
    print(f"FAIL  Honcho MCP smoke test could not start: {exc}", file=sys.stderr)
    raise SystemExit(1)

saw_tools = False
stdout_buffer = ""
failure = "failed"
try:
    assert proc.stdin is not None
    assert proc.stdout is not None
    proc.stdin.write(payload.encode())
    proc.stdin.close()

    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        remaining = max(0, deadline - time.monotonic())
        ready, _, _ = select.select([proc.stdout.fileno()], [], [], min(0.2, remaining))
        if ready:
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                break
            stdout_buffer += chunk.decode("utf-8", "replace")
            while "\n" in stdout_buffer:
                line, stdout_buffer = stdout_buffer.split("\n", 1)
                if not line:
                    continue
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue
                result = message.get("result", {})
                if message.get("id") == 2 and "tools" in result:
                    saw_tools = True
                    break
            if saw_tools:
                break

        if proc.poll() is not None:
            chunk = os.read(proc.stdout.fileno(), 65536)
            stdout_buffer += chunk.decode("utf-8", "replace")
            for line in stdout_buffer.splitlines():
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue
                result = message.get("result", {})
                if message.get("id") == 2 and "tools" in result:
                    saw_tools = True
                    break
            break

    if not saw_tools:
        if proc.poll() is None:
            failure = "timed out"
finally:
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

if not saw_tools:
    print(f"FAIL  Honcho MCP smoke test {failure}", file=sys.stderr)
    if proc.stderr:
        stderr = proc.stderr.read().decode("utf-8", "replace").strip()
        if stderr:
            print(stderr, file=sys.stderr)
    raise SystemExit(1)

print("OK    Honcho MCP bridge smoke test")
PY
  then
    die "Honcho MCP smoke test failed — the bridge could not list tools. Is the Honcho server reachable (LAN: orphic-lens:8100, or run 'honcho-up' for the tunnel)? Bring it up and re-run ./install.sh."
  fi
}

write_cursor_hooks_json() {
  local dest="$HOME/.cursor/hooks.json"
  local hooks_dir="$PLUGIN_ROOT/hooks"
  local bun_path prewarm_cmd
  bun_path="$(command -v bun || true)"
  prewarm_cmd="$HOME/.local/bin/honcho-prewarm-cursor.sh"
  [[ -n "$bun_path" ]] || die "bun not found (required for Cursor hooks)"
  [[ -d "$hooks_dir" ]] || die "cursor-honcho hooks dir missing: $hooks_dir"
  mkdir -p "$HOME/.cursor"

  cat > "$dest" <<EOF
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      { "command": "$prewarm_cmd" },
      { "command": "$bun_path run $hooks_dir/session-start.ts" }
    ],
    "sessionEnd": [
      { "command": "$bun_path run $hooks_dir/session-end.ts" }
    ],
    "beforeSubmitPrompt": [
      { "command": "$bun_path run $hooks_dir/before-submit-prompt.ts" }
    ],
    "postToolUse": [
      {
        "command": "$bun_path run $hooks_dir/post-tool-use.ts",
        "matcher": "Write|Edit|Shell|Task|MCP"
      }
    ],
    "preCompact": [
      { "command": "$bun_path run $hooks_dir/pre-compact.ts" }
    ],
    "stop": [
      { "command": "$bun_path run $hooks_dir/stop.ts" }
    ],
    "subagentStop": [
      { "command": "$bun_path run $hooks_dir/subagent-stop.ts" }
    ],
    "afterAgentThought": [
      { "command": "$bun_path run $hooks_dir/after-agent-thought.ts" }
    ],
    "afterAgentResponse": [
      { "command": "$bun_path run $hooks_dir/after-agent-response.ts" }
    ]
  }
}
EOF
  log "GEN   .cursor/hooks.json"
}

disable_cursor_git_attribution() {
  local script="$DOTFILES_DIR/scripts/disable_cursor_git_attribution.py"
  [[ -f "$script" ]] || die "missing $script"
  python3 "$script" || die "cursor attribution script failed"
}

# ── Hermes ──────────────────────────────────────────────────────────
install_hermes() {
  if have hermes || [[ -d "$HOME/.hermes/hermes-agent" ]]; then
    log "OK    hermes present"
  else
    log "INST  hermes (NousResearch official installer)"
    curl -fsSL "$HERMES_INSTALLER_URL" | bash || die "Hermes install failed"
    [[ -d "$HOME/.hermes/hermes-agent" ]] \
      || die "Hermes installer finished but ~/.hermes/hermes-agent is missing"
    log "OK    hermes installed"
  fi
  # Hermes symlinks its launcher into ~/.local/bin
  export PATH="$HOME/.local/bin:$PATH"
}

patch_hermes() {
  [[ -d "$HOME/.hermes" ]] || die "~/.hermes missing (Hermes not installed)"
  [[ -f "$HERMES_PATCHER" ]] || die "missing $HERMES_PATCHER"
  python3 "$HERMES_PATCHER" "$HOME/.hermes" || die "Hermes config patch failed"
  [[ -f "$HERMES_SOURCE_PATCHER" ]] || die "missing $HERMES_SOURCE_PATCHER"
  python3 "$HERMES_SOURCE_PATCHER" "$HOME/.hermes" || die "Hermes source patch failed"
}

# ── Honcho server ───────────────────────────────────────────────────
# POST {"id": "<id>"} to a Honcho API path. No-op on empty id; failures
# (including "already exists") are ignored so bootstrap stays idempotent.
honcho_post() {
  [[ -n "$2" ]] || return 0
  curl -sf --connect-timeout 1 --max-time 2 -X POST "$1" \
    -H "Content-Type: application/json" -d "{\"id\":\"$2\"}" >/dev/null 2>&1 || true
}

ensure_orphic_lens_dns() {
  # Check /etc/hosts first (works even when the tunnel/server is down)
  if grep -qsE '^[^#].*[[:space:]]orphic-lens' /etc/hosts; then
    log "OK    orphic-lens in /etc/hosts"
    return 0
  fi
  # Fall back to a live lookup (handles system DNS, mDNS, etc.)
  if have getent && getent hosts orphic-lens >/dev/null 2>&1; then
    log "OK    orphic-lens resolves"
    return 0
  fi
  if have dscacheutil && dscacheutil -q host -a name orphic-lens 2>/dev/null | grep -q ip_address; then
    log "OK    orphic-lens resolves"
    return 0
  fi

  # Not resolvable. Add the LAN entry. Use a password prompt only when there is
  # a TTY; otherwise try non-interactive sudo so we never hang on a prompt.
  local ip="192.168.50.227"
  local sudo_flags=""
  [[ -t 0 ]] || sudo_flags="-n"
  log "FIX   orphic-lens not resolvable — adding /etc/hosts entry (sudo)"
  if printf '%s\n' "$ip orphic-lens" | sudo $sudo_flags tee -a /etc/hosts >/dev/null 2>&1; then
    log "OK    orphic-lens → $ip"
  else
    # Off-LAN this is expected; the localhost tunnel (honcho-up) is the path,
    # and the bootstrap step below verifies real reachability and fails loudly
    # if neither the LAN host nor the tunnel is up.
    log "NOTE  could not add orphic-lens to /etc/hosts (no sudo here)."
    log "      LAN access: echo '$ip orphic-lens' | sudo tee -a /etc/hosts"
    log "      Off-LAN: run 'honcho-up' to tunnel localhost:8100."
  fi
  return 0
}

bootstrap_honcho_server() {
  local config="$HOME/.honcho/config.json"
  [[ -f "$config" ]] || die "Honcho config missing: $config"

  local endpoints
  endpoints=$(python3 -c "
import json
from urllib.parse import urlparse
c = json.load(open('$config')).get('endpoint', {})
seen = set()
urls = [url for url in c.get('candidates', []) + [c.get('baseUrl', '')] if url]
urls.sort(key=lambda url: 0 if urlparse(url).hostname in ('localhost', '127.0.0.1', '::1') else 1)
for url in urls:
    if url and url not in seen:
        seen.add(url)
        print(url)
") || die "could not parse endpoints from $config"

  [[ -n "$endpoints" ]] || die "no Honcho endpoint configured in $config"

  local endpoint=""
  local candidate
  while IFS= read -r candidate; do
    if curl -sf --connect-timeout 1 --max-time 2 "$candidate/docs" >/dev/null 2>&1; then
      endpoint="$candidate"
      break
    fi
  done <<< "$endpoints"

  if [[ -z "$endpoint" ]]; then
    die "Honcho server not reachable. Tried: $(echo "$endpoints" | paste -sd ', ' -). Start it (LAN: orphic-lens) or run 'honcho-up' for the tunnel, then re-run ./install.sh."
  fi

  local api="$endpoint/v3"
  local api_base="$api/workspaces"

  python3 -c "
import json, sys
c = json.load(open('$config'))
sessions = list(dict.fromkeys(c.get('sessions', {}).values()))
peer = c.get('peerName', '')
for name, block in c.get('hosts', {}).items():
    ws = block.get('workspace', name)
    ai = block.get('aiPeer', '')
    for s in sessions or ['']:
        print(f'{ws}\t{peer}\t{ai}\t{s}')
" | while IFS=$'\t' read -r workspace peer ai_peer session; do
    [[ -z "$workspace" ]] && continue
    honcho_post "$api_base" "$workspace"
    honcho_post "$api_base/$workspace/peers" "$peer"
    honcho_post "$api_base/$workspace/peers" "$ai_peer"
    honcho_post "$api_base/$workspace/sessions" "$session"
    log "OK    honcho $workspace (peer: $peer, ai: $ai_peer, session: ${session:-none})"
  done
}

# ── run ─────────────────────────────────────────────────────────────
log "Platform: $PLATFORM"

log ""
log "── Dependencies ──"
ensure_core_tools
ensure_pyyaml
ensure_node
install_bun

log ""
log "── Dotfiles ──"
link_dotfiles

log ""
log "── Honcho MCP bridge + Cursor integration ──"
install_mcp_bridge_deps
install_cursor_honcho
patch_cursor_honcho
write_cursor_mcp_json
write_cursor_hooks_json
disable_cursor_git_attribution

log ""
log "── Hermes ──"
install_hermes
patch_hermes

log ""
log "── Honcho server ──"
ensure_orphic_lens_dns
smoke_test_honcho_mcp
bootstrap_honcho_server

# ── ConEmu terminal settings (WSL only) ────────────────────────────
if [[ "$PLATFORM" == wsl ]] && [[ -f "$DOTFILES_DIR/scripts/configure_conemu.sh" ]]; then
  log ""
  log "── ConEmu (WSL) ──"
  bash "$DOTFILES_DIR/scripts/configure_conemu.sh"
fi

log ""
log "Done.  Review any .bak files and remove once verified."
log "Restart Cursor to pick up MCP + hooks."
