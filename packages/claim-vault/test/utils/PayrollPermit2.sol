// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {PayrollBatch} from "../../src/payroll/PayrollBatch.sol";
import {ISignatureTransfer} from "../../src/interfaces/ISignatureTransfer.sol";
import {ClaimSigs} from "./ClaimSigs.sol";

/// Stand-in for the treasury MSCA: ERC-1271 against one quorum key; can approve Permit2.
contract Treasury1271 {
    address public immutable signer;

    constructor(address s) {
        signer = s;
    }

    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        return ECDSA.recover(hash, sig) == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    function approveMax(address token, address spender) external {
        require(msg.sender == signer, "NOT SIGNER");
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok, "APPROVE FAILED");
    }

    /// Reclaims an expired claim link (the treasury is the deposit's sender).
    function call(address target, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == signer, "NOT SIGNER");
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "CALL FAILED");
        return ret;
    }
}

/// Permit2 batch-witness signing for PayrollBatch, independent of the contract under test.
abstract contract PayrollPermit2 is ClaimSigs {
    ISignatureTransfer internal constant PERMIT2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    uint256 internal permitNonce;

    function _oneTokenPermit(address token, uint256 amount)
        internal
        returns (ISignatureTransfer.PermitBatchTransferFrom memory p)
    {
        p.permitted = new ISignatureTransfer.TokenPermissions[](1);
        p.permitted[0] = ISignatureTransfer.TokenPermissions(token, amount);
        p.nonce = ++permitNonce;
        p.deadline = block.timestamp + 1 hours;
    }

    function _signPayroll(
        PayrollBatch batch,
        ISignatureTransfer.PermitBatchTransferFrom memory p,
        bytes32 payrollId,
        PayrollBatch.Payout[] memory payouts,
        PayrollBatch.ClaimDeposit[] memory claims,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 witness = batch.witnessOf(payrollId, payouts, claims);
        bytes32[] memory hashes = new bytes32[](p.permitted.length);
        for (uint256 i; i < p.permitted.length; ++i) {
            hashes[i] = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, p.permitted[i].token, p.permitted[i].amount));
        }
        bytes32 typehash = keccak256(
            abi.encodePacked(
                "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,",
                batch.WITNESS_TYPE_STRING()
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(typehash, keccak256(abi.encodePacked(hashes)), address(batch), p.nonce, p.deadline, witness)
        );
        return sign(pk, keccak256(abi.encodePacked("\x19\x01", PERMIT2.DOMAIN_SEPARATOR(), structHash)));
    }

    function _payouts(address token, address[] memory to, uint256[] memory amounts)
        internal
        pure
        returns (PayrollBatch.Payout[] memory p)
    {
        p = new PayrollBatch.Payout[](to.length);
        for (uint256 i; i < to.length; ++i) {
            p[i] = PayrollBatch.Payout(token, to[i], amounts[i]);
        }
    }

    function _claim(address token, address linkKey, uint256 amount)
        internal
        pure
        returns (PayrollBatch.ClaimDeposit[] memory c)
    {
        c = new PayrollBatch.ClaimDeposit[](1);
        c[0] = PayrollBatch.ClaimDeposit(token, linkKey, amount);
    }
}
