// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MultiTokenReceivableEscrow — invoice-bound custody for debtor repayments, any
///        admin-allowlisted settlement token (Midnight hub; plan §11.C).
/// @notice Same hardening as ReceivableEscrow, generalized to N tokens:
///   - every invoice is bound to ONE token while escrowed (`tokenOf`), later deposits
///     in another token revert, and clearing to zero unbinds `tokenOf` and `refundUnlockAt`;
///   - no function moves funds without an invoiceId; release/refund ≤ escrowedOf[invoiceId];
///   - Σ escrowedOf over invoices of token T == totalEscrowedOf[T] ≤ T.balanceOf(this).
///   SETTLEMENT_ROLE is reserved for the Midnight repay adapter (escrow → Midnight.repay).
contract MultiTokenReceivableEscrow is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 public constant ARBITER_ROLE = keccak256("ARBITER_ROLE");
    bytes32 public constant ROUTER_ROLE = keccak256("ROUTER_ROLE");

    uint64 public constant TOKEN_DISABLE_DELAY = 1 days;
    uint64 public constant TOKEN_DISABLE_WINDOW = 7 days;
    uint64 public constant DEFAULT_REFUND_LOCK_DURATION = 1 hours;
    uint64 public constant MIN_REFUND_LOCK_DURATION = 5 minutes;
    uint64 public constant MAX_REFUND_LOCK_DURATION = 7 days;

    mapping(address token => bool) public supportedToken;
    mapping(address token => uint64) public tokenDisableScheduledAt;
    mapping(uint256 invoiceId => address) public tokenOf;
    mapping(uint256 invoiceId => uint256) public escrowedOf;
    mapping(uint256 invoiceId => uint64) public refundUnlockAt;
    mapping(address token => uint256) public totalEscrowedOf;
    uint64 public refundLockDuration = DEFAULT_REFUND_LOCK_DURATION;

    event TokenSupported(address indexed token, bool supported);
    event TokenDisableScheduled(address indexed token, uint64 readyAt);
    event TokenDisableCancelled(address indexed token);
    event Deposited(uint256 indexed invoiceId, address indexed token, address indexed from, uint256 amount);
    event Released(uint256 indexed invoiceId, address indexed token, address indexed to, uint256 amount);
    event Refunded(uint256 indexed invoiceId, address indexed token, address indexed to, uint256 amount);
    event RefundLockSet(uint256 indexed invoiceId, uint64 unlockAt);
    event RefundLockDurationSet(uint64 duration);

    error ZeroAddress();
    error ZeroAmount();
    error TokenNotSupported(address token);
    error TokenDisableNotReady(address token, uint64 readyAt);
    error InvoiceTokenMismatch(uint256 invoiceId, address bound, address given);
    error InsufficientEscrow(uint256 invoiceId, uint256 have, uint256 want);
    error RefundLocked(uint256 invoiceId, uint64 unlockAt);
    error InvalidRefundLock(uint64 value);
    error BalanceMismatch();
    error InvalidDepositor(address caller, address from);

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function scheduleTokenDisable(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (!supportedToken[token]) revert TokenNotSupported(token);
        uint64 readyAt = uint64(block.timestamp) + TOKEN_DISABLE_DELAY;
        tokenDisableScheduledAt[token] = readyAt;
        emit TokenDisableScheduled(token, readyAt);
    }

    function cancelTokenDisable(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        delete tokenDisableScheduledAt[token];
        emit TokenDisableCancelled(token);
    }

    /// @notice enabling is free; disabling requires a scheduled timelock within the execution window
    ///         and only blocks NEW invoice bindings (already-bound in-flight invoices stay payable).
    function setToken(address token, bool supported) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (supported) {
            delete tokenDisableScheduledAt[token];
        } else if (supportedToken[token]) {
            uint64 readyAt = tokenDisableScheduledAt[token];
            if (
                readyAt == 0 || block.timestamp < readyAt
                    || block.timestamp > uint256(readyAt) + TOKEN_DISABLE_WINDOW
            ) {
                revert TokenDisableNotReady(token, readyAt);
            }
            delete tokenDisableScheduledAt[token];
        }
        supportedToken[token] = supported;
        emit TokenSupported(token, supported);
    }

    function setRefundLockDuration(uint64 duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (duration < MIN_REFUND_LOCK_DURATION || duration > MAX_REFUND_LOCK_DURATION) {
            revert InvalidRefundLock(duration);
        }
        refundLockDuration = duration;
        emit RefundLockDurationSet(duration);
    }

    function deposit(uint256 invoiceId, address token, uint256 amount, address from)
        external
        onlyRole(ROUTER_ROLE)
        nonReentrant
    {
        if (from != msg.sender) revert InvalidDepositor(msg.sender, from);
        if (amount == 0) revert ZeroAmount();
        bool alreadyBound = tokenOf[invoiceId] == token && escrowedOf[invoiceId] > 0;
        if (!supportedToken[token] && !alreadyBound) revert TokenNotSupported(token);

        address bound = tokenOf[invoiceId];
        if (bound == address(0)) tokenOf[invoiceId] = token;
        else if (bound != token) revert InvoiceTokenMismatch(invoiceId, bound, token);

        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBal = IERC20(token).balanceOf(address(this));
        if (afterBal != before + amount) revert BalanceMismatch();

        bool wasEmpty = escrowedOf[invoiceId] == 0;
        escrowedOf[invoiceId] += amount;
        totalEscrowedOf[token] += amount;
        if (wasEmpty) {
            uint64 unlockAt = uint64(block.timestamp) + refundLockDuration;
            if (unlockAt > refundUnlockAt[invoiceId]) {
                refundUnlockAt[invoiceId] = unlockAt;
                emit RefundLockSet(invoiceId, unlockAt);
            }
        }
        emit Deposited(invoiceId, token, msg.sender, amount);
    }

    function setRefundLock(uint256 invoiceId, uint64 unlockAt) external {
        bool isAdmin = hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
        if (!isAdmin && !hasRole(ROUTER_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, ROUTER_ROLE);
        }
        if (uint256(unlockAt) > block.timestamp + uint256(MAX_REFUND_LOCK_DURATION)) {
            revert InvalidRefundLock(unlockAt);
        }
        if (!isAdmin && unlockAt < refundUnlockAt[invoiceId]) {
            revert InvalidRefundLock(unlockAt);
        }
        refundUnlockAt[invoiceId] = unlockAt;
        emit RefundLockSet(invoiceId, unlockAt);
    }

    function releaseTo(uint256 invoiceId, address to, uint256 amount) external onlyRole(SETTLEMENT_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        address token = _debit(invoiceId, amount);
        IERC20(token).safeTransfer(to, amount);
        emit Released(invoiceId, token, to, amount);
    }

    function refund(uint256 invoiceId, address to, uint256 amount) external onlyRole(ARBITER_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint64 unlock = refundUnlockAt[invoiceId];
        if (block.timestamp < unlock) revert RefundLocked(invoiceId, unlock);
        address token = _debit(invoiceId, amount);
        IERC20(token).safeTransfer(to, amount);
        emit Refunded(invoiceId, token, to, amount);
    }

    function _debit(uint256 invoiceId, uint256 amount) internal returns (address token) {
        if (amount == 0) revert ZeroAmount();
        uint256 have = escrowedOf[invoiceId];
        if (amount > have) revert InsufficientEscrow(invoiceId, have, amount);
        token = tokenOf[invoiceId];
        uint256 remaining = have - amount;
        escrowedOf[invoiceId] = remaining;
        totalEscrowedOf[token] -= amount;
        if (remaining == 0) {
            delete tokenOf[invoiceId];
            delete refundUnlockAt[invoiceId];
        }
    }
}
