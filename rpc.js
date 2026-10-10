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

  // Send one JSON-RPC payload (object or array) with failover. Returns parsed JSON.
  async function send(payload) {
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
          const j = await postFor(ENDPOINTS[i], payload, body);
          state[i].fails = 0; state[i].ok++; preferred = i;
          setStatus(i === 0 ? "ok" : "degraded");
          return j;
        } catch (e) {
          lastErr = e;
          if (e.skip) continue; // this endpoint can't do this request; it stays healthy for others
          state[i].fails++;
          state[i].until = Date.now() + Math.min(60000, COOLDOWN_MS * 2 ** Math.min(5, state[i].fails - 1));
        }
      }
      await new Promise((r) => setTimeout(r, 800 * (round + 1)));
    }
    setStatus("down");
    throw Object.assign(new Error("All Arc RPC endpoints failed: " + (lastErr && lastErr.message)), { code: "SERVER_ERROR" });
  }

  let _provider = null;
  function provider() {
    if (_provider) return _provider;
    class FailoverProvider extends ethers.JsonRpcProvider {
      constructor() { super(ENDPOINTS[0].url, 5042, { staticNetwork: ethers.Network.from(5042), batchMaxCount: 1 }); }
      async _send(payload) { const j = await send(payload); return Array.isArray(j) ? j : [j]; }
    }
    _provider = new FailoverProvider();
    return _provider;
  }

  window.SaviorRPC = {
    endpoints: ENDPOINTS.map((e) => e.url), provider, send,
    status: () => status, onStatus: (f) => listeners.push(f),
    health: () => ENDPOINTS.map((e, i) => ({ url: e.url, ok: state[i].ok, fails: state[i].fails, coolingDown: state[i].until > Date.now() })),
  };
})();

// Number and date formatting: always en-US so separators read "60,000" regardless of browser locale.
window.SAVIOR_LOCALE = "en-US";
