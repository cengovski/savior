# $SAVIOR

SAVIOR is an experimental meme token on **Arc Mainnet**, the stablecoin-native chain where USDC is the gas token. It trades in a Uniswap V4 pool (SAVIOR / USDC) guarded by a custom hook. Half of every buy goes to the buyer right away and the other half is locked for 5 to 10 days. Buys of 10 USDC or more also get a chance to win a Savior Weapons NFT.

- App: https://cengovski.github.io/savior
- Docs: https://cengovski.github.io/savior/docs/
- NFT collection: https://opensea.io/collection/0xf9cedaa96278462f9b85adfbb4ea0bdfc38f383c

> SAVIOR is an experimental meme token. Nothing here is financial advice. The contracts have not been formally audited, prices can go to zero, and you should only use funds you can afford to lose.

## Network

| | |
|---|---|
| Network | Arc Mainnet |
| Chain ID | 5042 |
| RPC | https://rpc.mainnet.arc.io |
| Explorer | https://explorer.arc.io |
| Gas token | USDC |

## Token

| | |
|---|---|
| Name / symbol | SAVIOR / SAVIOR |
| Address | [`0x4A939085A36B4faB5D222b196619C0CdBdd6A022`](https://explorer.arc.io/address/0x4A939085A36B4faB5D222b196619C0CdBdd6A022) |
| Supply | 1,000,000,000 SAVIOR, fixed (minted once at deployment, no mint function) |
| Decimals | 6 |
| Logo | Stored on-chain (`logoURI`), can be updated by the owner |
| Ownership | `Ownable2Step` (two-step transfer). Ownership cannot be renounced. |
| Permit | Not supported (no EIP-2612 `permit`) |

The token is a plain ERC-20 with `burn` for holders. The owner cannot mint, change balances or move user funds. The only owner functions are updating the logo and rescuing other tokens sent to the token contract by mistake (never SAVIOR itself).

## How it works

All swaps go through the staking contract. The hook rejects any swap in the SAVIOR pool that does not come from it, so the rules below always apply in this pool.

### Buying

1. You pay USDC and the pool swaps it for SAVIOR.
2. 0.3% of the SAVIOR output goes to the treasury.
3. Of the rest, **50% goes to your wallet immediately** and **50% is locked** in the staking contract.

### Locks and reveal

- A new lock is set to unlock **10 days** after the buy.
- The lock uses commit-reveal randomness. A few blocks after the buy (about 2 seconds) a reveal window opens and stays open for about **70 minutes** (8,191 blocks, the EIP-2935 block hash history window).
- Revealing inside the window gives the lock a random duration of **5 to 10 days** from the buy. A reveal can only shorten the lock, never extend it.
- If nobody reveals in time, the lock simply stays at 10 days.
- Anyone can reveal any pending lock. The app has a **Reveal all** button that reveals everyone's pending locks in batches of up to 25.
- When a lock has expired, claim it with **Claim** in the app. Unlocked positions never expire, so you can claim any time.
- You can also lock SAVIOR you already hold with `stake` (minimum 1 SAVIOR). Staking on behalf of another wallet requires at least 100,000 SAVIOR. Staked locks follow the same reveal rules.

### Selling

Selling sends SAVIOR and returns USDC. Sells are not locked, and 0.3% of the USDC output goes to the treasury. Selling in the same block as your own buy is not allowed.

### Slippage protection

Every swap must set a nonzero minimum output. A swap with a minimum of zero reverts with `ZeroMinOut`, and a swap that would return less than the minimum reverts. The app computes the minimum from your slippage setting (default 0.5%).

### Fees

| Fee | Amount | Goes to |
|---|---|---|
| Pool fee | 1% | Liquidity providers |
| Hook fee | 0.3% of the swap output | Treasury |
| Gas | Paid in USDC, usually cents | Network |

### Emergency unlock

The staking owner can unlock all locks at once only through a **48-hour timelock**: the unlock must be scheduled first, can be cancelled at any time during the delay, and can only be executed after 48 hours. Its status is public on-chain (`emergencyUnlockStatus`). The owner can never take locked SAVIOR; rescue of SAVIOR is limited to any surplus above the total locked amount.

## Savior Weapons NFT

- Collection: Savior Weapons, an OpenSea SeaDrop drop with a **max supply of 1,111**.
- The collection is locked down so that only the Lucky NFT distributor can mint.
- **How to win:** buy SAVIOR for at least 10 USDC (counted as the USDC actually spent in the swap), then reveal the lock inside the reveal window. Each eligible reveal has a **5% chance** to win.
- A win is always reserved for the wallet that owns the lock, even if someone else pressed reveal. Claim it with **Claim NFT** in the app.
- No reveal in time means no draw for that lock. Locks created with `stake` are not eligible.
- The NFTs will be part of a future game funded by the treasury. Coming soon.

## Contracts (Arc Mainnet)

| Contract | Address |
|---|---|
| SAVIOR token | [`0x4A939085A36B4faB5D222b196619C0CdBdd6A022`](https://explorer.arc.io/address/0x4A939085A36B4faB5D222b196619C0CdBdd6A022) |
| Staking (swap, lock, reveal, claim) | [`0xFFaed084D0186FA96138d523f9292Fd4e47Dad63`](https://explorer.arc.io/address/0xFFaed084D0186FA96138d523f9292Fd4e47Dad63) |
| Uniswap V4 hook | [`0x813bdb7A1d4594B794ed9Df9Fad8A93f3873A080`](https://explorer.arc.io/address/0x813bdb7A1d4594B794ed9Df9Fad8A93f3873A080) |
| Factory (deployer) | [`0x5fC43F5078Ad4052E3B4A79aa0fC4BC5e5dF9b7c`](https://explorer.arc.io/address/0x5fC43F5078Ad4052E3B4A79aa0fC4BC5e5dF9b7c) |
| Lucky NFT distributor | [`0x54713bd7f1B6c23eCe81A2F334E247789A569c5e`](https://explorer.arc.io/address/0x54713bd7f1B6c23eCe81A2F334E247789A569c5e) |
| Savior Weapons NFT | [`0xf9cEdaA96278462f9b85ADfbB4ea0Bdfc38f383c`](https://explorer.arc.io/address/0xf9cEdaA96278462f9b85ADfbB4ea0Bdfc38f383c) |
| Treasury | [`0xb6768f8D1b1df86bD92a8bAE78202F797dAbb787`](https://explorer.arc.io/address/0xb6768f8D1b1df86bD92a8bAE78202F797dAbb787) |
| Uniswap V4 PoolManager | [`0x8366a39CC670B4001A1121B8F6A443A643e40951`](https://explorer.arc.io/address/0x8366a39CC670B4001A1121B8F6A443A643e40951) |
| USDC on Arc | [`0x3600000000000000000000000000000000000000`](https://explorer.arc.io/address/0x3600000000000000000000000000000000000000) |

Always check addresses on the explorer before approving anything.

## Pool

| | |
|---|---|
| Pair | USDC / SAVIOR (USDC is currency0) |
| Pool ID | `0x8946abd242378490313560cdf60e13902ca24d84add48f0f223bc26de5bb145f` |
| Fee | 1% (`10000`) |
| Tick spacing | 200 |
| Hook | `0x813bdb7A1d4594B794ed9Df9Fad8A93f3873A080` |
| Liquidity | 20-position SAVIOR liquidity ladder |

The hook has no owner and no proxy. It lets only the factory initialize this one pool key, and only the staking contract can swap in it. The token itself has no transfer restrictions, so the 50/50 split and locks apply to swaps in this pool, which is the pool the app uses.

## Bridge USDC to Arc

The app includes a Bridge section that moves native USDC from Ethereum, Base, Arbitrum, OP Mainnet, Avalanche, Polygon PoS, Linea or Unichain to Arc with Circle CCTP (Arc is CCTP domain 26), using Circle Bridge Kit in your browser. Your wallet signs every step.

## Repository

| Branch | Contents |
|---|---|
| `gh-pages` | The published site at https://cengovski.github.io/savior |
| `feature/phase1` | Source of the published site |
| `feature/lucky-nft` | Contract sources (`staking-v2/src/fresh/`) and Foundry tests |

The files at the root of this branch are not the published site. See `gh-pages` for what is live.

## Risks

- You can lose everything. The price can drop to zero.
- Smart contracts can have bugs. They have not been formally audited.
- Half of every buy is locked for up to 10 days and cannot be sold until it is claimed, even if the price falls.
- Liquidity is small, so prices move sharply and large sells may not be possible.
- Bridging relies on Circle CCTP and the source chain. Delays or outages can hold up a transfer.
- Arc is a new network. Public RPC endpoints can be slow or rate-limited.
- Never share your seed phrase and always check what you sign.

## License

MIT
