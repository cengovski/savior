import { chromium } from 'playwright';
import { execSync } from 'child_process';
const R = 'http://127.0.0.1:8545', DEP = '0x7185d50557040047A142aEadA95e41C4b31720e7';
const SH = '/workspace/fresh-tab-shots-v2/';
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
console.log('btn states', await page.evaluate(() => [1,2,3,4,5,6].map(k => document.getElementById('fsBtn' + k).disabled)));
await page.screenshot({ path: SH + '01-connected-step1-enabled.png', fullPage: true });
await page.fill('#fsLogo', 'ipfs://bafkreitestlogo');
await page.click('#fsBtn1'); console.log('STEP1\n' + await waitRes('fsRes1', 'totalSupply'));
await page.click('#fsBtn2'); console.log('STEP2\n' + await waitRes('fsRes2', 'expectedSqrtPrice', 240000));
console.log('btn states after 2', await page.evaluate(() => [1,2,3,4,5,6].map(k => document.getElementById('fsBtn' + k).disabled)));
await page.screenshot({ path: SH + '02-step1-2-verified.png', fullPage: true });
// Simulated OpenSea Studio: EIP-1167 clone of ERC721SeaDropCloneable, initialize(owner = deployer), maxSupply
const IMPL = '09a26fc8fcef18192e267d7a6da9dfb4be81dd6a', SEADROP = '0x00005EA00Ac477B1030CE78506496e8C2dE24bf5';
const out1 = execSync(`PATH=$HOME/.foundry/bin:$PATH cast send --rpc-url ${R} --unlocked --from ${DEP} --json --create 0x3d602d80600a3d3981f3363d3d373d3d3d363d73${IMPL}5af43d82803e903d91602b57fd5bf3`, { encoding: 'utf8' });
const NFT = JSON.parse(out1).contractAddress;
cast(`send ${NFT} "initialize(string,string,address[],address)" "SAVIOR Lucky" SVLUCKY "[${SEADROP}]" ${DEP} --unlocked --from ${DEP}`);
cast(`send ${NFT} "setMaxSupply(uint256)" 1000 --unlocked --from ${DEP}`);
console.log('clone', NFT);
await page.fill('#fsNft', NFT); await page.fill('#fsPrice', '0.01');
await page.click('#fsBtn3'); console.log('STEP3\n' + await waitRes('fsRes3', 'mint params'));
await page.click('#fsBtn4'); console.log('STEP4\n' + await waitRes('fsRes4', 'maxSupply'));
await page.screenshot({ path: SH + '03-step3-4-lucky-configured.png', fullPage: true });
await page.click('#fsBtn5'); console.log('STEP5\n' + await waitRes('fsRes5', 'matches ladder'));
await page.click('#fsMineBtn'); console.log('MINE\n' + await waitRes('fsMineRes', 'isValidHookSalt = true'));
await page.click('#fsBtn6'); console.log('STEP6\n' + await waitRes('fsRes6', 'factory SAVIOR', 240000));
await page.click('#fsBtnV'); console.log('VERIFY\n' + await waitRes('fsResV', 'ladder geometry'));
await page.screenshot({ path: SH + '04-step5-6-deployed-verified.png', fullPage: true });
const st0 = await page.evaluate(() => JSON.parse(localStorage.getItem('savior_fresh_v2')));
const S = (await page.textContent('#fsRes6')).match(/STAKING (0x\w+)/)[1];
const U = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';
cast(`send 0x3600000000000000000000000000000000000000 "approve(address,uint256)" ${S} $(PATH=$HOME/.foundry/bin:$PATH cast max-uint) --unlocked --from ${U}`);
const key = cast(`call ${S} "key()(address,address,uint24,int24,address)"`).split('\n');
const usdcIs0 = key[0].toLowerCase() === '0x3600000000000000000000000000000000000000';
// small buy: never eligible
cast(`send ${S} "swapExactIn(bool,uint256,uint256,uint256)" ${usdcIs0} 9000000 1 9999999999 --unlocked --from ${U}`);
console.log('9 USDC buy luckyEligible:', cast(`call ${S} "luckyEligible(address,uint256)(bool)" ${U} 0`));
cast('rpc anvil_setBalance 0x70997970C51812dc3A010C7d01b50e0d4c4F79C8 0x56BC75E2D63100000');
cast('rpc anvil_impersonateAccount 0x70997970C51812dc3A010C7d01b50e0d4c4F79C8');
let win = -1;
for (let i = 1; i <= 200 && win < 0; i++) {
  cast(`send ${S} "swapExactIn(bool,uint256,uint256,uint256)" ${usdcIs0} 20000000 1 9999999999 --unlocked --from ${U}`);
  cast('rpc anvil_mine 4');
  cast(`send ${S} "reveal(address,uint256)" ${U} ${i} --unlocked --from 0x70997970C51812dc3A010C7d01b50e0d4c4F79C8`); // third party reveals
  const owed = BigInt(cast(`call ${st0.dist} "owed(address)(uint256)" ${U}`).split(' ')[0]);
  if (owed > 0n) win = i;
}
console.log('first lucky win at lock', win, '(price 0.01 USDC, distributor unfunded -> deferred)');
cast(`rpc anvil_setBalance ${st0.dist} 0xDE0B6B3A7640000`); // prefund 1 USDC native
await page.fill('#fsLuckyUser', U);
await page.click('#fsLuckyCfgBtn'); console.log('LUCKY CFG\n' + await waitRes('fsLuckyCfg', 'total owed'));
await page.click('#fsLuckyLookupBtn'); console.log('LOOKUP\n' + await waitRes('fsLuckyRes', 'owed'));
await page.screenshot({ path: SH + '05-lucky-win-deferred.png', fullPage: true });
await page.click('#fsRetryBtn'); console.log('RETRY\n' + await waitRes('fsLuckyRes', 'retryMint done'));
await page.screenshot({ path: SH + '06-lucky-retrymint-reserved.png', fullPage: true });
const id = (await page.textContent('#fsLuckyRes')).match(/claimNFT\((\d+)\)/)[1];
cast(`send ${st0.dist} "claimNFT(uint256)" ${id} --unlocked --from ${U}`);
console.log('NFT owner after claim', cast(`call ${st0.nft} "ownerOf(uint256)(address)" ${id}`));
await page.click('#fsLuckyLookupBtn'); console.log('LOOKUP2\n' + await waitRes('fsLuckyRes', 'reserved unclaimed tokens \\(page\\): \\[\\]'));
await page.screenshot({ path: SH + '07-lucky-claimed.png', fullPage: true });
const st = { s: S, tok: st0.token };
// generate fees: buy + sell via staking from anvil dev account
cast(`send ${st.s} "swapExactIn(bool,uint256,uint256,uint256)" ${usdcIs0} 2000000000 1 9999999999 --unlocked --from ${U}`);
const sb = cast(`call ${st.tok} "balanceOf(address)(uint256)" ${U}`).split(' ')[0];
cast(`send ${st.tok} "approve(address,uint256)" ${st.s} ${sb} --unlocked --from ${U}`);
cast(`send ${st.s} "swapExactIn(bool,uint256,uint256,uint256)" ${!usdcIs0} ${BigInt(sb) / 2n} 1 9999999999 --unlocked --from ${U}`);
console.log('buy+sell done, buyer SAVIOR before sell', sb);
await page.click('#fsFeesBtn'); console.log('FEES\n' + await waitRes('fsFeesRes', 'Total accrued'));
await page.screenshot({ path: SH + '08-fees-loaded.png', fullPage: true });
const firstId = await page.evaluate(() => document.querySelector('#fsFeesTable tr:nth-child(2) td').textContent);
await page.click(`#fsFeesTable button[onclick="fsCollect('${firstId}')"]`); console.log('COLLECT ONE\n' + await waitRes('fsFeesRes', 'Collected[\\s\\S]*Total'));
await page.click('#fsCollectAllBtn'); console.log('COLLECT ALL\n' + await waitRes('fsFeesRes', 'Collected[\\s\\S]*Total accrued: 0.0 USDC, 0.0 SAVIOR'));
await page.screenshot({ path: SH + '09-fees-collected.png', fullPage: true });
await page.click('#fsEmSched'); console.log('EMERGENCY\n' + await waitRes('fsEmRes', 'countdown'));
await page.fill('#fsLockUser', U); await page.click('text=Load page'); console.log('LOCKS\n' + await waitRes('fsLockRes', 'lockCount'));
await page.click('text=Re-check owner() on-chain'); console.log('LEGACY\n' + await waitRes('fsLegacyRes', 'owner'));
await page.screenshot({ path: SH + '10-emergency-scheduled-locks-legacy.png', fullPage: true });
console.log('emergency exec disabled:', await page.isDisabled('#fsEmExec'));
console.log('page errors:', errors);
await browser.close();
