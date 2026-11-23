// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {CctpDepositForwarder} from "../../src/rails/cctp/CctpDepositForwarder.sol";
import {CctpDepositForwarderFactory} from "../../src/rails/cctp/CctpDepositForwarderFactory.sol";
import {ITokenMessengerV2} from "../../src/interfaces/ITokenMessengerV2.sol";
import {MockForwarderUSDC as MockUSDC} from "../mocks/MockForwarderUSDC.sol";
import {MockTokenMessengerV2} from "../mocks/MockTokenMessengerV2.sol";

/**
 * @title CctpDepositForwarderTest
 * @notice Unit + fuzz tests for CctpDepositForwarder and CctpDepositForwarderFactory.
 */
contract CctpDepositForwarderTest is Test {
    // -------------------------------------------------------------------------
    // Fixtures
    // -------------------------------------------------------------------------

    CctpDepositForwarder internal impl;
    MockUSDC internal usdc;
    MockTokenMessengerV2 internal messenger;
    CctpDepositForwarderFactory internal factory;

    uint32 constant DOMAIN_AVALANCHE = 1;
    uint32 constant DOMAIN_ARC = 26;

    bytes32 constant RECIPIENT = bytes32(uint256(0xBEEF));
    bytes32 constant CALLER_B32 = bytes32(uint256(0xCAFE));
    bytes32 constant COMMITMENT = keccak256("doc-1");
    uint16 constant BPS = 50; // 0.5 %

    function setUp() public {
        usdc = new MockUSDC();
        messenger = new MockTokenMessengerV2();
        impl = new CctpDepositForwarder();
        factory = new CctpDepositForwarderFactory(address(impl), address(usdc), address(messenger));
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _deploy(uint32 domain, bytes32 recipient, bytes32 caller_, uint16 bps, bytes32 doc)
        internal
        returns (CctpDepositForwarder)
    {
        return CctpDepositForwarder(factory.deploy(domain, recipient, caller_, bps, doc));
    }

    function _defaultFwd() internal returns (CctpDepositForwarder) {
        return _deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, BPS, COMMITMENT);
    }

    /// @dev Address derivation WITHOUT the factory's validation (factory has no unchecked predict).
    function _raw(uint32 domain, bytes32 recipient, bytes32 caller_, uint16 bps, bytes32 doc)
        internal
        view
        returns (address)
    {
        return Clones.predictDeterministicAddressWithImmutableArgs(
            address(impl),
            factory.cloneArgs(domain, recipient, caller_, bps, doc),
            factory.saltOf(domain, recipient, caller_, bps, doc),
            address(factory)
        );
    }

    function _fund(address to, uint256 amount) internal {
        usdc.mint(to, amount);
    }

    // -------------------------------------------------------------------------
    // 1. Different params => different addresses
    // -------------------------------------------------------------------------

    function test_differentParams_differentAddresses() public view {
        address a1 = _raw(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, BPS, COMMITMENT);
        address a2 = _raw(DOMAIN_ARC, RECIPIENT, CALLER_B32, BPS, COMMITMENT);
        address a3 = _raw(DOMAIN_AVALANCHE, bytes32(uint256(0xDEAD)), CALLER_B32, BPS, COMMITMENT);
        address a4 = _raw(DOMAIN_AVALANCHE, RECIPIENT, bytes32(0), BPS, COMMITMENT);
        address a5 = _raw(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, 10, COMMITMENT);
        address a6 = _raw(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, BPS, keccak256("doc-2"));

        assertTrue(a1 != a2, "domain differs");
        assertTrue(a1 != a3, "recipient differs");
        assertTrue(a1 != a4, "destinationCaller differs");
        assertTrue(a1 != a5, "bps differs");
        assertTrue(a1 != a6, "commitment differs");
    }

    function testFuzz_differentParams_differentAddresses(
        bytes32 r1,
        bytes32 r2,
        bytes32 c1,
        bytes32 c2,
        uint16 b1,
        uint16 b2,
        bytes32 d1,
        bytes32 d2
    ) public view {
        // _raw skips validation, so any domain/bps can be compared
        b1 = uint16(bound(b1, 0, 100));
        b2 = uint16(bound(b2, 0, 100));

        // Only assert when at least one field differs
        if (r1 == r2 && c1 == c2 && b1 == b2 && d1 == d2) return;

        address a1 = _raw(DOMAIN_AVALANCHE, r1, c1, b1, d1);
        address a2 = _raw(DOMAIN_AVALANCHE, r2, c2, b2, d2);
        assertTrue(_raw(DOMAIN_ARC, r1, c1, b1, d1) != a1, "domain must change the address");
        assertTrue(a1 != a2, "addresses collided on different params");
    }

    // -------------------------------------------------------------------------
    // 2. predict == deployed address
    // -------------------------------------------------------------------------

    function test_predictMatchesDeploy() public {
        address predicted = factory.predict(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, BPS, COMMITMENT);
        address deployed = factory.deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, BPS, COMMITMENT);
        assertEq(predicted, deployed);
    }

    // -------------------------------------------------------------------------
    // 3. Counterfactual: fund before deploy, then deployAndFlush
    // -------------------------------------------------------------------------

    function test_counterfactualFundAndFlush() public {
        uint256 amount = 1_000e6;

        address predicted = factory.predict(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, BPS, COMMITMENT);
        _fund(predicted, amount);
        assertEq(usdc.balanceOf(predicted), amount);

        (address fwd, uint256 flushedAmt, uint256 flushedFee) =
            factory.deployAndFlush(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, BPS, COMMITMENT, true);

        assertEq(fwd, predicted, "address mismatch");
        assertEq(flushedAmt, amount, "flushed amount wrong");

        // Verify mock call
        assertEq(messenger.callCount(), 1);
        MockTokenMessengerV2.BurnCall memory call = messenger.getCall(0);
        assertEq(call.amount, amount, "call.amount");
        assertEq(call.destinationDomain, DOMAIN_AVALANCHE, "call.domain");
        assertEq(call.mintRecipient, RECIPIENT, "call.recipient");
        assertEq(call.burnToken, address(usdc), "call.burnToken");
        assertEq(call.destinationCaller, CALLER_B32, "call.caller");
        assertEq(call.maxFee, flushedFee, "call.maxFee");
        assertEq(call.minFinalityThreshold, CctpDepositForwarder(fwd).FAST_FINALITY_THRESHOLD(), "call.threshold");

        // hookData
        (bytes32 magic, bytes32 doc) = abi.decode(call.hookData, (bytes32, bytes32));
        assertEq(magic, CctpDepositForwarder(fwd).FORWARDER_MAGIC(), "magic");
        assertEq(doc, COMMITMENT, "commitment in hookData");

        // Balance zeroed
        assertEq(usdc.balanceOf(fwd), 0, "balance not burned");
    }

    // -------------------------------------------------------------------------
    // 4. Double flush: second deposit flushed again; immediate second reverts
    // -------------------------------------------------------------------------

    function test_doubleFlush() public {
        CctpDepositForwarder fwd = _defaultFwd();
        _fund(address(fwd), 500e6);
        fwd.flush(false);

        // Immediate re-flush
        vm.expectRevert(CctpDepositForwarder.NothingToFlush.selector);
        fwd.flush(false);

        // Deposit again and flush
        _fund(address(fwd), 200e6);
        (uint256 amt,) = fwd.flush(false);
        assertEq(amt, 200e6);
    }

    // -------------------------------------------------------------------------
    // 5. flush(0 balance) => NothingToFlush
    // -------------------------------------------------------------------------

    function test_flushZeroReverts() public {
        CctpDepositForwarder fwd = _defaultFwd();
        vm.expectRevert(CctpDepositForwarder.NothingToFlush.selector);
        fwd.flush(true);
    }

    // -------------------------------------------------------------------------
    // 6. Fee math
    // -------------------------------------------------------------------------

    function test_feeMath_oneUnit_maxBps() public {
        CctpDepositForwarder fwd = _deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, 100, COMMITMENT);
        _fund(address(fwd), 1);
        (, uint256 fee) = fwd.flush(true);
        assertEq(fee, 0, "1 unit at 100 bps must give fee=0 (clamp)");
    }

    function test_feeMath_roundingDown() public {
        // 10001 at 1 bps => floor(10001 / 10000) = 1
        CctpDepositForwarder fwd = _deploy(DOMAIN_ARC, RECIPIENT, CALLER_B32, 1, keccak256("rc2"));
        _fund(address(fwd), 10001);
        (, uint256 fee) = fwd.flush(true);
        assertEq(fee, 1, "floor rounding");

        // 9999 at 1 bps => floor(9999 / 10000) = 0
        _fund(address(fwd), 9999);
        (, uint256 subUnitFee) = fwd.flush(true);
        assertEq(subUnitFee, 0, "sub-unit floor rounding");
    }

    function test_feeMath_exactDivisible() public {
        // 10000 at 1 bps => 1 exactly (no rounding needed)
        CctpDepositForwarder fwd = _deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, 1, keccak256("exact"));
        _fund(address(fwd), 10000);
        (, uint256 fee) = fwd.flush(true);
        assertEq(fee, 1);
    }

    function testFuzz_feeMath_capLtAmount(uint256 amount, uint16 bps) public {
        amount = bound(amount, 1, 1e15);
        bps = uint16(bound(bps, 0, 100));

        bytes32 doc = keccak256(abi.encode("fuzz-fee", amount, bps));
        CctpDepositForwarder fwd = _deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, bps, doc);
        _fund(address(fwd), amount);

        (, uint256 fee) = fwd.flush(true);
        assertLt(fee, amount, "maxFee must be strictly < amount");
        uint256 expected = (amount * bps) / 10_000; // independent floor
        if (expected >= amount) expected = amount - 1;
        assertEq(fee, expected, "maxFee != min(floor(amount*bps/1e4), amount-1)");
        assertEq(messenger.getCall(0).maxFee, expected, "recorded maxFee");
    }

    // -------------------------------------------------------------------------
    // 7. maxFastFeeBps = 0 is valid
    // -------------------------------------------------------------------------

    function test_zeroFeeBps() public {
        CctpDepositForwarder fwd = _deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, 0, COMMITMENT);
        _fund(address(fwd), 1_000e6);
        (uint256 amt, uint256 fee) = fwd.flush(true);
        assertEq(amt, 1_000e6);
        assertEq(fee, 0);
    }

    // -------------------------------------------------------------------------
    // 8. Standard path: maxFee = 0, threshold = 2000
    // -------------------------------------------------------------------------

    function test_standardPath() public {
        CctpDepositForwarder fwd = _defaultFwd();
        _fund(address(fwd), 1_000e6);
        (, uint256 fee) = fwd.flush(false);
        assertEq(fee, 0);

        MockTokenMessengerV2.BurnCall memory call = messenger.getCall(0);
        assertEq(call.maxFee, 0);
        assertEq(call.minFinalityThreshold, fwd.STANDARD_FINALITY_THRESHOLD());
    }

    // -------------------------------------------------------------------------
    // 9. Fast path: threshold = 1000
    // -------------------------------------------------------------------------

    function test_fastPath_threshold() public {
        CctpDepositForwarder fwd = _defaultFwd();
        _fund(address(fwd), 1_000e6);
        fwd.flush(true);
        MockTokenMessengerV2.BurnCall memory call = messenger.getCall(0);
        assertEq(call.minFinalityThreshold, fwd.FAST_FINALITY_THRESHOLD());
    }

    // -------------------------------------------------------------------------
    // 10. hookData == abi.encode(MAGIC, commitment)
    // -------------------------------------------------------------------------

    function test_hookData() public {
        CctpDepositForwarder fwd = _defaultFwd();
        _fund(address(fwd), 100e6);
        fwd.flush(true);

        MockTokenMessengerV2.BurnCall memory call = messenger.getCall(0);
        bytes memory expected = abi.encode(fwd.FORWARDER_MAGIC(), COMMITMENT);
        assertEq(keccak256(call.hookData), keccak256(expected), "hookData mismatch");
    }

    // -------------------------------------------------------------------------
    // 11. ETH send to forwarder reverts (no receive / fallback)
    // -------------------------------------------------------------------------

    function test_ethSendReverts() public {
        CctpDepositForwarder fwd = _defaultFwd();
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(fwd).call{value: 1 wei}("");
        assertFalse(ok, "ETH send must revert");
    }

    // -------------------------------------------------------------------------
    // 12. deploy is idempotent; second deploy emits no events
    // -------------------------------------------------------------------------

    function test_deployIdempotent() public {
        address a1 = factory.deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, BPS, COMMITMENT);

        vm.recordLogs();
        address a2 = factory.deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, BPS, COMMITMENT);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(a1, a2, "addresses must match");
        assertEq(logs.length, 0, "second deploy must emit no events");
    }

    // -------------------------------------------------------------------------
    // 13. Anyone (fuzzed caller) can flush; funds reach only bound recipient
    // -------------------------------------------------------------------------

    function testFuzz_anyoneCanFlush(address caller_) public {
        vm.assume(caller_ != address(0));

        CctpDepositForwarder fwd = _defaultFwd();
        _fund(address(fwd), 500e6);

        vm.prank(caller_);
        fwd.flush(false);

        MockTokenMessengerV2.BurnCall memory call = messenger.getCall(0);
        assertEq(call.destinationDomain, DOMAIN_AVALANCHE, "domain bound");
        assertEq(call.mintRecipient, RECIPIENT, "recipient bound");
        assertEq(call.destinationCaller, CALLER_B32, "destinationCaller bound");
    }

    // -------------------------------------------------------------------------
    // 14. Allowance is 0 after flush
    // -------------------------------------------------------------------------

    function test_allowanceZeroAfterFlush() public {
        CctpDepositForwarder fwd = _defaultFwd();
        _fund(address(fwd), 100e6);
        fwd.flush(false);
        assertEq(usdc.allowance(address(fwd), address(messenger)), 0);
    }

    // -------------------------------------------------------------------------
    // 15. Messenger revert leaves funds in place; retry succeeds
    // -------------------------------------------------------------------------

    function test_messengerRevert_fundsStay_retrySucceeds() public {
        CctpDepositForwarder fwd = _defaultFwd();
        _fund(address(fwd), 300e6);

        messenger.setShouldRevert(true);
        vm.expectRevert("MockTokenMessengerV2: revert");
        fwd.flush(false);

        // Whole tx reverted — funds still there, allowance zero
        assertEq(usdc.balanceOf(address(fwd)), 300e6, "funds moved");
        assertEq(usdc.allowance(address(fwd), address(messenger)), 0, "allowance non-zero");

        // Retry
        messenger.setShouldRevert(false);
        (uint256 amt,) = fwd.flush(false);
        assertEq(amt, 300e6);
        assertEq(usdc.balanceOf(address(fwd)), 0);
    }

    // -------------------------------------------------------------------------
    // 16. Messenger pulls less => AllowanceNotConsumed, funds stay
    // -------------------------------------------------------------------------

    function test_pullLess_AllowanceNotConsumed() public {
        CctpDepositForwarder fwd = _defaultFwd();
        _fund(address(fwd), 100e6);

        messenger.setPullLess(true);
        vm.expectRevert(CctpDepositForwarder.AllowanceNotConsumed.selector);
        fwd.flush(false);

        // Funds still in forwarder (tx reverted)
        assertEq(usdc.balanceOf(address(fwd)), 100e6);
    }

    // -------------------------------------------------------------------------
    // 17. Implementation direct calls revert NotAClone
    // -------------------------------------------------------------------------

    function test_impl_flush_notAClone() public {
        vm.expectRevert(CctpDepositForwarder.NotAClone.selector);
        impl.flush(false);
    }

    function test_impl_config_notAClone() public {
        vm.expectRevert(CctpDepositForwarder.NotAClone.selector);
        impl.config();
    }

    function test_impl_pendingAmount_notAClone() public {
        vm.expectRevert(CctpDepositForwarder.NotAClone.selector);
        impl.pendingAmount();
    }

    function test_impl_quoteMaxFee_notAClone() public {
        vm.expectRevert(CctpDepositForwarder.NotAClone.selector);
        impl.quoteMaxFee(1e6, true);
    }

    // -------------------------------------------------------------------------
    // 18. Factory validation errors — predict
    // -------------------------------------------------------------------------

    function test_factory_unsupportedDomain_predict() public {
        vm.expectRevert(abi.encodeWithSelector(CctpDepositForwarderFactory.UnsupportedDomain.selector, uint32(999)));
        factory.predict(999, RECIPIENT, CALLER_B32, BPS, COMMITMENT);
    }

    function test_factory_unsupportedDomain_deploy() public {
        vm.expectRevert(abi.encodeWithSelector(CctpDepositForwarderFactory.UnsupportedDomain.selector, uint32(0)));
        factory.deploy(0, RECIPIENT, CALLER_B32, BPS, COMMITMENT);
    }

    function test_factory_zeroRecipient_predict() public {
        vm.expectRevert(CctpDepositForwarderFactory.ZeroMintRecipient.selector);
        factory.predict(DOMAIN_AVALANCHE, bytes32(0), CALLER_B32, BPS, COMMITMENT);
    }

    function test_factory_zeroRecipient_deploy() public {
        vm.expectRevert(CctpDepositForwarderFactory.ZeroMintRecipient.selector);
        factory.deploy(DOMAIN_AVALANCHE, bytes32(0), CALLER_B32, BPS, COMMITMENT);
    }

    function test_factory_zeroCommitment_predict() public {
        vm.expectRevert(CctpDepositForwarderFactory.ZeroDocumentCommitment.selector);
        factory.predict(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, BPS, bytes32(0));
    }

    function test_factory_zeroCommitment_deploy() public {
        vm.expectRevert(CctpDepositForwarderFactory.ZeroDocumentCommitment.selector);
        factory.deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, BPS, bytes32(0));
    }

    function test_factory_feeBpsTooHigh_predict() public {
        vm.expectRevert(abi.encodeWithSelector(CctpDepositForwarderFactory.FeeBpsTooHigh.selector, uint16(101)));
        factory.predict(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, 101, COMMITMENT);
    }

    function test_factory_feeBpsTooHigh_deploy() public {
        vm.expectRevert(abi.encodeWithSelector(CctpDepositForwarderFactory.FeeBpsTooHigh.selector, uint16(255)));
        factory.deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, 255, COMMITMENT);
    }

    // destinationCaller zero is allowed
    function test_factory_zeroCaller_valid() public {
        address fwd = factory.deploy(DOMAIN_AVALANCHE, RECIPIENT, bytes32(0), BPS, COMMITMENT);
        assertTrue(fwd != address(0));
    }

    // -------------------------------------------------------------------------
    // 19. Factory constructor errors
    // -------------------------------------------------------------------------

    function test_factory_constructor_implZero() public {
        vm.expectRevert(CctpDepositForwarderFactory.InvalidImplementation.selector);
        new CctpDepositForwarderFactory(address(0), address(usdc), address(messenger));
    }

    function test_factory_constructor_implNoCode() public {
        vm.expectRevert(CctpDepositForwarderFactory.InvalidImplementation.selector);
        new CctpDepositForwarderFactory(address(0xDEAD), address(usdc), address(messenger));
    }

    function test_factory_constructor_zeroUsdc() public {
        vm.expectRevert(CctpDepositForwarderFactory.ZeroUsdc.selector);
        new CctpDepositForwarderFactory(address(impl), address(0), address(messenger));
    }

    function test_factory_constructor_zeroMessenger() public {
        vm.expectRevert(CctpDepositForwarderFactory.ZeroTokenMessenger.selector);
        new CctpDepositForwarderFactory(address(impl), address(usdc), address(0));
    }

    // -------------------------------------------------------------------------
    // 20. config() round-trip of all 7 fields (fuzz)
    // -------------------------------------------------------------------------

    function testFuzz_configRoundTrip(bytes32 recipient, bytes32 caller_, uint16 bps, bytes32 doc) public {
        recipient = bytes32(uint256(uint160(uint256(recipient))));
        vm.assume(recipient != bytes32(0) && doc != bytes32(0));
        caller_ = bytes32(uint256(uint160(uint256(caller_))));
        bps = uint16(bound(bps, 0, 100));
        uint32 domain = (uint256(doc) % 2 == 0) ? DOMAIN_AVALANCHE : DOMAIN_ARC;

        CctpDepositForwarder fwd = _deploy(domain, recipient, caller_, bps, doc);
        CctpDepositForwarder.ForwarderConfig memory cfg = fwd.config();

        assertEq(cfg.usdc, address(usdc), "usdc");
        assertEq(cfg.tokenMessenger, address(messenger), "messenger");
        assertEq(cfg.destinationDomain, domain, "domain");
        assertEq(cfg.mintRecipient, recipient, "recipient");
        assertEq(cfg.destinationCaller, caller_, "caller");
        assertEq(cfg.maxFastFeeBps, bps, "bps");
        assertEq(cfg.documentCommitment, doc, "commitment");
    }

    // -------------------------------------------------------------------------
    // 21. quoteMaxFee matches actual flush fee
    // -------------------------------------------------------------------------

    function testFuzz_quoteMatchesFlush(uint256 amount, uint16 bps) public {
        amount = bound(amount, 1, 1e15);
        bps = uint16(bound(bps, 0, 100));

        bytes32 doc = keccak256(abi.encode("qf", amount, bps));
        CctpDepositForwarder fwd = _deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, bps, doc);

        uint256 quoted = fwd.quoteMaxFee(amount, true);

        _fund(address(fwd), amount);
        (, uint256 actualFee) = fwd.flush(true);

        assertEq(quoted, actualFee, "quote != actual fee");
    }

    function test_quoteMaxFee_standardAlwaysZero() public {
        CctpDepositForwarder fwd = _defaultFwd();
        assertEq(fwd.quoteMaxFee(1e18, false), 0);
        assertEq(fwd.quoteMaxFee(1, false), 0);
    }

    // -------------------------------------------------------------------------
    // 22. cloneArgs length = 142
    // -------------------------------------------------------------------------

    function test_cloneArgsLength() public view {
        bytes memory args = factory.cloneArgs(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, BPS, COMMITMENT);
        assertEq(args.length, 142);
    }

    // -------------------------------------------------------------------------
    // 23. saltOf is deterministic
    // -------------------------------------------------------------------------

    function test_saltOf_deterministic() public view {
        bytes32 s1 = factory.saltOf(1, bytes32(uint256(1)), bytes32(0), 50, keccak256("x"));
        bytes32 s2 = factory.saltOf(1, bytes32(uint256(1)), bytes32(0), 50, keccak256("x"));
        assertEq(s1, s2);
    }

    // -------------------------------------------------------------------------
    // 24. predict never returns address(0) for valid params
    // -------------------------------------------------------------------------

    function testFuzz_predictNeverZero(bytes32 recipient, bytes32 caller_, uint16 bps, bytes32 doc) public view {
        recipient = bytes32(uint256(uint160(uint256(recipient))));
        vm.assume(recipient != bytes32(0) && doc != bytes32(0));
        caller_ = bytes32(uint256(uint160(uint256(caller_))));
        bps = uint16(bound(bps, 0, 100));
        uint32 domain = (uint256(doc) % 2 == 0) ? DOMAIN_AVALANCHE : DOMAIN_ARC;

        address predicted = factory.predict(domain, recipient, caller_, bps, doc);
        assertTrue(predicted != address(0));
    }

    // -------------------------------------------------------------------------
    // 25. Flushed event emission
    // -------------------------------------------------------------------------

    function test_flushedEventEmitted() public {
        CctpDepositForwarder fwd = _defaultFwd();
        uint256 amount = 500e6;
        _fund(address(fwd), amount);

        vm.recordLogs();
        fwd.flush(true);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Find the Flushed event (topic0 = keccak256("Flushed(uint256,bool,uint256,uint32,bytes32,bytes32)"))
        bytes32 flushedSig = keccak256("Flushed(uint256,bool,uint256,uint32,bytes32,bytes32)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == flushedSig) {
                found = true;
                (uint256 logAmt, bool logFast, uint256 logFee, uint32 logDomain, bytes32 logRecipient, bytes32 logDoc) =
                    abi.decode(logs[i].data, (uint256, bool, uint256, uint32, bytes32, bytes32));
                assertEq(logAmt, amount, "log amount");
                assertTrue(logFast, "log fast");
                assertEq(logDomain, DOMAIN_AVALANCHE, "log domain");
                assertEq(logRecipient, RECIPIENT, "log recipient");
                assertEq(logDoc, COMMITMENT, "log commitment");
                assertLt(logFee, amount, "log fee < amount");
                break;
            }
        }
        assertTrue(found, "Flushed event not emitted");
    }

    // -------------------------------------------------------------------------
    // 26. ForwarderDeployed event emission
    // -------------------------------------------------------------------------

    function test_forwarderDeployedEvent() public {
        vm.recordLogs();
        address fwd = factory.deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, BPS, COMMITMENT);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("ForwarderDeployed(address,uint32,bytes32,bytes32)");
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                found = true;
                // topics[1] = indexed forwarder, topics[2] = indexed mintRecipient, topics[3] = indexed commitment
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(fwd))), "forwarder in event");
                assertEq(logs[i].topics[2], RECIPIENT, "mintRecipient in event");
                assertEq(logs[i].topics[3], COMMITMENT, "commitment in event");
                break;
            }
        }
        assertTrue(found, "ForwarderDeployed not emitted");
    }

    // -------------------------------------------------------------------------
    // 27. Address derivation pinned independently of the factory (off-chain predictors)
    // -------------------------------------------------------------------------

    /// @dev Rebuilds OZ 5.x immutable-args clone init code byte-for-byte and derives CREATE2 by hand,
    ///      so an off-chain predictor (viem) can mirror exactly this formula.
    function testFuzz_addressDerivation_independent(
        bytes32 recipient,
        bytes32 caller_,
        uint16 bps,
        bytes32 doc,
        bool arc
    ) public view {
        recipient = bytes32(uint256(uint160(uint256(recipient))));
        vm.assume(recipient != bytes32(0) && doc != bytes32(0));
        caller_ = bytes32(uint256(uint160(uint256(caller_))));
        bps = uint16(bound(bps, 0, 100));
        uint32 domain = arc ? DOMAIN_ARC : DOMAIN_AVALANCHE;
        bytes memory args = abi.encodePacked(address(usdc), address(messenger), domain, recipient, caller_, bps, doc);
        assertEq(args.length, 142);
        bytes memory initCode = abi.encodePacked(
            hex"61",
            uint16(0x2d + args.length),
            hex"3d81600a3d39f3363d3d373d3d3d363d73",
            address(impl),
            hex"5af43d82803e903d91602b57fd5bf3",
            args
        );
        bytes32 salt = keccak256(abi.encode(domain, recipient, caller_, bps, doc));
        address expected = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(initCode)))))
        );
        assertEq(factory.predict(domain, recipient, caller_, bps, doc), expected, "predict != hand-derived CREATE2");
    }

    // -------------------------------------------------------------------------
    // 28. Funds at one address are unreachable by a forwarder with any other args
    // -------------------------------------------------------------------------

    function test_counterfactual_otherArgsCannotReachFunds() public {
        address victim = factory.predict(DOMAIN_ARC, RECIPIENT, bytes32(0), 10, COMMITMENT);
        _fund(victim, 1_000e6);

        bytes32 attacker = bytes32(uint256(0xBAD));
        address other = factory.deploy(DOMAIN_ARC, attacker, bytes32(0), 10, COMMITMENT);
        assertTrue(other != victim);
        vm.expectRevert(CctpDepositForwarder.NothingToFlush.selector);
        CctpDepositForwarder(other).flush(true);
        assertEq(usdc.balanceOf(victim), 1_000e6, "victim funds untouched");

        // Only the exact args reach them, and they go to RECIPIENT on Arc.
        factory.deployAndFlush(DOMAIN_ARC, RECIPIENT, bytes32(0), 10, COMMITMENT, true);
        MockTokenMessengerV2.BurnCall memory c = messenger.getCall(0);
        assertEq(c.mintRecipient, RECIPIENT);
        assertEq(c.destinationDomain, DOMAIN_ARC);
        assertEq(c.amount, 1_000e6);
        assertEq(c.maxFee, 1e6); // floor(1000e6 * 10 / 1e4)
    }

    // -------------------------------------------------------------------------
    // 29. Front-run deploy does not break deployAndFlush
    // -------------------------------------------------------------------------

    function test_frontRunDeploy_thenDeployAndFlush() public {
        address predicted = factory.predict(DOMAIN_ARC, RECIPIENT, bytes32(0), 10, COMMITMENT);
        _fund(predicted, 5e6);
        vm.prank(address(0xF00D));
        factory.deploy(DOMAIN_ARC, RECIPIENT, bytes32(0), 10, COMMITMENT);
        (address fwd, uint256 amt,) = factory.deployAndFlush(DOMAIN_ARC, RECIPIENT, bytes32(0), 10, COMMITMENT, false);
        assertEq(fwd, predicted);
        assertEq(amt, 5e6);
    }

    // -------------------------------------------------------------------------
    // 30. Post-condition: balance must be fully burned
    // -------------------------------------------------------------------------

    function test_refund_BalanceNotBurned_fundsStay() public {
        CctpDepositForwarder fwd = _defaultFwd();
        _fund(address(fwd), 10e6);
        messenger.setRefundOne(true);
        vm.expectRevert(CctpDepositForwarder.BalanceNotBurned.selector);
        fwd.flush(true);
        assertEq(usdc.balanceOf(address(fwd)), 10e6);
        assertEq(usdc.allowance(address(fwd), address(messenger)), 0);
    }

    // -------------------------------------------------------------------------
    // 31. Reentrancy from the messenger is blocked; funds stay
    // -------------------------------------------------------------------------

    function test_reentrantFlush_reverts_fundsStay() public {
        CctpDepositForwarder fwd = _defaultFwd();
        _fund(address(fwd), 10e6);
        messenger.setReenter(true);
        // The guard must be what stops it (without it the inner call would hit NothingToFlush).
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        fwd.flush(true);
        assertEq(usdc.balanceOf(address(fwd)), 10e6);
        assertEq(messenger.callCount(), 0);
    }

    // -------------------------------------------------------------------------
    // 32. Any ETH path reverts (value with data, plain transfer, unknown selector)
    // -------------------------------------------------------------------------

    function test_ethAndUnknownSelector_revert() public {
        CctpDepositForwarder fwd = _defaultFwd();
        vm.deal(address(this), 1 ether);
        (bool ok1,) = address(fwd).call{value: 1}(hex"deadbeef");
        (bool ok2,) = address(fwd).call(hex"deadbeef");
        (bool ok3,) = address(fwd).call{value: 1}(abi.encodeCall(CctpDepositForwarder.flush, (true)));
        assertFalse(ok1);
        assertFalse(ok2);
        assertFalse(ok3, "flush is non-payable");
        vm.expectRevert();
        payable(address(fwd)).transfer(1);
        assertEq(address(fwd).balance, 0);
    }

    // -------------------------------------------------------------------------
    // 33. Rogue clone with malformed args (not from this factory) cannot decode
    // -------------------------------------------------------------------------

    function test_rogueClone_badArgsLength() public {
        bytes memory args = new bytes(141);
        address rogue = Clones.cloneWithImmutableArgs(address(impl), args);
        vm.expectRevert(abi.encodeWithSelector(CctpDepositForwarder.BadArgsLength.selector, uint256(141)));
        CctpDepositForwarder(rogue).config();
    }

    // -------------------------------------------------------------------------
    // 34. Fee quote never overflows and never reaches amount
    // -------------------------------------------------------------------------

    function testFuzz_quoteMaxFee_fullRange(uint256 amount) public {
        CctpDepositForwarder fwd = _deploy(DOMAIN_ARC, RECIPIENT, bytes32(0), 100, COMMITMENT);
        uint256 q = fwd.quoteMaxFee(amount, true);
        if (amount == 0) assertEq(q, 0);
        else assertLt(q, amount);
        assertEq(fwd.quoteMaxFee(type(uint256).max, true), type(uint256).max / 100);
        assertEq(fwd.quoteMaxFee(amount, false), 0);
    }

    // -------------------------------------------------------------------------
    // 35. deployAndFlush validates before deploying
    // -------------------------------------------------------------------------

    function test_deployAndFlush_validation() public {
        vm.expectRevert(abi.encodeWithSelector(CctpDepositForwarderFactory.UnsupportedDomain.selector, uint32(6)));
        factory.deployAndFlush(6, RECIPIENT, bytes32(0), 10, COMMITMENT, true);
        vm.expectRevert(abi.encodeWithSelector(CctpDepositForwarderFactory.UnsupportedDomain.selector, uint32(0)));
        factory.predict(0, RECIPIENT, bytes32(0), 10, COMMITMENT);
        vm.expectRevert(CctpDepositForwarderFactory.ZeroMintRecipient.selector);
        factory.deployAndFlush(26, bytes32(0), bytes32(0), 10, COMMITMENT, true);
        vm.expectRevert(CctpDepositForwarderFactory.ZeroDocumentCommitment.selector);
        factory.deployAndFlush(26, RECIPIENT, bytes32(0), 10, bytes32(0), true);
        vm.expectRevert(abi.encodeWithSelector(CctpDepositForwarderFactory.FeeBpsTooHigh.selector, uint16(101)));
        factory.deployAndFlush(26, RECIPIENT, bytes32(0), 101, COMMITMENT, true);
    }

    function testFuzz_onlyArcAndAvalancheAccepted(uint32 domain) public {
        if (domain == DOMAIN_ARC || domain == DOMAIN_AVALANCHE) {
            assertTrue(factory.predict(domain, RECIPIENT, bytes32(0), 10, COMMITMENT) != address(0));
        } else {
            vm.expectRevert(abi.encodeWithSelector(CctpDepositForwarderFactory.UnsupportedDomain.selector, domain));
            factory.predict(domain, RECIPIENT, bytes32(0), 10, COMMITMENT);
        }
    }

    function test_F17_fullBalanceFlushRevertsWhenBalanceExceedsPerMessageBurnLimit() public {
        CctpDepositForwarder fwd = _defaultFwd();
        _fund(address(fwd), 2_000_000e6);
        (uint256 amount1,) = fwd.flushUpTo(1_000_000e6, false);
        assertEq(amount1, 1_000_000e6);
        assertEq(usdc.balanceOf(address(fwd)), 1_000_000e6);
        (uint256 amount2,) = fwd.flushUpTo(1_000_000e6, false);
        assertEq(amount2, 1_000_000e6);
        assertEq(usdc.balanceOf(address(fwd)), 0);
    }

    function test_F18_factoryPermitsZeroDestinationCallerWildcard() public {
        bytes32 dirtyCaller = bytes32(uint256(1) << 255);
        vm.expectRevert(
            abi.encodeWithSelector(CctpDepositForwarderFactory.NonCanonicalDestinationCaller.selector, dirtyCaller)
        );
        factory.deploy(DOMAIN_ARC, RECIPIENT, dirtyCaller, BPS, COMMITMENT);

        vm.expectRevert(CctpDepositForwarderFactory.ZeroDestinationCaller.selector);
        factory.deployCallerRestricted(DOMAIN_ARC, RECIPIENT, bytes32(0), BPS, COMMITMENT);

        vm.expectRevert(CctpDepositForwarderFactory.ZeroDestinationCaller.selector);
        factory.predictCallerRestricted(DOMAIN_ARC, RECIPIENT, bytes32(0), BPS, COMMITMENT);

        address fwd = factory.deployCallerRestricted(DOMAIN_ARC, RECIPIENT, CALLER_B32, BPS, COMMITMENT);
        CctpDepositForwarder.ForwarderConfig memory cfg = CctpDepositForwarder(fwd).config();
        assertEq(cfg.destinationCaller, CALLER_B32);
    }

    function test_F19_strictZeroEqualityInvariantsOnAllowanceAndPostBurnBalance() public {
        CctpDepositForwarder fwd = _defaultFwd();
        _fund(address(fwd), 100e6);
        fwd.flush(true);
        assertEq(usdc.allowance(address(fwd), address(messenger)), 0);
        assertEq(usdc.balanceOf(address(fwd)), 0);
    }

    // -------------------------------------------------------------------------
    // 36. BugPoCer remediation regression tests (5.1.16, 5.2.9, 5.2.11)
    // -------------------------------------------------------------------------

    function test_BugPoCer_5_1_16_chunkedFlushUpToCannotBypassMaxFastFeeBps() public {
        uint16 bps = 1; // 0.01%
        CctpDepositForwarder fwd = _deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, bps, keccak256("bugpocer-5-1-16"));
        _fund(address(fwd), 10_000);

        uint256 totalBurned;
        uint256 totalMaxFee;
        for (uint256 i = 0; i < 50; i++) {
            (uint256 amt, uint256 fee) = fwd.flushUpTo(2, true);
            totalBurned += amt;
            totalMaxFee += fee;
        }
        (uint256 remAmt, uint256 remFee) = fwd.flushUpTo(9_900, true);
        totalBurned += remAmt;
        totalMaxFee += remFee;

        assertEq(totalBurned, 10_000);
        assertLe(totalMaxFee, (totalBurned * bps) / 10_000, "chunked flushUpTo exceeded cumulative bps cap");
        assertEq(totalMaxFee, 0, "sub-10_000 chunks at 1 bps must floor to 0");

        _fund(address(fwd), 25_000);
        (uint256 c1Amt, uint256 c1Fee) = fwd.flushUpTo(12_500, true);
        (uint256 c2Amt, uint256 c2Fee) = fwd.flushUpTo(12_500, true);
        assertEq(c1Amt + c2Amt, 25_000);
        assertEq(c1Fee, 1);
        assertEq(c2Fee, 1);
        assertLe(c1Fee + c2Fee, (25_000 * bps) / 10_000);
    }

    function test_BugPoCer_5_2_9_factoryRejectsNonCanonicalMintRecipient() public {
        bytes32 highBitRecipient = bytes32(uint256(1) << 255) | RECIPIENT;
        bytes32 boundaryDirtyRecipient = bytes32(uint256(1) << 160);
        bytes memory expectedHighBitErr =
            abi.encodeWithSelector(CctpDepositForwarderFactory.NonCanonicalMintRecipient.selector, highBitRecipient);
        bytes memory expectedBoundaryErr = abi.encodeWithSelector(
            CctpDepositForwarderFactory.NonCanonicalMintRecipient.selector, boundaryDirtyRecipient
        );

        vm.expectRevert(expectedHighBitErr);
        factory.predict(DOMAIN_AVALANCHE, highBitRecipient, CALLER_B32, BPS, COMMITMENT);

        vm.expectRevert(expectedHighBitErr);
        factory.deploy(DOMAIN_AVALANCHE, highBitRecipient, CALLER_B32, BPS, COMMITMENT);

        vm.expectRevert(expectedHighBitErr);
        factory.deployAndFlush(DOMAIN_AVALANCHE, highBitRecipient, CALLER_B32, BPS, COMMITMENT, true);

        vm.expectRevert(expectedHighBitErr);
        factory.predictCallerRestricted(DOMAIN_AVALANCHE, highBitRecipient, CALLER_B32, BPS, COMMITMENT);

        vm.expectRevert(expectedHighBitErr);
        factory.deployCallerRestricted(DOMAIN_AVALANCHE, highBitRecipient, CALLER_B32, BPS, COMMITMENT);

        vm.expectRevert(expectedBoundaryErr);
        factory.predict(DOMAIN_ARC, boundaryDirtyRecipient, CALLER_B32, BPS, COMMITMENT);

        vm.expectRevert(expectedBoundaryErr);
        factory.deploy(DOMAIN_ARC, boundaryDirtyRecipient, CALLER_B32, BPS, COMMITMENT);

        // Max canonical 20-byte address (bit 159 set, upper 96 bits zero) must succeed.
        bytes32 maxCanonical = bytes32(uint256(type(uint160).max));
        address predicted = factory.predict(DOMAIN_ARC, maxCanonical, CALLER_B32, BPS, COMMITMENT);
        address deployed = factory.deploy(DOMAIN_ARC, maxCanonical, CALLER_B32, BPS, COMMITMENT);
        assertEq(deployed, predicted);
    }

    function test_BugPoCer_5_2_11_zeroFeeBpsForcesStandardFinalityThreshold() public {
        CctpDepositForwarder fwd = _deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, 0, keccak256("bugpocer-5-2-11"));
        _fund(address(fwd), 1_000e6);

        bytes32 flushedSig = keccak256("Flushed(uint256,bool,uint256,uint32,bytes32,bytes32)");

        vm.recordLogs();
        (uint256 amt1, uint256 fee1) = fwd.flushUpTo(400e6, true);
        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        assertEq(amt1, 400e6);
        assertEq(fee1, 0);
        MockTokenMessengerV2.BurnCall memory call1 = messenger.getCall(0);
        assertEq(
            call1.minFinalityThreshold, fwd.STANDARD_FINALITY_THRESHOLD(), "flushUpTo must force standard threshold"
        );
        assertEq(call1.maxFee, 0);
        _assertFlushedFastFlag(logs1, flushedSig, false, 0);

        vm.recordLogs();
        (uint256 amt2, uint256 fee2) = fwd.flush(true);
        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        assertEq(amt2, 600e6);
        assertEq(fee2, 0);
        MockTokenMessengerV2.BurnCall memory call2 = messenger.getCall(1);
        assertEq(call2.minFinalityThreshold, fwd.STANDARD_FINALITY_THRESHOLD(), "flush must force standard threshold");
        assertEq(call2.maxFee, 0);
        _assertFlushedFastFlag(logs2, flushedSig, false, 0);
    }

    // -------------------------------------------------------------------------
    // 37. Mutation-hardening tests for CctpDepositForwarder
    // -------------------------------------------------------------------------

    function test_mutation_maxFastFeeBpsCapConstant() public view {
        assertEq(impl.MAX_FAST_FEE_BPS_CAP(), 100);
        assertEq(factory.MAX_FAST_FEE_BPS_CAP(), 100);
    }

    function test_mutation_reentrantFlushUpTo_reverts_fundsStay() public {
        OneShotReentrantMessenger reentrantMessenger = new OneShotReentrantMessenger();
        CctpDepositForwarderFactory localFactory =
            new CctpDepositForwarderFactory(address(impl), address(usdc), address(reentrantMessenger));
        CctpDepositForwarder fwd =
            CctpDepositForwarder(localFactory.deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, BPS, COMMITMENT));
        _fund(address(fwd), 10e6);

        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        fwd.flushUpTo(5e6, true);

        assertEq(usdc.balanceOf(address(fwd)), 10e6);
        assertEq(reentrantMessenger.callCount(), 0);
    }

    function test_mutation_impl_flushUpTo_notAClone() public {
        vm.expectRevert(CctpDepositForwarder.NotAClone.selector);
        impl.flushUpTo(0, false);

        vm.expectRevert(CctpDepositForwarder.NotAClone.selector);
        impl.flushUpTo(1, false);
    }

    function test_mutation_impl_quoteMaxFeeStandard_notAClone() public {
        vm.expectRevert(CctpDepositForwarder.NotAClone.selector);
        impl.quoteMaxFee(1e6, false);
    }

    function test_mutation_overBurn_BalanceNotBurned_fundsStay() public {
        OverBurnUSDC overBurnToken = new OverBurnUSDC();
        CctpDepositForwarderFactory localFactory =
            new CctpDepositForwarderFactory(address(impl), address(overBurnToken), address(messenger));
        CctpDepositForwarder fwd =
            CctpDepositForwarder(localFactory.deploy(DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, BPS, COMMITMENT));

        overBurnToken.mint(address(fwd), 100e6);
        overBurnToken.setBurnExtraOnTransferFrom(true);

        // Allowance is fully consumed while balance drops below expectedRemaining (50e6 - 1 < 50e6).
        vm.expectRevert(CctpDepositForwarder.BalanceNotBurned.selector);
        fwd.flushUpTo(50e6, false);

        assertEq(overBurnToken.balanceOf(address(fwd)), 100e6);
        assertEq(overBurnToken.allowance(address(fwd), address(messenger)), 0);
    }

    function test_mutation_rogueClone_bpsAtOrAbove10000_clampedToAmountMinusOne() public {
        bytes memory argsAt10000 = abi.encodePacked(
            address(usdc), address(messenger), DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, uint16(10_000), COMMITMENT
        );
        CctpDepositForwarder rogueEq = CctpDepositForwarder(Clones.cloneWithImmutableArgs(address(impl), argsAt10000));
        assertEq(rogueEq.quoteMaxFee(100, true), 99, "bps == 10_000 must clamp to amount - 1");
        assertEq(rogueEq.quoteMaxFee(1, true), 0, "amount == 1 must clamp to 0");

        bytes memory argsAbove10000 = abi.encodePacked(
            address(usdc), address(messenger), DOMAIN_AVALANCHE, RECIPIENT, CALLER_B32, uint16(20_000), COMMITMENT
        );
        CctpDepositForwarder rogueGt =
            CctpDepositForwarder(Clones.cloneWithImmutableArgs(address(impl), argsAbove10000));
        assertEq(rogueGt.quoteMaxFee(100, true), 99, "bps > 10_000 must clamp to amount - 1");
    }

    function test_mutation_pendingAmount_returnsUsdcBalance() public {
        CctpDepositForwarder fwd = _defaultFwd();
        assertEq(fwd.pendingAmount(), 0);
        _fund(address(fwd), 42e6);
        assertEq(fwd.pendingAmount(), 42e6);
    }

    function _assertFlushedFastFlag(Vm.Log[] memory logs, bytes32 flushedSig, bool expectedFast, uint256 expectedFee)
        internal
        pure
    {
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == flushedSig) {
                found = true;
                (, bool logFast, uint256 logFee,,,) =
                    abi.decode(logs[i].data, (uint256, bool, uint256, uint32, bytes32, bytes32));
                assertEq(logFast, expectedFast, "Flushed fast flag mismatch");
                assertEq(logFee, expectedFee, "Flushed maxFee mismatch");
                break;
            }
        }
        assertTrue(found, "Flushed event not emitted");
    }
}

/// @dev Local ERC20 test helper that burns 1 extra unit from `from` during `transferFrom`
///      after consuming the exact allowance, exercising `balanceAfter < expectedRemaining`.
contract OverBurnUSDC is MockUSDC {
    bool public burnExtraOnTransferFrom;

    function setBurnExtraOnTransferFrom(bool v) external {
        burnExtraOnTransferFrom = v;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        bool ok = super.transferFrom(from, to, value);
        if (burnExtraOnTransferFrom) {
            _burn(from, 1);
        }
        return ok;
    }
}

/// @dev Local messenger helper that re-enters `flushUpTo` exactly once so removing `nonReentrant`
///      on `flushUpTo` cannot be masked by a second-level re-entry into `flush`.
contract OneShotReentrantMessenger is ITokenMessengerV2 {
    bool internal _reentered;
    uint256 public callCount;

    function depositForBurnWithHook(
        uint256 amount,
        uint32,
        bytes32,
        address burnToken,
        bytes32,
        uint256,
        uint32,
        bytes calldata
    ) external override {
        MockUSDC(burnToken).transferFrom(msg.sender, address(this), amount);
        callCount++;
        if (!_reentered) {
            _reentered = true;
            CctpDepositForwarder(msg.sender).flushUpTo(amount, true);
        }
    }
}
