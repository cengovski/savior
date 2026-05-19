// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vault} from "./Vault.sol";

/**
 * @title VaultFactory
 * @notice CREATE2 ile deterministic Vault deployment.
 *         Her cüzdan için tek Vault (userVault mapping).
 */
contract VaultFactory {
    mapping(address => address) public userVault;
    
    address public immutable saviorToken;
    address public immutable poolManager;
    address public immutable saviorHook;
    address public immutable treasury;

    event VaultCreated(address indexed user, address indexed vault);

    constructor(
        address _saviorToken,
        address _poolManager,
        address _saviorHook,
        address _treasury
    ) {
        saviorToken = _saviorToken;
        poolManager = _poolManager;
        saviorHook = _saviorHook;
        treasury = _treasury;
    }

    function deployVault() external returns (address vaultAddr) {
        require(userVault[msg.sender] == address(0), "Vault already exists for user");

        bytes32 salt = keccak256(abi.encodePacked(msg.sender));
        
        vaultAddr = address(new Vault{salt: salt}(
            msg.sender,
            saviorToken,
            poolManager,
            saviorHook,
            treasury
        ));

        userVault[msg.sender] = vaultAddr;
        emit VaultCreated(msg.sender, vaultAddr);
    }

    function getVault(address user) external view returns (address) {
        return userVault[user];
    }

    function predictVaultAddress(address user) external view returns (address predicted) {
        bytes32 salt = keccak256(abi.encodePacked(user));
        bytes32 hash = keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            keccak256(abi.encodePacked(
                type(Vault).creationCode,
                abi.encode(user, saviorToken, poolManager, saviorHook, treasury)
            ))
        ));
        predicted = address(uint160(uint256(hash)));
    }
}