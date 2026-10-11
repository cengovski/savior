// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test, console2} from "forge-std/Test.sol";
import {SaviorTokenV2} from "../src/fresh/SaviorTokenV2.sol";
import {ArcPrecompiles} from "./utils/ArcPrecompiles.sol";

contract FreshTokenGasTest is Test {
    address constant D = 0x7185d50557040047A142aEadA95e41C4b31720e7;

    function test_token_deploy_and_burn() public {
        bool forked = vm.envOr("ARC_FORK", false);
        if (forked) {
            vm.createSelectFork("arc_mainnet");
            ArcPrecompiles.install(vm);
        }
        uint256 g0 = gasleft();
        SaviorTokenV2 t = new SaviorTokenV2(D);
        uint256 used = g0 - gasleft();
        console2.log("deploy gas (approx)", used);
        assertEq(t.totalSupply(), 1_000_000_000e6);
        assertEq(t.balanceOf(D), 1_000_000_000e6);
        assertEq(t.decimals(), 6);
        vm.prank(D);
        t.burn(1e6);
        assertEq(t.totalSupply(), 1_000_000_000e6 - 1e6);
    }

    function test_fork_estimate_deploy_usdc() public {
        vm.skip(!vm.envOr("ARC_FORK", false));
        vm.createSelectFork("arc_mainnet");
        uint256 gp = block.basefee;
        vm.prank(D);
        uint256 g0 = gasleft();
        new SaviorTokenV2(D);
        uint256 used = g0 - gasleft();
        uint256 usdc18 = used * gp;
        console2.log("basefee", gp);
        console2.log("deploy gas", used);
        console2.log("approx USDC_18 wei", usdc18);
    }
}
