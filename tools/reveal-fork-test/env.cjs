// Fork test helpers (anvil fork of Arc + ForkSetup.s.sol). Addresses are deterministic for the impersonated deployer.
const {execSync}=require('child_process');
const A={TOKEN:'0xc67508Dd0F43C52da77de8E4d2A9293226d59345',HOOK:'0x180E4a3EC9Fa9ef2ac7Ee0ebcD159e4DFc67a080',ST:'0xE22b92176ABA2C302675a91A7c9f1F3EaAF79288',DIST:'0xDDA530017BC4fdD57D41522310b3BEce171Fa9A0',NFT:'0x748A47f372225F903cEebAD8066bF1b85c56c3CF',USDC:'0x3600000000000000000000000000000000000000',DEP:'0x7185d50557040047A142aEadA95e41C4b31720e7',U0:'0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266',DEPLOY:Number(process.env.DEPLOY||25368532)};
// Override with the addresses setup.sh prints (they depend on the impersonated deployer's nonce on the forked chain).
for(const [k,e] of [['TOKEN','TOKEN'],['HOOK','HOOK'],['ST','STAKING'],['DIST','DISTRIBUTOR'],['NFT','NFT']]) if(process.env[e]) A[k]=process.env[e];
const cast=(a)=>execSync(`PATH=$HOME/.foundry/bin:$PATH cast ${a} --rpc-url http://127.0.0.1:${process.env.PORT||8601}`,{maxBuffer:1e8}).toString().trim();
const url=(base='http://localhost:8772/')=>`${base}?rpc=http://127.0.0.1:${process.env.PORT||8601}&stack=${A.TOKEN},${A.HOOK},${A.ST},${A.DIST},${A.DEPLOY}`;
async function connect(p,addr=A.U0){await p.evaluate(async([U,RPC])=>{const pr=new ethers.JsonRpcProvider(RPC,5042,{staticNetwork:true});const s=await pr.getSigner(U);
 Object.defineProperty(WalletConnector,'signer',{get:()=>s,configurable:true});Object.defineProperty(WalletConnector,'provider',{get:()=>pr,configurable:true});userAddress=U;await refreshStakes();},[addr,`http://127.0.0.1:${process.env.PORT||8601}`]);}
const stakes=(p)=>p.evaluate(()=>[...document.querySelectorAll('#stakes-list .pos-row')].map(r=>r.innerText.replace(/\s+/g,' ')));
function buy(addr,usdc=10){cast(`send ${A.USDC} "setBalance(address,uint256)" ${addr} 1000000000000 --unlocked --from ${A.U0}`);
 cast(`rpc anvil_setBalance ${addr} 0x56BC75E2D63100000`);cast(`rpc anvil_impersonateAccount ${addr}`);
 cast(`send ${A.USDC} "approve(address,uint256)" ${A.ST} $(PATH=$HOME/.foundry/bin:$PATH cast max-uint) --unlocked --from ${addr}`);
 return cast(`send ${A.ST} "swapExactIn(bool,uint256,uint256,uint256)" true ${usdc*1e6} 1 9999999999 --unlocked --from ${addr} --json`);}
const synth=(k)=>'0x'+(0xabc00000+k).toString(16).padStart(40,'0'); // impersonated test wallets
module.exports={synth,A,cast,url,connect,stakes,buy};
