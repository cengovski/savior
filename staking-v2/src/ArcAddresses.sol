// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Arc Mainnet (chainId 5042) constants.
/// Uniswap v4: https://developers.uniswap.org/docs/protocols/v4/deployments (section "Arc: 5042")
/// Arc: https://docs.arc.io/integrate/infrastructure
library ArcAddresses {
    uint256 internal constant CHAIN_ID = 5042;
    address internal constant USDC = 0x3600000000000000000000000000000000000000; // native gas token, ERC-20 view 6 dec, native 18 dec
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSITION_MANAGER = 0x6049c9a0e26405C0985f9E3685C87d0aE917f82B;
    address internal constant UNIVERSAL_ROUTER = 0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;

    // SAVIOR deployment (deployments/arc-mainnet.json)
    address internal constant SAVIOR_TOKEN = 0xe4065efC5E19305e4ed1dfdB6542A32A34E0cAf3;
    address internal constant SAVIOR_HOOK = 0xFfcf2eF82AA17Fb31F3618E0302F9adC92D060c0;
    address internal constant STAKING_V1 = 0xBCA651C0A0540a1fCDef066B5476d714431fa525;
    address internal constant DEPLOYER = 0x7185d50557040047A142aEadA95e41C4b31720e7;
}
