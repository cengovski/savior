# Fresh-start UI fork test (lock reveal + Lucky NFT)

Local only: an anvil fork of Arc mainnet. Nothing is sent to mainnet, no keys are used (anvil unlocked/impersonated accounts).

What it deploys on the fork (`ForkSetup.s.sol`, mirrors `staking-v2/script/fresh/DeployFresh.s.sol` steps 1 to 6 from
`feature/lucky-nft` 338696d): SaviorTokenV2, FreshDeployer (20-tranche ladder, mined hook), SaviorStakingFresh,
an OpenSea ERC721SeaDrop clone (live impl 0x09a26fC8...Dd6A, live SeaDrop) and LuckyDistributor wired as the allow-list leaf.
Arc USDC is replaced by `../v2-fork-test/MockUSDC.sol` on the fork so test wallets can be funded.

```bash
LUCKY=/path/to/feature-lucky-nft-checkout PORT=8601 tools/reveal-fork-test/setup.sh   # prints DEPLOY_BLOCK
python3 -m http.server 8772                                                           # repo root
DEPLOY=<DEPLOY_BLOCK> PORT=8601 node tools/reveal-fork-test/e2e.cjs                   # needs playwright
```

The site switches to fresh mode on localhost with
`?rpc=http://127.0.0.1:8601&fresh=<token>,<hook>,<staking>,<distributor>,<deployBlock>` (see config.js).

Covered: UI buy (lock shown as 10 days default), reveal inside the window (button + countdown + warning), reveal through
EIP-2935 after 300 blocks, reveal after the window (RevealWindowClosed message, "Locked for 10 days"), Reveal all with
30 locks (batches of 25 + 5, RevealBatch counts), a Lucky NFT win (found by checking `isLuckyWin` on the committed hash
before revealing, no contract changes) then `claimNFT`, and a deferred mint (price > 0, unfunded) then `retryMint`.

Note: `setup.sh` zero-fills the 8191 EIP-2935 ring slots locally so mining thousands of blocks does not hit the
public RPC rate limit.
