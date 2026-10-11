// Legacy recovery e2e on an anvil Arc fork (run setup.sh first). Switches the injected account between both wallets.
import { chromium } from 'playwright';
import { execSync } from 'child_process';
const R = 'http://127.0.0.1:8545', DEP = '0x7185d50557040047A142aEadA95e41C4b31720e7', B = '0xb31113cEaAd11CadBfEBE5ae8420FA09F8f1c7de';
const SH = process.env.SHOTS || '/workspace/legacy-shots/';
const cast = c => execSync('PATH=$HOME/.foundry/bin:$PATH cast ' + c + ' --rpc-url ' + R, { encoding: 'utf8' }).trim();
cast(`rpc anvil_impersonateAccount ${B}`); cast(`rpc anvil_setBalance ${B} 0x56BC75E2D63100000`);
const b = await chromium.launch(); const ctx = await b.newContext({ viewport: { width: 1280, height: 1000 } });
await ctx.addInitScript(({ R, DEP }) => { let id = 0; window.__acct = DEP; window.ethereum = { isMetaMask: true, on(){}, removeListener(){}, async request({ method, params }) {
  if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [window.__acct]; if (method.startsWith('wallet_')) return null;
  const r = await fetch(R, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params: params || [] }) });
  const j = await r.json(); if (j.error) { const e = new Error(j.error.message); e.code = j.error.code; throw e; } return j.result; } }; }, { R, DEP });
const p = await ctx.newPage(); const errs = []; p.on('pageerror', e => errs.push(e.message)); p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); }); p.on('dialog', d => d.accept());
await p.goto('http://localhost:3999/login'); await p.fill('input[name=password]', 'localtestpassword-not-real-123'); await Promise.all([p.waitForNavigation(), p.click('button')]);
await p.click(`.tab[onclick="showTab('fresh')"]`);
const w = async (id, re) => { await p.waitForFunction(([id, re]) => new RegExp(re).test(document.getElementById(id).textContent), [id, re], { timeout: 120000 }); return p.textContent('#' + id); };
await p.click('text=Connect / Refresh legacy status'); console.log('STATUS\n' + await w('lrStatus', 'Sell'));
console.log('unlock disabled before typing:', await p.isDisabled('#lrUnlockBtn'));
await p.locator('#lrCard').screenshot({ path: SH + '01-status.png' });
await p.fill('#lrConfirm', 'UNLOCK ALL'); await p.click('#lrUnlockBtn'); console.log(await w('lrRes', 'globalUnlock set'));
for (const acct of [DEP, B]) {
  await p.evaluate(a => { window.__acct = a; }, acct); await p.click('text=Connect / Refresh legacy status'); await w('lrStatus', 'Connected: ' + acct.slice(0, 10)); await p.waitForTimeout(1500);
  const btns = await p.$$eval('#lrClaimBtns button', bs => bs.filter(x => !x.disabled).map(x => x.textContent));
  console.log(acct, 'claim buttons', btns);
  for (const t of btns.filter(x => x.startsWith('Claim v2'))) { await p.click(`#lrClaimBtns button:has-text("${t.slice(0, 15)}")`); await w('lrRes', 'Claimed'); }
  if (acct === DEP) { cast('rpc evm_increaseTime 700000'); cast('rpc anvil_mine 1'); await p.click('text=Connect / Refresh legacy status');
    await p.waitForFunction(() => { const x = [...document.querySelectorAll('#lrClaimBtns button')].find(b => b.textContent.includes('0xa9bd')); return x && !x.disabled; }, null, { timeout: 20000 }).catch(async e => { console.log('DBG', await p.textContent('#lrStatus'), await p.innerHTML('#lrClaimBtns'), cast('block latest -f timestamp')); throw e; });
    await p.click('#lrClaimBtns button:has-text("0xa9bd")'); console.log(await w('lrRes', 'Claimed 0xa9bd')); }
  await w('lrStatus', 'Sell'); await p.click('#lrApproveBtn'); await w('lrRes', 'Approved'); console.log((await w('lrStatus', 'Sell quote')).split('\n').pop());
  await p.click('#lrSellBtn'); console.log(await w('lrRes', 'Sold'));
  await p.locator('#lrCard').screenshot({ path: SH + (acct === DEP ? '02-deployer-sold.png' : '03-b311-sold.png') });
}
console.log('errors', errs); await b.close();
