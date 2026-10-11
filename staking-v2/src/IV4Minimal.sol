// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal Uniswap v4-core types/interfaces used by SaviorStakingV2
///         (subset of https://github.com/Uniswap/v4-core IPoolManager, ABI-identical).
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManagerMinimal {
    function unlock(bytes calldata data) external returns (bytes memory);
    /// @return delta BalanceDelta: amount0 in the upper 128 bits, amount1 in the lower 128 bits
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256 delta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

library TickMathBounds {
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
}
