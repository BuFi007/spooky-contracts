// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {console2} from "forge-std/Script.sol";
import {PeanutV4} from "../src/V4/PeanutV4.4.sol";
import {ClaimVaultCreate2} from "./ClaimVaultCreate2.sol";

/// @notice Claim vault + PayrollBatch on Arc MAINNET (chain 5042), owned by the Arc Safe.
///         Plan 398 wave B. Same factory, salts and init-code recipe as DeployTestnet; the
///         owner baked into the init code is the Arc Safe, so the addresses differ from testnet.
///
///   Simulate (no key, no broadcast):
///     CLAIM_VAULT_MFA_AUTHORIZER=0x<live OTP attestor DCW EOA> \
///       forge script script/DeployArcMainnet.s.sol --rpc-url https://rpc.mainnet.arc.io \
///       --sig "simulate()"
///   Deploy (a HUMAN only, after the audit; agents never broadcast a mainnet deploy):
///     ARC_MAINNET_DEPLOY_CONFIRM=deploy-arc-mainnet-5042 CLAIM_VAULT_MFA_AUTHORIZER=0x… \
///       forge script script/DeployArcMainnet.s.sol --rpc-url … --broadcast …
///   Then the Arc Safe sends `acceptOwnership()` to the vault, and only then:
///     forge script script/DeployArcMainnet.s.sol --rpc-url … --sig "verify(address)" <mfa>
///   The deployment is done when verify passes AND its rows land in contracts/deployments.json.
///
/// MFA_AUTHORIZER is REQUIRED (no fallback to the deployer, unlike the retired
/// DeployArcTestnet). It must be the live-entity OTP attestor EOA: the vault verifies the OTP
/// co-signature with ecrecover. PayrollBatch has no owner.
contract DeployArcMainnet is ClaimVaultCreate2 {
    uint256 public constant ARC_MAINNET = 5042;
    /// The Arc mainnet Safe (contracts/DEPLOYMENTS.md). Never reuse another chain's Safe.
    address public constant ARC_SAFE = 0x47Dc7D18A6E3a79F696714E7D47456a49B430D09;
    string public constant CONFIRM_PHRASE = "deploy-arc-mainnet-5042";

    function run() external returns (Deployment memory d) {
        _requireArcMainnet();
        address mfa = vm.envAddress("CLAIM_VAULT_MFA_AUTHORIZER");
        require(
            keccak256(bytes(vm.envOr("ARC_MAINNET_DEPLOY_CONFIRM", string("")))) == keccak256(bytes(CONFIRM_PHRASE)),
            "SET ARC_MAINNET_DEPLOY_CONFIRM=deploy-arc-mainnet-5042"
        );
        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        require(mfa != sender, "MFA AUTHORIZER IS THE DEPLOYER");
        d = deploy(mfa);
        vm.stopBroadcast();
        _logSafeAction(d);
    }

    /// Dry run against a fork/RPC with no broadcast.
    function simulate() external returns (Deployment memory d) {
        _requireArcMainnet();
        d = deploy(vm.envAddress("CLAIM_VAULT_MFA_AUTHORIZER"));
        _logSafeAction(d);
    }

    /// Deploys whatever is missing. Ends with the Safe as pendingOwner (or, on a re-run after
    /// the Safe accepted, as owner). Never leaves the vault headed anywhere else.
    function deploy(address mfa) public returns (Deployment memory d) {
        _requireArcMainnet();
        require(mfa != address(0), "ZERO MFA AUTHORIZER");
        require(mfa != ARC_SAFE, "MFA AUTHORIZER IS THE SAFE");
        require(mfa.code.length == 0, "MFA AUTHORIZER MUST BE AN EOA");
        require(ARC_SAFE.code.length > 0, "ARC SAFE HAS NO CODE");

        d = _deployMissing(ARC_SAFE, mfa);

        PeanutV4 vault = PeanutV4(payable(d.vault));
        bool pending = vault.owner() == d.vaultDeployer && vault.pendingOwner() == ARC_SAFE;
        bool accepted = vault.owner() == ARC_SAFE && vault.pendingOwner() == address(0);
        require(pending || accepted, "CLAIM VAULT OWNERSHIP NOT HEADED TO THE ARC SAFE");
        console2.log("vault owner:", vault.owner());
        console2.log("vault pendingOwner:", vault.pendingOwner());
    }

    /// Post-acceptOwnership check: reverts until the Safe owns the vault.
    function verify(address mfa) public view returns (Deployment memory d) {
        _requireArcMainnet();
        d = predict(ARC_SAFE, mfa);
        require(d.vault.code.length > 0, "CLAIM VAULT NOT DEPLOYED");
        require(d.payrollBatch.code.length > 0, "PAYROLL BATCH NOT DEPLOYED");
        PeanutV4 vault = PeanutV4(payable(d.vault));
        require(vault.owner() == ARC_SAFE, "CLAIM VAULT OWNER IS NOT THE ARC SAFE");
        require(vault.pendingOwner() == address(0), "CLAIM VAULT HAS A PENDING OWNER");
        _assertWiring(d, mfa);
    }

    function _requireArcMainnet() internal view {
        require(block.chainid == ARC_MAINNET, "NOT ARC MAINNET (5042)");
    }

    function _logSafeAction(Deployment memory d) internal view {
        PeanutV4 vault = PeanutV4(payable(d.vault));
        if (vault.owner() != ARC_SAFE) {
            console2.log("ACTION REQUIRED (Arc Safe transaction): call acceptOwnership() on", d.vault);
            console2.logBytes(abi.encodeWithSignature("acceptOwnership()"));
        }
    }
}
