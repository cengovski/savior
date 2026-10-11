set -e
export PATH=$HOME/.foundry/bin:$PATH
R=http://127.0.0.1:8545; USDC=0x3600000000000000000000000000000000000000; PM=0x8366a39CC670B4001A1121B8F6A443A643e40951; DEP=0x7185d50557040047A142aEadA95e41C4b31720e7; U=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
cast rpc anvil_reset '{"forking":{"jsonRpcUrl":"https://rpc.mainnet.arc.io"}}' --rpc-url $R >/dev/null
PMBAL=$(cast call $USDC "balanceOf(address)(uint256)" $PM --rpc-url $R | cut -d' ' -f1)
cast rpc anvil_setCode $USDC $(python3 -c "import json;print(json.load(open('/tmp/fsfork/out/MockUSDC.sol/MockUSDC.json'))['deployedBytecode']['object'])") --rpc-url $R >/dev/null
cast send $USDC "setBalance(address,uint256)" $PM $PMBAL --unlocked --from $U --rpc-url $R >/dev/null
cast send $USDC "setBalance(address,uint256)" $U 100000000000 --unlocked --from $U --rpc-url $R >/dev/null
cast rpc anvil_setBalance $DEP 0x56BC75E2D63100000 --rpc-url $R >/dev/null
cast rpc anvil_impersonateAccount $DEP --rpc-url $R >/dev/null
echo "fork ready at block $(cast block-number --rpc-url $R)"
