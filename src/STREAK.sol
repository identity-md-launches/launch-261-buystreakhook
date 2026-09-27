// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Fixed-supply Sepolia toy token. The deploying factory receives the entire supply.
contract STREAK is ERC20 {
    constructor() ERC20("Streak", "STREAK") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
