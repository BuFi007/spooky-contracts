// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {PeanutV4} from "../V4/PeanutV4.4.sol";

/// @notice One-shot, constructor-only deployer for the BUFI claim vault (PeanutV4.4 fork).
/// @dev Why it exists: PeanutV4's Ownable constructor makes `msg.sender` the owner. Deployed
///      straight through the Arachnid CREATE2 factory, the FACTORY would own the vault and
///      ownership would be bricked. This helper is deployed through the factory instead (so its
///      address is the same on every chain), creates the vault with CREATE (nonce 1, so the vault
///      address is also chain-independent), and hands ownership to `owner` via Ownable2Step.
///      `owner` must call `acceptOwnership()` on the vault to finish the handover. The helper has
///      no functions and no fallback (every call reverts), so while ownership is pending it can do nothing.
///      The audited vault bytecode is unchanged.
contract ClaimVaultDeployer {
    /// @notice Emitted when `vault` is deployed and ownership handover to `pendingOwner` is initiated.
    /// @dev `vault.owner()` remains `address(this)` until `pendingOwner` calls `vault.acceptOwnership()`.
    event ClaimVaultDeployed(address indexed vault, address indexed pendingOwner, address indexed mfaAuthorizer);

    constructor(address owner, address mfaAuthorizer) {
        require(owner != address(0), "ZERO OWNER");
        require(mfaAuthorizer != address(0), "ZERO MFA AUTHORIZER");
        // ecoAddress = address(0): no ECO on any supported chain, and it keeps init code chain-independent.
        PeanutV4 vault = new PeanutV4(address(0), mfaAuthorizer);
        vault.transferOwnership(owner);
        emit ClaimVaultDeployed(address(vault), owner, mfaAuthorizer);
    }
}
