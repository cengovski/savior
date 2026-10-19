// stakes.js: My Stakes (paginated lock reads, lock reveal, claim), Personal reveal, the reveal hint, Reveal all and the Lucky NFT card.
// Reads use ONLY the paginated views getLocks(user, offset, limit) and pendingRevealable(user, offset, limit).
(function () {
  const C = window.SAVIOR_CONFIG;
  if (!C) return;
  const ST = C.contracts.staking, DIST = C.contracts.distributor, PAGE = 200, BLOCK_S = 0.51;
  const MC3 = "0xcA11bde05977b3631167028862bE2a173976CA11";
  const STAKING_ABI = [
    "function lockCount(address) view returns (uint256)",
    "function getLocks(address user, uint256 offset, uint256 limit) view returns ((uint128 amount,uint64 createdAt,uint64 unlockAt,bool isPending,uint64 targetBlock,uint64 revealDeadlineBlock,bool revealableNow)[])",
    "function pendingRevealable(address user, uint256 offset, uint256 limit) view returns (uint256[])",
    "function luckyEligible(address user, uint256 i) view returns (bool)",
    "function luckyFailed(address) view returns (uint256)",
    "function globalUnlock() view returns (bool)",
    "function MAX_REVEAL_BATCH() view returns (uint256)",
    "function reveal(address user, uint256 i)",
    "function revealBatch(address[] users, uint256[] indices) returns (uint256)", // 0x1679398d
    "function claim(uint256 i)",
    "event LockRevealed(address indexed user, uint256 indexed index, uint64 unlockAt, uint64 duration, bool shortened)",
    "event LuckyWin(address indexed user, uint256 indexed index, bool delivered)",
    "event RevealBatch(address indexed caller, uint256 revealed, uint256 attempted)",
    "error TooEarly()", "error RevealWindowClosed()", "error AlreadyRevealed()", "error BadIndex()", "error NothingToClaim()",
    "error BatchLengthMismatch()", "error BatchTooLarge()", "error LowGas()", "error Locked()", "error StillRevealable()",
  ];
  const DIST_ABI = [
    "function owed(address) view returns (uint256)",
    "function reservedOf(address user, uint256 offset, uint256 limit) view returns (uint256[])",
    "function claimNFT(uint256 id)", "function retryMint(address user)", "function nft() view returns (address)",
    "event Reserved(address indexed user, uint256 indexed tokenId)", "event NftClaimed(address indexed user, uint256 indexed tokenId)",
    "error NotReserved()", "error NothingOwed()",
  ];
  const sI = new ethers.Interface(STAKING_ABI), dI = new ethers.Interface(DIST_ABI);
  const MESSAGES = {
    TooEarly: "Reveal opens 3 blocks after the buy (about 2 seconds). Try again in a moment.",
    RevealWindowClosed: "The reveal window has ended. This lock stays at 10 days.",
    AlreadyRevealed: "This lock is already revealed.",
    BatchLengthMismatch: "Batch error: the wallet and lock lists did not match. Nothing was changed.",
    BatchTooLarge: "Batch too large: at most 25 locks per transaction. Please try again.",
    LowGas: "Not enough gas for a possible Lucky NFT win. Please try again (the wallet will add more gas).",
    Locked: "This lock is still locked.", NothingToClaim: "Nothing to claim on this lock.",
    NotReserved: "This NFT is not reserved for your wallet.", NothingOwed: "There is no pending NFT mint for this wallet.",
    BadIndex: "This lock does not exist.",
  };
  function errMsg(e) {
    let name = e && e.revert && e.revert.name;
    if (!name) for (const d of [e && e.data, e && e.error && e.error.data, e && e.info && e.info.error && e.info.error.data]) {
      const hex = typeof d === "string" ? d : d && d.data;
      if (typeof hex === "string" && hex.length >= 10) for (const i of [sI, dI]) { try { name = i.parseError(hex).name; break; } catch (x) {} }
      if (name) break;
    }
    if (name && MESSAGES[name]) return MESSAGES[name];
    if (e && (e.code === "ACTION_REJECTED" || e.code === 4001)) return "Request cancelled in the wallet.";
    return (e && (e.shortMessage || e.reason || e.message)) || String(e);
  }
  const $ = (id) => document.getElementById(id);
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const fmt = (v) => Number(ethers.formatUnits(BigInt(v), 6)).toLocaleString("en-US", { maximumFractionDigits: 2 });
  const dateStr = (ts) => new Date(ts * 1000).toLocaleString("en-US", { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
  const P = () => window.SaviorRPC.provider();
  const rpc = (fn) => (window.SaviorLocks ? window.SaviorLocks.rpc(fn) : fn());
  let mc = null;
  const agg = (calls) => rpc(() => (mc = mc || new ethers.Contract(MC3, ["function aggregate3((address target,bool allowFailure,bytes callData)[] calls) view returns ((bool success,bytes returnData)[])"], P())).aggregate3.staticCall(calls));
  const sc = (fn, args) => ({ target: ST, allowFailure: true, callData: sI.encodeFunctionData(fn, args) });
  const dc = (fn, args) => ({ target: DIST, allowFailure: true, callData: dI.encodeFunctionData(fn, args) });
  const dec = (i, fn, r) => (r && r.success ? i.decodeFunctionResult(fn, r.returnData)[0] : null);
  const signer = () => window.WalletConnector && window.WalletConnector.signer;
  const user = () => (typeof userAddress !== "undefined" ? userAddress : null);

  // ---------- chain clock (blocks) ----------
  let head = 0, headAt = 0;
  const estHead = () => (head ? head + Math.floor((Date.now() - headAt) / (BLOCK_S * 1000)) : 0);
  function clock(blocks) {
    let s = Math.max(0, Math.round(blocks * BLOCK_S));
    const h = Math.floor(s / 3600); s %= 3600; const m = Math.floor(s / 60); s %= 60;
    return (h ? h + "h " : "") + m + "m " + String(s).padStart(2, "0") + "s";
  }
  const lockState = (l, b, now) => {
    if (l.pending && b > l.deadline) return "closed";      // window over: final 10 days
    if (l.pending && l.revealable) return "revealable";
    if (l.pending) return "pending";                       // reveal not open yet (3 blocks)
    return now >= l.unlockAt ? "claimable" : "waiting";
  };

  // ---------- My Stakes (lock screen) ----------
  let state = { locks: [], lucky: {}, gu: false, owed: 0n, ids: [], failed: 0n, at: 0 };
  async function load(u) {
    const b = await rpc(() => P().getBlockNumber()); head = b; headAt = Date.now();
    const calls = [sc("lockCount", [u]), sc("getLocks", [u, 0, PAGE]), sc("globalUnlock", []), sc("luckyFailed", [u])];
    if (DIST) calls.push(dc("owed", [u]), dc("reservedOf", [u, 0, PAGE]));
    const r = await agg(calls);
    const n = Number(dec(sI, "lockCount", r[0]) || 0n);
    let raw = (dec(sI, "getLocks", r[1]) || []).map((x, i) => [i, x]);
    for (let off = PAGE; off < n; off += PAGE) {               // more pages only for very active wallets
      const page = await rpc(() => new ethers.Contract(ST, STAKING_ABI, P()).getLocks(u, off, PAGE));
      raw = raw.concat(page.map((x, i) => [off + i, x]));
    }
    const locks = raw.map(([i, x]) => ({ i, amount: BigInt(x.amount), createdAt: Number(x.createdAt), unlockAt: Number(x.unlockAt),
      pending: x.isPending, target: Number(x.targetBlock), deadline: Number(x.revealDeadlineBlock), revealable: x.revealableNow }));
    let ids = DIST ? (dec(dI, "reservedOf", r[5]) || []).map(BigInt) : [];
    for (let off = PAGE; DIST && ids.length >= off; off += PAGE) ids = ids.concat((await rpc(() => new ethers.Contract(DIST, DIST_ABI, P()).reservedOf(u, off, PAGE))).map(BigInt));
    // NFT chance flags only for locks that are still pending (one more Multicall3 call)
    const pend = locks.filter((l) => l.amount > 0n && l.pending && b <= l.deadline);
    const lucky = {};
    if (pend.length) { const lr = await agg(pend.map((l) => sc("luckyEligible", [u, l.i]))); pend.forEach((l, k) => { lucky[l.i] = !!dec(sI, "luckyEligible", lr[k]); }); }
    state = { locks, lucky, gu: !!dec(sI, "globalUnlock", r[2]), failed: dec(sI, "luckyFailed", r[3]) || 0n,
      owed: DIST ? dec(dI, "owed", r[4]) || 0n : 0n, ids, at: Date.now() };
  }

  function ensureDom() {
    if (!$("reveal-warning")) {
      const w = el("div", "reveal-warn hidden"); w.id = "reveal-warning";
      w.innerHTML = '<svg class="ico-18"><use href="#i-bolt"/></svg>';
      w.appendChild(el("span", null, "Reveal within ~70 min to keep your NFT chance. New locks start at 10 days; revealing can drop them to 5 to 10 days."));
      const table = $("stakes-list").closest(".table"); table.parentNode.insertBefore(w, table);
    }
    if (DIST && !$("nft-card")) {
      const card = el("div", "card nft-card"); card.id = "nft-card";
      card.innerHTML = '<div class="eyebrow">Lucky NFT</div><h3 class="h2" style="font-size:20px">SAVIOR Lucky NFT</h3>';
      card.appendChild(el("p", "sub", "Buys of 10 USDC or more have a 5% chance to win a Lucky NFT when the lock is revealed. Wins are reserved for your wallet; claim them here."));
      const body = el("div"); body.id = "nft-body"; card.appendChild(body);
      const anchor = $("stakes-summary") || $("stakes-list").closest(".table");
      anchor.parentNode.insertBefore(card, anchor.nextSibling);
    }
    if (!$("reveal-all")) {
      const box = el("div", "reveal-all"); box.id = "reveal-all";
      const b = el("button", "btn btn-ghost btn-sm", "Reveal all pending locks"); b.id = "reveal-all-btn"; b.onclick = revealAll;
      const st = el("span", "sub mono"); st.id = "reveal-all-status";
      st.textContent = "Anyone can reveal open locks for everyone, in batches of 25.";
      box.append(b, st);
      const slot = $("preveal-all-slot");
      if (slot) { slot.appendChild(el("div", "label", "Help everyone")); slot.appendChild(box); }
      else { const sub = $("lb-status").closest(".sub-h"); sub.parentNode.insertBefore(box, sub.nextSibling); }
    }
  }

  function renderStakes() {
    const list = $("stakes-list"), loading = $("stakes-loading");
    const now = Math.floor(Date.now() / 1000), b = estHead();
    const live = state.locks.filter((l) => l.amount > 0n);
    const order = { claimable: 0, waiting: 1, closed: 1, revealable: 2, pending: 2 }; // claimable, then waiting, then pending
    const rows = live.map((l) => ({ l, s: state.gu && !(l.pending && b <= l.deadline) ? "claimable" : lockState(l, b, now) }))
      .sort((x, y) => order[x.s] - order[y.s] || x.l.unlockAt - y.l.unlockAt);
    list.replaceChildren();
    let total = 0n, claimable = 0n;
    for (const { l, s } of rows) {
      total += l.amount; if (s === "claimable") claimable += l.amount;
      const row = el("div", "tr pos-row");
      const c1 = el("span", "mono", "#" + l.i);
      const c2 = el("span"); c2.appendChild(el("b", "mono", fmt(l.amount) + " SAVIOR"));
      if (state.lucky[l.i] && (s === "pending" || s === "revealable")) { const d = el("div"); d.appendChild(el("span", "lucky-chip lucky-chip-row", "NFT chance")); c2.appendChild(d); }
      const c3 = el("span");
      if (s === "pending" || s === "revealable") {
        c3.className = "pos-reveal";
        c3.appendChild(el("div", "mono", "10 days (default)"));
        if (s === "pending") c3.appendChild(el("div", "reveal-cd", "Reveal opens in " + clock(Math.max(1, l.target + 1 - b))));
        else {
          const box = el("div", "reveal-box");
          const btn = el("button", "btn btn-primary btn-sm", "Reveal your lock: it can drop to 5-10 days"); btn.id = "reveal-" + l.i; btn.dataset.reveal = String(l.i);
          btn.onclick = () => reveal(l.i);
          box.append(btn, el("div", "reveal-cd", "Window closes in " + clock(l.deadline - b) + " (block " + l.deadline.toLocaleString("en-US") + ")"));
          c3.appendChild(box);
        }
      } else if (s === "closed") {
        c3.appendChild(el("div", "mono", "Locked for 10 days")); c3.appendChild(el("div", "reveal-cd", "Unlocks " + dateStr(l.unlockAt)));
      } else {
        c3.appendChild(el("div", "mono", s === "claimable" ? "Ready" : countdown(l.unlockAt - now)));
        c3.appendChild(el("div", "reveal-cd", (s === "claimable" ? "Unlocked " : "Unlocks ") + dateStr(l.unlockAt)));
      }
      const c4 = el("span");
      if (s === "claimable") { const cb = el("button", "btn btn-primary btn-sm", "Claim"); cb.id = "claim-" + l.i; cb.onclick = () => claimLock(l.i); c4.appendChild(cb); }
      else c4.appendChild(el("span", "lock-state" + (s === "revealable" || s === "pending" ? " pending" : ""), s === "revealable" ? "Reveal now" : s === "pending" ? "Pending" : "Locked"));
      row.append(c1, c2, c3, c4); list.appendChild(row);
    }
    $("total-locked-display").textContent = fmt(total) + " SAVIOR";
    $("claimable-display").textContent = fmt(claimable) + " SAVIOR";
    $("my-stakes-count").textContent = String(rows.length);
    $("reveal-warning").classList.toggle("hidden", !rows.some((r) => r.s === "pending" || r.s === "revealable"));
    if (!rows.length) { loading.textContent = "No active locks yet. Buy SAVIOR to start."; loading.classList.remove("hidden"); } else loading.classList.add("hidden");
    renderNft();
    renderPersonal(rows, b);
  }
  // ---------- Personal reveal (section below Swap): only this wallet's locks that can still be revealed ----------
  const revealing = new Set();
  function setBadge(n) {
    const badge = $("preveal-badge");
    if (badge) { badge.textContent = n ? `${n} to reveal` : ""; badge.classList.toggle("hidden", !n); }
    document.querySelectorAll(".nav-reveal").forEach((a) => { a.classList.toggle("has-dot", !!n); a.setAttribute("aria-label", n ? `Reveal (${n} lock${n > 1 ? "s" : ""} waiting)` : "Reveal"); });
  }
  function renderPersonal(rows, b) {
    const list = $("preveal-list"), empty = $("preveal-empty");
    if (!list || !empty) return;
    if (!user()) {
      list.replaceChildren(); setBadge(0);
      empty.innerHTML = 'Connect your wallet to see the locks you can reveal. <div style="margin-top:12px"><button class="btn btn-primary btn-sm" onclick="connectWallet()"><svg class="ico-18"><use href="#i-wallet"/></svg>Connect Wallet</button></div>';
      empty.classList.remove("hidden"); return;
    }
    const open = (rows || []).filter((r) => r.s === "pending" || r.s === "revealable").sort((x, y) => x.l.deadline - y.l.deadline);
    setBadge(open.length);
    list.replaceChildren();
    for (const { l, s } of open) {
      const row = el("div", "preveal-row" + (s === "revealable" ? " is-open" : ""));
      const left = el("div", "preveal-main");
      const top = el("div", "preveal-top");
      top.append(el("span", "mono preveal-id", "Lock #" + l.i), el("b", "mono", fmt(l.amount) + " SAVIOR"));
      if (state.lucky[l.i]) top.appendChild(el("span", "lucky-chip", "NFT chance"));
      left.appendChild(top);
      const span = Math.max(1, l.deadline - l.target), leftBlocks = Math.max(0, l.deadline - b);
      const cd = el("div", "preveal-cd");
      if (s === "pending") cd.textContent = "Reveal opens in " + clock(Math.max(1, l.target + 1 - b));
      else { cd.append("Time left to reveal: "); cd.appendChild(el("b", "mono", clock(leftBlocks))); }
      left.appendChild(cd);
      const bar = el("div", "preveal-bar"); const fill = el("i"); fill.style.width = Math.min(100, Math.max(0, (leftBlocks / span) * 100)).toFixed(1) + "%";
      if (leftBlocks / span < 0.2) bar.classList.add("low");
      bar.appendChild(fill); left.appendChild(bar);
      left.appendChild(el("div", "sub", "Now: 10 days. After reveal: 5 to 10 days" + (state.lucky[l.i] ? ", plus a 5% Lucky NFT draw." : ".")));
      const btn = el("button", "btn btn-primary btn-sm preveal-btn", s === "revealable" ? "Reveal" : "Opening soon");
      btn.dataset.reveal = String(l.i); btn.disabled = s !== "revealable" || revealing.has(l.i);
      if (revealing.has(l.i)) btn.textContent = "Revealing...";
      btn.onclick = () => reveal(l.i);
      row.append(left, btn); list.appendChild(row);
    }
    if (!open.length) { empty.textContent = "No locks waiting for a reveal. Each buy creates a lock you can reveal for about 70 minutes."; empty.classList.remove("hidden"); }
    else empty.classList.add("hidden");
  }

  function countdown(s) { s = Math.max(0, s); const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60); return `in ${d}d ${h}h ${m}m`; }

  function renderNft() {
    const body = $("nft-body"); if (!body) return;
    body.replaceChildren();
    if (!user()) { body.appendChild(el("p", "sub", "Connect your wallet to see your Lucky NFTs.")); return; }
    if (state.ids.length) {
      const wrap = el("div", "nft-list");
      for (const id of state.ids) {
        const it = el("div", "nft-item"); it.appendChild(el("b", "mono", "Lucky NFT #" + id));
        const btn = el("button", "btn btn-primary btn-sm", "Claim NFT"); btn.id = "claim-nft-" + id; btn.onclick = () => claimNFT(id);
        it.appendChild(btn); wrap.appendChild(it);
      }
      body.appendChild(wrap);
    }
    if (state.owed > 0n) {
      const p = el("div", "reveal-box");
      p.appendChild(el("div", null, `${state.owed} win${state.owed === 1n ? "" : "s"} waiting to be minted. Minting was deferred (for example, the drop was not funded yet).`));
      const rb = el("button", "btn btn-ghost btn-sm", "Retry mint"); rb.id = "retry-mint"; rb.onclick = retryMint; p.appendChild(rb);
      body.appendChild(p);
    }
    if (state.failed > 0n) body.appendChild(el("p", "sub", `${state.failed} win${state.failed === 1n ? "" : "s"} could not be recorded by the distributor. Please contact the team.`));
    if (!state.ids.length && state.owed === 0n && state.failed === 0n) body.appendChild(el("p", "sub", "No Lucky NFTs to claim yet."));
  }

  async function refreshStakes() {
    ensureDom();
    const loading = $("stakes-loading");
    if (!user()) {
      $("stakes-list").replaceChildren(); loading.textContent = "Connect wallet to see your positions"; loading.classList.remove("hidden");
      ["total-locked-display", "claimable-display", "my-stakes-count"].forEach((id) => { $(id).textContent = "-"; });
      $("reveal-warning").classList.add("hidden"); state.ids = []; state.owed = 0n; state.failed = 0n; renderNft(); renderPersonal([], 0); return;
    }
    if (!state.at) { loading.textContent = "Loading..."; loading.classList.remove("hidden"); }
    try { await load(user()); renderStakes(); }
    catch (e) { loading.textContent = "Could not load positions: " + errMsg(e); loading.classList.remove("hidden"); }
  }
  // countdowns tick locally (no RPC); a reload happens when a lock changes state
  let lastSig = "";
  setInterval(() => {
    if (!state.at || !user() || document.hidden) return;
    const now = Math.floor(Date.now() / 1000), b = estHead();
    const sig = state.locks.map((l) => lockState(l, b, now)).join();
    renderStakes();
    if (lastSig && sig !== lastSig) refreshStakes(); // e.g. reveal opened or window closed: confirm on chain
    lastSig = sig;
  }, 1000);

  // ---------- writes ----------
  async function send(fn, pending, ok) {
    if (!signer()) { window.toast("error", "Connect your wallet first"); return null; }
    const t = window.toast("pending", pending, "Confirm in your wallet");
    try {
      if (window.WalletConnector.ensureArc) await window.WalletConnector.ensureArc(); // back to Arc after a bridge
      await fn(true);                     // simulate first (readable revert before signing)
      const tx = await fn(false);
      t.update("pending", pending, "Waiting for confirmation");
      const rc = await tx.wait();
      t.update("success", ok(rc), "", { link: C.explorer + "/tx/" + tx.hash });
      return rc;
    } catch (e) { t.update("error", pending.replace(/\.\.\.$/, "") + " failed", errMsg(e)); return null; }
  }
  const parse = (rc, iface, name) => (rc ? rc.logs.map((l) => { try { return iface.parseLog(l); } catch (e) { return null; } }).filter((x) => x && x.name === name) : []);

  async function reveal(i) {
    const btns = () => document.querySelectorAll('[data-reveal="' + i + '"]');
    revealing.add(i); btns().forEach((x) => { x.disabled = true; });
    const c = new ethers.Contract(ST, STAKING_ABI, signer());
    const rc = await send((sim) => (sim ? c.reveal.staticCall(user(), i) : c.reveal(user(), i)), "Revealing lock...", (rc) => {
      const ev = parse(rc, sI, "LockRevealed")[0];
      return ev ? `Lock revealed: unlocks ${dateStr(Number(ev.args.unlockAt))} (${(Number(ev.args.duration) / 86400).toLocaleString("en-US", { maximumFractionDigits: 2 })} days)` : "Lock revealed";
    });
    if (rc && parse(rc, sI, "LuckyWin").length) window.toast("success", "You won a Lucky NFT!", "It is reserved for your wallet. Claim it in the Lucky NFT card.");
    revealing.delete(i); btns().forEach((x) => { x.disabled = false; });
    await refreshStakes(); window.SaviorLocks && window.SaviorLocks.refresh(true);
  }

  async function claimNFT(id) {
    const c = new ethers.Contract(DIST, DIST_ABI, signer());
    const btn = $("claim-nft-" + id); if (btn) btn.disabled = true;
    await send((sim) => (sim ? c.claimNFT.staticCall(id) : c.claimNFT(id)), "Claiming NFT...", () => `Lucky NFT #${id} is in your wallet`);
    await refreshStakes();
  }
  async function retryMint() {
    const c = new ethers.Contract(DIST, DIST_ABI, signer());
    const rc = await send((sim) => (sim ? c.retryMint.staticCall(user()) : c.retryMint(user())), "Retrying NFT mint...", (rc) =>
      parse(rc, dI, "Reserved").length ? "NFT minted and reserved for you" : "Mint still deferred, try again later");
    await refreshStakes();
    return rc;
  }

  // ---------- Reveal all pending locks (anyone) ----------
  async function collectRevealable(setSt) {
    if (window.SaviorLocks) { setSt("Checking new lockers..."); try { await window.SaviorLocks.scan(); } catch (e) {} }
    const wallets = window.SaviorLocks ? window.SaviorLocks.wallets() : [];
    const pairs = [];
    for (let s = 0; s < wallets.length; s += 100) {               // lockCount for up to 100 wallets per Multicall3 call
      const ws = wallets.slice(s, s + 100);
      const counts = (await agg(ws.map((w) => sc("lockCount", [w])))).map((r) => Number(dec(sI, "lockCount", r) || 0n));
      const pages = []; ws.forEach((w, k) => { for (let off = 0; off < counts[k]; off += PAGE) pages.push([w, off]); });
      for (let q = 0; q < pages.length; q += 100) {
        const chunk = pages.slice(q, q + 100);
        const res = await agg(chunk.map(([w, off]) => sc("pendingRevealable", [w, off, PAGE])));
        chunk.forEach(([w, off], j) => (dec(sI, "pendingRevealable", res[j]) || []).forEach((i) => pairs.push([w, BigInt(i)])));
      }
      setSt(`Checked ${Math.min(s + 100, wallets.length)} of ${wallets.length} wallets`);
    }
    return pairs;
  }
  async function revealAll() {
    const btn = $("reveal-all-btn"), st = $("reveal-all-status"), setSt = (m) => { st.textContent = m; };
    if (!signer()) { window.toast("error", "Connect your wallet first", "Revealing sends a transaction (anyone can pay the gas)."); return; }
    btn.disabled = true;
    try {
      const pairs = await collectRevealable(setSt);
      if (!pairs.length) { setSt("No pending locks to reveal right now."); return; }
      let max = 25; try { max = Number(await rpc(() => new ethers.Contract(ST, STAKING_ABI, P()).MAX_REVEAL_BATCH())) || 25; } catch (e) {}
      const chunks = []; for (let k = 0; k < pairs.length; k += max) chunks.push(pairs.slice(k, k + max));
      const c = new ethers.Contract(ST, STAKING_ABI, signer());
      let revealed = 0n, attempted = 0n;
      for (let k = 0; k < chunks.length; k++) {
        const us = chunks[k].map((p) => p[0]), is = chunks[k].map((p) => p[1]);
        setSt(`Batch ${k + 1} of ${chunks.length}: confirm in your wallet (${us.length} locks)`);
        const rc = await send((sim) => (sim ? c.revealBatch.staticCall(us, is) : c.revealBatch(us, is)), `Reveal all: batch ${k + 1} of ${chunks.length}...`, (rc) => {
          const ev = parse(rc, sI, "RevealBatch")[0];
          return ev ? `Batch ${k + 1}: revealed ${ev.args.revealed} of ${ev.args.attempted}` : `Batch ${k + 1} sent`;
        });
        if (!rc) { setSt(`Stopped at batch ${k + 1} of ${chunks.length}. Revealed ${revealed} of ${attempted} so far.`); return; }
        const ev = parse(rc, sI, "RevealBatch")[0];
        if (ev) { revealed += ev.args.revealed; attempted += ev.args.attempted; }
        const wins = parse(rc, sI, "LuckyWin").length;
        setSt(`Revealed ${revealed} of ${attempted} locks` + (wins ? `, ${wins} Lucky NFT win${wins > 1 ? "s" : ""}` : "") + (k + 1 < chunks.length ? ", next batch..." : "."));
      }
      setSt(`Done: revealed ${revealed} of ${attempted} locks in ${chunks.length} batch${chunks.length > 1 ? "es" : ""}. Skipped locks were already revealed, not ready or closed.`);
    } catch (e) { setSt("Reveal all failed: " + errMsg(e)); }
    finally { btn.disabled = false; window.SaviorLocks && window.SaviorLocks.refresh(true); refreshStakes(); }
  }

  // ---------- Reveal hint after a buy ----------
  // Shown after every successful buy until the user ticks "Don't show this again" and closes it.
  const HINT_KEY = "savior.hint.reveal.off";
  const hintOff = () => { try { return localStorage.getItem(HINT_KEY) === "1"; } catch (e) { return false; } };
  function closeHint() {
    const h = $("reveal-hint"); if (!h || h.classList.contains("hidden")) return;
    if ($("reveal-hint-off") && $("reveal-hint-off").checked) { try { localStorage.setItem(HINT_KEY, "1"); } catch (e) {} }
    h.classList.add("hidden");
  }
  function showRevealHint() {
    const h = $("reveal-hint"); if (!h || hintOff()) return false;
    $("reveal-hint-off").checked = false;
    h.classList.remove("hidden");
    const sec = $("reveal"); if (sec) sec.scrollIntoView({ behavior: "smooth", block: "start" });
    h.classList.remove("pulse"); void h.offsetWidth; h.classList.add("pulse");
    setTimeout(() => { try { $("reveal-hint-close").focus({ preventScroll: true }); } catch (e) {} }, 600);
    return true;
  }
  function wireHint() {
    const c = $("reveal-hint-close"), x = $("reveal-hint-x"), h = $("reveal-hint");
    if (c) c.onclick = closeHint; if (x) x.onclick = closeHint;
    if (h) h.addEventListener("keydown", (e) => { if (e.key === "Escape") closeHint(); });
  }

  window.SaviorRevealHint = { show: showRevealHint, close: closeHint, isOff: hintOff, reset: () => { try { localStorage.removeItem(HINT_KEY); } catch (e) {} } };
  window.SaviorStakes = { refreshStakes, reveal, revealAll, claimNFT, retryMint, errMsg, state: () => state, collectRevealable };
  const boot = () => { wireHint(); if (!$("stakes-list")) return; ensureDom(); renderNft(); renderPersonal([], 0); };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot); else boot();
})();
