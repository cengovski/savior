// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey, IPoolManagerMinimal} from "../IV4Minimal.sol";
import {SaviorStakingFresh} from "./SaviorStakingFresh.sol";
import {SaviorHookFresh} from "./SaviorHookFresh.sol";

interface IPoolManagerInit {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
}

/// @title FreshDeployer
/// @notice One-shot factory that breaks the hook<->staking circular dependency and removes the
///         initialize front-run window, all in ONE transaction:
///           1. staking = CREATE from this factory at nonce 1  (address predictable: predictStaking())
///           2. hook    = CREATE2(salt) with initcode bound to that staking address (mined off-chain)
///           3. PoolManager.initialize(key, sqrtPriceX96)  (hook only accepts this factory as initializer)
///         Off-chain: token deployed first; factory deployed; salt mined with HookMiner using
///         hookInitCodeHash(); then deploy(salt, sqrtPriceX96) by `admin`.
/// @dev Admin-tab friendly: every input/output is exposed as a view for on-chain verify + eth_call sim.
contract FreshDeployer {
    address public immutable admin; // deployer EOA; also staking owner
    address public immutable token;
    address public immutable usdc;
    address public immutable poolManager;
    address public immutable treasury;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    address public immutable currency0;
    address public immutable currency1;

    address public staking;
    address public hook;
    bool public deployed;

    event FreshDeployed(address staking, address hook, int24 tick, bytes32 salt);

    error NotAdmin();
    error AlreadyDeployed();
    error HookAddressMismatch();
    error StakingAddressMismatch();
    error BadHookFlags();

    constructor(
        address admin_,
        address token_,
        address usdc_,
        address poolManager_,
        address treasury_,
        uint24 fee_,
        int24 tickSpacing_
    ) {
        admin = admin_;
        token = token_;
        usdc = usdc_;
        poolManager = poolManager_;
        treasury = treasury_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        (currency0, currency1) = token_ < usdc_ ? (token_, usdc_) : (usdc_, token_);
    }

    /// @notice true if SAVIOR is currency0 (then SAVIOR-only ladder ranges sit ABOVE the start tick).
    function saviorIsCurrency0() public view returns (bool) {
        return currency0 == token;
    }

    /// @notice Staking address = CREATE(this, nonce 1) — first contract this factory creates.
    function predictStaking() public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes2(0xd694), address(this), bytes1(0x01))))));
    }

    function hookInitCode() public view returns (bytes memory) {
        return abi.encodePacked(
            type(SaviorHookFresh).creationCode,
            abi.encode(poolManager, predictStaking(), address(this), currency0, currency1, fee, tickSpacing)
        );
    }

    function hookInitCodeHash() public view returns (bytes32) {
        return keccak256(hookInitCode());
    }

    function computeHookAddress(bytes32 salt) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hookInitCodeHash())))));
    }

    function isValidHookSalt(bytes32 salt) public view returns (bool) {
        uint160 a = uint160(computeHookAddress(salt));
        return a & ((1 << 14) - 1) == (1 << 13) | (1 << 7);
    }

    function poolKey(address hook_) public view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, fee, tickSpacing, hook_);
    }

    function deploy(bytes32 salt, uint160 sqrtPriceX96) external returns (address staking_, address hook_, int24 tick) {
        if (msg.sender != admin) revert NotAdmin();
        if (deployed) revert AlreadyDeployed();
        if (!isValidHookSalt(salt)) revert BadHookFlags();
        deployed = true;
        address predictedHook = computeHookAddress(salt);
        address predictedStaking = predictStaking();

        staking_ = address(
            new SaviorStakingFresh(
                admin, IERC20(token), IPoolManagerMinimal(poolManager), treasury, poolKey(predictedHook)
            )
        );
        if (staking_ != predictedStaking) revert StakingAddressMismatch();

        hook_ = address(
            new SaviorHookFresh{salt: salt}(poolManager, staking_, address(this), currency0, currency1, fee, tickSpacing)
        );
        if (hook_ != predictedHook) revert HookAddressMismatch();

        tick = IPoolManagerInit(poolManager).initialize(poolKey(hook_), sqrtPriceX96);
        staking = staking_;
        hook = hook_;
        emit FreshDeployed(staking_, hook_, tick, salt);
    }
}
