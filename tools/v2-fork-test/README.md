# Staking v2 local fork test (not deployed anywhere)

Runs the real site against an anvil fork of Arc mainnet with SaviorStakingV2 deployed and the hook rewired to it.

1. `anvil --fork-url https://rpc.mainnet.arc.io --chain-id 5042 --port 8545`
2. Build `MockUSDC.sol` (forge) into `/tmp/v2fork/out`, then `bash setup.sh` (run from /tmp/v2fork with the v2 artifact saved as v2.json).
   Arc's USDC (0x3600...) moves balances through Arc-only precompiles that anvil lacks, so the fork replaces its code
   with a plain test ERC-20 that keeps the PoolManager's real USDC balance. Uses anvil's unlocked dev account, no keys.
   It makes one v1 buy (old lock), deploys v2 as the deployer (impersonated), and calls hook.setStakingContract(v2).
3. Serve the repo on localhost:8765 and run `node e2e.cjs` (playwright). The page is opened with
   `?rpc=http://127.0.0.1:8545&v2=<address>`; both overrides only work on localhost.
