// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey, IUnlockCallback} from "./IV4Minimal.sol";

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

interface IPoolManagerLiq {
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (int256 callerDelta, int256 feesAccrued);
    function take(address currency, address to, uint256 amount) external;
}

interface IStateViewPos {
    function getPositionInfo(bytes32 poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128);
}

/// @title LiquidityRescue
/// @notice One-shot UUPS implementation for the legacy liquidity proxy 0x6109...3c95, which owns the
///         SAVIOR/USDC v4 positions (PoolManager position owner = proxy, salt 0) but whose live
///         implementation has no remove-liquidity function.
///         Used as: proxy.upgradeToAndCall(rescueImpl, abi.encodeCall(withdrawAllAndRestore, (lowers, uppers))).
///         In that single tx it removes ALL liquidity (+ accrued fees) of the given ranges, sends both
///         currencies to DEPLOYER, and writes the previous implementation back into the ERC-1967 slot.
///         Stateless: uses only constants, so the proxy's storage is never touched (except the impl slot).
contract LiquidityRescue is IUnlockCallback {
    address public constant DEPLOYER = 0x7185d50557040047A142aEadA95e41C4b31720e7;
    address public constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address public constant USDC = 0x3600000000000000000000000000000000000000;
    address public constant SAVIOR = 0xe4065efC5E19305e4ed1dfdB6542A32A34E0cAf3;
    address public constant HOOK = 0xFfcf2eF82AA17Fb31F3618E0302F9adC92D060c0;
    /// @dev implementation live on the proxy before the rescue; restored at the end of the call
    address public constant RESTORE_IMPL = 0x954fF6ae3f19167f7c6c24FF6a43680c0Ffb5C83;
    /// @dev ERC-1967 implementation slot
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address private immutable self = address(this);

    event Upgraded(address indexed implementation);
    event Rescued(int24 tickLower, int24 tickUpper, uint128 liquidity);
    event Paid(uint256 usdc, uint256 savior);

    error NotDeployer();
    error NotDelegated();
    error OnlyPoolManager();
    error BadInput();

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey(USDC, SAVIOR, 10000, 200, HOOK);
    }

    function poolId() public pure returns (bytes32) {
        return keccak256(abi.encode(_key()));
    }

    /// @notice ERC-1822 UUID, required by OZ UUPSUpgradeable.upgradeToAndCall
    function proxiableUUID() external view returns (bytes32) {
        if (address(this) != self) revert NotDelegated();
        return IMPL_SLOT;
    }

    /// @notice Remove all liquidity of the given (salt 0) ranges to DEPLOYER, then restore RESTORE_IMPL.
    function withdrawAllAndRestore(int24[] calldata lowers, int24[] calldata uppers) external {
        if (address(this) == self) revert NotDelegated();
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (lowers.length == 0 || lowers.length != uppers.length) revert BadInput();
        IPoolManagerLiq(POOL_MANAGER).unlock(abi.encode(lowers, uppers));
        assembly {
            sstore(IMPL_SLOT, RESTORE_IMPL)
        }
        emit Upgraded(RESTORE_IMPL);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != POOL_MANAGER) revert OnlyPoolManager();
        (int24[] memory lowers, int24[] memory uppers) = abi.decode(data, (int24[], int24[]));
        int256 a0;
        int256 a1;
        bytes32 id = poolId();
        for (uint256 i; i < lowers.length; ++i) {
            (uint128 liq,,) = IStateViewPos(STATE_VIEW).getPositionInfo(id, address(this), lowers[i], uppers[i], 0);
            if (liq == 0) continue;
            (int256 d,) = IPoolManagerLiq(POOL_MANAGER).modifyLiquidity(
                _key(), ModifyLiquidityParams(lowers[i], uppers[i], -int256(uint256(liq)), 0), ""
            );
            a0 += int256(d >> 128);
            a1 += int256(int128(d));
            emit Rescued(lowers[i], uppers[i], liq);
        }
        if (a0 < 0 || a1 < 0) revert BadInput();
        if (a0 > 0) IPoolManagerLiq(POOL_MANAGER).take(USDC, DEPLOYER, uint256(a0));
        if (a1 > 0) IPoolManagerLiq(POOL_MANAGER).take(SAVIOR, DEPLOYER, uint256(a1));
        emit Paid(uint256(a0), uint256(a1));
        return "";
    }
}
