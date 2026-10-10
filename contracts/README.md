# Contracts — status

**Note:** the Solidity in this folder is **NOT** the code deployed on Arc Mainnet. See below.

## Recovered source (from git history, commit `511e255^`, Base-era skeleton)
- `SaviorToken.sol`, `Vault.sol`, `VaultFactory.sol`, `SaviorHook.sol`.
These are older, non-upgradeable drafts (Ownable + Vault/VaultFactory design). The deployed system uses UUPS proxies and a `SaviorStaking` contract that has no source anywhere in the repo history. `script/*.sol` imports `contracts/SaviorStaking.sol`, which is missing, and expects upgradeable versions of SaviorToken and SaviorHook. So the scripts **won't compile** against these files.

## ABI-only (from the live frontend, partial): `abi/*.json`
SaviorToken, SaviorHook, SaviorStaking, PoolManager (initialize only), V4Quoter (quoteExactInputSingle only). Format: ethers human-readable fragments.

## Bytecode (creation code embedded in live admin.html): `bytecode/`
- `SaviorHook_impl.creation.hex`
- `SaviorStaking.creation.hex`
- `ERC1967Proxy.creation.hex`

The token bytecode was empty in the frontend.

## Verification
explorer.arc.io sits behind a Cloudflare challenge, so I couldn't check verification status from scripts. Verified sources haven't been confirmed or downloaded.

## Missing
- Real sources for SaviorToken (upgradeable), SaviorHook (upgradeable), SaviorStaking.
- Tests.
- Explorer verification.

Addresses, implementations and owners: `../deployments/arc-mainnet.json`.
