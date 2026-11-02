// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";

/// @notice Independent re-implementation of the two claim digests (spec: SIGNATURES.md).
///         Deliberately NOT calling the vault, so a drift between the contract and the
///         documented spec fails the tests.
abstract contract ClaimSigs is Test {
    bytes32 internal constant SALT = keccak256("Konrad makes tokens go woosh tadam");
    bytes32 internal constant MODE_ANYONE = bytes32(0);
    bytes32 internal constant MODE_RECIPIENT = keccak256("only recipient");

    /// Digest the LINK key signs (EIP-191 personal_sign over a 32-byte inner hash).
    function linkDigest(uint256 chainId, address vault, uint256 index, address recipient, bytes32 mode)
        internal
        pure
        returns (bytes32)
    {
        bytes32 inner = keccak256(abi.encodePacked(SALT, chainId, vault, index, recipient, mode));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
    }

    /// Digest the MFA_AUTHORIZER signs (same prefix, NO trailing mode word).
    function mfaDigest(uint256 chainId, address vault, uint256 index, address recipient)
        internal
        pure
        returns (bytes32)
    {
        bytes32 inner = keccak256(abi.encodePacked(SALT, chainId, vault, index, recipient));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
    }

    function sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
