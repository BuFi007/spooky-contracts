// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {Script, console2} from "forge-std/Script.sol";
import {PeanutV4} from "../src/V4/PeanutV4.4.sol";
import {PayrollBatch} from "../src/payroll/PayrollBatch.sol";
import {ClaimVaultDeployer} from "../src/deploy/ClaimVaultDeployer.sol";
import {ISignatureTransfer} from "../src/interfaces/ISignatureTransfer.sol";
import {IPeanutV4MFAVault} from "../src/interfaces/IPeanutV4MFAVault.sol";

/// @notice The one deterministic recipe for the claim vault + PayrollBatch, shared by the
///         testnet and the Arc mainnet scripts so both use the same factory, salts and init code:
///   - ClaimVaultDeployer via the Arachnid CREATE2 factory, salt VAULT_DEPLOYER_SALT,
///     init code = creationCode ++ abi.encode(owner, mfaSigner)  (no chain-specific args)
///   - claim vault = CREATE(ClaimVaultDeployer, nonce 1); the helper hands it to `owner` with
///     Ownable2Step, so `owner` is only pendingOwner until it calls acceptOwnership()
///   - PayrollBatch via the factory, salt PAYROLL_BATCH_SALT, args (canonical Permit2, vault)
/// Owner and MFA signer are part of the init code: a different owner (testnet deployer vs the
/// Arc Safe) yields different addresses. Idempotent: anything already at its predicted address
/// is skipped. Chain gating lives in the derived scripts.
abstract contract ClaimVaultCreate2 is Script {
    address public constant ARACHNID_CREATE2 = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    bytes32 public constant VAULT_DEPLOYER_SALT = keccak256("bufi.claim-vault.deployer.v1");
    bytes32 public constant PAYROLL_BATCH_SALT = keccak256("bufi.payroll-batch.v1");

    struct Deployment {
        address vaultDeployer;
        address vault;
        address payrollBatch;
    }

    /// Pure function of (owner, mfaSigner, compiled bytecode): no chain id involved.
    function predict(address owner, address mfaSigner) public pure returns (Deployment memory d) {
        d.vaultDeployer = _create2Address(VAULT_DEPLOYER_SALT, keccak256(_vaultDeployerInitCode(owner, mfaSigner)));
        d.vault = _createAddressNonce1(d.vaultDeployer);
        d.payrollBatch = _create2Address(PAYROLL_BATCH_SALT, keccak256(_payrollBatchInitCode(d.vault)));
    }

    /// Deploys whatever is missing at the predicted addresses and checks the wiring.
    function _deployMissing(address owner, address mfaSigner) internal returns (Deployment memory d) {
        require(ARACHNID_CREATE2.code.length > 0, "NO CREATE2 FACTORY ON THIS CHAIN");
        require(PERMIT2.code.length > 0, "NO PERMIT2 ON THIS CHAIN");

        d = predict(owner, mfaSigner);
        console2.log("chainId:", block.chainid);
        console2.log("predicted ClaimVaultDeployer:", d.vaultDeployer);
        console2.log("predicted claim vault (PeanutV4):", d.vault);
        console2.log("predicted PayrollBatch:", d.payrollBatch);

        if (d.vault.code.length == 0) {
            _create2(VAULT_DEPLOYER_SALT, _vaultDeployerInitCode(owner, mfaSigner), d.vaultDeployer);
            console2.log("deployed claim vault");
        } else {
            console2.log("claim vault already deployed, skipping");
        }

        if (d.payrollBatch.code.length == 0) {
            _create2(PAYROLL_BATCH_SALT, _payrollBatchInitCode(d.vault), d.payrollBatch);
            console2.log("deployed PayrollBatch");
        } else {
            console2.log("PayrollBatch already deployed, skipping");
        }

        _assertWiring(d, mfaSigner);
    }

    function _assertWiring(Deployment memory d, address mfaSigner) internal view {
        require(PeanutV4(payable(d.vault)).MFA_AUTHORIZER() == mfaSigner, "MFA signer mismatch");
        require(address(PayrollBatch(d.payrollBatch).VAULT()) == d.vault, "batch vault mismatch");
        require(address(PayrollBatch(d.payrollBatch).PERMIT2()) == PERMIT2, "batch permit2 mismatch");
    }

    function _vaultDeployerInitCode(address owner, address mfaSigner) internal pure returns (bytes memory) {
        return abi.encodePacked(type(ClaimVaultDeployer).creationCode, abi.encode(owner, mfaSigner));
    }

    function _payrollBatchInitCode(address vault) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(PayrollBatch).creationCode, abi.encode(ISignatureTransfer(PERMIT2), IPeanutV4MFAVault(vault))
        );
    }

    function _create2(bytes32 salt, bytes memory initCode, address expected) internal {
        (bool ok, bytes memory ret) = ARACHNID_CREATE2.call(abi.encodePacked(salt, initCode));
        require(ok && ret.length == 20 && address(bytes20(ret)) == expected, "CREATE2 DEPLOY FAILED");
    }

    function _create2Address(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), ARACHNID_CREATE2, salt, initCodeHash)))));
    }

    /// CREATE address for (deployer, nonce 1): keccak256(rlp([deployer, 1])).
    function _createAddressNonce1(address deployer) internal pure returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x01))))));
    }
}
