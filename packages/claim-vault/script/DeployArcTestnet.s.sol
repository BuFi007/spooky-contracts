// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {Script, console2} from "forge-std/Script.sol";
import {PeanutV4} from "../src/V4/PeanutV4.4.sol";
import {PayrollBatch} from "../src/payroll/PayrollBatch.sol";
import {ISignatureTransfer} from "../src/interfaces/ISignatureTransfer.sol";
import {IPeanutV4MFAVault} from "../src/interfaces/IPeanutV4MFAVault.sol";

/// @notice Deploys the BUFI fork of PeanutV4.4 to Arc TESTNET only.
///   PRIVATE_KEY=... forge script script/DeployArcTestnet.s.sol --rpc-url arc_testnet --broadcast
/// MFA_AUTHORIZER defaults to the deployer (PLACEHOLDER — rotate to the OTP attestor with
/// transferMFAAuthorizer + acceptMFAAuthorizer). ecoAddress is address(0): no ECO on Arc.
contract DeployArcTestnet is Script {
    /// Canonical Permit2 (same address on every chain; present on Arc testnet).
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external returns (PeanutV4 vault, PayrollBatch batch) {
        require(block.chainid == 5042002, "ARC TESTNET ONLY");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address authorizer = vm.envOr("MFA_AUTHORIZER", deployer);

        vm.startBroadcast(pk);
        vault = new PeanutV4(address(0), authorizer);
        batch = new PayrollBatch(ISignatureTransfer(PERMIT2), IPeanutV4MFAVault(address(vault)));
        vm.stopBroadcast();

        require(address(batch.VAULT()) == address(vault), "batch vault mismatch");
        require(PERMIT2.code.length > 0, "no Permit2 on this chain");

        require(vault.MFA_AUTHORIZER() == authorizer, "authorizer not set");
        require(vault.owner() == deployer, "owner not deployer");
        console2.log("PeanutV4 (BUFI fork of v4.4):", address(vault));
        console2.log("owner:", deployer);
        console2.log("MFA_AUTHORIZER:", authorizer);
        console2.log("PayrollBatch:", address(batch));
    }
}
