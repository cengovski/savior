// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SaviorTokenV2} from "../../src/fresh/SaviorTokenV2.sol";
import {FreshDeployer} from "../../src/fresh/FreshDeployer.sol";
import {SaviorStakingFresh} from "../../src/fresh/SaviorStakingFresh.sol";
import {HookMiner} from "../../src/fresh/HookMiner.sol";
import {FreshLadder} from "../../src/fresh/FreshLadder.sol";
import {ArcAddresses as A} from "../../src/ArcAddresses.sol";

/// Fresh-start deploy, one STEP per run (ordered; each step verifies the previous on-chain state).
/// NEVER broadcast from CI/bots. Default = simulation (no --broadcast). Owner signs via admin tab or:
///   STEP=1 forge script script/fresh/DeployFresh.s.sol --rpc-url arc_mainnet --sender $DEPLOYER
///   STEP=1 ... --account <keystore> --broadcast        (only with Dzengo's explicit go)
/// Steps (audit N-1: ladder minted inside the factory deploy tx, no init/liquidity gap):
///   1 token    : SaviorTokenV2(recipient=DEPLOYER, owner=DEPLOYER, LOGO_URI)
///   2 factory  : FreshDeployer(admin=DEPLOYER, TOKEN, USDC, PoolManager, TREASURY, 10000, 200, Posm, Permit2)
///                FACTORY must be taken from THIS tx receipt (audit N-3), never from user input.
///   3 approve  : SAVIOR.approve(FACTORY, LADDER_AMOUNT)
///   4 deploy   : mine hook salt (0x2080) -> factory.deploy(salt, startSqrtPrice, LADDER_AMOUNT)
///                = staking + hook + PoolManager.initialize + 20 Posm NFTs to DEPLOYER, one tx
///   5 verify   : read-only checks (wiring, 20 NFTs, balances)
/// Env: STEP, TOKEN (after 1), FACTORY (after 2), LOGO_URI (step 1), LADDER_AMOUNT (default = full balance)
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
            FreshDeployer f = new FreshDeployer(
                deployer, token, A.USDC, A.POOL_MANAGER, A.TREASURY, A.POOL_FEE, A.POOL_TICK_SPACING,
                A.POSITION_MANAGER, A.PERMIT2, keccak256(type(SaviorStakingFresh).creationCode)
            );
            vm.stopBroadcast();
            console2.log("FACTORY", address(f));
            console2.log("predicted STAKING", f.predictStaking());
            return;
        }

        FreshDeployer fac = FreshDeployer(vm.envAddress("FACTORY"));
        require(fac.admin() == deployer && fac.token() == token, "FACTORY mismatch");
        require(fac.positionManager() == A.POSITION_MANAGER && fac.permit2() == A.PERMIT2, "FACTORY periphery mismatch");
        uint256 amt = vm.envOr("LADDER_AMOUNT", SaviorTokenV2(payable(token)).balanceOf(deployer));

        if (step == 3) {
            require(!fac.deployed(), "already deployed");
            vm.startBroadcast();
            SaviorTokenV2(payable(token)).approve(address(fac), amt);
            vm.stopBroadcast();
            console2.log("approved factory for SAVIOR", amt);
            return;
        }

        if (step == 4) {
            require(!fac.deployed(), "already deployed");
            require(SaviorTokenV2(payable(token)).allowance(deployer, address(fac)) >= amt, "step 3 first");
            require(SaviorTokenV2(payable(token)).balanceOf(deployer) >= amt, "balance < ladder amount");
            (bytes32 salt, address hook) = HookMiner.find(address(fac), FLAGS, fac.hookInitCodeHash(), 0, 500_000);
            uint160 sqrtP = FreshLadder.startSqrtPrice(fac.saviorIsCurrency0());
            console2.log("hook salt");
            console2.logBytes32(salt);
            console2.log("HOOK (predicted)", hook);
            console2.log("STAKING (predicted)", fac.predictStaking());
            console2.log("startSqrtPriceX96", sqrtP);
            bytes memory ladder = FreshLadder.build(fac.poolKey(hook), fac.saviorIsCurrency0(), amt, deployer);
            vm.startBroadcast();
            fac.deploy(salt, sqrtP, amt, ladder, type(SaviorStakingFresh).creationCode, vm.envOr("LUCKY_SINK", address(0)));
            vm.stopBroadcast();
            require(fac.hook() == hook && fac.staking() == fac.predictStaking(), "post-deploy mismatch");
            return;
        }

        if (step == 5) {
            require(fac.deployed(), "step 4 first");
            console2.log("STAKING", fac.staking());
            console2.log("HOOK", fac.hook());
            console2.log("deployer SAVIOR left", SaviorTokenV2(payable(token)).balanceOf(deployer));
            console2.log("PoolManager SAVIOR", SaviorTokenV2(payable(token)).balanceOf(A.POOL_MANAGER));
            return;
        }
        revert("unknown STEP");
    }
}
