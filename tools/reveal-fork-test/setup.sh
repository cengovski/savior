#!/usr/bin/env bash
# Fork setup for the fresh-start UI test (anvil fork of Arc mainnet, NOTHING is sent to mainnet).
# Usage: LUCKY=/path/to/feature-lucky-nft-checkout PORT=8601 tools/reveal-fork-test/setup.sh
# Needs foundry, a checkout of feature/lucky-nft with lib/ (forge-std, openzeppelin), and tools/v2-fork-test/MockUSDC.sol.
set -euo pipefail
PORT=${PORT:-8601}; R=http://127.0.0.1:$PORT; HERE=$(cd "$(dirname "$0")" && pwd)
USDC=0x3600000000000000000000000000000000000000; PM=0x8366a39CC670B4001A1121B8F6A443A643e40951
DEP=0x7185d50557040047A142aEadA95e41C4b31720e7; U0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
H2935=0x0000F90827F1C53a10cb7A02335B175320002935
anvil --fork-url https://rpc.mainnet.arc.io --chain-id 5042 --port $PORT --hardfork prague --silent >/tmp/anvil$PORT.log 2>&1 &
sleep 8
# Arc USDC is a precompile-backed token: replace it with a mintable mock on the fork, keep the PoolManager balance.
PMBAL=$(cast call $USDC "balanceOf(address)(uint256)" $PM --rpc-url $R | cut -d' ' -f1)
M=$(mktemp -d); mkdir -p $M/src; cp "$HERE/../v2-fork-test/MockUSDC.sol" $M/src/; ( cd $M && forge build --root $M -q )
cast rpc anvil_setCode $USDC "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['deployedBytecode']['object'])" $M/out/MockUSDC.sol/MockUSDC.json)" --rpc-url $R >/dev/null
cast send $USDC "setBalance(address,uint256)" $PM $PMBAL --unlocked --from $U0 --rpc-url $R >/dev/null
# EIP-2935 history storage: write all 8191 ring slots locally once, so mining thousands of blocks does not make anvil
# fetch each slot from the public RPC (429). Only pre-fork history is lost, which this test does not use.
python3 - "$R" "$H2935" <<'PY'
import json, sys, urllib.request
r, a = sys.argv[1], sys.argv[2]
for s in range(0, 8191, 1000):
    batch = [{"jsonrpc": "2.0", "id": i, "method": "anvil_setStorageAt", "params": [a, hex(i), "0x" + "00" * 32]} for i in range(s, min(s + 1000, 8191))]
    urllib.request.urlopen(urllib.request.Request(r, json.dumps(batch).encode(), {"Content-Type": "application/json"})).read()
PY
cast rpc anvil_setBalance $DEP 0x56BC75E2D63100000 --rpc-url $R >/dev/null; cast rpc anvil_impersonateAccount $DEP --rpc-url $R >/dev/null
echo "DEPLOY_BLOCK=$(cast block-number --rpc-url $R)"
cp "$HERE/ForkSetup.s.sol" "$LUCKY/staking-v2/script/fresh/ForkSetup.s.sol"
( cd "$LUCKY/staking-v2" && forge script script/fresh/ForkSetup.s.sol --rpc-url $R --unlocked --sender $DEP --broadcast --slow 2>&1 | grep -E "^  [A-Z_0-9]+ |ONCHAIN" )
