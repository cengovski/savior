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
