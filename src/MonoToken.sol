// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Website: <fill in before deploy>
// X:       <fill in before deploy>

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title MONO
/// @notice Fixed supply, minted once to the launch seeder. No owner, no mint, no pause, no transfer tax.
///  - the game lives in the pool hook
///  - metadata() / tokenURI() carry the project card for explorers and launch platforms
contract MonoToken is ERC20, ERC20Burnable {
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    string private constant DESCRIPTION = "<fill in before deploy>";
    string private constant WEBSITE = "<fill in before deploy>";
    string private constant IMAGE = "<fill in before deploy>";
    string private constant X = "<fill in before deploy>";

    constructor(address recipient) ERC20("Monopoly", "MONO") {
        _mint(recipient, SUPPLY);
    }

    /// @notice Project card: description, website, image and extra links as JSON bytes.
    function metadata() external pure returns (string memory, string memory, string memory, bytes memory) {
        return (DESCRIPTION, WEBSITE, IMAGE, bytes(string.concat("{\"v\":1,\"x\":\"", X, "\"}")));
    }

    /// @notice Same card as an inline JSON document.
    function tokenURI() external pure returns (string memory) {
        return string.concat(
            "data:application/json,{\"name\":\"Monopoly\",\"symbol\":\"MONO\",\"description\":\"", DESCRIPTION,
            "\",\"website\":\"", WEBSITE, "\",\"external_url\":\"", WEBSITE, "\",\"x\":\"", X, "\",\"image\":\"", IMAGE, "\"}"
        );
    }
}
