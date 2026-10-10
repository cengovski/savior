set -e
R=http://127.0.0.1:8545
USDC=0x3600000000000000000000000000000000000000; PM=0x8366a39CC670B4001A1121B8F6A443A643e40951
TOKEN=0xe4065efC5E19305e4ed1dfdB6542A32A34E0cAf3; HOOK=0xFfcf2eF82AA17Fb31F3618E0302F9adC92D060c0
V1=0xBCA651C0A0540a1fCDef066B5476d714431fa525; TREAS=0xb6768f8D1b1df86bD92a8bAE78202F797dAbb787
DEP=0x7185d50557040047A142aEadA95e41C4b31720e7
U=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266   # anvil dev account 0 (public test key)
PMBAL=$(cast call $USDC "balanceOf(address)(uint256)" $PM --rpc-url $R | cut -d' ' -f1)
cast rpc anvil_setCode $USDC $(python3 -c "import json;print(json.load(open('out/MockUSDC.sol/MockUSDC.json'))['deployedBytecode']['object'])") --rpc-url $R >/dev/null
cast send $USDC "setBalance(address,uint256)" $PM $PMBAL --unlocked --from $U --rpc-url $R >/dev/null
cast send $USDC "setBalance(address,uint256)" $U 1000000000 --unlocked --from $U --rpc-url $R >/dev/null
cast rpc anvil_setBalance $DEP 0x56BC75E2D63100000 --rpc-url $R >/dev/null
# 2) v1 buy (old lock) before the hook moves to v2
cast send $USDC "approve(address,uint256)" $V1 $(cast max-uint) --unlocked --from $U --rpc-url $R >/dev/null
cast send $V1 "swapExactIn(bool,uint256,uint256)" true 1000000 1 --unlocked --from $U --rpc-url $R >/dev/null
echo "v1 locks: $(cast call $V1 'getLocks(address)((uint128,uint64)[])' $U --rpc-url $R)"
# 3) deploy v2 as the deployer (impersonated), constructor per DeploySaviorStakingV2.s.sol
cast rpc anvil_impersonateAccount $DEP --rpc-url $R >/dev/null
BC=$(python3 -c "import json;print(json.load(open('v2.json'))['bytecode'])")
ARGS=$(cast abi-encode "c(address,address,address,address,(address,address,uint24,int24,address))" $DEP $TOKEN $PM $TREAS "($USDC,$TOKEN,10000,200,$HOOK)")
V2=$(cast send --unlocked --from $DEP --rpc-url $R --create ${BC}${ARGS#0x} --json | python3 -c "import json,sys;print(json.load(sys.stdin)['contractAddress'])")
echo "V2=$V2"
# 4) wire hook to v2 (as WireHook.s.sol does)
cast send --unlocked --from $DEP $HOOK "setStakingContract(address)" $V2 --rpc-url $R >/dev/null
echo "hook staking -> $(cast call $HOOK 'stakingContract()(address)' --rpc-url $R)"
echo "v2 fee bps $(cast call $V2 'TREASURY_FEE_BPS()(uint256)' --rpc-url $R)  key $(cast call $V2 'key()(address,address,uint24,int24,address)' --rpc-url $R | tr '\n' ' ')"
echo $V2 > v2addr
