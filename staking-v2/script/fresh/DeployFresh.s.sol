// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SaviorTokenV2} from "../../src/fresh/SaviorTokenV2.sol";
import {FreshDeployer} from "../../src/fresh/FreshDeployer.sol";
import {HookMiner} from "../../src/fresh/HookMiner.sol";
import {FreshLadder} from "../../src/fresh/FreshLadder.sol";
import {PoolKey} from "../../src/IV4Minimal.sol";
import {ArcAddresses as A} from "../../src/ArcAddresses.sol";

interface IPosmL {
    function modifyLiquidities(bytes calldata, uint256) external payable;
}

interface IPermit2L {
    function approve(address, address, uint160, uint48) external;
}

/// Fresh-start deploy, one STEP per run (ordered; each step verifies the previous on-chain state).
/// NEVER broadcast from CI/bots. Default = simulation (no --broadcast). Owner signs via admin tab or:
///   STEP=1 forge script script/fresh/DeployFresh.s.sol --rpc-url arc_mainnet --sender $DEPLOYER
///   STEP=1 ... --account <keystore> --broadcast        (only with Dzengo's explicit go)
/// Steps:
///   1 token    : SaviorTokenV2(recipient=DEPLOYER, owner=DEPLOYER, LOGO_URI)
///   2 factory  : FreshDeployer(admin=DEPLOYER, TOKEN, USDC, PoolManager, TREASURY, 10000, 200)
///   3 deploy   : mine hook salt (flags 0x2080) → factory.deploy(salt, startSqrtPrice)  [staking+hook+init, 1 tx]
///   4 approvals: SAVIOR.approve(Permit2) + Permit2.approve(SAVIOR, Posm)
///   5 ladder   : Posm.modifyLiquidities(20x MINT_POSITION + SETTLE_PAIR) → 20 NFTs to DEPLOYER
/// Env: STEP, TOKEN (after 1), FACTORY (after 2), LOGO_URI (step 1), LADDER_AMOUNT (step 5, default = full balance)
contract DeployFresh is Script {
    uint160 constant FLAGS = uint160((1 << 13) | (1 << 7));

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
            vm.startBroadcast();
            FreshDeployer f = new FreshDeployer(deployer, token, A.USDC, A.POOL_MANAGER, A.TREASURY, A.POOL_FEE, A.POOL_TICK_SPACING);
            vm.stopBroadcast();
            console2.log("FACTORY", address(f));
            console2.log("predicted STAKING", f.predictStaking());
            return;
        }

        FreshDeployer fac = FreshDeployer(vm.envAddress("FACTORY"));
        require(fac.admin() == deployer && fac.token() == token, "FACTORY mismatch");

        if (step == 3) {
            require(!fac.deployed(), "already deployed");
            (bytes32 salt, address hook) = HookMiner.find(address(fac), FLAGS, fac.hookInitCodeHash(), 0, 500_000);
            uint160 sqrtP = FreshLadder.startSqrtPrice(fac.saviorIsCurrency0());
            console2.log("hook salt");
            console2.logBytes32(salt);
            console2.log("HOOK (predicted)", hook);
            console2.log("STAKING (predicted)", fac.predictStaking());
            console2.log("startSqrtPriceX96", sqrtP);
            vm.startBroadcast();
            fac.deploy(salt, sqrtP);
            vm.stopBroadcast();
            require(fac.hook() == hook && fac.staking() == fac.predictStaking(), "post-deploy mismatch");
            return;
        }

        require(fac.deployed(), "step 3 first");
        if (step == 4) {
            vm.startBroadcast();
            SaviorTokenV2(payable(token)).approve(A.PERMIT2, type(uint256).max);
            IPermit2L(A.PERMIT2).approve(token, A.POSITION_MANAGER, type(uint160).max, uint48(block.timestamp + 1 days));
            vm.stopBroadcast();
            return;
        }

        if (step == 5) {
            uint256 amt = vm.envOr("LADDER_AMOUNT", SaviorTokenV2(payable(token)).balanceOf(deployer));
            PoolKey memory key = fac.poolKey(fac.hook());
            bytes memory data = FreshLadder.build(key, fac.saviorIsCurrency0(), amt, deployer);
            console2.log("ladder SAVIOR", amt);
            console2.log("Posm.modifyLiquidities unlockData:");
            console2.logBytes(data);
            vm.startBroadcast();
            IPosmL(A.POSITION_MANAGER).modifyLiquidities(data, block.timestamp + 600);
            vm.stopBroadcast();
            return;
        }
        revert("unknown STEP");
    }
}
