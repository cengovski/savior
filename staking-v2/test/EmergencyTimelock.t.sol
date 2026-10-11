// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SaviorStakingFresh} from "../src/fresh/SaviorStakingFresh.sol";
import {SaviorTokenV2} from "../src/fresh/SaviorTokenV2.sol";
import {PoolKey, IPoolManagerMinimal} from "../src/IV4Minimal.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract EmergencyTimelockTest is Test {
    SaviorTokenV2 token;
    SaviorStakingFresh st;
    address owner = address(this);
    address user = makeAddr("user");

    function setUp() public {
        token = new SaviorTokenV2(user, owner, "x");
        PoolKey memory k = PoolKey(address(0x3600000000000000000000000000000000000000), address(token), 10000, 200, address(1));
        if (address(token) < k.currency0) k = PoolKey(address(token), k.currency0, 10000, 200, address(1));
        st = new SaviorStakingFresh(owner, IERC20(address(token)), IPoolManagerMinimal(address(2)), address(3), k);
        vm.prank(user);
        token.approve(address(st), type(uint256).max);
    }

    function test_execute_before_48h_reverts_after_ok() public {
        vm.prank(user);
        uint256 idx = st.stake(10e6);
        st.scheduleEmergencyUnlock();
        (bool s, uint64 a, bool e) = st.emergencyUnlockStatus();
        assertTrue(s); assertEq(a, block.timestamp + 48 hours); assertFalse(e);
        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectRevert(SaviorStakingFresh.TimelockActive.selector);
        st.executeEmergencyUnlock();
        vm.warp(block.timestamp + 1);
        st.executeEmergencyUnlock();
        (s,, e) = st.emergencyUnlockStatus();
        assertFalse(s); assertTrue(e); assertTrue(st.globalUnlock());
        vm.prank(user);
        st.claim(idx);
        vm.expectRevert(SaviorStakingFresh.AlreadyUnlocked.selector);
        st.scheduleEmergencyUnlock();
    }

    function test_cancel_then_execute_reverts() public {
        st.scheduleEmergencyUnlock();
        st.cancelEmergencyUnlock();
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(SaviorStakingFresh.NotScheduled.selector);
        st.executeEmergencyUnlock();
        vm.expectRevert(SaviorStakingFresh.NotScheduled.selector);
        st.cancelEmergencyUnlock();
    }

    function test_reschedule_resets_clock() public {
        st.scheduleEmergencyUnlock();
        vm.warp(block.timestamp + 47 hours);
        st.scheduleEmergencyUnlock(); // resets
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(SaviorStakingFresh.TimelockActive.selector);
        st.executeEmergencyUnlock();
        vm.warp(block.timestamp + 46 hours);
        st.executeEmergencyUnlock();
        assertTrue(st.globalUnlock());
    }

    function test_owner_only() public {
        address x = makeAddr("x");
        vm.startPrank(x);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, x));
        st.scheduleEmergencyUnlock();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, x));
        st.cancelEmergencyUnlock();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, x));
        st.executeEmergencyUnlock();
        vm.stopPrank();
    }
}
