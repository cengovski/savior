# Fresh start plan — new SAVIOR token + new V4 pool (Arc)

**Status:** PLAN ONLY. No mainnet deploy, no tx, no keys.  
**Branch:** `feature/fresh-start` (from `feature/staking-v2`)  
**Date:** 2026-10-11 (Europe/Istanbul)  
**Owner decision (Dzengo):** clean restart; old pool LP is unrecoverable.

---

## 0) Executive recommendations

| Topic | Recommendation |
|-------|----------------|
| Token | New non-upgradeable ERC-20, **1B fixed supply**, **6 decimals**, mint once in constructor to deployer, `burn` allowed, **no** Ownable/rescue that can move the token |
| Hook | **New hook** (source in repo, CREATE2 flag mining). Do **not** reuse `0xFfcf…60c0` |
| Staking | Redeploy **`SaviorStakingFresh`** (v2 semantics + commit-reveal locks) with immutables = new token + new PoolKey + same treasury/deployer patterns (audit fixes D-1..D-4 kept). Live `SaviorStakingV2` on `feature/deployed-v2` unchanged. |
| Liquidity | **20-tranche SAVIOR-only ladder** via **PositionManager NFTs** owned by deployer; target **~50k USDC gross** to buy out all pool SAVIOR (incl. 1% pool fee) |
| Start price | **~5e-6 USDC per SAVIOR** (tick ≈ 122000), matching current market shape so the ladder math stays familiar |
| Old stack | Deprecate in site/config; do **not** attempt stuck-LP rescue; optional burn-to-dead of deployer-held old SAVIOR; no airdrop required if all economic holders are Dzengo |

---


## Decisions recorded (Dzengo)

| Date | Decision |
|------|----------|
| 2026-10-11 | **Token rescue = option (a):** owner rescues **foreign ERC-20 + native only**; **never** own SAVIOR (`CannotRescueOwnToken`). `to != 0`, **Ownable2Step**, `Rescued` event. **No** EIP-2612 permit. |
| 2026-10-11 | **Logo:** `logoURI` + `setLogoURI` (**onlyOwner**), `LogoURIUpdated` (also emitted in ctor). Owner-updatable; ownership is **never renounced** (renounceOwnership reverts). Prefer `ipfs://` or data-URI (~3KB svg). Wallets mostly ignore contract field — also tokenlists / Trust / explorer / CoinGecko. |
| 2026-10-11 | Lock duration bias: current `blockhash(n-1)+nonce` seed is **grindable across blocks** (PoC `staking-v2/test/LockBiasPoC.t.sol`). Prefer **fixed 7 days** for fresh-start unless product needs jitter; else commit-reveal or D20DAO VRF on Arc. |
| 2026-10-11 | **Lock duration = commit-reveal 5–10 days, NO VRF.** Implemented in `staking-v2/src/fresh/SaviorStakingFresh.sol` (fresh-start only; does **not** change `feature/deployed-v2` / live SaviorStakingV2 semantics). `REVEAL_DELAY_BLOCKS = 3` (Arc sub-second finality). Fallback if `blockhash(target)==0` → 10 days. Tests: `CommitRevealLock.t.sol`. D20DAO VRF rejected (native `msg.value` fee, async fulfill, complexity). |

## Owner powers (token)

Decision 2026-10-11: ownership is **not** renounced; `renounceOwnership()` reverts (`RenounceDisabled`). Ownership moves only via Ownable2Step transfer + accept.

Owner CAN only:
1. `setLogoURI(string)` (emits `LogoURIUpdated`).
2. `rescue(token, to, amount)` for **foreign ERC-20 or native** (`to != 0`, `Rescued` event).

Owner CANNOT: mint (no mint function; supply minted once in constructor), move or burn any user's balance, change supply, rescue own SAVIOR (`CannotRescueOwnToken`), pause/blacklist/tax, upgrade (no proxy). Burn is holder-only on own balance.

**Lock duration (closed):** commit-reveal 5–10d on `SaviorStakingFresh` only — see Appendix + §6.3 UI notes.

## 1) New token design

### 1.1 Goals
- Simple, auditable, non-upgradeable.
- Entire supply controlled at genesis by deployer (for ladder + treasury allocation).
- Cannot brick holders via admin mint/blacklist/upgrade (unlike current UUPS token `0xe406…cAf3`).

### 1.2 Spec (proposed)

| Field | Value | Rationale |
|-------|-------|-----------|
| Name / symbol | SAVIOR / SAVIOR | Brand continuity |
| Decimals | **6** | Matches Arc USDC (6) and current SAVIOR; keeps amount UX identical |
| Total supply | **1_000_000_000 × 10^6** (1B) | Round; same order as today’s circulating-in-pool ~1B |
| Mint | **Once**, in `constructor(recipient)` | No `mint`, no minter role |
| Burn | `burn(uint256)` by holder | Optional supply reduction / deprecate leftovers |
| Upgrade | **None** (no proxy) | Avoids UUPS / renounce traps seen on legacy liquidity proxy |
| Ownable / rescue | **Ownable2Step** + `rescue` foreign ERC-20/native only (decision **a**); never `address(this)`; `to != 0` + `Rescued` | Mistaken SAVIOR sent to token contract stays stuck — accepted |
| logoURI | Owner-updatable via `setLogoURI` (`ipfs://` or data-URI); event on set | Wallets rarely read it |
| Permit | **None** (decided) | Keep surface minimal |
| Transfer tax / rebase | **None** | Staking and V4 assume vanilla ERC-20 |

### 1.3 Allocation (decision point)
Propose at genesis (constructor recipient = deployer, then manual splits):

| Bucket | % | Notes |
|--------|---|-------|
| Liquidity ladder | 100% initially on deployer, then ~100% into Posm ranges | Or reserve e.g. 5–10% treasury/ops before ladder |
| Treasury / ops | 0–10% (decision) | If non-zero, transfer before ladder; ladder sizing uses remainder |
| Team lock | optional | Prefer staking v2 locks rather than a second vest contract |

**Decision point A:** Ladder 100% of supply vs keep a treasury reserve (recommend **≤5%** treasury, **≥95%** ladder so buyout cost stays near 50k USDC).

### 1.4 Prototype
`staking-v2/src/fresh/SaviorTokenV2.sol` — minimal fixed-supply token for fork gas / integration tests. Not mainnet-final until auditor pass.

---

## 2) Hook: reuse vs new

### 2.1 Live hook `0xFfcf2eF82AA17Fb31F3618E0302F9adC92D060c0` (facts)

| Fact | Evidence |
|------|----------|
| Flags in address (`0x20c0`) | `beforeInitialize`, `beforeSwap`, `afterSwap` only — **no** liquidity hooks, **no** ReturnDelta |
| UUPS | ERC-1967 impl `0xaee9…2bd9`, owner = deployer |
| Storage | slot0 = PoolManager, slot1 = **single** `stakingContract` (now v2 `0x8807…39bB`) |
| Pool key / currencies | **Not stored**; `currency0/1` / `poolKey()` revert; no per-pool allowlist |
| `poolInitialised()` | Returns **false** (flag unused / never set). Address has **no** `afterInitialize` bit, so PoolManager never calls it |
| Swap gate | `beforeSwap`: sender must be `stakingContract` → `OnlyStaking()` (0x3d704762). Verified in fork tests |
| Repo source | `contracts/SaviorHook.sol` is a **stub** and does **not** match live impl (auditor B-1) |

### 2.2 Can one hook serve old + new pool?
**Technically yes for PoolManager** (no currency binding). **Practically no for product:**
- One `stakingContract` address: pointing it at new staking breaks old-pool swaps through old staking; pointing at old breaks new.
- Shared UUPS surface: a bad upgrade affects every pool using the hook.
- No verified source / no CREATE2 reproducibility for the live bytecode.

### 2.3 Recommendation: **deploy a new hook**

| Property | New hook |
|----------|----------|
| Permissions | Same flags as today: `beforeInitialize` + `beforeSwap` + `afterSwap` (bits `0x20c0` family) — keep LP free; keep OnlyStaking |
| Logic | Port live behavior: `OnlyStaking`; optional `afterSwap` no-op or events only (treasury fee stays in staking at 0.3%) |
| Auth | Prefer **non-upgradeable** hook if possible; if UUPS kept, document why + 2-step ownable + no renounce |
| Deploy | CREATE2 + HookMiner salt so address matches permission bits |
| Binding | Optional: store allowed `PoolId` in `beforeInitialize` (one-shot) so hook cannot be attached to surprise pools |

**Decision point B:** Hook upgradeability — recommend **immutable hook** (no UUPS) for fresh start; staking remains the upgrade-sensitive piece (and we already chose non-upgradeable staking v2).

**Decision point C:** If reusing old hook anyway (not recommended): `setStakingContract(newV2)` only after old site is fully deprecated; accept old pool permanently ungated/unusable via staking.

---

## 3) Redeploy staking v2

Reuse `SaviorStakingV2` design (audit D-1..D-4):

- Constructor immutables: `owner`, **new SAVIOR**, PoolManager, treasury, **new PoolKey** (USDC, newSAVIOR, fee 10000, tickSpacing 200, newHook).
- `swapExactIn(bool,uint256,uint256,uint256 deadline)` — buy: 50% wallet / 50% lock; 0.3% treasury from output; SameBlock sell guard; MIN_STAKE; hardened lock seed.
- Non-upgradeable; `rescue` cannot pull SAVIOR below `totalLocked`.
- Deploy script + admin wizard: update embedded bytecode/ABI/immutables; O-1 verify before `setStakingContract`.

Wire order: deploy token → deploy hook → deploy staking(key) → `hook.setStakingContract(staking)` (or ctor-set if immutable hook takes staking in constructor — prefer **setter once** or ctor immutable staking for stronger guarantees).

**Decision point D:** `stakingContract` mutable setter (current) vs immutable in hook constructor. Recommend **immutable staking in hook ctor** for fresh start (eliminates malicious re-wire). Tradeoff: replacing staking requires new hook+pool.

---

## 4) Liquidity — 20-tranche ladder (PositionManager NFTs)

### 4.1 Goals
- Deployer **can withdraw** (Posm ERC-721 owned by deployer) — avoid legacy salt=0 proxy trap.
- Single-sided **SAVIOR-only** ranges (token1 below price; USDC = token0).
- Buying **all** pool SAVIOR via staking ≈ **50,000 USDC gross** (includes **1%** pool fee). Staking 0.3% treasury is taken from SAVIOR out, not from USDC in.
- Same structure validated on fork for the old pool (`LiquidityLadderFork`: ~50,044 USDC).

### 4.2 Recommended start price
- **P0 ≈ 5×10⁻⁶ USDC / SAVIOR** → initialize near tick **122000** (spacing 200).
- Place ladder **at/below** current tick (SAVIOR-only): first upper tick **121800**, then down.
- Gap: leave a tiny empty band or start ladder at 122000–121800 so the first buy immediately hits liquidity.

### 4.3 Tick table (same widths as prior plan: 16×1800 + 4×1600)

Assume **1B SAVIOR** (6 dec) in ladder, equal tranches of **50M** each. Approximate USDC (net into pool / gross to staking):

| # | tickLower | tickUpper | start $/SAV | end $/SAV | USDC net | USDC gross | cum. gross |
|---|-----------|-----------|-------------|-----------|----------|------------|------------|
| 1 | 120000 | 121800 | 5.14e-6 | 6.15e-6 | ~281 | ~284 | ~284 |
| 2 | 118200 | 120000 | 6.15e-6 | 7.36e-6 | ~336 | ~340 | ~624 |
| 3 | 116400 | 118200 | 7.36e-6 | 8.81e-6 | ~403 | ~407 | ~1,030 |
| 4 | 114600 | 116400 | 8.81e-6 | 1.05e-5 | ~482 | ~487 | ~1,517 |
| 5 | 112800 | 114600 | 1.05e-5 | 1.26e-5 | ~577 | ~583 | ~2,100 |
| 6 | 111000 | 112800 | 1.26e-5 | 1.51e-5 | ~691 | ~698 | ~2,798 |
| 7 | 109200 | 111000 | 1.51e-5 | 1.81e-5 | ~827 | ~836 | ~3,634 |
| 8 | 107400 | 109200 | 1.81e-5 | 2.17e-5 | ~990 | ~1,000 | ~4,634 |
| 9 | 105600 | 107400 | 2.17e-5 | 2.59e-5 | ~1,186 | ~1,198 | ~5,832 |
| 10 | 103800 | 105600 | 2.59e-5 | 3.11e-5 | ~1,419 | ~1,434 | ~7,265 |
| 11 | 102000 | 103800 | 3.11e-5 | 3.72e-5 | ~1,699 | ~1,717 | ~8,982 |
| 12 | 100200 | 102000 | 3.72e-5 | 4.45e-5 | ~2,035 | ~2,055 | ~11,037 |
| 13 | 98400 | 100200 | 4.45e-5 | 5.33e-5 | ~2,436 | ~2,460 | ~13,497 |
| 14 | 96600 | 98400 | 5.33e-5 | 6.38e-5 | ~2,916 | ~2,946 | ~16,443 |
| 15 | 94800 | 96600 | 6.38e-5 | 7.64e-5 | ~3,491 | ~3,526 | ~19,969 |
| 16 | 93000 | 94800 | 7.64e-5 | 9.15e-5 | ~4,180 | ~4,222 | ~24,191 |
| 17 | 91400 | 93000 | 9.15e-5 | 1.07e-4 | ~4,954 | ~5,004 | ~29,195 |
| 18 | 89800 | 91400 | 1.07e-4 | 1.26e-4 | ~5,814 | ~5,872 | ~35,067 |
| 19 | 88200 | 89800 | 1.26e-4 | 1.48e-4 | ~6,822 | ~6,891 | ~41,959 |
| 20 | 86600 | 88200 | 1.48e-4 | 1.73e-4 | ~8,006 | ~8,087 | **~50,045** |

Top of ladder ≈ 5.14e-6; bottom ≈ 1.73e-4 USDC/SAVIOR.  
Recompute exactly after final supply-in-ladder is fixed (Decision A).

### 4.4 Mint path (Posm)
1. `SAVIOR.approve(Permit2, max)`
2. `Permit2.approve(SAVIOR, PositionManager, uint160.max, expiry)`
3. `PositionManager.modifyLiquidities`: 20× `MINT_POSITION` + `SETTLE_PAIR` (USDC, SAVIOR), deadline set.
4. Record 20 tokenIds; admin “Liquidity” tab lists/burns via DECREASE+BURN+TAKE_PAIR to deployer.

**Do not** use a custom proxy with salt=0 positions.

---

## 5) Old token / pool fate

| Asset | State | Action |
|-------|-------|--------|
| Old pool LP (proxy `0x6109…`, salt 0) | **Unrecoverable** (`owner()==0`) | Leave; document; ignore in UI |
| Old SAVIOR in PoolManager | ~999.93M stuck | Abandoned with pool |
| Old staking v2 locks | ~9.80M, owner = deployer | Claim after unlock or leave; optional burn after claim |
| Deployer old SAVIOR wallet | ~19.6k | Optional `transfer(0xdead)` / burn if token supports |
| Old dead proxy `0xa9bd…` | ~9.8k stuck | No action |
| Old hook / staking v1/v2 | Live but deprecated | Stop site routing; keep explorer links in docs |

**Holders:** Economic supply outside the stuck pool is essentially Dzengo-controlled (deployer wallet + deployer locks). **No public airdrop required.** Optional “1:1 swap old→new” is unnecessary complexity unless a non-Dzengo holder appears in a full Transfer scan before launch.

**Site:** Remove old token/pool addresses from `config.js`; label “SAVIOR (legacy, deprecated)”; do not deep-link Uniswap to the old pool.

---

## 6) Site / admin / config — coder bot checklist

### 6.1 Config / deployments
- [ ] New `deployments/arc-mainnet.json` section `freshStart` (token, hook, staking, poolKey, posm tokenIds, deploy block).
- [ ] `config.js`: `contracts.token`, `stakingV2`, `hook`, pool fee/ticks; remove or nest legacy under `legacy:`.
- [ ] gh-pages/main only after explicit Dzengo approve (out of scope for coder bots until then).

### 6.2 Admin (`feature/phase1` admin.html)
- [ ] Deploy wizard: TokenV2 → Hook (CREATE2 mine) → **SaviorStakingFresh**(key) → wire/setStaking → `PoolManager.initialize` → Permit2 + 20-tranche mint.
- [ ] Every write: `eth_call` first; deployer-only; confirm dialogs.
- [ ] O-1 style verify on staking (codehash + immutables + owner + totalLocked==0) before wire.
- [ ] Liquidity tab: list Posm tokenIds for new pool; withdraw-all; do not call legacy proxy path for fresh pool.
- [ ] Retire migration-from-v1 flows for old token (already partially retired).
- [ ] Locks table: show `durationPending` when `unlockAt == 0` (display targetBlock / “reveal after block N”); after reveal show `unlockAt` + remaining.
- [ ] Optional admin “Reveal” button calling `reveal(user, lockId)` (anyone can call; useful for support).

### 6.3 Public site
- [ ] Swap/stake/estimate against **new** staking (`SaviorStakingFresh`) only.
- [ ] Leaderboard/feed seed from new staking deploy block.
- [ ] Copy: no promise about old pool liquidity.
- [ ] **Claim flow:** before/inside claim, UI may call `reveal(user, i)` if pending; contract `claim` also **auto-reveals** — either path OK. Prefer eth_call to detect pending (`unlockAt==0`) and show “duration revealing…” then refresh.
- [ ] **Lock sorting:** sort claimable first (`unlockAt != 0 && now >= unlockAt`), then revealed-waiting, then pending (`unlockAt==0`); never treat `unlockAt==0` as “unlocked”.
- [ ] After buy/stake: show “pending 5–10 days (reveal in ~N blocks)” not a fake fixed unlock time.

### 6.4 Auditor checklist
- [ ] Token: no post-ctor mint; no proxy; burn correct; no hidden admin.
- [ ] Hook: address bits == `getHookPermissions`; OnlyStaking; no ReturnDelta; init binding (if any); upgrade policy.
- [ ] StakingFresh: commit-reveal (pending unlockAt=0, targetBlock, anyone-reveal, 256-block → 10d fallback, claim auto-reveal, LockRevealed); D-2 MIN_STAKE; D-3 deadline; rescue vs totalLocked; 50/50 lock; treasury BPS; immutables match pool. Seed not grindable at commit (see CommitRevealLock.t.sol).
- [ ] Pool: fee 10000, spacing 200, hook address, initialize price.
- [ ] LP: Posm ownership = deployer; ladder math → ~50k USDC gross; eth_call mint simulation.
- [ ] Operational: owner keys secured; ownership is never renounced (token `renounceOwnership` reverts).

### 6.5 Fork test plan
- [ ] `SaviorTokenV2` deploy + totalSupply/balances.
- [ ] Hook CREATE2 address flags; `beforeSwap` rejects non-staking; accepts staking.
- [ ] StakingFresh deploy with new key; buy lock 50/50 pending; reveal by third party; claim auto-reveal; 256-block fallback; sell SameBlock; deadline; MIN_STAKE.
- [ ] `CommitRevealLock.t.sol`: precompute fails; delay→10d; multi-lock same block different durations.
- [ ] `PoolManager.initialize` + Posm 20 mints.
- [ ] Whale `swapExactIn` buyout → USDC spent ≈ 50k (±2%); pool SAVIOR ≈ 0; buyer wallet ≈ half net, half locked.
- [ ] Posm decrease/burn all → deployer recovers remaining SAVIOR/USDC.
- [ ] Arc USDC precompile mocks (existing `ArcPrecompiles`).
- [ ] Gas report: `forge test --gas-report` / `eth_estimateGas` on fork at current base fee.

---

## 7) Mainnet step order + cost estimate

### 7.1 Order (single deployer session)

1. **Snapshot** old balances / announce deprecate (off-chain).  
2. **Deploy SaviorTokenV2(deployer)**.  
3. **Mine salt + CREATE2 deploy new Hook** (flags).  
4. **Deploy SaviorStakingV2**(owner, token, PM, treasury, key).  
5. **Wire** hook → staking (`setStakingContract` or confirm ctor immutables).  
6. **`PoolManager.initialize(key, sqrtPriceX96)`** at tick ~122000.  
7. **Approvals**: SAVIOR → Permit2; Permit2 → Posm.  
8. **Mint 20 Posm positions** (ladder).  
9. **Verify** on explorer; update config on a PR (not main).  
10. **Smoke** small buy via staking (e.g. 1–10 USDC).  
11. **Site cutover** PR → preview → explicit approve for production.  
12. Optional: burn/send-to-dead remaining **old** SAVIOR in deployer wallet.

### 7.2 Gas / USDC cost (Arc)

Observed (2026-10-11): `baseFeePerGas ≈ 20 gwei`, `gasPrice ≈ 20 gwei`.  
Arc charges gas in **native USDC (18 decimals)**:  
`USDC ≈ gasUsed × gasPrice / 1e18`.

| Step | Est. gas | Est. USDC |
|------|----------|-----------|
| Token deploy | 0.8–1.5M | 0.016–0.030 |
| Hook impl + CREATE2 proxy | 2.5–4.0M | 0.050–0.080 |
| Staking v2 deploy | 3.0–4.5M | 0.060–0.090 |
| Wire + initialize | 0.2–0.4M | 0.004–0.008 |
| Approves (×2) | 0.1–0.2M | 0.002–0.004 |
| Posm 20-mint batch | 3.0–6.0M | 0.060–0.120 |
| Smoke swap | 0.3–0.6M | 0.006–0.012 |
| **Total gas** | **~10–17M** | **≈ 0.20–0.35 USDC** |

Deployer native USDC balance (gas wallet) ≈ **0.886 USDC** — **sufficient for gas** at current prices (leave margin for retries / higher base fee).

**Liquidity USDC:** ladder is SAVIOR-only → **0 USDC** required to seed LP.  
**Buyout USDC (~50k):** capital required by a buyer to purchase all SAVIOR — **not** a deployer seed cost. Deployer only needs the 1B token mint.

Re-estimate on fork immediately before launch (`cast estimate` / forge gas report) — base fee can move.

---

## 8) Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| Repeat of renounced-owner LP lock | High | Posm NFTs only; never custom proxy salt=0; owners never renounced |
| Reusing old hook → shared UUPS / single staking | High | New immutable hook |
| Wrong hook flags (CREATE2) | High | Miner + `getHookPermissions` assert; fork test |
| Ladder math drift if supply ≠ 1B in pool | Med | Recompute table after Decision A |
| JIT / third-party LP on new pool | Med | Accept (hooks don’t gate LP); or add liquidity hooks (changes flags → new address) |
| Site cutover to wrong addresses | Med | deployments json + O-1 style checks; preview Vercel |
| Old pool still shown on Uniswap UI | Low | Docs/warn; cannot delete pool |
| Arc USDC precompile quirks | Med | Keep ArcPrecompiles fork tests; tiny mainnet smoke swap |
| Deployer gas wallet low | Low | Top up native USDC if base fee spikes |
| Brand confusion old vs new token | Med | New address everywhere; “legacy” label |

---

## 9) Decision points (need Dzengo)

1. **A — Supply split:** % of 1B into ladder vs treasury (recommend ≥95% ladder).  
2. **B — Hook upgradeability:** immutable (recommend) vs UUPS.  
3. **C — Reuse old hook?** No (recommend).  
4. **D — Hook→staking link:** immutable ctor (recommend) vs `setStakingContract`.  
5. **E — Start price:** 5e-6 (recommend) vs other.  
6. **F — Buyout target:** 50k USDC gross (recommend) vs other depth.  
7. **G — Old SAVIOR:** burn/deprecate only vs 1:1 claim portal (recommend burn/deprecate only).  
8. **H — Symbol clash:** keep `SAVIOR` vs `SAVIOR2` / new ticker (product choice).  
9. **I — Production cutover:** which branch → main/gh-pages and when.

---

## 10) Optional prototypes on this branch

- `staking-v2/src/fresh/SaviorTokenV2.sol` — fixed supply token.  
- Fork tests to add next: CREATE2 hook miner stub, initialize + ladder + buyout gas/USDC assert (same pattern as `LiquidityLadderFork`).  
- Keep plans/tests on `feature/fresh-start`; **no** mainnet broadcast.

---

## 11) References

- Old pool id: `0x004d7e7f668a78ea18228d753008ccf0c2b6b9e7c6c03d7a44d7cd954d072ab6`  
- Old token `0xe406…cAf3` / hook `0xFfcf…60c0` / staking v2 `0x8807…39bB` / legacy LP proxy `0x6109…3c95`  
- Prior ladder fork proof: `staking-v2/test/LiquidityLadderFork.t.sol` + `docs/liquidity-ladder.md`  
- Uniswap Arc Posm `0x6049…f82B` / PM `0x8366…0951` / Permit2 canonical  
- Auditor notes: live hook source ≠ repo stub; OnlyStaking gate; UUPS owner = deployer  


## Appendix: logoURI and wallet display

### On-chain / IPFS options
| Option | Size / cost | Notes |
|--------|-------------|--------|
| `ipfs://<CID>` of `logo.svg` | Deploy stores ~60–80 chars | Pin via NFT.storage / Pinata / web3.storage / Kubo; CID deterministic for same bytes (CIDv1 recommended). Recurring pin cost small or free tiers. |
| `https://…` raw GitHub / CDN | Short | Mutable if URL content changes; explorers may hotlink. |
| `data:image/svg+xml;base64,…` | Current repo logo ≈ **2255 B** raw → URI ≈ **3034 chars** | Fits comfortably in ctor; increases initcode calldata gas (~few cents USDC on Arc). No dependency on IPFS. |

**Recommendation:** ship initial `logoURI` as `ipfs://` (pin `logo.svg`) **or** data-URI; owner can update later via `setLogoURI`. Keep PNG 256×256 for Trust Wallet PRs separately.

### Where wallets actually read logos (sources)
| Client | Source | Contract `logoURI`? |
|--------|--------|---------------------|
| **MetaMask** | Tokens API + static CDN `static.cx.metamask.io/.../tokenIcons/...`; legacy [contract-metadata](https://github.com/MetaMask/contract-metadata) | **No** for ERC-20 (NFT `tokenURI` is different — MIP-1) |
| **Trust Wallet** | [trustwallet/assets](https://github.com/trustwallet/assets) `blockchains/<chain>/assets/<checksum>/logo.png` | **No** |
| **Uniswap UI** | **CoinGecko** (official support article, updated 2026-08) | **No** |
| **Rabby** | Own backend API (`@rabby-wallet/rabby-api` token endpoints); exact logo upstream not fully documented in public source reviewed | Unlikely contract field |
| **Blockscout / Arc explorer** | Token metadata / admin or verified project profiles (explorer-specific; Cloudflare often blocks automated scrape) | Sometimes reads metadata if submitted |

### Steps for automatic / practical display
1. Deploy token with `logoURI` set (ipfs or data-URI).
2. Add `tokenlist.json` (Uniswap token lists schema) in the SAVIOR repo / site with `logoURI`.
3. PR to Trust Wallet `assets` once Arc chain folder exists / is accepted (checksum address, `logo.png` 256², `info.json`).
4. Submit MetaMask contract-metadata / Tokens pipeline if Arc supported.
5. CoinGecko / CoinMarketCap listing request (drives Uniswap logos).
6. Arc explorer token profile / verified metadata form.
7. Site & admin hardcode icon regardless of wallets.

## Appendix: lock randomness (current v2 bias)

PoC: `staking-v2/test/LockBiasPoC.t.sol` (ARC_FORK).

- Seed: `keccak256(blockhash(n-1), user, msg.sender, userNonce, globalNonce) % (5 days + 1)` → extra ∈ [0, 432000] sec.
- **Predictable** before sending: parent hash known; eth_call / off-chain match on-chain (PoC asserted equality).
- Same-block re-roll via amount: **blocked** (D-1). Failed conditional stake **does not** bump nonces.
- Stats: P(extra&lt;1h)≈0.83% (~121 blocks); &lt;12h≈10% (~11); &lt;1d≈20% (~6). Arc sub-second blocks → minutes of wall-clock for tight targets.
- Failed try gas ≈ **145k** → ≈ **0.0029 USDC** at 20 gwei (18-dec native).
- `block.prevrandao` on Arc = **0** ([docs.arc.io](https://docs.arc.io/arc/references/evm-differences)); Malachite/Tendermint PoA, no RANDAO.
- VRF on Arc: **D20DAO** coordinator `0xd20da057469C45928912d983F45790C41e290571`, `quoteFee` ≈ **0.02 USDC** (measured); Chainlink VRF / Pyth Entropy / Gelato VRF — **no Arc addresses found** in public docs searched.

### Decision (2026-10-11): commit-reveal 5–10 days, NO VRF

Implemented: `staking-v2/src/fresh/SaviorStakingFresh.sol` + `test/CommitRevealLock.t.sol`.

| Step | Behavior |
|------|----------|
| Commit (buy/stake) | Lock pushed with `unlockAt=0`, `createdAt=now`, `targetBlock=block.number+REVEAL_DELAY_BLOCKS` (**N=3**). Event `Staked(..., targetBlock)`. |
| Why N=3 | Arc has **sub-second deterministic finality** and **no reorgs** (Malachite BFT / PoA). 3 blocks ≈ seconds — enough that `blockhash(target)` is unknown at commit, UX stays snappy. Larger N only delays reveal. |
| Reveal | `reveal(user, i)` by **anyone** once `block.number > targetBlock`. `duration = 5d + keccak(blockhash(target), user, i, createdAt) % (5d+1)`; `unlockAt = createdAt + duration`. Event `LockRevealed`. |
| Fallback | If `blockhash(target)==0` (older than 256 blocks): **10 days** (max). Delaying reveal only hurts the staker. |
| Claim | Auto-calls `reveal` if still pending, then enforces `unlockAt`. |
| Views | `getLocks` returns struct (`unlockAt==0` ⇒ pending); `isPending(user,i)`. |
| Seed binding | Hash includes `user`, lock **index**, `createdAt` — multiple locks in the same block get different durations; nobody can change the seed after commit. |

**Why not D20DAO VRF:** fee is **native USDC `msg.value`** (not buyer ERC-20), async fulfill, coordinator dependency, ~0.02 USDC/request — rejected for lock jitter (PoC `D20VrfFeePoC`).

**Attack / fairness notes (tests):**
- Attacker contract with conditional revert **cannot** know duration at buy time (future blockhash).
- Precompute of final duration at commit **fails**.
- Withholding reveal past 256 blocks → only **10d fallback** (worse for attacker/staker).
- Selective reveal irrelevant: result is deterministic once `targetBlock` exists.
- Anyone can reveal (no grief beyond gas; claim also reveals).

### Arc block-producer risk (Malachite BFT)

- Arc uses **Malachite** (Tendermint-style BFT) with **PoA validators**, **deterministic finality &lt;1s**, **no reorgs** once committed ([docs.arc.io consensus](https://docs.arc.io/arc/concepts/consensus-layer)).
- A **rotating proposer** assembles the block; &gt;2/3 precommits finalize it. The proposer influences **which txs** enter *their* proposed block and thus can slightly bias the block’s content hash — but cannot rewrite a finalized hash, and cannot grind across reorgs.
- **Cost / practicality of biasing our seed:** to favor a short lock, a malicious proposer would need to be the proposer of the specific `targetBlock` (or collude) and search for a block body whose hash yields a short `keccak(...) % (5d+1)`. With sub-second blocks and PoA reputation/slashing-style governance (permissioned set), grinding many candidate bodies per slot is expensive and visible; benefit is only ±5 days on one lock, not MEV on a large pool. Collusion of &gt;1/3 validators to censor/reorg is out of threat model (BFT assumption).
- **AMP** (multi-proposer) is exploratory and would further constrain assembler discretion; not assumed deployed.
- **Residual risk:** accepted as low vs old v2 same-block / parent-hash grind. Fallback-to-max removes incentive to stall reveal. No mainnet tx in this work.

**Branch note:** `SaviorStakingFresh` lives under `staking-v2/src/fresh/` on `feature/fresh-start` only. Shared files (e.g. `IV4Minimal.sol`) unchanged in semantics for deployed-v2; do not merge lock logic into live `SaviorStakingV2` without an explicit decision.
