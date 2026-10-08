#!/bin/bash
# Savior Protocol — Tam Otomatik Deploy + Test
# Kullanım: bash script/AutoDeploy.sh <PRIVATE_KEY>
# Örnek:    bash script/AutoDeploy.sh 0x44ed77cc...

set -e
PK=${1:-$PRIVATE_KEY}
RPC=https://rpc.mainnet.arc.io
PM=0x8366a39CC670B4001A1121B8F6A443A643e40951
TREASURY=0xb6768f8D1b1df86bD92a8bAE78202F797dAbb787
OWNER=0x7185d50557040047A142aEadA95e41C4b31720e7
USDC=0x3600000000000000000000000000000000000000
CREATE2=0x4e59b44847b379578588920cA78FbF26c0B4956C

if [ -z "$PK" ]; then echo "PRIVATE_KEY gerekli"; exit 1; fi

log() { echo -e "\n\033[1;32m>>> $1\033[0m"; }
fail() { echo -e "\n\033[1;31mHATA: $1\033[0m"; exit 1; }

send() { # send <to> <sig> [args...] [--value V]
  cast send "$@" --rpc-url $RPC --private-key $PK --legacy --gas-limit 3000000 2>&1
}

SAVIOR_MINT=1000000000000000  # 1B × 10^6

cd /root/savior

log "1/9 forge build"
forge build 2>&1 | tail -2

log "2/9 SaviorToken impl deploy"
TK_IMPL=$(forge create contracts/SaviorToken.sol:SaviorToken \
  --rpc-url $RPC --private-key $PK --legacy --broadcast 2>&1 | grep "Deployed to:" | awk '{print $3}')
[ -z "$TK_IMPL" ] && fail "Token impl deploy başarısız"
echo "Token impl: $TK_IMPL"

log "3/9 SaviorToken proxy (CREATE2 salt mine)"
PROXY_BC=$(cat out/ERC1967Proxy.sol/ERC1967Proxy.json | python3 -c "import sys,json; print(json.load(sys.stdin)['bytecode']['object'][2:])")
INIT_DATA="c4d66de8$(printf '%064x' 0)${OWNER:2}" # initialize(owner)
TK_PROXY=$(python3 << PYEOF
import hashlib, json, subprocess

factory = bytes.fromhex("4e59b44847b379578588920cA78FbF26c0B4956C")
target  = bytes.fromhex("3600000000000000000000000000000000000000")
impl    = bytes.fromhex("${TK_IMPL:2}")
init    = bytes.fromhex("c4d66de8" + "0"*24 + "${OWNER:2}".lower())

data = json.load(open("out/ERC1967Proxy.sol/ERC1967Proxy.json"))
proxy_bc = bytes.fromhex(data["bytecode"]["object"].lstrip("0x"))

def abi_enc(impl_addr, init_bytes):
    addr_padded = b'\x00'*12 + impl_addr
    offset = (64).to_bytes(32, 'big')
    length = len(init_bytes).to_bytes(32, 'big')
    padded = init_bytes + b'\x00' * ((32 - len(init_bytes) % 32) % 32)
    return addr_padded + offset + length + padded

initcode = proxy_bc + abi_enc(impl, init)
initcode_hash = hashlib.sha3_256(initcode).digest()
initcode_hex = initcode.hex()

for i in range(10_000_000):
    salt = i.to_bytes(32, 'big')
    h = hashlib.sha3_256(b'\xff' + factory + salt + initcode_hash).digest()
    if h[12:] < target:
        # Write initcode to temp file
        open('/tmp/token_initcode.hex','w').write(initcode_hex)
        open('/tmp/token_salt.txt','w').write(str(i))
        print(f"0x{h[12:].hex()}")
        break
PYEOF
)
[ -z "$TK_PROXY" ] && fail "Salt mine başarısız"
echo "Token proxy (predicted): $TK_PROXY"
SALT=$(cat /tmp/token_salt.txt)
SALT_HEX=$(python3 -c "print(hex($SALT).zfill(64))")

# Deploy via CREATE2
DEPLOY_TX=$(cast send $CREATE2 \
  "0x${SALT_HEX}$(cat /tmp/token_initcode.hex)" \
  --rpc-url $RPC --private-key $PK --legacy --gas-limit 3000000 2>&1)
echo "$DEPLOY_TX" | grep -E "status|Error" | head -2

# Verify
CODE=$(cast code $TK_PROXY --rpc-url $RPC | wc -c)
[ "$CODE" -lt 10 ] && fail "Token proxy deploy başarısız"
echo "Token proxy deployed: $TK_PROXY"

log "4/9 SaviorHook deploy (HookMiner)"
forge script script/DeployContracts.s.sol \
  --rpc-url $RPC --private-key $PK --broadcast --skip-simulation --legacy 2>&1 \
  | grep -E "TOKEN:|HOOK:|STAKING:|DONE|Error" | head -10

# Adresleri broadcast dosyasından oku
BROADCAST=$(cat broadcast/DeployContracts.s.sol/5042/run-latest.json 2>/dev/null)
HK_PROXY=$(echo "$BROADCAST" | python3 -c "
import sys,json
d=json.load(sys.stdin)
txs=[t for t in d.get('transactions',[]) if t.get('contractName')=='ERC1967Proxy']
print(txs[1]['contractAddress'] if len(txs)>1 else '')
" 2>/dev/null)
ST_PROXY=$(echo "$BROADCAST" | python3 -c "
import sys,json
d=json.load(sys.stdin)
txs=[t for t in d.get('transactions',[]) if t.get('contractName')=='ERC1967Proxy']
print(txs[2]['contractAddress'] if len(txs)>2 else '')
" 2>/dev/null)

echo "Hook proxy: $HK_PROXY"
echo "Staking proxy: $ST_PROXY"

log "5/9 Pool initialize (fee=100, tickSpacing=1)"
send $PM "initialize((address,address,uint24,int24,address),uint160)" \
  "($USDC,$TK_PROXY,100,1,$HK_PROXY)" \
  79228162514264337593543950336 2>&1 | grep -E "status|PoolAlready"

log "6/9 Pool key set"
send $ST_PROXY "setPoolKey((address,address,uint24,int24,address))" \
  "($USDC,$TK_PROXY,100,1,$HK_PROXY)" 2>&1 | grep status

log "7/9 SAVIOR approve + mint"
send $TK_PROXY "approve(address,uint256)" $ST_PROXY \
  115792089237316195423570985008687907853269984665640564039457584007913129639935 2>&1 | grep status
send $TK_PROXY "mint(address,uint256)" $OWNER $SAVIOR_MINT 2>&1 | grep status

log "8/9 USDC transfer to staking + addLiquidity"
# Transfer 200k USDC ERC-20 to staking
cast send $USDC "transfer(address,uint256)" $ST_PROXY 500000 \
  --rpc-url $RPC --private-key $PK --legacy 2>&1 | grep status
# Transfer SAVIOR to staking
send $TK_PROXY "transfer(address,uint256)" $ST_PROXY 500000 2>&1 | grep status

# L for tick -1→1, fee=100 at price=1 with 200k USDC (6dec)
L=$(python3 -c "
import math; Q96=2**96
sl=int(math.sqrt(1.0001**(-1))*Q96); su=int(math.sqrt(1.0001**(1))*Q96); sc=Q96
usdc=200000
L=usdc*su*sc//((su-sc)*Q96)
print(L)
")
echo "Liquidity L=$L"

send $ST_PROXY "addLiquidity(uint128,int24,int24)" $L -1 1 \
  --value 0 2>&1 | grep -E "status|Error"

log "9/9 Swap test: 0.1 USDC"
SWAP_TX=$(cast send $ST_PROXY "buy(uint256,uint256)" 0 500 \
  --rpc-url $RPC --private-key $PK --legacy --gas-limit 3000000 \
  --value 100000000000000000 2>&1)
echo "$SWAP_TX" | grep -E "status|transactionHash"

echo ""
echo "========================================"
echo " SAVIOR PROTOCOL DEPLOY TAMAMLANDI"
echo "========================================"
echo " SaviorToken:   $TK_PROXY"
echo " SaviorHook:    $HK_PROXY"
echo " SaviorStaking: $ST_PROXY"
echo " Pool:          fee=100, tickSpacing=1"
echo "========================================"

# Save addresses
cat > /root/savior/deployed-addresses.json << EOF2
{
  "token": "$TK_PROXY",
  "hook": "$HK_PROXY",
  "staking": "$ST_PROXY",
  "poolFee": 100,
  "poolTickSpacing": 1
}
EOF2
