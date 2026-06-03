# AGENTS.md

## Cursor Cloud specific instructions

This is a **dotfiles repository** — it configures a development workstation with an AI-augmented workflow (Honcho persistent memory, cursor-honcho plugin, Hermes CLI agent). There is no traditional application to build/deploy.

### Key services

| Component | What it does | How to test locally |
|-----------|--------------|---------------------|
| **Honcho MCP bridge** (`.honcho/mcp/server.mjs`) | Node.js MCP server that bridges Cursor ↔ Honcho backend | `echo '<JSON-RPC init + tools/list>' \| node --preserve-symlinks-main ~/.honcho/mcp/server.mjs` |
| **cursor-honcho plugin** (`~/.honcho/plugins/cursor-honcho/`) | Bun-based Cursor hooks (session-start, before-submit-prompt, etc.) | Installed by `install.sh`; patched by `scripts/patch_cursor_honcho.py` |
| **install.sh** | Dotfiles installer — symlinks, deps, patches, config generation | `bash install.sh` (idempotent) |

### Running the MCP bridge smoke test

The install script already runs a smoke test. You can also run it manually:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | \
  HONCHO_API_KEY=local HONCHO_HUMAN_PEER=skyler \
  timeout 10 node --preserve-symlinks-main ~/.honcho/mcp/server.mjs
```

A successful response returns JSON-RPC with 9 tools listed.

### Linting

- **Bash scripts**: `bash -n <script>` for syntax check (no shellcheck in base image)
- **Python scripts**: `python3 -c "import ast; ast.parse(open('<script>').read())"` or run `python3 <script>` with appropriate args
- **Node/MCP bridge**: `node --check ~/.honcho/mcp/server.mjs` for syntax; smoke test above for full validation

### Gotchas

- The Honcho backend (`orphic-lens:8100`) is **not reachable** from Cloud Agent VMs. The MCP bridge starts fine and gracefully handles unreachable backends (returns error messages per-tool-call rather than crashing).
- `install.sh` requires `node`, `npm`, `bun`, and `python3` to be available. Node ≥ 18 required for MCP SDK. Bun is needed for cursor-honcho hooks.
- The install script is fully idempotent — safe to re-run.
- npm dependencies live in `.honcho/mcp/` (the MCP bridge). The cursor-honcho plugin uses `bun install` separately.
- No `.cursor/environment.json` exists in this repo.
