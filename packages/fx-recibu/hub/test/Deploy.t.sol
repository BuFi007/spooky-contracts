// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {MultiTokenReceivableEscrow} from "../src/rails/MultiTokenReceivableEscrow.sol";

contract EscrowDeployTest {
    function test_deploys_with_admin() public {
        MultiTokenReceivableEscrow escrow = new MultiTokenReceivableEscrow(address(this));
        require(escrow.hasRole(escrow.DEFAULT_ADMIN_ROLE(), address(this)), "admin");
    }
}
