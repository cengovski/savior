// feed.js, live $SAVIOR transaction feed, read-only, browser-only (ethers v6 global, public RPC, no keys).
// Sources:
//  - PoolManager Swap (decoded from receipts of txs that move SAVIOR through the PoolManager)(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160, uint128, int24, uint24)
//    filtered to the SAVIOR pool id. currency0 = USDC, currency1 = SAVIOR; amounts are the swapper's deltas,
//    so amount0 < 0 means USDC paid in => BUY.
//  - SaviorToken Transfer events touching the Staking contract => stake/lock and claim.
//    (On-chain scan 2026-10-10: SaviorStaking itself emits no events, so token transfers are the only signal.)
(function () {
  const C = window.SAVIOR_CONFIG;
  const SWAP_TOPIC = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f";
  const TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
  const CHUNK = 2000, BACKFILL_CHUNKS = 30, POLL_MS = 8000, MAX_ITEMS = 40;
  const lc = (a) => (a || "").toLowerCase();
  const STAKING = lc(C.contracts.staking), PM = lc(C.contracts.poolManager), TREASURY = lc(C.contracts.treasury);
  // Staking v2: both contracts count as staking; rows are labelled by source only when v2 is active.
  const V2 = lc(C.v2 || "");
  const isStaking = (a) => a === STAKING || (V2 && a === V2);
  const srcOf = (a) => (V2 && a === V2 ? "v2" : "v1");
  let provider, lastBlock = 0, timer = null, seen = new Set(), items = [];

  const topicAddr = (t) => "0x" + t.slice(26);
  const short = (a) => a.slice(0, 6) + "..." + a.slice(-4);
  const fmt = (v, d) => Number(ethers.formatUnits(v < 0n ? -v : v, d)).toLocaleString("en-US", { maximumFractionDigits: 4 });

  function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

  // Plain-English status line, with an optional Retry button.
  function setStatus(s, retry) {
    const e = document.getElementById("feed-status"); if (!e) return;
    e.replaceChildren(document.createTextNode(s));
    if (retry) { const b = el("button", "link", " Retry"); b.onclick = () => { clearTimeout(timer); setStatus("Reconnecting to Arc..."); poll(); }; e.appendChild(b); }
  }
  // cache: last trades survive reloads and show instantly
  const CACHE_KEY = V2 ? "savior.feed.v2." + V2 : "savior.feed.v1"; // v2 mode never mixes with v1-only cache
  let backfillFailed = false, pollFails = 0, lastPollOk = 0, seedScanned = 0;
  function saveCache() {
    try { localStorage.setItem(CACHE_KEY, JSON.stringify({ lastBlock, items: items.map((i) => ({ ...i, _req: undefined, locked: i.locked == null ? null : String(i.locked) })) })); } catch (e) {}
  }
  function loadItems(list) {
    for (const it of list || []) add({ ...it, locked: it.locked == null ? null : BigInt(it.locked), _req: false }, false);
  }

  function render() {
    const list = document.getElementById("feed-list");
    if (!list) return;
    list.replaceChildren();
    if (!items.length) {
      list.appendChild(el("div", "empty", backfillFailed
        ? "Could not load recent trades because the Arc network is busy. New trades will appear here automatically."
        : `No trades in the last ${(BACKFILL_CHUNKS * CHUNK).toLocaleString("en-US")} blocks. New ones appear here live.`));
      return;
    }
    for (const it of items.slice(0, 20)) {
      const row = el("a", "feed-row" + (it.big ? " feed-big" : ""));
      row.href = `${C.explorer}/tx/${it.tx}`; row.target = "_blank"; row.rel = "noopener";
      const kind = el("span", "feed-kind k-" + it.kind);
      if (it.big) kind.innerHTML = '<svg class="ico-16"><use href="#i-bolt"/></svg>';
      kind.appendChild(document.createTextNode(it.kind));
      if (V2 && it.src && !C.v1Retired) kind.appendChild(el("span", "src-tag", it.src === "v2" ? "v2" : "Old"));
      const mid = el("div", "feed-main");
      mid.appendChild(el("div", null, it.text));
      if (it.locked != null) {
        mid.appendChild(el("div", "feed-lock",
          `${fmt(it.locked, C.tokenDecimals)} locked` + (it.unlock === undefined ? "" : it.unlock ? `, unlocks ${new Date(it.unlock * 1000).toLocaleString("en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}` : ", claimed")));
        if (it.unlock === undefined && !it._req && window.SaviorLocks && it.who) {
          it._req = true;
          (C.v1Retired && (it.src || "v1") === "v1" ? Promise.resolve(null) : window.SaviorLocks.lockForBuy(it.who, it.locked, it.src || "v1")).then((l) => { it.unlock = l ? l.unlockAt : null; render(); }).catch(() => { it._req = false; });
        }
      }
      row.append(kind, mid, el("span", "feed-who", it.who ? short(it.who) : "#" + it.block));
      list.appendChild(row);
    }
  }

  function toast(msg) { if (window.toast) window.toast("big", "Big buy", msg); }

  function add(it, live) {
    const key = it.tx + ":" + it.idx;
    if (seen.has(key)) return;
    seen.add(key);
    items.push(it);
    items.sort((a, b) => b.block - a.block || b.idx - a.idx);
    items = items.slice(0, MAX_ITEMS);
    if (live && it.big) toast(it.text);
  }

  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  async function withRetry(fn, tries = 4) {
    if (window.SaviorLocks) return window.SaviorLocks.rpc(fn); // shared throttled queue with backoff
    for (let i = 0; ; i++) {
      try { return await fn(); }
      catch (e) { if (i >= tries) throw e; await sleep(1500 * 2 ** i); } // public RPC rate-limits (-32005)
    }
  }

  // Arc public RPC: eth_getLogs max 2000 blocks/request, rate-limited. PoolManager emits Swap for every pool
  // (very noisy), so we scan only the sparse SAVIOR Transfer log and decode the pool Swap from the receipt.
  async function fetchRange(from, to, live, pre) {
    const transfers = pre || await withRetry(() => provider.getLogs({ address: C.contracts.token, topics: [TRANSFER_TOPIC], fromBlock: from, toBlock: to }));
    const byTx = new Map();
    for (const l of transfers) { if (!byTx.has(l.transactionHash)) byTx.set(l.transactionHash, []); byTx.get(l.transactionHash).push(l); }
    for (const [hash, logs] of byTx) {
      const touchesPM = logs.some((l) => lc(topicAddr(l.topics[1])) === PM || lc(topicAddr(l.topics[2])) === PM);
      if (touchesPM) {
        const rc = await withRetry(() => provider.getTransactionReceipt(hash));
        const swaps = (rc?.logs || []).filter((l) => lc(l.address) === PM && l.topics[0] === SWAP_TOPIC && lc(l.topics[1]) === lc(C.poolId));
        if (swaps.length) {
          for (const l of swaps) {
            const [a0, a1] = ethers.AbiCoder.defaultAbiCoder().decode(["int128", "int128"], ethers.dataSlice(l.data, 0, 64));
            const buy = a0 < 0n;
            const usdc = fmt(a0, C.usdcDecimals), sav = fmt(a1, C.tokenDecimals);
            const usdcNum = Number(ethers.formatUnits(a0 < 0n ? -a0 : a0, C.usdcDecimals));
            let locked = null;
            if (buy) { const net = a1 - (a1 * 30n) / 10000n; locked = net / 2n; } // 0.3% treasury fee, then 50% locked
            const src = srcOf(lc(topicAddr(l.topics[2]))); // Swap(id, sender, ...): sender is the staking contract
            add({ kind: buy ? "BUY" : "SELL", src, text: buy ? `${usdc} USDC to ${sav} SAVIOR` : `${sav} SAVIOR to ${usdc} USDC`,
                  who: rc.from, tx: hash, block: l.blockNumber, idx: l.index, big: buy && usdcNum >= C.bigBuyUsdc, locked }, live);
          }
          continue; // remaining transfers are the swap's lock split
        }
      }
      for (const l of logs) {
        const f = lc(topicAddr(l.topics[1])), t = lc(topicAddr(l.topics[2]));
        const amt = fmt(BigInt(l.data), C.tokenDecimals);
        if (isStaking(t) && f !== PM && !isStaking(f)) add({ kind: "STAKE", src: srcOf(t), text: `${amt} SAVIOR locked`, who: f, tx: hash, block: l.blockNumber, idx: l.index }, live);
        else if (isStaking(f) && t !== PM && t !== TREASURY && !isStaking(t)) add({ kind: "CLAIM", src: srcOf(f), text: `${amt} SAVIOR claimed`, who: t, tx: hash, block: l.blockNumber, idx: l.index }, live);
      }
    }
  }

  async function poll() {
    try {
      // steady state: head + new logs in ONE batched HTTP request (logs to "latest", deduped by tx:index)
      if (lastBlock && Date.now() - lastPollOk < 60000) {
        const [head, logs] = await Promise.all([provider.getBlockNumber(),
          provider.getLogs({ address: C.contracts.token, topics: [TRANSFER_TOPIC], fromBlock: lastBlock + 1, toBlock: "latest" })]);
        if (logs.length) await fetchRange(lastBlock + 1, head, true, logs);
        lastBlock = Math.max(lastBlock, head, ...logs.map((l) => l.blockNumber));
        pollFails = 0; lastPollOk = Date.now();
        render(); if (logs.length) saveCache();
        setStatus("Live, block " + lastBlock.toLocaleString("en-US"));
        return schedule();
      }
      const head = await provider.getBlockNumber();
      if (head === lastBlock) { pollFails = 0; setStatus("Live, block " + head.toLocaleString("en-US")); return schedule(); } // no new block
      if (!lastBlock || head - lastBlock > BACKFILL_CHUNKS * CHUNK) lastBlock = head; // too far behind: jump to live
      while (lastBlock < head) {
        const to = Math.min(head, lastBlock + CHUNK);
        await fetchRange(lastBlock + 1, to, true);
        lastBlock = to;
      }
      pollFails = 0; lastPollOk = Date.now();
      render(); saveCache();
      setStatus("Live, block " + head.toLocaleString("en-US"));
    } catch (e) {
      console.warn("[feed] poll failed", e); pollFails++;
      setStatus(pollFails > 2 ? "Arc network is busy. Showing the last trades we loaded." : "Connection to Arc lost. Reconnecting...", pollFails > 2);
    }
    schedule();
  }
  // hidden tab: poll every 60s instead of 8s; exponential backoff with jitter after failures
  const HIDDEN_POLL_MS = 60000;
  function schedule() {
    clearTimeout(timer);
    let ms = document.hidden ? HIDDEN_POLL_MS : POLL_MS;
    if (pollFails) ms = Math.min(60000, POLL_MS * 2 ** pollFails);
    timer = setTimeout(poll, Math.round(ms * (0.85 + Math.random() * 0.3)));
  }
  document.addEventListener("visibilitychange", () => { if (!document.hidden && provider && lastBlock) { clearTimeout(timer); poll(); } });

  async function start() {
    if (typeof ethers === "undefined" || !window.SaviorRPC) return setTimeout(start, 300);
    if (!document.getElementById("feed-list")) return;
    provider = window.SaviorRPC.provider(); // failover across public Arc RPCs
    // 1) instant: trades from a previous visit, else the shipped snapshot
    let cached = null; try { cached = JSON.parse(localStorage.getItem(CACHE_KEY) || "null"); } catch (e) {}
    if (cached && cached.items && cached.items.length) { loadItems(cached.items); lastBlock = cached.lastBlock || 0; }
    else {
      try { const r = await fetch(new URL("locks-seed.json", document.baseURI), { cache: "no-cache" }); if (r.ok) { const sd = await r.json(); loadItems(sd.trades); seedScanned = sd.scanned || 0; } } catch (e) {}
    }
    if (items.length) { render(); setStatus("Showing recent trades, connecting to Arc..."); }
    else setStatus("Loading recent trades...");
    // 2) backfill only when we have no fresh history
    if (!lastBlock) {
      try {
        const head = await provider.getBlockNumber();
        lastBlock = head;
        if (seedScanned && head - seedScanned <= BACKFILL_CHUNKS * CHUNK) {
          for (let from = seedScanned + 1; from <= head; from += CHUNK) {
            const to = Math.min(head, from + CHUNK - 1);
            await fetchRange(from, to, false);
          }
          throw "done";
        }
        const ff = Number(new URLSearchParams(location.search).get("feedfrom"));
        const top = ff > 0 && ff < head ? ff + (BACKFILL_CHUNKS * CHUNK) / 2 : head;
        let found = 0, chunkFails = 0;
        for (let i = 0; i < BACKFILL_CHUNKS && found < 12; i++) {
          const to = top - i * CHUNK, before = items.length;
          try { await fetchRange(to - CHUNK + 1, to, false); }
          catch (e) { if (++chunkFails >= 2) throw e; } // skip one bad chunk, give up after two
          found += items.length - before;
          if (i % 5 === 4) { render(); setStatus(`Loading trade history: ${((i + 1) * CHUNK).toLocaleString("en-US")} blocks checked`); }
          await sleep(400);
        }
      } catch (e) { if (e !== "done") { console.warn("[feed] backfill failed", e); backfillFailed = true; lastBlock = 0; } }
    }
    render(); saveCache();
    poll();
  }

  window.SaviorFeed = { start, stop: () => clearTimeout(timer) };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start); else start();
})();
