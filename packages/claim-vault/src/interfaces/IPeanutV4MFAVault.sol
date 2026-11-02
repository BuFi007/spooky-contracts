// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

/// @notice The PeanutV4.4 (BUFI fork) entrypoint PayrollBatch calls.
/// @dev `makeCustomDeposit` rather than `makeSelflessMFADeposit`: only the custom
///      variant takes `_reclaimableAfter`, and BUFI deposits every claim link with a
///      30-day window (enforced for bearer links by the fork, change 2).
interface IPeanutV4MFAVault {
    function makeCustomDeposit(
        address _tokenAddress,
        uint8 _contractType,
        uint256 _amount,
        uint256 _tokenId,
        address _pubKey20,
        address _onBehalfOf,
        bool _withMFA,
        address _recipient,
        uint40 _reclaimableAfter,
        bool _isGasless3009,
        bytes calldata _args3009
    ) external payable returns (uint256);
}
