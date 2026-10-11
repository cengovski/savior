// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey, IPoolManagerMinimal} from "../src/IV4Minimal.sol";
import {SaviorTokenV2} from "../src/fresh/SaviorTokenV2.sol";
import {SaviorStakingFresh, ILuckySink} from "../src/fresh/SaviorStakingFresh.sol";
import {SaviorLuckyNFT} from "../src/fresh/SaviorLuckyNFT.sol";

/// Exposes _pushPending so eligible (buy-created) locks can be made without a pool. Buy-path eligibility
/// (>= 10 USDC gross input) is covered on the Arc fork in LuckySeaDropFork.t.sol.
contract StakingHarness is SaviorStakingFresh {
    constructor(address o, IERC20 s, PoolKey memory k, ILuckySink sink)
        SaviorStakingFresh(o, s, IPoolManagerMinimal(address(0xBEEF)), address(0x7EA5), k, sink)
    {}

    function pushLock(address u, uint128 amt, bool lucky) external returns (uint256) {
        return _pushPending(u, amt, lucky);
    }
}

contract RevertingSink {
    address public staking;
    constructor(address s) { staking = s; }
    function onWin(address, uint256) external pure { revert("boom"); }
}

contract LuckyNftTest is Test {
    SaviorTokenV2 token;
    StakingHarness st;
    SaviorLuckyNFT nft;
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    function _key() internal view returns (PoolKey memory) {
        return PoolKey(address(0x3600000000000000000000000000000000000000), address(token), 10000, 200, address(0x2080));
    }

    function setUp() public {
        vm.roll(1000);
        token = new SaviorTokenV2(address(this), owner, "ipfs://x");
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        nft = new SaviorLuckyNFT(owner, predicted, 0, "ipfs://lucky/", false, "ipfs://lucky/contract.json");
        st = new StakingHarness(owner, IERC20(address(token)), _key(), ILuckySink(address(nft)));
        assertEq(address(st), predicted);
        token.transfer(address(st), 1_000_000e6);
    }

    /// Lock for `u` whose target block will carry a hash that makes it WIN (or LOSE if !win).
    function _lock(address u, bool lucky, bool win) internal returns (uint256 i) {
        i = st.pushLock(u, 1e6, lucky);
        SaviorStakingFresh.LockView[] memory v = st.getLocks(u, i, 1);
        uint64 created = v[0].createdAt;
        bytes32 h;
        for (uint256 k = 1;; ++k) {
            h = keccak256(abi.encode(k, u, i, block.number));
            if (st.isLuckyWin(h, u, i, created) == win) break;
        }
        _tb.push(v[0].targetBlock);
        _th.push(h);
    }

    uint64[] internal _tb;
    bytes32[] internal _th;

    /// Move past all target blocks, then pin their hashes (setBlockhash needs block <= current).
    function _past() internal {
        vm.roll(block.number + 4);
        for (uint256 k; k < _tb.length; ++k) vm.setBlockhash(_tb[k], _th[k]);
    }

    function test_distribution_about_5pct_and_independent_of_duration() public view {
        uint256 wins;
        uint256 n = 20_000;
        uint256 shortWins;
        uint256 shortN;
        for (uint256 k; k < n; ++k) {
            bytes32 h = keccak256(abi.encode("seed", k));
            bool w = st.isLuckyWin(h, alice, k % 7, uint64(k));
            if (w) ++wins;
            uint256 r = uint256(keccak256(abi.encode(h, alice, k % 7, uint64(k)))) % (5 days + 1);
            if (r < 2.5 days) {
                ++shortN;
                if (w) ++shortWins;
            }
        }
        console2.log("wins / 20000", wins);
        assertGt(wins, 850); // 4.25%
        assertLt(wins, 1150); // 5.75%
        // independence: win rate in the short-duration half ~ overall
        uint256 a = shortWins * 10_000 / shortN;
        assertGt(a, 400);
        assertLt(a, 600);
    }

    function test_not_eligible_never_mints_even_on_winning_hash() public {
        uint256 i = _lock(alice, false, true);
        _past();
        st.reveal(alice, i);
        assertEq(nft.totalSupply(), 0);
        assertFalse(st.luckyEligible(alice, i));
    }

    function test_third_party_reveal_mints_to_lock_owner() public {
        uint256 i = _lock(alice, true, true);
        _past();
        vm.prank(keeper);
        st.reveal(alice, i);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.balanceOf(keeper), 0);
    }

    function test_losing_hash_no_mint() public {
        uint256 i = _lock(alice, true, false);
        _past();
        st.reveal(alice, i);
        assertEq(nft.totalSupply(), 0);
    }

    function test_batch_by_third_party_mints_to_each_owner() public {
        uint256 a = _lock(alice, true, true);
        vm.roll(block.number + 1);
        uint256 b = _lock(bob, true, true);
        vm.roll(block.number + 1);
        uint256 c = _lock(bob, true, false);
        _past();
        address[] memory us = new address[](3);
        uint256[] memory is_ = new uint256[](3);
        (us[0], us[1], us[2]) = (alice, bob, bob);
        (is_[0], is_[1], is_[2]) = (a, b, c);
        vm.prank(keeper);
        assertEq(st.revealBatch(us, is_), 3);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.ownerOf(2), bob);
        assertEq(nft.totalSupply(), 2);
    }

    function test_window_missed_no_nft() public {
        uint256 i = _lock(alice, true, true);
        _past();
        vm.roll(block.number + 3 + 8191 + 300); // native + EIP-2935 windows both gone (history contract absent)
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        st.claim(i);
        assertEq(nft.totalSupply(), 0);
    }

    function test_claim_auto_reveal_mints() public {
        uint256 i = _lock(alice, true, true);
        _past();
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        st.claim(i);
        assertEq(nft.ownerOf(1), alice);
    }

    function test_only_staking_can_mint() public {
        vm.expectRevert(SaviorLuckyNFT.NotMinter.selector);
        nft.onWin(alice, 0);
        vm.expectRevert(SaviorLuckyNFT.NotMinter.selector);
        vm.prank(owner);
        nft.mint(alice);
    }

    function test_low_gas_reveal_reverts_not_skips() public {
        uint256 i = _lock(alice, true, true);
        _past();
        vm.prank(keeper);
        (bool ok,) = address(st).call{gas: 150_000}(abi.encodeCall(st.reveal, (alice, i)));
        assertFalse(ok);
        assertTrue(st.isPending(alice, i)); // draw not consumed
        st.reveal(alice, i);
        assertEq(nft.ownerOf(1), alice);
    }

    function test_sink_revert_never_blocks_reveal() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        RevertingSink bad = new RevertingSink(predicted);
        StakingHarness s2 = new StakingHarness(owner, IERC20(address(token)), _key(), ILuckySink(address(bad)));
        st = s2;
        uint256 i = _lock(alice, true, true);
        _past();
        st.reveal(alice, i);
        assertFalse(st.isPending(alice, i));
        assertEq(st.luckyFailed(alice), 1);
    }

    function test_cap_returns_zero_never_reverts() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        nft = new SaviorLuckyNFT(owner, predicted, 1, "ipfs://u", true, "");
        st = new StakingHarness(owner, IERC20(address(token)), _key(), ILuckySink(address(nft)));
        uint256 a = _lock(alice, true, true);
        vm.roll(block.number + 1);
        uint256 b = _lock(bob, true, true);
        _past();
        st.reveal(alice, a);
        st.reveal(bob, b);
        assertEq(nft.totalSupply(), 1);
        assertEq(nft.tokenURI(1), "ipfs://u");
    }

    /// Gas: own-ERC721 option, MAX_REVEAL_BATCH all winners.
    function test_gas_batch_all_winners_ownNft() public {
        uint256 n = st.MAX_REVEAL_BATCH();
        address[] memory us = new address[](n);
        uint256[] memory is_ = new uint256[](n);
        for (uint256 k; k < n; ++k) {
            us[k] = address(uint160(0x1000 + k));
            is_[k] = _lock(us[k], true, true);
            vm.roll(block.number + 1);
        }
        _past();
        uint256 g = gasleft();
        st.revealBatch(us, is_);
        uint256 used = g - gasleft();
        console2.log("ownNFT revealBatch all winners, n", n);
        console2.log("gas", used);
        console2.log("per item", used / n);
        assertEq(nft.totalSupply(), n);
    }
}
