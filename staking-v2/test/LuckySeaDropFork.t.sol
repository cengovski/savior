// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PoolKey} from "../src/IV4Minimal.sol";
import {SaviorTokenV2} from "../src/fresh/SaviorTokenV2.sol";
import {SaviorStakingFresh, ILuckySink} from "../src/fresh/SaviorStakingFresh.sol";
import {FreshDeployer} from "../src/fresh/FreshDeployer.sol";
import {HookMiner} from "../src/fresh/HookMiner.sol";
import {LuckyDistributor, MintParams, ISeaDrop} from "../src/fresh/LuckyDistributor.sol";
import {ArcAddresses as A} from "../src/ArcAddresses.sol";
import {StakingHarness} from "./LuckyNft.t.sol";
import {FreshStackForkTest} from "./FreshStackFork.t.sol";

/// OpenSea ERC721SeaDropCloneable (impl used by OpenSea Studio drops on Arc, e.g. "The Arc Begins" clone
/// 0xb856...11de -> impl 0x09a2...6a). Only the functions used here.
interface IERC721SeaDropCloneable {
    function initialize(string calldata, string calldata, address[] calldata, address) external;
    function setMaxSupply(uint256) external;
    function updateAllowList(address seaDrop, AllowListData calldata) external;
    function updateAllowedFeeRecipient(address seaDrop, address feeRecipient, bool allowed) external;
    function updateCreatorPayoutAddress(address seaDrop, address payout) external;
    function totalSupply() external view returns (uint256);
    function ownerOf(uint256) external view returns (address);
    function getMintStats(address) external view returns (uint256, uint256, uint256);
}

struct AllowListData {
    bytes32 merkleRoot;
    string[] publicKeyURIs;
    string allowListURI;
}

/// Plain contract (no onERC721Received) trying to be the allow-listed minter.
contract NoReceiver {
    function mint(address nft, MintParams calldata p) external {
        ISeaDrop(LuckySeaDropForkTest(msg.sender).SEADROP()).mintAllowList(nft, LuckySeaDropForkTest(msg.sender).OS_FEE(), address(0), 1, p, new bytes32[](0));
    }
}

contract LuckySeaDropForkTest is FreshStackForkTest {
    address public constant SEADROP = 0x00005EA00Ac477B1030CE78506496e8C2dE24bf5;
    address public constant IMPL = 0x09a26fC8FCEF18192E267D7A6da9dFb4be81Dd6A;
    address public constant OS_FEE = 0x0000a26b00c1F0DF003000390027140000fAa719;

    address PAYOUT = address(0xC0FFEe0000000000000000000000000000001234);
    IERC721SeaDropCloneable nft;
    LuckyDistributor dist;
    StakingHarness hs;
    SaviorTokenV2 tok;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");
    uint64[] _tb;
    bytes32[] _th;

    function _params(uint256 price, uint256 maxWallet) internal view returns (MintParams memory) {
        return MintParams(price, maxWallet, block.timestamp - 1, type(uint64).max, 1, 1_000_000, 1000, true);
    }

    function _clone() internal {
        nft = IERC721SeaDropCloneable(Clones.clone(IMPL));
        address[] memory sd = new address[](1);
        sd[0] = SEADROP;
        nft.initialize("SAVIOR Lucky", "SVLUCKY", sd, D);
        vm.startPrank(D);
        nft.setMaxSupply(1_000_000);
        nft.updateAllowedFeeRecipient(SEADROP, OS_FEE, true);
        nft.updateCreatorPayoutAddress(SEADROP, PAYOUT);
        vm.stopPrank();
    }

    function _setRoot() internal {
        bytes32 leaf = dist.allowListLeaf();
        vm.prank(D);
        nft.updateAllowList(SEADROP, AllowListData(leaf, new string[](0), ""));
    }

    /// harness staking bound to a distributor bound to the real SeaDrop + real OpenSea clone impl
    function _harnessStack(uint256 price, uint256 maxWallet) internal {
        _clone();
        tok = new SaviorTokenV2(address(this), D, "ipfs://x");
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        dist = new LuckyDistributor(D, predicted, ISeaDrop(SEADROP), IERC721(address(nft)), OS_FEE, _params(price, maxWallet));
        PoolKey memory k = PoolKey(A.USDC, address(tok), 10000, 200, address(0x2080));
        if (address(tok) < A.USDC) k = PoolKey(address(tok), A.USDC, 10000, 200, address(0x2080));
        hs = new StakingHarness(D, IERC20(address(tok)), k, ILuckySink(address(dist)));
        assertEq(address(hs), predicted);
        tok.transfer(address(hs), 1_000_000e6);
        _setRoot();
    }

    function _lock(address u, bool win) internal returns (uint256 i) {
        i = hs.pushLock(u, 1e6, true);
        SaviorStakingFresh.LockView[] memory v = hs.getLocks(u, i, 1);
        bytes32 h;
        for (uint256 k = 1;; ++k) {
            h = keccak256(abi.encode(k, u, i, block.number));
            if (hs.isLuckyWin(h, u, i, v[0].createdAt) == win) break;
        }
        _tb.push(v[0].targetBlock);
        _th.push(h);
    }

    function _past() internal {
        vm.roll(block.number + 4);
        for (uint256 k; k < _tb.length; ++k) vm.setBlockhash(_tb[k], _th[k]);
    }

    function test_fork_seadrop_win_reserved_then_winner_pulls() public {
        vm.skip(!forked);
        _harnessStack(0, 1_000_000);
        uint256 i = _lock(alice, true);
        _past();
        uint256 supply0 = nft.totalSupply();
        uint256 g = gasleft();
        vm.prank(keeper);
        hs.reveal(alice, i);
        console2.log("reveal (winner, SeaDrop mint+reserve) gas", g - gasleft());
        uint256 id = supply0 + 1;
        assertEq(nft.ownerOf(id), address(dist));
        assertEq(dist.reservedFor(id), alice);
        assertEq(dist.owed(alice), 0);
        (uint256 minted,,) = nft.getMintStats(address(dist));
        assertEq(minted, 1);
        vm.prank(keeper);
        vm.expectRevert(LuckyDistributor.NotReserved.selector);
        dist.claimNFT(id);
        vm.prank(alice);
        dist.claimNFT(id);
        assertEq(nft.ownerOf(id), alice);
        assertEq(IERC721(address(nft)).balanceOf(keeper), 0);
    }

    function test_fork_seadrop_only_staking_can_trigger() public {
        vm.skip(!forked);
        _harnessStack(0, 1_000_000);
        vm.expectRevert(LuckyDistributor.NotStaking.selector);
        dist.onWin(alice, 0);
        // distributor is the only allow-list leaf: anyone else using its params is rejected by SeaDrop
        MintParams memory p = dist.mintParams();
        vm.expectRevert();
        ISeaDrop(SEADROP).mintAllowList(address(nft), OS_FEE, address(0), 1, p, new bytes32[](0));
    }

    function test_fork_seadrop_minter_needs_onERC721Received() public {
        vm.skip(!forked);
        _harnessStack(0, 1_000_000);
        NoReceiver nr = new NoReceiver();
        MintParams memory p = _params(0, 10);
        bytes32 leaf = keccak256(abi.encode(address(nr), p));
        vm.prank(D);
        nft.updateAllowList(SEADROP, AllowListData(leaf, new string[](0), ""));
        vm.expectRevert(); // ERC721SeaDrop mints with _safeMint
        nr.mint(address(nft), p);
    }

    function test_fork_seadrop_unfunded_price_defers_then_retry() public {
        vm.skip(!forked);
        _harnessStack(1e18, 1_000_000); // 1 USDC (native, 18 dec) price, distributor unfunded
        uint256 i = _lock(alice, true);
        _past();
        vm.prank(keeper);
        hs.reveal(alice, i); // never reverts
        assertFalse(hs.isPending(alice, i));
        assertEq(dist.owed(alice), 1);
        uint256 feeBal = OS_FEE.balance;
        uint256 creatorBefore = PAYOUT.balance;
        vm.deal(address(dist), 1e18); // prefund
        vm.prank(keeper);
        dist.retryMint(alice);
        assertEq(dist.owed(alice), 0);
        console2.log("OpenSea fee received (wei)", OS_FEE.balance - feeBal);
        console2.log("creator payout received (wei)", PAYOUT.balance - creatorBefore);
        assertEq(OS_FEE.balance - feeBal, 1e17); // feeBps 1000 = 10% of price to OpenSea
        assertEq(PAYOUT.balance - creatorBefore, 9e17); // rest to creator payout (Dzengo)
    }

    function test_fork_seadrop_maxPerWallet_limits_distributor() public {
        vm.skip(!forked);
        _harnessStack(0, 1);
        uint256 a = _lock(alice, true);
        vm.roll(block.number + 1);
        uint256 b = _lock(bob, true);
        _past();
        hs.reveal(alice, a);
        hs.reveal(bob, b); // second mint exceeds maxTotalMintableByWallet for the distributor -> deferred
        assertEq(dist.owed(bob), 1);
        assertEq(dist.owed(alice), 0);
    }

    function test_fork_seadrop_batch_gas_all_winners() public {
        vm.skip(!forked);
        _harnessStack(0, 1_000_000);
        uint256 n = hs.MAX_REVEAL_BATCH();
        address[] memory us = new address[](n);
        uint256[] memory is_ = new uint256[](n);
        for (uint256 k; k < n; ++k) {
            us[k] = address(uint160(0x5000 + k));
            is_[k] = _lock(us[k], true);
            vm.roll(block.number + 1);
        }
        _past();
        uint256 g = gasleft();
        vm.prank(keeper);
        hs.revealBatch(us, is_);
        uint256 used = g - gasleft();
        console2.log("SeaDrop revealBatch all winners n", n);
        console2.log("gas", used);
        console2.log("per item", used / n);
        for (uint256 k; k < n; ++k) assertEq(dist.owed(us[k]), 0);
    }

    /// Full stack via FreshDeployer with the distributor + real buys: < 10 USDC not eligible, >= 10 eligible.
    function test_fork_stack_with_distributor_buy_eligibility() public {
        vm.skip(!forked);
        _clone();
        SaviorTokenV2 t = _token(false);
        vm.prank(D);
        FreshDeployer f = new FreshDeployer(D, address(t), A.USDC, A.POOL_MANAGER, A.TREASURY, 10000, 200, A.POSITION_MANAGER, A.PERMIT2, keccak256(type(SaviorStakingFresh).creationCode));
        (bytes32 salt, address predicted) = HookMiner.find(address(f), uint160((1 << 13) | (1 << 7)), f.hookInitCodeHash(), 0, 200_000);
        uint256 total = t.balanceOf(D);
        vm.prank(D);
        t.approve(address(f), total);
        // wrongly bound sink is rejected
        LuckyDistributor wrong = new LuckyDistributor(D, address(0xdead), ISeaDrop(SEADROP), IERC721(address(nft)), OS_FEE, _params(0, 1e6));
        sink = address(wrong);
        bytes memory code = type(SaviorStakingFresh).creationCode;
        vm.expectRevert(FreshDeployer.BadLuckySink.selector);
        vm.prank(D);
        f.deploy(salt, 1, 0, "", code, sink);
        dist = new LuckyDistributor(D, f.predictStaking(), ISeaDrop(SEADROP), IERC721(address(nft)), OS_FEE, _params(0, 1e6));
        _setRoot();
        sink = address(dist);
        (address s_,) = _deployAll(f, salt, predicted, false, total);
        SaviorStakingFresh st = SaviorStakingFresh(s_);
        assertEq(address(st.luckySink()), address(dist));

        vm.deal(alice, 1000 ether);
        vm.startPrank(alice);
        IERC20(A.USDC).approve(s_, type(uint256).max);
        st.swapExactIn(true, 9_999_999, 1, block.timestamp); // 9.999999 USDC
        st.swapExactIn(true, 10e6, 1, block.timestamp); // exactly 10 USDC
        vm.stopPrank();
        assertFalse(st.luckyEligible(alice, 0));
        assertTrue(st.luckyEligible(alice, 1));
        // force a winning hash for lock 1 and let a third party reveal
        SaviorStakingFresh.LockView[] memory v = st.getLocks(alice, 1, 1);
        bytes32 h;
        for (uint256 k = 1;; ++k) {
            h = keccak256(abi.encode(k));
            if (st.isLuckyWin(h, alice, 1, v[0].createdAt)) break;
        }
        vm.roll(v[0].targetBlock + 1);
        vm.setBlockhash(v[0].targetBlock, h);
        vm.prank(keeper);
        st.reveal(alice, 1);
        uint256 id = nft.totalSupply();
        assertEq(dist.reservedFor(id), alice);
        vm.prank(alice);
        dist.claimNFT(id);
        assertEq(nft.ownerOf(id), alice);
    }
}
