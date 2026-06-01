import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { readFileSync } from "fs";
import { join } from "path";
import { z } from "zod";

const API_KEY = process.env.HONCHO_API_KEY || "local";

// HOME is unset on Windows; fall back to USERPROFILE so the same server.mjs
// works under PowerShell/cmd as well as POSIX shells.
const HOME = process.env.HOME || process.env.USERPROFILE || "";

function loadConfig() {
  try {
    return JSON.parse(readFileSync(
      join(HOME, ".honcho", "config.json"), "utf8"));
  } catch {
    return {};
  }
}

const cfg = loadConfig();

const WORKSPACE = process.env.HONCHO_WORKSPACE
  || cfg.hosts?.cursor?.workspace || "cursor";
const AI_PEER = process.env.HONCHO_AI_PEER
  || cfg.hosts?.cursor?.aiPeer || "cursor";
const HUMAN_PEER = process.env.HONCHO_HUMAN_PEER
  || cfg.peerName || "skyler";

const RESOLVE_TIMEOUT_MS = 1_000;
const DEFAULT_TIMEOUT_MS = 30_000;
const INFERENCE_TIMEOUT_MS = 300_000;
const TOOL_RACE_MS = Number(process.env.HONCHO_TOOL_RACE_MS || "30000");
const INFERENCE_RACE_MS = Number(process.env.HONCHO_INFERENCE_RACE_MS || "120000");

const TRANSIENT_CODES = new Set(
  ["ECONNREFUSED", "EHOSTUNREACH", "ENETUNREACH", "ENOTFOUND", "EAI_AGAIN"]);

// Endpoint resolution: try ordered candidates from config.json; cache
// the winner; drop the cache on any connection-class failure so the
// next call re-probes. This is the *only* mechanism — no env-var
// alias, no file watcher, no periodic timer. The candidates list is
// re-read from disk on every resolution so config edits land without
// a process restart.
function candidates() {
  const c = loadConfig();
  const list = c?.endpoint?.candidates
    ?? (c?.endpoint?.baseUrl ? [c.endpoint.baseUrl] : []);
  const ordered = list.length ? [...list] : ["http://localhost:8100"];
  return ordered.sort(function _preferLoopback(a, b) {
    const isLoopback = function _isLoopback(url) {
      try {
        return ["localhost", "127.0.0.1", "::1"].includes(new URL(url).hostname);
      } catch {
        return false;
      }
    };
    return Number(isLoopback(b)) - Number(isLoopback(a));
  });
}

let endpoint = null;
let resolving = null;

function resolveEndpoint() {
  if (resolving) return resolving;
  resolving = (async function _resolve() {
    for (const url of candidates()) {
      try {
        const res = await fetch(`${url}/docs`,
          { signal: AbortSignal.timeout(RESOLVE_TIMEOUT_MS) });
        if (res.ok) return (endpoint = url);
      } catch {}
    }
    return (endpoint = null);
  })().finally(function _clear() { resolving = null; });
  return resolving;
}

function raceNull(promise, ms) {
  return Promise.race([
    promise,
    new Promise(function _timeout(r) { setTimeout(() => r(null), ms); }),
  ]);
}

async function api(method, path, body, timeoutMs = DEFAULT_TIMEOUT_MS) {
  const url = endpoint ?? await resolveEndpoint();
  if (!url) {
    throw new Error(
      `Honcho unreachable. Tried: ${candidates().join(", ")}`);
  }
  const opts = {
    method,
    headers: {
      Authorization: `Bearer ${API_KEY}`,
      "Content-Type": "application/json",
    },
    signal: AbortSignal.timeout(timeoutMs),
  };
  if (body !== undefined) opts.body = JSON.stringify(body);
  try {
    const res = await fetch(`${url}${path}`, opts);
    const text = await res.text();
    if (!res.ok) {
      throw new Error(`Honcho ${method} ${path} → ${res.status}: ${text}`);
    }
    return text ? JSON.parse(text) : null;
  } catch (err) {
    if (TRANSIENT_CODES.has(err.cause?.code)
        || err.name === "TimeoutError") {
      endpoint = null;
    }
    throw err;
  }
}

let workspaceReady = false;
async function ensureWorkspaceAndPeers() {
  if (workspaceReady) return;
  await api("POST", "/v3/workspaces", { id: WORKSPACE });
  await api("POST", `/v3/workspaces/${WORKSPACE}/peers`, { id: AI_PEER });
  await api("POST", `/v3/workspaces/${WORKSPACE}/peers`, { id: HUMAN_PEER });
  workspaceReady = true;
}

// Wraps a tool handler so it races against a timeout and never blocks
// the agent indefinitely. If the backend is slow (cold model) or down,
// the agent gets a message back fast and can keep working. Endpoint
// reachability is handled inside api(); this wrapper just bounds time
// and turns thrown errors into MCP error responses.
function resilient(fn, raceMs, label) {
  return async function _wrapped(args) {
    try {
      const resultP = fn(args);
      const result = await raceNull(resultP, raceMs);
      if (result === null) {
        resultP.catch(function _swallow() {});
        return {
          content: [{
            type: "text",
            text: `${label}: timed out after ${raceMs / 1000}s `
              + `(backend may be warming up). Retry shortly.`,
          }],
        };
      }
      return result;
    } catch (err) {
      return {
        content: [{ type: "text", text: `${label} error: ${err.message}` }],
        isError: true,
      };
    }
  };
}

const server = new McpServer({
  name: "honcho",
  version: "1.0.0",
});

server.tool(
  "create_conclusion",
  "Save a conclusion/memory about the current conversation. The AI (observer) records what it learned about the human (observed).",
  { content: z.string().describe("The conclusion text to save") },
  resilient(async ({ content }) => {
    await ensureWorkspaceAndPeers();
    const result = await api("POST", `/v3/workspaces/${WORKSPACE}/conclusions`, {
      conclusions: [{ content, observer_id: AI_PEER, observed_id: HUMAN_PEER }],
    });
    return { content: [{ type: "text", text: JSON.stringify(result ?? { saved: true }, null, 2) }] };
  }, TOOL_RACE_MS, "create_conclusion")
);

server.tool(
  "query_conclusions",
  "Semantic search across all saved conclusions/memories.",
  {
    query: z.string().describe("Natural language search query"),
    top_k: z.number().min(1).max(50).default(10).describe("Number of results").optional(),
  },
  resilient(async ({ query, top_k }) => {
    const result = await api("POST", `/v3/workspaces/${WORKSPACE}/conclusions/query`, {
      query,
      top_k: top_k ?? 10,
      filters: { observer_id: AI_PEER, observed_id: HUMAN_PEER },
    });
    return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
  }, TOOL_RACE_MS, "query_conclusions")
);

server.tool(
  "list_conclusions",
  "List recent conclusions/memories with optional filters.",
  {
    page: z.number().min(1).default(1).optional(),
    size: z.number().min(1).max(100).default(20).optional(),
  },
  resilient(async ({ page, size }) => {
    const params = new URLSearchParams();
    if (page) params.set("page", page);
    if (size) params.set("size", size);
    const qs = params.toString();
    const result = await api(
      "POST",
      `/v3/workspaces/${WORKSPACE}/conclusions/list${qs ? `?${qs}` : ""}`,
      null
    );
    return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
  }, TOOL_RACE_MS, "list_conclusions")
);

server.tool(
  "delete_conclusion",
  "Delete a specific conclusion by ID.",
  { conclusion_id: z.string().describe("The conclusion ID to delete") },
  resilient(async ({ conclusion_id }) => {
    await api("DELETE", `/v3/workspaces/${WORKSPACE}/conclusions/${conclusion_id}`);
    return { content: [{ type: "text", text: `Deleted conclusion ${conclusion_id}` }] };
  }, TOOL_RACE_MS, "delete_conclusion")
);

server.tool(
  "chat",
  "Have a dialectic chat with Honcho about a peer to get insights.",
  {
    query: z.string().describe("Question or prompt for the dialectic chat"),
    peer_id: z.string().default(HUMAN_PEER).describe("Peer to chat about").optional(),
  },
  resilient(async ({ query, peer_id }) => {
    const pid = peer_id || HUMAN_PEER;
    const result = await api("POST", `/v3/workspaces/${WORKSPACE}/peers/${pid}/chat`, {
      query,
    }, INFERENCE_TIMEOUT_MS);
    return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
  }, INFERENCE_RACE_MS, "chat")
);

server.tool(
  "get_context",
  "Get the current context summary for a peer.",
  {
    peer_id: z.string().default(HUMAN_PEER).describe("Peer ID to get context for").optional(),
  },
  resilient(async ({ peer_id }) => {
    const pid = peer_id || HUMAN_PEER;
    const result = await api("GET", `/v3/workspaces/${WORKSPACE}/peers/${pid}/context`);
    return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
  }, TOOL_RACE_MS, "get_context")
);

server.tool(
  "get_representation",
  "Get the computed representation/profile of a peer.",
  {
    peer_id: z.string().default(HUMAN_PEER).describe("Peer ID").optional(),
  },
  resilient(async ({ peer_id }) => {
    const pid = peer_id || HUMAN_PEER;
    const result = await api("POST", `/v3/workspaces/${WORKSPACE}/peers/${pid}/representation`, {}, INFERENCE_TIMEOUT_MS);
    return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
  }, INFERENCE_RACE_MS, "get_representation")
);

server.tool(
  "search_workspace",
  "Search across all workspace data (conclusions, messages, etc.).",
  { query: z.string().describe("Search query") },
  resilient(async ({ query }) => {
    const result = await api("POST", `/v3/workspaces/${WORKSPACE}/search`, { query });
    return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
  }, TOOL_RACE_MS, "search_workspace")
);

server.tool(
  "inspect_workspace",
  "Get workspace info including peer list and queue status.",
  {},
  resilient(async () => {
    const [peers, queue] = await Promise.all([
      api("POST", `/v3/workspaces/${WORKSPACE}/peers/list`, null),
      api("GET", `/v3/workspaces/${WORKSPACE}/queue/status`).catch(() => null),
    ]);
    return {
      content: [{
        type: "text",
        text: JSON.stringify({ workspace: WORKSPACE, peers, queue }, null, 2),
      }],
    };
  }, TOOL_RACE_MS, "inspect_workspace")
);

// Non-blocking warmup — populates the workspace/peers and warms
// the Ollama model. Failures are silent; the resilient() wrapper
// on each tool handles them gracefully at call time.
(async () => {
  try {
    await ensureWorkspaceAndPeers();
    await api(
      "POST",
      `/v3/workspaces/${WORKSPACE}/peers/${HUMAN_PEER}/representation`,
      {},
      INFERENCE_TIMEOUT_MS
    );
  } catch {}
})();

const transport = new StdioServerTransport();
await server.connect(transport);
