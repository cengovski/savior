// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Vault
 * @notice Her kullanıcı için deploy edilen kişisel kasa kontratı.
 *         Alım (buy) burada yapılır → otomatik %48 lock + random 5-10 gün.
 *         Sadece owner (alıcı cüzdan) etkileşebilir.
 */
contract Vault is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable saviorToken;
    address public immutable factory;
    address public immutable poolManager;
    address public immutable saviorHook;
    address public immutable treasury;

    struct Lock {
        uint256 amount;
        uint256 unlockTime;
        bool claimed;
    }

    Lock[] public locks;
    uint256 public totalLocked;

    event Locked(address indexed user, uint256 amount, uint256 unlockTime);
    event Claimed(address indexed user, uint256 amount);

    constructor(
        address _owner,
        address _saviorToken,
        address _poolManager,
        address _saviorHook,
        address _treasury
    ) Ownable(_owner) {
        saviorToken = IERC20(_saviorToken);
        factory = msg.sender;
        poolManager = _poolManager;
        saviorHook = _saviorHook;
        treasury = _treasury;
    }

    /**
     * @dev Ana alım fonksiyonu. ETH alır, V4 pool'da swap yapar,
     *      %48'ini lock'lar, kalanını kullanıcıya verir.
     *      Bu fonksiyon çağrılmadan swap gerçekleşmez.
     */
    function buy(uint256 ethAmount, uint256 minSaviorOut, uint256 slippageBps) external payable onlyOwner {
        require(msg.value == ethAmount, "ETH mismatch");
        
        // TODO: Gerçek V4 entegrasyonu
        // 1. Quoter ile expectedOut hesapla
        // 2. IPoolManager.swap(...) çağrısı (delta handling)
        // 3. Alınan SAVIOR miktarını al
        
        uint256 saviorReceived = /* TODO: swap sonrası balance veya event */ (ethAmount * 12480000); // mock
        require(saviorReceived >= minSaviorOut, "Slippage too high");

        uint256 lockAmount = (saviorReceived * 48) / 100;
        uint256 userAmount = saviorReceived - lockAmount;

        if (lockAmount > 0) {
            _createLock(lockAmount);
        }
        
        if (userAmount > 0) {
            saviorToken.safeTransfer(owner(), userAmount);
        }
        
        // Kalan ETH'i iade et (gerekirse)
        if (address(this).balance > 0) {
            payable(owner()).transfer(address(this).balance);
        }
    }

    function _createLock(uint256 amount) internal {
        // 5-10 gün arası rastgele süre (tx anında, simüle edilemez)
        uint256 rand = uint256(keccak256(abi.encode(
            block.prevrandao, 
            block.timestamp, 
            msg.sender, 
            locks.length,
            block.number
        )));
        uint256 extraDays = rand % 6; // 0-5
        uint256 unlockTime = block.timestamp + ((5 + extraDays) * 1 days);

        locks.push(Lock({
            amount: amount,
            unlockTime: unlockTime,
            claimed: false
        }));
        
        totalLocked += amount;
        emit Locked(owner(), amount, unlockTime);
        
        // Token'lar bu kontrata transfer edilmeli (buy içinde veya approve ile)
    }

    function claim() external onlyOwner {
        uint256 claimable = 0;
        for (uint256 i = 0; i < locks.length; i++) {
            if (!locks[i].claimed && block.timestamp >= locks[i].unlockTime) {
                claimable += locks[i].amount;
                locks[i].claimed = true;
            }
        }
        require(claimable > 0, "No claimable amount");
        
        totalLocked -= claimable;
        saviorToken.safeTransfer(owner(), claimable);
        emit Claimed(owner(), claimable);
    }

    function getLocks() external view returns (Lock[] memory) {
        return locks;
    }

    function getClaimableAmount() external view returns (uint256) {
        uint256 claimable = 0;
        for (uint256 i = 0; i < locks.length; i++) {
            if (!locks[i].claimed && block.timestamp >= locks[i].unlockTime) {
                claimable += locks[i].amount;
            }
        }
        return claimable;
    }

    receive() external payable {}
}