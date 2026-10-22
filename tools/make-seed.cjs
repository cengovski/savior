// Regenerates locks-seed.json (lockers, lock amounts, recent trades for the configured staking contract) by running
// the real page in headless Chromium and dumping its caches.
// Usage: python3 -m http.server 8765 & node tools/make-seed.cjs http://localhost:8765/
const { chromium } = require("playwright"); const fs = require("fs");
(async () => {
  const b = await chromium.launch(); const p = await b.newPage();
  await p.goto(process.argv[2] || "http://localhost:8765/");
  await p.waitForFunction(() => /Updated/.test(document.getElementById("lb-status").textContent) && /Live/.test(document.getElementById("feed-status").textContent), null, { timeout: 240000 });
  const d = await p.evaluate(() => {
    const a = window.SAVIOR_CONFIG.contracts.staking.toLowerCase();
    return { a, l: JSON.parse(localStorage.getItem("savior.locks." + a)), f: JSON.parse(localStorage.getItem("savior.feed." + a)) };
  });
  const locks = {}; for (const [w, c] of Object.entries(d.l.locks || {})) if (d.l.wallets[w]) locks[w] = c.l;
  const seed = { generated: new Date().toISOString(), staking: d.a, scanned: d.l.scanned, wallets: d.l.wallets, locksAt: Date.now(), locks,
    trades: ((d.f && d.f.items) || []).slice(0, 20).map(({ _req, ...t }) => t) };
  fs.writeFileSync("locks-seed.json", JSON.stringify(seed, null, 1) + "\n");
  console.log("seed:", Object.keys(seed.wallets).length, "wallets,", seed.trades.length, "trades, scanned", seed.scanned);
  await b.close();
})();
