// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SaviorTokenV2} from "../../src/fresh/SaviorTokenV2.sol";
import {FreshDeployer} from "../../src/fresh/FreshDeployer.sol";
import {SaviorStakingFresh} from "../../src/fresh/SaviorStakingFresh.sol";
import {HookMiner} from "../../src/fresh/HookMiner.sol";
import {FreshLadder} from "../../src/fresh/FreshLadder.sol";
import {ArcAddresses as A} from "../../src/ArcAddresses.sol";
import {LuckyDistributor, MintParams, ISeaDrop} from "../../src/fresh/LuckyDistributor.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

struct AllowListData {
    bytes32 merkleRoot;
    string[] publicKeyURIs;
    string allowListURI;
}

interface ISeaDropNftAdmin {
    function updateAllowList(address seaDrop, AllowListData calldata) external;
    function updateAllowedFeeRecipient(address seaDrop, address feeRecipient, bool allowed) external;
    function updateCreatorPayoutAddress(address seaDrop, address payout) external;
}

/// Fresh-start deploy, one STEP per run (ordered; each step verifies the previous on-chain state).
/// NEVER broadcast from CI/bots. Default = simulation (no --broadcast). Owner signs via admin tab or:
///   STEP=1 forge script script/fresh/DeployFresh.s.sol --rpc-url arc_mainnet --sender $DEPLOYER
///   STEP=1 ... --account <keystore> --broadcast        (only with Dzengo's explicit go)
/// Steps (same order as the admin "Fresh start" tab):
///   1 token     : SaviorTokenV2(recipient=DEPLOYER, owner=DEPLOYER, LOGO_URI)
///   2 factory   : FreshDeployer(..., Posm, Permit2, stakingCodeHash, LADDER_AMOUNT). FACTORY only from THIS receipt (N-3).
///   3 lucky     : LUCKY_NFT = ERC721SeaDropCloneable created by DEPLOYER in OpenSea Studio (or a manual clone of impl
///                 0x09a2...Dd6A), then LuckyDistributor(staking = factory.predictStaking()). LUCKY_NFT unset = no lucky.
///   4 allowlist : nft.updateAllowList(SeaDrop, root = distributor.allowListLeaf()) (+ payout, fee recipient, maxSupply)
///   5 approve   : SAVIOR.approve(FACTORY, LADDER_AMOUNT)
///   6 deploy    : mine hook salt (0x2080) -> factory.deploy(salt, expectedSqrtPrice, LADDER_AMOUNT, ladderData, stakingCode, sink)
///                 factory enforces sqrtP, amount and keccak(ladderData) == expectedLadderHash(hook) (R3-1/R3-5)
///   7 verify    : read-only
/// Env: STEP, TOKEN, FACTORY, LOGO_URI, LADDER_AMOUNT (default full balance), LUCKY_NFT, DISTRIBUTOR, LUCKY_PAYOUT
contract DeployFresh is Script {
    uint160 constant FLAGS = uint160((1 << 13) | (1 << 7));
    address constant SEADROP = 0x00005EA00Ac477B1030CE78506496e8C2dE24bf5;
    address constant OS_FEE = 0x0000a26b00c1F0DF003000390027140000fAa719;

    function run() external {
        require(block.chainid == A.CHAIN_ID || vm.envOr("ALLOW_OTHER_CHAIN", false), "not Arc");
        uint256 step = vm.envUint("STEP");
        address deployer = msg.sender;
        console2.log("step", step, "sender", deployer);

        if (step == 1) {
            vm.startBroadcast();
            SaviorTokenV2 t = new SaviorTokenV2(deployer, deployer, vm.envOr("LOGO_URI", string("")));
            vm.stopBroadcast();
            console2.log("TOKEN", address(t));
            console2.log("saviorIsCurrency0", address(t) < A.USDC);
            return;
        }

        address token = vm.envAddress("TOKEN");
        require(token.code.length > 0, "TOKEN not deployed");
        require(SaviorTokenV2(payable(token)).owner() == deployer, "TOKEN owner != sender");

        if (step == 2) {
            uint256 amt2 = vm.envOr("LADDER_AMOUNT", SaviorTokenV2(payable(token)).balanceOf(deployer));
            vm.startBroadcast();
            FreshDeployer f = new FreshDeployer(
                deployer, token, A.USDC, A.POOL_MANAGER, A.TREASURY, A.POOL_FEE, A.POOL_TICK_SPACING,
                A.POSITION_MANAGER, A.PERMIT2, keccak256(type(SaviorStakingFresh).creationCode), amt2
            );
            vm.stopBroadcast();
            console2.log("FACTORY", address(f));
            console2.log("predicted STAKING", f.predictStaking());
            return;
        }

        FreshDeployer fac = FreshDeployer(vm.envAddress("FACTORY"));
        require(fac.admin() == deployer && fac.token() == token, "FACTORY mismatch");
        require(fac.positionManager() == A.POSITION_MANAGER && fac.permit2() == A.PERMIT2, "FACTORY periphery mismatch");
        require(fac.stakingCodeHash() == keccak256(type(SaviorStakingFresh).creationCode), "stakingCodeHash mismatch");
        uint256 amt = fac.expectedLadderAmount();
        address nft = vm.envOr("LUCKY_NFT", address(0));

        if (step == 3) {
            require(nft != address(0), "LUCKY_NFT (OpenSea clone) required");
            vm.startBroadcast();
            LuckyDistributor d = new LuckyDistributor(
                deployer, fac.predictStaking(), ISeaDrop(SEADROP), IERC721(nft), OS_FEE,
                MintParams(0, 1_000_000, block.timestamp, type(uint64).max, 1, 1_000_000, 1000, true)
            );
            vm.stopBroadcast();
            console2.log("DISTRIBUTOR", address(d));
            return;
        }

        address sink = vm.envOr("DISTRIBUTOR", address(0));
        if (sink != address(0)) require(LuckyDistributor(payable(sink)).staking() == fac.predictStaking(), "DISTRIBUTOR not bound");

        if (step == 4) {
            require(sink != address(0) && nft != address(0), "DISTRIBUTOR + LUCKY_NFT required");
            vm.startBroadcast();
            ISeaDropNftAdmin(nft).updateAllowList(SEADROP, AllowListData(LuckyDistributor(payable(sink)).allowListLeaf(), new string[](0), ""));
            ISeaDropNftAdmin(nft).updateAllowedFeeRecipient(SEADROP, OS_FEE, true);
            ISeaDropNftAdmin(nft).updateCreatorPayoutAddress(SEADROP, vm.envOr("LUCKY_PAYOUT", deployer));
            vm.stopBroadcast();
            return;
        }

        if (step == 5) {
            require(!fac.deployed(), "already deployed");
            vm.startBroadcast();
            SaviorTokenV2(payable(token)).approve(address(fac), amt);
            vm.stopBroadcast();
            console2.log("approved factory for SAVIOR", amt);
            return;
        }

        if (step == 6) {
            require(!fac.deployed(), "already deployed");
            require(SaviorTokenV2(payable(token)).allowance(deployer, address(fac)) >= amt, "step 5 first");
            require(SaviorTokenV2(payable(token)).balanceOf(deployer) == amt, "balance != ladder amount");
            (bytes32 salt, address hook) = HookMiner.find(address(fac), FLAGS, fac.hookInitCodeHash(), 0, 500_000);
            uint160 sqrtP = FreshLadder.startSqrtPrice(fac.saviorIsCurrency0());
            require(sqrtP == fac.expectedSqrtPrice(), "sqrtP mismatch");
            bytes memory ladder = FreshLadder.build(fac.poolKey(hook), fac.saviorIsCurrency0(), amt, deployer);
            require(keccak256(ladder) == fac.expectedLadderHash(hook), "ladder hash mismatch");
            console2.log("hook salt");
            console2.logBytes32(salt);
            console2.log("HOOK (predicted)", hook);
            vm.startBroadcast();
            fac.deploy(salt, sqrtP, amt, ladder, type(SaviorStakingFresh).creationCode, sink);
            vm.stopBroadcast();
            require(fac.hook() == hook && fac.staking() == fac.predictStaking(), "post-deploy mismatch");
            return;
        }

        if (step == 7) {
            require(fac.deployed(), "step 6 first");
            console2.log("STAKING", fac.staking());
            console2.log("HOOK", fac.hook());
            console2.log("deployer SAVIOR left", SaviorTokenV2(payable(token)).balanceOf(deployer));
            console2.log("PoolManager SAVIOR", SaviorTokenV2(payable(token)).balanceOf(A.POOL_MANAGER));
            return;
        }
        revert("unknown STEP");
    }
}
