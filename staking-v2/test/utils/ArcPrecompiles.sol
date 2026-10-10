// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @notice Arc native-USDC ERC-20 (0x3600..00) delegates balance moves to Arc-specific precompiles
///         (0x1800..00 native transfer, 0x1800..01 blocklist) that foundry's local EVM does not implement.
///         These mocks are etched ONLY inside local fork tests so the real USDC proxy/impl code can run.
contract ArcNativeTransferMock {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function transfer(address from, address to, uint256 amount) external returns (bool) {
        require(from.balance >= amount, "native: insufficient");
        vm.deal(from, from.balance - amount);
        vm.deal(to, to.balance + amount);
        return true;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(true);
    }
}

contract ArcBlocklistMock {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(false); // isBlocklisted(x) == false
    }
}

library ArcPrecompiles {
    address internal constant NATIVE_TRANSFER = 0x1800000000000000000000000000000000000000;
    address internal constant BLOCKLIST = 0x1800000000000000000000000000000000000001;

    function install(Vm vm) internal {
        vm.etch(NATIVE_TRANSFER, address(new ArcNativeTransferMock()).code);
        vm.allowCheatcodes(NATIVE_TRANSFER);
        vm.etch(BLOCKLIST, address(new ArcBlocklistMock()).code);
    }
}
