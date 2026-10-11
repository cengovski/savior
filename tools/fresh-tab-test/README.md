# Fresh start tab: local fork test (no mainnet tx)
1. `anvil --fork-url https://rpc.mainnet.arc.io --chain-id 5042 --port 8545`
2. Build `tools/v2-fork-test/MockUSDC.sol` into `/tmp/fsfork/out`, then `bash setup.sh` (USDC mock keeps PoolManager balance, deployer impersonated, no keys).
3. `ADMIN_PASSWORD=... SESSION_SECRET=... node admin/dev/local-server.mjs admin` then `node e2e.mjs` (playwright; injected EIP-1193 provider forwards to anvil). Runs STEP 1-5, buy+sell, collect fees (single + all), schedule emergency unlock, paged locks, legacy LP check. Screenshots go to /workspace/fresh-tab-shots.
`cmp.mjs` checks the in-page FreshLadder JS port is byte-identical to FreshLadder.sol output.
Artifacts embedded in admin.html (FRESH_ART) come from feature/fresh-start@38d6a3f.
