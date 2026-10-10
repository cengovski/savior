// locks.js: public Locks Leaderboard + shared lock lookups (read-only, no wallet).
// The staking contract emits no events, so lockers are discovered from SAVIOR Transfer logs:
// a buy moves SAVIOR from the PoolManager into the staking contract; the buyer is that tx's sender.
// Every RPC call goes through one throttled queue with exponential backoff (public Arc RPC returns 429s).
(function () {
  const C = window.SAVIOR_CONFIG;
  const TRANSFER = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
  const START_BLOCK = 25000000; // token deployed at block 25,000,469
  const CHUNK = 2000, MIN_GAP_MS = 300, LOCK_TTL_MS = 60000, CACHE_KEY = "savior.locks.v1";
  const lc = (a) => (a || "").toLowerCase();
  const STAKING = lc(C.contracts.staking), PM = lc(C.contracts.poolManager);
  let provider = null, staking = null;
  const P = () => provider || (provider = window.SaviorRPC.provider()); // failover across public Arc RPCs
  const S = () => staking || (staking = new ethers.Contract(C.contracts.staking,
    ["function getLocks(address) view returns ((uint128 amount,uint64 unlockAt)[])", "function globalUnlock() view returns (bool)"], P()));

  // ---------- throttled queue ----------
  let chain = Promise.resolve(), last = 0;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  function rpc(fn) {
    const run = async () => {
      for (let i = 0; ; i++) {
        const wait = last + MIN_GAP_MS - Date.now(); if (wait > 0) await sleep(wait);
        last = Date.now();
        try { return await fn(); }
        catch (e) {
          const msg = String(e && (e.shortMessage || e.message) || "");
          // the shared provider already fails over across endpoints; only retry a little on top
          if (i >= 2 || !/429|rate|limit|coalesce|timeout|network|fetch|endpoints failed/i.test(msg)) throw e;
          await sleep(Math.min(15000, 1000 * 2 ** i) + Math.random() * 300);
        }
      }
    };
    const p = chain.then(run, run); chain = p.catch(() => {}); return p;
  }

  // ---------- cache ----------
  let cache = { scanned: START_BLOCK - 1, wallets: {}, txFrom: {}, locks: {} };
  try { const c = JSON.parse(localStorage.getItem(CACHE_KEY) || "null"); if (c && c.wallets) cache = Object.assign(cache, c); } catch (e) {}
  const save = () => { try { localStorage.setItem(CACHE_KEY, JSON.stringify(cache)); } catch (e) {} };

  async function txFrom(hash) {
    if (cache.txFrom[hash]) return cache.txFrom[hash];
    const tx = await rpc(() => P().getTransaction(hash));
    return (cache.txFrom[hash] = lc(tx && tx.from));
  }
  async function getLocks(addr, force) {
    addr = lc(addr);
    const c = cache.locks[addr];
    if (!force && c && Date.now() - c.t < LOCK_TTL_MS) return c.l;
    const raw = await rpc(() => S().getLocks(addr));
    const l = raw.map((x, i) => ({ i, amount: x.amount.toString(), unlockAt: Number(x.unlockAt) }));
    cache.locks[addr] = { t: Date.now(), l }; save();
    return l;
  }

  // Multicall3 (deployed on Arc at the canonical address): globalUnlock + getLocks for many wallets in ONE eth_call.
  const MC3 = "0xcA11bde05977b3631167028862bE2a173976CA11";
  const stakingIface = new ethers.Interface(["function getLocks(address) view returns ((uint128 amount,uint64 unlockAt)[])", "function globalUnlock() view returns (bool)"]);
  let mc = null;
  const MC = () => mc || (mc = new ethers.Contract(MC3, ["function aggregate3((address target,bool allowFailure,bytes callData)[] calls) view returns ((bool success,bytes returnData)[])"], P()));
  async function getLocksMany(addrs) {
    const calls = [{ target: C.contracts.staking, allowFailure: true, callData: stakingIface.encodeFunctionData("globalUnlock", []) }]
      .concat(addrs.map((a) => ({ target: C.contracts.staking, allowFailure: true, callData: stakingIface.encodeFunctionData("getLocks", [a]) })));
    const res = await rpc(() => MC().aggregate3.staticCall(calls));
    if (res[0].success) globalUnlock = stakingIface.decodeFunctionResult("globalUnlock", res[0].returnData)[0];
    addrs.forEach((a, i) => {
      const r = res[i + 1]; if (!r.success) return;
      const raw = stakingIface.decodeFunctionResult("getLocks", r.returnData)[0];
      cache.locks[lc(a)] = { t: Date.now(), l: raw.map((x, j) => ({ i: j, amount: x.amount.toString(), unlockAt: Number(x.unlockAt) })) };
    });
    save();
  }

  // Incremental scan of SAVIOR transfers; registers buyers as lockers.
  // Pre-scanned snapshot shipped with the site (regenerated occasionally) so first visits only scan new blocks.
  async function loadSeed() {
    try {
      const r = await fetch(new URL("locks-seed.json", document.baseURI), { cache: "no-cache" });
      if (!r.ok) return;
      const seed = await r.json();
      if (seed.scanned > cache.scanned) {
        for (const [w, b] of Object.entries(seed.wallets || {})) cache.wallets[w] = Math.max(cache.wallets[w] || 0, b);
        cache.scanned = seed.scanned;
      }
      // seed lock snapshot: used only where we have nothing newer
      for (const [w, l] of Object.entries(seed.locks || {})) if (!cache.locks[w] || cache.locks[w].t < (seed.locksAt || 0)) cache.locks[w] = { t: seed.locksAt || 0, l };
      save();
    } catch (e) {}
  }

  let scanning = null;
  function scan(onProgress) {
    if (scanning) return scanning;
    scanning = (async () => {
      const head = await rpc(() => P().getBlockNumber());
      for (let from = cache.scanned + 1; from <= head; from += CHUNK) {
        const to = Math.min(head, from + CHUNK - 1);
        const logs = await rpc(() => P().getLogs({ address: C.contracts.token, topics: [TRANSFER], fromBlock: from, toBlock: to }));
        for (const l of logs) {
          const f = lc("0x" + l.topics[1].slice(26)), t = lc("0x" + l.topics[2].slice(26));
          if (t === STAKING && f === PM) { const w = await txFrom(l.transactionHash); if (w) cache.wallets[w] = Math.max(cache.wallets[w] || 0, l.blockNumber); }
        }
        cache.scanned = to; save();
        onProgress && onProgress((to - START_BLOCK) / Math.max(1, head - START_BLOCK));
      }
    })().finally(() => { scanning = null; });
    return scanning;
  }

  // ---------- UI ----------
  const $ = (id) => document.getElementById(id);
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const fmt = (v) => Number(ethers.formatUnits(BigInt(v), C.tokenDecimals)).toLocaleString("en-US", { maximumFractionDigits: 0 });
  const short = (a) => a.slice(0, 6) + "..." + a.slice(-4);
  function countdown(ts) {
    let s = ts - Math.floor(Date.now() / 1000);
    if (s <= 0) return "Unlocked";
    const d = Math.floor(s / 86400); s %= 86400; const h = Math.floor(s / 3600); s %= 3600; const m = Math.floor(s / 60);
    return (d ? d + "d " : "") + h + "h " + m + "m";
  }
  const dateStr = (ts) => new Date(ts * 1000).toLocaleString("en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
  let rows = [], globalUnlock = false;

  function render() {
    const body = $("lb-body"); if (!body) return;
    const now = Math.floor(Date.now() / 1000), soon = now + 86400;
    let total = 0n, soonAmt = 0n, holders = 0, nLocks = 0;
    for (const r of rows) { total += r.total; holders++; nLocks += r.count; soonAmt += r.soonAmt; }
    $("lb-total").textContent = fmt(total) + " SAVIOR";
    $("lb-holders").textContent = holders + (holders === 1 ? " wallet, " : " wallets, ") + nLocks + (nLocks === 1 ? " lock" : " locks");
    $("lb-soon").textContent = fmt(soonAmt) + " SAVIOR";
    body.replaceChildren();
    if (!rows.length) { body.appendChild(el("div", "lb-empty", "No active locks found yet.")); return; }
    rows.forEach((r, idx) => {
      const isSoon = r.next && r.next <= soon && r.next > now;
      const row = el("div", "tr lb-row" + (isSoon ? " lb-soon" : ""));
      row.appendChild(el("span", "lb-rank", "#" + (idx + 1)));
      const a = el("a", "lb-addr", short(r.addr)); a.href = C.explorer + "/address/" + r.addr; a.target = "_blank"; a.rel = "noopener";
      row.appendChild(a);
      row.appendChild(el("span", "lb-amt", fmt(r.total)));
      row.appendChild(el("span", "lb-count", String(r.count)));
      const nx = el("span", "lb-time lb-next"); nx.appendChild(el("b", null, globalUnlock ? "Unlocked" : countdown(r.next))); nx.appendChild(el("small", null, dateStr(r.next)));
      const ls = el("span", "lb-time lb-last"); ls.appendChild(el("b", null, globalUnlock ? "Unlocked" : countdown(r.lastU))); ls.appendChild(el("small", null, dateStr(r.lastU)));
      row.appendChild(nx); row.appendChild(ls);
      if (isSoon) row.appendChild(el("span", "lb-badge", "Unlocking in 24h"));
      body.appendChild(row);
    });
  }

  function rowsFromCache() {
    const now = Math.floor(Date.now() / 1000);
    return Object.entries(cache.locks).map(([addr, c]) => {
      const l = c.l.filter((x) => BigInt(x.amount) > 0n); if (!l.length) return null;
      const times = l.map((x) => x.unlockAt).sort((a, b) => a - b);
      return { addr, total: l.reduce((s, x) => s + BigInt(x.amount), 0n), count: l.length, next: times.find((t) => t > now) || times[0], lastU: times[times.length - 1],
        soonAmt: l.filter((x) => x.unlockAt > now && x.unlockAt <= now + 86400).reduce((s, x) => s + BigInt(x.amount), 0n) };
    }).filter(Boolean).sort((a, b) => (b.total > a.total ? 1 : b.total < a.total ? -1 : 0));
  }
  function showRows() { rows = rowsFromCache(); render(); }
  function setStatus(text, retry) {
    const st = $("lb-status"); if (!st) return;
    st.replaceChildren(document.createTextNode(text));
    if (retry) { const b = el("button", "link", " Retry"); b.onclick = () => refresh(true); st.appendChild(b); }
  }
  let refreshing = null, lastHead = 0;
  function refresh(force) {
    if (refreshing) return refreshing;
    if (!force && document.hidden) return Promise.resolve(); // tab hidden: skip, catch up on return
    refreshing = (async () => {
      setStatus("Updating from Arc...");
      let head;
      try { head = await rpc(() => P().getBlockNumber()); }
      catch (e) { setStatus("Arc network is busy. Showing last known data.", true); return; }
      if (!force && head === lastHead) { setStatus("Updated " + new Date().toLocaleTimeString("en-US")); return; } // no new block: nothing to re-read
      let failed = 0;
      // 1) wallets we already know (seed + cache): one Multicall3 call
      const known = Object.keys(cache.wallets);
      try { if (known.length) { await getLocksMany(known); showRows(); } }
      catch (e) { failed++; setStatus("Arc network is busy. Showing last known data.", true); return; }
      // 2) new lockers in blocks after the seed/cache
      try {
        await scan((f) => setStatus("Checking new blocks " + Math.min(100, Math.round(f * 100)) + "%"));
        const fresh = Object.keys(cache.wallets).filter((w) => !known.includes(w));
        if (fresh.length) await getLocksMany(fresh);
      } catch (e) { console.warn("[locks] scan", e); failed++; }
      lastHead = head;
      showRows();
      if (failed) setStatus("Arc network is busy. Showing last known data.", true);
      else setStatus("Updated " + new Date().toLocaleTimeString("en-US"));
    })().finally(() => { refreshing = null; });
    return refreshing;
  }

  async function start() {
    if (typeof ethers === "undefined" || !window.SaviorRPC) return setTimeout(start, 300);
    if (!$("lb-body")) return;
    showRows();                 // cached results from a previous visit, instantly
    await loadSeed(); showRows(); // shipped snapshot (first visit)
    if (rows.length) setStatus("Last known data, updating...");
    refresh(true);
    setInterval(render, 30000);   // countdowns (no RPC)
    setInterval(refresh, 120000); // incremental chain refresh, skipped while hidden or when no new block
    document.addEventListener("visibilitychange", () => { if (!document.hidden) refresh(); });
  }

  // For the Live Trades feed: find the lock created by a buy (amount match, newest first).
  async function lockForBuy(buyer, lockedAmount) {
    const l = await getLocks(buyer);
    const want = BigInt(lockedAmount);
    const hit = [...l].reverse().find((x) => { const a = BigInt(x.amount); return a === want || a + 1n === want || a === want + 1n; });
    return hit || null;
  }

  window.SaviorLocks = { getLocks, lockForBuy, refresh, rpc };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start); else start();
})();
