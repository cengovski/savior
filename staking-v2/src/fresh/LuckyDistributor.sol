// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @dev OpenSea SeaDrop v1 MintParams (allow-list stage). Leaf = keccak256(abi.encode(minter, params)).
struct MintParams {
    uint256 mintPrice;
    uint256 maxTotalMintableByWallet;
    uint256 startTime;
    uint256 endTime;
    uint256 dropStageIndex;
    uint256 maxTokenSupplyForStage;
    uint256 feeBps;
    bool restrictFeeRecipients;
}

interface ISeaDrop {
    function mintAllowList(
        address nftContract,
        address feeRecipient,
        address minterIfNotPayer,
        uint256 quantity,
        MintParams calldata mintParams,
        bytes32[] calldata proof
    ) external payable;
}

/// @title LuckyDistributor
/// @notice Lucky NFT option A: the collection is OpenSea's own drop contract (ERC721SeaDrop clone, minted
///         through SeaDrop 0x00005EA0...4bf5). This contract is the ONLY allow-list entry (single-leaf Merkle
///         root = allowListLeaf()). On a win, SaviorStakingFresh calls onWin(user): the win is recorded first
///         (owed[user]++), then one token is minted to THIS contract via SeaDrop.mintAllowList and reserved
///         for `user`. The winner pulls it with claimNFT(id). If the mint fails (price unfunded, stage ended,
///         supply out, misconfig), nothing reverts: the win stays in owed[] and anyone can retryMint(user).
/// @dev Binding: `staking` immutable = FreshDeployer.predictStaking(); the factory checks it before deploy.
contract LuckyDistributor is Ownable2Step, IERC721Receiver {
    address public immutable staking;
    ISeaDrop public immutable seaDrop;
    IERC721 public immutable nft;
    address public immutable feeRecipient;

    MintParams internal _params;

    mapping(uint256 => address) public reservedFor;
    mapping(address => uint256) public owed; // recorded wins not yet minted
    mapping(address => uint256[]) internal _reservedIds; // history (may contain claimed ids)
    uint256 public totalOwed;

    uint256 private _received;
    bool private _minting;

    event WinRecorded(address indexed user, uint256 indexed lockIndex);
    event Reserved(address indexed user, uint256 indexed tokenId);
    event MintDeferred(address indexed user, bytes reason);
    event NftClaimed(address indexed user, uint256 indexed tokenId);
    event MintParamsUpdated(bytes32 leaf);

    error NotStaking();
    error NotReserved();
    error NothingOwed();
    error UnexpectedNft();
    error RenounceDisabled();

    constructor(address initialOwner, address staking_, ISeaDrop seaDrop_, IERC721 nft_, address feeRecipient_, MintParams memory p)
        Ownable(initialOwner)
    {
        staking = staking_;
        seaDrop = seaDrop_;
        nft = nft_;
        feeRecipient = feeRecipient_;
        _params = p;
        emit MintParamsUpdated(allowListLeaf());
    }

    receive() external payable {} // prefund only needed if mintPrice > 0 (native USDC on Arc)

    function mintParams() external view returns (MintParams memory) {
        return _params;
    }

    /// @notice Single-leaf allow-list root to set on the NFT: updateAllowList(seaDrop, (root, [], "")).
    function allowListLeaf() public view returns (bytes32) {
        return keccak256(abi.encode(address(this), _params));
    }

    function onWin(address user, uint256 lockIndex) external {
        if (msg.sender != staking) revert NotStaking();
        ++owed[user];
        ++totalOwed;
        emit WinRecorded(user, lockIndex);
        _tryMint(user);
    }

    /// @notice Anyone can retry a deferred mint (e.g. after the owner funded/fixed the stage). Mints to this
    ///         contract and reserves for `user` (never msg.sender).
    function retryMint(address user) external {
        if (owed[user] == 0) revert NothingOwed();
        _tryMint(user);
    }

    function _tryMint(address user) internal {
        uint256 price = _params.mintPrice;
        if (address(this).balance < price) {
            emit MintDeferred(user, "unfunded");
            return;
        }
        uint256 g = gasleft();
        if (g < 60_000) {
            emit MintDeferred(user, "gas");
            return;
        }
        _minting = true;
        _received = 0;
        try seaDrop.mintAllowList{value: price, gas: g - 40_000}(
            address(nft), feeRecipient, address(0), 1, _params, new bytes32[](0)
        ) {
            uint256 id = _received;
            reservedFor[id] = user;
            _reservedIds[user].push(id);
            --owed[user];
            --totalOwed;
            emit Reserved(user, id);
        } catch (bytes memory reason) {
            emit MintDeferred(user, reason);
        }
        _minting = false;
    }

    /// @dev ERC721SeaDrop mints with _safeMint: the callback must accept only our own in-flight mint.
    function onERC721Received(address, address from, uint256 id, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(nft) || !_minting || from != address(0)) revert UnexpectedNft();
        _received = id;
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Winner pulls a reserved token. Plain transferFrom (no receiver callback).
    function claimNFT(uint256 id) external {
        if (reservedFor[id] != msg.sender) revert NotReserved();
        delete reservedFor[id];
        nft.transferFrom(address(this), msg.sender, id);
        emit NftClaimed(msg.sender, id);
    }

    /// @notice Reserved, unclaimed token ids of `user` (paged for UI).
    function reservedOf(address user, uint256 offset, uint256 limit) external view returns (uint256[] memory out) {
        uint256[] storage a = _reservedIds[user];
        uint256 n;
        for (uint256 i = offset; i < a.length && n < limit; ++i) if (reservedFor[a[i]] == user) ++n;
        out = new uint256[](n);
        n = 0;
        for (uint256 i = offset; i < a.length && n < out.length; ++i) if (reservedFor[a[i]] == user) out[n++] = a[i];
    }

    /// @notice Owner may update stage params (then must re-set the NFT allow-list root to allowListLeaf()).
    function setMintParams(MintParams calldata p) external onlyOwner {
        _params = p;
        emit MintParamsUpdated(allowListLeaf());
    }

    /// @notice Withdraw unused native prefund only (never NFTs).
    function withdrawNative(address payable to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{value: amount}("");
        require(ok);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }
}
