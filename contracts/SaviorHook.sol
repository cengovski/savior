// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title SaviorHook
 * @notice Uniswap V4 Hook for $SAVIOR
 *         - %2 fee on swaps → Treasury
 *         - Enforce vault interaction (opsiyonel beforeSwap kontrolü)
 * 
 * Deploy öncesi HookMiner ile izinli adres hesaplanmalı.
 */
contract SaviorHook is IHooks {
    address public immutable treasury;
    uint256 public constant FEE_BPS = 200; // 2%

    constructor(address _treasury) {
        treasury = _treasury;
    }

    function getHookPermissions() external pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        // İsteğe bağlı: Sadece belirli Vault'lardan swap'a izin ver
        // if (hookData.length == 0) revert("Must come from Vault");
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override returns (bytes4, int128) {
        // %2 fee implementation (basit örnek)
        // Gerçekte delta.amount0() / amount1() üzerinden fee hesaplanır
        // ve IPoolManager.take() veya donate() ile treasury'ye aktarılır.
        
        // Örnek:
        // uint256 feeAmount = ...calculate...
        // if (feeAmount > 0) {
        //     IPoolManager(msg.sender).take(key.currency0, treasury, feeAmount);
        // }
        
        return (IHooks.afterSwap.selector, 0);
    }
}