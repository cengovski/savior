# SAVIOR/USDC V4 liquidity rescue + 20-tranche ladder

## Positions found (Arc mainnet)

All liquidity is in **5 PoolManager positions** owned by legacy proxy `0x61096C5850d492530524c14c0602757f1d9d3c95` (salt 0). **No PositionManager NFTs.**

| tickLower | tickUpper | liquidity | added by |
|-----------|-----------|-----------|----------|
| 121000 | 121200 | 46938400481114 | deployer via proxy `addLiquidity` |
| 121200 | 121400 | 46471378826914 | same |
| 121400 | 121600 | 46009003884643 | same |
| 121600 | 121800 | 45551229421047 | same |
| 121800 | 122000 | 45098009662873 | same |

Sender in `ModifyLiquidity` events = proxy; txs signed by deployer `0x7185…20e7`.

## Withdraw blocker (critical)

Legacy proxy `owner()` (slot 9) = `address(0)` (renounced). Current impl `upgradeToAndCall` checks slot 9 → **NotOwner**. ERC-7201 Ownable slot still holds deployer but is unused by the live impl. Mainnet cannot send from `address(0)`, so UUPS rescue is currently impossible without an external ownership restore.

Rescue path (once owner is deployer again):

1. Deploy `LiquidityRescue`
2. `legacy.upgradeToAndCall(rescue, abi.encodeCall(withdrawAllAndRestore, (lowers, uppers)))`
3. Rescue removes all 5 ranges, `take`s USDC+SAVIOR to deployer, restores impl `0x954f…5C83`

## 20-tranche ladder (after withdraw)

Equal SAVIOR tranches in consecutive single-sided (currency1 / SAVIOR-only) ranges from tick 121800 down to 86600 (16×1800 + 4×1600). Buying ALL SAVIOR through staking v2 costs **~50,045 USDC gross** (includes 1% pool fee; 0.3% treasury is taken from SAVIOR out, not USDC in).

Fork E2E (`ARC_FORK=true forge test --match-contract LiquidityLadderFork -vv`): rescue (with `prank(0)` ownership cheat) → ladder → `swapExactIn` buyout ≈ 50,044.52 USDC.
