// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SaviorStakingV2} from "../src/SaviorStakingV2.sol";
import {ArcAddresses as A} from "../src/ArcAddresses.sol";

interface IStakingV1 {
    function globalUnlock() external view returns (bool);
    function keySet() external view returns (bool);
    function owner() external view returns (address);
    function emergencyUnlockAll() external;
}

/// Fork tests against Arc Mainnet. Read-only simulation on a local fork; nothing is broadcast.
/// Run: forge test --match-contract ArcFork --fork-url arc   (skipped when ARC_FORK is unset)
contract ArcForkTest is Test {
    bool forked;

    function setUp() public {
        if (!vm.envOr("ARC_FORK", false)) return;
        vm.createSelectFork("arc_mainnet");
        forked = true;
    }

    function test_fork_chainAndCode() public view {
        if (!forked) return;
        assertEq(block.chainid, A.CHAIN_ID);
        assertGt(A.STAKING_V1.code.length, 0);
        assertGt(A.POOL_MANAGER.code.length, 0);
        assertGt(A.POSITION_MANAGER.code.length, 0);
        assertGt(A.UNIVERSAL_ROUTER.code.length, 0);
        assertGt(A.PERMIT2.code.length, 0);
        assertEq(IERC20Metadata(A.SAVIOR_TOKEN).decimals(), 6);
    }

    function test_fork_v1State() public view {
        if (!forked) return;
        IStakingV1 v1 = IStakingV1(A.STAKING_V1);
        assertEq(v1.owner(), address(0)); // owner() returns 0 -> rescue/upgradeToAndCall uncallable
        v1.globalUnlock();
        v1.keySet();
    }

    function test_fork_v1EmergencyUnlockGatedByDeployer() public {
        if (!forked) return;
        IStakingV1 v1 = IStakingV1(A.STAKING_V1);
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes4(0x30cd7471)); // NotOwner()
        v1.emergencyUnlockAll();
        // simulated only on local fork: deployer can flip it
        vm.prank(A.DEPLOYER);
        v1.emergencyUnlockAll();
        assertTrue(v1.globalUnlock());
    }

    function test_fork_v2WithRealSavior() public {
        if (!forked) return;
        address owner = makeAddr("owner");
        address user = makeAddr("user");
        SaviorStakingV2 st = new SaviorStakingV2(owner, IERC20(A.SAVIOR_TOKEN));
        deal(A.SAVIOR_TOKEN, user, 100e6);
        vm.startPrank(user);
        IERC20(A.SAVIOR_TOKEN).approve(address(st), 100e6);
        st.stake(100e6);
        vm.expectRevert(SaviorStakingV2.Locked.selector);
        st.claim(0);
        vm.stopPrank();
        vm.prank(owner); st.emergencyUnlockAll();
        vm.prank(user); st.claim(0);
        assertEq(IERC20(A.SAVIOR_TOKEN).balanceOf(user), 100e6);
    }
}
