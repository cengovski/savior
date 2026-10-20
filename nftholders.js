// nftholders.js: public NFT Holders leaderboard for Savior Weapons (read-only, no wallet).
// Owners come from ownerOf(id) for every minted id, batched through Multicall3 and sent through the
// shared throttled RPC queue (SaviorLocks.rpc: failover + backoff on 429). Results are cached for 2 minutes.
// The LuckyDistributor (holds won but unclaimed NFTs) and the zero address are excluded.
(function () {
  const NFT = "0xf9cEdaA96278462f9b85ADfbB4ea0Bdfc38f383c";
  const EXCLUDE = new Set(["0x54713bd7f1b6c23ece81a2f334e247789a569c5e", "0x0000000000000000000000000000000000000000"]);
  const MC3 = "0xcA11bde05977b3631167028862bE2a173976CA11";
  const EXPLORER = (window.SAVIOR_CONFIG && window.SAVIOR_CONFIG.explorer) || "https://explorer.arc.io";
  const PER_PAGE = 50, BATCH = 250, TTL = 120000, CACHE_KEY = "savior.nftholders.v1." + NFT.toLowerCase();
  const TITLES = { 1: "Eternal Savior", 2: "Guardian Savior", 3: "Vanguard Savior" };
  const nI = new ethers.Interface(["function totalSupply() view returns (uint256)", "function ownerOf(uint256) view returns (address)"]);
  const mI = new ethers.Interface(["function aggregate3((address target,bool allowFailure,bytes callData)[] calls) view returns ((bool success,bytes returnData)[])"]);
  const $ = (id) => document.getElementById(id);
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const short = (a) => a.slice(0, 6) + "..." + a.slice(-4);
  const rpc = (fn) => (window.SaviorLocks && window.SaviorLocks.rpc ? window.SaviorLocks.rpc(fn) : fn());
  let provider = null;
  const P = () => provider || (provider = window.SaviorRPC.provider());
  let rows = [], page = 1, loading = false;

  function tier(rank) {
    if (rank <= 3) return null;
    if (rank <= 10) return { key: "elite", label: "Elite" };
    if (rank <= 20) return { key: "champion", label: "Champion" };
    if (rank <= 50) return { key: "defender", label: "Defender" };
    return null;
  }
  const badgeImg = (src, alt, cls) => { const i = el("img", cls); i.src = src; i.alt = alt; i.width = 20; i.height = 20; i.loading = "lazy"; return i; };
  const addrLink = (addr, cls) => { const a = el("a", cls, short(addr)); a.href = EXPLORER + "/address/" + addr; a.target = "_blank"; a.rel = "noopener"; a.title = addr; return a; };
  const nfts = (n) => n + (n === 1 ? " NFT" : " NFTs");

  async function load() {
    const total = Number(await rpc(() => new ethers.Contract(NFT, nI, P()).totalSupply()));
    const owners = new Map(); // addr -> { count, first }
    const mc = new ethers.Contract(MC3, mI, P());
    for (let start = 1; start <= total; start += BATCH) {
      const ids = []; for (let id = start; id < Math.min(total + 1, start + BATCH); id++) ids.push(id);
      const res = await rpc(() => mc.aggregate3.staticCall(ids.map((id) => ({ target: NFT, allowFailure: true, callData: nI.encodeFunctionData("ownerOf", [id]) }))));
      res.forEach((r, i) => {
        if (!r.success) return;
        const a = nI.decodeFunctionResult("ownerOf", r.returnData)[0];
        if (EXCLUDE.has(a.toLowerCase())) return;
        const o = owners.get(a) || { addr: a, count: 0, first: ids[i] };
        o.count++; o.first = Math.min(o.first, ids[i]); owners.set(a, o);
      });
    }
    // most NFTs first; ties: the wallet holding the earliest minted token, then address
    return [...owners.values()].sort((a, b) => b.count - a.count || a.first - b.first || (a.addr.toLowerCase() < b.addr.toLowerCase() ? -1 : 1));
  }

  function renderPodium() {
    const pod = $("nh-podium"); if (!pod) return;
    pod.replaceChildren();
    pod.classList.toggle("hidden", page !== 1);
    if (page !== 1) return;
    const stage = el("div", "podium-stage");
    for (const rank of [2, 1, 3]) {
      const r = rows[rank - 1];
      const col = el("div", "podium-col p" + rank + (r ? "" : " empty"));
      const FIG = { 1: ["soldier-gold-swords", "Gold soldier with dual swords"], 2: ["soldier-silver-spear", "Silver soldier with spear"], 3: ["soldier-copper-bow", "Copper soldier with bow"] }[rank];
      const fig = el("img", "podium-figure"); fig.src = "assets/podium/" + FIG[0] + ".svg"; fig.alt = r ? FIG[1] : ""; fig.width = 64; fig.height = 100; fig.decoding = "async";
      if (!r) fig.setAttribute("aria-hidden", "true");
      col.appendChild(fig); // soldier stands on top of the block
      const block = el("div", "podium-block"); // rank badge, title, wallet and count sit ON the block
      block.appendChild(badgeImg("assets/badges/rank-" + rank + ".svg", "Rank " + rank, "podium-medal"));
      block.appendChild(el("div", "podium-title", TITLES[rank]));
      if (r) { block.appendChild(addrLink(r.addr, "podium-addr")); block.appendChild(el("div", "podium-count", nfts(r.count))); }
      else block.appendChild(el("div", "podium-addr muted", "Open spot"));
      col.appendChild(block);
      stage.appendChild(col);
    }
    pod.appendChild(stage);
  }

  function render() {
    const body = $("nh-body"); if (!body) return;
    const pages = Math.max(1, Math.ceil(rows.length / PER_PAGE));
    if (page > pages) page = pages;
    renderPodium();
    body.replaceChildren();
    const from = page === 1 ? 3 : (page - 1) * PER_PAGE, to = Math.min(rows.length, page * PER_PAGE);
    if (!rows.length) body.appendChild(el("div", "lb-empty", "No holders yet. Lucky NFT wins show up here once claimed."));
    else if (from >= to) body.appendChild(el("div", "lb-empty", "No other holders yet. New Lucky NFT winners show up here once they claim."));
    for (let i = from; i < to; i++) {
      const r = rows[i], rank = i + 1, t = tier(rank);
      const row = el("div", "tr nh-row"); row.setAttribute("role", "row");
      const w = el("span", "lb-wallet"); w.setAttribute("role", "cell");
      if (t) { const b = el("span", "nh-tier nh-" + t.key); b.title = t.label + " (ranks " + (t.key === "elite" ? "4-10" : t.key === "champion" ? "11-20" : "21-50") + ")"; b.appendChild(badgeImg("assets/badges/tier-" + t.key + ".svg", t.label, "")); b.appendChild(el("span", null, t.label)); w.appendChild(b); }
      w.appendChild(el("span", "lb-rank", "#" + rank));
      w.appendChild(addrLink(r.addr, "lb-addr"));
      const c = el("span", "lb-amt", r.count.toLocaleString("en-US")); c.setAttribute("role", "cell");
      row.append(w, c); body.appendChild(row);
    }
    $("nh-page").textContent = "Page " + page + " of " + pages;
    $("nh-prev").disabled = page <= 1; $("nh-next").disabled = page >= pages;
  }

  function setStatus(text, retry) {
    const s = $("nh-status"); if (!s) return;
    s.replaceChildren(document.createTextNode(text));
    if (retry) { const b = el("button", "link", " Retry"); b.onclick = () => refresh(true); s.appendChild(b); }
  }
  async function refresh(force) {
    if (loading) return; loading = true;
    try {
      let cached = null; try { cached = JSON.parse(localStorage.getItem(CACHE_KEY) || "null"); } catch (e) {}
      if (cached && Array.isArray(cached.rows)) { rows = cached.rows; render(); }
      if (!force && cached && Date.now() - cached.at < TTL) { setStatus(rows.length + (rows.length === 1 ? " holder" : " holders")); return; }
      setStatus(cached ? "Updating from Arc..." : "Loading from Arc...");
      rows = await load();
      try { localStorage.setItem(CACHE_KEY, JSON.stringify({ at: Date.now(), rows })); } catch (e) {}
      render(); setStatus(rows.length + (rows.length === 1 ? " holder" : " holders"));
    } catch (e) {
      console.warn("nft holders", e);
      render(); setStatus(rows.length ? "Arc network is busy, showing saved data." : "Arc network is busy, holders could not load.", true);
    } finally { loading = false; }
  }
  function init() {
    if (!$("nh-body")) return;
    $("nh-prev").onclick = () => { if (page > 1) { page--; render(); $("nft-holders").scrollIntoView({ behavior: "smooth" }); } };
    $("nh-next").onclick = () => { page++; render(); $("nft-holders").scrollIntoView({ behavior: "smooth" }); };
    render();
    setTimeout(() => refresh(false), 1200); // let the locks leaderboard take the first RPC slots
    setInterval(() => { if (!document.hidden) refresh(false); }, TTL);
  }
  window.SaviorNftHolders = { refresh, _set: (r) => { rows = r; page = 1; render(); }, _page: (p) => { page = p; render(); } };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init); else init();
})();
