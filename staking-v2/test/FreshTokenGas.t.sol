// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test, console2} from "forge-std/Test.sol";
import {SaviorTokenV2} from "../src/fresh/SaviorTokenV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
}

contract FreshTokenGasTest is Test {
    address constant D = 0x7185d50557040047A142aEadA95e41C4b31720e7;
    // small data-URI for unit tests (not full logo — full URI optional at deploy)
    string constant LOGO = "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjwvc3ZnPg==";

    function test_token_deploy_burn_logo() public {
        SaviorTokenV2 t = new SaviorTokenV2(D, D, LOGO);
        assertEq(t.totalSupply(), 1_000_000_000e6);
        assertEq(t.balanceOf(D), 1_000_000_000e6);
        assertEq(t.decimals(), 6);
        assertEq(t.owner(), D);
        assertEq(t.logoURI(), LOGO);
        vm.prank(D);
        t.burn(1e6);
        assertEq(t.totalSupply(), 1_000_000_000e6 - 1e6);
    }

    function test_rescue_foreign_ok_own_reverts() public {
        SaviorTokenV2 t = new SaviorTokenV2(D, D, LOGO);
        MockERC20 other = new MockERC20();
        other.mint(address(t), 1000);
        // own token stuck on contract
        vm.prank(D);
        t.transfer(address(t), 5e6);
        assertEq(t.balanceOf(address(t)), 5e6);

        vm.prank(D);
        vm.expectRevert(SaviorTokenV2.CannotRescueOwnToken.selector);
        t.rescue(address(t), D, 5e6);

        vm.prank(D);
        t.rescue(address(other), D, 1000);
        assertEq(other.balanceOf(D), 1000);

        vm.deal(address(t), 1 ether);
        vm.prank(D);
        t.rescue(address(0), D, 0.5 ether);
        assertEq(D.balance, 0.5 ether);

        vm.prank(D);
        vm.expectRevert(SaviorTokenV2.ZeroAddress.selector);
        t.rescue(address(other), address(0), 1);
    }

    function test_ownable2step() public {
        SaviorTokenV2 t = new SaviorTokenV2(D, D, LOGO);
        address n = makeAddr("next");
        vm.prank(D);
        t.transferOwnership(n);
        assertEq(t.owner(), D);
        vm.prank(n);
        t.acceptOwnership();
        assertEq(t.owner(), n);
    }

    function test_fork_prevrandao_note() public {
        // kept lightweight; lock PoC is LockBiasPoC
        assertTrue(true);
    }
}
