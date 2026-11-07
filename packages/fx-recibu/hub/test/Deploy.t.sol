// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BUFIIdentityRegistry} from "../src/identity/BUFIIdentityRegistry.sol";
import {BUFIReputationRegistry} from "../src/identity/BUFIReputationRegistry.sol";
import {WorkspaceTierRegistry} from "../src/credit/WorkspaceTierRegistry.sol";
import {InvoiceShelf} from "../src/invoice/InvoiceShelf.sol";
import {BINV} from "../src/invoice/BINV.sol";
import {FactoringEvidenceV1} from "../src/libraries/FactoringEvidenceV1.sol";
import {ReceivableCommitment} from "../src/libraries/ReceivableCommitment.sol";
import {IInvoiceShelf} from "../src/interfaces/IInvoiceShelf.sol";
import {MultiTokenReceivableEscrow} from "../src/rails/MultiTokenReceivableEscrow.sol";
import {RecibuMemoRouter} from "../src/rails/RecibuMemoRouter.sol";
import {WorkspaceOperatingReserve} from "../src/rails/WorkspaceOperatingReserve.sol";
import {SpokeMemoConduit} from "../../spoke-cctp/src/rails/SpokeMemoConduit.sol";
import {MemoConduit, IAddressBook} from "../../spoke-cctp/src/rails/MemoConduit.sol";
import {CctpConfig} from "../../spoke-cctp/src/rails/MemoConduitCctpConfig.sol";

interface Vm {
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function warp(uint256) external;
    function chainId(uint256) external;
    function etch(address, bytes calldata) external;
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
    function expectEmit(bool, bool, bool, bool, address) external;
}

contract HubTestToken is ERC20 {
    bool public permitReverts;
    mapping(address => mapping(bytes32 => bool)) public authorizationState;

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPermitReverts(bool v) external {
        permitReverts = v;
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

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256,
        uint256,
        bytes32 nonce,
        bytes calldata
    ) external {
        require(msg.sender == to, "CALLER_MUST_BE_PAYEE");
        require(!authorizationState[from][nonce], "AUTH_USED");
        authorizationState[from][nonce] = true;
        _transfer(from, to, value);
    }

    function burnFromMessenger(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract HubMockAddressBook is IAddressBook {
    mapping(address => address[]) internal _allowed;

    function setAllowed(address account, address recipient) external {
        _allowed[account].push(recipient);
    }

    function getAllowedRecipients(address account) external view override returns (address[] memory) {
        return _allowed[account];
    }
}

contract HubMockCctpMessengerMinter {
    HubTestToken public immutable token;

    constructor(HubTestToken token_) {
        token = token_;
    }

    function localMinter() external view returns (address) {
        return address(this);
    }

    function remoteTokenMessengers(uint32) external view returns (bytes32) {
        return bytes32(uint256(uint160(address(this))));
    }

    function burnLimitsPerMessage(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function depositForBurn(uint256 amount, uint32, bytes32, address, bytes32, uint256, uint32) external {
        token.transferFrom(msg.sender, address(this), amount);
        token.burnFromMessenger(address(this), amount);
    }
}

contract EscrowDeployTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    HubTestToken internal usdc;
    BUFIIdentityRegistry internal identity;
    BUFIReputationRegistry internal reputation;
    WorkspaceTierRegistry internal tiers;
    InvoiceShelf internal shelf;
    MultiTokenReceivableEscrow internal escrow;
    RecibuMemoRouter internal router;

    address internal admin = address(0xAD01);
    address internal sellerOwner = address(0x5E11);
    address internal debtorOwner = address(0xDEB7);
    address internal attacker = address(0xBAD0);

    uint256 internal sellerId;
    uint256 internal debtorId;

    function setUp() public {
        usdc = new HubTestToken();
        identity = new BUFIIdentityRegistry(admin);
        reputation = new BUFIReputationRegistry(admin, identity);
        tiers = new WorkspaceTierRegistry(identity, reputation);
        shelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin, false);
        escrow = new MultiTokenReceivableEscrow(admin);
        router = new RecibuMemoRouter(IInvoiceShelf(address(shelf)), escrow, admin);

        vm.startPrank(admin);
        identity.grantRole(identity.ISSUER_ROLE(), admin);
        reputation.grantRole(reputation.ATTESTOR_ROLE(), admin);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(shelf));
        shelf.grantRole(shelf.SERVICER_ROLE(), admin);
        shelf.grantRole(shelf.SETTLEMENT_ROLE(), admin);
        shelf.setEscrow(address(escrow));
        escrow.setToken(address(usdc), true);
        escrow.grantRole(escrow.ROUTER_ROLE(), address(router));
        router.setToken(address(usdc), true, router.CAP_3009() | router.CAP_PERMIT());

        sellerId = identity.registerWorkspace(keccak256("seller"), sellerOwner);
        debtorId = identity.registerWorkspace(keccak256("debtor"), debtorOwner);
        identity.setKybStatus(sellerId, true, uint64(block.timestamp + 365 days), 1, keccak256("op-s"));
        identity.setKybStatus(debtorId, true, uint64(block.timestamp + 365 days), 1, keccak256("op-d"));
        reputation.setScore(sellerId, 80, 80, 1, bytes32("s"));
        reputation.setScore(debtorId, 80, 90, 1, bytes32("d"));
        vm.stopPrank();

        usdc.mint(admin, 1_000_000e6);
        vm.startPrank(admin);
        usdc.approve(address(shelf), type(uint256).max);
        shelf.depositTranche(2, 500_000e6);
        vm.stopPrank();
    }

    function _lockSampleInvoice(InvoiceShelf targetShelf, bytes32 tag) internal returns (uint256 invoiceId) {
        vm.startPrank(admin);
        uint256 dId = identity.registerWorkspace(keccak256(abi.encodePacked("debtor-", tag)), debtorOwner);
        identity.setKybStatus(dId, true, uint64(block.timestamp + 365 days), 1, tag);
        reputation.setScore(dId, 80, 90, 1, bytes32("d"));
        vm.stopPrank();

        uint64 firstMaturity = uint64(block.timestamp + 30 days);
        uint32 interval = 30 days;
        uint64 dueAt = uint64(uint256(firstMaturity) + uint256(interval));
        ReceivableCommitment.Terms memory terms = ReceivableCommitment.Terms({
            canonicalInvoiceCommitmentHash: tag,
            issuedAt: uint64(block.timestamp),
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
        vm.prank(admin);
        invoiceId = targetShelf.lockInvoice(sellerId, dId, 100e6, 2, firstMaturity, interval, terms, evidence, docs);
    }

    function test_deploys_with_admin() public {
        MultiTokenReceivableEscrow e = new MultiTokenReceivableEscrow(address(this));
        require(e.hasRole(e.DEFAULT_ADMIN_ROLE(), address(this)), "admin");
    }

    function test_identity_and_reputation_registries_deploy() public {
        BUFIIdentityRegistry idReg = new BUFIIdentityRegistry(address(this));
        BUFIReputationRegistry repReg = new BUFIReputationRegistry(address(this), idReg);
        require(idReg.hasRole(idReg.DEFAULT_ADMIN_ROLE(), address(this)), "identity admin");
        require(repReg.hasRole(repReg.DEFAULT_ADMIN_ROLE(), address(this)), "reputation admin");
    }

    function test_F01_payWithPermit_allowsThirdPartyWhenPriorAllowanceExists() public {
        uint256 inv1 = _lockSampleInvoice(shelf, keccak256("inv-f01-1"));
        uint256 inv2 = _lockSampleInvoice(shelf, keccak256("inv-f01-2"));
        require(inv1 != inv2, "distinct invoices");

        usdc.mint(debtorOwner, 500e6);
        vm.prank(debtorOwner);
        usdc.approve(address(router), 500e6);

        usdc.setPermitReverts(true);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.UnauthorizedPermitCaller.selector, attacker, debtorOwner)
        );
        router.payWithPermit(
            address(usdc), debtorOwner, inv2, 0, 500e6, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0)
        );

        require(escrow.escrowedOf(inv2) == 0, "inv2 untouched");
        require(usdc.balanceOf(debtorOwner) == 500e6, "debtor funds safe");
    }

    function test_F02_hubInvoiceShelf_microPaymentIncrementsInstallmentCounter() public {
        uint256 inv = _lockSampleInvoice(shelf, keccak256("inv-f02"));
        uint256 onTimeBefore = reputation.paidOnTimeCumulative(sellerId);

        vm.prank(admin);
        shelf.applyPayment(inv, 1);

        (,,,,,,,,,,, uint8 paidInstallments,,) = shelf.invoices(inv);
        require(paidInstallments == 0, "installment not incremented on 1-wei payment");
        require(shelf.installmentProgress(inv) == 1, "progress tracks partial 1-wei payment");
        require(reputation.paidOnTimeCumulative(sellerId) == onTimeBefore, "reputation unchanged on dust payment");

        vm.prank(admin);
        shelf.applyPayment(inv, 50e6 - 1);
        (,,,,,,,,,,, paidInstallments,,) = shelf.invoices(inv);
        require(paidInstallments == 1, "installment incremented once full 50e6 slot paid");
        require(shelf.installmentProgress(inv) == 0, "progress reset at slot boundary");
        require(reputation.paidOnTimeCumulative(sellerId) == onTimeBefore + 1, "reputation incremented on full slot");
    }

    function test_F03_payWithAuthorization_nonceNotBoundToInvoiceId() public {
        uint256 inv1 = _lockSampleInvoice(shelf, keccak256("inv-f03-1"));
        uint256 inv2 = _lockSampleInvoice(shelf, keccak256("inv-f03-2"));
        require(inv1 != inv2, "distinct invoices");

        usdc.mint(debtorOwner, 250e6);
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonceForInv1 =
            router.authorizationNonceOf(address(usdc), debtorOwner, inv1, 0, 250e6, 0, validBefore);
        bytes32 expectedForInv2 =
            router.authorizationNonceOf(address(usdc), debtorOwner, inv2, 0, 250e6, 0, validBefore);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(RecibuMemoRouter.InvalidAuthorizationNonce.selector, nonceForInv1, expectedForInv2)
        );
        router.payWithAuthorization(
            address(usdc), debtorOwner, inv2, 0, 250e6, 0, validBefore, nonceForInv1, 27, bytes32(0), bytes32(0)
        );

        vm.prank(attacker);
        router.payWithAuthorization(
            address(usdc), debtorOwner, inv1, 0, 250e6, 0, validBefore, nonceForInv1, 27, bytes32(0), bytes32(0)
        );
        require(escrow.escrowedOf(inv1) == 250e6, "bound to inv1");
        require(escrow.escrowedOf(inv2) == 0, "inv2 untouched");
    }

    function test_F04_setKybStatus_twoArgOverloadClearsValidUntilToZero() public {
        uint64 expiry = uint64(block.timestamp + 30 days);
        vm.prank(admin);
        identity.setKybStatus(sellerId, true, expiry, 2, keccak256("op-s-2"));

        (,, uint64 validBefore, uint64 verBefore,) = identity.kybState(sellerId);
        require(validBefore == expiry, "expiry set");

        vm.prank(admin);
        identity.setKybStatus(sellerId, true);

        (,, uint64 validAfter, uint64 verAfter,) = identity.kybState(sellerId);
        require(validAfter == expiry, "validUntil preserved on re-approval");
        require(verAfter == verBefore + 1, "version incremented");

        vm.prank(admin);
        identity.setKybStatus(sellerId, false);
        (,, uint64 validRevoked,,) = identity.kybState(sellerId);
        require(validRevoked == 0, "validUntil cleared on revocation");
    }

    function test_F05_hubInvoiceShelf_midnightModeSkipsTokenTransferWhenEnabled() public {
        require(!shelf.MIDNIGHT_MODE(), "default shelf is non-midnight");

        InvoiceShelf midnightShelf = new InvoiceShelf(usdc, identity, reputation, tiers, admin, true);
        vm.startPrank(admin);
        reputation.grantRole(reputation.SETTLEMENT_ROLE(), address(midnightShelf));
        midnightShelf.grantRole(midnightShelf.SERVICER_ROLE(), admin);
        midnightShelf.grantRole(midnightShelf.SETTLEMENT_ROLE(), admin);
        vm.stopPrank();

        uint256 sellerBalBefore = usdc.balanceOf(sellerOwner);
        uint256 inv = _lockSampleInvoice(midnightShelf, keccak256("inv-f05"));
        require(usdc.balanceOf(sellerOwner) == sellerBalBefore, "no USDC moved in midnight mode");

        vm.prank(admin);
        vm.expectRevert(InvoiceShelf.MidnightDirectPaymentDisabled.selector);
        midnightShelf.applyPayment(inv, 10e6);

        vm.prank(admin);
        vm.expectRevert(InvoiceShelf.MidnightDirectPaymentDisabled.selector);
        midnightShelf.applyPaymentFrom(inv, 10e6, admin);
    }

    function test_F09_recibuMemoRouter_setTokenCanDisableTokenImmediately() public {
        uint256 inv = _lockSampleInvoice(shelf, keccak256("inv-f09"));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RecibuMemoRouter.TokenDisableNotReady.selector, address(usdc), uint64(0)));
        router.setToken(address(usdc), false, 0);

        vm.prank(admin);
        router.scheduleTokenDisable(address(usdc));
        uint64 readyAt = router.tokenDisableScheduledAt(address(usdc));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RecibuMemoRouter.TokenDisableNotReady.selector, address(usdc), readyAt));
        router.setToken(address(usdc), false, 0);

        vm.warp(readyAt);
        vm.prank(admin);
        router.setToken(address(usdc), false, 0);

        vm.prank(debtorOwner);
        vm.expectRevert(abi.encodeWithSelector(RecibuMemoRouter.TokenNotAllowed.selector, address(usdc)));
        router.pay(address(usdc), inv, 0, 50e6);
    }

    function test_F10_invoiceShelf_overpaymentRevertsWithZeroAmount() public {
        uint256 inv = _lockSampleInvoice(shelf, keccak256("inv-f10"));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.Overpayment.selector, uint256(100e6 + 1), uint256(100e6)));
        shelf.applyPayment(inv, 100e6 + 1);
    }

    function test_F11_multiTokenReceivableEscrow_depositRequiresRouterRole() public {
        uint256 inv = _lockSampleInvoice(shelf, keccak256("inv-f11"));
        usdc.mint(attacker, 100e6);
        vm.startPrank(attacker);
        usdc.approve(address(escrow), 100e6);
        vm.expectRevert();
        escrow.deposit(inv, address(usdc), 100e6, attacker);
        vm.stopPrank();

        vm.prank(address(router));
        vm.expectRevert(
            abi.encodeWithSelector(MultiTokenReceivableEscrow.InvalidDepositor.selector, address(router), attacker)
        );
        escrow.deposit(inv, address(usdc), 100e6, attacker);
    }

    function test_F13_spokeMemoConduit_crossChainTimingWindowAllowsHubDefaultBeforeBridgeSettles() public {
        uint256 inv = _lockSampleInvoice(shelf, keccak256("inv-f13"));
        uint256 due = shelf.installmentDue(inv, 0);
        uint256 graceEnd = shelf.lateAfter(inv, due);

        vm.warp(graceEnd + 1);
        vm.prank(admin);
        shelf.notifyCrossChainRepayment(inv, keccak256("bridge-nonce-f13"));
        uint64 pendingUntil = shelf.pendingBridgeUntil(inv);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvoiceShelf.CrossChainRepaymentInFlight.selector, inv, pendingUntil));
        shelf.markDefaulted(inv);

        vm.warp(pendingUntil + 1);
        vm.prank(admin);
        shelf.markDefaulted(inv);
        require(uint8(shelf.invoiceStatus(inv)) == uint8(IInvoiceShelf.Status.Defaulted), "defaulted after buffer");
    }

    function test_F14_spokeMemoConduit_payWithMemoChecksBridgeCommitmentNotSameChainCommitment() public {
        HubMockAddressBook book = new HubMockAddressBook();
        address payer = address(0xA11CE);
        address recipient = address(0xB0B);
        book.setAllowed(payer, recipient);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        CctpConfig memory cctp;
        MemoConduit conduit = new MemoConduit(book, tokens, cctp);

        usdc.mint(payer, 200e6);
        bytes32 memoId = keccak256("same-memo-id");

        conduit.payWithMemo(address(usdc), payer, recipient, 100e6, 0, 1000, memoId, "memo", hex"01");
        require(conduit.memoPaymentCommitment(payer, memoId) != bytes32(0), "commitment set");

        vm.expectRevert(abi.encodeWithSelector(MemoConduit.MemoAlreadyPaid.selector, payer, memoId));
        conduit.payWithMemo(address(usdc), payer, recipient, 100e6, 0, 2000, memoId, "memo", hex"01");
        require(usdc.balanceOf(recipient) == 100e6, "second payment blocked");
    }

    function test_F15_spokeMemoConduit_repaymentInitiatedEmitsAuthNonceAsBridgeNonce() public {
        vm.chainId(43113);
        address fujiUsdc = 0x5425890298aed601595a70AB815c96711a31Bc65;
        HubTestToken impl = new HubTestToken();
        vm.etch(fujiUsdc, address(impl).code);

        HubMockAddressBook book = new HubMockAddressBook();
        address payer = address(0xCAFECAFE);
        vm.etch(payer, hex"600080fd");
        address recipient = address(0xBEEFBEEF);
        book.setAllowed(payer, recipient);

        HubMockCctpMessengerMinter cctpMock = new HubMockCctpMessengerMinter(HubTestToken(fujiUsdc));
        address[] memory tokens = new address[](1);
        tokens[0] = fujiUsdc;
        CctpConfig memory cfg = CctpConfig({
            tokenMessenger: address(cctpMock),
            messageTransmitter: address(0x7777),
            tokenMinter: address(cctpMock),
            ccts: address(0),
            eurcManager: address(0),
            cirbtcManager: address(0)
        });

        SpokeMemoConduit spoke = new SpokeMemoConduit(book, tokens, cfg);
        HubTestToken(fujiUsdc).mint(payer, 100e6);

        MemoConduit.BridgePayment memory bp = MemoConduit.BridgePayment({
            protocol: spoke.CCTP_V2_USDC(),
            token: fujiUsdc,
            from: payer,
            recipient: recipient,
            amount: 100e6,
            destinationChainId: 5042002,
            destinationDomain: 26,
            destinationToken: 0x3600000000000000000000000000000000000000,
            maxFee: 0,
            minFinalityThreshold: 2000,
            validAfter: 0,
            validBefore: block.timestamp + 1 hours,
            paymentId: keccak256("adv-1"),
            termsHash: keccak256("mkt-1"),
            memoId: keccak256("memo-1"),
            memo: "repay",
            tokenId: bytes32(0),
            quoteHash: bytes32(0),
            nativeFee: 0,
            quoteValidUntil: 0
        });

        bytes32 expectedAuthNonce = spoke.bridgePaymentNonceOf(bp);
        bytes32 expectedBridgeNonce = spoke.computeBridgeNonce(bp, expectedAuthNonce, 26);
        require(expectedBridgeNonce != expectedAuthNonce, "bridgeNonce distinct from authNonce");
        vm.expectEmit(true, true, true, true, address(spoke));
        emit SpokeMemoConduit.RepaymentInitiated(
            bp.paymentId,
            bp.termsHash,
            bp.memoId,
            payer,
            recipient,
            100e6,
            26,
            expectedBridgeNonce,
            cfg.messageTransmitter
        );
        spoke.bridgeWithMemo(bp, hex"01");
    }

    function test_F16_memoConduit_balanceSnapshotEnforcesZeroRetentionUnderNonReentrant() public {
        HubMockAddressBook book = new HubMockAddressBook();
        address payer = address(0x1616);
        address recipient = address(0x1617);
        book.setAllowed(payer, recipient);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        CctpConfig memory cctp;
        MemoConduit conduit = new MemoConduit(book, tokens, cctp);

        usdc.mint(address(conduit), 77);
        usdc.mint(payer, 50e6);
        conduit.payWithMemo(address(usdc), payer, recipient, 50e6, 0, 1000, keccak256("m16"), "m", hex"01");
        require(usdc.balanceOf(address(conduit)) == 77, "conduit balance unchanged");
        require(usdc.balanceOf(recipient) == 50e6, "recipient received exact amount");
    }

    function test_SafeTxBuilder_Arc5042_FxRecibuHubBatch() public {
        address create2Factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        address safe = 0x47Dc7D18A6E3a79F696714E7D47456a49B430D09;
        address arcUsdc = 0x3600000000000000000000000000000000000000;
        address arcEurc = 0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a;
        address issuerEoa = 0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474;
        address keeperEoa = 0xcA02Be6cDBb806d4a327FC92E094D1A44EC37445;

        vm.etch(safe, hex"600080fd");
        vm.etch(arcUsdc, hex"600080fd");
        vm.etch(arcEurc, hex"600080fd");

        vm.startPrank(safe);
        (bool ok1, bytes memory r1) = create2Factory.call(
            abi.encodePacked(keccak256("bufi.identity-registry.v1"), type(BUFIIdentityRegistry).creationCode, abi.encode(safe))
        );
        require(ok1 && address(bytes20(r1)) == 0x6730b8f3FF0eF85E097Af01eC8a3e450d30e466d, "id deploy");
        BUFIIdentityRegistry idReg = BUFIIdentityRegistry(address(bytes20(r1)));

        (bool ok2, bytes memory r2) = create2Factory.call(
            abi.encodePacked(
                keccak256("bufi.reputation-registry.v1"),
                type(BUFIReputationRegistry).creationCode,
                abi.encode(safe, address(idReg))
            )
        );
        require(ok2 && address(bytes20(r2)) == 0x2D7125b1cf826bE4ad6D0b043F6B4675897EB2e9, "rep deploy");
        BUFIReputationRegistry repReg = BUFIReputationRegistry(address(bytes20(r2)));

        (bool ok3, bytes memory r3) = create2Factory.call(
            abi.encodePacked(
                keccak256("bufi.workspace-tier-registry.v1"),
                type(WorkspaceTierRegistry).creationCode,
                abi.encode(address(idReg), address(repReg))
            )
        );
        require(ok3 && address(bytes20(r3)) == 0x9a3029Be2323695647A24DD2aB6014887E04A4C7, "tiers deploy");
        WorkspaceTierRegistry tierReg = WorkspaceTierRegistry(address(bytes20(r3)));

        (bool ok4, bytes memory r4) = create2Factory.call(
            abi.encodePacked(
                keccak256("bufi.workspace-operating-reserve.v1"),
                type(WorkspaceOperatingReserve).creationCode,
                abi.encode(arcUsdc, safe)
            )
        );
        require(ok4 && address(bytes20(r4)) == 0x9075121f006CC0646bf1799993AC29B4aBF096f4, "reserve deploy");
        WorkspaceOperatingReserve opRes = WorkspaceOperatingReserve(address(bytes20(r4)));

        (bool ok5, bytes memory r5) = create2Factory.call(
            abi.encodePacked(
                keccak256("bufi.invoice-shelf.v1"),
                type(InvoiceShelf).creationCode,
                abi.encode(arcUsdc, address(idReg), address(repReg), address(tierReg), safe, false)
            )
        );
        require(ok5 && address(bytes20(r5)) == 0x90eCDd402C0E357362b7805173191A153b876DF4, "shelf deploy");
        InvoiceShelf hubShelf = InvoiceShelf(address(bytes20(r5)));
        require(address(hubShelf.BINV_TOKEN()) == 0xd692453558A92C712b74cFad13C0b769F4AC3037, "binv child addr");
        require(address(hubShelf.tranches(0)) == 0xE29590E4A240CEDc5438531f3A4284309064aA8e, "tranche A addr");
        require(address(hubShelf.tranches(1)) == 0xbA4368e30E83D5087E1257f7Db08918691dF773c, "tranche B addr");
        require(address(hubShelf.tranches(2)) == 0x06215695D37CB9a43aa9B2bb3057fcf5fcb507f5, "tranche C addr");

        (bool ok6, bytes memory r6) = create2Factory.call(
            abi.encodePacked(
                keccak256("bufi.multi-token-receivable-escrow.v1"),
                type(MultiTokenReceivableEscrow).creationCode,
                abi.encode(safe)
            )
        );
        require(ok6 && address(bytes20(r6)) == 0x4772d02a36cfBfF5c139C8d3b5F2DACc82FFAE96, "escrow deploy");
        MultiTokenReceivableEscrow hubEscrow = MultiTokenReceivableEscrow(address(bytes20(r6)));

        (bool ok7, bytes memory r7) = create2Factory.call(
            abi.encodePacked(
                keccak256("bufi.recibu-memo-router.v1"),
                type(RecibuMemoRouter).creationCode,
                abi.encode(address(hubShelf), address(hubEscrow), safe)
            )
        );
        require(ok7 && address(bytes20(r7)) == 0x652D1eD9c519bf7582bFE55AEB504De3f48B7545, "router deploy");
        RecibuMemoRouter hubRouter = RecibuMemoRouter(address(bytes20(r7)));

        idReg.grantRole(idReg.ISSUER_ROLE(), safe);
        idReg.grantRole(idReg.ISSUER_ROLE(), issuerEoa);
        repReg.grantRole(repReg.ATTESTOR_ROLE(), safe);
        repReg.grantRole(repReg.SETTLEMENT_ROLE(), address(hubShelf));
        opRes.grantRole(opRes.SHELF_ROLE(), address(hubShelf));
        hubShelf.setReserve(opRes);
        hubShelf.setEscrow(address(hubEscrow));
        hubShelf.grantRole(hubShelf.SERVICER_ROLE(), safe);
        hubShelf.grantRole(hubShelf.SETTLEMENT_ROLE(), safe);
        hubShelf.grantRole(hubShelf.OPS_ROLE(), keeperEoa);
        hubEscrow.setToken(arcUsdc, true);
        hubEscrow.setToken(arcEurc, true);
        hubEscrow.grantRole(hubEscrow.ROUTER_ROLE(), address(hubRouter));
        hubRouter.setToken(arcUsdc, true, 3);
        hubRouter.setToken(arcEurc, true, 3);
        vm.stopPrank();

        require(address(hubShelf.reserve()) == address(opRes), "reserve wired");
        require(address(hubShelf.escrow()) == address(hubEscrow), "escrow wired");
        require(hubEscrow.supportedToken(arcUsdc), "escrow usdc wired");
    }
}

