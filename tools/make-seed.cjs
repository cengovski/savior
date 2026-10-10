// Regenerates locks-seed.json (lockers, lock amounts, recent trades; plus a v2 section when run with a v2 address) by running the real page in headless
// Chromium and dumping its caches. Usage: python3 -m http.server 8765 & node tools/make-seed.cjs http://localhost:8765/
const { chromium } = require("playwright"); const fs = require("fs");
(async () => {
  const b = await chromium.launch(); const p = await b.newPage();
  await p.goto(process.argv[2] || "http://localhost:8765/");
  await p.waitForFunction(() => /Updated/.test(document.getElementById("lb-status").textContent) && /Live/.test(document.getElementById("feed-status").textContent), null, { timeout: 240000 });
  const d = await p.evaluate(() => {
    const v2 = (window.SAVIOR_CONFIG.v2 || "").toLowerCase();
    return { v2, l: JSON.parse(localStorage.getItem("savior.locks.v1")), l2: v2 ? JSON.parse(localStorage.getItem("savior.locks.v2." + v2)) : null,
      f: JSON.parse(localStorage.getItem(v2 ? "savior.feed.v2." + v2 : "savior.feed.v1")) };
  });
  const locks = {}; for (const [w, c] of Object.entries(d.l.locks)) if (d.l.wallets[w]) locks[w] = c.l;
  const seed = { generated: new Date().toISOString(), scanned: d.l.scanned, wallets: d.l.wallets, locksAt: Date.now(), locks,
    trades: d.f.items.slice(0, 20).map(({ _req, ...t }) => t) };
  // v2 section, only when the page ran with a v2 address; the site uses it only if the address matches.
  if (d.v2 && d.l2) {
    const l2 = {}; for (const [w, c] of Object.entries(d.l2.locks)) if (d.l2.wallets[w]) l2[w] = c.l;
    seed.v2 = { address: d.v2, deployBlock: d.l2.deployBlock, scanned: d.l2.scanned, wallets: d.l2.wallets, locks: l2 };
  }
  fs.writeFileSync("locks-seed.json", JSON.stringify(seed, null, 1) + "\n");
  console.log("seed:", Object.keys(seed.wallets).length, "wallets,", seed.trades.length, "trades, scanned", seed.scanned);
  await b.close();
})();
