// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SaviorStakingV2} from "../src/SaviorStakingV2.sol";
import {PoolKey, IPoolManagerMinimal} from "../src/IV4Minimal.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Savior", "SAVIOR") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract SaviorStakingV2Test is Test {
    MockToken tok;
    MockToken other;
    SaviorStakingV2 st;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        tok = new MockToken();
        other = new MockToken();
        st = _deploy(owner);
        tok.mint(alice, 1_000e6);
        tok.mint(bob, 1_000e6);
        vm.prank(alice);
        tok.approve(address(st), type(uint256).max);
        vm.prank(bob);
        tok.approve(address(st), type(uint256).max);
    }

    address pm = makeAddr("poolManager");
    address treasury = makeAddr("treasury");

    function _key() internal view returns (PoolKey memory k) {
        k = PoolKey(address(0x3600000000000000000000000000000000000000), address(tok), 10000, 200, address(0));
        if (k.currency0 > k.currency1) (k.currency0, k.currency1) = (k.currency1, k.currency0);
    }

    function _deploy(address o) internal returns (SaviorStakingV2) {
        return new SaviorStakingV2(o, IERC20(address(tok)), IPoolManagerMinimal(pm), treasury, _key());
    }

    function test_unlockCallbackOnlyPoolManager() public {
        vm.expectRevert(SaviorStakingV2.OnlyPoolManager.selector);
        st.unlockCallback(abi.encode(true, uint256(1)));
    }

    function test_swapZeroReverts() public {
        vm.expectRevert(SaviorStakingV2.Bad.selector);
        st.swapExactIn(true, 0, 0);
    }

    function test_keySet() public view {
        assertTrue(st.keySet());
        (address c0, address c1,,,) = st.key();
        assertLt(uint160(c0), uint160(c1));
    }

    function test_constructor() public view {
        assertEq(st.owner(), owner);
        assertEq(address(st.savior()), address(tok));
        assertEq(st.LOCK_DURATION(), 432000);
        assertFalse(st.globalUnlock());
    }

    function test_constructor_zeroOwnerReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        _deploy(address(0));
    }

    function test_selectorsMatchV1() public pure {
        assertEq(SaviorStakingV2.claim.selector, bytes4(0x379607f5));
        assertEq(SaviorStakingV2.getLocks.selector, bytes4(0x719f3089));
        assertEq(bytes4(keccak256("globalUnlock()")), bytes4(0x06aec0ef));
        assertEq(SaviorStakingV2.emergencyUnlockAll.selector, bytes4(0xe20cc079));
        assertEq(SaviorStakingV2.rescue.selector, bytes4(0x7a4e4ecf));
        assertEq(SaviorStakingV2.Locked.selector, bytes4(0x0f2e5b6c));
        assertEq(SaviorStakingV2.swapExactIn.selector, bytes4(0x1d2105ba));
        assertEq(SaviorStakingV2.unlockCallback.selector, bytes4(0x91dd7346));
        assertEq(bytes4(keccak256("lastBuyBlock(address)")), bytes4(0x37b28bfd));
        assertEq(bytes4(keccak256("treasury()")), bytes4(0x61d027b3));
        assertEq(bytes4(keccak256("keySet()")), bytes4(0x788499c0));
        assertEq(SaviorStakingV2.SameBlock.selector, bytes4(0x6dde4588));
        assertEq(SaviorStakingV2.Bad.selector, bytes4(0xe143a034));
    }

    function test_stake() public {
        vm.prank(alice);
        uint256 i = st.stake(100e6);
        assertEq(i, 0);
        SaviorStakingV2.Lock[] memory ls = st.getLocks(alice);
        assertEq(ls.length, 1);
        assertEq(ls[0].amount, 100e6);
        assertGe(ls[0].unlockAt, block.timestamp + 5 days);
        assertLe(ls[0].unlockAt, block.timestamp + 10 days);
        assertEq(st.totalLocked(), 100e6);
        assertEq(tok.balanceOf(address(st)), 100e6);
    }

    function test_stakeZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(SaviorStakingV2.ZeroAmount.selector);
        st.stake(0);
    }

    function test_stakeFor() public {
        vm.prank(alice);
        st.stakeFor(bob, 10e6);
        assertEq(st.getLocks(bob)[0].amount, 10e6);
        assertEq(st.getLocks(alice).length, 0);
    }

    function testFuzz_lockWithin5to10Days(uint96 amt, uint32 blk) public {
        amt = uint96(bound(amt, 1, 1_000e6));
        vm.roll(uint256(blk) + 2);
        vm.prank(alice);
        st.stake(amt);
        uint256 u = st.getLocks(alice)[0].unlockAt;
        assertGe(u, block.timestamp + 5 days);
        assertLe(u, block.timestamp + 10 days);
    }

    function test_lockEnforced() public {
        vm.prank(alice);
        st.stake(100e6);
        vm.warp(st.getLocks(alice)[0].unlockAt - 1);
        vm.prank(alice);
        vm.expectRevert(SaviorStakingV2.Locked.selector);
        st.claim(0);
    }

    function test_claimAfterUnlock() public {
        vm.prank(alice);
        st.stake(100e6);
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        st.claim(0);
        assertEq(tok.balanceOf(alice), 1_000e6);
        assertEq(st.totalLocked(), 0);
        vm.prank(alice);
        vm.expectRevert(SaviorStakingV2.NothingToClaim.selector);
        st.claim(0);
    }

    function test_claimBadIndex() public {
        vm.prank(alice);
        vm.expectRevert(SaviorStakingV2.BadIndex.selector);
        st.claim(0);
    }

    function test_cannotClaimOthersLock() public {
        vm.prank(alice);
        st.stake(100e6);
        vm.warp(block.timestamp + 6 days);
        vm.prank(bob);
        vm.expectRevert(SaviorStakingV2.BadIndex.selector);
        st.claim(0);
    }

    function test_emergencyUnlockBypassesLock() public {
        vm.prank(alice);
        st.stake(100e6);
        vm.prank(bob);
        st.stake(50e6);
        vm.prank(owner);
        st.emergencyUnlockAll();
        assertTrue(st.globalUnlock());
        vm.prank(alice);
        st.claim(0);
        vm.prank(bob);
        st.claim(0);
        assertEq(tok.balanceOf(alice), 1_000e6);
        assertEq(tok.balanceOf(bob), 1_000e6);
    }

    function test_emergencyUnlockOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        st.emergencyUnlockAll();
    }

    function test_rescueOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        st.rescue(address(other), 1);
    }

    function test_rescueOtherToken() public {
        other.mint(address(st), 5e6);
        vm.prank(owner);
        st.rescue(address(other), 5e6);
        assertEq(other.balanceOf(owner), 5e6);
    }

    function test_rescueSaviorLockedReverts() public {
        vm.prank(alice);
        st.stake(100e6);
        vm.prank(owner);
        vm.expectRevert(SaviorStakingV2.ExceedsSurplus.selector);
        st.rescue(address(tok), 1);
    }

    function test_rescueSaviorSurplusOnly() public {
        vm.prank(alice);
        st.stake(100e6);
        tok.mint(address(st), 7e6); // accidental direct transfer
        vm.startPrank(owner);
        vm.expectRevert(SaviorStakingV2.ExceedsSurplus.selector);
        st.rescue(address(tok), 7e6 + 1);
        st.rescue(address(tok), 7e6);
        vm.stopPrank();
        assertEq(tok.balanceOf(address(st)), st.totalLocked());
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        st.claim(0);
    }

    function testFuzz_rescueNeverBelowTotalLocked(uint96 staked, uint96 extra, uint96 take) public {
        staked = uint96(bound(staked, 1, 1_000e6));
        tok.mint(alice, staked);
        vm.prank(alice);
        st.stake(staked);
        tok.mint(address(st), extra);
        vm.prank(owner);
        if (take > extra) vm.expectRevert(SaviorStakingV2.ExceedsSurplus.selector);
        st.rescue(address(tok), take);
        assertGe(tok.balanceOf(address(st)), st.totalLocked());
    }

    function test_twoStepOwnership() public {
        vm.prank(owner);
        st.transferOwnership(bob);
        assertEq(st.owner(), owner);
        assertEq(st.pendingOwner(), bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        st.acceptOwnership();
        vm.prank(bob);
        st.acceptOwnership();
        assertEq(st.owner(), bob);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        st.emergencyUnlockAll();
        vm.prank(bob);
        st.emergencyUnlockAll();
    }

    function test_renounceDisabled() public {
        vm.prank(owner);
        vm.expectRevert(bytes("renounce disabled"));
        st.renounceOwnership();
        assertEq(st.owner(), owner);
    }
}
