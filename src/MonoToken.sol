// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Website: https://tycoon.family/
// X:       https://x.com/Tycoonv4

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title TYCOON
/// @notice Fixed supply, minted once to the launch seeder. No owner, no mint, no pause, no transfer tax.
///  - the game lives in the pool hook
///  - metadata() / tokenURI() carry the project card for explorers and launch platforms
contract MonoToken is ERC20, ERC20Burnable {
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    string private constant DESCRIPTION = "Every trade rolls the dice. Every land you own pays you ETH from every trade.";
    string private constant WEBSITE = "https://tycoon.family/";
    string private constant IMAGE = "https://tycoon.family/token.jpg";
    string private constant X = "https://x.com/Tycoonv4";

    constructor(address recipient) ERC20("Tycoon", "TYCOON") {
        _mint(recipient, SUPPLY);
    }

    /// @notice Project card: description, website, image and extra links as JSON bytes.
    function metadata() external pure returns (string memory, string memory, string memory, bytes memory) {
        return (DESCRIPTION, WEBSITE, IMAGE, bytes(string.concat("{\"v\":1,\"x\":\"", X, "\"}")));
    }

    /// @notice Same card as an inline JSON document.
    function tokenURI() external pure returns (string memory) {
        return string.concat(
            "data:application/json,{\"name\":\"Tycoon\",\"symbol\":\"TYCOON\",\"description\":\"", DESCRIPTION,
            "\",\"website\":\"", WEBSITE, "\",\"external_url\":\"", WEBSITE, "\",\"x\":\"", X, "\",\"image\":\"", IMAGE, "\"}"
        );
    }
}
