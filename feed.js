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
  let provider, lastBlock = 0, timer = null, seen = new Set(), items = [];

  const topicAddr = (t) => "0x" + t.slice(26);
  const short = (a) => a.slice(0, 6) + "..." + a.slice(-4);
  const fmt = (v, d) => Number(ethers.formatUnits(v < 0n ? -v : v, d)).toLocaleString(undefined, { maximumFractionDigits: 4 });

  function el(tag, cls, text) { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

  function setStatus(s) { const e = document.getElementById("feed-status"); if (e) e.textContent = s; }

  function render() {
    const list = document.getElementById("feed-list");
    if (!list) return;
    list.replaceChildren();
    if (!items.length) { list.appendChild(el("div", "empty", `No trades in the last ${(BACKFILL_CHUNKS * CHUNK).toLocaleString()} blocks, new ones appear live`)); return; }
    for (const it of items.slice(0, 20)) {
      const row = el("a", "feed-row" + (it.big ? " feed-big" : ""));
      row.href = `${C.explorer}/tx/${it.tx}`; row.target = "_blank"; row.rel = "noopener";
      const kind = el("span", "feed-kind k-" + it.kind);
      if (it.big) kind.innerHTML = '<svg class="ico-16"><use href="#i-bolt"/></svg>';
      kind.appendChild(document.createTextNode(it.kind));
      const mid = el("div", "feed-main");
      mid.appendChild(el("div", null, it.text));
      if (it.locked != null) {
        mid.appendChild(el("div", "feed-lock",
          `${fmt(it.locked, C.tokenDecimals)} locked` + (it.unlock === undefined ? "" : it.unlock ? `, unlocks ${new Date(it.unlock * 1000).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}` : ", claimed")));
        if (it.unlock === undefined && !it._req && window.SaviorLocks && it.who) {
          it._req = true;
          window.SaviorLocks.lockForBuy(it.who, it.locked).then((l) => { it.unlock = l ? l.unlockAt : null; render(); }).catch(() => { it._req = false; });
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
  async function fetchRange(from, to, live) {
    const transfers = await withRetry(() => provider.getLogs({ address: C.contracts.token, topics: [TRANSFER_TOPIC], fromBlock: from, toBlock: to }));
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
            add({ kind: buy ? "BUY" : "SELL", text: buy ? `${usdc} USDC to ${sav} SAVIOR` : `${sav} SAVIOR to ${usdc} USDC`,
                  who: rc.from, tx: hash, block: l.blockNumber, idx: l.index, big: buy && usdcNum >= C.bigBuyUsdc, locked }, live);
          }
          continue; // remaining transfers are the swap's lock split
        }
      }
      for (const l of logs) {
        const f = lc(topicAddr(l.topics[1])), t = lc(topicAddr(l.topics[2]));
        const amt = fmt(BigInt(l.data), C.tokenDecimals);
        if (t === STAKING && f !== PM) add({ kind: "STAKE", text: `${amt} SAVIOR locked`, who: f, tx: hash, block: l.blockNumber, idx: l.index }, live);
        else if (f === STAKING && t !== PM && t !== TREASURY) add({ kind: "CLAIM", text: `${amt} SAVIOR claimed`, who: t, tx: hash, block: l.blockNumber, idx: l.index }, live);
      }
    }
  }

  async function poll() {
    try {
      const head = await provider.getBlockNumber();
      while (lastBlock < head) {
        const to = Math.min(head, lastBlock + CHUNK);
        await fetchRange(lastBlock + 1, to, true);
        lastBlock = to;
      }
      render();
      setStatus("live, block " + head.toLocaleString());
    } catch (e) { console.warn("[feed] poll failed", e); setStatus("reconnecting…"); }
    timer = setTimeout(poll, POLL_MS);
  }

  async function start() {
    if (typeof ethers === "undefined") return setTimeout(start, 300);
    if (!document.getElementById("feed-list")) return;
    provider = new ethers.JsonRpcProvider(C.rpc, C.chainId, { staticNetwork: true });
    setStatus("loading history…");
    try {
      const head = await provider.getBlockNumber();
      lastBlock = head;
      // ?feedfrom=<block> (debug): backfill starting from a specific block instead of the head
      const ff = Number(new URLSearchParams(location.search).get("feedfrom"));
      const top = ff > 0 && ff < head ? ff + (BACKFILL_CHUNKS * CHUNK) / 2 : head;
      for (let i = 0; i < BACKFILL_CHUNKS && items.length < 12; i++) {
        const to = top - i * CHUNK;
        await fetchRange(to - CHUNK + 1, to, false);
        if (i % 5 === 4) { render(); setStatus(`scanning history… ${((i + 1) * CHUNK).toLocaleString()} blocks`); }
        await sleep(400);
      }
    } catch (e) { console.warn("[feed] backfill failed", e); }
    render();
    poll();
  }

  window.SaviorFeed = { start, stop: () => clearTimeout(timer) };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start); else start();
})();
