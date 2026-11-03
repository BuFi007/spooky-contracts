// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 6-decimal ERC-20 stand-in for Arc's USDC ERC-20 interface at
///         0x3600000000000000000000000000000000000000 (NOT the 18-decimal native
///         gas balance). Tests `vm.etch` this runtime code at that exact address.
contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
