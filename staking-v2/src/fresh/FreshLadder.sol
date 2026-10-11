// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "../IV4Minimal.sol";

/// @title FreshLadder
/// @notice 20 SAVIOR-only tranches for the fresh pool, minted as PositionManager NFTs to `owner`.
///         Base geometry (SAVIOR = currency1): ranges BELOW start tick 121800 (16x1800 + 4x1600 wide),
///         sized for ~50k USDC gross to buy out all SAVIOR at ~5e-6 USDC/SAVIOR start.
///         If SAVIOR = currency0 the ladder is mirrored: ticks negated, ranges ABOVE start tick -121800.
///         Asserts orientation: token1-only ranges must have tickUpper <= startTick; token0-only ranges
///         tickLower > startTick (startTick rounded down by v4).
library FreshLadder {
    uint256 internal constant N = 20;
    uint256 internal constant Q96 = 1 << 96;
    uint8 internal constant MINT_POSITION = 0x02;
    uint8 internal constant SETTLE_PAIR = 0x0d;

    function ticks() internal pure returns (int24[21] memory t) {
        t = [
            int24(121800), 120000, 118200, 116400, 114600, 112800, 111000, 109200, 107400, 105600,
            103800, 102000, 100200, 98400, 96600, 94800, 93000, 91400, 89800, 88200, 86600
        ];
    }

    /// sqrtPriceX96 at ticks() (TickMath.getSqrtPriceAtTick, precomputed).
    function sqrts() internal pure returns (uint160[21] memory s) {
        s = [
            uint160(34962360349697265032986773817444), 31953335214378312554014683580590,
            29203280931553866779873355698343, 26689909251898744636872781992034,
            24392850157630797652685242206350, 22293486770484211798113310380059,
            20374804468278937933786501323173, 18621252987227656732820051416783,
            17018620392366642985394678120592, 15553917894683978985743565222032,
            14215274581427338678292663124139, 12991841206416493925970834189792,
            11873702260613933624349404812283, 10851795610315646184681248037272,
            9917839051657088880707386496347, 9064263186183736465700110338626,
            8284150073465667804633817457384, 7647264935695662854132592423401,
            7059343502725204859575735652508, 6516621446819952884979925665545,
            6015623841616429162295202690126
        ];
    }

    /// @notice Initial sqrtPriceX96 for the pool so the whole ladder is out of range (SAVIOR-only).
    function startSqrtPrice(bool saviorIsCurrency0) internal pure returns (uint160) {
        uint160 s0 = sqrts()[0];
        // currency1 = SAVIOR: price at tick 121800 exactly (tick == tickUpper of top range → out of range).
        // currency0 = SAVIOR: 1/price, floored → tick -121801 < tickLower -121800 of bottom range.
        return saviorIsCurrency0 ? uint160((uint256(1) << 192) / s0) : s0;
    }

    /// @notice Encoded Posm.modifyLiquidities(unlockData) payload for 20 mints + SETTLE_PAIR.
    /// @param totalSavior SAVIOR to distribute equally (each tranche total/20).
    function build(PoolKey memory key, bool saviorIsCurrency0, uint256 totalSavior, address owner)
        internal
        pure
        returns (bytes memory unlockData)
    {
        require(key.currency0 < key.currency1, "ladder: unsorted key");
        int24[21] memory t = ticks();
        uint160[21] memory s = sqrts();
        uint256 a = totalSavior / N;
        bytes memory actions = new bytes(N + 1);
        bytes[] memory ps = new bytes[](N + 1);
        for (uint256 i; i < N; ++i) {
            actions[i] = bytes1(MINT_POSITION);
            ps[i] = _mint(key, saviorIsCurrency0, t[i], t[i + 1], s[i], s[i + 1], a, owner);
        }
        actions[N] = bytes1(SETTLE_PAIR);
        ps[N] = abi.encode(key.currency0, key.currency1);
        unlockData = abi.encode(actions, ps);
    }

    /// @dev one tranche; tHi/tLo are the base (positive) ticks, sHi/sLo their sqrt prices.
    function _mint(
        PoolKey memory key,
        bool c0,
        int24 tHi,
        int24 tLo,
        uint160 sHi,
        uint160 sLo,
        uint256 a,
        address owner
    ) private pure returns (bytes memory) {
        if (!c0) {
            // SAVIOR = currency1: range [tLo, tHi] at/below start tick 121800 → token1-only.
            require(tHi <= 121800 && tLo < tHi, "ladder: c1 range must be below start");
            uint256 L = Math.mulDiv(a, Q96, sHi - sLo);
            return abi.encode(key, tLo, tHi, _shave(L), uint128(0), uint128(a), owner, bytes(""));
        }
        // SAVIOR = currency0: mirrored range [-tHi, -tLo] above start tick -121801 → token0-only.
        require(-tHi > -121801 && -tHi < -tLo, "ladder: c0 range must be above start");
        uint256 sa = (uint256(1) << 192) / sHi;
        uint256 sb = (uint256(1) << 192) / sLo;
        uint256 L0 = Math.mulDiv(Math.mulDiv(a, sa, Q96), sb, sb - sa);
        return abi.encode(key, -tHi, -tLo, _shave(L0), uint128(a), uint128(0), owner, bytes(""));
    }

    /// @dev shave 1 ppm so rounding inside v4 never needs more than amountMax.
    function _shave(uint256 L) private pure returns (uint256) {
        return L - L / 1_000_000 - 1;
    }
}
