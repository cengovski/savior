// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
// FORK TEST ONLY (anvil fork of Arc). Mirrors DeployFresh.s.sol steps 1-6 in one broadcast from the impersonated deployer.
import {Script, console2} from "forge-std/Script.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {SaviorTokenV2} from "../../src/fresh/SaviorTokenV2.sol";
import {FreshDeployer} from "../../src/fresh/FreshDeployer.sol";
import {SaviorStakingFresh} from "../../src/fresh/SaviorStakingFresh.sol";
import {HookMiner} from "../../src/fresh/HookMiner.sol";
import {FreshLadder} from "../../src/fresh/FreshLadder.sol";
import {ArcAddresses as A} from "../../src/ArcAddresses.sol";
import {LuckyDistributor, MintParams, ISeaDrop} from "../../src/fresh/LuckyDistributor.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

struct AllowListData { bytes32 merkleRoot; string[] publicKeyURIs; string allowListURI; }
interface ICloneNft {
    function initialize(string calldata, string calldata, address[] calldata, address) external;
    function setMaxSupply(uint256) external;
    function updateAllowList(address seaDrop, AllowListData calldata) external;
    function updateAllowedFeeRecipient(address seaDrop, address feeRecipient, bool allowed) external;
    function updateCreatorPayoutAddress(address seaDrop, address payout) external;
}

contract ForkSetup is Script {
    uint160 constant FLAGS = uint160((1 << 13) | (1 << 7));
    address constant SEADROP = 0x00005EA00Ac477B1030CE78506496e8C2dE24bf5;
    address constant OS_FEE = 0x0000a26b00c1F0DF003000390027140000fAa719;
    address constant IMPL = 0x09a26fC8FCEF18192E267D7A6da9dFb4be81Dd6A;

    function run() external {
        address d = msg.sender;
        vm.startBroadcast();
        SaviorTokenV2 t = new SaviorTokenV2(d, d, "");
        uint256 amt = t.balanceOf(d);
        FreshDeployer fac = new FreshDeployer(d, address(t), A.USDC, A.POOL_MANAGER, A.TREASURY, A.POOL_FEE, A.POOL_TICK_SPACING,
            A.POSITION_MANAGER, A.PERMIT2, keccak256(type(SaviorStakingFresh).creationCode), amt);
        ICloneNft nft = ICloneNft(Clones.clone(IMPL));
        address[] memory sd = new address[](1); sd[0] = SEADROP;
        nft.initialize("SAVIOR Lucky", "SVLUCKY", sd, d);
        nft.setMaxSupply(1_000_000);
        LuckyDistributor dist = new LuckyDistributor(d, fac.predictStaking(), ISeaDrop(SEADROP), IERC721(address(nft)), OS_FEE,
            MintParams(0, 1_000_000, block.timestamp, type(uint64).max, 1, 1_000_000, 1000, true));
        nft.updateAllowList(SEADROP, AllowListData(dist.allowListLeaf(), new string[](0), ""));
        nft.updateAllowedFeeRecipient(SEADROP, OS_FEE, true);
        nft.updateCreatorPayoutAddress(SEADROP, d);
        t.approve(address(fac), amt);
        vm.stopBroadcast();
        (bytes32 salt, address hook) = HookMiner.find(address(fac), FLAGS, fac.hookInitCodeHash(), 0, 500_000);
        uint160 sqrtP = FreshLadder.startSqrtPrice(fac.saviorIsCurrency0());
        bytes memory ladder = FreshLadder.build(fac.poolKey(hook), fac.saviorIsCurrency0(), amt, d);
        vm.startBroadcast();
        fac.deploy(salt, sqrtP, amt, ladder, type(SaviorStakingFresh).creationCode, address(dist));
        vm.stopBroadcast();
        console2.log("TOKEN", address(t));
        console2.log("HOOK", fac.hook());
        console2.log("STAKING", fac.staking());
        console2.log("DISTRIBUTOR", address(dist));
        console2.log("NFT", address(nft));
        console2.log("SAVIOR_IS_C0", fac.saviorIsCurrency0());
    }
}
