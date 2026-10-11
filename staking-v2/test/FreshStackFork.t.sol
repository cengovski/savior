// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey, SwapParams, IUnlockCallback, TickMathBounds} from "../src/IV4Minimal.sol";
import {SaviorTokenV2} from "../src/fresh/SaviorTokenV2.sol";
import {SaviorStakingFresh} from "../src/fresh/SaviorStakingFresh.sol";
import {SaviorHookFresh} from "../src/fresh/SaviorHookFresh.sol";
import {FreshDeployer} from "../src/fresh/FreshDeployer.sol";
import {HookMiner} from "../src/fresh/HookMiner.sol";
import {FreshLadder} from "../src/fresh/FreshLadder.sol";
import {ArcAddresses as A} from "../src/ArcAddresses.sol";
import {ArcPrecompiles} from "./utils/ArcPrecompiles.sol";

interface IPosm {
    function modifyLiquidities(bytes calldata, uint256) external payable;
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256) external view returns (address);
}

interface IPermit2 {
    function approve(address, address, uint160, uint48) external;
}

interface IPM {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
}

/// Bypass attempt: swap directly on the hooked pool, not through staking.
contract DirectSwapper is IUnlockCallback {
    PoolKey key;
    constructor(PoolKey memory k) { key = k; }
    function go() external { IPM(A.POOL_MANAGER).unlock(""); }
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        IPM(A.POOL_MANAGER).swap(key, SwapParams(true, -1e6, TickMathBounds.MIN_SQRT_PRICE + 1), "");
        return "";
    }
}

/// End-to-end fresh stack on an Arc fork: token -> FreshDeployer(staking+hook+init, 1 tx) -> 20-tranche ladder.
/// Both currency orderings are exercised (token address mined below / above USDC 0x36..).
contract FreshStackForkTest is Test {
    address D = makeAddr("deployer");
    bool forked;

    function setUp() public {
        forked = vm.envOr("ARC_FORK", false);
        if (!forked) return;
        vm.createSelectFork("arc_mainnet");
        ArcPrecompiles.install(vm);
    }

    function _token(bool below) internal returns (SaviorTokenV2 t) {
        for (uint256 s;; ++s) {
            bytes memory ic = abi.encodePacked(type(SaviorTokenV2).creationCode, abi.encode(D, D, "ipfs://x"));
            address p = vm.computeCreate2Address(bytes32(s), keccak256(ic), address(this));
            if ((p < A.USDC) == below) {
                t = new SaviorTokenV2{salt: bytes32(s)}(D, D, "ipfs://x");
                return t;
            }
        }
    }

    function _stack(bool saviorC0)
        internal
        returns (SaviorTokenV2 t, FreshDeployer f, SaviorStakingFresh st, SaviorHookFresh h, PoolKey memory key)
    {
        t = _token(saviorC0);
        vm.prank(D);
        f = new FreshDeployer(D, address(t), A.USDC, A.POOL_MANAGER, A.TREASURY, 10000, 200);
        assertEq(f.saviorIsCurrency0(), saviorC0, "ordering");
        (bytes32 salt, address predicted) = HookMiner.find(address(f), uint160((1 << 13) | (1 << 7)), f.hookInitCodeHash(), 0, 200_000);
        console2.log("mined salt", uint256(salt));
        console2.log("hook", predicted);
        vm.prank(D);
        (address s_, address h_, int24 tick) = f.deploy(salt, FreshLadder.startSqrtPrice(saviorC0));
        console2.logInt(tick);
        assertEq(h_, predicted);
        assertEq(s_, f.predictStaking());
        st = SaviorStakingFresh(s_);
        h = SaviorHookFresh(h_);
        key = f.poolKey(h_);
        assertEq(st.owner(), D);
        assertEq(h.staking(), s_);

        // 20-tranche ladder (Posm NFTs to D)
        uint256 total = t.balanceOf(D);
        bytes memory data = FreshLadder.build(key, saviorC0, total, D);
        uint256 first = IPosm(A.POSITION_MANAGER).nextTokenId();
        vm.startPrank(D);
        t.approve(A.PERMIT2, type(uint256).max);
        IPermit2(A.PERMIT2).approve(address(t), A.POSITION_MANAGER, type(uint160).max, uint48(block.timestamp + 3600));
        IPosm(A.POSITION_MANAGER).modifyLiquidities(data, block.timestamp + 600);
        vm.stopPrank();
        for (uint256 i; i < 20; ++i) assertEq(IPosm(A.POSITION_MANAGER).ownerOf(first + i), D);
        console2.log("SAVIOR left on deployer (dust)", t.balanceOf(D));
        assertLt(t.balanceOf(D), total / 1000);
    }

    function _check(bool saviorC0) internal {
        (SaviorTokenV2 t, FreshDeployer f, SaviorStakingFresh st, SaviorHookFresh h, PoolKey memory key) = _stack(saviorC0);

        // re-deploy / second init impossible
        vm.prank(D);
        vm.expectRevert(FreshDeployer.AlreadyDeployed.selector);
        f.deploy(bytes32(0), 1);
        // another key using the same hook cannot be initialized
        PoolKey memory k2 = key;
        k2.fee = 3000;
        k2.tickSpacing = 60;
        vm.expectRevert();
        IPM(A.POOL_MANAGER).initialize(k2, FreshLadder.startSqrtPrice(saviorC0));

        // direct swap on hooked pool reverts (beforeSwap: NotStaking)
        DirectSwapper ds = new DirectSwapper(key);
        vm.expectRevert();
        ds.go();

        // buy through staking works: half locked, fee to treasury
        address b = makeAddr("buyer");
        vm.deal(b, 10_000 ether);
        bool buyZeroForOne = !saviorC0; // USDC -> SAVIOR
        vm.startPrank(b);
        IERC20(A.USDC).approve(address(st), type(uint256).max);
        vm.expectRevert(SaviorStakingFresh.ZeroMinOut.selector);
        st.swapExactIn(buyZeroForOne, 1000e6, 0, block.timestamp);
        uint256 net = st.swapExactIn(buyZeroForOne, 1000e6, 1, block.timestamp);
        vm.stopPrank();
        console2.log("net SAVIOR for 1000 USDC", net);
        assertGt(net, 0);
        assertEq(st.lockCount(b), 1);
        assertApproxEqAbs(t.balanceOf(b), net - net / 2, 1);
        assertGt(t.balanceOf(A.TREASURY), 0);
        h; // silence
    }

    function test_fork_fresh_stack_savior_currency1() public {
        vm.skip(!forked);
        _check(false);
    }

    function test_fork_fresh_stack_savior_currency0() public {
        vm.skip(!forked);
        _check(true);
    }
}
