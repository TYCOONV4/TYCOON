// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Swap fee arithmetic on the gross ETH leg. Units: pips (1e-6).
library FeeCalc {
    uint256 internal constant ONE = 1_000_000;

    /// @dev Exact input: fee = gross * pips.
    function onGross(uint256 gross, uint24 pips) internal pure returns (uint256) {
        return Math.mulDiv(gross, pips, ONE);
    }

    /// @dev Exact output: fee such that net = gross - fee is exactly the requested amount (rounded up).
    function onNet(uint256 net, uint24 pips) internal pure returns (uint256) {
        return Math.mulDiv(net, pips, ONE - pips, Math.Rounding.Ceil);
    }

    /// @dev Share of a fee that belongs to `partPips` out of `totalPips`, never above `fee`.
    function share(uint256 gross, uint256 fee, uint24 partPips) internal pure returns (uint256 part) {
        part = Math.mulDiv(gross, partPips, ONE);
        if (part > fee) part = fee;
    }
}
