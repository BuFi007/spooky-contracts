// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice The subset of Uniswap Permit2's ISignatureTransfer that PayrollBatch uses.
/// Struct layouts and the function signature are copied verbatim from
/// github.com/Uniswap/permit2 src/interfaces/ISignatureTransfer.sol (MIT). They MUST stay
/// identical, because the canonical deployment at 0x000000000022D473030F116dDEE9F6B43aC78BA3
/// ABI-decodes against them.
interface ISignatureTransfer {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitBatchTransferFrom {
        TokenPermissions[] permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitWitnessTransferFrom(
        PermitBatchTransferFrom memory permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;

    function DOMAIN_SEPARATOR() external view returns (bytes32);
}
