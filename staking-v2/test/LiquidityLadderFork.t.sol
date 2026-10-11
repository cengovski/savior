// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "../src/IV4Minimal.sol";
import {LiquidityRescue} from "../src/LiquidityRescue.sol";
import {ArcPrecompiles} from "./utils/ArcPrecompiles.sol";

interface IUUPS {
    function upgradeToAndCall(address, bytes calldata) external payable;
    function owner() external view returns (address);
    function transferOwnership(address) external;
}

interface IPosm {
    function modifyLiquidities(bytes calldata, uint256) external payable;
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256) external view returns (address);
}

interface IPermit2 {
    function approve(address, address, uint160, uint48) external;
}

interface V2 {
    function swapExactIn(bool, uint256, uint256, uint256) external returns (uint256);
}

interface ISV {
    function getSlot0(bytes32) external view returns (uint160, int24, uint24, uint24);
    function getLiquidity(bytes32) external view returns (uint128);
    function getPositionInfo(bytes32, address, int24, int24, bytes32)
        external
        view
        returns (uint128, uint256, uint256);
}

/// @dev Arc fork E2E. Mainnet caveat: legacy proxy owner() == address(0) (renounced), so the
///      first step (transferOwnership from address(0)) is IMPOSSIBLE on-chain. The fork uses
///      vm.prank(address(0)) only to prove the rescue+ladder math; admin UI will surface NotOwner.
contract LiquidityLadderForkTest is Test {
    address constant D = 0x7185d50557040047A142aEadA95e41C4b31720e7;
    address constant LEGACY = 0x61096C5850d492530524c14c0602757f1d9d3c95;
    address constant USDC = 0x3600000000000000000000000000000000000000;
    IERC20 constant SAV = IERC20(0xe4065efC5E19305e4ed1dfdB6542A32A34E0cAf3);
    address constant HOOK = 0xFfcf2eF82AA17Fb31F3618E0302F9adC92D060c0;
    IPosm constant P = IPosm(0x6049c9a0e26405C0985f9E3685C87d0aE917f82B);
    address constant P2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    V2 constant ST = V2(0x8807DA96A254B370e1E9ae8d3cc4163d1E2939bB);
    ISV constant SV = ISV(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b);
    bytes32 constant PID = 0x004d7e7f668a78ea18228d753008ccf0c2b6b9e7c6c03d7a44d7cd954d072ab6;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // 20 SAVIOR-only ranges (currency1 below price), tickSpacing 200 aligned.
    // 16x width 1800 + 4x width 1600, starting at 121800 going down.
    // Sized for ~50_000 USDC gross (incl. 1% pool fee) to buy out ALL SAVIOR.
    int24[21] internal TICKS = [
        int24(121800),
        120000,
        118200,
        116400,
        114600,
        112800,
        111000,
        109200,
        107400,
        105600,
        103800,
        102000,
        100200,
        98400,
        96600,
        94800,
        93000,
        91400,
        89800,
        88200,
        86600
    ];
    uint160[21] internal SQRT = [
        uint160(34962360349697265032986773817444),
        31953335214378312554014683580590,
        29203280931553866779873355698343,
        26689909251898744636872781992034,
        24392850157630797652685242206350,
        22293486770484211798113310380059,
        20374804468278937933786501323173,
        18621252987227656732820051416783,
        17018620392366642985394678120592,
        15553917894683978985743565222032,
        14215274581427338678292663124139,
        12991841206416493925970834189792,
        11873702260613933624349404812283,
        10851795610315646184681248037272,
        9917839051657088880707386496347,
        9064263186183736465700110338626,
        8284150073465667804633817457384,
        7647264935695662854132592423401,
        7059343502725204859575735652508,
        6516621446819952884979925665545,
        6015623841616429162295202690126
    ];

    bool forked;

    function setUp() public {
        forked = vm.envOr("ARC_FORK", false);
        if (!forked) return;
        vm.createSelectFork("arc_mainnet");
        ArcPrecompiles.install(vm);
    }

    /// @dev Mainnet-impossible step: restore owner via address(0). Documents the blocker.
    function _restoreOwnerCheat() internal {
        require(IUUPS(LEGACY).owner() == address(0), "expected renounced");
        vm.prank(address(0));
        IUUPS(LEGACY).transferOwnership(D);
        require(IUUPS(LEGACY).owner() == D, "restore failed");
    }

    function _rescue() internal returns (uint256 gotU, uint256 gotS) {
        int24[] memory lo = new int24[](5);
        int24[] memory hi = new int24[](5);
        for (uint256 i; i < 5; ++i) {
            lo[i] = int24(121000 + int256(i) * 200);
            hi[i] = lo[i] + 200;
        }
        uint256 u0 = IERC20(USDC).balanceOf(D);
        uint256 s0 = SAV.balanceOf(D);
        address oldImpl = address(uint160(uint256(vm.load(LEGACY, IMPL_SLOT))));
        vm.startPrank(D);
        LiquidityRescue r = new LiquidityRescue();
        IUUPS(LEGACY).upgradeToAndCall(
            address(r), abi.encodeCall(LiquidityRescue.withdrawAllAndRestore, (lo, hi))
        );
        vm.stopPrank();
        assertEq(address(uint160(uint256(vm.load(LEGACY, IMPL_SLOT)))), oldImpl, "impl restored");
        assertEq(SV.getLiquidity(PID), 0, "pool empty");
        for (uint256 i; i < 5; ++i) {
            (uint128 l,,) = SV.getPositionInfo(PID, LEGACY, lo[i], hi[i], 0);
            assertEq(l, 0);
        }
        gotU = IERC20(USDC).balanceOf(D) - u0;
        gotS = SAV.balanceOf(D) - s0;
    }

    function test_fork_mainnet_owner_renounced() public {
        vm.skip(!forked);
        assertEq(IUUPS(LEGACY).owner(), address(0), "owner renounced on mainnet");
        LiquidityRescue r = new LiquidityRescue();
        int24[] memory lo = new int24[](1);
        int24[] memory hi = new int24[](1);
        lo[0] = 121000;
        hi[0] = 121200;
        vm.prank(D);
        vm.expectRevert(); // NotOwner
        IUUPS(LEGACY).upgradeToAndCall(
            address(r), abi.encodeCall(LiquidityRescue.withdrawAllAndRestore, (lo, hi))
        );
    }

    function test_fork_rescue_ladder_buyout() public {
        vm.skip(!forked);
        _restoreOwnerCheat();
        (uint256 gotU, uint256 gotS) = _rescue();
        console2.log("rescued USDC (raw)", gotU);
        console2.log("rescued SAVIOR (raw)", gotS);
        uint256 total = SAV.balanceOf(D);
        console2.log("deployer SAVIOR after rescue", total);

        uint256 a = total / 20;
        PoolKey memory key = PoolKey(USDC, address(SAV), 10000, 200, HOOK);
        bytes memory actions = new bytes(21);
        bytes[] memory ps = new bytes[](21);
        for (uint256 i; i < 20; ++i) {
            actions[i] = bytes1(0x02); // MINT_POSITION
            uint256 L = a * (1 << 96) / (SQRT[i] - SQRT[i + 1]);
            ps[i] = abi.encode(key, TICKS[i + 1], TICKS[i], L, uint128(0), uint128(a), D, bytes(""));
        }
        actions[20] = bytes1(0x0d); // SETTLE_PAIR
        ps[20] = abi.encode(USDC, address(SAV));

        uint256 firstId = P.nextTokenId();
        vm.startPrank(D);
        SAV.approve(P2, type(uint256).max);
        IPermit2(P2).approve(address(SAV), address(P), type(uint160).max, uint48(block.timestamp + 3600));
        P.modifyLiquidities(abi.encode(actions, ps), block.timestamp + 600);
        vm.stopPrank();

        uint256 poolSav = SAV.balanceOf(PM);
        console2.log("deployer SAVIOR left (dust)", SAV.balanceOf(D));
        console2.log("pool SAVIOR after ladder", poolSav);
        for (uint256 i; i < 20; ++i) {
            assertEq(P.ownerOf(firstId + i), D);
        }

        address b = makeAddr("whale");
        vm.deal(b, 200_000 ether);
        uint256 u0 = IERC20(USDC).balanceOf(b);
        uint256 pm0 = SAV.balanceOf(PM);
        vm.startPrank(b);
        IERC20(USDC).approve(address(ST), type(uint256).max);
        ST.swapExactIn(true, 100_000e6, 0, block.timestamp);
        vm.stopPrank();
        uint256 spent = u0 - IERC20(USDC).balanceOf(b);
        (, int24 t,,) = SV.getSlot0(PID);
        console2.log("SAVIOR bought out of pool", pm0 - SAV.balanceOf(PM));
        console2.log("buyer wallet SAVIOR", SAV.balanceOf(b));
        console2.log("gross USDC spent", spent);
        console2.logInt(t);
        assertApproxEqRel(spent, 50_000e6, 0.02e18, "~50k USDC +/-2%");
        assertLt(SAV.balanceOf(PM), 1e6, "pool nearly empty of SAVIOR");
    }
}
