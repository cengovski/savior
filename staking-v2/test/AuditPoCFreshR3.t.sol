// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "../src/IV4Minimal.sol";
import {SaviorTokenV2} from "../src/fresh/SaviorTokenV2.sol";
import {SaviorStakingFresh} from "../src/fresh/SaviorStakingFresh.sol";
import {FreshDeployer} from "../src/fresh/FreshDeployer.sol";
import {HookMiner} from "../src/fresh/HookMiner.sol";
import {FreshLadder} from "../src/fresh/FreshLadder.sol";
import {ArcAddresses as A} from "../src/ArcAddresses.sol";
import {ArcPrecompiles} from "./utils/ArcPrecompiles.sol";

interface IPermit2View {
    function allowance(address, address, address) external view returns (uint160, uint48, uint48);
}

/// RAPOR3 PoCs, adapted to prove the fixes (R3-1, R3-2, R3-5, R3-6).
contract AuditPoCFreshR3 is Test {
    address D = makeAddr("deployerR3");
    bool forked;
    SaviorTokenV2 t;
    FreshDeployer f;
    bytes32 salt;
    address hook;
    uint256 total;

    function setUp() public {
        forked = vm.envOr("ARC_FORK", false);
        if (!forked) return;
        vm.createSelectFork("arc_mainnet");
        ArcPrecompiles.install(vm);
        t = new SaviorTokenV2(D, D, "ipfs://x");
        total = t.balanceOf(D);
        vm.prank(D);
        f = new FreshDeployer(D, address(t), A.USDC, A.POOL_MANAGER, A.TREASURY, 10000, 200, A.POSITION_MANAGER, A.PERMIT2, keccak256(type(SaviorStakingFresh).creationCode), total);
        (salt, hook) = HookMiner.find(address(f), uint160((1 << 13) | (1 << 7)), f.hookInitCodeHash(), 0, 300_000);
        vm.prank(D);
        t.approve(address(f), total);
    }

    function _deploy(uint160 p, uint256 amt, bytes memory ladder) internal {
        bytes memory code = type(SaviorStakingFresh).creationCode;
        vm.prank(D);
        f.deploy(salt, p, amt, ladder, code, address(0));
    }

    /// Auditor PoC: ~99% in tranche 1, dust elsewhere -> was accepted (cheap buyout). Now reverts.
    function test_r3_skewedLadderAccepted_cheapBuyout() public {
        vm.skip(!forked);
        PoolKey memory k = f.poolKey(hook);
        bool c0 = f.saviorIsCurrency0();
        (bytes memory act, bytes[] memory big) = abi.decode(FreshLadder.build(k, c0, total * 99 / 100 * 20, D), (bytes, bytes[]));
        (, bytes[] memory small) = abi.decode(FreshLadder.build(k, c0, total / 100, D), (bytes, bytes[]));
        small[0] = big[0];
        bytes memory skewed = abi.encode(act, small);
        uint160 p = f.expectedSqrtPrice();
        vm.expectRevert(FreshDeployer.BadLadder.selector);
        _deploy(p, total, skewed);
    }

    function test_r3_wrongSqrtPrice_reverts() public {
        vm.skip(!forked);
        bytes memory l = FreshLadder.build(f.poolKey(hook), f.saviorIsCurrency0(), total, D);
        uint160 p = f.expectedSqrtPrice() / 2; // cheaper start
        vm.expectRevert(FreshDeployer.BadSqrtPrice.selector);
        _deploy(p, total, l);
    }

    function test_r3_5_zeroOrWrongLadderAmount_reverts() public {
        vm.skip(!forked);
        uint160 p = f.expectedSqrtPrice();
        vm.expectRevert(FreshDeployer.BadLadderAmount.selector);
        _deploy(p, 0, "");
        bytes memory l = FreshLadder.build(f.poolKey(hook), f.saviorIsCurrency0(), total / 2, D);
        vm.expectRevert(FreshDeployer.BadLadderAmount.selector);
        _deploy(p, total / 2, l);
        vm.expectRevert(FreshDeployer.BadLadderAmount.selector);
        new FreshDeployer(D, address(t), A.USDC, A.POOL_MANAGER, A.TREASURY, 10000, 200, A.POSITION_MANAGER, A.PERMIT2, bytes32(0), 0);
    }

    function test_r3_correctLadder_ok_and_permit2_cleared() public {
        vm.skip(!forked);
        bytes memory l = FreshLadder.build(f.poolKey(hook), f.saviorIsCurrency0(), total, D);
        assertEq(keccak256(l), f.expectedLadderHash(hook));
        _deploy(f.expectedSqrtPrice(), total, l);
        (uint160 amt,,) = IPermit2View(A.PERMIT2).allowance(address(f), address(t), A.POSITION_MANAGER);
        assertEq(amt, 0, "R3-2 permit2 residue");
        assertEq(t.allowance(address(f), A.PERMIT2), 0);
        assertEq(t.balanceOf(address(f)), 0);
    }
}

/// R3-6: EIP-170 size guard in the normal (non-fork) suite.
contract FreshSizeGuard is Test {
    function test_r3_6_runtime_sizes_under_eip170() public view {
        string[5] memory cs = [
            "FreshDeployer.sol:FreshDeployer",
            "SaviorStakingFresh.sol:SaviorStakingFresh",
            "SaviorHookFresh.sol:SaviorHookFresh",
            "LuckyDistributor.sol:LuckyDistributor",
            "SaviorTokenV2.sol:SaviorTokenV2"
        ];
        for (uint256 i; i < cs.length; ++i) {
            assertLt(vm.getDeployedCode(cs[i]).length, 24_576 - 1024, cs[i]); // keep >= 1 KB margin
        }
    }
}
