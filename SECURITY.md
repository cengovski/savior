# SAVIOR security status

**Status: unaudited. Do not treat the UI or this repository as evidence that the deployed token, hook, staking contract, or fee/lock behavior is safe.**

This file records what can be verified from the repository as of 19 October 2026. It is not a smart-contract audit.

## Repository findings

- The current frontend targets Arc Mainnet, chain ID `5042`, and uses the Arc USDC ERC-20 predeploy at `0x3600000000000000000000000000000000000000` (6 ERC-20 decimals). Native USDC accounting for gas uses 18 decimals.
- The frontend obtains `savior_staking`, `savior_token`, and `savior_hook` addresses from browser `localStorage`. There is no canonical, verified SAVIOR deployment address set committed for users to independently check.
- The admin panel embeds compiled `TOKEN_BC`, `HOOK_BC`, and `STAKING_BC` bytecode. The review could not locate matching Solidity source files for those embedded implementations at the expected contract paths or via repository code search; the Solidity snippets in `README.md` are explicitly treated as prototype/skeleton examples.
- The UI and admin panel have not had a proven ABI/source match. The trade UI therefore fails closed if the configured key, treasury, hook wiring, canonical PoolManager, token decimals, or quote cannot be read and validated. A failed quote must never become a swap with `minOut = 0`.
- Token units must be read from the deployed token's `decimals()`; don't assume SAVIOR is 6 or 18 decimals based only on a label or code comment.
- No single treasury address is considered authoritative until it is read from a verified deployed contract and reconciled across the hook, staking contract, and deployment transaction. The admin panel no longer silently defaults to the old hard-coded treasury.
- The admin page is a static web page. Its client-side password hash only gates the UI; it is not server-side authentication or a security boundary. A connected wallet may still be asked to sign deployment, upgrade, approval, and emergency transactions. Verify each target and calldata before signing.

## Before production use

1. Publish the exact Arc Mainnet token, hook, staking/proxy, implementation, and pool addresses, with transaction hashes.
2. Publish Solidity source, compiler settings, ABI, and build artifacts that reproduce the deployed bytecode. Verify proxy implementation and admin/upgrade authority on-chain.
3. Reconcile all frontend/admin ABIs against the source and deployed runtime, including `key()`, `treasury()`, `poolManager()`, and the hook's staking connection.
4. Test swap direction and decimals; stale quotes; zero output; pool key mismatch; wrong hook; failed quote; exact approval; fee recipient; locked-token accounting; claim boundaries; emergency unlock; reentrancy; and all owner/admin operations.
5. Have an independent smart-contract auditor review the exact deployed bytecode and configuration.

Until these checks are complete, don't advertise the %50 lock, 5–10 day lock duration, 2% treasury fee, pool restrictions, or admin emergency behavior as audited or guaranteed properties.
