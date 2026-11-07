// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IInvoiceShelf} from "../interfaces/IInvoiceShelf.sol";
import {IERC3009} from "../interfaces/IERC3009.sol";
import {IERC2612} from "../interfaces/IERC2612.sol";
import {MultiTokenReceivableEscrow} from "./MultiTokenReceivableEscrow.sol";

/// @title RecibuMemoRouter — multi-currency, gasless, one-signed-action memo settlement front door.
///
/// Generalizes InvoiceMemoRouter (single immutable USDC + approve→pay) into a token-parametrized
/// router with three entrypoints that all pull the payment token, bind it in that token's escrow,
/// and emit the Arc-Memo twin `RecibuPayment{token,…}`:
///   • payWithAuthorization — ERC-3009 `receiveWithAuthorization`: gasless for the payer, no prior
///     approve, one tx, replay- + expiry-safe. USDC/EURC support this natively.
///   • payWithPermit        — ERC-2612 `permit`: signed approval + pull in one tx.
///   • pay                  — legacy approve→transferFrom fallback for tokens with neither.
///
/// NOT EIP-1363: that is a token-side standard our third-party stablecoins don't implement. See
/// docs/superpowers/specs/2026-07-09-erc3009-gasless-memo-settlement.md.
///
/// Multi-currency: each allowed token maps to its OWN ReceivableEscrow (the escrow is single-token
/// by design — Σ escrowedOf == token held). `setToken` is the registry-sourced allowlist; adding a
/// stablecoin is a config action, never a redeploy. Settlement stays separate (InvoiceSettlement /
/// the CRE keeper reacting to `RecibuPayment`) — this router is the thin, auditable deposit path.
contract RecibuMemoRouter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// Capability bitfield — which signed-pull primitives a token supports.
    uint8 public constant CAP_3009 = 1 << 0;
    uint8 public constant CAP_PERMIT = 1 << 1;
    uint64 public constant TOKEN_DISABLE_DELAY = 1 days;

    bytes32 public constant AUTH_PAYMENT_NONCE_TYPEHASH = keccak256(
        "RecibuAuthorizationPayment(uint256 chainId,address router,address token,address from,uint256 invoiceId,uint8 installment,uint256 amount,uint256 validAfter,uint256 validBefore)"
    );

    struct TokenConfig {
        bool allowed;
        uint8 caps; // CAP_3009 | CAP_PERMIT
    }

    IInvoiceShelf public immutable SHELF;
    /// @notice one multi-token escrow for every settlement token (no per-token escrows).
    MultiTokenReceivableEscrow public immutable ESCROW;
    mapping(address => TokenConfig) public tokenConfig;
    mapping(address => uint64) public tokenDisableScheduledAt;

    event RecibuPayment(
        uint256 indexed invoiceId,
        uint8 indexed installment,
        bytes32 indexed memoId,
        address token,
        uint256 amount,
        address from
    );
    event TokenConfigured(address indexed token, bool allowed, uint8 caps);
    event TokenDisableScheduled(address indexed token, uint64 readyAt);

    error ZeroAmount();
    error InvoiceNotFunded(uint256 invoiceId);
    error TokenNotAllowed(address token);
    error CapabilityMissing(address token, uint8 required);
    error EscrowTokenUnsupported(address token);
    error ZeroAddress();
    error UnauthorizedPermitCaller(address caller, address owner);
    error InvalidAuthorizationNonce(bytes32 provided, bytes32 expected);
    error TokenDisableNotReady(address token, uint64 readyAt);

    constructor(IInvoiceShelf shelf, MultiTokenReceivableEscrow escrow, address admin) {
        if (address(shelf) == address(0) || address(escrow) == address(0) || admin == address(0)) revert ZeroAddress();
        SHELF = shelf;
        ESCROW = escrow;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice canonical Arc-Memo reconciliation key — byte-identical to InvoiceMemoRouter +
    ///         computeShelfMemoId (desk) so on/off-chain settlement reconcile.
    function memoIdOf(uint256 invoiceId, uint8 installment) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(invoiceId, installment));
    }

    // ── admin: registry-sourced token allowlist ──────────────────────────────

    /// @notice schedule removal of an already-enabled settlement token after TOKEN_DISABLE_DELAY.
    function scheduleTokenDisable(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (!tokenConfig[token].allowed) revert TokenNotAllowed(token);
        uint64 readyAt = uint64(block.timestamp) + TOKEN_DISABLE_DELAY;
        tokenDisableScheduledAt[token] = readyAt;
        emit TokenDisableScheduled(token, readyAt);
    }

    /// @notice enable/disable a settlement token + its per-token escrow + capabilities.
    ///         The escrow MUST be deployed for `token` (single-token invariant).
    function setToken(address token, bool allowed, uint8 caps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (allowed) {
            if (!ESCROW.supportedToken(token)) revert EscrowTokenUnsupported(token);
            delete tokenDisableScheduledAt[token];
        } else if (tokenConfig[token].allowed) {
            uint64 readyAt = tokenDisableScheduledAt[token];
            if (readyAt == 0 || block.timestamp < readyAt) revert TokenDisableNotReady(token, readyAt);
            delete tokenDisableScheduledAt[token];
        }
        tokenConfig[token] = TokenConfig(allowed, caps);
        emit TokenConfigured(token, allowed, caps);
    }

    /// @notice Deterministic ERC-3009 nonce binding `(chainId, router, token, from, invoiceId, installment, amount, validAfter, validBefore)`.
    function authorizationNonceOf(
        address token,
        address from,
        uint256 invoiceId,
        uint8 installment,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                AUTH_PAYMENT_NONCE_TYPEHASH,
                block.chainid,
                address(this),
                token,
                from,
                invoiceId,
                installment,
                amount,
                validAfter,
                validBefore
            )
        );
    }

    // ── pay: three entrypoints, one downstream ───────────────────────────────

    /// @notice legacy path — needs a prior `token.approve(router, amount)`. Fallback for tokens
    ///         with neither ERC-3009 nor ERC-2612.
    function pay(address token, uint256 invoiceId, uint8 installment, uint256 amount) external nonReentrant {
        TokenConfig memory cfg = _guard(token, invoiceId, amount);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _bind(cfg, token, invoiceId, installment, amount, msg.sender);
    }

    /// @notice ERC-2612 permit — `owner`'s signed approval + pull in one tx (no prior approve).
    function payWithPermit(
        address token,
        address owner,
        uint256 invoiceId,
        uint8 installment,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        if (msg.sender != owner) revert UnauthorizedPermitCaller(msg.sender, owner);
        TokenConfig memory cfg = _guard(token, invoiceId, amount);
        if (cfg.caps & CAP_PERMIT == 0) revert CapabilityMissing(token, CAP_PERMIT);
        try IERC2612(token).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        _bind(cfg, token, invoiceId, installment, amount, msg.sender);
    }

    /// @notice ERC-3009 receiveWithAuthorization — gasless for `from`, one tx, no approve.
    ///         `from` is the off-chain signer; any relayer may submit. The token binds the
    ///         authorization to this router (`to == address(this)`), and `nonce` commits to
    ///         `(invoiceId, installment)` so a relayer cannot redirect the payment.
    function payWithAuthorization(
        address token,
        address from,
        uint256 invoiceId,
        uint8 installment,
        uint256 amount,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        TokenConfig memory cfg = _guard(token, invoiceId, amount);
        if (cfg.caps & CAP_3009 == 0) revert CapabilityMissing(token, CAP_3009);
        bytes32 expectedNonce =
            authorizationNonceOf(token, from, invoiceId, installment, amount, validAfter, validBefore);
        if (nonce != expectedNonce) revert InvalidAuthorizationNonce(nonce, expectedNonce);
        IERC3009(token).receiveWithAuthorization(from, address(this), amount, validAfter, validBefore, nonce, v, r, s);
        _bind(cfg, token, invoiceId, installment, amount, from);
    }

    // ── internals ────────────────────────────────────────────────────────────

    function _guard(address token, uint256 invoiceId, uint256 amount) internal view returns (TokenConfig memory cfg) {
        if (amount == 0) revert ZeroAmount();
        cfg = tokenConfig[token];
        if (!cfg.allowed) revert TokenNotAllowed(token);
        if (SHELF.invoiceStatus(invoiceId) != IInvoiceShelf.Status.Funded) revert InvoiceNotFunded(invoiceId);
    }

    /// @dev token now sits in the router; bind it in the per-token escrow + emit the twin event.
    function _bind(
        TokenConfig memory cfg,
        address token,
        uint256 invoiceId,
        uint8 installment,
        uint256 amount,
        address from
    ) internal {
        IERC20(token).forceApprove(address(ESCROW), amount);
        ESCROW.deposit(invoiceId, token, amount, address(this));
        emit RecibuPayment(invoiceId, installment, memoIdOf(invoiceId, installment), token, amount, from);
    }
}
