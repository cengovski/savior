// rpc.js: one shared read-only Arc provider with automatic failover across public RPCs.
// Each endpoint was checked to return chainId 5042 and to send CORS headers for the site's origins.
// On HTTP 429, 5xx, timeouts, network/CORS errors or rate-limit JSON errors the endpoint is put on a
// short cooldown and the request moves to the next one. Endpoints that reject 2000-block eth_getLogs
// ranges are only used for other methods.
(function () {
  const ENDPOINTS = [
    { url: "https://rpc.mainnet.arc.io", logs: true },      // official Arc
    { url: "https://arc-rpc.publicnode.com", logs: true },  // Allnodes PublicNode: recent-block logs only (older ranges are skipped)
    { url: "https://arc-mainnet.drpc.org", logs: false },   // dRPC free tier: rejects our getLogs ranges
    { url: "https://5042.rpc.thirdweb.com", logs: true, logsMax: 1000 }, // thirdweb: archive logs, max 1000 blocks per request
  ];
  const TIMEOUT_MS = 10000, COOLDOWN_MS = 3000; // 429: 3s, doubling per consecutive failure, max 60s
  const state = ENDPOINTS.map(() => ({ until: 0, fails: 0, ok: 0 }));
  let preferred = 0;
  const listeners = [];
  let status = "ok"; // ok | degraded | down
  function setStatus(s) { if (s !== status) { status = s; listeners.forEach((f) => { try { f(s); } catch (e) {} }); } }

  // Endpoint can't serve this particular request (archive range, plan limits): try the next one, no cooldown.
  const isUnsupported = (j) => j && j.error && /archive|personal token|free plan|not supported|response size|exceed|range/i.test(j.error.message || "");
  const isRateLimit = (j) => j && j.error && (j.error.code === -32005 || j.error.code === 429 || /rate|limit exceeded|too many/i.test(j.error.message || ""));

  async function post(url, body) {
    const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), TIMEOUT_MS);
    try {
      const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body, signal: ctl.signal });
      if (r.status === 429 || r.status >= 500) throw Object.assign(new Error("HTTP " + r.status), { retry: true });
      const j = await r.json().catch(() => { throw Object.assign(new Error("HTTP " + r.status + " (not JSON)"), { retry: true }); });
      if (Array.isArray(j) ? j.some(isUnsupported) : isUnsupported(j)) throw Object.assign(new Error((j.error && j.error.message) || "unsupported"), { skip: true });
      if (Array.isArray(j) ? j.some(isRateLimit) : isRateLimit(j)) throw Object.assign(new Error("rate limited"), { retry: true });
      return j;
    } catch (e) { if (e.retry === undefined) e.retry = true; throw e; } // network, CORS, TLS, abort: try the next endpoint
    finally { clearTimeout(t); }
  }

  // eth_getLogs wider than an endpoint's limit is split into sub-ranges and merged.
  async function postFor(ep, payload, body) {
    const q = !Array.isArray(payload) && payload.method === "eth_getLogs" && payload.params && payload.params[0];
    if (!ep.logsMax || !q || typeof q.fromBlock !== "string" || !q.fromBlock.startsWith("0x") || !String(q.toBlock).startsWith("0x")) return post(ep.url, body);
    const from = parseInt(q.fromBlock, 16), to = parseInt(q.toBlock, 16);
    if (to - from + 1 <= ep.logsMax) return post(ep.url, body);
    let all = [];
    for (let a = from; a <= to; a += ep.logsMax) {
      const b = Math.min(to, a + ep.logsMax - 1);
      const sub = { ...payload, params: [{ ...q, fromBlock: "0x" + a.toString(16), toBlock: "0x" + b.toString(16) }] };
      const j = await post(ep.url, JSON.stringify(sub));
      if (j.error) return j;
      all = all.concat(j.result || []);
    }
    return { jsonrpc: "2.0", id: payload.id, result: all };
  }

  // ---------- global request budget: token bucket (one token per HTTP request, a batch counts once) ----------
  const BUCKET_MAX = 8, REFILL_PER_S = 3;
  let tokens = BUCKET_MAX, lastRefill = Date.now();
  async function takeToken() {
    for (;;) {
      const now = Date.now();
      tokens = Math.min(BUCKET_MAX, tokens + ((now - lastRefill) / 1000) * REFILL_PER_S); lastRefill = now;
      if (tokens >= 1) { tokens -= 1; return; }
      await new Promise((r) => setTimeout(r, Math.ceil(((1 - tokens) / REFILL_PER_S) * 1000)));
    }
  }
  const jitter = (ms) => Math.round(ms * (0.75 + Math.random() * 0.5));

  // ---------- short read cache shared across tabs (localStorage + BroadcastChannel) ----------
  // Only head-dependent reads at "latest": eth_blockNumber (2s) and eth_call (4s). Logs and receipts are not cached here.
  const TTL = { eth_blockNumber: 2000, eth_call: 4000 };
  const mem = new Map();
  let bc = null; try { bc = new BroadcastChannel("savior-rpc"); bc.onmessage = (e) => { if (e.data && e.data.k) mem.set(e.data.k, e.data.v); }; } catch (e) {}
  const LOGS_TTL = 600000;
  function cacheKey(p) {
    if (Array.isArray(p)) return null;
    if (p.method === "eth_getLogs") { const q = p.params && p.params[0]; return q && /^0x/.test(q.toBlock || "") ? "logs:" + JSON.stringify(q) : null; }
    if (!TTL[p.method]) return null;
    if (p.method === "eth_call" && p.params[1] && p.params[1] !== "latest") return null;
    return p.method + ":" + JSON.stringify(p.params);
  }
  function cacheGet(k, method) {
    if (method === "eth_getLogs") { const v = mem.get(k); return v && Date.now() - v.t < LOGS_TTL ? v.r : undefined; }
    let v = mem.get(k);
    if (!v) { try { v = JSON.parse(localStorage.getItem("savior.rpc." + k) || "null"); } catch (e) {} }
    return v && Date.now() - v.t < TTL[method] ? v.r : undefined;
  }
  function cachePut(k, r) {
    const v = { t: Date.now(), r }; mem.set(k, v);
    if (k.startsWith("logs:")) return; // logs stay in this tab's memory only
    try { localStorage.setItem("savior.rpc." + k, JSON.stringify(v)); } catch (e) {}
    try { bc && bc.postMessage({ k, v }); } catch (e) {}
  }
  // prune old cache entries once per load
  try { for (let i = localStorage.length - 1; i >= 0; i--) { const k = localStorage.key(i); if (k && k.startsWith("savior.rpc.")) { const v = JSON.parse(localStorage.getItem(k)); if (!v || Date.now() - v.t > 60000) localStorage.removeItem(k); } } } catch (e) {}
  const inflight = new Map();
  window.__rpcStats = { http: 0, cached: 0, deduped: 0 };

  async function send(payload) {
    const k = cacheKey(payload);
    if (k) {
      const hit = cacheGet(k, payload.method);
      if (hit !== undefined) { window.__rpcStats.cached++; return { jsonrpc: "2.0", id: payload.id, result: hit }; }
      if (inflight.has(k)) { window.__rpcStats.deduped++; const j = await inflight.get(k); return { ...j, id: payload.id }; }
      const pr = sendNet(payload).then((j) => { if (j && j.result !== undefined && !j.error) cachePut(k, j.result); return j; });
      inflight.set(k, pr);
      try { return await pr; } finally { inflight.delete(k); }
    }
    return sendNet(payload);
  }

  // Send one JSON-RPC payload (object or array) with failover. Returns parsed JSON.
  async function sendNet(payload) {
    const methods = (Array.isArray(payload) ? payload : [payload]).map((p) => p.method);
    const needsLogs = methods.includes("eth_getLogs");
    const body = JSON.stringify(payload);
    let lastErr = null;
    for (let round = 0; round < 2; round++) {
      const now = Date.now();
      const order = ENDPOINTS.map((_, i) => (preferred + i) % ENDPOINTS.length)
        .filter((i) => !needsLogs || ENDPOINTS[i].logs)
        .sort((a, b) => (state[a].until > now) - (state[b].until > now)); // healthy endpoints first
      for (const i of order) {
        if (state[i].until > Date.now() && round === 0) continue;
        try {
          await takeToken(); window.__rpcStats.http++;
          const j = await postFor(ENDPOINTS[i], payload, body);
          state[i].fails = 0; state[i].ok++; preferred = i;
          setStatus(i === 0 ? "ok" : "degraded");
          return j;
        } catch (e) {
          lastErr = e;
          if (e.skip) continue; // this endpoint can't do this request; it stays healthy for others
          state[i].fails++;
          state[i].until = Date.now() + jitter(Math.min(60000, COOLDOWN_MS * 2 ** Math.min(5, state[i].fails - 1)));
        }
      }
      await new Promise((r) => setTimeout(r, jitter(800 * 2 ** round)));
    }
    setStatus("down");
    throw Object.assign(new Error("All Arc RPC endpoints failed: " + (lastErr && lastErr.message)), { code: "SERVER_ERROR" });
  }

  let _provider = null;
  function provider() {
    if (_provider) return _provider;
    class FailoverProvider extends ethers.JsonRpcProvider {
      constructor() { super(ENDPOINTS[0].url, 5042, { staticNetwork: ethers.Network.from(5042), batchMaxCount: 20, batchStallTime: 25 }); }
      async _send(payload) {
        const list = Array.isArray(payload) ? payload : [payload];
        if (list.length === 1) { const j = await send(list[0]); return [j]; }
        // batch: answer cached parts locally, send the remainder as one JSON-RPC batch (getLogs go alone)
        const out = [], rest = [];
        for (const p of list) {
          const k = cacheKey(p), hit = k && cacheGet(k, p.method);
          if (k && hit !== undefined) { window.__rpcStats.cached++; out.push({ jsonrpc: "2.0", id: p.id, result: hit }); }
          else if (p.method === "eth_getLogs" && !(p.params && p.params[0] && p.params[0].toBlock === "latest")) out.push(await send(p));
          else rest.push(p);
        }
        if (rest.length === 1) out.push(await send(rest[0]));
        else if (rest.length) {
          const res = await sendNet(rest);
          for (const r of (Array.isArray(res) ? res : [res])) {
            out.push(r);
            const p = rest.find((x) => x.id === r.id), k = p && cacheKey(p);
            if (k && r.result !== undefined && !r.error) cachePut(k, r.result);
          }
        }
        return out;
      }
    }
    _provider = new FailoverProvider();
    return _provider;
  }

  window.SaviorRPC = {
    endpoints: ENDPOINTS.map((e) => e.url), provider, send,
    status: () => status, stats: () => window.__rpcStats, onStatus: (f) => listeners.push(f),
    health: () => ENDPOINTS.map((e, i) => ({ url: e.url, ok: state[i].ok, fails: state[i].fails, coolingDown: state[i].until > Date.now() })),
  };
})();

// Number and date formatting: always en-US so separators read "60,000" regardless of browser locale.
window.SAVIOR_LOCALE = "en-US";
