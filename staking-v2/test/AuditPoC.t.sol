// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SaviorStakingV2} from "../src/SaviorStakingV2.sol";
import {PoolKey, IPoolManagerMinimal} from "../src/IV4Minimal.sol";

contract T is ERC20 {
    constructor() ERC20("S", "S") {}

    function mint(address a, uint256 x) external {
        _mint(a, x);
    }
}

contract FoT is ERC20 {
    constructor() ERC20("F", "F") {}

    function mint(address a, uint256 x) external {
        _mint(a, x);
    }

    function _update(address f, address t, uint256 v) internal override {
        if (f != address(0) && t != address(0)) {
            uint256 fee = v / 100;
            super._update(f, address(0xdead), fee);
            v -= fee;
        }
        super._update(f, t, v);
    }
}

contract AuditPoC is Test {
    T tok;
    SaviorStakingV2 st;
    address owner = makeAddr("o");
    address a = makeAddr("a");
    address v = makeAddr("victim");

    function _k(address t) internal pure returns (PoolKey memory k) {
        k = PoolKey(address(0x3600000000000000000000000000000000000000), t, 10000, 200, address(0));
        if (k.currency0 > k.currency1) (k.currency0, k.currency1) = (k.currency1, k.currency0);
    }

    function setUp() public {
        tok = new T();
        st = new SaviorStakingV2(
            owner, IERC20(address(tok)), IPoolManagerMinimal(makeAddr("pm")), makeAddr("tr"), _k(address(tok))
        );
        tok.mint(a, 1e12);
        vm.prank(a);
        tok.approve(address(st), type(uint256).max);
    }

    // Auditor PoC D-1 (original asserted the grind worked). After the fix the amount is not part of the seed:
    // trying 200 amounts in the same state yields one single unlockAt, so there is nothing to grind.
    function test_poc_grindMinLock() public {
        vm.roll(1000);
        vm.warp(1e9);
        uint256 snap = vm.snapshotState();
        vm.prank(a);
        st.stake(1e6);
        uint256 first = st.getLocks(a)[0].unlockAt;
        for (uint256 x = 1e6 + 1; x < 1e6 + 200; x++) {
            vm.revertToState(snap);
            vm.prank(a);
            st.stake(x);
            assertEq(st.getLocks(a)[0].unlockAt, first, "amount must not change lock time");
        }
        uint256 extra = first - block.timestamp - 5 days;
        console2.log("extra lock seconds (fixed for this state):", extra);
        assertLe(extra, 432000);
    }

    // Auditor PoC D-2: dust stakeFor spam now reverts below MIN_STAKE (1 SAVIOR)
    function test_poc_stakeForDustSpam() public {
        vm.startPrank(a);
        vm.expectRevert(SaviorStakingV2.BelowMinStake.selector);
        st.stakeFor(v, 1);
        // 500 spam locks now cost 500 SAVIOR of the attacker's own funds (they are the victim's to claim)
        for (uint256 i; i < 500; i++) {
            st.stakeFor(v, 1e6);
        }
        vm.stopPrank();
        assertEq(st.getLocks(v).length, 500);
        assertEq(st.totalLocked(), 500e6);
    }

    // rescue: donation is surplus; locked never touchable, even after emergencyUnlockAll
    function test_poc_rescueAfterEmergency() public {
        vm.prank(a);
        st.stake(100e6);
        tok.mint(address(st), 5e6);
        vm.startPrank(owner);
        st.emergencyUnlockAll();
        vm.expectRevert(SaviorStakingV2.ExceedsSurplus.selector);
        st.rescue(address(tok), 5e6 + 1);
        st.rescue(address(tok), 5e6);
        vm.stopPrank();
        vm.prank(a);
        st.claim(0);
        assertEq(tok.balanceOf(address(st)), 0);
    }

    // fee-on-transfer token: stake books received; claim pays booked amount -> solvency ok, user gets less
    function test_poc_fotStakeClaim() public {
        FoT f = new FoT();
        SaviorStakingV2 s2 = new SaviorStakingV2(
            owner, IERC20(address(f)), IPoolManagerMinimal(makeAddr("pm")), makeAddr("tr"), _k(address(f))
        );
        f.mint(a, 100e6);
        vm.startPrank(a);
        f.approve(address(s2), type(uint256).max);
        s2.stake(100e6);
        assertEq(s2.totalLocked(), 99e6);
        assertEq(f.balanceOf(address(s2)), 99e6);
        vm.warp(block.timestamp + 11 days);
        s2.claim(0);
        vm.stopPrank();
        assertEq(s2.totalLocked(), 0);
    }
}
