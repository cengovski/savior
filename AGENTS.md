# SAVIOR: project facts for contributors and AI agents

Keep this file free of secrets. Never commit credentials, private keys or seed phrases.

## Network
- Arc Mainnet, chain ID 5042
- RPC: https://rpc.mainnet.arc.io
- Explorer: https://explorer.arc.io
- Gas token: USDC

## Contracts
| Contract | Address |
|----------|---------|
| SaviorTokenV2 | 0x4A939085A36B4faB5D222b196619C0CdBdd6A022 |
| Staking | 0xFFaed084D0186FA96138d523f9292Fd4e47Dad63 |
| Uniswap V4 hook | 0x813bdb7A1d4594B794ed9Df9Fad8A93f3873A080 |
| Factory (FreshDeployer) | 0x5fC43F5078Ad4052E3B4A79aa0fC4BC5e5dF9b7c |
| LuckyDistributor | 0x54713bd7f1B6c23eCe81A2F334E247789A569c5e |
| Savior Weapons NFT | 0xf9cEdaA96278462f9b85ADfbB4ea0Bdfc38f383c |
| Treasury | 0xb6768f8D1b1df86bD92a8bAE78202F797dAbb787 |
| Uniswap V4 PoolManager | 0x8366a39CC670B4001A1121B8F6A443A643e40951 |
| USDC (native) | 0x3600000000000000000000000000000000000000 |

## Pool
- Pool ID: 0x8946abd242378490313560cdf60e13902ca24d84add48f0f223bc26de5bb145f
- Fee: 10000 (1%), tick spacing 200, USDC is currency0
- 20-position SAVIOR liquidity ladder

## Mechanics
- Token: 1B fixed supply, 6 decimals, on-chain logo, Ownable2Step, ownership cannot be renounced, no permit.
- Buys: 50% of the SAVIOR goes to the buyer, 50% is locked. Hook fee is 0.3% of the swap output, sent to the treasury.
- Locks start at 10 days. Commit-reveal inside a window of about 70 minutes (EIP-2935) gives a random 5 to 10 days. A reveal can only shorten a lock. Anyone can reveal; Reveal all handles up to 25 per batch.
- Swaps need a nonzero minimum output (`ZeroMinOut`).
- Emergency unlock is behind a 48-hour cancellable timelock.
- Site: personal Reveal section below Swap (pending locks, countdowns, Reveal and Reveal all) and a reveal reminder after each buy.
- Bridge: Circle Bridge Kit (CCTP V2) from 24 EVM source chains to Arc, chain dropdown, automatic wallet network switching, WalletConnect (Reown) supports all of them.
- Lucky NFT: buys of at least 10 USDC have a 5% chance at reveal to win a Savior Weapons NFT (max 1,111), claimed with Claim NFT.

## Branches
- `feature/phase1`: site source
- `gh-pages`: published static output, served at https://arcsavior.trade
- `feature/lucky-nft`: contract sources (`staking-v2/src/fresh/`)
- `main`: README and documentation. Other files at the root are not part of the live site.
