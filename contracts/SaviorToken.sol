// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SaviorToken
 * @notice $SAVIOR - Trench'lerin Kurtarıcısı Token
 * @dev Basit ERC20. Mint yetkisi owner'da (deploy sonrası renounce edilebilir).
 *      Gerçek projede initial supply doğrudan pool'a mint edilir.
 */
contract SaviorToken is ERC20, Ownable {
    constructor(address initialOwner) ERC20("$SAVIOR", "SAVIOR") Ownable(initialOwner) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    // İleride eklenebilir: onlyPool modifier veya hook entegrasyonu
}