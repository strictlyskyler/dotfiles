# dotfiles

Skyler Forge's workstation configuration. Primary target is Linux
(Pop!_OS / Ubuntu-based, bash + oh-my-bash), with macOS (zsh), WSL, and
Windows (PowerShell) supported. POSIX systems use `install.sh`; Windows uses
`windows/install.ps1` (see [Install (Windows / PowerShell)](#install-windows--powershell)).

## Install (macOS / Linux / WSL)

```bash
git clone git@github.com:StrictlySkyler/dotfiles.git ~/src/dotfiles
cd ~/src/dotfiles
./install.sh
```

The script:

1. Symlinks each dotfile into `$HOME` (existing files backed up as `*.bak`).
   On macOS (zsh), it also injects a small managed block into `~/.zshrc` so
   interactive shells source `~/.aliases` and export the Honcho env — giving
   the `honcho-*`, `hermes-*`, and `ai-*` helpers parity with the Linux/WSL
   `.bashrc`.
2. Installs **bun** if missing.
3. Clones/updates [cursor-honcho](https://github.com/plastic-labs/cursor-honcho)
   to `~/.honcho/plugins/cursor-honcho`, runs `bun install`, and applies
   local compatibility patches.
4. Generates `~/.cursor/mcp.json` and `~/.cursor/hooks.json` with
   absolute paths, a 5 minute MCP timeout, a symlink-safe Honcho MCP
   launch command, and a detached Honcho warmup hook for this machine.
5. Ensures `orphic-lens` resolves (adds `/etc/hosts` entry if needed;
   may prompt for `sudo`).
6. **Ensures Honcho is reachable** — if it doesn't answer on the LAN
   (`orphic-lens:8100`), opens a detached SSH tunnel to
   `skyler@ssh.skyler.is` forwarding `localhost:8100`, so off-LAN
   machines reach the same server before the steps below run. The
   tunnel outlives the installer; tear it down later with `honcho-down`.
7. Patches an existing `~/.hermes/config.yaml` for the orphic-lens model:
   `Qwen_Qwen3-14B-Q4_K_M.gguf`, 65,536 token context, and matching
   Ollama `num_ctx`. It also reapplies local Hermes source patches after
   `hermes setup` or `hermes update`.
8. **Bootstraps the Honcho server** — creates workspaces, peers, and
   sessions for every host in `.honcho/config.json`. Idempotent and
   safe to re-run. Skips gracefully if the server is unreachable.

After running, restart Cursor.

The installer opens this tunnel automatically when Honcho isn't on the
LAN (step 6 above), so a fresh off-LAN machine works after `./install.sh`
with no manual step — provided SSH access to `skyler@ssh.skyler.is` is set
up (key-based auth recommended). Override the target with the
`HONCHO_TUNNEL_USER` / `HONCHO_TUNNEL_HOST` env vars.

In later shells, `honcho-up` opens the same tunnel and points the Honcho
config at `http://localhost:8100`; `honcho-down` / `honcho-lan` switch back
to the LAN endpoint. (`honcho-status` shows the current tunnel + endpoint.)

For Hermes away from the LAN, run `hermes-up`. It opens the LLM tunnel on
`localhost:11434`, ensures the Honcho tunnel is up, and switches Hermes'
LLM/Honcho endpoints to loopback. Run `hermes-down` or `hermes-lan` when
back on the LAN.

## Install (Windows / PowerShell)

Windows runs PowerShell instead of bash, so it has its own installer under
`windows/`. From an ordinary (non-admin) **Windows PowerShell 5.1+** prompt:

```powershell
git clone https://github.com/StrictlySkyler/dotfiles.git $HOME\source\dotfiles
cd $HOME\source\dotfiles
# one-time, only if your execution policy blocks local scripts:
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
.\windows\install.ps1
```

`windows/install.ps1` mirrors `install.sh` for Windows:

1. Installs the dependencies it can — Node LTS + npm and Python via `winget`,
   and bun via its official installer (all needed by the MCP bridge, the
   cursor-honcho hooks, and the patchers).
2. Copies the dotfiles into `%USERPROFILE%` (existing files backed up as
   `*.bak`). Pass `-Symlink` to symlink instead — that needs Developer Mode or
   an elevated shell, so copy is the default.
3. Adds a managed block to your all-hosts `$PROFILE` that sets the Honcho env
   and dot-sources `windows/profile.ps1`, giving the `honcho-*`, `hermes-*`, and
   `ai-*` helpers parity with the Linux/WSL `.bashrc`.
4. Installs the Honcho MCP bridge deps, clones/patches `cursor-honcho`, and
   writes `~/.cursor/mcp.json` + `~/.cursor/hooks.json` with Windows-native
   commands: a `cmd /c node-launcher.cmd` MCP launch that resolves Node at spawn
   time (the Windows analogue of `node-nvm`), plus `bun` / PowerShell hook
   commands. All JSON is written UTF-8 **without a BOM** so Node can parse it.
5. Disables Cursor git attribution and bootstraps the Honcho server, opening an
   SSH tunnel to `ssh.skyler.is` when Honcho isn't on the LAN — same behavior as
   the POSIX installer.

Hermes is skipped on Windows (its installer is a POSIX `curl | bash` script),
but the `hermes-*` helpers still work against a tunneled *nix Hermes.

Useful switches: `-SkipNode`, `-SkipBun`, `-SkipCursorHoncho`,
`-SkipHonchoServer`. After it finishes, open a new PowerShell window (or run
`. $PROFILE`) and restart Cursor.

## Secrets

`.exports` is gitignored.  Copy `.exports.example` to `~/.exports`
and fill in values on each machine.  The `.vimrc` API key slot is
commented out — set it via environment or a local override.

On Windows, copy `windows/exports.example.ps1` to `$HOME\.exports.ps1` (the
installer does this automatically) and set values as `$env:NAME = "..."`. It is
gitignored too.

## What's included

| Path | Purpose |
|------|---------|
| `.bashrc` | oh-my-bash, completions, PATH, nvm/fvm/bun, Honcho env vars |
| `.bash_profile` | login shell bootstrap |
| `.profile` | system profile (Debian default + ~/bin) |
| `.aliases` | shortcuts: sudo, vim, AI service control |
| `.exports.example` | template for secret env vars |
| `.vimrc` | vim-plug, NERDTree, solarized, 2-space tabs |
| `.gitconfig` | user identity, kdiff3 diff/merge |
| `.cursor/rules/` | Cursor IDE agent rules |
| `.cursor/settings.json` | Cursor/agent settings (MCP timeout, etc.) |
| `.honcho/config.json` | Honcho memory config (self-hosted at orphic-lens) |
| `.local/bin/honcho-prewarm-cursor.sh` | Detached session-start warmup for Honcho dialectic chat |
| `scripts/patch_cursor_honcho.py` | Applies local fixes to the upstream cursor-honcho clone |
| `scripts/patch_hermes_config.py` | Applies durable Hermes model/context defaults after `hermes setup` |
| `scripts/patch_hermes_agent_sources.py` | Reapplies local Hermes source patches after `hermes update` |
| `windows/install.ps1` | Windows/PowerShell installer (mirrors `install.sh`) |
| `windows/profile.ps1` | PowerShell parity for `.bashrc` + `.aliases` (`honcho-*`, `hermes-*`, `ai-*`, terminal title) |
| `windows/node-launcher.cmd` | Resolves Node at spawn time for the MCP server (Windows `node-nvm`) |
| `windows/honcho-prewarm-cursor.ps1` | Detached Honcho warmup for Cursor `sessionStart` (Windows port) |
| `windows/exports.example.ps1` | PowerShell secrets template (copied to `$HOME\.exports.ps1`) |

### Generated at install time (not in repo)

| Path | Purpose |
|------|---------|
| `~/.cursor/mcp.json` | Cursor MCP server config (absolute paths) |
| `~/.cursor/hooks.json` | Cursor lifecycle hooks (absolute paths) |
