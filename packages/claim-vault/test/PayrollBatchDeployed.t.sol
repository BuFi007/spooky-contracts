// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {Vm} from "forge-std/Vm.sol";

import {PayrollBatch} from "../src/payroll/PayrollBatch.sol";
import {ISignatureTransfer} from "../src/interfaces/ISignatureTransfer.sol";
import {PBToken, MockTreasury1271} from "./PayrollBatch.t.sol";
import {ClaimSigs} from "./utils/ClaimSigs.sol";

/// @notice Plan 386 Phase 0 measurements, run against the DEPLOYED Arc testnet bytecode
///         (`test/fixtures/payroll-batch.arc-testnet.runtime.hex`, etched at its own address)
///         and the real canonical Permit2 runtime. Only one `executePayroll` has ever run on
///         Arc testnet, with one line (tx 0x63533b02…c230fc), so the multi-line facts below
///         cannot be read from a real receipt yet; this is the closest measurement: the bytes
///         on chain, executed.
///
///         0.2  `PayrollPayout` is emitted once per payout, in array order, each its own log,
///              and it is never the token's `Transfer` log. Duplicate lines stay distinct.
///         Re-open  An expired, unrelayed permit for a payrollId does not block a fresh permit
///              (new nonce) for the SAME payrollId; once one executes, every other permit for
///              that payrollId reverts `AlreadyExecuted`.
contract PayrollBatchDeployedTest is ClaimSigs {
    uint256 constant ARC_TESTNET = 5042002;
    ISignatureTransfer constant PERMIT2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    PayrollBatch constant BATCH = PayrollBatch(0x8f4e4d47C0D4F8bF3AAeAcC31C9Cd425476B30C5);
    address constant DEPLOYED_VAULT = 0xb96Cc197F4b15DA762e4c34E1413CECa57FaC4fC;
    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant PAYOUT_TOPIC = keccak256("PayrollPayout(bytes32,address,address,uint256)");
    bytes32 constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    MockTreasury1271 treasury;
    PBToken usd6;
    PBToken fx18;
    uint256 quorumPk = uint256(keccak256("treasury quorum"));
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        vm.chainId(ARC_TESTNET);
        vm.etch(address(PERMIT2), vm.parseBytes(vm.trim(vm.readFile("test/fixtures/permit2.arc-testnet.runtime.hex"))));
        vm.etch(address(BATCH), vm.parseBytes(vm.trim(vm.readFile("test/fixtures/payroll-batch.arc-testnet.runtime.hex"))));
        treasury = new MockTreasury1271(vm.addr(quorumPk));
        usd6 = new PBToken(6);
        fx18 = new PBToken(18);
        usd6.mint(address(treasury), 1_000_000e6);
        fx18.mint(address(treasury), 1_000_000e18);
        vm.startPrank(vm.addr(quorumPk));
        treasury.approveMax(address(usd6), address(PERMIT2));
        treasury.approveMax(address(fx18), address(PERMIT2));
        vm.stopPrank();
    }

    function _permit(address[] memory tokens, uint256[] memory amounts, uint256 nonce)
        internal
        view
        returns (ISignatureTransfer.PermitBatchTransferFrom memory p)
    {
        p.permitted = new ISignatureTransfer.TokenPermissions[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            p.permitted[i] = ISignatureTransfer.TokenPermissions(tokens[i], amounts[i]);
        }
        p.nonce = nonce;
        p.deadline = block.timestamp + 1 hours;
    }

    function _sign(ISignatureTransfer.PermitBatchTransferFrom memory p, bytes32 witness)
        internal
        view
        returns (bytes memory)
    {
        bytes32[] memory hashes = new bytes32[](p.permitted.length);
        for (uint256 i; i < p.permitted.length; ++i) {
            hashes[i] = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, p.permitted[i].token, p.permitted[i].amount));
        }
        bytes32 typehash = keccak256(
            abi.encodePacked(
                "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,",
                BATCH.WITNESS_TYPE_STRING()
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(typehash, keccak256(abi.encodePacked(hashes)), address(BATCH), p.nonce, p.deadline, witness)
        );
        return sign(quorumPk, keccak256(abi.encodePacked("\x19\x01", PERMIT2.DOMAIN_SEPARATOR(), structHash)));
    }

    function _noClaims() internal pure returns (PayrollBatch.ClaimDeposit[] memory c) {
        c = new PayrollBatch.ClaimDeposit[](0);
    }

    function test_deployed_immutables() public view {
        assertEq(address(BATCH.PERMIT2()), address(PERMIT2));
        assertEq(address(BATCH.VAULT()), DEPLOYED_VAULT);
        assertEq(BATCH.MAX_LINES(), 100);
    }

    /// 0.2 — one PayrollPayout per line, in array order, never the Transfer log.
    function test_payoutLogs_inArrayOrder_oneEach_distinct() public {
        PayrollBatch.Payout[] memory payouts = new PayrollBatch.Payout[](4);
        payouts[0] = PayrollBatch.Payout(address(usd6), alice, 100e6);
        payouts[1] = PayrollBatch.Payout(address(fx18), bob, 5e18);
        payouts[2] = PayrollBatch.Payout(address(usd6), alice, 100e6); // identical to line 0
        payouts[3] = PayrollBatch.Payout(address(usd6), carol, 7e6);
        address[] memory t = new address[](2);
        uint256[] memory a = new uint256[](2);
        (t[0], a[0]) = (address(usd6), 207e6);
        (t[1], a[1]) = (address(fx18), 5e18);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _permit(t, a, 1);
        bytes32 payrollId = keccak256("bufi.disbursement.v1:measure");
        bytes memory sig = _sign(permit, BATCH.witnessOf(payrollId, payouts, _noClaims()));

        vm.recordLogs();
        BATCH.executePayroll(permit, address(treasury), sig, payrollId, payouts, _noClaims());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 seen;
        uint256 lastPosition;
        uint256 transfersSinceLastPayout;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(BATCH) && logs[i].topics[0] == TRANSFER_TOPIC) {
                ++transfersSinceLastPayout;
                continue;
            }
            if (logs[i].emitter != address(BATCH) || logs[i].topics[0] != PAYOUT_TOPIC) continue;
            PayrollBatch.Payout memory expected = payouts[seen];
            assertEq(logs[i].topics[1], payrollId);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), expected.token);
            assertEq(address(uint160(uint256(logs[i].topics[3]))), expected.recipient);
            assertEq(abi.decode(logs[i].data, (uint256)), expected.amount);
            if (seen > 0) assertGt(i, lastPosition); // strictly later log => distinct logIndex
            // The line's own token Transfer precedes its PayrollPayout; they are separate logs.
            assertGe(transfersSinceLastPayout, 1);
            transfersSinceLastPayout = 0;
            lastPosition = i;
            ++seen;
        }
        assertEq(seen, payouts.length);
    }

    /// Re-open: an expired permit never executed does not burn the payrollId; a fresh nonce
    /// for the same payrollId executes; then that payrollId is spent for every permit.
    function test_reopen_samePayrollId_afterExpiry_thenLocked() public {
        PayrollBatch.Payout[] memory payouts = new PayrollBatch.Payout[](1);
        payouts[0] = PayrollBatch.Payout(address(usd6), alice, 10e6);
        address[] memory t = new address[](1);
        uint256[] memory a = new uint256[](1);
        (t[0], a[0]) = (address(usd6), 10e6);
        bytes32 payrollId = keccak256("bufi.disbursement.v1:reopen");
        bytes32 witness = BATCH.witnessOf(payrollId, payouts, _noClaims());

        ISignatureTransfer.PermitBatchTransferFrom memory expired = _permit(t, a, 11);
        bytes memory expiredSig = _sign(expired, witness);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(abi.encodeWithSignature("SignatureExpired(uint256)", expired.deadline));
        BATCH.executePayroll(expired, address(treasury), expiredSig, payrollId, payouts, _noClaims());
        assertFalse(BATCH.payrollExecuted(address(treasury), payrollId));

        ISignatureTransfer.PermitBatchTransferFrom memory reopened = _permit(t, a, 12);
        BATCH.executePayroll(reopened, address(treasury), _sign(reopened, witness), payrollId, payouts, _noClaims());
        assertTrue(BATCH.payrollExecuted(address(treasury), payrollId));
        assertEq(usd6.balanceOf(alice), 10e6);

        ISignatureTransfer.PermitBatchTransferFrom memory third = _permit(t, a, 13);
        bytes memory thirdSig = _sign(third, witness);
        vm.expectRevert(PayrollBatch.AlreadyExecuted.selector);
        BATCH.executePayroll(third, address(treasury), thirdSig, payrollId, payouts, _noClaims());
    }

    function test_vaultIsABadRecipient() public {
        PayrollBatch.Payout[] memory payouts = new PayrollBatch.Payout[](1);
        payouts[0] = PayrollBatch.Payout(address(usd6), DEPLOYED_VAULT, 1e6);
        address[] memory t = new address[](1);
        uint256[] memory a = new uint256[](1);
        (t[0], a[0]) = (address(usd6), 1e6);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _permit(t, a, 21);
        bytes32 payrollId = keccak256("bufi.disbursement.v1:vault");
        bytes memory sig = _sign(permit, BATCH.witnessOf(payrollId, payouts, _noClaims()));
        vm.expectRevert(abi.encodeWithSelector(PayrollBatch.BadRecipient.selector, DEPLOYED_VAULT));
        BATCH.executePayroll(permit, address(treasury), sig, payrollId, payouts, _noClaims());
    }
}
