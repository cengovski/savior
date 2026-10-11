// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title SaviorLuckyNFT (Lucky NFT option B: own collection)
/// @notice "Lucky" ERC-721 won on >= 10 USDC buys (5%, decided at lock reveal by SaviorStakingFresh).
///         OpenSea-compatible: tokenURI, contractURI (+ ERC-7572 ContractURIUpdated), ERC-4906 refresh
///         events, optional ERC-2981 royalty (default none, capped 10%).
/// @dev Mint authority = immutable `minter` (the staking contract; its address is predicted by
///      FreshDeployer.predictStaking() before it exists). No other mint path, no burn-by-owner, no admin mint.
///      Metadata is owner-updatable like SaviorTokenV2.logoURI (renounce disabled).
contract SaviorLuckyNFT is ERC721, ERC2981, Ownable2Step {
    using Strings for uint256;

    /// @notice Only mint authority (SaviorStakingFresh, = FreshDeployer.predictStaking()).
    address public immutable staking;
    /// @notice 0 = uncapped. Fixed at deploy.
    uint256 public immutable maxSupply;
    uint96 public constant MAX_ROYALTY_BPS = 1000;

    uint256 public totalSupply;
    string public baseURI;
    /// @notice true: every token returns `baseURI` as-is (single image/metadata). false: baseURI + id (+ ".json").
    bool public uniformMetadata;
    string private _contractURI;

    event ContractURIUpdated(); // ERC-7572
    event MetadataUpdate(uint256 _tokenId); // ERC-4906
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId); // ERC-4906
    event LuckyMinted(address indexed to, uint256 indexed tokenId);

    error NotMinter();
    error ZeroAddress();
    error RoyaltyTooHigh();
    error RenounceDisabled();

    constructor(
        address initialOwner,
        address minter_,
        uint256 maxSupply_,
        string memory baseURI_,
        bool uniform_,
        string memory contractURI_
    ) ERC721("SAVIOR Lucky", "SVLUCKY") Ownable(initialOwner) {
        if (minter_ == address(0)) revert ZeroAddress();
        staking = minter_;
        maxSupply = maxSupply_;
        baseURI = baseURI_;
        uniformMetadata = uniform_;
        _contractURI = contractURI_;
    }

    /// @notice Mint next id to `to`. Never reverts on cap: returns 0 when sold out so a reveal/claim
    ///         can never be blocked by the NFT. Uses _mint (no onERC721Received callback: no reentrancy,
    ///         contract wallets cannot grief reveal/claim).
    /// @notice ILuckySink hook: mints straight to the lock owner `to` (never the revealer).
    function onWin(address to, uint256) external {
        mint(to);
    }

    function mint(address to) public returns (uint256 id) {
        if (msg.sender != staking) revert NotMinter();
        if (maxSupply != 0 && totalSupply >= maxSupply) return 0;
        id = ++totalSupply;
        _mint(to, id);
        emit LuckyMinted(to, id);
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        _requireOwned(id);
        if (uniformMetadata) return baseURI;
        return string.concat(baseURI, id.toString(), ".json");
    }

    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    function setBaseURI(string calldata uri, bool uniform) external onlyOwner {
        baseURI = uri;
        uniformMetadata = uniform;
        if (totalSupply != 0) emit BatchMetadataUpdate(1, totalSupply);
    }

    function setContractURI(string calldata uri) external onlyOwner {
        _contractURI = uri;
        emit ContractURIUpdated();
    }

    /// @notice Optional ERC-2981 royalty (marketplaces may ignore it). bps <= 10%. receiver 0 = delete.
    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        if (receiver == address(0)) return _deleteDefaultRoyalty();
        if (bps > MAX_ROYALTY_BPS) revert RoyaltyTooHigh();
        _setDefaultRoyalty(receiver, bps);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function supportsInterface(bytes4 i) public view override(ERC721, ERC2981) returns (bool) {
        return i == bytes4(0x49064906) || super.supportsInterface(i);
    }
}
