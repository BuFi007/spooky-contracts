// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {console2} from "forge-std/Script.sol";
import {PeanutV4} from "../src/V4/PeanutV4.4.sol";
import {ClaimVaultCreate2} from "./ClaimVaultCreate2.sol";

/// @notice Deterministic claim vault + PayrollBatch deployment for EVM TESTNETS ONLY.
///
///   CLAIM_VAULT_OWNER=0x… CLAIM_VAULT_MFA_SIGNER=0x… \
///     forge script script/DeployTestnet.s.sol --rpc-url <testnet rpc> --sender <deployer>
///   (add --broadcast plus a signer to actually send; simulation needs no key.)
///
/// Same addresses on every allowlisted chain:
///   - ClaimVaultDeployer via the Arachnid CREATE2 factory, salt VAULT_DEPLOYER_SALT,
///     init code = creationCode ++ abi.encode(owner, mfaSigner)  (no chain-specific args)
///   - claim vault = CREATE(ClaimVaultDeployer, nonce 1)
///   - PayrollBatch via the factory, salt PAYROLL_BATCH_SALT, args (canonical Permit2, vault)
/// Owner and MFA signer are part of the init code, so they must be identical on every chain
/// for the addresses to match. Any source/compiler change also changes the addresses.
/// Idempotent: a contract that already has code at its predicted address is skipped.
/// Arc testnet already has a legacy (non-deterministic) deployment pinned in
/// packages/env/src/payroll-batch.ts; deploying here on Arc requires ALLOW_ARC_TESTNET=true.
contract DeployTestnet is ClaimVaultCreate2 {
    uint256 internal constant ARC_TESTNET = 5042002;

    /// The only chains this script will touch. Every mainnet (and anything else) reverts.
    function isAllowedChain(uint256 chainId) public pure returns (bool) {
        return chainId == 5042002 // ARC-TESTNET
            || chainId == 43113 // AVAX-FUJI
            || chainId == 11155111 // ETH-SEPOLIA
            || chainId == 84532 // BASE-SEPOLIA
            || chainId == 421614 // ARB-SEPOLIA
            || chainId == 11155420 // OP-SEPOLIA
            || chainId == 1301 // UNI-SEPOLIA
            || chainId == 10143; // MONAD-TESTNET
    }

    function run() external returns (Deployment memory d) {
        require(isAllowedChain(block.chainid), "CHAIN NOT IN TESTNET ALLOWLIST");
        address owner = vm.envAddress("CLAIM_VAULT_OWNER");
        address mfaSigner = vm.envAddress("CLAIM_VAULT_MFA_SIGNER");
        if (block.chainid == ARC_TESTNET) {
            require(
                vm.envOr("ALLOW_ARC_TESTNET", false), "ARC TESTNET HAS A LEGACY DEPLOYMENT; SET ALLOW_ARC_TESTNET=true"
            );
        }
        vm.startBroadcast();
        d = deploy(owner, mfaSigner);
        // Finish the Ownable2Step handover in the same run when the broadcaster IS the owner.
        (, address sender,) = vm.readCallers();
        PeanutV4 vault = PeanutV4(payable(d.vault));
        if (sender == owner && vault.pendingOwner() == owner) vault.acceptOwnership();
        vm.stopBroadcast();

        if (vault.owner() != owner) {
            console2.log(
                "ACTION REQUIRED: owner must call acceptOwnership() on the vault; pending:", vault.pendingOwner()
            );
        }
        require(vault.owner() == owner || vault.pendingOwner() == owner, "vault owner mismatch");
        console2.log("vault owner:", vault.owner());
    }

    /// Deploys whatever is missing. Safe to call repeatedly.
    function deploy(address owner, address mfaSigner) public returns (Deployment memory d) {
        require(isAllowedChain(block.chainid), "CHAIN NOT IN TESTNET ALLOWLIST");
        require(owner != address(0), "ZERO CLAIM_VAULT_OWNER");
        require(mfaSigner != address(0), "ZERO CLAIM_VAULT_MFA_SIGNER");
        d = _deployMissing(owner, mfaSigner);
    }
}
