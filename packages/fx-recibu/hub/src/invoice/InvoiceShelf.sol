// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBUFIIdentityRegistry} from "../interfaces/IBUFIIdentityRegistry.sol";
import {IBUFIReputationRegistry} from "../interfaces/IBUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../credit/WorkspaceTierRegistry.sol";
import {BINV} from "./BINV.sol";
import {BIFTranche} from "./BIFTranche.sol";
import {WorkspaceOperatingReserve} from "../rails/WorkspaceOperatingReserve.sol";
import {Params} from "../libraries/Params.sol";
import {ReceivableCommitment} from "../libraries/ReceivableCommitment.sol";
import {FactoringEvidenceV1} from "../libraries/FactoringEvidenceV1.sol";

/// @dev Minimal view into ReceivableEscrow so markDefaulted can detect an unsettled
///      debtor payment (deposited via RecibuMemoRouter.pay) before writing off the
///      receivable. Full escrow behaviour lives in src/rails/MultiTokenReceivableEscrow.sol.
interface IReceivableEscrowView {
    function escrowedOf(uint256 invoiceId) external view returns (uint256);
    function tokenOf(uint256 invoiceId) external view returns (address);
}

/// @title InvoiceShelf — the single custodian of locked invoices (M3, Tinlake-Shelf-inspired design lineage; no AGPL code)
///
///  lockInvoice (SERVICER attests docs)                         apply memo inflow
///        │ caps: L(w) · debtor-concentration · velocity              │
///        ▼                                                           ▼
///  mint bINV ─▶ advance = face×rate − holdback ─▶ installments ─▶ applyPayment
///        │            (USDC out of tranche liquidity)                │ on-time → reputation++
///        │                                                           │ (the ONLY L(w) raiser)
///        ▼                                                           ▼
///  markDefaulted (past grace) ──▶ §4.8 waterfall: holdback → [reserve → recourse M4] → C → B → A
///        └─ workspace freeze (lifts on non-fraud resolution after full loss recovery; permanent on fraud)
///
/// FRAUD-CONTAINMENT INVARIANTS (test/invariant/ShelfInvariants.t.sol):
///   I1 atRiskExposure(w) ≤ L(w)                      (SPEC §3.5/§4.9)
///   I2 loss allocation strictly C→B→A                (SPEC §4.8 layers 4–6)
///   I3 Σ trancheAssets + holdbacks ≤ USDC under management (no NAV inflation)
contract InvoiceShelf is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant SERVICER_ROLE = keccak256("SERVICER_ROLE");
    bytes32 public constant OPS_ROLE = keccak256("OPS_ROLE");
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    /// @dev Midnight path: the BUFI advance router / repay adapter / keeper that binds and
    ///      reports Morpho Midnight positions. Never granted to an EOA on mainnet.
    bytes32 public constant ADVANCE_ROLE = keccak256("ADVANCE_ROLE");

    uint8 internal constant TRANCHE_COUNT = 3;
    uint256 internal constant USDC_TO_SHARE_SCALE = 1e12;

    /// @notice Midnight path (mainnet hub): the shelf is a RECEIVABLE REGISTRY only. LP capital,
    ///         loss and liquidation live in Morpho Midnight; tranches are off, no cash moves
    ///         through the shelf, and `USDC` is only the receivable's denomination (any token).
    bool public immutable MIDNIGHT_MODE;

    /// @dev One open Midnight advance per receivable (invoiceId <-> (account, marketId) 1:1).
    struct Advance {
        address account; // borrower CreditAccount (Midnight position owner)
        bytes32 marketId; // Morpho Midnight market id
        uint64 maturity; // market maturity
        uint128 units; // debt units sold at origination
        uint128 repaidUnits; // debt units reported repaid / liquidated
    }

    mapping(uint256 invoiceId => Advance) public advanceOf;

    /// @notice Cross-chain settlement buffer (Safe-settable). A CCTP repayment from a spoke
    ///         (Avalanche) is NOT atomic: while it is in flight Midnight still sees the debt
    ///         open. Nothing is late/defaultable on BUFI's side before due + grace + buffer, and
    ///         a bound Midnight market must mature after that point. Midnight's own liquidation
    ///         is LLTV-based and ignores this buffer: it must also be priced into haircut/LTV.
    uint32 public constant DEFAULT_CROSS_CHAIN_BUFFER = 6 hours;
    uint32 public constant MAX_CROSS_CHAIN_BUFFER = 3 days;
    uint32 public crossChainBuffer = DEFAULT_CROSS_CHAIN_BUFFER;

    enum Status {
        None,
        Funded,
        Settled,
        Defaulted
    }

    enum DefaultResolution {
        Unresolved,
        Restructured,
        Fraud
    }

    struct Invoice {
        uint256 sellerAgentId;
        uint256 debtorAgentId;
        uint128 face; // USDC 6-dec
        uint128 advance; // funded to seller at lock
        uint128 outstanding; // advance not yet repaid
        uint128 holdback; // face − advance (notional): the seller's residual, paid by the debtor
        uint128 holdbackCollected; // debtor payments received beyond the advance — CASH held here
        uint64 firstMaturity;
        uint32 interval;
        uint32 grace;
        uint8 nInstallments;
        uint8 paidInstallments;
        uint8 tranche; // 0=A 1=B 2=C — the most-junior eligible tranche funds it
        Status status;
    }

    IERC20 public immutable USDC;
    IBUFIIdentityRegistry public immutable IDENTITY;
    IBUFIReputationRegistry public immutable REPUTATION;
    WorkspaceTierRegistry public immutable TIERS;
    BINV public immutable BINV_TOKEN;
    BIFTranche[3] internal _tranches; // [A, B, C]
    /// @dev M4: seller first-loss capital (waterfall layer 2). Set once post-deploy.
    WorkspaceOperatingReserve public reserve;
    /// @dev M5: the receivable escrow, so markDefaulted can detect an unsettled debtor
    ///      payment sitting in escrow before defaulting. Set once post-deploy.
    IReceivableEscrowView public escrow;

    uint256 public nextInvoiceId = 1;
    mapping(uint256 => Invoice) public invoices;
    mapping(uint256 => uint128) public installmentProgress;
    mapping(uint256 => uint64) public pendingBridgeUntil;
    mapping(bytes32 bridgeNonce => bool) public usedBridgeNonce;

    /// @dev Permanent anti-double-financing indices. Terminal invoice states and bINV
    ///      burns MUST NOT clear these values.
    mapping(bytes32 commitment => uint256 invoiceId) public invoiceIdOfReceivableCommitment;
    mapping(uint256 invoiceId => bytes32 commitment) public receivableCommitmentOf;
    mapping(bytes32 authorityInvoiceId => uint256 invoiceId) public invoiceIdOfAuthorityInvoiceId;
    mapping(uint256 invoiceId => bytes32 authorityInvoiceId) public authorityInvoiceIdOf;
    mapping(uint256 invoiceId => bytes32 canonicalInvoiceCommitmentHash) public canonicalInvoiceCommitmentHashOf;
    mapping(uint256 invoiceId => bytes32 documentBundleHash) public documentBundleHashOf;
    mapping(uint256 invoiceId => FactoringEvidenceV1 evidence) public factoringEvidenceOf;

    /// @dev I1 accounting: per-seller aggregate outstanding + per-(seller,debtor) outstanding
    mapping(uint256 => uint256) public outstandingOf;
    mapping(uint256 => mapping(uint256 => uint256)) public debtorOutstandingOf;
    /// @dev velocity: advances started per epoch (SPEC §3.5)
    mapping(uint256 => mapping(uint256 => uint256)) public advancesInEpoch;
    /// @dev Cross-default gate. May reopen only after every seller default is resolved as
    ///      legitimate distress and all seller unrecovered losses are cured; fraud stays terminal.
    mapping(uint256 => bool) public workspaceFrozen;
    mapping(uint256 invoiceId => DefaultResolution resolution) public defaultResolutionOf;
    mapping(uint256 sellerAgentId => uint256 count) public unresolvedDefaultCountOf;
    mapping(uint256 invoiceId => uint256 amount) public unrecoveredLossOf;
    mapping(uint256 sellerAgentId => uint256 amount) public sellerUnrecoveredLossOf;
    uint256 public totalUnrecoveredLoss;

    /// @dev SHARED-POOL tranche model (SPEC §6.2). Tranches are risk layers over one pool;
    ///      cash is fungible for funding, but LOSSES fill junior→senior (C→B→A).
    ///        NAV(T) = trancheDeposits[T] − trancheLoss[T]     (accrued/reserveCredit = future)
    ///      Pool identity: totalLiquid + totalPrincipal == Σ deposits − Σ loss.
    uint256 public totalLiquid; // shared fundable cash (LP capital, undeployed)
    uint256 public totalPrincipal; // shared outstanding advances (deployed, expected back)
    uint256[3] public tranchePrincipal; // principal reserved against the tranche selected at origination
    uint256[3] public trancheDeposits; // live LP gross basis per tranche (assets + loss claim)
    uint256[3] public trancheLoss; // realized loss still borne by live shares (C fills first)
    uint256 public totalHoldbackHeld; // collected holdback cash owed to sellers (liability, not tranche capital)
    /// @dev residual holdback of a settled/defaulted invoice whose workspace is frozen — custodied,
    ///      pending M4 recourse netting (part of totalHoldbackHeld; per-workspace slice)
    mapping(uint256 => uint256) public frozenHoldbackOf;

    event InvoiceLocked(
        uint256 indexed invoiceId,
        uint256 indexed sellerAgentId,
        uint256 indexed debtorAgentId,
        uint128 face,
        uint128 advance,
        uint8 tranche
    );
    event ReceivableCommitmentConsumed(
        bytes32 indexed commitment, uint256 indexed invoiceId, bytes32 indexed documentBundleHash
    );
    event AuthorityInvoiceIdConsumed(bytes32 indexed authorityInvoiceId, uint256 indexed invoiceId);
    event FactoringEvidenceBound(
        uint256 indexed invoiceId,
        bytes32 indexed featureRootHash,
        bytes32 indexed currentSnapshotHash,
        bytes32 privateTermsHash
    );
    event InstallmentPaymentApplied(
        uint256 indexed invoiceId,
        uint8 indexed index,
        uint256 amount,
        uint256 cumulativeProgress,
        uint256 installmentAmount
    );
    event InstallmentPaid(uint256 indexed invoiceId, uint8 index, uint256 amount, bool creditedOnTime);
    event CrossChainRepaymentNotified(uint256 indexed invoiceId, bytes32 indexed bridgeNonce, uint64 pendingUntil);
    event InvoiceSettled(uint256 indexed invoiceId, uint256 holdbackReleased, uint256 holdbackContested);
    event InvoiceDefaulted(uint256 indexed invoiceId, uint256 lossAfterHoldback);
    event LossAllocated(uint8 indexed tranche, uint256 amount);
    event TrancheDeposit(uint8 indexed tranche, address indexed lp, uint256 assets, uint256 shares);
    event TrancheRedemption(uint8 indexed tranche, address indexed lp, uint256 assets, uint256 shares);
    event ReserveSurplusWithdrawn(uint256 indexed agentId, address indexed owner, uint256 amount);
    event WorkspaceFrozen(uint256 indexed agentId);
    event DefaultResolved(uint256 indexed invoiceId, bool fraud);
    event ContestedHoldbackRecovered(
        uint256 indexed invoiceId, uint256 indexed sellerAgentId, uint256 applied, uint256 retainedExcess
    );
    event LossRecovered(
        uint256 indexed invoiceId, uint256 indexed sellerAgentId, uint8 indexed tranche, uint256 amount, address source
    );

    // ── Midnight accounting (plan §4.4 / §11.B): marketId is the Midnight bytes32 id,
    //    `units` are Midnight debt units (1 unit = 1 loan token at maturity). ──
    event AdvanceOriginated(
        uint256 indexed invoiceId,
        address indexed account,
        bytes32 indexed marketId,
        uint256 units,
        uint256 assetsOut,
        uint64 maturity,
        uint16 haircutBps,
        bytes32 scoreHash
    );
    event AdvanceRepaid(
        uint256 indexed invoiceId, address indexed account, bytes32 indexed marketId, uint256 units, bytes32 memoId
    );
    event AdvanceLiquidated(
        uint256 indexed invoiceId,
        address indexed account,
        bytes32 indexed marketId,
        uint256 repaidUnits,
        uint256 seizedAssets,
        address collateralToken,
        uint256 badDebt
    );
    event CrossChainBufferSet(uint32 previous, uint32 current);
    /// @notice hub side of a spoke repayment: CCTP mint observed and applied (pairs with the
    ///         spoke's MemoConduit RepaymentInitiated; accounting clears "pending in flight").
    event RepaymentSettled(
        uint256 indexed invoiceId,
        bytes32 indexed marketId,
        bytes32 indexed messageHash,
        uint32 sourceDomain,
        uint256 amount,
        uint256 units,
        bytes32 memoId
    );
    event AdvanceRolledToBlue(uint256 indexed invoiceId, address indexed account, bytes32 indexed blueMarketId);

    error NotEligible(uint256 agentId);
    error Frozen(uint256 agentId);
    error ExposureCapExceeded(uint256 agentId, uint256 requested, uint256 headroom);
    error ConcentrationCapExceeded(uint256 debtorAgentId);
    error SelfDealingReceivable(uint256 agentId);
    error VelocityCapExceeded(uint256 agentId);
    error BadSchedule();
    error BadStatus(uint256 invoiceId);
    error UnknownInvoice(uint256 invoiceId);
    error BadInstallmentIndex(uint256 invoiceId, uint8 index);
    error NoCurrentInstallment(uint256 invoiceId, Status status);
    error InsufficientTrancheLiquidity(uint8 tranche);
    error NotPastGrace();
    error ZeroAddress();
    error ZeroAmount();
    error ReserveAlreadySet();
    error EscrowAlreadySet();
    error EscrowPendingSettlement(uint256 invoiceId);
    error BondNotPosted(uint256 required, uint256 posted);
    error IncompleteReceivableIdentity();
    error IncompleteDocumentBundle();
    error InvalidIssueDate(uint64 issuedAt, uint256 currentTimestamp);
    error InvalidDueDate(uint64 issuedAt, uint64 dueAt);
    error ScheduleDueOutOfRange(uint256 expectedDueAt);
    error ScheduleDueMismatch(uint64 providedDueAt, uint64 expectedDueAt);
    error ReceivableAlreadyConsumed(bytes32 commitment, uint256 originalInvoiceId);
    error AuthorityInvoiceAlreadyConsumed(bytes32 authorityInvoiceId, uint256 originalInvoiceId);
    error IncompleteFactoringEvidence();
    error TranchesDisabled();
    error MidnightOnly();
    error AdvanceAlreadyBound(uint256 invoiceId);
    error AdvanceNotBound(uint256 invoiceId);
    error BadAdvance();
    error MaturityBeforeDue(uint64 maturity, uint256 dueWithGrace);
    error UnitsExceedOpen(uint256 units, uint256 open);
    error BufferTooLarge(uint32 buffer);
    error Overpayment(uint256 amount, uint256 remainingFace);
    error MidnightDirectPaymentDisabled();
    error UnauthorizedPayer(address payer);
    error InstallmentAccountingMismatch(
        uint256 invoiceId, uint8 paidInstallments, uint8 expectedInstallments, uint256 progress
    );
    error CrossChainRepaymentInFlight(uint256 invoiceId, uint64 pendingUntil);
    error BridgeNonceAlreadyUsed(bytes32 bridgeNonce);
    error DefaultAlreadyResolved(uint256 invoiceId);
    error InvalidTranche(uint8 tranche);
    error InsolventTranche(uint8 tranche);
    error RedemptionRoundsToZero();
    error InsufficientTrancheShares(uint256 requested, uint256 available);
    error InsufficientRedemptionLiquidity(uint256 requested, uint256 available);
    error PoolNotIdle(uint256 principal, uint256 bookedLoss);
    error PoolHasUnresolvedLoss(uint256 bookedLoss, uint256 unrecoveredLoss);
    error RecoveryExceedsUnrecoveredLoss(uint256 requested, uint256 available);
    error LossAccountingMismatch(uint256 requested, uint256 applied);
    error ReserveNotSet();
    error NotWorkspaceOwner(uint256 agentId, address caller);
    error OutstandingExposure(uint256 agentId, uint256 outstanding);
    error ReserveFloorActive(uint256 agentId, uint256 required);

    constructor(
        IERC20 usdc,
        IBUFIIdentityRegistry identity_,
        IBUFIReputationRegistry reputation_,
        WorkspaceTierRegistry tiers_,
        address admin,
        bool midnightMode
    ) {
        if (
            address(usdc) == address(0) || address(identity_) == address(0) || address(reputation_) == address(0)
                || address(tiers_) == address(0) || admin == address(0)
        ) revert ZeroAddress();
        MIDNIGHT_MODE = midnightMode;
        USDC = usdc;
        IDENTITY = identity_;
        REPUTATION = reputation_;
        TIERS = tiers_;
        BINV_TOKEN = new BINV(address(this));
        if (!midnightMode) {
            _tranches[0] = new BIFTranche("BUFI Invoice Senior", "bIF-A", address(this));
            _tranches[1] = new BIFTranche("BUFI Invoice Mezzanine", "bIF-B", address(this));
            _tranches[2] = new BIFTranche("BUFI Invoice Junior", "bIF-C", address(this));
        }
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice one-time wiring of the seller first-loss reserve (M4)
    function setReserve(WorkspaceOperatingReserve reserve_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(reserve_) == address(0)) revert ZeroAddress();
        if (address(reserve) != address(0)) revert ReserveAlreadySet();
        reserve = reserve_;
    }

    /// @notice one-time wiring of the receivable escrow (M5). Lets markDefaulted see an
    ///         unsettled debtor payment before writing off the receivable.
    function setEscrow(address escrow_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (escrow_ == address(0)) revert ZeroAddress();
        if (address(escrow) != address(0)) revert EscrowAlreadySet();
        escrow = IReceivableEscrowView(escrow_);
    }

    function tranches(uint8 tranche) external view returns (BIFTranche) {
        _requireValidTranche(tranche);
        return _tranches[tranche];
    }

    // ── LP side (M3: deposits/redemptions at live NAV) ──

    function depositTranche(uint8 tranche, uint256 assets) external nonReentrant returns (uint256 shares) {
        _requireNotMidnight();
        _requireValidTranche(tranche);
        _requireNonZero(assets);
        uint256 bookedLoss = _totalBookedLoss();
        if (bookedLoss != 0 || totalUnrecoveredLoss != 0) {
            revert PoolHasUnresolvedLoss(bookedLoss, totalUnrecoveredLoss);
        }

        BIFTranche trancheToken = _tranches[tranche];
        uint256 supply = trancheToken.totalSupply();
        if (supply == 0) {
            shares = assets * USDC_TO_SHARE_SCALE;
        } else {
            uint256 nav = trancheAssets(tranche);
            if (nav == 0) revert InsolventTranche(tranche);
            shares = Math.mulDiv(assets, supply, nav);
            _requireNonZero(shares);
        }

        _transferIn(msg.sender, assets);
        totalLiquid += assets;
        trancheDeposits[tranche] += assets;
        trancheToken.mint(msg.sender, shares);
        emit TrancheDeposit(tranche, msg.sender, assets, shares);
    }

    /// @notice Burn tranche shares and return their proportional NAV from an idle, lossless pool.
    function redeemTranche(uint8 tranche, uint256 shares) external nonReentrant returns (uint256 assets) {
        _requireNotMidnight();
        _requireValidTranche(tranche);
        _requireNonZero(shares);
        uint256 bookedLoss = _totalBookedLoss();
        if (totalPrincipal != 0 || bookedLoss != 0) revert PoolNotIdle(totalPrincipal, bookedLoss);

        BIFTranche trancheToken = _tranches[tranche];
        uint256 balance = trancheToken.balanceOf(msg.sender);
        if (shares > balance) revert InsufficientTrancheShares(shares, balance);

        assets = Math.mulDiv(shares, trancheDeposits[tranche], trancheToken.totalSupply());
        if (assets == 0) revert RedemptionRoundsToZero();
        if (totalLiquid < assets) revert InsufficientRedemptionLiquidity(assets, totalLiquid);

        trancheDeposits[tranche] -= assets;
        totalLiquid -= assets;
        trancheToken.burn(msg.sender, shares);
        _transferOut(msg.sender, assets);
        emit TrancheRedemption(tranche, msg.sender, assets, shares);
    }

    /// @notice Return a workspace's idle operating reserve to its current identity owner.
    function withdrawReserveSurplus(uint256 agentId, uint256 amount) external nonReentrant {
        WorkspaceOperatingReserve reserve_ = reserve;
        if (address(reserve_) == address(0)) revert ReserveNotSet();
        _requireNonZero(amount);

        address owner = IDENTITY.ownerOf(agentId);
        if (msg.sender != owner) revert NotWorkspaceOwner(agentId, msg.sender);
        uint256 outstanding = outstandingOf[agentId];
        if (outstanding != 0) revert OutstandingExposure(agentId, outstanding);
        if (unresolvedDefaultCountOf[agentId] != 0 || sellerUnrecoveredLossOf[agentId] != 0) {
            revert Frozen(agentId);
        }
        uint256 required = reserve_.requiredOf(agentId);
        if (required != 0) revert ReserveFloorActive(agentId, required);

        reserve_.withdrawSurplus(agentId, owner, amount);
        emit ReserveSurplusWithdrawn(agentId, owner, amount);
    }

    // ── Lock (SPEC §3) ──────────────────────────────────────────────────

    function lockInvoice(
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        uint128 face,
        uint8 nInstallments,
        uint64 firstMaturity,
        uint32 interval,
        ReceivableCommitment.Terms calldata terms,
        FactoringEvidenceV1 calldata evidence,
        BINV.DocBundle calldata docs
    ) external onlyRole(SERVICER_ROLE) nonReentrant returns (uint256 invoiceId) {
        if (sellerAgentId == debtorAgentId) revert SelfDealingReceivable(sellerAgentId);
        // v2v hard gate: KYB'd + not defaulted, both sides (SPEC §1)
        if (!TIERS.eligible(sellerAgentId)) revert NotEligible(sellerAgentId);
        if (!TIERS.eligible(debtorAgentId)) revert NotEligible(debtorAgentId);
        address sellerOwner = IDENTITY.ownerOf(sellerAgentId);
        if (sellerOwner == IDENTITY.ownerOf(debtorAgentId)) {
            revert SelfDealingReceivable(sellerAgentId);
        }
        if (workspaceFrozen[sellerAgentId]) revert Frozen(sellerAgentId);
        if (
            nInstallments < Params.MIN_INSTALLMENTS || nInstallments > Params.MAX_INSTALLMENTS
                || interval < Params.MIN_INSTALLMENT_INTERVAL || firstMaturity <= block.timestamp
                || uint256(face) < nInstallments
        ) revert BadSchedule();
        if (terms.canonicalInvoiceCommitmentHash == bytes32(0)) revert IncompleteReceivableIdentity();
        if (
            docs.invoiceDocHash == bytes32(0) || docs.assignmentHash == bytes32(0)
                || docs.paymentInstructionHash == bytes32(0) || docs.servicingPolicyHash == bytes32(0)
                || docs.disputePolicyHash == bytes32(0)
        ) revert IncompleteDocumentBundle();
        if (
            evidence.featureRootHash == bytes32(0) || evidence.currentSnapshotHash == bytes32(0)
                || evidence.privateTermsHash == bytes32(0)
        ) revert IncompleteFactoringEvidence();
        if (terms.issuedAt == 0 || terms.issuedAt > block.timestamp) {
            revert InvalidIssueDate(terms.issuedAt, block.timestamp);
        }
        if (terms.dueAt <= terms.issuedAt) revert InvalidDueDate(terms.issuedAt, terms.dueAt);

        uint256 expectedDueAtValue = uint256(firstMaturity) + uint256(nInstallments - 1) * uint256(interval);
        if (expectedDueAtValue > type(uint64).max) revert ScheduleDueOutOfRange(expectedDueAtValue);
        uint64 expectedDueAt = uint64(expectedDueAtValue);
        if (terms.dueAt != expectedDueAt) revert ScheduleDueMismatch(terms.dueAt, expectedDueAt);

        bytes32 commitment = ReceivableCommitment.compute(
            block.chainid, sellerAgentId, debtorAgentId, address(USDC), face, terms, docs.assignmentHash
        );
        bytes32 authorityInvoiceId = ReceivableCommitment.authorityInvoiceId(terms.canonicalInvoiceCommitmentHash);
        uint256 originalInvoiceId = invoiceIdOfReceivableCommitment[commitment];
        if (originalInvoiceId != 0) revert ReceivableAlreadyConsumed(commitment, originalInvoiceId);
        originalInvoiceId = invoiceIdOfAuthorityInvoiceId[authorityInvoiceId];
        if (originalInvoiceId != 0) {
            revert AuthorityInvoiceAlreadyConsumed(authorityInvoiceId, originalInvoiceId);
        }

        bool pair = TIERS.hasPairHistory(sellerAgentId, debtorAgentId);
        uint8 sellerScore = REPUTATION.scoreOf(sellerAgentId).sellerScore;
        uint8 debtorScore = REPUTATION.scoreOf(debtorAgentId).debtorScore;

        uint128 advance = uint128((uint256(face) * TIERS.advanceRateBps(debtorScore, pair)) / Params.BPS);

        // I1 — the fraud ramp (SPEC §3.5)
        uint256 limit = TIERS.limitOf(sellerAgentId);
        uint256 current = outstandingOf[sellerAgentId];
        uint256 nextOutstanding = current + advance;
        if (nextOutstanding > limit) revert ExposureCapExceeded(sellerAgentId, advance, limit - current);
        // debtor concentration
        uint256 debtorCap = TIERS.debtorConcentrationCap(sellerAgentId);
        if (debtorOutstandingOf[sellerAgentId][debtorAgentId] + advance > debtorCap) {
            revert ConcentrationCapExceeded(debtorAgentId);
        }
        // velocity
        uint256 epoch = block.timestamp / Params.EPOCH_LENGTH;
        if (advancesInEpoch[sellerAgentId][epoch] >= Params.MAX_ADVANCES_PER_EPOCH) {
            revert VelocityCapExceeded(sellerAgentId);
        }
        advancesInEpoch[sellerAgentId][epoch] += 1;

        // bond gate (SPEC §3.2): weak-tier sellers must have POSTED first-loss capital
        // covering bondShare × reserveRatio × new outstanding, before funds move.
        if (address(reserve) != address(0)) {
            uint16 bondShare = TIERS.bondShareBps(sellerScore);
            uint256 requiredFloor =
                (nextOutstanding * TIERS.reserveRatioBps(sellerScore) / Params.BPS) * bondShare / Params.BPS;
            uint256 posted = reserve.balanceOf(sellerAgentId);
            if (bondShare > 0 && posted < requiredFloor) {
                revert BondNotPosted(requiredFloor, posted);
            }
            reserve.setRequired(sellerAgentId, requiredFloor);
        }

        uint8 tranche = uint8(TIERS.trancheEligibility(sellerScore, debtorScore, pair));
        if (!MIDNIGHT_MODE && (totalLiquid < advance || trancheCapacity(tranche) < advance)) {
            revert InsufficientTrancheLiquidity(tranche);
        }

        invoiceId = nextInvoiceId++;
        bytes32 documentBundleHash = ReceivableCommitment.hashDocumentBundle(docs);
        invoiceIdOfReceivableCommitment[commitment] = invoiceId;
        receivableCommitmentOf[invoiceId] = commitment;
        invoiceIdOfAuthorityInvoiceId[authorityInvoiceId] = invoiceId;
        authorityInvoiceIdOf[invoiceId] = authorityInvoiceId;
        canonicalInvoiceCommitmentHashOf[invoiceId] = terms.canonicalInvoiceCommitmentHash;
        documentBundleHashOf[invoiceId] = documentBundleHash;
        factoringEvidenceOf[invoiceId] = evidence;
        uint32 grace = TIERS.tierOf(sellerScore) >= WorkspaceTierRegistry.Tier.Strong
            ? Params.GRACE_STRONG
            : Params.GRACE_WEAK;
        Invoice storage inv = invoices[invoiceId];
        inv.sellerAgentId = sellerAgentId;
        inv.debtorAgentId = debtorAgentId;
        inv.face = face;
        inv.advance = advance;
        inv.outstanding = advance;
        inv.holdback = face - advance;
        inv.firstMaturity = firstMaturity;
        inv.interval = interval;
        inv.grace = grace;
        inv.nInstallments = nInstallments;
        inv.tranche = tranche;
        inv.status = Status.Funded;

        outstandingOf[sellerAgentId] = nextOutstanding;
        debtorOutstandingOf[sellerAgentId][debtorAgentId] += advance;
        BINV_TOKEN.mint(sellerOwner, invoiceId, docs);
        if (!MIDNIGHT_MODE) {
            totalLiquid -= advance;
            totalPrincipal += advance;
            tranchePrincipal[tranche] += advance;
            _transferOut(sellerOwner, advance);
        }
        emit ReceivableCommitmentConsumed(commitment, invoiceId, documentBundleHash);
        emit AuthorityInvoiceIdConsumed(authorityInvoiceId, invoiceId);
        emit FactoringEvidenceBound(
            invoiceId, evidence.featureRootHash, evidence.currentSnapshotHash, evidence.privateTermsHash
        );
        emit InvoiceLocked(invoiceId, sellerAgentId, debtorAgentId, face, advance, tranche);
    }

    // ── Repayment (SPEC §3.6 — earliest open installment; M5 wires the Memo router in front) ──

    /// @notice apply a debtor payment (servicer relays directly; pays from own balance).
    function applyPayment(uint256 invoiceId, uint256 amount) external onlyRole(SERVICER_ROLE) nonReentrant {
        if (MIDNIGHT_MODE) revert MidnightDirectPaymentDisabled();
        _applyPayment(invoiceId, amount, msg.sender);
    }

    /// @notice M5: the settlement orchestrator applies an escrowed inflow on the debtor's
    ///         behalf. In Midnight mode `payer` must be the canonical escrow; in non-Midnight
    ///         mode `payer` must be `msg.sender` so settlement cannot pull arbitrary approvals.
    function applyPaymentFrom(uint256 invoiceId, uint256 amount, address payer)
        external
        onlyRole(SETTLEMENT_ROLE)
        nonReentrant
    {
        if (MIDNIGHT_MODE) {
            if (address(escrow) == address(0) || payer != address(escrow)) revert MidnightDirectPaymentDisabled();
        } else {
            if (payer != msg.sender) revert UnauthorizedPayer(payer);
        }
        _applyPayment(invoiceId, amount, payer);
    }

    /// @notice Record that a spoke CCTP repayment burn was observed for `invoiceId`,
    ///         holding default eligibility open for `crossChainBuffer`.
    function notifyCrossChainRepayment(uint256 invoiceId, bytes32 bridgeNonce) external onlyRole(SERVICER_ROLE) {
        _requireStatus(invoiceId, Status.Funded);
        if (bridgeNonce == bytes32(0)) revert BadAdvance();
        if (usedBridgeNonce[bridgeNonce]) revert BridgeNonceAlreadyUsed(bridgeNonce);
        usedBridgeNonce[bridgeNonce] = true;
        uint64 pendingUntil = uint64(block.timestamp + crossChainBuffer);
        uint64 currentPending = pendingBridgeUntil[invoiceId];
        if (pendingUntil > currentPending) {
            pendingBridgeUntil[invoiceId] = pendingUntil;
            currentPending = pendingUntil;
        }
        emit CrossChainRepaymentNotified(invoiceId, bridgeNonce, currentPending);
    }

    function _applyPayment(uint256 invoiceId, uint256 amount, address payer) internal {
        Invoice storage inv = _requireStatus(invoiceId, Status.Funded);
        _requireNonZero(amount);
        // Midnight path: record-only (cash goes escrow -> Midnight repay, never the shelf)
        if (!MIDNIGHT_MODE) _transferIn(payer, amount);

        // split: tranche recovery first (outstanding), then the seller's holdback slice.
        // anything beyond face is rejected — the debtor owes face, no more.
        uint128 out = inv.outstanding;
        uint128 hbCol = inv.holdbackCollected;
        uint256 remainingFace = uint256(out) + uint256(inv.holdback - hbCol);
        if (amount > remainingFace) revert Overpayment(amount, remainingFace);
        uint128 toOutstanding = amount >= out ? out : uint128(amount);
        uint128 remainder = uint128(amount) - toOutstanding;

        out -= toOutstanding;
        hbCol += remainder;
        inv.outstanding = out;
        inv.holdbackCollected = hbCol;
        if (toOutstanding > 0) {
            _reduceExposure(inv, toOutstanding);
            if (!MIDNIGHT_MODE) {
                totalPrincipal -= toOutstanding; // receivable repaid → back to fundable cash
                totalLiquid += toOutstanding;
            }
        }
        if (remainder > 0 && !MIDNIGHT_MODE) totalHoldbackHeld += remainder; // seller's cash, held as liability

        _creditInstallments(invoiceId, inv, amount);
        _clearPendingBridgeIfCurrent(invoiceId, inv, false);

        if (out == 0 && hbCol == inv.holdback) {
            if (inv.paidInstallments != inv.nInstallments || installmentProgress[invoiceId] != 0) {
                revert InstallmentAccountingMismatch(
                    invoiceId, inv.paidInstallments, inv.nInstallments, installmentProgress[invoiceId]
                );
            }
            _settle(invoiceId, inv);
        }
    }

    function _installmentAmount(Invoice storage inv, uint8 index) internal view returns (uint256) {
        uint256 base = uint256(inv.face) / inv.nInstallments;
        if (index + 1 < inv.nInstallments) return base;
        return base + (uint256(inv.face) % inv.nInstallments);
    }

    function _creditInstallments(uint256 invoiceId, Invoice storage inv, uint256 amount) internal {
        uint256 remaining = amount;
        while (remaining > 0) {
            uint8 index = inv.paidInstallments;
            if (index >= inv.nInstallments) {
                revert InstallmentAccountingMismatch(
                    invoiceId, inv.paidInstallments, inv.nInstallments, installmentProgress[invoiceId]
                );
            }

            uint256 fullAmount = _installmentAmount(inv, index);
            uint256 progress = installmentProgress[invoiceId];
            uint256 openAmount = fullAmount - progress;
            uint256 applied = remaining < openAmount ? remaining : openAmount;
            uint256 cumulative = progress + applied;

            installmentProgress[invoiceId] = uint128(cumulative);
            emit InstallmentPaymentApplied(invoiceId, index, applied, cumulative, fullAmount);
            remaining -= applied;

            if (cumulative == fullAmount) {
                installmentProgress[invoiceId] = 0;
                inv.paidInstallments = index + 1;
                uint256 due = installmentDue(invoiceId, index);
                bool creditedOnTime = false;
                if (
                    block.timestamp >= due && block.timestamp <= lateAfter(invoiceId, due)
                        && !REPUTATION.permanentDefault(inv.sellerAgentId)
                ) {
                    creditedOnTime = REPUTATION.recordOnTimeInstallment(inv.sellerAgentId, fullAmount);
                }
                emit InstallmentPaid(invoiceId, index, fullAmount, creditedOnTime);
            }
        }
    }

    /// @notice flip a missed invoice (earliest open installment past grace) into default
    ///         and run the M3 waterfall slice: holdback first, reserve second, then C→B→A.
    function markDefaulted(uint256 invoiceId) external onlyRole(SERVICER_ROLE) nonReentrant {
        Invoice storage inv = _requireStatus(invoiceId, Status.Funded);
        uint256 due = installmentDue(invoiceId, inv.paidInstallments);
        uint256 lateBoundary = lateAfter(invoiceId, due);
        if (block.timestamp <= lateBoundary) revert NotPastGrace();
        if (block.timestamp <= pendingBridgeUntil[invoiceId]) {
            revert CrossChainRepaymentInFlight(invoiceId, pendingBridgeUntil[invoiceId]);
        }

        if (address(escrow) != address(0)) {
            uint256 escrowed = escrow.escrowedOf(invoiceId);
            if (escrowed > 0) {
                bool pending = escrow.tokenOf(invoiceId) == address(USDC)
                    ? escrowed >= (_installmentAmount(inv, inv.paidInstallments) - installmentProgress[invoiceId])
                    : block.timestamp <= lateBoundary + crossChainBuffer;
                if (pending) revert EscrowPendingSettlement(invoiceId);
            }
        }

        inv.status = Status.Defaulted;
        delete pendingBridgeUntil[invoiceId];
        uint256 sellerId = inv.sellerAgentId;
        uint128 outstanding = inv.outstanding;
        inv.outstanding = 0;
        _reduceExposure(inv, outstanding);

        BINV_TOKEN.burn(invoiceId);
        workspaceFrozen[sellerId] = true;
        unresolvedDefaultCountOf[sellerId] += 1;

        if (MIDNIGHT_MODE) {
            // loss is realized in Midnight (liquidation / lossFactor), not here
            emit WorkspaceFrozen(sellerId);
            emit InvoiceDefaulted(invoiceId, outstanding);
            return;
        }

        // the receivable is written off the pool; recovery below returns real cash to it
        totalPrincipal -= outstanding;

        // §4.8 layer 1: the UNRELEASED holdback cash this invoice collected absorbs first
        uint128 hbCol = inv.holdbackCollected;
        uint128 fromHoldback = outstanding < hbCol ? outstanding : hbCol;
        uint128 contestedRemainder = hbCol - fromHoldback;
        inv.holdbackCollected = 0;
        if (fromHoldback > 0) {
            totalHoldbackHeld -= fromHoldback;
            totalLiquid += fromHoldback;
        }
        if (contestedRemainder > 0) {
            frozenHoldbackOf[sellerId] += contestedRemainder;
        }
        uint256 loss = outstanding - fromHoldback;

        // §4.8 layer 2: the SELLER's posted reserve burns before any LP tranche
        if (loss > 0 && address(reserve) != address(0)) {
            uint256 covered = reserve.sweepFor(sellerId, loss);
            totalLiquid += covered; // reserve cash enters the pool
            loss -= covered;
        }

        // layers 4–6: allocate the residual loss C → B → A over each tranche's capacity
        if (loss > 0) {
            unrecoveredLossOf[invoiceId] = loss;
            sellerUnrecoveredLossOf[sellerId] += loss;
            totalUnrecoveredLoss += loss;
            _allocateLoss(loss);
        }

        emit WorkspaceFrozen(sellerId);
        emit InvoiceDefaulted(invoiceId, loss);
    }

    /// @notice M4 resolution (ops multisig): the PERMANENT_DEFAULT vs RESTRUCTURED split.
    /// @dev Resolution classifies the event; it does not forgive an LP loss. Frozen
    ///      recourse cash is first netted against the invoice's unrecovered balance on
    ///      either path. A legitimate seller reopens only after every default is resolved
    ///      and every dollar of seller loss has been recovered.
    function resolveDefault(uint256 invoiceId, bool fraud) external onlyRole(OPS_ROLE) nonReentrant {
        Invoice storage inv = _requireStatus(invoiceId, Status.Defaulted);
        if (defaultResolutionOf[invoiceId] != DefaultResolution.Unresolved) {
            revert DefaultAlreadyResolved(invoiceId);
        }

        uint256 sellerAgentId = inv.sellerAgentId;
        unresolvedDefaultCountOf[sellerAgentId] -= 1;
        defaultResolutionOf[invoiceId] = fraud ? DefaultResolution.Fraud : DefaultResolution.Restructured;

        if (fraud) {
            REPUTATION.setPermanentDefault(sellerAgentId);
        } else {
            if (!REPUTATION.permanentDefault(sellerAgentId)) {
                REPUTATION.markRestructured(sellerAgentId);
            }
        }

        if (!MIDNIGHT_MODE) {
            _netFrozenHoldback(invoiceId, inv);
        }
        _finalizeSellerResolution(sellerAgentId);
        emit DefaultResolved(invoiceId, fraud);
    }

    /// @notice Apply already-custodied seller recourse to a specific default loss.
    function applyFrozenHoldback(uint256 invoiceId) external nonReentrant returns (uint256 applied) {
        _requireNotMidnight();
        Invoice storage inv = _requireStatus(invoiceId, Status.Defaulted);

        applied = _netFrozenHoldback(invoiceId, inv);
        _finalizeSellerResolution(inv.sellerAgentId);
    }

    /// @notice Repay a defaulted invoice with new cash, capped at its unrecovered loss.
    function recoverDefault(uint256 invoiceId, uint256 amount) external nonReentrant {
        _requireNotMidnight();
        Invoice storage inv = _requireStatus(invoiceId, Status.Defaulted);
        _requireNonZero(amount);

        uint256 available = unrecoveredLossOf[invoiceId];
        if (amount > available) revert RecoveryExceedsUnrecoveredLoss(amount, available);

        _transferIn(msg.sender, amount);
        _applyLossRecovery(invoiceId, inv, amount, msg.sender);
        totalLiquid += amount;
        _finalizeSellerResolution(inv.sellerAgentId);
    }

    // ── Midnight binding + accounting (ADVANCE_ROLE: router / repay adapter / keeper) ──

    /// @notice bind a Morpho Midnight advance to a funded receivable. One per invoice.
    ///         The market must mature after the receivable's last due date plus grace.
    function bindAdvance(
        uint256 invoiceId,
        address account,
        bytes32 marketId,
        uint64 maturity,
        uint128 units,
        uint256 assetsOut,
        uint16 haircutBps,
        bytes32 scoreHash
    ) external onlyRole(ADVANCE_ROLE) {
        if (!MIDNIGHT_MODE) revert MidnightOnly();
        _requireStatus(invoiceId, Status.Funded);
        Advance storage a = advanceOf[invoiceId];
        if (a.account != address(0)) revert AdvanceAlreadyBound(invoiceId);
        if (account == address(0) || marketId == bytes32(0) || units == 0) revert BadAdvance();
        uint256 dueWithGrace = lateAfter(invoiceId, dueDate(invoiceId));
        if (maturity < dueWithGrace) revert MaturityBeforeDue(maturity, dueWithGrace);
        a.account = account;
        a.marketId = marketId;
        a.maturity = maturity;
        a.units = units;
        emit AdvanceOriginated(invoiceId, account, marketId, units, assetsOut, maturity, haircutBps, scoreHash);
    }

    function recordAdvanceRepaid(uint256 invoiceId, uint128 units, bytes32 memoId) external onlyRole(ADVANCE_ROLE) {
        Advance storage a = _openAdvance(invoiceId, units);
        a.repaidUnits += units;
        emit AdvanceRepaid(invoiceId, a.account, a.marketId, units, memoId);
    }

    /// @notice a spoke (CCTP) repayment was minted on the hub and applied to Midnight.
    function recordRepaymentSettled(
        uint256 invoiceId,
        uint128 units,
        uint256 amount,
        uint32 sourceDomain,
        bytes32 messageHash,
        bytes32 memoId
    ) external onlyRole(ADVANCE_ROLE) {
        if (messageHash == bytes32(0)) revert BadAdvance();
        Advance storage a = _openAdvance(invoiceId, units);
        a.repaidUnits += units;
        _clearPendingBridgeIfCurrent(invoiceId, invoices[invoiceId], a.repaidUnits == a.units);
        emit RepaymentSettled(invoiceId, a.marketId, messageHash, sourceDomain, amount, units, memoId);
        emit AdvanceRepaid(invoiceId, a.account, a.marketId, units, memoId);
    }

    function setCrossChainBuffer(uint32 buffer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (buffer > MAX_CROSS_CHAIN_BUFFER) revert BufferTooLarge(buffer);
        emit CrossChainBufferSet(crossChainBuffer, buffer);
        crossChainBuffer = buffer;
    }

    function recordAdvanceLiquidated(
        uint256 invoiceId,
        uint128 repaidUnits,
        uint256 seizedAssets,
        address collateralToken,
        uint256 badDebt
    ) external onlyRole(ADVANCE_ROLE) {
        Advance storage a = _openAdvance(invoiceId, repaidUnits);
        a.repaidUnits += repaidUnits;
        emit AdvanceLiquidated(invoiceId, a.account, a.marketId, repaidUnits, seizedAssets, collateralToken, badDebt);
    }

    function recordAdvanceRolledToBlue(uint256 invoiceId, bytes32 blueMarketId) external onlyRole(ADVANCE_ROLE) {
        Advance storage a = advanceOf[invoiceId];
        if (a.account == address(0)) revert AdvanceNotBound(invoiceId);
        emit AdvanceRolledToBlue(invoiceId, a.account, blueMarketId);
    }

    function _openAdvance(uint256 invoiceId, uint128 units) internal view returns (Advance storage a) {
        a = advanceOf[invoiceId];
        if (a.account == address(0)) revert AdvanceNotBound(invoiceId);
        uint256 open = a.units - a.repaidUnits;
        if (units == 0 || units > open) revert UnitsExceedOpen(units, open);
    }

    // ── Views ──────────────────────────────────────────────────────────

    /// @notice the receivable's final installment due date (Midnight maturity selection).
    function dueDate(uint256 invoiceId) public view returns (uint256) {
        Invoice storage inv = invoices[invoiceId];
        return installmentDue(invoiceId, inv.nInstallments == 0 ? 0 : inv.nInstallments - 1);
    }

    /// @notice first instant an installment due at `due` counts as late on BUFI's side:
    ///         due + grace (+ crossChainBuffer on the Midnight path).
    function lateAfter(uint256 invoiceId, uint256 due) public view returns (uint256) {
        return due + invoices[invoiceId].grace + (MIDNIGHT_MODE ? crossChainBuffer : 0);
    }

    function isLate(uint256 invoiceId) external view returns (bool) {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status != Status.Funded) return false;
        return block.timestamp > lateAfter(invoiceId, installmentDue(invoiceId, inv.paidInstallments));
    }

    function graceOf(uint256 invoiceId) external view returns (uint32) {
        return invoices[invoiceId].grace;
    }

    function installmentDue(uint256 invoiceId, uint8 index) public view returns (uint256) {
        Invoice storage inv = invoices[invoiceId];
        return uint256(inv.firstMaturity) + uint256(index) * inv.interval;
    }

    function installmentAmount(uint256 invoiceId, uint8 index) external view returns (uint256) {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status == Status.None) revert UnknownInvoice(invoiceId);
        if (index >= inv.nInstallments) revert BadInstallmentIndex(invoiceId, index);
        return _installmentAmount(inv, index);
    }

    function currentInstallment(uint256 invoiceId)
        external
        view
        returns (uint8 index, uint256 fullAmount, uint256 paidAmount, uint256 maturity, uint256 graceEndsAt)
    {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status != Status.Funded || inv.paidInstallments >= inv.nInstallments) {
            revert NoCurrentInstallment(invoiceId, inv.status);
        }

        index = inv.paidInstallments;
        fullAmount = _installmentAmount(inv, index);
        paidAmount = installmentProgress[invoiceId];
        maturity = installmentDue(invoiceId, index);
        graceEndsAt = lateAfter(invoiceId, maturity);
    }

    function remainingFaceOf(uint256 invoiceId) external view returns (uint256) {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status != Status.Funded) return 0;
        return uint256(inv.outstanding) + uint256(inv.holdback - inv.holdbackCollected);
    }

    /// @notice rail-facing views (IInvoiceShelf)
    function invoiceStatus(uint256 invoiceId) external view returns (Status) {
        return invoices[invoiceId].status;
    }

    function sellerAgentIdOf(uint256 invoiceId) external view returns (uint256) {
        return invoices[invoiceId].sellerAgentId;
    }

    function debtorPayerOf(uint256 invoiceId) external view returns (address) {
        Invoice storage inv = invoices[invoiceId];
        if (inv.status == Status.None) revert UnknownInvoice(invoiceId);
        return IDENTITY.ownerOf(inv.debtorAgentId);
    }

    /// @notice Compute the exact V1 commitment Desk/CRE must submit, without consuming it.
    function computeReceivableCommitment(
        uint256 sellerAgentId,
        uint256 debtorAgentId,
        uint128 face,
        ReceivableCommitment.Terms calldata terms,
        bytes32 assignmentHash
    ) external view returns (bytes32) {
        return ReceivableCommitment.compute(
            block.chainid, sellerAgentId, debtorAgentId, address(USDC), face, terms, assignmentHash
        );
    }

    /// @notice Derive the only authority invoice ID accepted by the shelf's V1 lock path.
    function computeAuthorityInvoiceId(bytes32 canonicalInvoiceCommitmentHash) external pure returns (bytes32) {
        return ReceivableCommitment.authorityInvoiceId(canonicalInvoiceCommitmentHash);
    }

    /// @notice SPEC §6.2 NAV numerator per tranche: contributed capital minus allocated
    ///         loss (accrued yield / reserveCredit are future terms, 0 today). BUFIOracle
    ///         divides this by the tranche's share supply.
    function trancheAssets(uint8 tranche) public view returns (uint256) {
        _requireValidTranche(tranche);
        uint256 dep = trancheDeposits[tranche];
        uint256 loss = trancheLoss[tranche];
        return dep > loss ? dep - loss : 0;
    }

    /// @notice Net origination capacity in a tranche (NAV minus already selected principal).
    function trancheCapacity(uint8 tranche) public view returns (uint256) {
        uint256 assets = trancheAssets(tranche);
        uint256 principal = tranchePrincipal[tranche];
        return assets > principal ? assets - principal : 0;
    }

    // ── Internals ──────────────────────────────────────────────────────

    function _requireValidTranche(uint8 tranche) internal pure {
        if (tranche >= TRANCHE_COUNT) revert InvalidTranche(tranche);
    }

    function _requireNotMidnight() internal view {
        if (MIDNIGHT_MODE) revert TranchesDisabled();
    }

    function _requireNonZero(uint256 amount) internal pure {
        if (amount == 0) revert ZeroAmount();
    }

    function _requireStatus(uint256 invoiceId, Status expected) internal view returns (Invoice storage inv) {
        inv = invoices[invoiceId];
        if (inv.status != expected) revert BadStatus(invoiceId);
    }

    function _clearPendingBridgeIfCurrent(uint256 invoiceId, Invoice storage inv, bool force) internal {
        if (
            force || inv.paidInstallments >= inv.nInstallments
                || block.timestamp <= lateAfter(invoiceId, installmentDue(invoiceId, inv.paidInstallments))
        ) {
            delete pendingBridgeUntil[invoiceId];
        }
    }

    function _transferIn(address from, uint256 amount) internal {
        USDC.safeTransferFrom(from, address(this), amount);
    }

    function _transferOut(address to, uint256 amount) internal {
        USDC.safeTransfer(to, amount);
    }

    function _settle(uint256 invoiceId, Invoice storage inv) internal {
        inv.status = Status.Settled;
        delete pendingBridgeUntil[invoiceId];
        uint256 sellerId = inv.sellerAgentId;
        uint256 residual = MIDNIGHT_MODE ? 0 : inv.holdbackCollected;
        uint256 released = 0;
        uint256 contested = 0;
        inv.holdbackCollected = 0;
        bool frozen = workspaceFrozen[sellerId];
        if (residual > 0) {
            if (!frozen) {
                totalHoldbackHeld -= residual;
                _transferOut(IDENTITY.ownerOf(sellerId), residual);
                released = residual;
            } else {
                frozenHoldbackOf[sellerId] += residual;
                contested = residual;
            }
        }
        BINV_TOKEN.burn(invoiceId);
        if (
            address(reserve) != address(0) && outstandingOf[sellerId] == 0 && unresolvedDefaultCountOf[sellerId] == 0
                && sellerUnrecoveredLossOf[sellerId] == 0
        ) {
            reserve.setRequired(sellerId, 0);
        }
        if (inv.face >= Params.MIN_PAIR_SETTLEMENT_USDC && !REPUTATION.permanentDefault(sellerId)) {
            REPUTATION.recordPairSettlement(sellerId, inv.debtorAgentId);
        }
        emit InvoiceSettled(invoiceId, released, contested);
    }

    function _reduceExposure(Invoice storage inv, uint128 amount) internal {
        outstandingOf[inv.sellerAgentId] -= amount;
        debtorOutstandingOf[inv.sellerAgentId][inv.debtorAgentId] -= amount;
        if (!MIDNIGHT_MODE) tranchePrincipal[inv.tranche] -= amount;
    }

    /// @dev SPEC §4.8 layers 4–6 / §6.2: losses fill junior-first — C until its
    ///      capacity (deposits − loss) is exhausted, then B, then A.
    function _allocateLoss(uint256 loss) internal {
        uint256 requested = loss;
        for (uint8 i = 0; i < TRANCHE_COUNT; ++i) {
            uint8 t = (TRANCHE_COUNT - 1) - i;
            uint256 capacity = trancheAssets(t); // = deposits[t] − loss[t], the remaining buffer
            uint256 take = loss < capacity ? loss : capacity;
            if (take > 0) {
                trancheLoss[t] += take;
                loss -= take;
                emit LossAllocated(t, take);
            }
            if (loss == 0) break;
        }
        if (loss != 0) revert LossAccountingMismatch(requested, requested - loss);
    }

    function _recoverLossSeniorFirst(uint256 invoiceId, uint256 sellerAgentId, uint256 recovery, address source)
        internal
        returns (uint256 applied)
    {
        for (uint8 t = 0; t < TRANCHE_COUNT; ++t) {
            uint256 booked = trancheLoss[t];
            uint256 take = recovery < booked ? recovery : booked;
            if (take > 0) {
                trancheLoss[t] -= take;
                recovery -= take;
                applied += take;
                emit LossRecovered(invoiceId, sellerAgentId, t, take, source);
            }
            if (recovery == 0) break;
        }
    }

    function _applyLossRecovery(uint256 invoiceId, Invoice storage inv, uint256 amount, address source) internal {
        unrecoveredLossOf[invoiceId] -= amount;
        sellerUnrecoveredLossOf[inv.sellerAgentId] -= amount;
        totalUnrecoveredLoss -= amount;
        uint256 applied = _recoverLossSeniorFirst(invoiceId, inv.sellerAgentId, amount, source);
        if (applied != amount) revert LossAccountingMismatch(amount, applied);
    }

    function _netFrozenHoldback(uint256 invoiceId, Invoice storage inv) internal returns (uint256 applied) {
        uint256 sellerAgentId = inv.sellerAgentId;
        uint256 contested = frozenHoldbackOf[sellerAgentId];
        uint256 invoiceLoss = unrecoveredLossOf[invoiceId];
        applied = contested < invoiceLoss ? contested : invoiceLoss;
        if (applied == 0) return 0;

        frozenHoldbackOf[sellerAgentId] = contested - applied;
        totalHoldbackHeld -= applied;
        _applyLossRecovery(invoiceId, inv, applied, address(this));
        totalLiquid += applied;
        emit ContestedHoldbackRecovered(invoiceId, sellerAgentId, applied, contested - applied);
    }

    function _finalizeSellerResolution(uint256 sellerAgentId) internal {
        if (unresolvedDefaultCountOf[sellerAgentId] != 0 || sellerUnrecoveredLossOf[sellerAgentId] != 0) return;

        if (!MIDNIGHT_MODE) {
            uint256 excess = frozenHoldbackOf[sellerAgentId];
            if (excess > 0) {
                frozenHoldbackOf[sellerAgentId] = 0;
                totalHoldbackHeld -= excess;
                _transferOut(IDENTITY.ownerOf(sellerAgentId), excess);
            }
        }

        if (address(reserve) != address(0) && outstandingOf[sellerAgentId] == 0) {
            reserve.setRequired(sellerAgentId, 0);
        }

        if (REPUTATION.permanentDefault(sellerAgentId)) return;
        workspaceFrozen[sellerAgentId] = false;
    }

    function _totalBookedLoss() internal view returns (uint256) {
        return trancheLoss[0] + trancheLoss[1] + trancheLoss[2];
    }
}
