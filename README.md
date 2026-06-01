# dotfiles

Skyler Forge's configuration for Linux workstations
(Pop!_OS / Ubuntu-based, bash + oh-my-bash).

## Install

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

## Secrets

`.exports` is gitignored.  Copy `.exports.example` to `~/.exports`
and fill in values on each machine.  The `.vimrc` API key slot is
commented out — set it via environment or a local override.

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

### Generated at install time (not in repo)

| Path | Purpose |
|------|---------|
| `~/.cursor/mcp.json` | Cursor MCP server config (absolute paths) |
| `~/.cursor/hooks.json` | Cursor lifecycle hooks (absolute paths) |
