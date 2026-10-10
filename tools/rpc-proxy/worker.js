// $SAVIOR read-only RPC proxy for Arc Mainnet (Cloudflare Worker). PROPOSAL, NOT DEPLOYED.
// - Only read methods are forwarded (no eth_sendRawTransaction: wallets send transactions themselves).
// - Responses are cached at the edge by method + params, so many visitors share one upstream request.
// - Upstreams are tried in order; on 429/5xx/network errors the next one is used.
// - CORS is limited to the site's origins.
// No secrets: all upstreams are public endpoints. If a keyed RPC is added later, store its URL as a Worker secret.

const UPSTREAMS = [
  "https://rpc.mainnet.arc.io",
  "https://arc-rpc.publicnode.com",
  "https://5042.rpc.thirdweb.com",
  "https://arc-mainnet.drpc.org",
];
const ALLOWED_ORIGINS = [
  "https://cengovski.github.io",
  "https://savior-cengovski.vercel.app",
  /^https:\/\/savior-[a-z0-9-]+-cengovski\.vercel\.app$/, // Vercel previews
  /^http:\/\/localhost(:\d+)?$/,
];
// Seconds to cache each method at the edge. Not listed = not allowed.
const TTL = {
  eth_chainId: 86400, net_version: 86400,
  eth_blockNumber: 1,
  eth_call: 2,               // "latest" reads (pool state, locks); block-pinned calls get the long TTL below
  eth_getBalance: 2,
  eth_getLogs: 5,            // ranges ending at a fixed block are immutable: long TTL below
  eth_getTransactionByHash: 3600, eth_getTransactionReceipt: 3600, // immutable once found
  eth_getBlockByNumber: 2, eth_getCode: 3600, eth_estimateGas: 0, eth_gasPrice: 2, eth_feeHistory: 2,
  eth_maxPriorityFeePerGas: 2,
};
const IMMUTABLE_TTL = 86400;
const MAX_BATCH = 20;

function corsHeaders(origin) {
  const ok = ALLOWED_ORIGINS.some((o) => (typeof o === "string" ? o === origin : o.test(origin)));
  return ok ? { "Access-Control-Allow-Origin": origin, "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "content-type", "Access-Control-Max-Age": "86400", Vary: "Origin" } : null;
}

function ttlFor(req) {
  const t = TTL[req.method];
  if (t === undefined) return -1; // method not allowed
  const p = req.params || [];
  if (req.method === "eth_getLogs" && p[0] && /^0x/.test(p[0].toBlock || "")) return IMMUTABLE_TTL;
  if (req.method === "eth_call" && /^0x/.test(p[1] || "")) return IMMUTABLE_TTL;
  if ((req.method === "eth_getTransactionReceipt" || req.method === "eth_getTransactionByHash")) return t; // null results are not cached (see below)
  return t;
}

async function upstream(body) {
  let last;
  for (const url of UPSTREAMS) {
    try {
      const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body });
      if (r.status === 429 || r.status >= 500) { last = new Error("HTTP " + r.status); continue; }
      const j = await r.json();
      const errs = (Array.isArray(j) ? j : [j]).map((x) => x && x.error && x.error.message).filter(Boolean).join(" ");
      if (/rate|limit|archive|personal token|free plan|response size/i.test(errs)) { last = new Error(errs); continue; }
      return j;
    } catch (e) { last = e; }
  }
  throw last || new Error("no upstream");
}

async function handleOne(req, ctx) {
  const ttl = ttlFor(req);
  if (ttl < 0) return { jsonrpc: "2.0", id: req.id ?? null, error: { code: -32601, message: "Method not allowed on this proxy" } };
  const key = new Request("https://rpc-cache.internal/" + encodeURIComponent(JSON.stringify([req.method, req.params || []])));
  const cache = caches.default;
  if (ttl > 0) {
    const hit = await cache.match(key);
    if (hit) { const v = await hit.json(); return { jsonrpc: "2.0", id: req.id, result: v }; }
  }
  const j = await upstream(JSON.stringify({ jsonrpc: "2.0", id: 1, method: req.method, params: req.params || [] }));
  if (ttl > 0 && j && !j.error && j.result !== null && j.result !== undefined) {
    ctx.waitUntil(cache.put(key, new Response(JSON.stringify(j.result), { headers: { "Cache-Control": "max-age=" + ttl } })));
  }
  return { ...j, id: req.id };
}

export default {
  async fetch(request, env, ctx) {
    const origin = request.headers.get("Origin") || "";
    const cors = corsHeaders(origin);
    if (request.method === "OPTIONS") return new Response(null, { status: cors ? 204 : 403, headers: cors || {} });
    if (request.method !== "POST") return new Response("POST JSON-RPC only", { status: 405 });
    if (!cors) return new Response("Origin not allowed", { status: 403 });
    let body;
    try { body = await request.json(); } catch (e) { return new Response("Bad JSON", { status: 400, headers: cors }); }
    const list = Array.isArray(body) ? body : [body];
    if (list.length > MAX_BATCH) return new Response("Batch too large", { status: 413, headers: cors });
    let out;
    try { out = await Promise.all(list.map((r) => handleOne(r, ctx))); }
    catch (e) { return new Response(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32603, message: "All upstreams failed" } }), { status: 502, headers: { ...cors, "content-type": "application/json" } }); }
    return new Response(JSON.stringify(Array.isArray(body) ? out : out[0]), { headers: { ...cors, "content-type": "application/json" } });
  },
};
