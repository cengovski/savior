// Fork e2e for the fresh-start UI: reveal in window, reveal after window, Reveal all (>25), Lucky NFT win + claimNFT, deferred mint + retry.
// Needs: anvil fork on PORT (default 8601) with ForkSetup.s.sol deployed, the site served on :8772, playwright.
const { chromium } = require(process.env.PW || 'playwright');
const E = require('./env.cjs'); const { A, cast } = E;
const SHOTS = process.env.SHOTS || '/workspace/savior-shots';
const R = {}; const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const lockCount = (u) => Number(cast(`call ${A.ST} "lockCount(address)(uint256)" ${u}`).split(' ')[0]);
const mine = (n) => cast(`rpc anvil_mine 0x${n.toString(16)}`);
const settle = () => sleep(4500); // site read cache: eth_call 4 s (anvil makes no blocks on its own)
const lockView = (u, i) => cast(`call ${A.ST} "getLocks(address,uint256,uint256)((uint128,uint64,uint64,bool,uint64,uint64,bool)[])" ${u} ${i} 1`);
const toasts = (p) => p.evaluate(() => [...document.querySelectorAll('.toast')].map((x) => x.innerText.replace(/\s+/g, ' ')).slice(-3));
const accounts = JSON.parse(cast('rpc eth_accounts'));
(async () => {
  const b = await chromium.launch();
  const ctx = await b.newContext({ viewport: { width: 1280, height: 900 } });
  const p = await ctx.newPage(); const errs = [];
  p.on('pageerror', (e) => errs.push(e.message));
  const shot = async (name, theme = 'light', w = 1280, sel = '#reveal-warning') => {
    await p.setViewportSize({ width: w, height: 900 });
    await p.evaluate((t) => { localStorage.setItem('savior.theme', t); document.documentElement.dataset.theme = t; document.documentElement.classList.toggle('dark', t === 'dark'); }, theme);
    await p.evaluate((sel) => { const e = document.querySelector(sel); (e && e.offsetParent ? e : document.getElementById('stakes-list')).scrollIntoView({ block: 'start' }); window.scrollBy(0, -90); }, sel); await sleep(400);
    await p.screenshot({ path: `${SHOTS}/reveal-${name}-${theme}-${w}.png` });
  };
  cast(`send ${A.USDC} "setBalance(address,uint256)" ${A.U0} 1000000000000 --unlocked --from ${A.U0}`);
  await p.goto(E.url()); await sleep(5000); await E.connect(p); await sleep(1500);

  // 1) UI buy: lock shown as 10 days (default), pending
  await p.fill('#swap-amount', '10'); await sleep(2500);
  R.estimate = await p.textContent('#savior-out-display');
  await p.evaluate(() => executeSwap()); await sleep(6000);
  R.buyStatus = await p.textContent('#swap-status');
  const i0 = lockCount(A.U0) - 1;
  await p.evaluate(() => SaviorStakes.refreshStakes()); await sleep(800);
  R.afterBuy = (await E.stakes(p)).find((x) => x.startsWith('#' + i0));
  await shot('1-pending');
  // 2) reveal window open: button + countdown + warning
  mine(4); await settle(); await p.evaluate(() => SaviorStakes.refreshStakes()); await sleep(800);
  R.revealable = (await E.stakes(p)).find((x) => x.startsWith('#' + i0));
  R.warning = await p.evaluate(() => !document.getElementById('reveal-warning').classList.contains('hidden'));
  await shot('2-countdown'); await shot('2-countdown', 'dark'); await shot('2-countdown', 'light', 375); await shot('2-countdown', 'dark', 375);
  await p.setViewportSize({ width: 1280, height: 900 });
  // 3) reveal within the window
  await p.evaluate((i) => SaviorStakes.reveal(i), i0); await sleep(4000);
  R.revealToasts = await toasts(p); R.revealedRow = (await E.stakes(p)).find((x) => x.startsWith('#' + i0)); R.revealedOnChain = lockView(A.U0, i0);
  await shot('3-revealed');
  // 4) EIP-2935 path on anvil (older than 256 blocks) + reveal after the window
  E.buy(A.U0); const i1 = lockCount(A.U0) - 1; mine(300);
  R.revealableAfter300 = cast(`call ${A.ST} "revealableNow(address,uint256)(bool)" ${A.U0} ${i1}`);
  mine(8000);
  R.closedOnChain = cast(`call ${A.ST} "revealWindowClosed(address,uint256)(bool)" ${A.U0} ${i1}`);
  await settle(); await p.evaluate(() => SaviorStakes.refreshStakes()); await sleep(800);
  R.closedRow = (await E.stakes(p)).find((x) => x.startsWith('#' + i1));
  await p.evaluate((i) => SaviorStakes.reveal(i), i1); await sleep(2500);
  R.closedRevealToasts = await toasts(p);
  await shot('4-window-ended', 'light', 1280, '#stakes-list');
  // 5) Reveal all with > 25 locks (10 wallets x 3 buys = 30 locks) + U0's own
  const others = Array.from({ length: 10 }, (_, k) => E.synth(k + 1));
  for (const a of others) for (let k = 0; k < 3; k++) E.buy(a);
  mine(4); await settle();
  await p.evaluate(() => SaviorLocks.refresh(true)); await sleep(5000);
  R.lbBefore = await p.evaluate(() => [...document.querySelectorAll('#lb-body .lb-row')].slice(0, 4).map((r) => r.innerText.replace(/\s+/g, ' ')));
  await shot('5-leaderboard-pending', 'light', 1280, '#reveal-all');
  await p.evaluate(() => SaviorStakes.revealAll());
  R.revealAll = await p.textContent('#reveal-all-status');
  const batches = JSON.parse(cast(`logs --from-block ${A.DEPLOY} --address ${A.ST} "RevealBatch(address,uint256,uint256)" --json`));
  R.revealBatchEvents = batches.map((l) => [BigInt('0x' + l.data.slice(2, 66)).toString(), BigInt('0x' + l.data.slice(66, 130)).toString()]);
  R.pendingLeft = others.map((a) => cast(`call ${A.ST} "pendingRevealable(address,uint256,uint256)(uint256[])" ${a} 0 200`)).join(' ');
  await sleep(4000); await p.evaluate(() => SaviorLocks.refresh(true)); await sleep(4000);
  R.lbAfter = await p.evaluate(() => [...document.querySelectorAll('#lb-body .lb-row')].slice(0, 4).map((r) => r.innerText.replace(/\s+/g, ' ')));
  R.feedTop = await p.evaluate(() => [...document.querySelectorAll('#feed-list .feed-row')].slice(0, 4).map((r) => r.innerText.replace(/\s+/g, ' ')));
  await shot('5-reveal-all', 'light', 1280, '#reveal-all'); await shot('5-reveal-all', 'dark', 375, '#reveal-all');
  // 6) Lucky NFT: search for a winning committed hash (deterministic check via isLuckyWin before revealing), reveal in the UI, claimNFT
  async function findWin(tag) {
    for (let t = 0; t < 120; t++) {
      E.buy(A.U0); const i = lockCount(A.U0) - 1; mine(4);
      const v = lockView(A.U0, i).match(/\((\d+) \[[^\]]*\], (\d+)[^,]*, (\d+)[^,]*, (true|false), (\d+)/);
      const h = cast(`call ${A.ST} "ringBlockHash(uint256)(bytes32)" ${v[5]}`);
      if (cast(`call ${A.ST} "isLuckyWin(bytes32,address,uint256,uint64)(bool)" ${h} ${A.U0} ${i} ${v[2]}`) === 'true') return { i, tries: t + 1 };
      cast(`send ${A.ST} "reveal(address,uint256)" ${A.U0} ${i} --unlocked --from ${E.synth(99)} --gas-limit 2000000`);
    }
    throw new Error('no win in 120 tries ' + tag);
  }
  cast(`rpc anvil_setBalance ${E.synth(99)} 0x56BC75E2D63100000`); cast(`rpc anvil_impersonateAccount ${E.synth(99)}`);
  const w = await findWin('claim'); R.win = w; await settle();
  await p.evaluate(() => SaviorStakes.refreshStakes()); await sleep(800);
  R.winRowBefore = (await E.stakes(p)).find((x) => x.startsWith('#' + w.i));
  await p.evaluate((i) => SaviorStakes.reveal(i), w.i); await sleep(5000);
  R.winToasts = await toasts(p); R.nftCard = await p.textContent('#nft-body');
  await p.evaluate(() => document.getElementById('nft-card').scrollIntoView()); await sleep(300);
  for (const [t, wd] of [['light', 1280], ['dark', 1280], ['light', 375], ['dark', 375]]) {
    await p.setViewportSize({ width: wd, height: 900 });
    await p.evaluate((t) => { localStorage.setItem('savior.theme', t); document.documentElement.dataset.theme = t; document.documentElement.classList.toggle('dark', t === 'dark'); }, t);
    await p.evaluate(() => document.getElementById('nft-card').scrollIntoView({ block: 'center' })); await sleep(300);
    await p.screenshot({ path: `${SHOTS}/reveal-6-claim-nft-${t}-${wd}.png` });
  }
  await p.setViewportSize({ width: 1280, height: 900 });
  const id = (await p.evaluate(() => SaviorStakes.state().ids.map(String)))[0];
  R.reservedId = id;
  await p.evaluate((id) => SaviorStakes.claimNFT(BigInt(id)), id); await sleep(4000);
  R.claimToasts = await toasts(p); R.ownerOf = cast(`call ${A.NFT} "ownerOf(uint256)(address)" ${id}`); R.nftAfterClaim = await p.textContent('#nft-body');
  // 7) Deferred mint (price > 0, distributor unfunded) -> owed + Retry mint -> fund -> retry
  const params = `(1000000000000000000,1000000,0,18446744073709551615,1,1000000,1000,true)`;
  cast(`send ${A.DIST} "setMintParams((uint256,uint256,uint256,uint256,uint256,uint256,uint256,bool))" "${params}" --unlocked --from ${A.DEP}`);
  const leaf = cast(`call ${A.DIST} "allowListLeaf()(bytes32)"`);
  cast(`send ${A.NFT} "updateAllowList(address,(bytes32,string[],string))" 0x00005EA00Ac477B1030CE78506496e8C2dE24bf5 "(${leaf},[],\\"\\")" --unlocked --from ${A.DEP}`);
  const w2 = await findWin('retry'); R.win2 = w2; await settle();
  await p.evaluate(() => SaviorStakes.refreshStakes()); await sleep(800);
  await p.evaluate((i) => SaviorStakes.reveal(i), w2.i); await sleep(5000);
  R.owed = cast(`call ${A.DIST} "owed(address)(uint256)" ${A.U0}`); R.nftDeferred = await p.textContent('#nft-body');
  await p.evaluate(() => document.getElementById('nft-card').scrollIntoView({ block: 'center' })); await sleep(300);
  await p.screenshot({ path: `${SHOTS}/reveal-7-retry-mint-light-1280.png` });
  cast(`rpc anvil_setBalance ${A.DIST} 0x8AC7230489E80000`); // 10 native USDC
  await p.evaluate(() => SaviorStakes.retryMint()); await sleep(5000);
  R.retryToasts = await toasts(p); R.owedAfter = cast(`call ${A.DIST} "owed(address)(uint256)" ${A.U0}`); R.nftAfterRetry = await p.textContent('#nft-body');
  await p.screenshot({ path: `${SHOTS}/reveal-7-after-retry-light-1280.png` });
  R.pageErrors = errs;
  console.log(JSON.stringify(R, null, 1)); await b.close();
})().catch((e) => { console.error('FAIL', e); console.log(JSON.stringify(R, null, 1)); process.exit(1); });
