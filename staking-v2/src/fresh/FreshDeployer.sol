// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey, IPoolManagerMinimal} from "../IV4Minimal.sol";

import {SaviorHookFresh} from "./SaviorHookFresh.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPosmLadder {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function getPoolAndPositionInfo(uint256 id) external view returns (PoolKey memory, uint256);
}

interface ILuckyBound {
    function staking() external view returns (address);
}

interface IPermit2Approve {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

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
    address public immutable positionManager;
    address public immutable permit2;
    /// @notice keccak256(type(SaviorStakingFresh).creationCode). Staking initcode is passed as calldata to
    ///         deploy() and must match (keeps this factory under EIP-170; admin tab checks it vs artifact).
    bytes32 public immutable stakingCodeHash;

    address public staking;
    address public hook;
    bool public deployed;

    event FreshDeployed(address staking, address hook, int24 tick, bytes32 salt);
    event LadderMinted(uint256 amount, uint256 refunded);

    error NotAdmin();
    error AlreadyDeployed();
    error HookAddressMismatch();
    error StakingAddressMismatch();
    error BadHookFlags();
    error BadLadder();
    error BadStakingCode();
    error BadLuckySink();

    /// @dev Post-check each new NFT: owner == admin and its PoolKey (first 5 words of
    ///      Posm.getPoolAndPositionInfo) == this pool's key. Raw compare keeps bytecode small (EIP-170).
    function _checkNft(uint256 id, bytes32 kh) internal view {
        if (IPosmLadder(positionManager).ownerOf(id) != admin) revert BadLadder();
        (bool ok, bytes memory r) =
            positionManager.staticcall(abi.encodeWithSelector(IPosmLadder.getPoolAndPositionInfo.selector, id));
        bytes32 h;
        assembly ("memory-safe") {
            h := keccak256(add(r, 32), 160)
        }
        if (!ok || r.length < 192 || h != kh) revert BadLadder();
    }

    constructor(
        address admin_,
        address token_,
        address usdc_,
        address poolManager_,
        address treasury_,
        uint24 fee_,
        int24 tickSpacing_,
        address positionManager_,
        address permit2_,
        bytes32 stakingCodeHash_
    ) {
        stakingCodeHash = stakingCodeHash_;
        positionManager = positionManager_;
        permit2 = permit2_;
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

    function _hookInitCode() internal view returns (bytes memory) {
        return abi.encodePacked(
            type(SaviorHookFresh).creationCode,
            abi.encode(poolManager, predictStaking(), address(this), currency0, currency1, fee, tickSpacing)
        );
    }

    function hookInitCodeHash() public view returns (bytes32) {
        return keccak256(_hookInitCode());
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

    /// @notice One tx: staking + hook + initialize + (if ladderAmount > 0) the 20-tranche ladder.
    ///         Ladder: pulls `ladderAmount` SAVIOR from admin (prior SAVIOR.approve(factory)), forwards the
    ///         off-chain built `ladderData` (FreshLadder.build / admin UI port) to PositionManager.
    ///         Post-check: exactly 20 new NFTs, each owned by `admin` and on THIS pool key; dust refunded;
    ///         Permit2 allowance capped to `ladderAmount` (factory holds nothing else). Closes audit N-1 (no window
    ///         between initialize and liquidity). Ladder geometry stays in FreshLadder (EIP-170 size budget).
    function deploy(
        bytes32 salt,
        uint160 sqrtPriceX96,
        uint256 ladderAmount,
        bytes calldata ladderData,
        bytes calldata stakingCode,
        address luckySink
    )
        external
        returns (address staking_, address hook_, int24 tick)
    {
        if (msg.sender != admin) revert NotAdmin();
        if (deployed) revert AlreadyDeployed();
        if (!isValidHookSalt(salt)) revert BadHookFlags();
        deployed = true;
        staking_ = _createStaking(stakingCode, luckySink, computeHookAddress(salt));
        hook_ = _createHook(salt, staking_);

        tick = IPoolManagerInit(poolManager).initialize(poolKey(hook_), sqrtPriceX96);
        staking = staking_;
        hook = hook_;
        emit FreshDeployed(staking_, hook_, tick, salt);
        if (ladderAmount != 0) _ladder(hook_, ladderAmount, ladderData);
    }

    function _createHook(bytes32 salt, address staking_) internal returns (address hook_) {
        hook_ = address(
            new SaviorHookFresh{salt: salt}(poolManager, staking_, address(this), currency0, currency1, fee, tickSpacing)
        );
        if (hook_ != computeHookAddress(salt)) revert HookAddressMismatch();
    }

    function _createStaking(bytes calldata stakingCode, address luckySink, address predictedHook)
        internal
        returns (address staking_)
    {
        address predictedStaking = predictStaking();
        if (keccak256(stakingCode) != stakingCodeHash) revert BadStakingCode();
        // Lucky sink (if any) must already be bound to the predicted staking (immutable minter binding).
        if (luckySink != address(0) && ILuckyBound(luckySink).staking() != predictedStaking) revert BadLuckySink();
        bytes memory init = abi.encodePacked(
            stakingCode, abi.encode(admin, token, poolManager, treasury, poolKey(predictedHook), luckySink)
        );
        assembly ("memory-safe") {
            staking_ := create(0, add(init, 32), mload(init))
        }
        if (staking_ != predictedStaking) revert StakingAddressMismatch();
    }

    function _ladder(address hook_, uint256 amount, bytes calldata data) internal {
        SafeERC20.safeTransferFrom(IERC20(token), admin, address(this), amount);
        SafeERC20.forceApprove(IERC20(token), permit2, amount);
        IPermit2Approve(permit2).approve(token, positionManager, uint160(amount), uint48(block.timestamp));
        uint256 first = IPosmLadder(positionManager).nextTokenId();
        IPosmLadder(positionManager).modifyLiquidities(data, block.timestamp);
        if (IPosmLadder(positionManager).nextTokenId() != first + 20) revert BadLadder();
        bytes32 kh = keccak256(abi.encode(poolKey(hook_)));
        for (uint256 i; i < 20; ++i) {
            _checkNft(first + i, kh);
        }
        SafeERC20.forceApprove(IERC20(token), permit2, 0);
        uint256 left = IERC20(token).balanceOf(address(this));
        if (left != 0) SafeERC20.safeTransfer(IERC20(token), admin, left);
        emit LadderMinted(amount, left);
    }
}
