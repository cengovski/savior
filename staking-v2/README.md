# SaviorStakingV2

Non-upgradeable, Ownable2Step replacement for the lock/claim logic of the live SaviorStaking
(`0xBCA651C0A0540a1fCDef066B5476d714431fa525`, Arc Mainnet 5042). See PR description for the
bytecode-reconstructed v1 interface and the migration plan.

```sh
# deps (lib/ is gitignored at repo root)
cd .. && git clone --depth 1 -b v1.17.0 https://github.com/foundry-rs/forge-std lib/forge-std
git clone --depth 1 -b v5.1.0 https://github.com/OpenZeppelin/openzeppelin-contracts lib/openzeppelin-contracts
cd staking-v2
forge test                                         # unit tests
ARC_FORK=true forge test --match-contract ArcFork  # fork tests vs https://rpc.mainnet.arc.io
```

Arc: chainId 5042, RPC https://rpc.mainnet.arc.io, gas token native USDC (18 decimals natively,
ERC-20 interface `0x3600…0000` with 6 decimals), explorer Blockscout https://explorer.arc.io
(`--verifier blockscout --verifier-url https://explorer.arc.io/api/`).
Uniswap v4 on Arc: see `src/ArcAddresses.sol`. The v2 staking contract itself does not interact with v4.

## Buy & lock (swapExactIn) and hook wiring

`swapExactIn(bool zeroForOne, uint256 amountIn, uint256 minOut, uint256 deadline)` (deadline added after audit D-3, so the selector differs from v1's 0x1d2105ba) reproduces the v1 flow observed on an Arc fork trace:
pull tokenIn, `PoolManager.unlock`, exact-in swap on the SAVIOR/USDC pool (fee 10000, tickSpacing 200, hook 0xFfcf…60c0),
0.3% of the output to treasury, on buys the net SAVIOR is split 50% to the buyer and 50% locked for a pseudo-random 5 to 10 days: 432000 + keccak256(abi.encode(blockhash(n-1), user, msg.sender, userLockNonce, globalLockNonce)) % 432001 s. v1 also mixed in the swap output, which let callers grind by picking the amount (audit D-1); that input was removed.
Selling in the same block as your last buy reverts `SameBlock()`, slippage/zero amount reverts `Bad()` (same selectors as v1).

The hook's `beforeSwap` only accepts swaps whose sender is `hook.stakingContract()` (reverts `OnlyStaking()` 0x3d704762).
The hook proxy (UUPS, impl 0xaee9…2bd9, owner = deployer) already has `setStakingContract(address)` (0x9dd373b9),
so wiring v2 is a single owner call, no new hook implementation needed. Once wired, v1 can no longer swap,
but v1 `claim()` keeps working. Simulate with `STAKING_V2=0x… forge script script/WireHook.s.sol --rpc-url arc_mainnet`.

`artifacts/SaviorStakingV2.json` holds the ABI + creation bytecode used by the admin panel migration wizard.
Constructor: `(address initialOwner, address savior, address poolManager, address treasury, (address,address,uint24,int24,address) key)`.

Fork tests mock Arc's native-USDC precompiles (0x1800…00 transfer, 0x1800…01 blocklist) locally because foundry's EVM lacks them.

## Audit fixes (/workspace/audit-v2/RAPOR.md)
- D-1 lock seed without caller-chosen amount (nonces instead). Residual: not secure randomness, a block producer or a caller who only submits in a favourable block can still bias within 5 to 10 days.
- D-2 `MIN_STAKE = 1e6` (1 SAVIOR, 6 decimals) for `stake`/`stakeFor`; dust spam now costs real SAVIOR (which goes to the victim).
- D-3 `deadline` on `swapExactIn`, `Expired()` after it.
- D-4 fork tests `vm.skip` when `ARC_FORK` is unset (shown as skipped, not green).
- `test/AuditPoC.t.sol`: auditor PoCs; the two exploit PoCs (grind, dust spam) now fail against the fixed code and are rewritten to assert the fix.
