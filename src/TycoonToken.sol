// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Website: https://tycoon.family/
// X:       https://x.com/Tycoonv4

import { ProtectedLaunchTokenV1 } from "./launch-protection/ProtectedLaunchTokenV1.sol";

/// @title TYCOON
/// @notice ProtectedLaunchTokenV1 (launch-protection v1, unchanged) plus the project card for explorers.
///  - fixed supply, minted once to the launch initializer; no owner, no mint, no pause, no transfer tax
///  - cumulative 2% receiving budget during the opening five minutes, as in the kernel
///  - the game lives in the pool hook
contract TycoonToken is ProtectedLaunchTokenV1 {
    string private constant DESCRIPTION = "Every trade rolls the dice. Every land you own pays you ETH from every trade.";
    string private constant WEBSITE = "https://tycoon.family/";
    string private constant IMAGE = "https://raw.githubusercontent.com/TYCOONV4/TYCOON/main/token.jpg";
    string private constant X = "https://x.com/Tycoonv4";

    constructor(string memory name_, string memory symbol_, uint256 supply_, address initializer_, address manager_)
        ProtectedLaunchTokenV1(name_, symbol_, supply_, initializer_, manager_)
    {}

    /// @notice Project card: description, website, image and extra links as JSON bytes.
    function metadata() external pure returns (string memory, string memory, string memory, bytes memory) {
        return (DESCRIPTION, WEBSITE, IMAGE, bytes(string.concat("{\"v\":1,\"x\":\"", X, "\"}")));
    }

    /// @notice Same card as an inline JSON document.
    function tokenURI() external view returns (string memory) {
        return string.concat(
            "data:application/json,{\"name\":\"", name(), "\",\"symbol\":\"", symbol(), "\",\"description\":\"", DESCRIPTION,
            "\",\"website\":\"", WEBSITE, "\",\"external_url\":\"", WEBSITE, "\",\"x\":\"", X, "\",\"image\":\"", IMAGE, "\"}"
        );
    }
}
