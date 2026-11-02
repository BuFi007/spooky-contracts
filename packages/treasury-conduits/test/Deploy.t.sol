// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.24;

import {TreasuryBridgeConduitV2} from "../src/bufi/conduit/TreasuryBridgeConduitV2.sol";
import {TreasuryConduit} from "../src/bufi/conduit/TreasuryConduit.sol";
import {TreasuryRedeemConduit} from "../src/bufi/conduit/TreasuryRedeemConduit.sol";

/// @notice Deployment smoke checks. These are not the upstream Foundry suite
/// (that suite lives in the private BUFI-6900 tree and was not reachable).
contract TreasuryConduitDeployTest {
    function test_deploys_with_owner() public {
        TreasuryConduit conduit = new TreasuryConduit(address(this));
        require(conduit.owner() == address(this), "owner");
        require(conduit.INTENT_TYPEHASH() != bytes32(0), "typehash");
    }

    function test_bridge_deploys_with_owner() public {
        TreasuryBridgeConduitV2 bridge = new TreasuryBridgeConduitV2(address(this));
        require(bridge.owner() == address(this), "owner");
        require(bridge.INTENT_TYPEHASH() != bytes32(0), "typehash");
    }

    function test_redeem_deploys_with_owner() public {
        TreasuryRedeemConduit redeem = new TreasuryRedeemConduit(address(this));
        require(redeem.owner() == address(this), "owner");
    }
}
