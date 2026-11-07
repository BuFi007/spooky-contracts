// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {AgentGatewayAccountFactory} from "./AgentGatewayAccountFactory.sol";

/// @notice Arc testnet bootstrap of the canonical policy factory with one explicit initial issuer.
/// @dev The registered chain Safe remains the immutable administrator. The constructor grants issuance only;
/// every account still requires its owner's exact EIP-712 creation authorization, and starts with zero budget.
/// No Safe transaction, arbitrary initialization call, or deployer administration is introduced.
contract AgentGatewayAccountFactoryArcTestnet is AgentGatewayAccountFactory {
    address public constant ARC_TESTNET_SAFE = 0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B;
    uint256 public constant ARC_TESTNET_CHAIN_ID = 5042002;

    constructor(address administrator_, address initialIssuer_) AgentGatewayAccountFactory(administrator_) {
        if (block.chainid != ARC_TESTNET_CHAIN_ID || administrator_ != ARC_TESTNET_SAFE || initialIssuer_ == address(0))
        {
            revert Refused();
        }
        issuers[initialIssuer_] = true;
        emit IssuerAuthorized(initialIssuer_, true);
    }
}
