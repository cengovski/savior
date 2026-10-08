# Savior Project — Deployed Contracts

## Arc Mainnet (Chain ID: 5042)
RPC: https://rpc.mainnet.arc.io
Explorer: https://explorer.arc.io

### Current Deployment (ACTIVE)
| Contract | Address |
|----------|---------|
| SaviorToken (proxy) | 0x80999297169de61D0C02ada180e6b92440f77770 |
| SaviorHook (proxy, 0xC0 flags) | 0x33139589A270bec9BD940512ba6d422DA22a00C0 |
| SaviorStaking (proxy) | 0xC3F106BEAC49bC93130379a03f67B0D725865B51 |
| PoolManager | 0x8366a39CC670B4001A1121B8F6A443A643e40951 |
| Treasury | 0xb6768f8D1b1df86bD92a8bAE78202F797dAbb787 |
| USDC (native) | 0x3600000000000000000000000000000000000000 |

### Pool Config
- fee: 10000 (1%)
- tickSpacing: 200
- Initial price: 1:1 (sqrtPriceX96 = 2^96)
- Liquidity bands: 5 × 200M SAVIOR @ tick 0→200, 200→400, 400→600, 600→800, 800→1000

### Deployer
0x7185d50557040047A142aEadA95e41C4b31720e7

### Verified swap TX
0x57575d96435d7d4eef88337a3e2c97d1cb051784631eb159621d7752708281bf

## Frontend
GitHub Pages: https://cengovski.github.io/savior/
Admin: https://cengovski.github.io/savior/admin.html
Password: paX@whJXLI9*AYtuPMaeL
