// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {BurnIntent, GatewayIntentPolicy, IntentLimits} from "../gateway-guard/GatewayIntentPolicy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

interface IAgentGatewayWallet {
    function deposit(address token, uint256 amount) external;
    function initiateWithdrawal(address token, uint256 amount) external;
    function withdraw(address token) external;
}

interface IAgentRecibuRouter {
    function SETTLEMENT_TOKEN() external view returns (address);
    function pay(address token, uint256 invoiceId, uint8 installment, uint256 amount) external;
}

/// @notice Local, unaudited per-connection Gateway depositor. No delegate, arbitrary-call or upgrade entry point.
/// @dev One account per (owner, agent connection). `owner` is the real Personal signer or the Treasury quorum account,
/// never an OAuth client, a shared Circle DCW or a team-member id. The canonical ERC-8004 NFT is held by this account;
/// only its owner/quorum can release it. Account-local epochs invalidate grants across every release and receipt.
///
/// Two independent funding rails, each with its own explicit owner assignment and its own accounting:
///  1. Gateway transfers: `assign` -> `reserveGateway`. Value + maxFee is charged against the signed grant and the
///     per-asset allocation BEFORE the ERC-1271 marker validates. Commitments are NEVER recycled (timeout, revocation,
///     expiry and key rotation do not prove a burn cannot still settle).
///  2. Local document checkout: `fundLocal` -> `checkout`. One transaction: spend check, router pull and escrow
///     funding, or full revert. It never touches the Gateway allocation.
///
/// Document funding FROM Gateway is NOT supported (GATEWAY_FUNDED_DOCUMENT_CHECKOUT == false): the burn, the
/// attestation and the mint are separate operations and the burn is executed off this chain's transaction, so no
/// single transaction can cover burn + mint + escrow funding. Such routes are refused before anything is exposed.
///
/// Honest limits: ERC-1271 is read-only and Gateway may validate historical state; an already-issued intent or
/// attestation can outlive revocation. Revocation blocks NEW reservations and current reads on this chain only.
contract AgentGatewayAccount is EIP712, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    enum Action {
        GatewayTransfer,
        LocalCheckout
    }
    /// @dev Finite owner operations for treasuries whose AddressBook forbids arbitrary calls.
    enum OwnerAction {
        AssignGateway,
        FundLocal,
        RevokeGrant,
        InvalidateAll,
        RotateAgentKey,
        RecoverLocal,
        InitiateRecovery,
        CompleteRecovery,
        RecoverIdentity
    }

    struct OwnerAuthorization {
        OwnerAction action;
        address token;
        uint256 amount;
        address target;
        bytes32 grantHash;
        uint256 epoch;
        bytes32 nonce;
        uint64 deadline;
    }

    enum Asset {
        USDC,
        EURC,
        CirBTC
    }

    struct Route {
        Asset asset;
        address token;
        uint32 destinationDomain;
        bytes32 destinationToken;
        bytes32 destinationMinter;
    }

    /// @dev Signed by `owner` (EIP-712, domain = this chain + this account). The domain binds chain and account;
    /// the fields bind registry/id/custody epoch, agent key, asset, route, recipient, limits, expiry, salt (nonce)
    /// and the account revocation epoch.
    struct Grant {
        address owner;
        address agent;
        address identityRegistry;
        uint256 identityId;
        uint256 identityEpoch;
        uint256 accountEpoch;
        address token;
        uint32 destinationDomain;
        bytes32 destinationToken;
        bytes32 recipient;
        bytes32 destinationCaller;
        Action action;
        bytes32 checkoutHash;
        bytes32 salt;
        uint256 limit;
        uint256 perIntent;
        uint256 maxFee;
        uint64 validAfter;
        uint64 validUntil;
    }

    struct Checkout {
        uint256 invoiceId;
        uint8 installment;
        uint256 amount;
        bytes32 nonce;
        uint256 deadline;
    }

    struct Reservation {
        bytes32 grantHash;
        uint256 maxBlockHeight;
        uint256 value;
    }

    struct AssetBudget {
        uint256 assigned; // Only explicit owner `assign` deposits. Donations never increase this.
        uint256 committed; // Lifetime worst-case debit, INCLUDING unresolved Gateway reservations.
        uint256 gatewayReserved; // Worst-case commitment; not evidence of actual settlement.
    }

    struct LocalBudget {
        uint256 funded; // Only explicit owner `fundLocal`. Staged/unsolicited balances never count.
        uint256 escrowed; // Lifetime amount pushed into invoice escrow. Escrow funding, not final settlement.
    }

    bytes32 public constant GRANT_TYPEHASH = keccak256(
        "Grant(address owner,address agent,address identityRegistry,uint256 identityId,uint256 identityEpoch,uint256 accountEpoch,address token,uint32 destinationDomain,bytes32 destinationToken,bytes32 recipient,bytes32 destinationCaller,uint8 action,bytes32 checkoutHash,bytes32 salt,uint256 limit,uint256 perIntent,uint256 maxFee,uint64 validAfter,uint64 validUntil)"
    );
    bytes32 public constant OPERATION_TYPEHASH = keccak256("AgentOperation(bytes32 grantHash,bytes32 operationHash)");
    bytes32 public constant CHECKOUT_TYPEHASH =
        keccak256("Checkout(uint256 invoiceId,uint8 installment,uint256 amount,bytes32 nonce,uint256 deadline)");
    bytes32 public constant OWNER_ACTION_TYPEHASH = keccak256(
        "OwnerAuthorization(uint8 action,address token,uint256 amount,address target,bytes32 grantHash,uint256 epoch,bytes32 nonce,uint64 deadline)"
    );
    bytes4 private constant VALID = 0x1626ba7e;
    bytes4 private constant INVALID = 0xffffffff;
    /// @dev Gas ceiling for the owner's ERC-1271 call (Treasury quorum verification).
    uint256 private constant OWNER_1271_GAS = 500_000;
    /// @dev Contract agent verification is separately bounded; owner approval is always also required.
    uint256 private constant AGENT_1271_GAS = 500_000;

    /// @notice Explicit gate. Gateway cannot supply burn + mint + escrow funding in one transaction.
    bool public constant GATEWAY_FUNDED_DOCUMENT_CHECKOUT = false;

    uint256 public immutable sourceChainId;
    address public immutable owner; // Personal signing account or the actual Treasury quorum account, never a member
    // ID.
    address public immutable identityRegistry;
    uint256 public immutable identityId;
    address public immutable gatewayWallet;
    uint32 public immutable localDomain;
    uint256 public immutable maxExpiryBlocks;
    address public immutable recibuRouter; // address(0) disables local checkout.
    address public agentKey;
    uint256 public accountEpoch;
    uint256 public identityEpoch;

    mapping(bytes32 => bytes32) public routes;
    mapping(address => bool) public supportedTokens;
    mapping(address => AssetBudget) public budgets;
    mapping(address => LocalBudget) public localBudgets;
    mapping(bytes32 => Grant) private _grants;
    mapping(bytes32 => uint256) public committedByGrant;
    mapping(bytes32 => bool) public revoked;
    mapping(bytes32 => Reservation) public reservations;
    mapping(bytes32 => bool) public usedCheckoutNonces;
    mapping(bytes32 => bool) public usedOwnerNonces;

    event OwnerActionExecuted(bytes32 indexed nonce, OwnerAction indexed action, bytes32 authorizationHash);
    event Assigned(address indexed token, uint256 amount);
    event LocalFunded(address indexed token, uint256 amount);
    event Reserved(bytes32 indexed digest, bytes32 indexed grantHash, address indexed token, uint256 maximumDebit);
    event CheckoutEscrowed(
        bytes32 indexed grantHash,
        bytes32 indexed nonce,
        uint256 invoiceId,
        uint8 installment,
        address token,
        uint256 amount
    );
    event IdentityCustodied(uint256 indexed identityId, uint256 epoch);
    event IdentityRecovered(address indexed recipient, uint256 epoch);
    event GrantRevoked(bytes32 indexed grantHash);
    event EpochChanged(uint256 epoch, address indexed agent);
    error Refused();

    constructor(
        address owner_,
        address agent_,
        address registry_,
        uint256 id_,
        address gateway_,
        uint32 domain_,
        uint256 expiryBlocks_,
        address router_,
        Route[] memory routes_
    ) EIP712("BUFI Agent Gateway Account", "1") {
        if (
            owner_ == address(0) || agent_ == address(0) || agent_ == owner_ || agent_ == address(this)
                || registry_.code.length == 0 || gateway_.code.length == 0 || domain_ != 26 || expiryBlocks_ == 0
                || registry_
                    != (block.chainid == 5042002
                            ? address(0x8004A818BFB912233c491871b3d84c89A494BD9e)
                            : address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432))
                || (router_ != address(0) && router_.code.length == 0)
                || (block.chainid != 5042 && block.chainid != 5042002)
                || gateway_
                    != (block.chainid == 5042002
                            ? address(0x0077777d7EBA4688BDeF3E311b846F25870A19B9)
                            : address(0x77777777Dcc4d5A8B6E418Fd04D8997ef11000eE))
        ) revert Refused();
        sourceChainId = block.chainid;
        owner = owner_;
        agentKey = agent_;
        identityRegistry = registry_;
        identityId = id_;
        gatewayWallet = gateway_;
        localDomain = domain_;
        maxExpiryBlocks = expiryBlocks_;
        recibuRouter = router_;
        for (uint256 i; i < routes_.length; ++i) {
            Route memory r = routes_[i];
            uint8 decimals = r.asset == Asset.CirBTC ? 8 : 6;
            if (
                r.token.code.length == 0 || IERC20Metadata(r.token).decimals() != decimals
                    || r.token != _canonicalToken(r.asset, 26)
                    || r.destinationToken
                        != GatewayIntentPolicy.toBytes32(_canonicalToken(r.asset, r.destinationDomain))
                    || r.destinationMinter
                        != GatewayIntentPolicy.toBytes32(
                            block.chainid == 5042002
                                ? address(0x0022222ABE238Cc2C7Bb1f21003F0a260052475B)
                                : address(0x2222222d7164433c4C09B0b0D809a9b52C04C205)
                        ) || !_supportedDomain(r.asset, r.destinationDomain)
                    || !GatewayIntentPolicy.matchesDomainShape(r.destinationDomain, r.destinationToken)
                    || !GatewayIntentPolicy.matchesDomainShape(r.destinationDomain, r.destinationMinter)
            ) revert Refused();
            bytes32 key = keccak256(abi.encode(r.token, r.destinationDomain));
            if (routes[key] != bytes32(0)) revert Refused();
            routes[key] = keccak256(abi.encode(r.destinationToken, r.destinationMinter));
            supportedTokens[r.token] = true;
        }
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Refused();
        _;
    }

    /// @notice Receive only this account's canonical identity. Receipt never adds spending budget.
    function onERC721Received(address, address, uint256 tokenId, bytes calldata)
        external
        override
        nonReentrant
        returns (bytes4)
    {
        if (
            msg.sender != identityRegistry || tokenId != identityId
                || IERC721(identityRegistry).ownerOf(identityId) != address(this)
        ) revert Refused();
        ++identityEpoch;
        ++accountEpoch;
        emit IdentityCustodied(identityId, identityEpoch);
        emit EpochChanged(accountEpoch, agentKey);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Only the real owner/quorum may release the NFT; old grants never revive on return.
    function recoverIdentity(address recipient) external onlyOwner nonReentrant {
        _recoverIdentity(recipient);
    }

    function _recoverIdentity(address recipient) private {
        if (recipient == address(0) || recipient == address(this)) revert Refused();
        ++identityEpoch;
        ++accountEpoch;
        IERC721(identityRegistry).safeTransferFrom(address(this), recipient, identityId);
        emit IdentityRecovered(recipient, identityEpoch);
        emit EpochChanged(accountEpoch, agentKey);
    }

    function grantDigest(Grant memory g) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(GRANT_TYPEHASH, g)));
    }

    function checkoutHash(Checkout memory c) public pure returns (bytes32) {
        return keccak256(abi.encode(CHECKOUT_TYPEHASH, c));
    }

    function operationDigest(bytes32 grantHash, bytes32 operationHash) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(OPERATION_TYPEHASH, grantHash, operationHash)));
    }

    /// @notice Explicit owner/Treasury Gateway allocation: atomic pull, Gateway deposit and accounting.
    function assign(address token, uint256 amount) external onlyOwner nonReentrant {
        _assign(token, amount);
    }

    function _assign(address token, uint256 amount) private {
        if (!supportedTokens[token] || amount == 0) revert Refused();
        IERC20 t = IERC20(token);
        uint256 before_ = t.balanceOf(address(this));
        t.safeTransferFrom(owner, address(this), amount);
        if (t.balanceOf(address(this)) != before_ + amount) revert Refused();
        t.forceApprove(gatewayWallet, amount);
        IAgentGatewayWallet(gatewayWallet).deposit(token, amount);
        t.forceApprove(gatewayWallet, 0);
        if (t.balanceOf(address(this)) != before_) revert Refused();
        budgets[token].assigned += amount;
        emit Assigned(token, amount);
    }

    /// @notice Explicit owner/Treasury allocation held LOCALLY for document checkout. Never enters Gateway and
    /// never counts toward the Gateway allocation. Only the router's settlement token is accepted.
    function fundLocal(address token, uint256 amount) external onlyOwner nonReentrant {
        _fundLocal(token, amount);
    }

    function _fundLocal(address token, uint256 amount) private {
        address router = recibuRouter;
        if (
            router == address(0) || router.code.length == 0 || !supportedTokens[token] || amount == 0
                || IAgentRecibuRouter(router).SETTLEMENT_TOKEN() != token
        ) revert Refused();
        IERC20 t = IERC20(token);
        uint256 before_ = t.balanceOf(address(this));
        t.safeTransferFrom(owner, address(this), amount);
        if (t.balanceOf(address(this)) != before_ + amount) revert Refused();
        localBudgets[token].funded += amount;
        emit LocalFunded(token, amount);
    }

    /// @notice Reserve one Gateway burn. Independent transfers only; document-funding routes are refused up front.
    function reserveGateway(
        Grant calldata g,
        bytes calldata ownerSignature,
        BurnIntent calldata intent,
        bytes calldata agentSignature
    ) external nonReentrant returns (bytes32 digest) {
        // Incompatible routes die BEFORE any signature work or effect: no checkout grant, no document binding, and
        // no same-domain recipient that would stage Gateway proceeds into this account, the router or the wallet.
        if (g.action != Action.GatewayTransfer || g.checkoutHash != bytes32(0) || _stagesLocally(g)) revert Refused();
        digest = GatewayIntentPolicy.burnIntentDigest(intent);
        bytes32 grantHash = _authenticate(g, ownerSignature, digest, agentSignature);
        (bool ok, address token) = GatewayIntentPolicy.checkIntentShape(
            intent,
            IntentLimits({
                gatewayWallet: gatewayWallet,
                sourceDomain: localDomain,
                depositor: address(this),
                maxExpiryBlocks: maxExpiryBlocks,
                perIntentCap: g.perIntent,
                maxFeeCap: g.maxFee
            })
        );
        if (
            !ok || token != g.token || intent.maxBlockHeight <= block.number
                || intent.spec.destinationDomain != g.destinationDomain
                || intent.spec.destinationToken != g.destinationToken || intent.spec.destinationRecipient != g.recipient
                || intent.spec.destinationCaller != g.destinationCaller
                || routes[keccak256(abi.encode(token, g.destinationDomain))]
                    != keccak256(abi.encode(intent.spec.destinationToken, intent.spec.destinationContract))
        ) revert Refused();
        if (
            !GatewayIntentPolicy.matchesDomainShape(g.destinationDomain, g.recipient)
                || (g.destinationCaller != bytes32(0)
                    && !GatewayIntentPolicy.matchesDomainShape(g.destinationDomain, g.destinationCaller))
                || reservations[digest].grantHash != bytes32(0)
        ) revert Refused();
        uint256 debit = intent.spec.value + intent.maxFee;
        AssetBudget storage b = budgets[token];
        if (committedByGrant[grantHash] + debit > g.limit || b.committed + debit > b.assigned) revert Refused();
        committedByGrant[grantHash] += debit;
        b.committed += debit;
        b.gatewayReserved += debit;
        if (_grants[grantHash].agent == address(0)) _grants[grantHash] = g;
        reservations[digest] = Reservation(grantHash, intent.maxBlockHeight, intent.spec.value);
        emit Reserved(digest, grantHash, token, debit);
    }

    /// @notice Only exact precommitted Gateway burns validate. No generic owner signature, token authorization or
    /// delegate bypass. View-only: repeated reads can never consume budget.
    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != 1 || signature[0] != 0x01) return INVALID;
        Reservation memory r = reservations[digest];
        if (
            r.grantHash == bytes32(0) || block.number > r.maxBlockHeight || !_current(_grants[r.grantHash], r.grantHash)
        ) {
            return INVALID;
        }
        return VALID;
    }

    /// @notice Atomic local document checkout. ONE transaction: authorization, local debit, nonce, allowance, router
    /// pull and escrow funding all succeed together or everything reverts. Consumes ONLY `localBudgets` and the grant.
    /// @dev The router call funds invoice escrow; it is NOT final debt settlement. Requires this account to be the
    /// shelf's assigned debtorPayer. EURC/cirBTC fail here unless the router's settlement token is that asset.
    function checkout(
        Grant calldata g,
        bytes calldata ownerSignature,
        Checkout calldata c,
        bytes calldata agentSignature
    ) external nonReentrant {
        address router = recibuRouter;
        bytes32 op = checkoutHash(c);
        // Route compatibility is decided before signatures, effects or any token movement.
        if (
            router == address(0) || router.code.length == 0 || g.action != Action.LocalCheckout || g.checkoutHash != op
                || g.recipient != GatewayIntentPolicy.toBytes32(router) || g.destinationDomain != localDomain
                || g.destinationToken != GatewayIntentPolicy.toBytes32(g.token) || g.destinationCaller != bytes32(0)
                || c.amount == 0 || c.amount > g.perIntent || c.deadline < block.timestamp || c.deadline > g.validUntil
                || usedCheckoutNonces[c.nonce] || IAgentRecibuRouter(router).SETTLEMENT_TOKEN() != g.token
        ) revert Refused();
        bytes32 grantHash = _authenticate(g, ownerSignature, op, agentSignature);
        LocalBudget storage lb = localBudgets[g.token];
        if (committedByGrant[grantHash] + c.amount > g.limit || lb.escrowed + c.amount > lb.funded) revert Refused();
        committedByGrant[grantHash] += c.amount;
        lb.escrowed += c.amount;
        usedCheckoutNonces[c.nonce] = true;
        IERC20 token = IERC20(g.token);
        uint256 before_ = token.balanceOf(address(this));
        token.forceApprove(router, c.amount);
        IAgentRecibuRouter(router).pay(g.token, c.invoiceId, c.installment, c.amount);
        token.forceApprove(router, 0);
        // The router must have pulled exactly the signed amount, no more and no less.
        if (token.balanceOf(address(this)) + c.amount != before_) revert Refused();
        emit CheckoutEscrowed(grantHash, c.nonce, c.invoiceId, c.installment, g.token, c.amount);
    }

    function revokeGrant(bytes32 grantHash) external onlyOwner nonReentrant {
        _revokeGrant(grantHash);
    }

    function _revokeGrant(bytes32 grantHash) private {
        revoked[grantHash] = true;
        emit GrantRevoked(grantHash);
    }

    function invalidateAll() external onlyOwner nonReentrant {
        _invalidateAll();
    }

    function _invalidateAll() private {
        ++accountEpoch;
        emit EpochChanged(accountEpoch, agentKey);
    }

    function rotateAgentKey(address next) external onlyOwner nonReentrant {
        _rotateAgentKey(next);
    }

    function _rotateAgentKey(address next) private {
        if (next == address(0) || next == owner || next == address(this)) revert Refused();
        agentKey = next;
        ++accountEpoch;
        emit EpochChanged(accountEpoch, next);
    }

    /// @notice Recovery never requires a valid agent identity or consent. Outstanding Gateway burns can still win the
    /// race.
    function initiateRecovery(address token, uint256 amount) external onlyOwner nonReentrant {
        _initiateRecovery(token, amount);
    }

    function _initiateRecovery(address token, uint256 amount) private {
        if (!supportedTokens[token]) revert Refused();
        ++accountEpoch;
        // Remove ALL uncommitted allocation before any recovery. Old commitments are never recycled.
        budgets[token].assigned = budgets[token].committed;
        IAgentGatewayWallet(gatewayWallet).initiateWithdrawal(token, amount);
        emit EpochChanged(accountEpoch, agentKey);
    }

    /// @notice Return staged, unsolicited or unspent locally funded tokens even if Gateway withdrawal is unavailable.
    function recoverLocal(address token) external onlyOwner nonReentrant {
        _recoverLocal(token);
    }

    function _recoverLocal(address token) private {
        _closeAllocation(token);
        IERC20(token).safeTransfer(owner, IERC20(token).balanceOf(address(this)));
    }

    function completeRecovery(address token) external onlyOwner nonReentrant {
        _completeRecovery(token);
    }

    function _completeRecovery(address token) private {
        _closeAllocation(token);
        IAgentGatewayWallet(gatewayWallet).withdraw(token);
        IERC20(token).safeTransfer(owner, IERC20(token).balanceOf(address(this)));
    }

    function ownerActionDigest(OwnerAuthorization memory authorization) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(OWNER_ACTION_TYPEHASH, authorization)));
    }

    /// @notice A relay may submit only this finite owner-signed operation. The owner remains the treasury
    /// quorum and ERC-1271 is checked at execution; a relay or DB role confers no authority. ERC20 funding
    /// still requires the treasury's independently authorized token allowance to this account.
    function executeOwnerAction(OwnerAuthorization calldata a, bytes calldata ownerSignature) external nonReentrant {
        if (a.epoch != accountEpoch || block.timestamp >= a.deadline || usedOwnerNonces[a.nonce]) revert Refused();
        _validateOwnerFields(a);
        bytes32 digest = ownerActionDigest(a);
        if (!_ownerSigned(digest, ownerSignature)) revert Refused();
        usedOwnerNonces[a.nonce] = true;
        if (a.action == OwnerAction.AssignGateway) _assign(a.token, a.amount);
        else if (a.action == OwnerAction.FundLocal) _fundLocal(a.token, a.amount);
        else if (a.action == OwnerAction.RevokeGrant) _revokeGrant(a.grantHash);
        else if (a.action == OwnerAction.InvalidateAll) _invalidateAll();
        else if (a.action == OwnerAction.RotateAgentKey) _rotateAgentKey(a.target);
        else if (a.action == OwnerAction.RecoverLocal) _recoverLocal(a.token);
        else if (a.action == OwnerAction.InitiateRecovery) _initiateRecovery(a.token, a.amount);
        else if (a.action == OwnerAction.CompleteRecovery) _completeRecovery(a.token);
        else if (a.action == OwnerAction.RecoverIdentity) _recoverIdentity(a.target);
        else revert Refused();
        emit OwnerActionExecuted(a.nonce, a.action, digest);
    }

    /// @dev Canonical fields avoid signers approving irrelevant values or ambiguous operation descriptions.
    function _validateOwnerFields(OwnerAuthorization calldata a) private pure {
        bool hasToken = a.action == OwnerAction.AssignGateway || a.action == OwnerAction.FundLocal
            || a.action == OwnerAction.RecoverLocal || a.action == OwnerAction.InitiateRecovery
            || a.action == OwnerAction.CompleteRecovery;
        bool hasAmount = a.action == OwnerAction.AssignGateway || a.action == OwnerAction.FundLocal
            || a.action == OwnerAction.InitiateRecovery;
        bool hasTarget = a.action == OwnerAction.RotateAgentKey || a.action == OwnerAction.RecoverIdentity;
        if ((!hasToken && a.token != address(0)) || (!hasAmount && a.amount != 0)
            || (!hasTarget && a.target != address(0))
            || (a.action != OwnerAction.RevokeGrant && a.grantHash != bytes32(0))) revert Refused();
    }

    function _closeAllocation(address token) private {
        ++accountEpoch;
        budgets[token].assigned = budgets[token].committed;
        localBudgets[token].funded = localBudgets[token].escrowed;
        emit EpochChanged(accountEpoch, agentKey);
    }

    /// @dev Same-domain recipients that would deliver Gateway proceeds into this account, the router, the Gateway
    /// wallet or the token itself. That is an (eventual, non-atomic) document-funding route and is refused.
    function _stagesLocally(Grant calldata g) private view returns (bool) {
        if (g.destinationDomain != localDomain) return false;
        bytes32 r = g.recipient;
        return r == GatewayIntentPolicy.toBytes32(address(this)) || r == GatewayIntentPolicy.toBytes32(recibuRouter)
            || r == GatewayIntentPolicy.toBytes32(gatewayWallet) || r == GatewayIntentPolicy.toBytes32(g.token);
    }

    function _authenticate(
        Grant memory g,
        bytes memory ownerSignature,
        bytes32 operationHash,
        bytes memory agentSignature
    ) private view returns (bytes32 hash) {
        hash = grantDigest(g);
        if (!_current(g, hash) || !_ownerSigned(hash, ownerSignature)) revert Refused();
        bytes32 digest = operationDigest(hash, operationHash);
        if (agentKey.code.length == 0) {
            (address signer, ECDSA.RecoverError error, bytes32 errorArg) = ECDSA.tryRecover(digest, agentSignature);
            if (error != ECDSA.RecoverError.NoError || errorArg != bytes32(0) || signer != agentKey) revert Refused();
        } else if (!GatewayIntentPolicy.isValidERC1271(agentKey, digest, agentSignature, AGENT_1271_GAS)) {
            revert Refused();
        }
    }

    /// @dev EOA owner: ECDSA. Contract owner (Treasury quorum): bounded, return-bomb-safe ERC-1271 staticcall.
    function _ownerSigned(bytes32 hash, bytes memory signature) private view returns (bool) {
        address o = owner;
        if (o.code.length == 0) {
            (address signer, ECDSA.RecoverError error, bytes32 errorArg) = ECDSA.tryRecover(hash, signature);
            return error == ECDSA.RecoverError.NoError && errorArg == bytes32(0) && signer == o;
        }
        return GatewayIntentPolicy.isValidERC1271(o, hash, signature, OWNER_1271_GAS);
    }

    function _current(Grant memory g, bytes32 hash) private view returns (bool) {
        if (
            block.chainid != sourceChainId || g.owner != owner || g.agent != agentKey
                || g.identityRegistry != identityRegistry || g.identityId != identityId || identityEpoch == 0
                || g.identityEpoch != identityEpoch || g.accountEpoch != accountEpoch || g.validAfter > block.timestamp
                || g.validUntil <= block.timestamp || g.validUntil <= g.validAfter || g.limit == 0 || g.perIntent == 0
                || !supportedTokens[g.token] || revoked[hash]
        ) return false;
        // Custody prevents transfers that bypass the local epoch; registry upgrades remain an external trust gate.
        try IERC721(identityRegistry).ownerOf(identityId) returns (address holder) {
            return holder == address(this);
        } catch {
            return false;
        }
    }

    /// @dev V1 deliberately enables only Arc-source / Arc-or-Ethereum destination, from Circle's published registry.
    function _canonicalToken(Asset asset, uint32 domain) private view returns (address) {
        bool testnet = block.chainid == 5042002;
        if (domain == 26) {
            if (asset == Asset.USDC) return address(0x3600000000000000000000000000000000000000);
            if (asset == Asset.EURC) {
                return testnet
                    ? address(0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a)
                    : address(0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1);
            }
            return testnet
                ? address(0xf0C4a4CE82A5746AbAAd9425360Ab04fbBA432BF)
                : address(0x171A4217b86A807A64eB94757Db6849fb4bDbAA0);
        }
        if (domain == 0) {
            if (asset == Asset.USDC) {
                return testnet
                    ? address(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238)
                    : address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
            }
            if (asset == Asset.EURC) {
                return testnet
                    ? address(0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4)
                    : address(0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c);
            }
            return testnet
                ? address(0x3a3fe695F684Bf9b9e43CF43C2b895Ea5e392bB3)
                : address(0x72DFB2E44f59C5AD2bAFE84314E5b99a7cd5075E);
        }
        return address(0);
    }

    function _supportedDomain(Asset, uint32 domain) private pure returns (bool) {
        return domain == 0 || domain == 26;
    }
}
