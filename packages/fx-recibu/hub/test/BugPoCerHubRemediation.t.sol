// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {BUFIIdentityRegistry} from "../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../src/identity/BUFIReputationRegistry.sol";
import {IBUFIReputationRegistry} from "../src/interfaces/IBUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../src/invoice/InvoiceShelf.sol";
import {BINV} from "../src/invoice/BINV.sol";
import {BIFTranche} from "../src/invoice/BIFTranche.sol";
import {FactoringEvidenceV1} from "../src/libraries/FactoringEvidenceV1.sol";
import {ReceivableCommitment} from "../src/libraries/ReceivableCommitment.sol";
import {Params} from "../src/libraries/Params.sol";
import {IInvoiceShelf} from "../src/interfaces/IInvoiceShelf.sol";
import {MultiTokenReceivableEscrow} from "../src/rails/MultiTokenReceivableEscrow.sol";
import {RecibuMemoRouter} from "../src/rails/RecibuMemoRouter.sol";
import {WorkspaceOperatingReserve} from "../src/rails/WorkspaceOperatingReserve.sol";

interface VmHub {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function getBlockTimestamp() external view returns (uint256);
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function expectEmit(bool, bool, bool, bool, address) external;
}

contract MockStableToken is ERC20 {
    uint256 public feeWei;
    uint256 public bonusWei;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeWei(uint256 fee) external {
        feeWei = fee;
    }

    function setBonusWei(uint256 bonus) external {
        bonusWei = bonus;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeWei > 0 && value > feeWei) {
            super._update(from, address(0), feeWei);
            super._update(from, to, value - feeWei);
            return;
        }
        super._update(from, to, value);
        if (from != address(0) && to != address(0) && bonusWei > 0) {
            super._update(address(0), to, bonusWei);
        }
    }

    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32) external {
        _approve(owner, spender, value);
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256,
        uint256,
        bytes32 nonce,
        uint8,
        bytes32,
        bytes32
    ) external {
        require(msg.sender == to, "CALLER_MUST_BE_PAYEE");
        require(!authorizationState[from][nonce], "AUTH_USED");
        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }
}

contract BugPoCerHubRemediationTest {
    VmHub internal constant vm = VmHub(address(uint160(uint256(keccak256("hevm cheat code")))));

    MockStableToken internal usdc;
    MockStableToken internal eurc;
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    WorkspaceOperatingReserve internal reserve;
    InvoiceShelf internal shelf;
    MultiTokenReceivableEscrow internal escrow;
    RecibuMemoRouter internal router;

    address internal admin = address(0xAD01);
    address internal ops = address(0x0F51);
    address internal servicer = address(0x5E20);
    address internal settlement = address(0x5E77);
    address internal arbiter = address(0xA2B1);
    address internal lp = address(0x1111);
    address internal lp2 = address(0x2222);
    address internal sellerOwner = address(0x5E11);
    address internal debtorOwner = address(0xDEB7);
    address internal attacker = address(0xBAD0);

    uint256 internal sellerId;
    uint256 internal debtorId;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockStableToken("USD Coin", "USDC");
        eurc = new MockStableToken("Euro Coin", "EURC");
        identity = new BUFIIdentityRegistry(admin);
        reputation = new BUFIReputationRegistry(admin, identity);
        tiers = new WorkspaceTierRegistry(identity, reputation);
        reserve = new WorkspaceOperatingReserve(usdc, admin);
        shelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin, false);
        escrow = new MultiTokenReceivableEscrow(admin);
        router = new RecibuMemoRouter(IInvoiceShelf(address(shelf)), escrow, admin);

        vm.startPrank(admin);
        identity.grantRole(identity.ISSUER_ROLE(), admin);
        reputation.grantRole(reputation.ATTESTOR_ROLE(), admin);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(shelf));
        reserve.grantRole(reserve.SHELF_ROLE(), address(shelf));
        shelf.setReserve(reserve);
        shelf.setEscrow(address(escrow));
        shelf.grantRole(shelf.SERVICER_ROLE(), servicer);
        shelf.grantRole(shelf.SETTLEMENT_ROLE(), settlement);
        shelf.grantRole(shelf.OPS_ROLE(), ops);

        escrow.setToken(address(usdc), true);
        escrow.setToken(address(eurc), true);
        escrow.grantRole(escrow.ROUTER_ROLE(), address(router));
        escrow.grantRole(escrow.SETTLEMENT_ROLE(), settlement);
        escrow.grantRole(escrow.ARBITER_ROLE(), arbiter);

        router.setToken(address(usdc), true, router.CAP_3009() | router.CAP_PERMIT());
        router.setToken(address(eurc), true, router.CAP_3009() | router.CAP_PERMIT());

        sellerId = identity.registerWorkspace(keccak256("seller-main"), sellerOwner);
        debtorId = identity.registerWorkspace(keccak256("debtor-main"), debtorOwner);
        identity.setKybStatus(sellerId, true, uint64(block.timestamp + 365 days), 1, keccak256("op-s"));
        identity.setKybStatus(debtorId, true, uint64(block.timestamp + 365 days), 1, keccak256("op-d"));
        reputation.setScore(sellerId, 80, 80, 1, bytes32("s"));
        reputation.setScore(debtorId, 80, 90, 1, bytes32("d"));
        vm.stopPrank();

        usdc.mint(lp, 5_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(shelf), type(uint256).max);
        shelf.depositTranche(2, 500_000e6);
        shelf.depositTranche(1, 500_000e6);
        shelf.depositTranche(0, 500_000e6);
        vm.stopPrank();
    }

    function _newDebtor(bytes32 tag, address owner_, uint8 score) internal returns (uint256 dId) {
        vm.startPrank(admin);
        dId = identity.registerWorkspace(keccak256(abi.encodePacked("debtor-", tag)), owner_);
        identity.setKybStatus(dId, true, uint64(vm.getBlockTimestamp() + 365 days), 1, tag);
        reputation.setScore(dId, 80, score, 1, bytes32("d"));
        vm.stopPrank();
    }

    function _lockCustom(
        InvoiceShelf targetShelf,
        uint256 sId,
        uint256 dId,
        uint128 face,
        uint8 nInst,
        uint64 firstMaturity,
        uint32 interval,
        bytes32 tag
    ) internal returns (uint256 invoiceId) {
        uint64 dueAt = uint64(uint256(firstMaturity) + uint256(nInst - 1) * uint256(interval));
        ReceivableCommitment.Terms memory terms = ReceivableCommitment.Terms({
            canonicalInvoiceCommitmentHash: tag,
            issuedAt: uint64(vm.getBlockTimestamp()),
            dueAt: dueAt
        });
        FactoringEvidenceV1 memory evidence = FactoringEvidenceV1({
            featureRootHash: keccak256("f"),
            currentSnapshotHash: keccak256("c"),
            privateTermsHash: keccak256("p")
        });
        BINV.DocBundle memory docs = BINV.DocBundle({
            invoiceDocHash: keccak256("doc"),
            assignmentHash: keccak256("assign"),
            paymentInstructionHash: keccak256("pay"),
            servicingPolicyHash: keccak256("serv"),
            disputePolicyHash: keccak256("disp")
        });
        vm.prank(servicer);
        invoiceId = targetShelf.lockInvoice(sId, dId, face, nInst, firstMaturity, interval, terms, evidence, docs);
    }

    function _lockDefault(bytes32 tag, uint128 face, uint8 debtorScore) internal returns (uint256 inv, uint256 dId) {
        dId = _newDebtor(tag, debtorOwner, debtorScore);
        inv = _lockCustom(shelf, sellerId, dId, face, 2, uint64(vm.getBlockTimestamp() + 30 days), 30 days, tag);
    }

    function _assertPoolInvariants() internal view {
        _assertPoolInvariantsOn(shelf);
    }

    function _assertPoolInvariantsOn(InvoiceShelf target) internal view {
        uint256 netTrancheAssets = target.trancheDeposits(0) + target.trancheDeposits(1) + target.trancheDeposits(2)
            - target.trancheLoss(0) - target.trancheLoss(1) - target.trancheLoss(2);
        require(target.totalLiquid() + target.totalPrincipal() == netTrancheAssets, "pool accounting identity");
        require(
            usdc.balanceOf(address(target)) == target.totalLiquid() + target.totalHoldbackHeld(),
            "shelf USDC custody identity"
        );
    }

    // ── 5.1.1: Escrow debit unbinding + Router debtor payer guard ────────

    function test_BugPoCer_5_1_1_escrowDebitUnbindsOnlyAtZeroAndRouterBlocksWrongPayer() public {
        (uint256 inv,) = _lockDefault(keccak256("5-1-1"), 200e6, 80);

        // Unauthorized attacker cannot poison tokenOf[inv] via pay, payWithPermit, or payWithAuthorization.
        eurc.mint(attacker, 100e6);
        vm.startPrank(attacker);
        eurc.approve(address(router), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.UnauthorizedPayer.selector, inv, attacker, debtorOwner)
        );
        router.pay(address(eurc), inv, 0, 50e6);

        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.UnauthorizedPayer.selector, inv, attacker, debtorOwner)
        );
        router.payWithPermit(address(eurc), attacker, inv, 0, 50e6, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));

        bytes32 badNonce = router.authorizationNonceOf(address(eurc), attacker, inv, 0, 50e6, 0, block.timestamp + 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.UnauthorizedPayer.selector, inv, attacker, debtorOwner)
        );
        router.payWithAuthorization(
            address(eurc), attacker, inv, 0, 50e6, 0, block.timestamp + 1 hours, badNonce, 27, bytes32(0), bytes32(0)
        );
        vm.stopPrank();
        require(escrow.tokenOf(inv) == address(0), "attacker failed to poison tokenOf");

        // Legitimate debtor deposits EURC.
        eurc.mint(debtorOwner, 100e6);
        vm.startPrank(debtorOwner);
        eurc.approve(address(router), 100e6);
        router.pay(address(eurc), inv, 0, 100e6);
        vm.stopPrank();
        require(escrow.tokenOf(inv) == address(eurc), "bound to eurc");
        uint64 lockBefore = escrow.refundUnlockAt(inv);
        require(lockBefore == uint64(block.timestamp) + escrow.DEFAULT_REFUND_LOCK_DURATION(), "lock armed");

        // Partial release preserves tokenOf and refundUnlockAt.
        vm.prank(settlement);
        escrow.releaseTo(inv, settlement, 40e6);
        require(escrow.tokenOf(inv) == address(eurc), "partial debit keeps tokenOf");
        require(escrow.refundUnlockAt(inv) == lockBefore, "partial debit keeps lock");
        require(escrow.escrowedOf(inv) == 60e6, "remaining 60");

        // Full release clears tokenOf and refundUnlockAt, allowing subsequent deposit in USDC.
        vm.prank(settlement);
        escrow.releaseTo(inv, settlement, 60e6);
        require(escrow.tokenOf(inv) == address(0), "full debit clears tokenOf");
        require(escrow.refundUnlockAt(inv) == 0, "full debit clears lock");
        require(escrow.totalEscrowedOf(address(eurc)) == 0, "totalEscrowedOf zero");

        usdc.mint(debtorOwner, 100e6);
        vm.startPrank(debtorOwner);
        usdc.approve(address(router), 100e6);
        router.pay(address(usdc), inv, 0, 100e6);
        vm.stopPrank();
        require(escrow.tokenOf(inv) == address(usdc), "re-bound cleanly to usdc");
    }

    // ── 5.1.2: markDefaulted burns bINV in both modes ────────────────────

    function test_BugPoCer_5_1_2_markDefaultedBurnsBinvInBothModes() public {
        (uint256 inv,) = _lockDefault(keccak256("5-1-2-std"), 200e6, 80);
        _assertPoolInvariants();
        BINV binv = shelf.BINV_TOKEN();
        require(binv.ownerOf(inv) == sellerOwner, "minted to seller");

        uint256 graceEnd = shelf.lateAfter(inv, shelf.installmentDue(inv, 0));
        vm.warp(graceEnd + 1);
        vm.prank(servicer);
        shelf.markDefaulted(inv);
        _assertPoolInvariants();

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, inv));
        binv.ownerOf(inv);
        require(binv.docBundleOf(inv).invoiceDocHash == bytes32(0), "docs cleared on burn");

        // Midnight mode also burns bINV on markDefaulted.
        InvoiceShelf midnightShelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin, true);
        vm.startPrank(admin);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(midnightShelf));
        midnightShelf.grantRole(midnightShelf.SERVICER_ROLE(), servicer);
        uint256 s2 = identity.registerWorkspace(keccak256("seller-m2"), address(0x5E12));
        identity.setKybStatus(s2, true, uint64(vm.getBlockTimestamp() + 365 days), 1, keccak256("op-s2"));
        reputation.setScore(s2, 80, 80, 1, bytes32("s2"));
        vm.stopPrank();
        uint256 d2 = _newDebtor(keccak256("5-1-2-mid"), debtorOwner, 80);
        uint256 mInv = _lockCustom(
            midnightShelf, s2, d2, 200e6, 2, uint64(vm.getBlockTimestamp() + 30 days), 30 days, keccak256("5-1-2-m")
        );
        BINV mBinv = midnightShelf.BINV_TOKEN();
        require(mBinv.ownerOf(mInv) == address(0x5E12), "midnight binv minted");

        uint256 mGraceEnd = midnightShelf.lateAfter(mInv, midnightShelf.installmentDue(mInv, 0));
        vm.warp(mGraceEnd + 1);
        vm.prank(servicer);
        midnightShelf.markDefaulted(mInv);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, mInv));
        mBinv.ownerOf(mInv);
        require(midnightShelf.unresolvedDefaultCountOf(s2) == 1, "midnight tracks unresolved count");
    }

    function test_BugPoCer_5_1_2_markDefaultedReclassifiesHoldbackWhenOutstandingIsZero() public {
        // face = 200e6, advance = 160e6, holdback = 40e6, two 100e6 installments.
        (uint256 inv,) = _lockDefault(keccak256("5-1-2-hb-zero-out"), 200e6, 80);
        _assertPoolInvariants();

        // Pay 170e6: clears all 160e6 advance (outstanding == 0) and collects 10e6 holdback,
        // leaving 30e6 unpaid on installment 1 so the invoice remains Funded.
        usdc.mint(servicer, 170e6);
        vm.startPrank(servicer);
        usdc.approve(address(shelf), 170e6);
        shelf.applyPayment(inv, 170e6);
        vm.stopPrank();

        (,,,, uint128 outBefore,, uint128 hbColBefore,,,,,,,) = shelf.invoices(inv);
        require(outBefore == 0, "outstanding zeroed");
        require(hbColBefore == 10e6, "10e6 holdback collected");
        require(shelf.frozenHoldbackOf(sellerId) == 0, "no frozen holdback before default");
        require(shelf.totalHoldbackHeld() == 10e6, "totalHoldbackHeld tracks 10e6");
        _assertPoolInvariants();

        // Default on installment 1: inv.holdbackCollected (10e6) must move to frozenHoldbackOf[sellerId].
        uint256 graceEnd = shelf.lateAfter(inv, shelf.installmentDue(inv, 1));
        vm.warp(graceEnd + 1);
        vm.prank(servicer);
        shelf.markDefaulted(inv);
        _assertPoolInvariants();

        (,,,,,, uint128 hbColAfter,,,,,,,) = shelf.invoices(inv);
        require(hbColAfter == 0, "invoice holdbackCollected cleared");
        require(shelf.frozenHoldbackOf(sellerId) == 10e6, "holdback reclassified into frozenHoldbackOf");
        require(shelf.totalHoldbackHeld() == 10e6, "totalHoldbackHeld preserved");
        require(shelf.unrecoveredLossOf(inv) == 0, "zero LP loss");
        BINV binv = shelf.BINV_TOKEN();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, inv));
        binv.ownerOf(inv);

        // Resolving releases the 10e6 excess back to seller and keeps pool accounting exact.
        uint256 sellerBefore = usdc.balanceOf(sellerOwner);
        vm.prank(ops);
        shelf.resolveDefault(inv, false);
        _assertPoolInvariants();
        require(shelf.frozenHoldbackOf(sellerId) == 0, "frozen holdback released");
        require(shelf.totalHoldbackHeld() == 0, "totalHoldbackHeld zeroed");
        require(usdc.balanceOf(sellerOwner) == sellerBefore + 10e6, "seller received 10e6 holdback");
        require(!shelf.workspaceFrozen(sellerId), "seller unfrozen");
    }

    // ── 5.1.3: depositTranche NAV pricing & loss gate ────────────────────

    function test_BugPoCer_5_1_3_depositTrancheBlocksUnresolvedLossAndPricesAtNav() public {
        (uint256 inv,) = _lockDefault(keccak256("5-1-3"), 200e6, 80);
        _assertPoolInvariants();
        uint256 graceEnd = shelf.lateAfter(inv, shelf.installmentDue(inv, 0));
        vm.warp(graceEnd + 1);
        vm.prank(servicer);
        shelf.markDefaulted(inv);
        _assertPoolInvariants();

        uint256 loss = shelf.unrecoveredLossOf(inv);
        require(loss > 0, "loss booked");

        usdc.mint(lp2, 100_000e6);
        vm.startPrank(lp2);
        usdc.approve(address(shelf), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.PoolHasUnresolvedLoss.selector, loss, loss));
        shelf.depositTranche(2, 10_000e6);
        vm.stopPrank();

        // Recover full loss, then lp2 deposits at live NAV cleanly.
        usdc.mint(address(this), loss);
        usdc.approve(address(shelf), loss);
        shelf.recoverDefault(inv, loss);
        _assertPoolInvariants();

        uint256 supplyBefore = shelf.tranches(2).totalSupply();
        uint256 navBefore = shelf.trancheAssets(2);
        vm.prank(lp2);
        uint256 shares = shelf.depositTranche(2, 50_000e6);
        require(shares == (50_000e6 * supplyBefore) / navBefore, "exact NAV shares");
        _assertPoolInvariants();

        // Invalid tranche index rejected.
        vm.prank(lp2);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.InvalidTranche.selector, uint8(3)));
        shelf.depositTranche(3, 1_000e6);
    }

    // ── 5.1.4: resolveDefault blocks replay and never forgives LP loss ───

    function test_BugPoCer_5_1_4_resolveDefaultNoReplayAndKeepsFrozenUntilLossCured() public {
        (uint256 inv,) = _lockDefault(keccak256("5-1-4"), 200e6, 80);
        _assertPoolInvariants();
        uint256 graceEnd = shelf.lateAfter(inv, shelf.installmentDue(inv, 0));
        vm.warp(graceEnd + 1);
        vm.prank(servicer);
        shelf.markDefaulted(inv);
        _assertPoolInvariants();

        uint256 loss = shelf.unrecoveredLossOf(inv);
        require(loss > 0, "loss exists");

        // Resolve as legitimate distress: count drops to 0, but seller stays frozen while loss > 0.
        vm.prank(ops);
        shelf.resolveDefault(inv, false);
        _assertPoolInvariants();
        require(shelf.workspaceFrozen(sellerId), "still frozen while LP loss unrecovered");
        require(shelf.unresolvedDefaultCountOf(sellerId) == 0, "unresolved count 0");
        require(uint8(shelf.defaultResolutionOf(inv)) == uint8(InvoiceShelf.DefaultResolution.Restructured), "marked");

        // Re-borrowing while sellerUnrecoveredLossOf > 0 MUST revert with Frozen!
        uint256 dReborrow = _newDebtor(keccak256("5-1-4-reborrow"), debtorOwner, 80);
        uint64 fm = uint64(vm.getBlockTimestamp() + 30 days);
        ReceivableCommitment.Terms memory terms =
            ReceivableCommitment.Terms(keccak256("5-1-4-reborrow-inv"), uint64(vm.getBlockTimestamp()), fm + 30 days);
        FactoringEvidenceV1 memory ev = FactoringEvidenceV1(keccak256("f"), keccak256("c"), keccak256("p"));
        BINV.DocBundle memory docs =
            BINV.DocBundle(keccak256("d"), keccak256("a"), keccak256("p"), keccak256("s"), keccak256("x"));
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.Frozen.selector, sellerId));
        shelf.lockInvoice(sellerId, dReborrow, 200e6, 2, fm, 30 days, terms, ev, docs);

        // Replay must revert.
        vm.prank(ops);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.DefaultAlreadyResolved.selector, inv));
        shelf.resolveDefault(inv, false);

        // Curing the loss unfreezes the seller and re-enables lockInvoice.
        usdc.mint(address(this), loss);
        usdc.approve(address(shelf), loss);
        shelf.recoverDefault(inv, loss);
        _assertPoolInvariants();
        require(!shelf.workspaceFrozen(sellerId), "unfrozen after loss cured");

        vm.prank(servicer);
        shelf.lockInvoice(sellerId, dReborrow, 200e6, 2, fm, 30 days, terms, ev, docs);
        _assertPoolInvariants();
    }

    // ── 5.1.5: Dust escrow cannot DoS default; router enforces guards ────

    function test_BugPoCer_5_1_5_escrowDustNoDefaultDosAndRouterGuards() public {
        (uint256 inv,) = _lockDefault(keccak256("5-1-5-dust"), 200e6, 80);
        // Debtor deposits 1 wei USDC before grace; open installment is 100e6.
        usdc.mint(debtorOwner, 500e6);
        vm.startPrank(debtorOwner);
        usdc.approve(address(router), 500e6);
        router.pay(address(usdc), inv, 0, 1);
        require(usdc.allowance(address(router), address(escrow)) == 0, "allowance cleared");

        // Overpayment rejected by router.
        vm.expectRevert(abi.encodeWithSelector(RecibuMemoRouter.Overpayment.selector, uint256(200e6 + 1), uint256(200e6)));
        router.pay(address(usdc), inv, 0, 200e6);
        vm.stopPrank();

        // Warp past grace: late partial USDC payment (< openAmount 100e6) rejected by router.
        uint256 graceEnd = shelf.lateAfter(inv, shelf.installmentDue(inv, 0));
        vm.warp(graceEnd + 1);
        vm.prank(debtorOwner);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.InsufficientLatePayment.selector, uint256(50e6 + 1), uint256(100e6))
        );
        router.pay(address(usdc), inv, 0, 50e6);

        // Late non-USDC payment rejected by router.
        eurc.mint(debtorOwner, 100e6);
        vm.startPrank(debtorOwner);
        eurc.approve(address(router), 100e6);
        vm.expectRevert(abi.encodeWithSelector(RecibuMemoRouter.LateNonDenominationPayment.selector, inv, address(eurc)));
        router.pay(address(eurc), inv, 0, 100e6);
        vm.stopPrank();

        // Because escrowed (1 wei) < openAmount (100e6), markDefaulted succeeds (dust cannot DoS default!).
        vm.prank(servicer);
        shelf.markDefaulted(inv);
        require(uint8(shelf.invoiceStatus(inv)) == uint8(InvoiceShelf.Status.Defaulted), "default succeeded despite 1 wei");

        // Now test full USDC installment DOES protect against default, and non-USDC only protects within crossChainBuffer.
        vm.startPrank(admin);
        uint256 s2 = identity.registerWorkspace(keccak256("seller-515b"), address(0x515B));
        identity.setKybStatus(s2, true, uint64(vm.getBlockTimestamp() + 365 days), 1, keccak256("op-515b"));
        reputation.setScore(s2, 80, 80, 1, bytes32("s"));
        vm.stopPrank();
        uint256 d2 = _newDebtor(keccak256("5-1-5-full"), debtorOwner, 80);
        uint256 invFull =
            _lockCustom(shelf, s2, d2, 200e6, 2, uint64(vm.getBlockTimestamp() + 30 days), 30 days, keccak256("5-1-5-f"));
        uint256 d3 = _newDebtor(keccak256("5-1-5-eurc"), debtorOwner, 80);
        uint256 invEurc =
            _lockCustom(shelf, s2, d3, 200e6, 2, uint64(vm.getBlockTimestamp() + 30 days), 30 days, keccak256("5-1-5-e"));

        vm.startPrank(debtorOwner);
        router.pay(address(usdc), invFull, 0, 100e6);
        eurc.approve(address(router), 100e6);
        router.pay(address(eurc), invEurc, 0, 1);
        vm.stopPrank();

        uint256 graceEnd2 = shelf.lateAfter(invFull, shelf.installmentDue(invFull, 0));
        vm.warp(graceEnd2 + 1);
        vm.startPrank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.EscrowPendingSettlement.selector, invFull));
        shelf.markDefaulted(invFull);

        // Non-USDC blocked during crossChainBuffer window.
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.EscrowPendingSettlement.selector, invEurc));
        shelf.markDefaulted(invEurc);

        // Once crossChainBuffer elapses, non-USDC dust cannot DoS default.
        vm.warp(graceEnd2 + shelf.crossChainBuffer() + 1);
        shelf.markDefaulted(invEurc);
        vm.stopPrank();
        require(uint8(shelf.invoiceStatus(invEurc)) == uint8(InvoiceShelf.Status.Defaulted), "eurc default unblocked");
    }

    function test_BugPoCer_5_1_5_routerRejectsFeeOnTransferBalanceMismatch() public {
        MockStableToken fot = new MockStableToken("Fee Token", "FOT");
        fot.setFeeWei(5);
        vm.startPrank(admin);
        escrow.setToken(address(fot), true);
        router.setToken(address(fot), true, router.CAP_3009() | router.CAP_PERMIT());
        vm.stopPrank();

        (uint256 inv,) = _lockDefault(keccak256("5-1-5-fot2"), 200e6, 80);
        fot.mint(debtorOwner, 100e6);
        vm.startPrank(debtorOwner);
        fot.approve(address(router), 100e6);
        vm.expectRevert(RecibuMemoRouter.BalanceMismatch.selector);
        router.pay(address(fot), inv, 0, 50e6);

        vm.expectRevert(RecibuMemoRouter.BalanceMismatch.selector);
        router.payWithPermit(address(fot), debtorOwner, inv, 0, 50e6, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));

        bytes32 n = router.authorizationNonceOf(address(fot), debtorOwner, inv, 0, 50e6, 0, block.timestamp + 1 hours);
        vm.expectRevert(RecibuMemoRouter.BalanceMismatch.selector);
        router.payWithAuthorization(
            address(fot), debtorOwner, inv, 0, 50e6, 0, block.timestamp + 1 hours, n, 27, bytes32(0), bytes32(0)
        );
        vm.stopPrank();
    }

    // ── 5.1.6: Tranche capacity isolates junior risk from senior capital ─

    function test_BugPoCer_5_1_6_trancheCapacityBlocksJuniorBorrowingFromSenior() public {
        InvoiceShelf isolatedShelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin, false);
        vm.startPrank(admin);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(isolatedShelf));
        isolatedShelf.grantRole(isolatedShelf.SERVICER_ROLE(), servicer);
        vm.stopPrank();

        // Deposit ONLY into SeniorA (0); JuniorC (2) has 0.
        usdc.mint(lp, 100_000e6);
        vm.startPrank(lp);
        usdc.approve(address(isolatedShelf), 100_000e6);
        isolatedShelf.depositTranche(0, 100_000e6);
        vm.stopPrank();

        uint256 d = _newDebtor(keccak256("5-1-6-a"), debtorOwner, 80);
        uint64 fm = uint64(block.timestamp + 30 days);
        uint32 iv = 30 days;
        ReceivableCommitment.Terms memory terms = ReceivableCommitment.Terms({
            canonicalInvoiceCommitmentHash: keccak256("5-1-6-1"),
            issuedAt: uint64(block.timestamp),
            dueAt: fm + iv
        });
        FactoringEvidenceV1 memory ev = FactoringEvidenceV1(keccak256("f"), keccak256("c"), keccak256("p"));
        BINV.DocBundle memory docs =
            BINV.DocBundle(keccak256("d"), keccak256("a"), keccak256("p"), keccak256("s"), keccak256("x"));

        // Pair has no history -> JuniorC (2). Must revert even though SeniorA has 100k liquid!
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.InsufficientTrancheLiquidity.selector, uint8(2)));
        isolatedShelf.lockInvoice(sellerId, d, 200e6, 2, fm, iv, terms, ev, docs);

        // Deposit exact advance (160e6) into JuniorC -> first lock succeeds, second lock fails.
        usdc.mint(lp, 160e6);
        vm.startPrank(lp);
        usdc.approve(address(isolatedShelf), 160e6);
        isolatedShelf.depositTranche(2, 160e6);
        vm.stopPrank();

        vm.prank(servicer);
        uint256 inv = isolatedShelf.lockInvoice(sellerId, d, 200e6, 2, fm, iv, terms, ev, docs);
        require(isolatedShelf.tranchePrincipal(2) == 160e6, "tranchePrincipal reserved");
        require(isolatedShelf.trancheCapacity(2) == 0, "JuniorC capacity exhausted");
        _assertPoolInvariantsOn(isolatedShelf);

        uint256 d2 = _newDebtor(keccak256("5-1-6-b"), debtorOwner, 80);
        ReceivableCommitment.Terms memory terms2 = ReceivableCommitment.Terms({
            canonicalInvoiceCommitmentHash: keccak256("5-1-6-2"),
            issuedAt: uint64(block.timestamp),
            dueAt: fm + iv
        });
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.InsufficientTrancheLiquidity.selector, uint8(2)));
        isolatedShelf.lockInvoice(sellerId, d2, 200e6, 2, fm, iv, terms2, ev, docs);

        // Repaying restores JuniorC capacity.
        usdc.mint(servicer, 200e6);
        vm.startPrank(servicer);
        usdc.approve(address(isolatedShelf), 200e6);
        isolatedShelf.applyPayment(inv, 200e6);
        vm.stopPrank();
        require(isolatedShelf.tranchePrincipal(2) == 0, "principal released");
        require(isolatedShelf.trancheCapacity(2) == 160e6, "capacity restored");
        _assertPoolInvariantsOn(isolatedShelf);
    }

    // ── 5.1.7: Permanent default doesn't block other open invoice settlements ─

    function test_BugPoCer_5_1_7_permanentDefaultAllowsOtherOpenInvoicesToRepayAndSettle() public {
        (uint256 inv1,) = _lockDefault(keccak256("5-1-7-1"), 200e6, 80);
        (uint256 inv2, uint256 d2) = _lockDefault(keccak256("5-1-7-2"), 600e6, 60);
        (uint256 inv3,) = _lockDefault(keccak256("5-1-7-3"), 200e6, 80);

        uint256 graceEnd = shelf.lateAfter(inv1, shelf.installmentDue(inv1, 0));
        vm.warp(graceEnd + 1);
        vm.prank(servicer);
        shelf.markDefaulted(inv1);

        // Resolve inv1 as fraud -> seller permanently defaulted.
        vm.prank(ops);
        shelf.resolveDefault(inv1, true);
        _assertPoolInvariants();
        require(reputation.permanentDefault(sellerId), "seller permanently defaulted");

        // inv2 can STILL be repaid and settled without reverting in BUFIReputationRegistry!
        uint256 onTimeBefore = reputation.paidOnTimeCumulative(sellerId);
        usdc.mint(servicer, 600e6);
        vm.startPrank(servicer);
        usdc.approve(address(shelf), 600e6);
        shelf.applyPayment(inv2, 600e6);
        vm.stopPrank();
        _assertPoolInvariants();

        require(uint8(shelf.invoiceStatus(inv2)) == uint8(InvoiceShelf.Status.Settled), "inv2 settled cleanly");
        require(reputation.paidOnTimeCumulative(sellerId) == onTimeBefore, "no rep credit after perm default");
        require(reputation.pairSettledCount(sellerId, d2) == 0, "no pair history after perm default");
        require(shelf.frozenHoldbackOf(sellerId) == 180e6, "holdback captured as contested");

        // Defaulting inv3 and resolving with fraud=false after permanentDefault must NOT revert and must stay frozen.
        vm.prank(servicer);
        shelf.markDefaulted(inv3);
        vm.prank(ops);
        shelf.resolveDefault(inv3, false);
        _assertPoolInvariants();
        require(shelf.workspaceFrozen(sellerId), "remains terminally frozen");
    }

    // ── 5.1.8: withdrawReserveSurplus ────────────────────────────────────

    function test_BugPoCer_5_1_8_withdrawReserveSurplusEnforcesCleanWorkspace() public {
        // Use a Moderate seller (score 60 -> 20% reserve ratio, 50% bond share = 10% bond floor).
        vm.startPrank(admin);
        uint256 modSeller = identity.registerWorkspace(keccak256("mod-seller"), address(0x5E60));
        identity.setKybStatus(modSeller, true, uint64(block.timestamp + 365 days), 1, keccak256("op-ms"));
        reputation.setScore(modSeller, 60, 60, 1, bytes32("ms"));
        vm.stopPrank();

        usdc.mint(address(0x5E60), 1_000e6);
        vm.startPrank(address(0x5E60));
        usdc.approve(address(reserve), 1_000e6);
        reserve.postBond(modSeller, 500e6);
        vm.stopPrank();

        uint256 d = _newDebtor(keccak256("5-1-8-d"), debtorOwner, 80);
        uint256 inv = _lockCustom(shelf, modSeller, d, 200e6, 2, uint64(block.timestamp + 30 days), 30 days, keccak256("5-1-8"));

        // Non-owner rejected.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.NotWorkspaceOwner.selector, modSeller, attacker));
        shelf.withdrawReserveSurplus(modSeller, 100e6);

        // Active exposure rejected.
        vm.prank(address(0x5E60));
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.OutstandingExposure.selector, modSeller, uint256(160e6)));
        shelf.withdrawReserveSurplus(modSeller, 100e6);

        // Settle invoice cleanly -> exposure = 0 and floor = 0.
        _assertPoolInvariants();
        usdc.mint(servicer, 200e6);
        vm.startPrank(servicer);
        usdc.approve(address(shelf), 200e6);
        shelf.applyPayment(inv, 200e6);
        vm.stopPrank();
        require(reserve.requiredOf(modSeller) == 0, "floor cleared");
        _assertPoolInvariants();

        // Zero amount rejected.
        vm.prank(address(0x5E60));
        vm.expectRevert(InvoiceShelf.ZeroAmount.selector);
        shelf.withdrawReserveSurplus(modSeller, 0);

        // Clean withdrawal succeeds to workspace owner.
        uint256 balBefore = usdc.balanceOf(address(0x5E60));
        vm.expectEmit(true, true, false, true, address(shelf));
        emit InvoiceShelf.ReserveSurplusWithdrawn(modSeller, address(0x5E60), 500e6);
        vm.prank(address(0x5E60));
        shelf.withdrawReserveSurplus(modSeller, 500e6);
        require(usdc.balanceOf(address(0x5E60)) == balBefore + 500e6, "surplus returned");
        require(reserve.balanceOf(modSeller) == 0, "reserve drained");
        _assertPoolInvariants();
    }

    // ── 5.1.10: Ramp anti-gaming (min installment, epoch slope, no early prepay, pair min) ──

    function test_BugPoCer_5_1_10_reputationRampAndPairHistoryHardening() public {
        // face < nInstallments rejected.
        uint256 dBad = _newDebtor(keccak256("5-1-10-bad"), debtorOwner, 80);
        uint64 fm = uint64(block.timestamp + 30 days);
        ReceivableCommitment.Terms memory tBad = ReceivableCommitment.Terms(keccak256("5-1-10-b"), uint64(block.timestamp), fm + 30 days);
        FactoringEvidenceV1 memory ev = FactoringEvidenceV1(keccak256("f"), keccak256("c"), keccak256("p"));
        BINV.DocBundle memory docs = BINV.DocBundle(keccak256("d"), keccak256("a"), keccak256("p"), keccak256("s"), keccak256("x"));
        vm.prank(servicer);
        vm.expectRevert(InvoiceShelf.BadSchedule.selector);
        shelf.lockInvoice(sellerId, dBad, 1, 2, fm, 30 days, tBad, ev, docs);

        // Dust invoice (face 200e6 < 250e6, installments 100e6 < 250e6): neither ramp nor pair history credited.
        (uint256 invDust, uint256 dDust) = _lockDefault(keccak256("5-1-10-dust"), 200e6, 80);
        vm.warp(shelf.installmentDue(invDust, 0));
        usdc.mint(servicer, 5_000e6);
        vm.startPrank(servicer);
        usdc.approve(address(shelf), type(uint256).max);
        shelf.applyPayment(invDust, 100e6);
        vm.warp(shelf.installmentDue(invDust, 1));
        shelf.applyPayment(invDust, 100e6);
        vm.stopPrank();
        require(reputation.paidOnTimeCumulative(sellerId) == 0, "dust installments gave 0 credits");
        require(reputation.pairSettledCount(sellerId, dDust) == 0, "dust invoice gave 0 pair history");

        // Early prepayment BEFORE firstMaturity gives 0 ramp credit, but full settlement >= 250e6 grants pair history.
        (uint256 invEarly, uint256 dEarly) = _lockDefault(keccak256("5-1-10-early"), 600e6, 60);
        vm.prank(servicer);
        shelf.applyPayment(invEarly, 300e6);
        require(reputation.paidOnTimeCumulative(sellerId) == 0, "early payment gave 0 credit");
        require(reputation.pairSettledCount(sellerId, dEarly) == 0, "no pair history until full settle");
        vm.prank(servicer);
        shelf.applyPayment(invEarly, 300e6);
        require(reputation.paidOnTimeCumulative(sellerId) == 0, "both early payments gave 0 credit");
        require(reputation.pairSettledCount(sellerId, dEarly) == 1, "pair history credited on full settle >= 250e6");

        // Same-epoch slope cap: L0 = 1500e6 -> 20% = 300e6 -> maxCredits = 1 per epoch.
        uint64 epochStart = uint64(((vm.getBlockTimestamp() / Params.EPOCH_LENGTH) + 1) * Params.EPOCH_LENGTH);
        vm.warp(epochStart);
        uint256 dSlope1 = _newDebtor(keccak256("5-1-10-s1"), debtorOwner, 60);
        uint256 dSlope2 = _newDebtor(keccak256("5-1-10-s2"), debtorOwner, 60);
        uint256 invS1 = _lockCustom(shelf, sellerId, dSlope1, 600e6, 2, epochStart + 7 days, 7 days, keccak256("5-1-10-inv1"));
        uint256 invS2 = _lockCustom(shelf, sellerId, dSlope2, 600e6, 2, epochStart + 7 days, 7 days, keccak256("5-1-10-inv2"));

        vm.warp(epochStart + 7 days);
        vm.startPrank(servicer);
        shelf.applyPayment(invS1, 300e6);
        require(reputation.paidOnTimeCumulative(sellerId) == 1, "1st slot in epoch credited");
        shelf.applyPayment(invS2, 300e6);
        require(reputation.paidOnTimeCumulative(sellerId) == 1, "2nd slot in same epoch slope-capped");
        vm.stopPrank();

        // Next epoch allows another credit.
        uint64 nextEpoch = epochStart + Params.EPOCH_LENGTH;
        vm.warp(nextEpoch);
        uint256 dSlope3 = _newDebtor(keccak256("5-1-10-s3"), debtorOwner, 60);
        uint256 invS3 = _lockCustom(shelf, sellerId, dSlope3, 600e6, 2, nextEpoch + 7 days, 7 days, keccak256("5-1-10-inv3"));
        vm.warp(nextEpoch + 7 days);
        vm.prank(servicer);
        shelf.applyPayment(invS3, 300e6);
        require(reputation.paidOnTimeCumulative(sellerId) == 2, "next epoch credit granted");
    }

    // ── 5.1.11: Holdback reclassification on default & excess release on fraud ──

    function test_BugPoCer_5_1_11_defaultHoldbackReclassifiedAndExcessReturnedOnFraud() public {
        // Lock inv1 (200e6, advance 160e6, holdback 40e6) and inv2 (600e6, advance 420e6, holdback 180e6).
        (uint256 inv1,) = _lockDefault(keccak256("5-1-11-1"), 200e6, 80);
        (uint256 inv2,) = _lockDefault(keccak256("5-1-11-2"), 600e6, 60);

        // Pay 100e6 on inv1 (remaining outstanding = 60e6), then default inv1 -> loss = 60e6.
        usdc.mint(servicer, 1_000e6);
        vm.startPrank(servicer);
        usdc.approve(address(shelf), type(uint256).max);
        shelf.applyPayment(inv1, 100e6);

        uint256 graceEnd = shelf.lateAfter(inv1, shelf.installmentDue(inv1, 1));
        vm.warp(graceEnd + 1);
        shelf.markDefaulted(inv1);
        require(shelf.unrecoveredLossOf(inv1) == 60e6, "loss 60e6");
        _assertPoolInvariants();

        // inv2 settles while seller is frozen -> 180e6 holdback goes to frozenHoldbackOf[seller].
        shelf.applyPayment(inv2, 600e6);
        vm.stopPrank();
        require(shelf.frozenHoldbackOf(sellerId) == 180e6, "180e6 contested holdback");
        require(shelf.totalHoldbackHeld() == 180e6, "totalHoldbackHeld matches");
        _assertPoolInvariants();

        // Ops marks inv1 as FRAUD -> 60e6 nets LP loss, 120e6 true excess returns to seller!
        uint256 sellerBefore = usdc.balanceOf(sellerOwner);
        vm.prank(ops);
        shelf.resolveDefault(inv1, true);
        _assertPoolInvariants();

        require(shelf.unrecoveredLossOf(inv1) == 0, "loss cured");
        require(shelf.frozenHoldbackOf(sellerId) == 0, "no stranded holdback");
        require(shelf.totalHoldbackHeld() == 0, "totalHoldbackHeld zeroed");
        require(usdc.balanceOf(sellerOwner) == sellerBefore + 120e6, "true excess 120e6 returned");
        require(shelf.workspaceFrozen(sellerId), "fraud stays permanently frozen");
    }

    // ── 5.1.12: redeemTranche ────────────────────────────────────────────

    function test_BugPoCer_5_1_12_redeemTrancheExitsIdlePoolAndProtectsHoldbacks() public {
        (uint256 inv,) = _lockDefault(keccak256("5-1-12"), 200e6, 80);
        _assertPoolInvariants();

        // Cannot redeem while principal deployed.
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.PoolNotIdle.selector, uint256(160e6), uint256(0)));
        shelf.redeemTranche(2, 1_000e18);

        // Settle invoice cleanly.
        usdc.mint(servicer, 200e6);
        vm.startPrank(servicer);
        usdc.approve(address(shelf), 200e6);
        shelf.applyPayment(inv, 200e6);
        vm.stopPrank();
        require(shelf.totalPrincipal() == 0, "pool idle");
        _assertPoolInvariants();

        // Exceeding share balance reverts.
        uint256 lpShares = shelf.tranches(2).balanceOf(lp);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.InsufficientTrancheShares.selector, lpShares + 1, lpShares));
        shelf.redeemTranche(2, lpShares + 1);

        // Zero shares reverts.
        vm.prank(lp);
        vm.expectRevert(InvoiceShelf.ZeroAmount.selector);
        shelf.redeemTranche(2, 0);

        // Dust shares rounding to 0 assets reverts.
        vm.prank(lp);
        vm.expectRevert(InvoiceShelf.RedemptionRoundsToZero.selector);
        shelf.redeemTranche(2, 1);

        // Full redemption returns exact USDC basis.
        uint256 lpBalBefore = usdc.balanceOf(lp);
        vm.expectEmit(true, true, false, true, address(shelf));
        emit InvoiceShelf.TrancheRedemption(2, lp, 500_000e6, lpShares);
        vm.prank(lp);
        uint256 assetsOut = shelf.redeemTranche(2, lpShares);
        require(assetsOut == 500_000e6, "full assets redeemed");
        require(usdc.balanceOf(lp) == lpBalBefore + 500_000e6, "usdc transferred");
        require(shelf.tranches(2).totalSupply() == 0, "shares burned");
        _assertPoolInvariants();

        // Midnight mode disables redeemTranche.
        InvoiceShelf mShelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin, true);
        vm.prank(lp);
        vm.expectRevert(InvoiceShelf.TranchesDisabled.selector);
        mShelf.redeemTranche(0, 1e18);
    }

    // ── 5.1.15: Multi-default resolution requires ALL resolved + cured ───

    function test_BugPoCer_5_1_15_multipleDefaultsRequireAllResolvedAndCured() public {
        (uint256 inv1,) = _lockDefault(keccak256("5-1-15-1"), 200e6, 80);
        (uint256 inv2,) = _lockDefault(keccak256("5-1-15-2"), 200e6, 80);

        uint256 graceEnd = shelf.lateAfter(inv1, shelf.installmentDue(inv1, 0));
        vm.warp(graceEnd + 1);
        vm.startPrank(servicer);
        shelf.markDefaulted(inv1);
        shelf.markDefaulted(inv2);
        vm.stopPrank();
        require(shelf.unresolvedDefaultCountOf(sellerId) == 2, "two unresolved defaults");

        uint256 loss1 = shelf.unrecoveredLossOf(inv1);
        uint256 loss2 = shelf.unrecoveredLossOf(inv2);

        // Resolve & cure inv1 only -> MUST stay frozen because inv2 is still unresolved!
        _assertPoolInvariants();
        vm.prank(ops);
        shelf.resolveDefault(inv1, false);
        usdc.mint(address(this), loss1 + loss2);
        usdc.approve(address(shelf), loss1 + loss2);
        shelf.recoverDefault(inv1, loss1);
        _assertPoolInvariants();
        require(shelf.workspaceFrozen(sellerId), "still frozen: inv2 unresolved");

        // Resolve inv2 -> STILL frozen because loss2 unrecovered!
        vm.prank(ops);
        shelf.resolveDefault(inv2, false);
        require(shelf.workspaceFrozen(sellerId), "still frozen: inv2 loss unrecovered");

        // Cure loss2 -> NOW unfrozen!
        shelf.recoverDefault(inv2, loss2);
        _assertPoolInvariants();
        require(!shelf.workspaceFrozen(sellerId), "unfrozen once all defaults resolved & cured");
    }

    // ── 5.1.19: Bridge nonce dedup & partial payment preserves window ────

    function test_BugPoCer_5_1_19_bridgeNonceDedupAndPartialPaymentPreservesWindow() public {
        (uint256 inv,) = _lockDefault(keccak256("5-1-19"), 200e6, 80);
        uint256 graceEnd = shelf.lateAfter(inv, shelf.installmentDue(inv, 0));
        vm.warp(graceEnd + 1);

        bytes32 nonce = keccak256("bridge-nonce-5119");
        vm.startPrank(servicer);
        shelf.notifyCrossChainRepayment(inv, nonce);
        uint64 pendingUntil = shelf.pendingBridgeUntil(inv);

        // Replaying the same bridgeNonce must revert!
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.BridgeNonceAlreadyUsed.selector, nonce));
        shelf.notifyCrossChainRepayment(inv, nonce);

        // A 1-wei partial payment while past grace MUST NOT clear pendingBridgeUntil!
        usdc.mint(servicer, 200e6);
        usdc.approve(address(shelf), 200e6);
        shelf.applyPayment(inv, 1);
        require(shelf.pendingBridgeUntil(inv) == pendingUntil, "dust payment did not wipe bridge window");

        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.CrossChainRepaymentInFlight.selector, inv, pendingUntil));
        shelf.markDefaulted(inv);

        // Completing the overdue installment (so next installment is NOT late) clears pendingBridgeUntil!
        shelf.applyPayment(inv, 100e6 - 1);
        require(shelf.pendingBridgeUntil(inv) == 0, "clearing overdue installment clears bridge window");
        vm.stopPrank();

        // Midnight mode: recordRepaymentSettled with partial units while overdue preserves pendingBridgeUntil.
        InvoiceShelf mShelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin, true);
        vm.startPrank(admin);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(mShelf));
        mShelf.grantRole(mShelf.SERVICER_ROLE(), servicer);
        mShelf.grantRole(mShelf.ADVANCE_ROLE(), settlement);
        vm.stopPrank();

        uint256 dM = _newDebtor(keccak256("5-1-19-m"), debtorOwner, 80);
        uint256 mInv = _lockCustom(
            mShelf, sellerId, dM, 200e6, 2, uint64(vm.getBlockTimestamp() + 30 days), 30 days, keccak256("5-1-19-mi")
        );
        uint64 mat = uint64(mShelf.lateAfter(mInv, mShelf.dueDate(mInv)) + 1 days);
        vm.prank(settlement);
        mShelf.bindAdvance(mInv, address(0xACC1), keccak256("mkt"), mat, 100, 100e6, 500, keccak256("sc"));

        uint256 mGraceEnd = mShelf.lateAfter(mInv, mShelf.installmentDue(mInv, 0));
        vm.warp(mGraceEnd + 1);
        vm.prank(servicer);
        mShelf.notifyCrossChainRepayment(mInv, keccak256("bn-mid"));
        uint64 mPending = mShelf.pendingBridgeUntil(mInv);

        vm.prank(settlement);
        mShelf.recordRepaymentSettled(mInv, 40, 40e6, 1, keccak256("msg-1"), keccak256("memo-1"));
        require(mShelf.pendingBridgeUntil(mInv) == mPending, "partial midnight settle preserves window");

        vm.prank(settlement);
        mShelf.recordRepaymentSettled(mInv, 60, 60e6, 1, keccak256("msg-2"), keccak256("memo-2"));
        require(mShelf.pendingBridgeUntil(mInv) == 0, "full midnight unit settle clears window");
    }

    // ── 5.2.2: BUFIReputationRegistry.markRestructured accepts SETTLEMENT_ROLE ──

    function test_BugPoCer_5_2_2_markRestructuredAcceptsSettlementOrOpsRole() public {
        // Notice in setUp(): `shelf` has ONLY `SETTLEMENT_ROLE` on `reputation` (NOT `OPS_ROLE`!).
        require(!reputation.hasRole(reputation.OPS_ROLE(), address(shelf)), "shelf lacks OPS_ROLE on rep");
        require(reputation.hasRole(reputation.SETTLEMENT_ROLE(), address(shelf)), "shelf has SETTLEMENT_ROLE");

        (uint256 inv,) = _lockDefault(keccak256("5-2-2"), 200e6, 80);
        uint256 graceEnd = shelf.lateAfter(inv, shelf.installmentDue(inv, 0));
        vm.warp(graceEnd + 1);
        vm.prank(servicer);
        shelf.markDefaulted(inv);

        // Previously reverted with AccessControlUnauthorizedAccount(shelf, OPS_ROLE)!
        vm.prank(ops);
        shelf.resolveDefault(inv, false);
        require(reputation.restructuredCount(sellerId) == 1, "markRestructured succeeded via SETTLEMENT_ROLE");

        // Direct OPS_ROLE also works; unauthorized reverts.
        bytes32 repOps = reputation.OPS_ROLE();
        vm.prank(admin);
        reputation.grantRole(repOps, ops);
        vm.prank(ops);
        reputation.markRestructured(sellerId);
        require(reputation.restructuredCount(sellerId) == 2, "OPS_ROLE also succeeds");

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, repOps)
        );
        reputation.markRestructured(sellerId);
    }

    // ── 5.2.4: Active, bounded, non-sliding escrow refund lock ───────────

    function test_BugPoCer_5_2_4_escrowRefundLockActiveBoundedAndNonSliding() public {
        (uint256 inv,) = _lockDefault(keccak256("5-2-4"), 200e6, 80);

        // Bounds on setRefundLockDuration.
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(MultiTokenReceivableEscrow.InvalidRefundLock.selector, uint64(4 minutes)));
        escrow.setRefundLockDuration(4 minutes);
        vm.expectRevert(abi.encodeWithSelector(MultiTokenReceivableEscrow.InvalidRefundLock.selector, uint64(7 days + 1)));
        escrow.setRefundLockDuration(7 days + 1);
        escrow.setRefundLockDuration(2 hours);
        vm.stopPrank();

        // First deposit arms 2-hour lock.
        usdc.mint(debtorOwner, 200e6);
        vm.startPrank(debtorOwner);
        usdc.approve(address(router), 200e6);
        router.pay(address(usdc), inv, 0, 50e6);
        vm.stopPrank();
        uint64 armedUnlock = uint64(block.timestamp) + 2 hours;
        require(escrow.refundUnlockAt(inv) == armedUnlock, "first deposit armed lock");

        // Arbiter cannot refund while locked.
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(MultiTokenReceivableEscrow.RefundLocked.selector, inv, armedUnlock));
        escrow.refund(inv, debtorOwner, 50e6);

        // Second deposit 1 hour later MUST NOT slide the lock forward!
        uint64 afterWarp = uint64(vm.getBlockTimestamp()) + 1 hours;
        vm.warp(afterWarp);
        vm.prank(debtorOwner);
        router.pay(address(usdc), inv, 0, 50e6);
        require(escrow.refundUnlockAt(inv) == armedUnlock, "subsequent deposit did not slide lock");

        // Router cannot freeze permanently (type(uint64).max) or shorten existing lock.
        vm.startPrank(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(MultiTokenReceivableEscrow.InvalidRefundLock.selector, type(uint64).max)
        );
        escrow.setRefundLock(inv, type(uint64).max);

        vm.expectRevert(
            abi.encodeWithSelector(MultiTokenReceivableEscrow.InvalidRefundLock.selector, armedUnlock - 1)
        );
        escrow.setRefundLock(inv, armedUnlock - 1);

        // Router CAN extend within MAX_REFUND_LOCK_DURATION.
        uint64 extended = armedUnlock + 1 hours;
        escrow.setRefundLock(inv, extended);
        require(escrow.refundUnlockAt(inv) == extended, "router extended lock");
        vm.stopPrank();

        // Admin cannot exceed MAX_REFUND_LOCK_DURATION, but CAN shorten/clear lock.
        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiTokenReceivableEscrow.InvalidRefundLock.selector, afterWarp + 7 days + 1
            )
        );
        escrow.setRefundLock(inv, afterWarp + 7 days + 1);
        escrow.setRefundLock(inv, afterWarp);
        vm.stopPrank();

        // Now arbiter can refund immediately.
        vm.prank(arbiter);
        escrow.refund(inv, debtorOwner, 100e6);
        require(escrow.escrowedOf(inv) == 0, "refunded after admin shortened lock");
    }

    // ── 5.2.7: applyFrozenHoldback & recoverDefault unwind A->B->C ───────

    function test_BugPoCer_5_2_7_recoveryUnwindsWaterfallSeniorFirst() public {
        // Fresh shelf with small tranches (C=50, B=50, A=100) so one loss hits C, B, and A!
        InvoiceShelf wShelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin, false);
        vm.startPrank(admin);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(wShelf));
        wShelf.grantRole(wShelf.SERVICER_ROLE(), servicer);
        wShelf.grantRole(wShelf.OPS_ROLE(), ops);
        vm.stopPrank();

        usdc.mint(lp, 1_000e6);
        vm.startPrank(lp);
        usdc.approve(address(wShelf), 1_000e6);
        wShelf.depositTranche(2, 200e6); // Junior C = 200
        wShelf.depositTranche(1, 200e6); // Mezz B = 200
        wShelf.depositTranche(0, 200e6); // Senior A = 200
        vm.stopPrank();

        // Lock 2 invoices totaling 420e6 advance across Junior C? Wait: trancheCapacity(2) == 200e6!
        // Use a pair with history -> SeniorA (0), advance 420e6? Let's fund C=200, B=100, A=200 and use 2 defaults:
        // Actually give C=160, B=160, A=160? Even simpler: let's deposit C=160, B=0? No, for C to spill into B & A,
        // we need SeniorA/MezzB invoices to default (since C capacity bounds C principal, B+A defaults spill C first!).
        // Grant pair history for (sellerId, dA) so invoice uses SeniorA (0)!
        uint256 dA = _newDebtor(keccak256("5-2-7-dA"), debtorOwner, 90);
        uint256 dB = _newDebtor(keccak256("5-2-7-dB"), debtorOwner, 60);
        vm.startPrank(admin);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), admin);
        reputation.recordPairSettlement(sellerId, dA);
        reputation.recordPairSettlement(sellerId, dB);
        vm.stopPrank();

        // invA: SeniorA (0), face 500e6, advance 450e6? Deposit 500e6 into A first!
        usdc.mint(lp, 300e6);
        vm.startPrank(lp);
        usdc.approve(address(wShelf), 300e6);
        wShelf.depositTranche(0, 300e6); // A = 500e6, B = 200e6, C = 200e6
        vm.stopPrank();

        // Lock invA (SeniorA, face 500e6 -> advance 450e6) and invB (MezzB, face 200e6 -> advance 150e6).
        uint256 invA = _lockCustom(wShelf, sellerId, dA, 500e6, 2, uint64(block.timestamp + 30 days), 30 days, keccak256("5-2-7-A"));
        uint256 invB = _lockCustom(wShelf, sellerId, dB, 200e6, 2, uint64(block.timestamp + 30 days), 30 days, keccak256("5-2-7-B"));
        // Also lock invC (JuniorC, face 200e6 -> advance 160e6, holdback 40e6) to settle late while frozen!
        uint256 dC = _newDebtor(keccak256("5-2-7-dC"), debtorOwner, 80);
        uint256 invC = _lockCustom(wShelf, sellerId, dC, 200e6, 2, uint64(block.timestamp + 30 days), 30 days, keccak256("5-2-7-C"));

        // Default invA (450e6 loss): wipes C (200e6), wipes B (200e6), hits A (50e6)!
        _assertPoolInvariantsOn(wShelf);
        uint256 graceEnd = wShelf.lateAfter(invA, wShelf.installmentDue(invA, 0));
        vm.warp(graceEnd + 1);
        vm.prank(servicer);
        wShelf.markDefaulted(invA);
        _assertPoolInvariantsOn(wShelf);
        require(wShelf.trancheLoss(2) == 200e6, "C wiped");
        require(wShelf.trancheLoss(1) == 200e6, "B wiped");
        require(wShelf.trancheLoss(0) == 50e6, "A took 50e6");

        // Resolve invA first (while frozenHoldback is 0), then invC settles -> populates 40e6 frozenHoldback!
        vm.prank(ops);
        wShelf.resolveDefault(invA, false);
        _assertPoolInvariantsOn(wShelf);

        // Re-borrowing after resolveDefault(invA, false) while sellerUnrecoveredLossOf > 0 MUST revert Frozen!
        uint256 dReborrow = _newDebtor(keccak256("5-2-7-reborrow"), debtorOwner, 80);
        uint64 fmRe = uint64(vm.getBlockTimestamp() + 30 days);
        ReceivableCommitment.Terms memory termsRe =
            ReceivableCommitment.Terms(keccak256("5-2-7-reborrow-inv"), uint64(vm.getBlockTimestamp()), fmRe + 30 days);
        FactoringEvidenceV1 memory evRe = FactoringEvidenceV1(keccak256("f"), keccak256("c"), keccak256("p"));
        BINV.DocBundle memory docsRe =
            BINV.DocBundle(keccak256("d"), keccak256("a"), keccak256("p"), keccak256("s"), keccak256("x"));
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.Frozen.selector, sellerId));
        wShelf.lockInvoice(sellerId, dReborrow, 200e6, 2, fmRe, 30 days, termsRe, evRe, docsRe);

        usdc.mint(servicer, 400e6);
        vm.startPrank(servicer);
        usdc.approve(address(wShelf), 400e6);
        wShelf.applyPayment(invC, 200e6);
        wShelf.applyPayment(invB, 200e6);
        vm.stopPrank();
        _assertPoolInvariantsOn(wShelf);
        // invC had 40e6 holdback, invB had 50e6 holdback -> frozenHoldbackOf == 90e6!
        require(wShelf.frozenHoldbackOf(sellerId) == 90e6, "90e6 late frozen holdback");

        // Permissionless applyFrozenHoldback recovers A (50e6) FIRST, then B (40e6)!
        uint256 applied = wShelf.applyFrozenHoldback(invA);
        _assertPoolInvariantsOn(wShelf);
        require(applied == 90e6, "90e6 applied");
        require(wShelf.trancheLoss(0) == 0, "A recovered first!");
        require(wShelf.trancheLoss(1) == 160e6, "B recovered next!");
        require(wShelf.trancheLoss(2) == 200e6, "C still untouched");

        // Over-recovery rejected.
        usdc.mint(address(this), 500e6);
        usdc.approve(address(wShelf), 500e6);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.RecoveryExceedsUnrecoveredLoss.selector, uint256(360e6 + 1), uint256(360e6)));
        wShelf.recoverDefault(invA, 360e6 + 1);

        // Recover remaining 360e6 -> clears B (160e6) then C (200e6), and unfreezes seller!
        wShelf.recoverDefault(invA, 360e6);
        _assertPoolInvariantsOn(wShelf);
        require(wShelf.trancheLoss(1) == 0 && wShelf.trancheLoss(2) == 0, "B and C fully recovered");
        require(!wShelf.workspaceFrozen(sellerId), "seller unfrozen");
    }

    // ── 5.2.8: Escrow disable timelock, window, cancel, in-flight continuity ─

    function test_BugPoCer_5_2_8_escrowDisableTimelockWindowAndInFlightContinuity() public {
        (uint256 invInFlight,) = _lockDefault(keccak256("5-2-8-1"), 200e6, 80);
        (uint256 invFresh,) = _lockDefault(keccak256("5-2-8-2"), 200e6, 80);

        // Bind invInFlight with EURC before disable.
        eurc.mint(debtorOwner, 200e6);
        vm.startPrank(debtorOwner);
        eurc.approve(address(router), 200e6);
        router.pay(address(eurc), invInFlight, 0, 50e6);
        vm.stopPrank();

        // Immediate disable reverts.
        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(MultiTokenReceivableEscrow.TokenDisableNotReady.selector, address(eurc), uint64(0))
        );
        escrow.setToken(address(eurc), false);

        // Schedule disable -> readyAt = now + 1 day.
        escrow.scheduleTokenDisable(address(eurc));
        uint64 readyAt = escrow.tokenDisableScheduledAt(address(eurc));
        require(readyAt == uint64(block.timestamp) + 1 days, "1 day delay");

        // Cancel clears schedule.
        escrow.cancelTokenDisable(address(eurc));
        require(escrow.tokenDisableScheduledAt(address(eurc)) == 0, "cancelled");

        // Re-schedule and verify before readyAt and after window expiry both revert.
        escrow.scheduleTokenDisable(address(eurc));
        readyAt = escrow.tokenDisableScheduledAt(address(eurc));
        vm.warp(readyAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(MultiTokenReceivableEscrow.TokenDisableNotReady.selector, address(eurc), readyAt)
        );
        escrow.setToken(address(eurc), false);

        vm.warp(uint256(readyAt) + escrow.TOKEN_DISABLE_WINDOW() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(MultiTokenReceivableEscrow.TokenDisableNotReady.selector, address(eurc), readyAt)
        );
        escrow.setToken(address(eurc), false);

        // Re-schedule and execute inside window.
        escrow.scheduleTokenDisable(address(eurc));
        readyAt = escrow.tokenDisableScheduledAt(address(eurc));
        vm.warp(readyAt);
        escrow.setToken(address(eurc), false);
        vm.stopPrank();
        require(!escrow.supportedToken(address(eurc)), "eurc disabled on escrow");

        // New invoice cannot bind disabled EURC.
        vm.prank(debtorOwner);
        vm.expectRevert(abi.encodeWithSelector(MultiTokenReceivableEscrow.TokenNotSupported.selector, address(eurc)));
        router.pay(address(eurc), invFresh, 0, 50e6);

        // Already-bound in-flight invoice CAN still receive top-up EURC deposit!
        vm.prank(debtorOwner);
        router.pay(address(eurc), invInFlight, 0, 50e6);
        require(escrow.escrowedOf(invInFlight) == 100e6, "in-flight invoice top-up succeeded");
    }

    // ── 5.2.10: Self-dealing check (same id OR same owner) ───────────────

    function test_BugPoCer_5_2_10_lockInvoiceBlocksSelfDealingSameIdAndSameOwner() public {
        uint64 fm = uint64(block.timestamp + 30 days);
        ReceivableCommitment.Terms memory terms = ReceivableCommitment.Terms(keccak256("5-2-10-1"), uint64(block.timestamp), fm + 30 days);
        FactoringEvidenceV1 memory ev = FactoringEvidenceV1(keccak256("f"), keccak256("c"), keccak256("p"));
        BINV.DocBundle memory docs = BINV.DocBundle(keccak256("d"), keccak256("a"), keccak256("p"), keccak256("s"), keccak256("x"));

        // Same agentId.
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.SelfDealingReceivable.selector, sellerId));
        shelf.lockInvoice(sellerId, sellerId, 200e6, 2, fm, 30 days, terms, ev, docs);

        // Different agentId but SAME owner address (`sellerOwner`).
        uint256 sameOwnerDebtor = _newDebtor(keccak256("5-2-10-same-owner"), sellerOwner, 80);
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.SelfDealingReceivable.selector, sellerId));
        shelf.lockInvoice(sellerId, sameOwnerDebtor, 200e6, 2, fm, 30 days, terms, ev, docs);
    }

    // ── 5.2.15: applyPaymentFrom cannot pull arbitrary approvals ─────────

    function test_BugPoCer_5_2_15_applyPaymentFromRejectsArbitraryPayerInNonMidnight() public {
        (uint256 inv,) = _lockDefault(keccak256("5-2-15"), 200e6, 80);
        // `lp` already has infinite USDC approval to `shelf` from setUp()!
        uint256 lpBalBefore = usdc.balanceOf(lp);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.UnauthorizedPayer.selector, lp));
        shelf.applyPaymentFrom(inv, 100e6, lp);
        require(usdc.balanceOf(lp) == lpBalBefore, "LP approval protected");

        // Passing msg.sender (settlement) as payer works.
        usdc.mint(settlement, 100e6);
        vm.startPrank(settlement);
        usdc.approve(address(shelf), 100e6);
        shelf.applyPaymentFrom(inv, 100e6, settlement);
        vm.stopPrank();
        require(shelf.remainingFaceOf(inv) == 100e6, "self-funded settlement succeeded");

        // In Midnight mode, payer MUST equal address(escrow).
        InvoiceShelf mShelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin, true);
        vm.startPrank(admin);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(mShelf));
        mShelf.grantRole(mShelf.SERVICER_ROLE(), servicer);
        mShelf.grantRole(mShelf.SETTLEMENT_ROLE(), settlement);
        mShelf.setEscrow(address(escrow));
        vm.stopPrank();

        uint256 dM = _newDebtor(keccak256("5-2-15-m"), debtorOwner, 80);
        uint256 mInv =
            _lockCustom(mShelf, sellerId, dM, 200e6, 2, uint64(block.timestamp + 30 days), 30 days, keccak256("5-2-15-mi"));
        vm.prank(settlement);
        vm.expectRevert(InvoiceShelf.MidnightDirectPaymentDisabled.selector);
        mShelf.applyPaymentFrom(mInv, 100e6, settlement);

        vm.prank(settlement);
        mShelf.applyPaymentFrom(mInv, 100e6, address(escrow));
        require(mShelf.remainingFaceOf(mInv) == 100e6, "midnight escrow payer accepted");
    }

    // ── 5.2.17: Router cap stripping timelock, window expiry, cancel ─────

    function test_BugPoCer_5_2_17_routerCapStrippingRequiresTimelockAndWindow() public {
        uint8 cap3009 = router.CAP_3009();
        uint8 capPermit = router.CAP_PERMIT();
        vm.startPrank(admin);
        // Stripping CAP_PERMIT without schedule reverts.
        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.TokenDisableNotReady.selector, address(usdc), uint64(0))
        );
        router.setToken(address(usdc), true, cap3009);

        // Schedule disable, cancel it -> reverts again.
        router.scheduleTokenDisable(address(usdc));
        uint64 readyAt = router.tokenDisableScheduledAt(address(usdc));
        vm.expectEmit(true, false, false, false, address(router));
        emit RecibuMemoRouter.TokenDisableCancelled(address(usdc));
        router.cancelTokenDisable(address(usdc));
        require(router.tokenDisableScheduledAt(address(usdc)) == 0, "schedule cleared");

        // Re-schedule, strip CAP_PERMIT within window -> succeeds and clears schedule.
        router.scheduleTokenDisable(address(usdc));
        readyAt = router.tokenDisableScheduledAt(address(usdc));
        vm.warp(readyAt);
        router.setToken(address(usdc), true, cap3009);
        require(router.tokenDisableScheduledAt(address(usdc)) == 0, "schedule cleared on cap strip");
        (, uint8 capsNow) = router.tokenConfig(address(usdc));
        require(capsNow == cap3009, "cap stripped");

        // Adding CAP_PERMIT back while a disable is scheduled MUST NOT require timelock AND MUST NOT clear schedule!
        router.scheduleTokenDisable(address(usdc));
        uint64 pendingDisable = router.tokenDisableScheduledAt(address(usdc));
        router.setToken(address(usdc), true, cap3009 | capPermit);
        require(router.tokenDisableScheduledAt(address(usdc)) == pendingDisable, "adding cap preserves disable schedule");

        // Expired window (> readyAt + 7 days) rejects disable!
        vm.warp(uint256(pendingDisable) + router.TOKEN_DISABLE_WINDOW() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.TokenDisableNotReady.selector, address(usdc), pendingDisable)
        );
        router.setToken(address(usdc), false, 0);

        // Fresh schedule -> disable within window forces caps = 0 even if non-zero caps passed!
        router.scheduleTokenDisable(address(usdc));
        uint64 readyAt2 = router.tokenDisableScheduledAt(address(usdc));
        vm.warp(readyAt2);
        vm.expectEmit(true, false, false, true, address(router));
        emit RecibuMemoRouter.TokenConfigured(address(usdc), false, 0);
        router.setToken(address(usdc), false, 3);
        (bool allowed, uint8 disabledCaps) = router.tokenConfig(address(usdc));
        require(!allowed && disabledCaps == 0, "disabled token forced to caps=0");
        vm.stopPrank();
    }

    // ── Audit Medium #3: Midnight non-USDC escrow gets settlement buffer ──

    function test_Audit_Medium3_midnightNonUsdcEscrowGetsSettlementBuffer() public {
        InvoiceShelf mShelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin, true);
        MultiTokenReceivableEscrow mEscrow = new MultiTokenReceivableEscrow(admin);
        RecibuMemoRouter mRouter = new RecibuMemoRouter(IInvoiceShelf(address(mShelf)), mEscrow, admin);

        vm.startPrank(admin);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(mShelf));
        mShelf.setEscrow(address(mEscrow));
        mShelf.grantRole(mShelf.SERVICER_ROLE(), servicer);
        mEscrow.setToken(address(usdc), true);
        mEscrow.setToken(address(eurc), true);
        mEscrow.grantRole(mEscrow.ROUTER_ROLE(), address(mRouter));
        mRouter.setToken(address(usdc), true, mRouter.CAP_3009() | mRouter.CAP_PERMIT());
        mRouter.setToken(address(eurc), true, mRouter.CAP_3009() | mRouter.CAP_PERMIT());
        vm.stopPrank();

        uint256 dM = _newDebtor(keccak256("audit-m3-d"), debtorOwner, 80);
        uint256 mInv = _lockCustom(
            mShelf, sellerId, dM, 200e6, 2, uint64(vm.getBlockTimestamp() + 30 days), 30 days, keccak256("audit-m3-inv")
        );
        uint256 lateBoundary = mShelf.lateAfter(mInv, mShelf.installmentDue(mInv, 0));

        // On-time EURC payment deposited right at lateBoundary.
        vm.warp(lateBoundary);
        eurc.mint(debtorOwner, 100e6);
        vm.startPrank(debtorOwner);
        eurc.approve(address(mRouter), 100e6);
        mRouter.pay(address(eurc), mInv, 0, 100e6);
        vm.stopPrank();

        // At lateBoundary + 1 and lateBoundary + crossChainBuffer, markDefaulted MUST block for FX settlement!
        vm.warp(lateBoundary + 1);
        vm.startPrank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.EscrowPendingSettlement.selector, mInv));
        mShelf.markDefaulted(mInv);

        vm.warp(lateBoundary + mShelf.crossChainBuffer());
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.EscrowPendingSettlement.selector, mInv));
        mShelf.markDefaulted(mInv);

        // Once crossChainBuffer elapses beyond lateBoundary, markDefaulted succeeds.
        vm.warp(lateBoundary + mShelf.crossChainBuffer() + 1);
        mShelf.markDefaulted(mInv);
        vm.stopPrank();
        require(uint8(mShelf.invoiceStatus(mInv)) == uint8(InvoiceShelf.Status.Defaulted), "defaulted after buffer");
    }

    // ── Audit Medium #4: Fraud resolution unbricks true excess reserve bond ──

    function test_Audit_Medium4_fraudResolutionUnbricksExcessReserveBond() public {
        address fraudOwner = address(0xF2AD);
        vm.startPrank(admin);
        uint256 fraudSeller = identity.registerWorkspace(keccak256("fraud-seller-m4"), fraudOwner);
        identity.setKybStatus(fraudSeller, true, uint64(vm.getBlockTimestamp() + 365 days), 1, keccak256("op-fm4"));
        reputation.setScore(fraudSeller, 60, 60, 1, bytes32("fm4"));
        vm.stopPrank();

        // Post 500e6 bond; lock invoice with 160e6 advance (floor = 16e6).
        usdc.mint(fraudOwner, 500e6);
        vm.startPrank(fraudOwner);
        usdc.approve(address(reserve), 500e6);
        reserve.postBond(fraudSeller, 500e6);
        vm.stopPrank();

        uint256 d1 = _newDebtor(keccak256("audit-m4-d1"), debtorOwner, 80);
        uint256 inv1 = _lockCustom(
            shelf, fraudSeller, d1, 200e6, 2, uint64(vm.getBlockTimestamp() + 30 days), 30 days, keccak256("audit-m4-1")
        );
        _assertPoolInvariants();

        // Default sweeps 160e6 from reserve (leaving 340e6 true excess, 0 unrecovered LP loss).
        uint256 graceEnd = shelf.lateAfter(inv1, shelf.installmentDue(inv1, 0));
        vm.warp(graceEnd + 1);
        vm.prank(servicer);
        shelf.markDefaulted(inv1);
        _assertPoolInvariants();
        require(reserve.balanceOf(fraudSeller) == 340e6, "340e6 excess bond remains");
        require(shelf.unrecoveredLossOf(inv1) == 0, "loss fully covered by reserve");

        // While unresolved, surplus withdrawal MUST revert Frozen.
        vm.prank(fraudOwner);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.Frozen.selector, fraudSeller));
        shelf.withdrawReserveSurplus(fraudSeller, 340e6);

        // Ops resolves as FRAUD -> reserve floor clears to 0, seller stays permanently frozen.
        vm.prank(ops);
        shelf.resolveDefault(inv1, true);
        _assertPoolInvariants();
        require(reputation.permanentDefault(fraudSeller), "permanently defaulted");
        require(shelf.workspaceFrozen(fraudSeller), "permanently frozen against new locks");
        require(reserve.requiredOf(fraudSeller) == 0, "reserve floor cleared after full loss coverage");

        // New lockInvoice remains permanently blocked.
        uint256 d2 = _newDebtor(keccak256("audit-m4-d2"), debtorOwner, 80);
        uint64 fm2 = uint64(vm.getBlockTimestamp() + 30 days);
        ReceivableCommitment.Terms memory terms2 =
            ReceivableCommitment.Terms(keccak256("audit-m4-2"), uint64(vm.getBlockTimestamp()), fm2 + 30 days);
        FactoringEvidenceV1 memory ev = FactoringEvidenceV1(keccak256("f"), keccak256("c"), keccak256("p"));
        BINV.DocBundle memory docs =
            BINV.DocBundle(keccak256("d"), keccak256("a"), keccak256("p"), keccak256("s"), keccak256("x"));
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.NotEligible.selector, fraudSeller));
        shelf.lockInvoice(fraudSeller, d2, 200e6, 2, fm2, 30 days, terms2, ev, docs);

        // True excess 340e6 bond IS withdrawable by workspace owner.
        uint256 balBefore = usdc.balanceOf(fraudOwner);
        vm.prank(fraudOwner);
        shelf.withdrawReserveSurplus(fraudSeller, 340e6);
        require(usdc.balanceOf(fraudOwner) == balBefore + 340e6, "340e6 excess bond returned");
        require(reserve.balanceOf(fraudSeller) == 0, "reserve cleanly emptied");
        _assertPoolInvariants();

        // Multi-invoice fraud case: invB settles AFTER invA was resolved as Fraud -> _settle clears reserve floor.
        address fraudOwner2 = address(0xF2AE);
        vm.startPrank(admin);
        uint256 fraudSeller2 = identity.registerWorkspace(keccak256("fraud-seller-m4-b"), fraudOwner2);
        identity.setKybStatus(fraudSeller2, true, uint64(vm.getBlockTimestamp() + 365 days), 1, keccak256("op-fm4b"));
        reputation.setScore(fraudSeller2, 60, 60, 1, bytes32("fm4b"));
        vm.stopPrank();
        usdc.mint(fraudOwner2, 500e6);
        vm.startPrank(fraudOwner2);
        usdc.approve(address(reserve), 500e6);
        reserve.postBond(fraudSeller2, 500e6);
        vm.stopPrank();

        uint256 dA = _newDebtor(keccak256("audit-m4-dA"), debtorOwner, 80);
        uint256 dB = _newDebtor(keccak256("audit-m4-dB"), debtorOwner, 80);
        uint256 invA = _lockCustom(
            shelf, fraudSeller2, dA, 200e6, 2, uint64(vm.getBlockTimestamp() + 30 days), 30 days, keccak256("audit-m4-A")
        );
        uint256 invB = _lockCustom(
            shelf, fraudSeller2, dB, 200e6, 2, uint64(vm.getBlockTimestamp() + 30 days), 30 days, keccak256("audit-m4-B")
        );
        vm.warp(shelf.lateAfter(invA, shelf.installmentDue(invA, 0)) + 1);
        vm.prank(servicer);
        shelf.markDefaulted(invA);
        vm.prank(ops);
        shelf.resolveDefault(invA, true);

        // invB is still open -> OutstandingExposure blocks withdrawal.
        vm.prank(fraudOwner2);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.OutstandingExposure.selector, fraudSeller2, uint256(160e6)));
        shelf.withdrawReserveSurplus(fraudSeller2, 340e6);

        // Settle invB -> exposure hits 0, reserve floor clears to 0, 340e6 excess bond becomes withdrawable.
        usdc.mint(servicer, 200e6);
        vm.startPrank(servicer);
        usdc.approve(address(shelf), 200e6);
        shelf.applyPayment(invB, 200e6);
        vm.stopPrank();
        require(reserve.requiredOf(fraudSeller2) == 0, "floor cleared on final settle");

        vm.prank(fraudOwner2);
        shelf.withdrawReserveSurplus(fraudSeller2, 340e6);
        require(reserve.balanceOf(fraudSeller2) == 0, "multi-invoice fraud excess returned");
        _assertPoolInvariants();
    }

    // ── Audit Low #8: Monotonic pendingBridgeUntil ──────────────────────

    function test_Audit_Low8_notifyCrossChainRepaymentIsMonotonic() public {
        (uint256 inv,) = _lockDefault(keccak256("audit-l8"), 200e6, 80);
        uint256 t1 = shelf.lateAfter(inv, shelf.installmentDue(inv, 0)) + 1;
        vm.warp(t1);

        vm.prank(admin);
        shelf.setCrossChainBuffer(12 hours);

        bytes32 bnLong = keccak256("audit-l8-long");
        uint64 longUntil = uint64(t1 + 12 hours);
        vm.expectEmit(true, true, false, true, address(shelf));
        emit InvoiceShelf.CrossChainRepaymentNotified(inv, bnLong, longUntil);
        vm.prank(servicer);
        shelf.notifyCrossChainRepayment(inv, bnLong);
        require(shelf.pendingBridgeUntil(inv) == longUntil, "long window set");

        // Admin shortens crossChainBuffer to 1 hour; second spoke notification MUST NOT shorten pendingBridgeUntil!
        vm.prank(admin);
        shelf.setCrossChainBuffer(1 hours);

        vm.warp(t1 + 1 hours);
        bytes32 bnShort = keccak256("audit-l8-short");
        vm.expectEmit(true, true, false, true, address(shelf));
        emit InvoiceShelf.CrossChainRepaymentNotified(inv, bnShort, longUntil);
        vm.prank(servicer);
        shelf.notifyCrossChainRepayment(inv, bnShort);
        require(shelf.pendingBridgeUntil(inv) == longUntil, "shorter buffer preserved longer window");

        // markDefaulted at t1 + 2 hours + 1 MUST still revert with longUntil.
        vm.warp(t1 + 2 hours + 1);
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.CrossChainRepaymentInFlight.selector, inv, longUntil));
        shelf.markDefaulted(inv);

        // Later notification whose deadline exceeds longUntil extends the window monotonically.
        vm.warp(t1 + 11 hours + 30 minutes);
        uint64 extendedUntil = uint64(t1 + 12 hours + 30 minutes);
        vm.prank(servicer);
        shelf.notifyCrossChainRepayment(inv, keccak256("audit-l8-ext"));
        require(shelf.pendingBridgeUntil(inv) == extendedUntil, "longer deadline extended monotonically");
    }
}
