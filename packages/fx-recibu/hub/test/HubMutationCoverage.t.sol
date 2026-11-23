// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BUFIIdentityRegistry} from "../src/identity/BUFIIdentityRegistry.sol";
import {IBUFIIdentityRegistry} from "../src/interfaces/IBUFIIdentityRegistry.sol";
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

interface VmMut {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function getBlockTimestamp() external view returns (uint256);
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function expectEmit(bool, bool, bool, bool, address) external;
}

/// @dev Reentrant / fee / bonus ERC20 mock for killing nonReentrant & BalanceMismatch mutants.
contract MutMockToken is ERC20 {
    address public reenterTarget;
    bytes public reenterData;
    bool public armed;
    bool public reenterSucceeded;
    bytes public reenterError;
    bool public permitReverts;
    uint256 public feeWei;
    uint256 public bonusWei;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    constructor(string memory n, string memory s) ERC20(n, s) {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFee(uint256 f) external {
        feeWei = f;
    }

    function setBonus(uint256 b) external {
        bonusWei = b;
    }

    function setPermitReverts(bool v) external {
        permitReverts = v;
    }

    function armReentry(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
        armed = true;
        reenterSucceeded = false;
        reenterError = "";
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeWei > 0 && value > feeWei) {
            super._update(from, address(0), feeWei);
            super._update(from, to, value - feeWei);
        } else {
            super._update(from, to, value);
            if (from != address(0) && to != address(0) && bonusWei > 0) {
                super._update(address(0), to, bonusWei);
            }
        }
        if (armed && from != address(0) && to != address(0)) {
            armed = false;
            (bool ok, bytes memory ret) = reenterTarget.call(reenterData);
            reenterSucceeded = ok;
            reenterError = ret;
        }
    }

    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32) external {
        require(!permitReverts, "PERMIT_REVERT");
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

contract HubMutationCoverageTest {
    VmMut internal constant vm = VmMut(address(uint160(uint256(keccak256("hevm cheat code")))));

    MutMockToken internal usdc;
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    WorkspaceOperatingReserve internal reserve;
    InvoiceShelf internal shelf;
    MultiTokenReceivableEscrow internal escrow;
    RecibuMemoRouter internal router;

    address internal admin = address(0xA001);
    address internal servicer = address(0xA002);
    address internal settlement = address(0xA003);
    address internal ops = address(0xA004);
    address internal arbiter = address(0xA005);
    address internal lp = address(0xA006);
    address internal seller = address(0xA007);
    address internal debtor = address(0xA008);
    address internal rando = address(0xA009);

    uint256 internal sellerId;
    uint256 internal debtorId;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MutMockToken("USD Coin", "USDC");
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
        escrow.grantRole(escrow.ROUTER_ROLE(), address(router));
        escrow.grantRole(escrow.SETTLEMENT_ROLE(), settlement);
        escrow.grantRole(escrow.ARBITER_ROLE(), arbiter);
        router.setToken(address(usdc), true, router.CAP_3009() | router.CAP_PERMIT());

        sellerId = identity.registerWorkspace(keccak256("mut-seller"), seller);
        debtorId = identity.registerWorkspace(keccak256("mut-debtor"), debtor);
        identity.setKybStatus(sellerId, true, uint64(block.timestamp + 365 days), 1, keccak256("op1"));
        identity.setKybStatus(debtorId, true, uint64(block.timestamp + 365 days), 1, keccak256("op2"));
        reputation.setScore(sellerId, 80, 80, 1, bytes32("s"));
        reputation.setScore(debtorId, 80, 90, 1, bytes32("d"));
        vm.stopPrank();

        usdc.mint(lp, 2_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(shelf), type(uint256).max);
        shelf.depositTranche(2, 500_000e6);
        shelf.depositTranche(1, 500_000e6);
        shelf.depositTranche(0, 500_000e6);
        vm.stopPrank();
    }

    function _expectUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role));
    }

    // ── 1. WorkspaceOperatingReserve (kills all 17 mutants) ──────────────

    function test_Mut_WorkspaceOperatingReserve_fullCoverage() public {
        WorkspaceOperatingReserve res = new WorkspaceOperatingReserve(usdc, admin);
        bytes32 shelfRole = res.SHELF_ROLE();
        vm.prank(admin);
        res.grantRole(shelfRole, servicer);

        // Zero postBond reverts.
        vm.expectRevert(WorkspaceOperatingReserve.ZeroAmount.selector);
        res.postBond(1, 0);

        // postBond increments balanceOf and emits BondPosted.
        usdc.mint(seller, 500e6);
        vm.startPrank(seller);
        usdc.approve(address(res), 500e6);
        vm.expectEmit(true, true, false, true, address(res));
        emit WorkspaceOperatingReserve.BondPosted(1, seller, 300e6);
        res.postBond(1, 300e6);
        require(res.balanceOf(1) == 300e6, "bal 300");
        res.postBond(1, 200e6);
        require(res.balanceOf(1) == 500e6, "bal 500");
        vm.stopPrank();

        // setRequired role + event.
        vm.prank(rando);
        _expectUnauthorized(rando, shelfRole);
        res.setRequired(1, 100e6);

        vm.expectEmit(true, false, false, true, address(res));
        emit WorkspaceOperatingReserve.RequiredSet(1, 200e6);
        vm.prank(servicer);
        res.setRequired(1, 200e6);
        require(res.requiredOf(1) == 200e6, "req 200");

        // withdrawSurplus role, guards (amount > bal, bal - amount < required), exact boundary, event.
        vm.prank(rando);
        _expectUnauthorized(rando, shelfRole);
        res.withdrawSurplus(1, seller, 100e6);

        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(WorkspaceOperatingReserve.BelowRequired.selector, 500e6, 200e6));
        res.withdrawSurplus(1, seller, 501e6);

        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(WorkspaceOperatingReserve.BelowRequired.selector, 500e6, 200e6));
        res.withdrawSurplus(1, seller, 301e6);

        uint256 sellerBefore = usdc.balanceOf(seller);
        vm.expectEmit(true, true, false, true, address(res));
        emit WorkspaceOperatingReserve.Withdrawn(1, seller, 300e6);
        vm.prank(servicer);
        res.withdrawSurplus(1, seller, 300e6);
        require(res.balanceOf(1) == 200e6, "bal 200 left");
        require(usdc.balanceOf(seller) == sellerBefore + 300e6, "300 received");

        // sweepFor role, need < bal, need > bal, zero bal, event.
        vm.prank(rando);
        _expectUnauthorized(rando, shelfRole);
        res.sweepFor(1, 50e6);

        uint256 servBefore = usdc.balanceOf(servicer);
        vm.expectEmit(true, false, false, true, address(res));
        emit WorkspaceOperatingReserve.Swept(1, 80e6, 80e6);
        vm.prank(servicer);
        uint256 cov1 = res.sweepFor(1, 80e6);
        require(cov1 == 80e6 && res.balanceOf(1) == 120e6 && usdc.balanceOf(servicer) == servBefore + 80e6, "partial sweep");

        vm.expectEmit(true, false, false, true, address(res));
        emit WorkspaceOperatingReserve.Swept(1, 500e6, 120e6);
        vm.prank(servicer);
        uint256 cov2 = res.sweepFor(1, 500e6);
        require(cov2 == 120e6 && res.balanceOf(1) == 0 && usdc.balanceOf(servicer) == servBefore + 200e6, "capped sweep");

        vm.expectEmit(true, false, false, true, address(res));
        emit WorkspaceOperatingReserve.Swept(1, 50e6, 0);
        vm.prank(servicer);
        uint256 cov3 = res.sweepFor(1, 50e6);
        require(cov3 == 0, "empty sweep");
    }

    // ── 2. WorkspaceTierRegistry (kills all 26 mutants) ──────────────────

    function test_Mut_WorkspaceTierRegistry_fullBoundaryMatrix() public {
        // Constructor zero checks (individually).
        vm.expectRevert(WorkspaceTierRegistry.ZeroAddress.selector);
        new WorkspaceTierRegistry(IBUFIIdentityRegistry(address(0)), reputation);
        vm.expectRevert(WorkspaceTierRegistry.ZeroAddress.selector);
        new WorkspaceTierRegistry(identity, IBUFIReputationRegistry(address(0)));

        // tierOf boundaries: 0, 49, 50, 69, 70, 84, 85, 100.
        require(tiers.tierOf(0) == WorkspaceTierRegistry.Tier.Developing, "0");
        require(tiers.tierOf(49) == WorkspaceTierRegistry.Tier.Developing, "49");
        require(tiers.tierOf(50) == WorkspaceTierRegistry.Tier.Moderate, "50");
        require(tiers.tierOf(69) == WorkspaceTierRegistry.Tier.Moderate, "69");
        require(tiers.tierOf(70) == WorkspaceTierRegistry.Tier.Strong, "70");
        require(tiers.tierOf(84) == WorkspaceTierRegistry.Tier.Strong, "84");
        require(tiers.tierOf(85) == WorkspaceTierRegistry.Tier.Excellent, "85");
        require(tiers.tierOf(100) == WorkspaceTierRegistry.Tier.Excellent, "100");

        // advanceRateBps all 4 tiers x pairHistory true/false.
        require(tiers.advanceRateBps(85, true) == 9000 && tiers.advanceRateBps(85, false) == 8500, "adv exc");
        require(tiers.advanceRateBps(70, true) == 8500 && tiers.advanceRateBps(70, false) == 8000, "adv str");
        require(tiers.advanceRateBps(50, true) == 7500 && tiers.advanceRateBps(50, false) == 7000, "adv mod");
        require(tiers.advanceRateBps(49, true) == 6000 && tiers.advanceRateBps(49, false) == 5500, "adv dev");

        // reserveRatioBps all 4 tiers.
        require(tiers.reserveRatioBps(85) == 1000, "res exc");
        require(tiers.reserveRatioBps(70) == 1500, "res str");
        require(tiers.reserveRatioBps(50) == 2000, "res mod");
        require(tiers.reserveRatioBps(49) == 2500, "res dev");

        // bondShareBps all 4 tiers.
        require(tiers.bondShareBps(49) == 10_000, "bond dev");
        require(tiers.bondShareBps(50) == 5_000, "bond mod");
        require(tiers.bondShareBps(70) == 0, "bond str");
        require(tiers.bondShareBps(85) == 0, "bond exc");

        // nonRecourseEligible matrix.
        require(tiers.nonRecourseEligible(70, 70, true), "nr true");
        require(!tiers.nonRecourseEligible(70, 70, false), "nr no pair");
        require(!tiers.nonRecourseEligible(69, 70, true), "nr weak seller");
        require(!tiers.nonRecourseEligible(70, 69, true), "nr weak debtor");

        // trancheEligibility matrix.
        require(tiers.trancheEligibility(85, 85, true) == WorkspaceTierRegistry.TrancheEligibility.SeniorA, "A");
        require(tiers.trancheEligibility(85, 85, false) == WorkspaceTierRegistry.TrancheEligibility.JuniorC, "C no pair");
        require(tiers.trancheEligibility(49, 85, true) == WorkspaceTierRegistry.TrancheEligibility.JuniorC, "C dev s");
        require(tiers.trancheEligibility(85, 49, true) == WorkspaceTierRegistry.TrancheEligibility.JuniorC, "C dev d");
        require(tiers.trancheEligibility(50, 85, true) == WorkspaceTierRegistry.TrancheEligibility.MezzB, "B mod s");
        require(tiers.trancheEligibility(85, 50, true) == WorkspaceTierRegistry.TrancheEligibility.MezzB, "B mod d");
        require(tiers.trancheEligibility(50, 50, true) == WorkspaceTierRegistry.TrancheEligibility.MezzB, "B both mod");

        // limitOf, debtorConcentrationCap, eligible, hasPairHistory.
        require(tiers.limitOf(sellerId) == 1_500e6, "L0");
        require(tiers.debtorConcentrationCap(sellerId) == 450e6, "30% of L0");
        require(tiers.eligible(sellerId), "eligible");
        require(!tiers.hasPairHistory(sellerId, debtorId), "no pair yet");

        vm.startPrank(admin);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), admin);
        reputation.recordOnTimeInstallment(sellerId, 250e6);
        reputation.recordPairSettlement(sellerId, debtorId);
        vm.stopPrank();
        require(tiers.limitOf(sellerId) == 1_750e6, "L0 + step");
        require(tiers.debtorConcentrationCap(sellerId) == 525e6, "30% of 1750");
        require(tiers.hasPairHistory(sellerId, debtorId), "pair recorded");

        // Ramp up to L_MAX_USDC cap across epochs.
        vm.startPrank(admin);
        uint256 t = block.timestamp;
        for (uint256 e = 0; e < 32; ++e) {
            t += Params.EPOCH_LENGTH;
            vm.warp(t);
            for (uint256 k = 0; k < 200; ++k) {
                if (!reputation.recordOnTimeInstallment(sellerId, 250e6)) break;
            }
            if (tiers.limitOf(sellerId) == Params.L_MAX_USDC) break;
        }
        require(tiers.limitOf(sellerId) == Params.L_MAX_USDC, "hit hard cap");

        // Permanent default zeroes limitOf and eligible.
        reputation.setPermanentDefault(sellerId);
        vm.stopPrank();
        require(tiers.limitOf(sellerId) == 0, "defaulted limit 0");
        require(!tiers.eligible(sellerId), "defaulted ineligible");
    }

    // ── 3. BIFTranche & BINV (kills all 9 mutants) ───────────────────────

    function test_Mut_BIFTranche_and_BINV_accessAndSoulbound() public {
        BIFTranche tr = shelf.tranches(0);
        vm.prank(rando);
        vm.expectRevert(BIFTranche.OnlyShelf.selector);
        tr.mint(rando, 1e18);
        vm.prank(rando);
        vm.expectRevert(BIFTranche.OnlyShelf.selector);
        tr.burn(lp, 1e18);

        BINV binv = shelf.BINV_TOKEN();
        BINV.DocBundle memory docs = BINV.DocBundle(keccak256("1"), keccak256("2"), keccak256("3"), keccak256("4"), keccak256("5"));
        vm.prank(rando);
        vm.expectRevert(BINV.OnlyShelf.selector);
        binv.mint(rando, 99, docs);
        vm.prank(rando);
        vm.expectRevert(BINV.OnlyShelf.selector);
        binv.burn(99);

        // Lock an invoice so BINV token 1 exists, then verify docBundleOf and Soulbound transfer block.
        uint64 fm = uint64(block.timestamp + 30 days);
        ReceivableCommitment.Terms memory terms = ReceivableCommitment.Terms(keccak256("binv-t1"), uint64(block.timestamp), fm + 30 days);
        FactoringEvidenceV1 memory ev = FactoringEvidenceV1(keccak256("f"), keccak256("c"), keccak256("p"));
        vm.prank(servicer);
        uint256 inv = shelf.lockInvoice(sellerId, debtorId, 200e6, 2, fm, 30 days, terms, ev, docs);
        require(inv == 1, "nextInvoiceId starts at 1");
        require(binv.docBundleOf(inv).invoiceDocHash == keccak256("1"), "docs stored");

        vm.prank(seller);
        vm.expectRevert(BINV.Soulbound.selector);
        binv.transferFrom(seller, rando, inv);

        vm.prank(seller);
        vm.expectRevert(BINV.Soulbound.selector);
        binv.safeTransferFrom(seller, rando, inv);
    }

    // ── 4. BUFIIdentityRegistry (kills all non-equivalent mutants) ───────

    function test_Mut_BUFIIdentityRegistry_rolesEventsAndExpiry() public {
        vm.expectRevert(BUFIIdentityRegistry.ZeroAddress.selector);
        new BUFIIdentityRegistry(address(0));

        BUFIIdentityRegistry idr = new BUFIIdentityRegistry(admin);
        vm.prank(admin);
        idr.grantRole(idr.ISSUER_ROLE(), admin);

        // Unauthorized reverts.
        bytes32 issuerRole = idr.ISSUER_ROLE();
        vm.prank(rando);
        _expectUnauthorized(rando, issuerRole);
        idr.registerWorkspace(keccak256("w"), seller);

        // Zero workspace / zero owner / duplicate.
        vm.startPrank(admin);
        vm.expectRevert(BUFIIdentityRegistry.ZeroWorkspaceId.selector);
        idr.registerWorkspace(bytes32(0), seller);
        vm.expectRevert(BUFIIdentityRegistry.ZeroAddress.selector);
        idr.registerWorkspace(keccak256("w"), address(0));

        vm.expectEmit(true, true, false, true, address(idr));
        emit IBUFIIdentityRegistry.WorkspaceRegistered(1, keccak256("w1"), seller);
        uint256 a1 = idr.registerWorkspace(keccak256("w1"), seller);
        require(a1 == 1, "first agentId must be 1");
        require(idr.agentIdOf(keccak256("w1")) == 1 && idr.workspaceOf(1) == keccak256("w1"), "lookup");
        require(idr.ownerOf(1) == seller && idr.exists(1) && !idr.exists(99), "exists/owner");

        vm.expectRevert(abi.encodeWithSelector(BUFIIdentityRegistry.AlreadyRegistered.selector, keccak256("w1")));
        idr.registerWorkspace(keccak256("w1"), seller);

        // Unauthorized setKybStatus (both overloads) & setWorkspaceOwner.
        vm.stopPrank();
        vm.startPrank(rando);
        _expectUnauthorized(rando, issuerRole);
        idr.setKybStatus(1, true);
        _expectUnauthorized(rando, issuerRole);
        idr.setKybStatus(1, true, uint64(block.timestamp + 1 days), 1, keccak256("op"));
        _expectUnauthorized(rando, issuerRole);
        idr.setWorkspaceOwner(1, rando);
        vm.stopPrank();

        // 5-arg KYB + event + stale version + expiry boundary.
        uint64 exp = uint64(block.timestamp + 10 days);
        vm.startPrank(admin);
        vm.expectEmit(true, false, false, true, address(idr));
        emit IBUFIIdentityRegistry.KybStatusSet(1, true);
        idr.setKybStatus(1, true, exp, 2, keccak256("opA"));
        require(idr.kybApproved(1), "approved before exp");

        vm.expectRevert(abi.encodeWithSelector(BUFIIdentityRegistry.StaleKybVersion.selector, uint64(2), uint64(2)));
        idr.setKybStatus(1, true, exp, 2, keccak256("opB"));

        vm.warp(exp);
        require(idr.kybApproved(1), "approved at exact exp");
        vm.warp(exp + 1);
        require(!idr.kybApproved(1), "expired after exp");

        // 2-arg KYB emits event; revoking clears validUntil; re-approving with validUntil==0 never expires.
        vm.expectEmit(true, false, false, true, address(idr));
        emit IBUFIIdentityRegistry.KybStatusSet(1, false);
        idr.setKybStatus(1, false);
        idr.setKybStatus(1, true);
        require(idr.kybApproved(1), "validUntil 0 non-expiring");

        // setWorkspaceOwner zero guard + event.
        vm.expectRevert(BUFIIdentityRegistry.ZeroAddress.selector);
        idr.setWorkspaceOwner(1, address(0));
        vm.expectEmit(true, false, false, true, address(idr));
        emit IBUFIIdentityRegistry.WorkspaceOwnerSet(1, debtor);
        idr.setWorkspaceOwner(1, debtor);
        require(idr.ownerOf(1) == debtor, "owner updated");

        // Unknown agent reverts on kybState.
        vm.expectRevert(abi.encodeWithSelector(BUFIIdentityRegistry.UnknownAgent.selector, 999));
        idr.kybState(999);
        vm.stopPrank();
    }

    // ── 5. BUFIReputationRegistry (kills all mutants) ────────────────────

    function test_Mut_BUFIReputationRegistry_rolesEventsAndGuards() public {
        vm.expectRevert(BUFIReputationRegistry.ZeroAddress.selector);
        new BUFIReputationRegistry(address(0), identity);
        vm.expectRevert(BUFIReputationRegistry.ZeroAddress.selector);
        new BUFIReputationRegistry(admin, IBUFIIdentityRegistry(address(0)));

        // Unauthorized callers revert.
        bytes32 attestorRole = reputation.ATTESTOR_ROLE();
        bytes32 repSettlementRole = reputation.SETTLEMENT_ROLE();
        bytes32 repOpsRole = reputation.OPS_ROLE();
        vm.startPrank(rando);
        _expectUnauthorized(rando, attestorRole);
        reputation.setScore(sellerId, 80, 80, 1, bytes32("x"));
        _expectUnauthorized(rando, repSettlementRole);
        reputation.recordOnTimeInstallment(sellerId, 250e6);
        _expectUnauthorized(rando, repSettlementRole);
        reputation.recordPairSettlement(sellerId, debtorId);
        _expectUnauthorized(rando, repSettlementRole);
        reputation.setPermanentDefault(sellerId);
        _expectUnauthorized(rando, repOpsRole);
        reputation.markRestructured(sellerId);
        vm.stopPrank();

        // ScoreOutOfRange individually on sellerScore > 100 and debtorScore > 100.
        vm.startPrank(admin);
        vm.expectRevert(BUFIReputationRegistry.ScoreOutOfRange.selector);
        reputation.setScore(sellerId, 101, 80, 1, bytes32("x"));
        vm.expectRevert(BUFIReputationRegistry.ScoreOutOfRange.selector);
        reputation.setScore(sellerId, 80, 101, 1, bytes32("x"));

        vm.expectEmit(true, false, false, true, address(reputation));
        emit IBUFIReputationRegistry.ScoreAttested(sellerId, 90, 95, 2);
        reputation.setScore(sellerId, 90, 95, 2, bytes32("feat"));
        IBUFIReputationRegistry.ScoreSnapshot memory snap = reputation.scoreOf(sellerId);
        require(snap.sellerScore == 90 && snap.debtorScore == 95 && snap.modelVersion == 2, "snap saved");

        // Grant admin SETTLEMENT_ROLE to test events directly.
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), admin);
        uint256 epoch = block.timestamp / Params.EPOCH_LENGTH;
        vm.expectEmit(true, false, false, true, address(reputation));
        emit IBUFIReputationRegistry.OnTimeInstallmentRecorded(sellerId, 1);
        vm.expectEmit(true, true, false, true, address(reputation));
        emit IBUFIReputationRegistry.OnTimeInstallmentObserved(sellerId, 250e6, epoch, true);
        require(reputation.recordOnTimeInstallment(sellerId, 250e6), "credited");

        // recordPairSettlement unknown debtor + event.
        vm.expectRevert(abi.encodeWithSelector(BUFIReputationRegistry.UnknownAgent.selector, 999));
        reputation.recordPairSettlement(sellerId, 999);
        vm.expectEmit(true, true, false, true, address(reputation));
        emit IBUFIReputationRegistry.PairHistoryRecorded(sellerId, debtorId, 1);
        reputation.recordPairSettlement(sellerId, debtorId);

        // markRestructured event + role split (OPS_ROLE only vs SETTLEMENT_ROLE only).
        reputation.grantRole(reputation.OPS_ROLE(), ops);
        vm.stopPrank();

        vm.expectEmit(true, false, false, true, address(reputation));
        emit IBUFIReputationRegistry.RestructuredMarked(sellerId, 1);
        vm.prank(ops);
        reputation.markRestructured(sellerId);

        // setPermanentDefault works with OPS_ROLE ONLY (no SETTLEMENT_ROLE) and emits event.
        vm.expectEmit(true, false, false, false, address(reputation));
        emit IBUFIReputationRegistry.PermanentDefaultSet(sellerId);
        vm.prank(ops);
        reputation.setPermanentDefault(sellerId);

        // Permanently defaulted agent rejects live writes.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(BUFIReputationRegistry.AgentPermanentlyDefaulted.selector, sellerId));
        reputation.setScore(sellerId, 50, 50, 3, bytes32("z"));
    }

    // ── 6. MultiTokenReceivableEscrow & RecibuMemoRouter (roles, events, reentrancy, balance) ──

    function test_Mut_EscrowAndRouter_rolesEventsBalanceAndReentrancy() public {
        // Constructor zero checks.
        vm.expectRevert(MultiTokenReceivableEscrow.ZeroAddress.selector);
        new MultiTokenReceivableEscrow(address(0));
        vm.expectRevert(RecibuMemoRouter.ZeroAddress.selector);
        new RecibuMemoRouter(IInvoiceShelf(address(0)), escrow, admin);
        vm.expectRevert(RecibuMemoRouter.ZeroAddress.selector);
        new RecibuMemoRouter(IInvoiceShelf(address(shelf)), MultiTokenReceivableEscrow(address(0)), admin);
        vm.expectRevert(RecibuMemoRouter.ZeroAddress.selector);
        new RecibuMemoRouter(IInvoiceShelf(address(shelf)), escrow, address(0));

        // Delay constants pinned.
        require(router.TOKEN_DISABLE_DELAY() == 1 days, "router delay 1d");
        require(router.TOKEN_DISABLE_WINDOW() == 7 days, "router window 7d");
        require(escrow.TOKEN_DISABLE_DELAY() == 1 days, "escrow delay 1d");
        require(escrow.TOKEN_DISABLE_WINDOW() == 7 days, "escrow window 7d");

        // Unauthorized role calls on Escrow & Router revert.
        vm.startPrank(rando);
        _expectUnauthorized(rando, escrow.DEFAULT_ADMIN_ROLE());
        escrow.setToken(address(usdc), true);
        _expectUnauthorized(rando, escrow.DEFAULT_ADMIN_ROLE());
        escrow.scheduleTokenDisable(address(usdc));
        _expectUnauthorized(rando, escrow.DEFAULT_ADMIN_ROLE());
        escrow.cancelTokenDisable(address(usdc));
        _expectUnauthorized(rando, escrow.DEFAULT_ADMIN_ROLE());
        escrow.setRefundLockDuration(1 hours);
        _expectUnauthorized(rando, escrow.ROUTER_ROLE());
        escrow.setRefundLock(1, uint64(block.timestamp + 1 hours));
        _expectUnauthorized(rando, escrow.SETTLEMENT_ROLE());
        escrow.releaseTo(1, rando, 1);
        _expectUnauthorized(rando, escrow.ARBITER_ROLE());
        escrow.refund(1, rando, 1);
        _expectUnauthorized(rando, router.DEFAULT_ADMIN_ROLE());
        router.scheduleTokenDisable(address(usdc));
        _expectUnauthorized(rando, router.DEFAULT_ADMIN_ROLE());
        router.cancelTokenDisable(address(usdc));
        _expectUnauthorized(rando, router.DEFAULT_ADMIN_ROLE());
        router.setToken(address(usdc), true, 3);
        vm.stopPrank();

        // Lock sample invoice.
        uint64 fm = uint64(block.timestamp + 30 days);
        ReceivableCommitment.Terms memory terms = ReceivableCommitment.Terms(keccak256("mut-esc-1"), uint64(block.timestamp), fm + 30 days);
        FactoringEvidenceV1 memory ev = FactoringEvidenceV1(keccak256("f"), keccak256("c"), keccak256("p"));
        BINV.DocBundle memory docs = BINV.DocBundle(keccak256("d"), keccak256("a"), keccak256("p"), keccak256("s"), keccak256("x"));
        vm.prank(servicer);
        uint256 inv = shelf.lockInvoice(sellerId, debtorId, 200e6, 2, fm, 30 days, terms, ev, docs);

        // CapabilityMissing on CAP_PERMIT & CAP_3009.
        MutMockToken noCaps = new MutMockToken("NoCaps", "NC");
        vm.startPrank(admin);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit MultiTokenReceivableEscrow.TokenSupported(address(noCaps), true);
        escrow.setToken(address(noCaps), true);
        vm.expectEmit(true, false, false, true, address(router));
        emit RecibuMemoRouter.TokenConfigured(address(noCaps), true, 0);
        router.setToken(address(noCaps), true, 0);
        vm.stopPrank();

        noCaps.mint(debtor, 100e6);
        vm.startPrank(debtor);
        vm.expectRevert(abi.encodeWithSelector(RecibuMemoRouter.CapabilityMissing.selector, address(noCaps), router.CAP_PERMIT()));
        router.payWithPermit(address(noCaps), debtor, inv, 0, 50e6, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(RecibuMemoRouter.CapabilityMissing.selector, address(noCaps), router.CAP_3009()));
        router.payWithAuthorization(address(noCaps), debtor, inv, 0, 50e6, 0, block.timestamp + 1 hours, bytes32(0), 27, bytes32(0), bytes32(0));
        vm.stopPrank();

        // Rebasing/bonus token (afterBal > before + amount) reverts BalanceMismatch on escrow & router!
        noCaps.setBonus(1);
        vm.startPrank(debtor);
        noCaps.approve(address(router), 50e6);
        vm.expectRevert(RecibuMemoRouter.BalanceMismatch.selector);
        router.pay(address(noCaps), inv, 0, 50e6);
        vm.stopPrank();

        // Direct escrow deposit BalanceMismatch for both fee (<) and bonus (>).
        vm.prank(admin);
        escrow.grantRole(escrow.ROUTER_ROLE(), admin);
        noCaps.mint(admin, 100e6);
        vm.startPrank(admin);
        noCaps.approve(address(escrow), 100e6);
        vm.expectRevert(MultiTokenReceivableEscrow.BalanceMismatch.selector);
        escrow.deposit(inv, address(noCaps), 50e6, admin);
        noCaps.setBonus(0);
        noCaps.setFee(1);
        vm.expectRevert(MultiTokenReceivableEscrow.BalanceMismatch.selector);
        escrow.deposit(inv, address(noCaps), 50e6, admin);
        vm.stopPrank();

        // Pay via payWithPermit (with permit fallback & RecibuPayment + Deposited + RefundLockSet events).
        usdc.mint(debtor, 200e6);
        usdc.setPermitReverts(true);
        vm.startPrank(debtor);
        usdc.approve(address(router), 200e6);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit MultiTokenReceivableEscrow.Deposited(inv, address(usdc), address(router), 50e6);
        vm.expectEmit(true, true, true, true, address(router));
        emit RecibuMemoRouter.RecibuPayment(inv, 0, router.memoIdOf(inv, 0), address(usdc), 50e6, debtor);
        router.payWithPermit(address(usdc), debtor, inv, 0, 50e6, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));
        vm.stopPrank();
        usdc.setPermitReverts(false);

        // Escrow _debit guards (ZeroAmount, InsufficientEscrow, ZeroAddress) + Released & Refunded events.
        vm.startPrank(settlement);
        vm.expectRevert(MultiTokenReceivableEscrow.ZeroAddress.selector);
        escrow.releaseTo(inv, address(0), 10e6);
        vm.expectRevert(MultiTokenReceivableEscrow.ZeroAmount.selector);
        escrow.releaseTo(inv, settlement, 0);
        vm.expectRevert(abi.encodeWithSelector(MultiTokenReceivableEscrow.InsufficientEscrow.selector, inv, 50e6, 51e6));
        escrow.releaseTo(inv, settlement, 51e6);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit MultiTokenReceivableEscrow.Released(inv, address(usdc), settlement, 20e6);
        escrow.releaseTo(inv, settlement, 20e6);
        require(escrow.escrowedOf(inv) == 30e6 && escrow.totalEscrowedOf(address(usdc)) == 30e6, "exact debit");
        vm.stopPrank();

        // Refund at exact unlockAt timestamp succeeds and emits Refunded.
        uint64 unlockAt = escrow.refundUnlockAt(inv);
        vm.warp(unlockAt);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit MultiTokenReceivableEscrow.Refunded(inv, address(usdc), debtor, 30e6);
        vm.prank(arbiter);
        escrow.refund(inv, debtor, 30e6);
        require(escrow.escrowedOf(inv) == 0 && escrow.totalEscrowedOf(address(usdc)) == 0, "exact refund");

        // Reentrancy checks on router.pay, router.payWithPermit, router.payWithAuthorization, escrow.deposit, releaseTo, refund.
        usdc.armReentry(address(router), abi.encodeWithSelector(router.pay.selector, address(usdc), inv, 0, 10e6));
        vm.prank(debtor);
        router.pay(address(usdc), inv, 0, 20e6);
        require(!usdc.reenterSucceeded() && bytes4(usdc.reenterError()) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "router.pay nonReentrant");

        usdc.armReentry(address(router), abi.encodeWithSelector(router.pay.selector, address(usdc), inv, 0, 10e6));
        vm.prank(debtor);
        router.payWithPermit(address(usdc), debtor, inv, 0, 20e6, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));
        require(!usdc.reenterSucceeded() && bytes4(usdc.reenterError()) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "router.payWithPermit nonReentrant");

        bytes32 authNonce = router.authorizationNonceOf(address(usdc), debtor, inv, 0, 20e6, 0, block.timestamp + 1 hours);
        usdc.armReentry(address(router), abi.encodeWithSelector(router.pay.selector, address(usdc), inv, 0, 10e6));
        router.payWithAuthorization(address(usdc), debtor, inv, 0, 20e6, 0, block.timestamp + 1 hours, authNonce, 27, bytes32(0), bytes32(0));
        require(!usdc.reenterSucceeded() && bytes4(usdc.reenterError()) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "router.payWithAuth nonReentrant");

        // Escrow deposit / releaseTo / refund nonReentrant checks.
        vm.prank(admin);
        escrow.grantRole(escrow.ROUTER_ROLE(), address(usdc));
        vm.prank(admin);
        escrow.grantRole(escrow.SETTLEMENT_ROLE(), address(usdc));
        vm.prank(admin);
        escrow.grantRole(escrow.ARBITER_ROLE(), address(usdc));
        usdc.mint(address(usdc), 100e6);
        vm.prank(address(usdc));
        usdc.approve(address(escrow), 100e6);

        usdc.armReentry(address(escrow), abi.encodeWithSelector(escrow.deposit.selector, inv, address(usdc), 1e6, address(usdc)));
        vm.prank(debtor);
        router.pay(address(usdc), inv, 0, 10e6);
        // Note: router's transferFrom triggers usdc._update first (inside router.pay, not inside escrow.deposit).
        // Trigger reentrancy directly inside escrow.deposit, releaseTo, and refund!
        usdc.mint(admin, 20e6);
        vm.prank(admin);
        usdc.approve(address(escrow), 20e6);
        usdc.armReentry(address(escrow), abi.encodeWithSelector(escrow.deposit.selector, inv, address(usdc), 1e6, address(usdc)));
        vm.prank(admin);
        escrow.deposit(inv, address(usdc), 10e6, admin);
        require(!usdc.reenterSucceeded() && bytes4(usdc.reenterError()) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "escrow.deposit nonReentrant");

        usdc.armReentry(address(escrow), abi.encodeWithSelector(escrow.releaseTo.selector, inv, settlement, 1e6));
        vm.prank(settlement);
        escrow.releaseTo(inv, settlement, 10e6);
        require(!usdc.reenterSucceeded() && bytes4(usdc.reenterError()) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "escrow.releaseTo nonReentrant");

        vm.warp(escrow.refundUnlockAt(inv));
        usdc.armReentry(address(escrow), abi.encodeWithSelector(escrow.refund.selector, inv, debtor, 1e6));
        vm.prank(arbiter);
        escrow.refund(inv, debtor, 10e6);
        require(!usdc.reenterSucceeded() && bytes4(usdc.reenterError()) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "escrow.refund nonReentrant");
    }

    // ── 7. InvoiceShelf: lock validation, bond gate, remainder installments, events, midnight ──

    function test_Mut_InvoiceShelf_lockValidationBondGateAndScheduleMath() public {
        require(shelf.DEFAULT_CROSS_CHAIN_BUFFER() == 6 hours, "default buffer 6h");

        // setReserve / setEscrow role, zero, already-set checks.
        vm.startPrank(rando);
        _expectUnauthorized(rando, shelf.DEFAULT_ADMIN_ROLE());
        shelf.setReserve(reserve);
        _expectUnauthorized(rando, shelf.DEFAULT_ADMIN_ROLE());
        shelf.setEscrow(address(escrow));
        vm.stopPrank();

        vm.startPrank(admin);
        vm.expectRevert(InvoiceShelf.ReserveAlreadySet.selector);
        shelf.setReserve(reserve);
        vm.expectRevert(InvoiceShelf.EscrowAlreadySet.selector);
        shelf.setEscrow(address(escrow));
        vm.stopPrank();

        InvoiceShelf fresh = new InvoiceShelf(usdc, identity, reputation, tiers, admin, false);
        vm.startPrank(admin);
        vm.expectRevert(InvoiceShelf.ZeroAddress.selector);
        fresh.setReserve(WorkspaceOperatingReserve(address(0)));
        vm.expectRevert(InvoiceShelf.ZeroAddress.selector);
        fresh.setEscrow(address(0));
        vm.stopPrank();

        uint64 fm = uint64(block.timestamp + 30 days);
        ReceivableCommitment.Terms memory terms = ReceivableCommitment.Terms(keccak256("val-1"), uint64(block.timestamp), fm + 30 days);
        FactoringEvidenceV1 memory ev = FactoringEvidenceV1(keccak256("f"), keccak256("c"), keccak256("p"));
        BINV.DocBundle memory docs = BINV.DocBundle(keccak256("d"), keccak256("a"), keccak256("p"), keccak256("s"), keccak256("x"));

        // Unauthorized lockInvoice reverts.
        bytes32 servicerRole = shelf.SERVICER_ROLE();
        _expectUnauthorized(rando, servicerRole);
        vm.prank(rando);
        shelf.lockInvoice(sellerId, debtorId, 200e6, 2, fm, 30 days, terms, ev, docs);

        // Schedule bounds individually.
        vm.startPrank(servicer);
        vm.expectRevert(InvoiceShelf.BadSchedule.selector);
        shelf.lockInvoice(sellerId, debtorId, 200e6, 1, fm, 30 days, terms, ev, docs);
        vm.expectRevert(InvoiceShelf.BadSchedule.selector);
        shelf.lockInvoice(sellerId, debtorId, 200e6, 13, fm, 30 days, terms, ev, docs);
        vm.expectRevert(InvoiceShelf.BadSchedule.selector);
        shelf.lockInvoice(sellerId, debtorId, 200e6, 2, fm, 7 days - 1, terms, ev, docs);
        vm.expectRevert(InvoiceShelf.BadSchedule.selector);
        shelf.lockInvoice(sellerId, debtorId, 200e6, 2, uint64(block.timestamp), 30 days, terms, ev, docs);

        // Incomplete docs individually (all 5 fields).
        vm.expectRevert(InvoiceShelf.IncompleteDocumentBundle.selector);
        shelf.lockInvoice(
            sellerId,
            debtorId,
            200e6,
            2,
            fm,
            30 days,
            terms,
            ev,
            BINV.DocBundle(bytes32(0), keccak256("a"), keccak256("p"), keccak256("s"), keccak256("x"))
        );
        vm.expectRevert(InvoiceShelf.IncompleteDocumentBundle.selector);
        shelf.lockInvoice(
            sellerId,
            debtorId,
            200e6,
            2,
            fm,
            30 days,
            terms,
            ev,
            BINV.DocBundle(keccak256("d"), bytes32(0), keccak256("p"), keccak256("s"), keccak256("x"))
        );
        vm.expectRevert(InvoiceShelf.IncompleteDocumentBundle.selector);
        shelf.lockInvoice(
            sellerId,
            debtorId,
            200e6,
            2,
            fm,
            30 days,
            terms,
            ev,
            BINV.DocBundle(keccak256("d"), keccak256("a"), bytes32(0), keccak256("s"), keccak256("x"))
        );
        vm.expectRevert(InvoiceShelf.IncompleteDocumentBundle.selector);
        shelf.lockInvoice(
            sellerId,
            debtorId,
            200e6,
            2,
            fm,
            30 days,
            terms,
            ev,
            BINV.DocBundle(keccak256("d"), keccak256("a"), keccak256("p"), bytes32(0), keccak256("x"))
        );
        vm.expectRevert(InvoiceShelf.IncompleteDocumentBundle.selector);
        shelf.lockInvoice(
            sellerId,
            debtorId,
            200e6,
            2,
            fm,
            30 days,
            terms,
            ev,
            BINV.DocBundle(keccak256("d"), keccak256("a"), keccak256("p"), keccak256("s"), bytes32(0))
        );

        // Incomplete evidence individually (all 3 fields).
        vm.expectRevert(InvoiceShelf.IncompleteFactoringEvidence.selector);
        shelf.lockInvoice(
            sellerId,
            debtorId,
            200e6,
            2,
            fm,
            30 days,
            terms,
            FactoringEvidenceV1(bytes32(0), keccak256("c"), keccak256("p")),
            docs
        );
        vm.expectRevert(InvoiceShelf.IncompleteFactoringEvidence.selector);
        shelf.lockInvoice(
            sellerId,
            debtorId,
            200e6,
            2,
            fm,
            30 days,
            terms,
            FactoringEvidenceV1(keccak256("f"), bytes32(0), keccak256("p")),
            docs
        );
        vm.expectRevert(InvoiceShelf.IncompleteFactoringEvidence.selector);
        shelf.lockInvoice(
            sellerId,
            debtorId,
            200e6,
            2,
            fm,
            30 days,
            terms,
            FactoringEvidenceV1(keccak256("f"), keccak256("c"), bytes32(0)),
            docs
        );

        // Issue/due date guards.
        vm.expectRevert(InvoiceShelf.IncompleteReceivableIdentity.selector);
        shelf.lockInvoice(
            sellerId,
            debtorId,
            200e6,
            2,
            fm,
            30 days,
            ReceivableCommitment.Terms(bytes32(0), uint64(block.timestamp), fm + 30 days),
            ev,
            docs
        );

        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.InvalidIssueDate.selector, uint64(0), block.timestamp));
        shelf.lockInvoice(
            sellerId,
            debtorId,
            200e6,
            2,
            fm,
            30 days,
            ReceivableCommitment.Terms(keccak256("val-1"), 0, fm + 30 days),
            ev,
            docs
        );

        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.InvalidIssueDate.selector, uint64(block.timestamp + 1), block.timestamp)
        );
        shelf.lockInvoice(
            sellerId,
            debtorId,
            200e6,
            2,
            fm,
            30 days,
            ReceivableCommitment.Terms(keccak256("val-1"), uint64(block.timestamp + 1), fm + 30 days),
            ev,
            docs
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceShelf.InvalidDueDate.selector, uint64(block.timestamp), uint64(block.timestamp)
            )
        );
        shelf.lockInvoice(
            sellerId,
            debtorId,
            200e6,
            2,
            fm,
            30 days,
            ReceivableCommitment.Terms(keccak256("val-1"), uint64(block.timestamp), uint64(block.timestamp)),
            ev,
            docs
        );

        vm.expectRevert(
            abi.encodeWithSelector(InvoiceShelf.ScheduleDueMismatch.selector, fm + 30 days + 1, fm + 30 days)
        );
        shelf.lockInvoice(
            sellerId,
            debtorId,
            200e6,
            2,
            fm,
            30 days,
            ReceivableCommitment.Terms(keccak256("val-1"), uint64(block.timestamp), fm + 30 days + 1),
            ev,
            docs
        );
        vm.stopPrank();

        // Bond gate math & GRACE_WEAK vs GRACE_STRONG!
        vm.startPrank(admin);
        uint256 devSeller = identity.registerWorkspace(keccak256("dev-s"), address(0xDE01));
        identity.setKybStatus(devSeller, true, uint64(block.timestamp + 365 days), 1, keccak256("op-ds"));
        reputation.setScore(devSeller, 40, 40, 1, bytes32("ds")); // Developing -> 25% reserve, 100% bond, GRACE_WEAK (3d)
        vm.stopPrank();

        // face = 1001 across 3 installments -> 333, 333, 335! Advance for debtorScore=90 (no pair, 8500bps) = 850.
        // Required bond = 850 * 2500 / 10000 * 10000 / 10000 = 212!
        ReceivableCommitment.Terms memory t3 = ReceivableCommitment.Terms(keccak256("val-3inst"), uint64(block.timestamp), fm + 60 days);
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.BondNotPosted.selector, uint256(212), uint256(0)));
        shelf.lockInvoice(devSeller, debtorId, 1001, 3, fm, 30 days, t3, ev, docs);

        usdc.mint(address(0xDE01), 212);
        vm.startPrank(address(0xDE01));
        usdc.approve(address(reserve), 212);
        reserve.postBond(devSeller, 212);
        vm.stopPrank();

        uint256 liqBefore = shelf.totalLiquid();
        bytes32 expectedComm = shelf.computeReceivableCommitment(devSeller, debtorId, 1001, t3, docs.assignmentHash);
        bytes32 expectedAuth = shelf.computeAuthorityInvoiceId(t3.canonicalInvoiceCommitmentHash);
        vm.expectEmit(true, true, true, true, address(shelf));
        emit InvoiceShelf.ReceivableCommitmentConsumed(expectedComm, 1, ReceivableCommitment.hashDocumentBundle(docs));
        vm.expectEmit(true, true, false, false, address(shelf));
        emit InvoiceShelf.AuthorityInvoiceIdConsumed(expectedAuth, 1);
        vm.expectEmit(true, true, true, true, address(shelf));
        emit InvoiceShelf.FactoringEvidenceBound(1, ev.featureRootHash, ev.currentSnapshotHash, ev.privateTermsHash);
        vm.expectEmit(true, true, true, true, address(shelf));
        emit InvoiceShelf.InvoiceLocked(1, devSeller, debtorId, 1001, 850, 2);
        vm.prank(servicer);
        uint256 inv = shelf.lockInvoice(devSeller, debtorId, 1001, 3, fm, 30 days, t3, ev, docs);

        require(shelf.totalLiquid() == liqBefore - 850, "totalLiquid decremented");
        require(shelf.graceOf(inv) == Params.GRACE_WEAK, "weak grace 3d");
        require(shelf.installmentAmount(inv, 0) == 333, "inst 0");
        require(shelf.installmentAmount(inv, 1) == 333, "inst 1");
        require(shelf.installmentAmount(inv, 2) == 335, "inst 2 with remainder");
        require(shelf.dueDate(inv) == uint256(fm) + 60 days, "dueDate last installment");
        require(shelf.debtorPayerOf(inv) == debtor, "debtorPayerOf");
        require(!shelf.isLate(inv), "not late yet");
        (uint8 idx, uint256 fullAmt, uint256 paidAmt, uint256 mat, uint256 gEnd) = shelf.currentInstallment(inv);
        require(idx == 0 && fullAmt == 333 && paidAmt == 0 && mat == fm && gEnd == fm + Params.GRACE_WEAK, "currentInstallment");

        // Pay all 3 installments and verify events, holdback release, and exposure cleanup.
        usdc.mint(servicer, 1001);
        vm.startPrank(servicer);
        usdc.approve(address(shelf), 1001);
        vm.expectEmit(true, true, false, true, address(shelf));
        emit InvoiceShelf.InstallmentPaymentApplied(inv, 0, 333, 333, 333);
        vm.expectEmit(true, false, false, true, address(shelf));
        emit InvoiceShelf.InstallmentPaid(inv, 0, 333, false);
        shelf.applyPayment(inv, 333);
        shelf.applyPayment(inv, 333);
        vm.expectEmit(true, false, false, true, address(shelf));
        emit InvoiceShelf.InvoiceSettled(inv, 151, 0);
        shelf.applyPayment(inv, 335);
        vm.stopPrank();

        require(shelf.outstandingOf(devSeller) == 0 && shelf.debtorOutstandingOf(devSeller, debtorId) == 0, "exposure 0");
        require(shelf.totalLiquid() == liqBefore, "liquid restored");
        require(shelf.totalHoldbackHeld() == 0, "holdback released");
        require(reserve.requiredOf(devSeller) == 0, "bond floor released");
        require(!shelf.isLate(inv), "settled is not late");

        // Velocity cap: 10 advances per epoch, 11th reverts VelocityCapExceeded, next epoch succeeds!
        vm.startPrank(admin);
        for (uint256 i = 0; i < 10; ++i) {
            uint256 di = identity.registerWorkspace(keccak256(abi.encodePacked("vel-d-", i)), address(uint160(0xB000 + i)));
            identity.setKybStatus(di, true, uint64(block.timestamp + 365 days), 1, keccak256(abi.encodePacked("vop-", i)));
            reputation.setScore(di, 80, 90, 1, bytes32("d"));
            vm.stopPrank();
            ReceivableCommitment.Terms memory tv = ReceivableCommitment.Terms(keccak256(abi.encodePacked("vel-t-", i)), uint64(block.timestamp), fm + 30 days);
            vm.prank(servicer);
            shelf.lockInvoice(sellerId, di, 100e6, 2, fm, 30 days, tv, ev, docs);
            vm.startPrank(admin);
        }
        uint256 d11 = identity.registerWorkspace(keccak256("vel-d-11"), address(0xB011));
        identity.setKybStatus(d11, true, uint64(block.timestamp + 365 days), 1, keccak256("vop-11"));
        reputation.setScore(d11, 80, 90, 1, bytes32("d"));
        vm.stopPrank();
        ReceivableCommitment.Terms memory tv11 = ReceivableCommitment.Terms(keccak256("vel-t-11"), uint64(vm.getBlockTimestamp()), fm + 30 days);
        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.VelocityCapExceeded.selector, sellerId));
        shelf.lockInvoice(sellerId, d11, 100e6, 2, fm, 30 days, tv11, ev, docs);

        // Next epoch resets velocity counter; moderate seller second lock tests cumulative bond floor math (`current + advance`).
        uint64 nextEp = uint64(vm.getBlockTimestamp()) + Params.EPOCH_LENGTH;
        vm.warp(nextEp);
        ReceivableCommitment.Terms memory tv12 = ReceivableCommitment.Terms(keccak256("vel-t-12"), nextEp, nextEp + 60 days);
        vm.prank(servicer);
        shelf.lockInvoice(sellerId, d11, 100e6, 2, nextEp + 30 days, 30 days, tv12, ev, docs);

        vm.startPrank(admin);
        uint256 modS = identity.registerWorkspace(keccak256("mod-s-bond"), address(0xDE02));
        identity.setKybStatus(modS, true, nextEp + 365 days, 1, keccak256("op-msb"));
        reputation.setScore(modS, 60, 60, 1, bytes32("ms")); // Moderate: 20% reserve, 50% bond = 10% floor
        uint256 dM1 = identity.registerWorkspace(keccak256("mod-d-1"), address(0xD001));
        uint256 dM2 = identity.registerWorkspace(keccak256("mod-d-2"), address(0xD002));
        identity.setKybStatus(dM1, true, nextEp + 365 days, 1, keccak256("op-dm1"));
        identity.setKybStatus(dM2, true, nextEp + 365 days, 1, keccak256("op-dm2"));
        reputation.setScore(dM1, 80, 90, 1, bytes32("d1"));
        reputation.setScore(dM2, 80, 90, 1, bytes32("d2"));
        vm.stopPrank();

        // Advance per 200e6 invoice = 170e6; 1st floor = 17e6, 2nd cumulative floor = 34e6.
        usdc.mint(address(0xDE02), 34e6);
        vm.startPrank(address(0xDE02));
        usdc.approve(address(reserve), 34e6);
        reserve.postBond(modS, 17e6);
        vm.stopPrank();
        vm.prank(servicer);
        shelf.lockInvoice(
            modS,
            dM1,
            200e6,
            2,
            nextEp + 30 days,
            30 days,
            ReceivableCommitment.Terms(keccak256("mod-inv-1"), nextEp, nextEp + 60 days),
            ev,
            docs
        );
        require(reserve.requiredOf(modS) == 17e6, "1st bond floor 17e6");

        vm.prank(servicer);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.BondNotPosted.selector, uint256(34e6), uint256(17e6)));
        shelf.lockInvoice(
            modS,
            dM2,
            200e6,
            2,
            nextEp + 30 days,
            30 days,
            ReceivableCommitment.Terms(keccak256("mod-inv-2"), nextEp, nextEp + 60 days),
            ev,
            docs
        );

        vm.prank(address(0xDE02));
        reserve.postBond(modS, 17e6);
        vm.prank(servicer);
        shelf.lockInvoice(
            modS,
            dM2,
            200e6,
            2,
            nextEp + 30 days,
            30 days,
            ReceivableCommitment.Terms(keccak256("mod-inv-2"), nextEp, nextEp + 60 days),
            ev,
            docs
        );
        require(reserve.requiredOf(modS) == 34e6, "2nd cumulative bond floor 34e6");
    }

    // ── 8. InvoiceShelf: Midnight accounting + CrossChainBuffer + Reentrancy ──

    function test_Mut_InvoiceShelf_midnightAccountingAndBuffer() public {
        InvoiceShelf mShelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin, true);
        vm.startPrank(admin);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(mShelf));
        mShelf.grantRole(mShelf.SERVICER_ROLE(), servicer);
        mShelf.grantRole(mShelf.ADVANCE_ROLE(), settlement);
        vm.stopPrank();

        // CrossChainBuffer role, upper bound, event, and lateAfter difference.
        bytes32 adminRole = mShelf.DEFAULT_ADMIN_ROLE();
        _expectUnauthorized(rando, adminRole);
        vm.prank(rando);
        mShelf.setCrossChainBuffer(1 hours);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.BufferTooLarge.selector, uint32(3 days + 1)));
        mShelf.setCrossChainBuffer(3 days + 1);
        vm.expectEmit(false, false, false, true, address(mShelf));
        emit InvoiceShelf.CrossChainBufferSet(6 hours, 12 hours);
        mShelf.setCrossChainBuffer(12 hours);
        vm.stopPrank();

        uint64 fm = uint64(block.timestamp + 30 days);
        ReceivableCommitment.Terms memory terms = ReceivableCommitment.Terms(keccak256("mid-1"), uint64(block.timestamp), fm + 30 days);
        FactoringEvidenceV1 memory ev = FactoringEvidenceV1(keccak256("f"), keccak256("c"), keccak256("p"));
        BINV.DocBundle memory docs = BINV.DocBundle(keccak256("d"), keccak256("a"), keccak256("p"), keccak256("s"), keccak256("x"));

        // Non-midnight bindAdvance reverts MidnightOnly.
        vm.prank(servicer);
        uint256 stdInv = shelf.lockInvoice(sellerId, debtorId, 200e6, 2, fm, 30 days, terms, ev, docs);
        bytes32 advRole = shelf.ADVANCE_ROLE();
        vm.prank(admin);
        shelf.grantRole(advRole, settlement);
        vm.prank(settlement);
        vm.expectRevert(InvoiceShelf.MidnightOnly.selector);
        shelf.bindAdvance(stdInv, address(0x1), keccak256("m"), fm + 90 days, 100, 100, 0, bytes32(0));

        // Lock in Midnight shelf and verify lateAfter includes crossChainBuffer (12 hours) while std does not!
        vm.prank(servicer);
        uint256 inv = mShelf.lockInvoice(sellerId, debtorId, 200e6, 2, fm, 30 days, terms, ev, docs);
        require(mShelf.lateAfter(inv, fm) == uint256(fm) + Params.GRACE_STRONG + 12 hours, "midnight lateAfter + buffer");
        require(shelf.lateAfter(stdInv, fm) == uint256(fm) + Params.GRACE_STRONG, "std lateAfter no buffer");
        require(mShelf.dueDate(0) == 0, "unknown invoice dueDate 0");

        // bindAdvance guards (role, status, zero args, maturity < dueWithGrace, duplicate, event).
        bytes32 mAdvRole = mShelf.ADVANCE_ROLE();
        _expectUnauthorized(rando, mAdvRole);
        vm.prank(rando);
        mShelf.bindAdvance(inv, address(0x1), keccak256("m"), fm + 90 days, 100, 100, 0, bytes32(0));

        vm.startPrank(settlement);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.BadStatus.selector, 999));
        mShelf.bindAdvance(999, address(0x1), keccak256("m"), fm + 90 days, 100, 100, 0, bytes32(0));
        vm.expectRevert(InvoiceShelf.BadAdvance.selector);
        mShelf.bindAdvance(inv, address(0), keccak256("m"), fm + 90 days, 100, 100, 0, bytes32(0));
        vm.expectRevert(InvoiceShelf.BadAdvance.selector);
        mShelf.bindAdvance(inv, address(0x1), bytes32(0), fm + 90 days, 100, 100, 0, bytes32(0));
        vm.expectRevert(InvoiceShelf.BadAdvance.selector);
        mShelf.bindAdvance(inv, address(0x1), keccak256("m"), fm + 90 days, 0, 100, 0, bytes32(0));

        uint256 dueWithGrace = mShelf.lateAfter(inv, mShelf.dueDate(inv));
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.MaturityBeforeDue.selector, uint64(dueWithGrace - 1), dueWithGrace));
        mShelf.bindAdvance(inv, address(0x1), keccak256("m"), uint64(dueWithGrace - 1), 100, 100, 0, bytes32(0));

        // Unbound advance calls revert AdvanceNotBound.
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.AdvanceNotBound.selector, inv));
        mShelf.recordAdvanceRepaid(inv, 10, keccak256("memo"));
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.AdvanceNotBound.selector, inv));
        mShelf.recordAdvanceRolledToBlue(inv, keccak256("blue"));

        vm.expectEmit(true, true, true, true, address(mShelf));
        emit InvoiceShelf.AdvanceOriginated(inv, address(0xACC1), keccak256("m1"), 100, 95e6, uint64(dueWithGrace), 500, keccak256("sc"));
        mShelf.bindAdvance(inv, address(0xACC1), keccak256("m1"), uint64(dueWithGrace), 100, 95e6, 500, keccak256("sc"));

        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.AdvanceAlreadyBound.selector, inv));
        mShelf.bindAdvance(inv, address(0xACC1), keccak256("m1"), uint64(dueWithGrace), 100, 95e6, 500, keccak256("sc"));

        // recordAdvanceRepaid, recordRepaymentSettled, recordAdvanceLiquidated, recordAdvanceRolledToBlue + guards & events.
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.UnitsExceedOpen.selector, 0, 100));
        mShelf.recordAdvanceRepaid(inv, 0, keccak256("m"));
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.UnitsExceedOpen.selector, 101, 100));
        mShelf.recordAdvanceRepaid(inv, 101, keccak256("m"));

        vm.expectEmit(true, true, true, true, address(mShelf));
        emit InvoiceShelf.AdvanceRepaid(inv, address(0xACC1), keccak256("m1"), 30, keccak256("memo1"));
        mShelf.recordAdvanceRepaid(inv, 30, keccak256("memo1"));

        vm.expectRevert(InvoiceShelf.BadAdvance.selector);
        mShelf.recordRepaymentSettled(inv, 20, 20e6, 1, bytes32(0), keccak256("memo2"));

        vm.expectEmit(true, true, true, true, address(mShelf));
        emit InvoiceShelf.RepaymentSettled(inv, keccak256("m1"), keccak256("msg2"), 1, 20e6, 20, keccak256("memo2"));
        vm.expectEmit(true, true, true, true, address(mShelf));
        emit InvoiceShelf.AdvanceRepaid(inv, address(0xACC1), keccak256("m1"), 20, keccak256("memo2"));
        mShelf.recordRepaymentSettled(inv, 20, 20e6, 1, keccak256("msg2"), keccak256("memo2"));

        vm.expectEmit(true, true, true, true, address(mShelf));
        emit InvoiceShelf.AdvanceLiquidated(inv, address(0xACC1), keccak256("m1"), 50, 45e6, address(usdc), 5e6);
        mShelf.recordAdvanceLiquidated(inv, 50, 45e6, address(usdc), 5e6);

        (,,,, uint128 repaidTotal) = mShelf.advanceOf(inv);
        require(repaidTotal == 100, "all 100 units accounted");

        vm.expectEmit(true, true, true, false, address(mShelf));
        emit InvoiceShelf.AdvanceRolledToBlue(inv, address(0xACC1), keccak256("blue1"));
        mShelf.recordAdvanceRolledToBlue(inv, keccak256("blue1"));
        vm.stopPrank();

        // Unauthorized role reverts on all 4 Midnight recording functions.
        vm.startPrank(rando);
        _expectUnauthorized(rando, mShelf.ADVANCE_ROLE());
        mShelf.recordAdvanceRepaid(inv, 1, bytes32(0));
        _expectUnauthorized(rando, mShelf.ADVANCE_ROLE());
        mShelf.recordRepaymentSettled(inv, 1, 1, 1, keccak256("x"), bytes32(0));
        _expectUnauthorized(rando, mShelf.ADVANCE_ROLE());
        mShelf.recordAdvanceLiquidated(inv, 1, 1, address(usdc), 0);
        _expectUnauthorized(rando, mShelf.ADVANCE_ROLE());
        mShelf.recordAdvanceRolledToBlue(inv, keccak256("b"));
        vm.stopPrank();
    }

    function test_Mut_InvoiceShelf_nonReentrantGuardsAndRoleChecks() public {
        // Unauthorized applyPayment, applyPaymentFrom, notifyCrossChainRepayment, markDefaulted, resolveDefault.
        vm.startPrank(rando);
        _expectUnauthorized(rando, shelf.SERVICER_ROLE());
        shelf.applyPayment(1, 1);
        _expectUnauthorized(rando, shelf.SETTLEMENT_ROLE());
        shelf.applyPaymentFrom(1, 1, rando);
        _expectUnauthorized(rando, shelf.SERVICER_ROLE());
        shelf.notifyCrossChainRepayment(1, keccak256("x"));
        _expectUnauthorized(rando, shelf.SERVICER_ROLE());
        shelf.markDefaulted(1);
        _expectUnauthorized(rando, shelf.OPS_ROLE());
        shelf.resolveDefault(1, false);
        vm.stopPrank();

        // depositTranche nonReentrant check + event.
        usdc.mint(address(usdc), 20_000e6);
        vm.prank(address(usdc));
        usdc.approve(address(shelf), 20_000e6);
        usdc.armReentry(address(shelf), abi.encodeWithSelector(shelf.depositTranche.selector, 2, 1_000e6));
        vm.expectEmit(true, true, false, true, address(shelf));
        emit InvoiceShelf.TrancheDeposit(2, lp, 10_000e6, 10_000e18);
        vm.prank(lp);
        shelf.depositTranche(2, 10_000e6);
        require(!usdc.reenterSucceeded() && bytes4(usdc.reenterError()) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "depositTranche nonReentrant");

        // lockInvoice nonReentrant check.
        uint64 fm = uint64(block.timestamp + 30 days);
        ReceivableCommitment.Terms memory terms = ReceivableCommitment.Terms(keccak256("re-lock"), uint64(block.timestamp), fm + 30 days);
        FactoringEvidenceV1 memory ev = FactoringEvidenceV1(keccak256("f"), keccak256("c"), keccak256("p"));
        BINV.DocBundle memory docs = BINV.DocBundle(keccak256("d"), keccak256("a"), keccak256("p"), keccak256("s"), keccak256("x"));

        vm.startPrank(admin);
        shelf.grantRole(shelf.SERVICER_ROLE(), address(usdc));
        shelf.grantRole(shelf.SETTLEMENT_ROLE(), address(usdc));
        vm.stopPrank();

        usdc.armReentry(address(shelf), abi.encodeWithSelector(shelf.applyPayment.selector, 1, 1));
        vm.prank(servicer);
        uint256 inv = shelf.lockInvoice(sellerId, debtorId, 200e6, 2, fm, 30 days, terms, ev, docs);
        require(!usdc.reenterSucceeded() && bytes4(usdc.reenterError()) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "lockInvoice nonReentrant");

        // applyPayment & applyPaymentFrom nonReentrant checks.
        usdc.mint(servicer, 100e6);
        vm.prank(servicer);
        usdc.approve(address(shelf), 100e6);
        usdc.armReentry(address(shelf), abi.encodeWithSelector(shelf.applyPayment.selector, inv, 1));
        vm.prank(servicer);
        shelf.applyPayment(inv, 50e6);
        require(!usdc.reenterSucceeded() && bytes4(usdc.reenterError()) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "applyPayment nonReentrant");

        usdc.mint(settlement, 100e6);
        vm.prank(settlement);
        usdc.approve(address(shelf), 100e6);
        usdc.armReentry(address(shelf), abi.encodeWithSelector(shelf.applyPaymentFrom.selector, inv, 1, address(usdc)));
        vm.prank(settlement);
        shelf.applyPaymentFrom(inv, 50e6, settlement);
        require(!usdc.reenterSucceeded() && bytes4(usdc.reenterError()) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "applyPaymentFrom nonReentrant");

        // markDefaulted nonReentrant check (via reserve.sweepFor transfer) + isLate true + events.
        usdc.mint(seller, 10e6);
        vm.startPrank(seller);
        usdc.approve(address(reserve), 10e6);
        reserve.postBond(sellerId, 10e6);
        vm.stopPrank();
        uint256 lateTs = shelf.lateAfter(inv, shelf.installmentDue(inv, 1)) + 1;
        vm.warp(lateTs);
        require(shelf.isLate(inv), "funded past grace isLate == true");

        bytes32 bn = keccak256("mut-bn-1");
        vm.expectEmit(true, true, false, true, address(shelf));
        emit InvoiceShelf.CrossChainRepaymentNotified(inv, bn, uint64(lateTs + shelf.crossChainBuffer()));
        vm.prank(servicer);
        shelf.notifyCrossChainRepayment(inv, bn);

        vm.warp(lateTs + shelf.crossChainBuffer() + 1);
        usdc.armReentry(address(shelf), abi.encodeWithSelector(shelf.markDefaulted.selector, inv));
        vm.expectEmit(true, false, false, true, address(shelf));
        emit InvoiceShelf.LossAllocated(2, 60e6);
        vm.expectEmit(true, false, false, false, address(shelf));
        emit InvoiceShelf.WorkspaceFrozen(sellerId);
        vm.expectEmit(true, false, false, true, address(shelf));
        emit InvoiceShelf.InvoiceDefaulted(inv, 60e6);
        vm.prank(servicer);
        shelf.markDefaulted(inv);
        require(!usdc.reenterSucceeded() && bytes4(usdc.reenterError()) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "markDefaulted nonReentrant");

        // recoverDefault nonReentrant check + LossRecovered & DefaultResolved events.
        uint256 loss = shelf.unrecoveredLossOf(inv);
        require(loss == 60e6, "170 advance - 100 paid - 10 reserve = 60 loss");
        usdc.mint(address(this), loss);
        usdc.approve(address(shelf), loss);
        usdc.armReentry(address(shelf), abi.encodeWithSelector(shelf.recoverDefault.selector, inv, 1));
        vm.expectEmit(true, true, true, true, address(shelf));
        emit InvoiceShelf.LossRecovered(inv, sellerId, 2, loss, address(this));
        shelf.recoverDefault(inv, loss);
        require(!usdc.reenterSucceeded() && bytes4(usdc.reenterError()) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "recoverDefault nonReentrant");

        vm.expectEmit(true, false, false, true, address(shelf));
        emit InvoiceShelf.DefaultResolved(inv, false);
        vm.prank(ops);
        shelf.resolveDefault(inv, false);
        require(!shelf.workspaceFrozen(sellerId), "unfrozen after resolve");
    }
}
