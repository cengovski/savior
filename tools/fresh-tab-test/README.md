# Fresh start tab: local fork test (no mainnet tx)
1. `anvil --fork-url https://rpc.mainnet.arc.io --chain-id 5042 --port 8545`
2. Build `tools/v2-fork-test/MockUSDC.sol` into `/tmp/fsfork/out`, then `bash setup.sh` (USDC mock keeps PoolManager balance, deployer impersonated, no keys).
3. `ADMIN_PASSWORD=... SESSION_SECRET=... node admin/dev/local-server.mjs admin` then `node e2e.mjs` (playwright; injected EIP-1193 provider forwards to anvil). Runs STEP 1-5, buy+sell, collect fees (single + all), schedule emergency unlock, paged locks, legacy LP check. Screenshots go to /workspace/fresh-tab-shots.
`cmp.mjs` checks the in-page FreshLadder JS port is byte-identical to FreshLadder.sol output.
Artifacts embedded in admin.html (FRESH_ART) come from feature/fresh-start@38d6a3f.

## v2 (feature/lucky-nft contracts, 6 steps)
`e2e.mjs` now runs: 1 token, 2 factory (stakingCodeHash + expectedLadderAmount), simulated OpenSea Studio clone (EIP-1167 of ERC721SeaDropCloneable, owner = deployer), 3 LuckyDistributor, 4 SeaDrop config, 5 approve, 6 mine + deploy (local ladder hash checked against factory.expectedLadderHash), verify (ticks + liquidity vs table), lucky win (third-party reveal, deferred because unfunded), retryMint from the UI, user claimNFT, fees, emergency, locks, legacy. Screenshots in /workspace/fresh-tab-shots-v2.
ethers is self-hosted at admin/public/vendor/ethers-6.13.5.umd.min.js (sha384 identical to npm + cdnjs) and loaded with SRI.
