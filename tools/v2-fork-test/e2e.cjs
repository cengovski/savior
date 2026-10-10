const {chromium}=require('playwright');const {execSync}=require('child_process');
const V2=require('fs').readFileSync('/tmp/v2fork/v2addr','utf8').trim();const U='0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266';
const cast=(a)=>execSync(`PATH=$HOME/.foundry/bin:$PATH cast ${a} --rpc-url http://127.0.0.1:8545`).toString().trim();
(async()=>{const b=await chromium.launch();const c=await b.newContext({viewport:{width:1280,height:900},locale:'tr-TR'});const p=await c.newPage();
const errs=[];p.on('pageerror',e=>errs.push(e.message));
const url=`http://localhost:8765/?rpc=http://127.0.0.1:8545&v2=${V2}`;
await p.goto(url);await p.waitForTimeout(4000);
const R={};
R.config=await p.evaluate(()=>({v2:SAVIOR_CONFIG.v2,STAKING_ADDR,STAKING_V2_ADDR,sources:SAVIOR_CONFIG.stakingSources.map(s=>s.id),endpoints:SaviorRPC.endpoints}));
// connect a test signer (anvil unlocked dev account 0)
await p.evaluate(async(U)=>{const pr=new ethers.JsonRpcProvider('http://127.0.0.1:8545',5042,{staticNetwork:true});const s=await pr.getSigner(U);
 Object.defineProperty(WalletConnector,'signer',{get:()=>s});Object.defineProperty(WalletConnector,'provider',{get:()=>pr});userAddress=U;await refreshStakes();},U);
R.stakesBefore=await p.evaluate(()=>[...document.querySelectorAll('#stakes-list .pos-row')].map(r=>r.innerText.replace(/\s+/g,' ')));
// estimate for 2 USDC buy, then real swap through the UI code path (v2)
await p.fill('#swap-amount','2');await p.waitForTimeout(3000);
R.estimate={out:await p.textContent('#savior-out-display'),instant:await p.textContent('#immediate-preview'),locked:await p.textContent('#locked-preview'),fee:await p.textContent('#quote-fee'),min:await p.textContent('#quote-min')};
R.minOutArg=await p.evaluate(async()=>{const q=await SaviorQuote.quote(getReadProvider(),true,2000000n);return {gross:q.gross.toString(),net:q.net.toString(),minOut:SaviorQuote.minOut(q,currentSlipBps).toString(),slipBps:currentSlipBps}});
await p.evaluate(()=>executeSwap());await p.waitForTimeout(6000);
R.swapStatus=await p.textContent('#swap-status');
const logs=JSON.parse(cast(`rpc eth_getLogs '{"address":"${V2}","fromBlock":"latest","toBlock":"latest"}'`));
const sw=logs.find(l=>l.topics[0]===execSync(`PATH=$HOME/.foundry/bin:$PATH cast keccak "Swapped(address,bool,uint256,uint256,uint256,uint256)"`).toString().trim());
if(sw){const d=sw.data.slice(2).match(/.{64}/g).map(x=>BigInt('0x'+x).toString());R.onchainSwapped={zeroForOne:d[0],amountIn:d[1],grossOut:d[2],fee:d[3],locked:d[4]};}
await p.evaluate(()=>refreshStakes());await p.waitForTimeout(1500);
R.stakesAfter=await p.evaluate(()=>[...document.querySelectorAll('#stakes-list .pos-row')].map(r=>r.innerText.replace(/\s+/g,' ')));
R.stats=await p.evaluate(()=>({locked:document.getElementById('total-locked-display').textContent,claimable:document.getElementById('claimable-display').textContent,count:document.getElementById('my-stakes-count').textContent}));
// leaderboard + feed after refresh
await p.evaluate(()=>SaviorLocks.refresh(true));await p.waitForTimeout(8000);
R.leaderboard=await p.evaluate(()=>({status:document.getElementById('lb-status').textContent,total:document.getElementById('lb-total').textContent,holders:document.getElementById('lb-holders').textContent,rows:[...document.querySelectorAll('#lb-body .lb-row')].map(r=>r.innerText.replace(/\s+/g,' '))}));
await p.waitForTimeout(10000);
R.feed=await p.evaluate(()=>({status:document.getElementById('feed-status').textContent,rows:[...document.querySelectorAll('#feed-list .feed-row')].slice(0,3).map(r=>r.innerText.replace(/\s+/g,' '))}));
R.cacheKeys=await p.evaluate(()=>Object.keys(localStorage).filter(k=>/locks|feed/.test(k)));
// time travel 11 days, claim v2 lock #0 and old lock #0 through the UI claim function
cast('rpc evm_increaseTime 950400');cast('rpc evm_mine');
await p.evaluate(()=>refreshStakes());await p.waitForTimeout(1500);
R.stakesMatured=await p.evaluate(()=>[...document.querySelectorAll('#stakes-list .pos-row')].map(r=>r.innerText.replace(/\s+/g,' ')));
const balBefore=cast(`call 0xe4065efC5E19305e4ed1dfdB6542A32A34E0cAf3 "balanceOf(address)(uint256)" ${U}`);
await p.evaluate(()=>claimLock(0,'v2'));await p.waitForTimeout(3000);
await p.evaluate(()=>claimLock(0,'v1'));await p.waitForTimeout(3000);
const balAfter=cast(`call 0xe4065efC5E19305e4ed1dfdB6542A32A34E0cAf3 "balanceOf(address)(uint256)" ${U}`);
R.claim={balBefore,balAfter,v2LocksLeft:cast(`call ${V2} "getLocks(address)((uint128,uint64)[])" ${U}`),v1LocksLeft:cast(`call 0xBCA651C0A0540a1fCDef066B5476d714431fa525 "getLocks(address)((uint128,uint64)[])" ${U}`)};
await p.evaluate(()=>refreshStakes());await p.waitForTimeout(1500);
R.stakesFinal=await p.evaluate(()=>({rows:[...document.querySelectorAll('#stakes-list .pos-row')].length,msg:document.getElementById('stakes-loading').textContent}));
R.toasts=await p.evaluate(()=>[...document.querySelectorAll('.toast b')].map(x=>x.textContent));
await p.screenshot({path:'/workspace/savior-shots/v2-fork-desktop.png',fullPage:true});
R.errs=errs;console.log(JSON.stringify(R,null,1));await b.close()})();
