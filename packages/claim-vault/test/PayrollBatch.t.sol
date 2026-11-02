// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {console2} from "forge-std/console2.sol";

import {PeanutV4} from "../src/V4/PeanutV4.4.sol";
import {PayrollBatch} from "../src/payroll/PayrollBatch.sol";
import {ISignatureTransfer} from "../src/interfaces/ISignatureTransfer.sol";
import {IPeanutV4MFAVault} from "../src/interfaces/IPeanutV4MFAVault.sol";
import {ClaimSigs} from "./utils/ClaimSigs.sol";

contract PBToken is ERC20 {
    uint8 private immutable d;
    constructor(uint8 d_) ERC20("PB", "PB") { d = d_; }
    function decimals() public view override returns (uint8) { return d; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// USDT-style: no return values.
contract PBNoReturn {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external { allowance[msg.sender][s] = a; }
    function transfer(address to, uint256 a) external { balanceOf[msg.sender] -= a; balanceOf[to] += a; }
    function transferFrom(address f, address to, uint256 a) external {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a;
    }
}

/// Burns 1% on every transfer.
contract PBFeeToken is ERC20 {
    constructor() ERC20("FEE", "FEE") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function _transfer(address f, address t, uint256 a) internal override {
        uint256 fee = a / 100;
        super._transfer(f, t, a - fee);
        if (fee > 0) _burn(f, fee);
    }
}

/// Burns 1% only when transferring out of `taxedSender` (simulating outbound-only fee on _payAll).
contract PBOutboundFeeToken is ERC20 {
    address public immutable taxedSender;
    constructor(address s) ERC20("OUTFEE", "OUTFEE") { taxedSender = s; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function _transfer(address f, address t, uint256 a) internal override {
        if (f == taxedSender) {
            uint256 fee = a / 100;
            super._transfer(f, t, a - fee);
            if (fee > 0) _burn(t, 0); // fee burned from sender's transfer amount
            // Burn fee from recipient share while deducting full `a` from `f`:
            // Wait: super._transfer(f, t, a - fee) leaves `fee` in `f`; burn `fee` from `f`:
            if (fee > 0) _burn(f, fee);
        } else {
            super._transfer(f, t, a);
        }
    }
}

/// Stand-in for the treasury MSCA: validates ERC-1271 against one owner key, and can only
/// `approve` (the one non-transfer call its AddressBook admits, when the spender is allowlisted).
contract MockTreasury1271 {
    address public immutable signer;
    constructor(address s) { signer = s; }
    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        return ECDSA.recover(hash, sig) == signer ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
    function approveMax(address token, address spender) external {
        require(msg.sender == signer, "NOT SIGNER");
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, type(uint256).max));
        require(ok, "APPROVE FAILED");
    }
}

contract PayrollBatchTest is ClaimSigs {
    uint256 constant ARC_TESTNET = 5042002;
    ISignatureTransfer constant PERMIT2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

    PeanutV4 vault;
    PayrollBatch batch;
    MockTreasury1271 treasury;
    PBToken usd6; // USDC-like, 6dp
    PBToken fx18; // JPYC / Ripio-W-like, 18dp

    uint256 quorumPk = uint256(keccak256("treasury quorum"));
    uint256 authPk = uint256(keccak256("mfa authorizer"));
    uint256 linkPk = uint256(keccak256("claim link"));
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol"); // walletless contractor, claims later
    uint256 nonceCounter;

    function setUp() public {
        vm.chainId(ARC_TESTNET);
        string memory hexCode = vm.trim(vm.readFile("test/fixtures/permit2.arc-testnet.runtime.hex"));
        vm.etch(address(PERMIT2), vm.parseBytes(hexCode));

        vault = new PeanutV4(address(0), vm.addr(authPk));
        batch = new PayrollBatch(PERMIT2, IPeanutV4MFAVault(address(vault)));
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

    // ------------------------------------------------------------------ helpers

    function _permit(address[] memory tokens, uint256[] memory amounts)
        internal
        returns (ISignatureTransfer.PermitBatchTransferFrom memory p)
    {
        p.permitted = new ISignatureTransfer.TokenPermissions[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            p.permitted[i] = ISignatureTransfer.TokenPermissions(tokens[i], amounts[i]);
        }
        p.nonce = ++nonceCounter;
        p.deadline = block.timestamp + 1 hours;
    }

    function _sign(
        ISignatureTransfer.PermitBatchTransferFrom memory p,
        bytes32 witness,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32[] memory hashes = new bytes32[](p.permitted.length);
        for (uint256 i; i < p.permitted.length; ++i) {
            hashes[i] = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, p.permitted[i].token, p.permitted[i].amount));
        }
        bytes32 typehash = keccak256(
            abi.encodePacked(
                "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,",
                batch.WITNESS_TYPE_STRING()
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(typehash, keccak256(abi.encodePacked(hashes)), address(batch), p.nonce, p.deadline, witness)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", PERMIT2.DOMAIN_SEPARATOR(), structHash));
        return sign(pk, digest);
    }

    function _oneToken(address token, uint256 amount)
        internal
        returns (ISignatureTransfer.PermitBatchTransferFrom memory)
    {
        address[] memory t = new address[](1);
        uint256[] memory a = new uint256[](1);
        t[0] = token;
        a[0] = amount;
        return _permit(t, a);
    }

    function _payouts1(address token, address to, uint256 amount) internal pure returns (PayrollBatch.Payout[] memory p) {
        p = new PayrollBatch.Payout[](1);
        p[0] = PayrollBatch.Payout(token, to, amount);
    }

    function _noClaims() internal pure returns (PayrollBatch.ClaimDeposit[] memory c) {
        c = new PayrollBatch.ClaimDeposit[](0);
    }

    function _run(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        bytes32 payrollId,
        PayrollBatch.Payout[] memory payouts,
        PayrollBatch.ClaimDeposit[] memory claims
    ) internal {
        bytes memory sig = _sign(permit, batch.witnessOf(payrollId, payouts, claims), quorumPk);
        batch.executePayroll(permit, address(treasury), sig, payrollId, payouts, claims);
    }

    // ------------------------------------------------------------------ happy path

    function test_mixedTokens_payoutsAndClaim_oneTx() public {
        PayrollBatch.Payout[] memory payouts = new PayrollBatch.Payout[](2);
        payouts[0] = PayrollBatch.Payout(address(usd6), alice, 1_500e6);
        payouts[1] = PayrollBatch.Payout(address(fx18), bob, 230_000e18);
        PayrollBatch.ClaimDeposit[] memory claims = new PayrollBatch.ClaimDeposit[](1);
        claims[0] = PayrollBatch.ClaimDeposit(address(usd6), vm.addr(linkPk), 800e6);

        address[] memory t = new address[](2);
        uint256[] memory a = new uint256[](2);
        (t[0], a[0]) = (address(usd6), 2_300e6);
        (t[1], a[1]) = (address(fx18), 230_000e18);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _permit(t, a);

        _run(permit, keccak256("payroll-1"), payouts, claims);

        assertEq(usd6.balanceOf(alice), 1_500e6);
        assertEq(fx18.balanceOf(bob), 230_000e18);
        assertEq(usd6.balanceOf(address(vault)), 800e6);
        assertEq(usd6.balanceOf(address(batch)), 0);
        assertEq(fx18.balanceOf(address(batch)), 0);
        assertEq(usd6.balanceOf(address(treasury)), 1_000_000e6 - 2_300e6);

        PeanutV4.Deposit memory d = vault.getDeposit(0);
        assertEq(d.senderAddress, address(treasury)); // reclaimer = treasury
        assertTrue(d.requiresMFA);
        assertEq(d.recipient, address(0)); // bearer link
        assertEq(uint256(d.reclaimableAfter), block.timestamp + 30 days);
        assertEq(d.pubKey20, vm.addr(linkPk));
    }

    function test_claimFromPayroll_needsLinkAndOtp_thenTreasuryRefundOnlyAfter30Days() public {
        PayrollBatch.ClaimDeposit[] memory claims = new PayrollBatch.ClaimDeposit[](2);
        claims[0] = PayrollBatch.ClaimDeposit(address(usd6), vm.addr(linkPk), 100e6);
        claims[1] = PayrollBatch.ClaimDeposit(address(usd6), vm.addr(linkPk + 1), 40e6);
        _run(_oneToken(address(usd6), 140e6), keccak256("p"), new PayrollBatch.Payout[](0), claims);

        // Contractor claims deposit 0 with link key + OTP co-signature.
        bytes memory linkSig = sign(linkPk, linkDigest(block.chainid, address(vault), 0, carol, MODE_ANYONE));
        bytes memory mfaSig = sign(authPk, mfaDigest(block.chainid, address(vault), 0, carol));
        vault.withdrawMFADeposit(0, carol, linkSig, mfaSig);
        assertEq(usd6.balanceOf(carol), 100e6);

        // Deposit 1 is never claimed: the treasury cannot pull it back inside 30 days…
        vm.prank(address(treasury));
        vm.expectRevert("TOO EARLY TO RECLAIM");
        vault.withdrawDepositSender(1);
        // …and gets it back after.
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(address(treasury));
        vault.withdrawDepositSender(1);
        assertEq(usd6.balanceOf(address(treasury)), 1_000_000e6 - 100e6);
    }

    function test_noReturnToken_works() public {
        PBNoReturn t = new PBNoReturn();
        t.mint(address(treasury), 1_000e6);
        vm.prank(vm.addr(quorumPk));
        treasury.approveMax(address(t), address(PERMIT2));
        _run(_oneToken(address(t), 10e6), keccak256("nr"), _payouts1(address(t), alice, 10e6), _noClaims());
        assertEq(t.balanceOf(alice), 10e6);
    }

    function test_donationDoesNotBlock() public {
        usd6.mint(address(batch), 1); // griefing donation
        _run(_oneToken(address(usd6), 5e6), keccak256("d"), _payouts1(address(usd6), alice, 5e6), _noClaims());
        assertEq(usd6.balanceOf(alice), 5e6);
        assertEq(usd6.balanceOf(address(batch)), 1);
    }

    // ------------------------------------------------------------------ the signature binds the list

    function test_tamperedRecipient_reverts() public {
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 10e6);
        bytes32 id = keccak256("t");
        bytes memory sig = _sign(permit, batch.witnessOf(id, _payouts1(address(usd6), alice, 10e6), _noClaims()), quorumPk);
        vm.expectRevert();
        batch.executePayroll(permit, address(treasury), sig, id, _payouts1(address(usd6), bob, 10e6), _noClaims());
    }

    function test_tamperedPayrollId_reverts() public {
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 10e6);
        PayrollBatch.Payout[] memory p = _payouts1(address(usd6), alice, 10e6);
        bytes memory sig = _sign(permit, batch.witnessOf(keccak256("a"), p, _noClaims()), quorumPk);
        vm.expectRevert();
        batch.executePayroll(permit, address(treasury), sig, keccak256("b"), p, _noClaims());
    }

    function test_wrongSigner_reverts() public {
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 10e6);
        PayrollBatch.Payout[] memory p = _payouts1(address(usd6), alice, 10e6);
        bytes memory sig = _sign(permit, batch.witnessOf(keccak256("w"), p, _noClaims()), uint256(keccak256("attacker")));
        vm.expectRevert();
        batch.executePayroll(permit, address(treasury), sig, keccak256("w"), p, _noClaims());
    }

    function test_replay_samePayrollId_reverts() public {
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 10e6);
        PayrollBatch.Payout[] memory p = _payouts1(address(usd6), alice, 10e6);
        bytes32 id = keccak256("r");
        bytes memory sig = _sign(permit, batch.witnessOf(id, p, _noClaims()), quorumPk);
        batch.executePayroll(permit, address(treasury), sig, id, p, _noClaims());
        vm.expectRevert(PayrollBatch.AlreadyExecuted.selector);
        batch.executePayroll(permit, address(treasury), sig, id, p, _noClaims());
    }

    function test_permitted_mustEqualOwed() public {
        PayrollBatch.Payout[] memory p = _payouts1(address(usd6), alice, 10e6);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 11e6);
        bytes memory sig = _sign(permit, batch.witnessOf(keccak256("m"), p, _noClaims()), quorumPk);
        vm.expectRevert(
            abi.encodeWithSelector(PayrollBatch.PermittedAmountMismatch.selector, address(usd6), 11e6, 10e6)
        );
        batch.executePayroll(permit, address(treasury), sig, keccak256("m"), p, _noClaims());
    }

    // ------------------------------------------------------------------ line validation

    function test_feeOnTransfer_reverts() public {
        PBFeeToken f = new PBFeeToken();
        f.mint(address(treasury), 1_000e18);
        vm.prank(vm.addr(quorumPk));
        treasury.approveMax(address(f), address(PERMIT2));
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(f), 100e18);
        PayrollBatch.Payout[] memory p = _payouts1(address(f), alice, 100e18);
        bytes memory sig = _sign(permit, batch.witnessOf(keccak256("f"), p, _noClaims()), quorumPk);
        vm.expectRevert(abi.encodeWithSelector(PayrollBatch.ShortReceipt.selector, address(f), 100e18, 99e18));
        batch.executePayroll(permit, address(treasury), sig, keccak256("f"), p, _noClaims());
    }

    function test_zeroLinkKey_reverts() public {
        PayrollBatch.ClaimDeposit[] memory c = new PayrollBatch.ClaimDeposit[](1);
        c[0] = PayrollBatch.ClaimDeposit(address(usd6), address(0), 1e6);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 1e6);
        bytes memory sig = _sign(permit, batch.witnessOf(keccak256("z"), new PayrollBatch.Payout[](0), c), quorumPk);
        vm.expectRevert(PayrollBatch.ZeroLinkKey.selector);
        batch.executePayroll(permit, address(treasury), sig, keccak256("z"), new PayrollBatch.Payout[](0), c);
    }

    function test_badRecipients_revert() public {
        address[3] memory bad = [address(0), address(batch), address(vault)];
        for (uint256 i; i < bad.length; ++i) {
            PayrollBatch.Payout[] memory p = _payouts1(address(usd6), bad[i], 1e6);
            ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 1e6);
            bytes32 id = keccak256(abi.encode("bad", i));
            bytes memory sig = _sign(permit, batch.witnessOf(id, p, _noClaims()), quorumPk);
            vm.expectRevert(abi.encodeWithSelector(PayrollBatch.BadRecipient.selector, bad[i]));
            batch.executePayroll(permit, address(treasury), sig, id, p, _noClaims());
        }
    }

    function test_duplicateAndUnknownTokens_revert() public {
        address[] memory t = new address[](2);
        uint256[] memory a = new uint256[](2);
        (t[0], a[0]) = (address(usd6), 1e6);
        (t[1], a[1]) = (address(usd6), 1e6);
        ISignatureTransfer.PermitBatchTransferFrom memory dup = _permit(t, a);
        PayrollBatch.Payout[] memory p = _payouts1(address(usd6), alice, 1e6);
        bytes memory sig = _sign(dup, batch.witnessOf(keccak256("u"), p, _noClaims()), quorumPk);
        vm.expectRevert(abi.encodeWithSelector(PayrollBatch.DuplicateToken.selector, address(usd6)));
        batch.executePayroll(dup, address(treasury), sig, keccak256("u"), p, _noClaims());

        ISignatureTransfer.PermitBatchTransferFrom memory only6 = _oneToken(address(usd6), 1e6);
        PayrollBatch.Payout[] memory p18 = _payouts1(address(fx18), alice, 1e6);
        bytes memory sig2 = _sign(only6, batch.witnessOf(keccak256("u2"), p18, _noClaims()), quorumPk);
        vm.expectRevert(abi.encodeWithSelector(PayrollBatch.UnknownToken.selector, address(fx18)));
        batch.executePayroll(only6, address(treasury), sig2, keccak256("u2"), p18, _noClaims());
    }

    function test_empty_reverts() public {
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 1e6);
        vm.expectRevert(PayrollBatch.EmptyPayroll.selector);
        batch.executePayroll(permit, address(treasury), "", keccak256("e"), new PayrollBatch.Payout[](0), _noClaims());
    }

    // ------------------------------------------------------------------ gas

    function test_gas_50payouts_10claims() public {
        PayrollBatch.Payout[] memory p = new PayrollBatch.Payout[](50);
        PayrollBatch.ClaimDeposit[] memory c = new PayrollBatch.ClaimDeposit[](10);
        for (uint256 i; i < 50; ++i) p[i] = PayrollBatch.Payout(address(usd6), address(uint160(0x1000 + i)), 100e6);
        for (uint256 i; i < 10; ++i) c[i] = PayrollBatch.ClaimDeposit(address(usd6), vm.addr(linkPk + i), 50e6);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 50 * 100e6 + 10 * 50e6);
        bytes memory sig = _sign(permit, batch.witnessOf(keccak256("g"), p, c), quorumPk);
        uint256 g = gasleft();
        batch.executePayroll(permit, address(treasury), sig, keccak256("g"), p, c);
        console2.log("gas executePayroll 50 payouts + 10 claims:", g - gasleft());
        assertEq(usd6.balanceOf(address(vault)), 500e6);
    }

    function test_F16_payoutFeeOnTransferOrDeflationaryRecipientReverts() public {
        PBOutboundFeeToken outFee = new PBOutboundFeeToken(address(batch));
        outFee.mint(address(treasury), 1_000e18);
        vm.prank(vm.addr(quorumPk));
        treasury.approveMax(address(outFee), address(PERMIT2));

        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(outFee), 100e18);
        PayrollBatch.Payout[] memory p = _payouts1(address(outFee), alice, 100e18);
        bytes memory sig = _sign(permit, batch.witnessOf(keccak256("f16"), p, _noClaims()), quorumPk);

        vm.expectRevert(abi.encodeWithSelector(PayrollBatch.ShortReceipt.selector, address(outFee), 100e18, 99e18));
        batch.executePayroll(permit, address(treasury), sig, keccak256("f16"), p, _noClaims());
    }

    function test_F23_witnessTypeStringMatchesPermit2Spec() public view {
        assertEq(
            batch.WITNESS_TYPE_STRING(),
            "PayrollWitness witness)PayrollWitness(bytes32 payrollId,bytes32 payrollHash)TokenPermissions(address token,uint256 amount)"
        );
        assertEq(
            batch.PAYROLL_WITNESS_TYPEHASH(),
            keccak256("PayrollWitness(bytes32 payrollId,bytes32 payrollHash)")
        );
    }

    function test_F27_strictBalanceDeltaWithPriorDonation() public {
        usd6.mint(address(batch), 42);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 10e6);
        PayrollBatch.Payout[] memory p = _payouts1(address(usd6), alice, 10e6);
        bytes32 id = keccak256("f27");
        bytes memory sig = _sign(permit, batch.witnessOf(id, p, _noClaims()), quorumPk);
        batch.executePayroll(permit, address(treasury), sig, id, p, _noClaims());
        assertEq(usd6.balanceOf(alice), 10e6);
        assertEq(usd6.balanceOf(address(batch)), 42);
    }

    function test_F30_maxLinesBoundaryEnforced() public {
        PayrollBatch.Payout[] memory p = new PayrollBatch.Payout[](101);
        for (uint256 i; i < 101; ++i) {
            p[i] = PayrollBatch.Payout(address(usd6), alice, 1e6);
        }
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 101e6);
        vm.expectRevert(PayrollBatch.TooManyLines.selector);
        batch.executePayroll(permit, address(treasury), "", keccak256("f30"), p, _noClaims());
    }
}
