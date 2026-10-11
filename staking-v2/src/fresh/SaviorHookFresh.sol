// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey, SwapParams} from "../IV4Minimal.sol";

/// @title SaviorHookFresh
/// @notice Uniswap v4 hook for the fresh-start SAVIOR/USDC pool. Immutable (no proxy, no owner).
///         - beforeInitialize: only `initializer` (FreshDeployer) may initialize, and only the single
///           PoolKey fixed at construction (currencies, fee, tickSpacing, hooks == this).
///         - beforeSwap: only `staking` (SaviorStakingFresh) may swap → 0.3% treasury fee + 50% lock
///           cannot be skipped IN THIS POOL. Liquidity add/remove is not hooked (Posm works normally).
///         Flags: BEFORE_INITIALIZE (1<<13) | BEFORE_SWAP (1<<7) = 0x2080 in the low 14 address bits.
///         afterSwap is NOT used: fees/locks are applied by the staking router after the swap settles,
///         so an afterSwap callback would add gas and attack surface for no function.
/// @dev Hook-free pools with the same token CAN be created by anyone (v4 is permissionless) and the
///      token has no transfer restrictions by design — see docs/fresh-start-plan.md "Hook bypass".
contract SaviorHookFresh {
    uint160 public constant FLAGS = uint160((1 << 13) | (1 << 7));
    uint160 public constant ALL_FLAGS_MASK = uint160((1 << 14) - 1);

    address public immutable poolManager;
    address public immutable staking;
    address public immutable initializer;
    address public immutable currency0;
    address public immutable currency1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    error NotPoolManager();
    error NotStaking();
    error NotInitializer();
    error WrongPoolKey();
    error BadHookAddress();
    error NotImplemented();

    constructor(
        address poolManager_,
        address staking_,
        address initializer_,
        address currency0_,
        address currency1_,
        uint24 fee_,
        int24 tickSpacing_
    ) {
        if (uint160(address(this)) & ALL_FLAGS_MASK != FLAGS) revert BadHookAddress();
        poolManager = poolManager_;
        staking = staking_;
        initializer = initializer_;
        currency0 = currency0_;
        currency1 = currency1_;
        fee = fee_;
        tickSpacing = tickSpacing_;
    }

    modifier onlyPM() {
        if (msg.sender != poolManager) revert NotPoolManager();
        _;
    }

    /// @notice True iff `key` is the single pool this hook serves.
    function isBoundKey(PoolKey calldata key) public view returns (bool) {
        return key.currency0 == currency0 && key.currency1 == currency1 && key.fee == fee
            && key.tickSpacing == tickSpacing && key.hooks == address(this);
    }

    function boundKey() external view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, fee, tickSpacing, address(this));
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view onlyPM returns (bytes4) {
        if (sender != initializer) revert NotInitializer();
        if (!isBoundKey(key)) revert WrongPoolKey();
        return SaviorHookFresh.beforeInitialize.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        onlyPM
        returns (bytes4, int256, uint24)
    {
        if (sender != staking) revert NotStaking();
        if (!isBoundKey(key)) revert WrongPoolKey(); // defensive; init binding already guarantees it
        return (SaviorHookFresh.beforeSwap.selector, 0, 0);
    }

    // Any other callback is unreachable (flag bits not set); revert defensively if ever called.
    fallback() external {
        revert NotImplemented();
    }
}
