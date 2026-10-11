import { chromium } from 'playwright';
import { execSync } from 'child_process';
const R = 'http://127.0.0.1:8545', DEP = '0x7185d50557040047A142aEadA95e41C4b31720e7';
const SH = '/workspace/fresh-tab-shots/';
const cast = c => execSync('PATH=$HOME/.foundry/bin:$PATH cast ' + c + ' --rpc-url ' + R, { encoding: 'utf8' }).trim();
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 1280, height: 1000 } });
await ctx.addInitScript(({ R, DEP }) => {
  let id = 0;
  window.ethereum = { isMetaMask: true, on(){}, removeListener(){},
    async request({ method, params }) {
      if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [DEP];
      if (method === 'wallet_switchEthereumChain' || method === 'wallet_addEthereumChain') return null;
      const r = await fetch(R, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params: params || [] }) });
      const j = await r.json(); if (j.error) { const e = new Error(j.error.message); e.code = j.error.code; e.data = j.error.data; throw e; } return j.result;
    } };
}, { R, DEP });
const page = await ctx.newPage();
const errors = []; page.on('pageerror', e => errors.push(e.message));
page.on('dialog', d => { console.log('dialog:', d.message().split('\n')[0]); d.accept(); });
await page.goto('http://localhost:3999/login');
await page.fill('input[name=password]', 'localtestpassword-not-real-123');
await Promise.all([page.waitForNavigation(), page.click('button')]);
// existing tabs still render
for (const t of ['deploy','manage','liquidity','info','migrate']) { await page.click(`.tab[onclick="showTab('${t}')"]`); if (!await page.isVisible('#tab-' + t)) throw new Error('tab broken ' + t); }
await page.click(`.tab[onclick="showTab('fresh')"]`);
await page.screenshot({ path: SH + '00-fresh-tab-disconnected.png', fullPage: true });
await page.click('text=Connect wallet');
const waitRes = async (id, re, ms = 240000) => { try { await page.waitForFunction(([id, re]) => new RegExp(re).test(document.getElementById(id).textContent), [id, re], { timeout: ms }); } catch (e) { console.log("TIMEOUT " + id + ": " + await page.textContent("#" + id)); await page.screenshot({ path: SH + "zz-fail.png", fullPage: true }); throw e; } return page.textContent("#" + id); };
await waitRes('fsStatus', 'deployer');
console.log('btn states', await page.evaluate(() => [1,2,3,4,5].map(k => document.getElementById('fsBtn' + k).disabled)));
await page.screenshot({ path: SH + '01-connected-step1-enabled.png', fullPage: true });
await page.fill('#fsLogo', 'ipfs://bafkreitestlogo');
await page.click('#fsBtn1'); console.log('STEP1\n' + await waitRes('fsRes1', 'totalSupply'));
await page.click('#fsBtn2'); console.log('STEP2\n' + await waitRes('fsRes2', 'permit2', 240000));
await page.screenshot({ path: SH + '02-step1-2-verified.png', fullPage: true });
await page.click('#fsBtn3'); console.log('STEP3\n' + await waitRes('fsRes3', 'matches ladder'));
await page.screenshot({ path: SH + '03-step3-approved-transfer-lock.png', fullPage: true });
await page.click('#fsMineBtn'); console.log('MINE\n' + await waitRes('fsMineRes', 'isValidHookSalt = true'));
await page.click('#fsBtn4'); console.log('STEP4\n' + await waitRes('fsRes4', 'ladder NFTs', 180000));
await page.click('#fsBtn5'); console.log('STEP5\n' + await waitRes('fsRes5', 'factory SAVIOR'));
await page.screenshot({ path: SH + '04-step4-5-deployed-verified.png', fullPage: true });
// generate fees: buy + sell via staking from anvil dev account
const st = await page.evaluate(() => ({ s: (document.getElementById('fsRes4').textContent.match(/STAKING (0x\w+)/) || [])[1], tok: JSON.parse(localStorage.getItem('savior_fresh_v1')).token }));
const U = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';
cast(`send 0x3600000000000000000000000000000000000000 "approve(address,uint256)" ${st.s} $(PATH=$HOME/.foundry/bin:$PATH cast max-uint) --unlocked --from ${U}`);
const key = cast(`call ${st.s} "key()(address,address,uint24,int24,address)"`).split('\n');
const usdcIs0 = key[0].toLowerCase() === '0x3600000000000000000000000000000000000000';
cast(`send ${st.s} "swapExactIn(bool,uint256,uint256,uint256)" ${usdcIs0} 2000000000 1 9999999999 --unlocked --from ${U}`);
const sb = cast(`call ${st.tok} "balanceOf(address)(uint256)" ${U}`).split(' ')[0];
cast(`send ${st.tok} "approve(address,uint256)" ${st.s} ${sb} --unlocked --from ${U}`);
cast(`send ${st.s} "swapExactIn(bool,uint256,uint256,uint256)" ${!usdcIs0} ${BigInt(sb) / 2n} 1 9999999999 --unlocked --from ${U}`);
console.log('buy+sell done, buyer SAVIOR before sell', sb);
await page.click('#fsFeesBtn'); console.log('FEES\n' + await waitRes('fsFeesRes', 'Total accrued'));
await page.screenshot({ path: SH + '05-fees-loaded.png', fullPage: true });
const firstId = await page.evaluate(() => document.querySelector('#fsFeesTable tr:nth-child(2) td').textContent);
await page.click(`#fsFeesTable button[onclick="fsCollect('${firstId}')"]`); console.log('COLLECT ONE\n' + await waitRes('fsFeesRes', 'Collected[\\s\\S]*Total'));
await page.click('#fsCollectAllBtn'); console.log('COLLECT ALL\n' + await waitRes('fsFeesRes', 'Collected[\\s\\S]*Total accrued: 0.0 USDC, 0.0 SAVIOR'));
await page.screenshot({ path: SH + '06-fees-collected.png', fullPage: true });
await page.click('#fsEmSched'); console.log('EMERGENCY\n' + await waitRes('fsEmRes', 'countdown'));
await page.fill('#fsLockUser', U); await page.click('text=Load page'); console.log('LOCKS\n' + await waitRes('fsLockRes', 'lockCount'));
await page.click('text=Re-check owner() on-chain'); console.log('LEGACY\n' + await waitRes('fsLegacyRes', 'owner'));
await page.screenshot({ path: SH + '07-emergency-scheduled-locks-legacy.png', fullPage: true });
console.log('emergency exec disabled:', await page.isDisabled('#fsEmExec'));
console.log('page errors:', errors);
await browser.close();
