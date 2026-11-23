// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {console2} from "forge-std/console2.sol";

import {PeanutV4} from "../src/V4/PeanutV4.4.sol";
import {PayrollBatch} from "../src/payroll/PayrollBatch.sol";
import {ClaimVaultDeployer} from "../src/deploy/ClaimVaultDeployer.sol";
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

/// Mints 1 extra unit to `target` when transferring into it (triggers `received > owed[i]` in `_pull`).
contract PBOverDeliverPullToken is ERC20 {
    address public immutable target;
    constructor(address t) ERC20("OVP", "OVP") { target = t; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function _transfer(address f, address t, uint256 a) internal override {
        super._transfer(f, t, a);
        if (t == target) _mint(t, 1);
    }
}

/// Mints 1 extra unit to recipient when transferring out of `sender_` (triggers `received > p.amount` in `_payAll`).
contract PBOverDeliverPayoutToken is ERC20 {
    address public immutable sender_;
    constructor(address s) ERC20("OVO", "OVO") { sender_ = s; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function _transfer(address f, address t, uint256 a) internal override {
        super._transfer(f, t, a);
        if (f == sender_) _mint(t, 1);
    }
}

/// Token + rogue vault pair where the vault burns 1 extra unit from `batch` during `makeCustomDeposit`,
/// triggering `balAfter < before[i]` in `_assertNoRetention`.
contract PBDrainToken is ERC20 {
    constructor() ERC20("DRN", "DRN") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function burnExtra(address from, uint256 a) external { _burn(from, a); }
}

contract PBDrainingVault is IPeanutV4MFAVault {
    function makeCustomDeposit(
        address token,
        uint8,
        uint256 amount,
        uint256,
        address,
        address,
        bool,
        address,
        uint40,
        bool,
        bytes calldata
    ) external payable returns (uint256) {
        PBDrainToken(token).transferFrom(msg.sender, address(this), amount);
        PBDrainToken(token).burnExtra(msg.sender, 1);
        return 0;
    }
}

/// Reenters `PayrollBatch.cancelPayroll` during `_payAll` transfer to verify `nonReentrant`.
contract PBReentrantToken is ERC20 {
    PayrollBatch public batch;
    address public reenterFrom;
    bytes32 public reenterId;
    uint256 public reenterDeadline;
    bytes public reenterSig;
    bool public armed;

    constructor(PayrollBatch b) ERC20("RE", "RE") { batch = b; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function arm(address from_, bytes32 id_, uint256 deadline_, bytes calldata sig_) external {
        reenterFrom = from_;
        reenterId = id_;
        reenterDeadline = deadline_;
        reenterSig = sig_;
        armed = true;
    }

    function _transfer(address f, address t, uint256 a) internal override {
        super._transfer(f, t, a);
        if (armed && f == address(batch)) {
            armed = false;
            batch.cancelPayroll(reenterFrom, reenterId, reenterDeadline, reenterSig);
        }
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
        bytes memory sig = _sign(permit, batch.witnessOf(address(treasury), payrollId, payouts, claims), quorumPk);
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
        bytes memory sig =
            _sign(permit, batch.witnessOf(address(treasury), id, _payouts1(address(usd6), alice, 10e6), _noClaims()), quorumPk);
        vm.expectRevert();
        batch.executePayroll(permit, address(treasury), sig, id, _payouts1(address(usd6), bob, 10e6), _noClaims());
    }

    function test_tamperedPayrollId_reverts() public {
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 10e6);
        PayrollBatch.Payout[] memory p = _payouts1(address(usd6), alice, 10e6);
        bytes memory sig = _sign(permit, batch.witnessOf(address(treasury), keccak256("a"), p, _noClaims()), quorumPk);
        vm.expectRevert();
        batch.executePayroll(permit, address(treasury), sig, keccak256("b"), p, _noClaims());
    }

    function test_wrongSigner_reverts() public {
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 10e6);
        PayrollBatch.Payout[] memory p = _payouts1(address(usd6), alice, 10e6);
        bytes memory sig =
            _sign(permit, batch.witnessOf(address(treasury), keccak256("w"), p, _noClaims()), uint256(keccak256("attacker")));
        vm.expectRevert();
        batch.executePayroll(permit, address(treasury), sig, keccak256("w"), p, _noClaims());
    }

    function test_replay_samePayrollId_reverts() public {
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 10e6);
        PayrollBatch.Payout[] memory p = _payouts1(address(usd6), alice, 10e6);
        bytes32 id = keccak256("r");
        bytes memory sig = _sign(permit, batch.witnessOf(address(treasury), id, p, _noClaims()), quorumPk);
        batch.executePayroll(permit, address(treasury), sig, id, p, _noClaims());
        vm.expectRevert(PayrollBatch.AlreadyExecuted.selector);
        batch.executePayroll(permit, address(treasury), sig, id, p, _noClaims());
    }

    function test_permitted_mustEqualOwed() public {
        PayrollBatch.Payout[] memory p = _payouts1(address(usd6), alice, 10e6);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 11e6);
        bytes memory sig = _sign(permit, batch.witnessOf(address(treasury), keccak256("m"), p, _noClaims()), quorumPk);
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
        bytes memory sig = _sign(permit, batch.witnessOf(address(treasury), keccak256("f"), p, _noClaims()), quorumPk);
        vm.expectRevert(abi.encodeWithSelector(PayrollBatch.ShortReceipt.selector, address(f), 100e18, 99e18));
        batch.executePayroll(permit, address(treasury), sig, keccak256("f"), p, _noClaims());
    }

    function test_zeroLinkKey_reverts() public {
        PayrollBatch.ClaimDeposit[] memory c = new PayrollBatch.ClaimDeposit[](1);
        c[0] = PayrollBatch.ClaimDeposit(address(usd6), address(0), 1e6);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 1e6);
        bytes memory sig =
            _sign(permit, batch.witnessOf(address(treasury), keccak256("z"), new PayrollBatch.Payout[](0), c), quorumPk);
        vm.expectRevert(PayrollBatch.ZeroLinkKey.selector);
        batch.executePayroll(permit, address(treasury), sig, keccak256("z"), new PayrollBatch.Payout[](0), c);
    }

    function test_badRecipients_revert() public {
        address[3] memory bad = [address(0), address(batch), address(vault)];
        for (uint256 i; i < bad.length; ++i) {
            PayrollBatch.Payout[] memory p = _payouts1(address(usd6), bad[i], 1e6);
            ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 1e6);
            bytes32 id = keccak256(abi.encode("bad", i));
            bytes memory sig = _sign(permit, batch.witnessOf(address(treasury), id, p, _noClaims()), quorumPk);
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
        bytes memory sig = _sign(dup, batch.witnessOf(address(treasury), keccak256("u"), p, _noClaims()), quorumPk);
        vm.expectRevert(abi.encodeWithSelector(PayrollBatch.DuplicateToken.selector, address(usd6)));
        batch.executePayroll(dup, address(treasury), sig, keccak256("u"), p, _noClaims());

        ISignatureTransfer.PermitBatchTransferFrom memory only6 = _oneToken(address(usd6), 1e6);
        PayrollBatch.Payout[] memory p18 = _payouts1(address(fx18), alice, 1e6);
        bytes memory sig2 = _sign(only6, batch.witnessOf(address(treasury), keccak256("u2"), p18, _noClaims()), quorumPk);
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
        bytes memory sig = _sign(permit, batch.witnessOf(address(treasury), keccak256("g"), p, c), quorumPk);
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
        bytes memory sig = _sign(permit, batch.witnessOf(address(treasury), keccak256("f16"), p, _noClaims()), quorumPk);

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
        bytes memory sig = _sign(permit, batch.witnessOf(address(treasury), id, p, _noClaims()), quorumPk);
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

    function test_F28_directPeanutV4DepositPermitsZeroPubKey20WhilePayrollBatchRejectsIt() public {
        usd6.mint(alice, 10e6);
        vm.startPrank(alice);
        usd6.approve(address(vault), 10e6);
        vm.expectRevert("ZERO PUBKEY20 REQUIRES RECIPIENT");
        vault.makeDeposit(address(usd6), 1, 10e6, 0, address(0));
        vm.stopPrank();

        PayrollBatch.ClaimDeposit[] memory c = new PayrollBatch.ClaimDeposit[](1);
        c[0] = PayrollBatch.ClaimDeposit(address(usd6), address(0), 1e6);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 1e6);
        bytes memory sig =
            _sign(permit, batch.witnessOf(address(treasury), keccak256("f28"), new PayrollBatch.Payout[](0), c), quorumPk);
        vm.expectRevert(PayrollBatch.ZeroLinkKey.selector);
        batch.executePayroll(permit, address(treasury), sig, keccak256("f28"), new PayrollBatch.Payout[](0), c);
    }

    function test_F29_peanutV4ConstructorAcceptsZeroEcoAndCancelMfaRotationAcceptsZero() public {
        assertEq(vault.ecoAddress(), address(0));
        vault.transferMFAAuthorizer(alice);
        assertEq(vault.pendingMFAAuthorizer(), alice);
        vm.expectRevert("ZERO MFA AUTHORIZER");
        vault.transferMFAAuthorizer(address(0));
        vault.cancelMFAAuthorizerTransfer();
        assertEq(vault.pendingMFAAuthorizer(), address(0));
    }

    function test_F30_peanutV4AndPayrollBatchEnforceAuthenticatedWithdrawalsAndExactBalanceDeltas() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        uint256 idx = vault.makeDeposit{value: 1 ether}(address(0), 0, 1 ether, 0, vm.addr(linkPk));

        vm.prank(bob);
        vm.expectRevert("NOT THE SENDER");
        vault.withdrawDepositSender(idx);
    }

    function test_SafeTxBuilder_Arc5042_ClaimVaultAndPayrollBatch() public {
        address create2Factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        address safe = 0x47Dc7D18A6E3a79F696714E7D47456a49B430D09;
        address mfaAuthorizer = 0x9c8515333aFdB567C31CDF53CD60868f3B64b724;
        address canonicalPermit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

        vm.etch(safe, hex"600080fd");
        vm.etch(canonicalPermit2, hex"600080fd");

        bytes32 deployerSalt = keccak256("bufi.claim-vault.deployer.v1");
        bytes memory deployerInitCode =
            abi.encodePacked(type(ClaimVaultDeployer).creationCode, abi.encode(safe, mfaAuthorizer));
        address expectedDeployer =
            vm.computeCreate2Address(deployerSalt, keccak256(deployerInitCode), create2Factory);
        address expectedVault = vm.computeCreateAddress(expectedDeployer, 1);

        bytes32 batchSalt = keccak256("bufi.payroll-batch.v1");
        bytes memory batchInitCode =
            abi.encodePacked(type(PayrollBatch).creationCode, abi.encode(canonicalPermit2, expectedVault));
        address expectedBatch = vm.computeCreate2Address(batchSalt, keccak256(batchInitCode), create2Factory);

        vm.startPrank(safe);
        (bool ok1, bytes memory r1) = create2Factory.call(abi.encodePacked(deployerSalt, deployerInitCode));
        assertTrue(ok1);
        assertEq(address(bytes20(r1)), expectedDeployer);

        PeanutV4 deployedVault = PeanutV4(payable(expectedVault));
        assertEq(deployedVault.pendingOwner(), safe);
        deployedVault.acceptOwnership();
        assertEq(deployedVault.owner(), safe);
        assertEq(deployedVault.MFA_AUTHORIZER(), mfaAuthorizer);

        (bool ok2, bytes memory r2) = create2Factory.call(abi.encodePacked(batchSalt, batchInitCode));
        assertTrue(ok2);
        PayrollBatch deployedBatch = PayrollBatch(address(bytes20(r2)));
        assertEq(address(deployedBatch), expectedBatch);
        assertEq(address(deployedBatch.VAULT()), address(deployedVault));
        assertEq(address(deployedBatch.PERMIT2()), canonicalPermit2);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ BugPoCer remediations

    function test_BugPoCer_5_2_14_payrollHashBindsFromOwner() public {
        MockTreasury1271 treasuryB = new MockTreasury1271(vm.addr(quorumPk));
        usd6.mint(address(treasuryB), 1_000_000e6);
        vm.prank(vm.addr(quorumPk));
        treasuryB.approveMax(address(usd6), address(PERMIT2));

        PayrollBatch.Payout[] memory p = _payouts1(address(usd6), alice, 10e6);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 10e6);
        bytes32 id = keccak256("bugpocer-5-2-14");

        // Zero owner rejected before state mutation.
        vm.expectRevert(PayrollBatch.ZeroAddress.selector);
        batch.executePayroll(permit, address(0), "", id, p, _noClaims());

        bytes32 witnessA = batch.witnessOf(address(treasury), id, p, _noClaims());
        bytes32 witnessB = batch.witnessOf(address(treasuryB), id, p, _noClaims());
        assertTrue(witnessA != witnessB);

        bytes memory sigForA = _sign(permit, witnessA, quorumPk);

        // Witness signed for Treasury A must NOT execute against Treasury B even though both share quorumPk.
        vm.expectRevert(bytes4(keccak256("InvalidContractSignature()")));
        batch.executePayroll(permit, address(treasuryB), sigForA, id, p, _noClaims());
        assertEq(usd6.balanceOf(address(treasuryB)), 1_000_000e6);
        assertFalse(batch.payrollExecuted(address(treasuryB), id));

        // Executing against Treasury A succeeds as intended.
        batch.executePayroll(permit, address(treasury), sigForA, id, p, _noClaims());
        assertEq(usd6.balanceOf(alice), 10e6);
    }

    function test_BugPoCer_5_2_12_cancelPayrollWithQuorumSignatureBlocksStaleExecution() public {
        PayrollBatch.Payout[] memory stalePayouts = _payouts1(address(usd6), alice, 10e6);
        ISignatureTransfer.PermitBatchTransferFrom memory stalePermit = _oneToken(address(usd6), 10e6);
        bytes32 id = keccak256("bugpocer-5-2-12");
        bytes memory staleSig = _sign(stalePermit, batch.witnessOf(address(treasury), id, stalePayouts, _noClaims()), quorumPk);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = batch.cancelPayrollDigest(address(treasury), id, deadline);
        bytes memory cancelSig = sign(quorumPk, digest);

        // Zero address rejected.
        vm.expectRevert(PayrollBatch.ZeroAddress.selector);
        batch.cancelPayroll(address(0), id, deadline, cancelSig);

        vm.expectEmit(true, true, false, false);
        emit PayrollBatch.PayrollCancelled(id, address(treasury));
        vm.prank(bob); // untrusted relayer submits valid quorum cancellation
        batch.cancelPayroll(address(treasury), id, deadline, cancelSig);
        assertTrue(batch.payrollExecuted(address(treasury), id));

        // Stale payroll execution is now permanently blocked.
        vm.expectRevert(PayrollBatch.AlreadyExecuted.selector);
        batch.executePayroll(stalePermit, address(treasury), staleSig, id, stalePayouts, _noClaims());

        // Re-cancelling the same payrollId reverts.
        vm.expectRevert(PayrollBatch.AlreadyExecuted.selector);
        batch.cancelPayroll(address(treasury), id, deadline, cancelSig);

        // Corrected payroll with a fresh payrollId succeeds; then cancelling it reverts AlreadyExecuted.
        bytes32 freshId = keccak256("bugpocer-5-2-12-fresh");
        PayrollBatch.Payout[] memory correctedPayouts = _payouts1(address(usd6), bob, 12e6);
        ISignatureTransfer.PermitBatchTransferFrom memory freshPermit = _oneToken(address(usd6), 12e6);
        _run(freshPermit, freshId, correctedPayouts, _noClaims());
        assertEq(usd6.balanceOf(bob), 12e6);

        bytes memory freshCancelSig = sign(quorumPk, batch.cancelPayrollDigest(address(treasury), freshId, deadline));
        vm.expectRevert(PayrollBatch.AlreadyExecuted.selector);
        batch.cancelPayroll(address(treasury), freshId, deadline, freshCancelSig);
    }

    function test_BugPoCer_5_2_12_cancelPayrollRejectsExpiredAndWrongSigner() public {
        uint256 startTs = 1_000;
        uint256 deadline = 1_100;
        vm.warp(startTs);
        bytes32 id = keccak256("bugpocer-5-2-12-invalid");
        bytes32 digest = batch.cancelPayrollDigest(address(treasury), id, deadline);

        // Wrong signer rejected.
        uint256 attackerPk = uint256(keccak256("attacker"));
        bytes memory wrongSig = sign(attackerPk, digest);
        vm.expectRevert(PayrollBatch.InvalidCancelSignature.selector);
        batch.cancelPayroll(address(treasury), id, deadline, wrongSig);

        // Valid signer over wrong payrollId rejected.
        bytes memory wrongIdSig = sign(quorumPk, batch.cancelPayrollDigest(address(treasury), keccak256("other"), deadline));
        vm.expectRevert(PayrollBatch.InvalidCancelSignature.selector);
        batch.cancelPayroll(address(treasury), id, deadline, wrongIdSig);

        // Expired cancellation rejected even with valid quorum signature.
        bytes memory validSig = sign(quorumPk, digest);
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(PayrollBatch.CancelExpired.selector, deadline, deadline + 1));
        batch.cancelPayroll(address(treasury), id, deadline, validSig);
        assertFalse(batch.payrollExecuted(address(treasury), id));
    }

    function test_BugPoCer_5_2_12_cancelPayrollDirectByOwner() public {
        PayrollBatch.Payout[] memory p = _payouts1(address(usd6), alice, 10e6);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 10e6);
        bytes32 id = keccak256("bugpocer-5-2-12-direct");
        bytes memory sig = _sign(permit, batch.witnessOf(address(treasury), id, p, _noClaims()), quorumPk);

        vm.expectEmit(true, true, false, false);
        emit PayrollBatch.PayrollCancelled(id, address(treasury));
        vm.prank(address(treasury));
        batch.cancelPayroll(address(treasury), id, 0, "");
        assertTrue(batch.payrollExecuted(address(treasury), id));

        vm.expectRevert(PayrollBatch.AlreadyExecuted.selector);
        batch.executePayroll(permit, address(treasury), sig, id, p, _noClaims());
    }

    // ------------------------------------------------------------------ mutation hardening

    function test_ClaimVaultDeployer_rejectsZeroAndContractAndEmitsEvent() public {
        address mfa = makeAddr("mfa-eoa");
        vm.expectRevert("ZERO OWNER");
        new ClaimVaultDeployer(address(0), mfa);

        vm.expectRevert("ZERO MFA AUTHORIZER");
        new ClaimVaultDeployer(alice, address(0));

        vm.expectRevert("MFA AUTHORIZER CANNOT BE CONTRACT");
        new ClaimVaultDeployer(alice, address(usd6));

        address expectedDeployer = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address expectedVault = vm.computeCreateAddress(expectedDeployer, 1);
        vm.expectEmit(true, true, true, true);
        emit ClaimVaultDeployer.ClaimVaultDeployed(expectedVault, alice, mfa);
        ClaimVaultDeployer deployer = new ClaimVaultDeployer(alice, mfa);
        assertEq(address(deployer), expectedDeployer);
        assertEq(PeanutV4(payable(expectedVault)).pendingOwner(), alice);
        assertEq(PeanutV4(payable(expectedVault)).MFA_AUTHORIZER(), mfa);
    }

    function test_PayrollBatch_constructorRejectsZeroAddresses() public {
        vm.expectRevert("ZERO ADDRESS");
        new PayrollBatch(ISignatureTransfer(address(0)), IPeanutV4MFAVault(address(vault)));

        vm.expectRevert("ZERO ADDRESS");
        new PayrollBatch(PERMIT2, IPeanutV4MFAVault(address(0)));
    }

    function test_PayrollBatch_zeroAmountRevertsForPayoutAndClaim() public {
        PayrollBatch.Payout[] memory p = _payouts1(address(usd6), alice, 0);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 0);
        vm.expectRevert(PayrollBatch.ZeroAmount.selector);
        batch.executePayroll(permit, address(treasury), "", keccak256("z-p"), p, _noClaims());

        PayrollBatch.ClaimDeposit[] memory c = new PayrollBatch.ClaimDeposit[](1);
        c[0] = PayrollBatch.ClaimDeposit(address(usd6), vm.addr(linkPk), 0);
        vm.expectRevert(PayrollBatch.ZeroAmount.selector);
        batch.executePayroll(permit, address(treasury), "", keccak256("z-c"), new PayrollBatch.Payout[](0), c);
    }

    function test_PayrollBatch_maxLinesExact100SucceedsAndMixed101Reverts() public {
        // 50 payouts + 51 claims = 101 lines reverts TooManyLines.
        PayrollBatch.Payout[] memory p50 = new PayrollBatch.Payout[](50);
        PayrollBatch.ClaimDeposit[] memory c51 = new PayrollBatch.ClaimDeposit[](51);
        for (uint256 i; i < 50; ++i) p50[i] = PayrollBatch.Payout(address(usd6), alice, 1e6);
        for (uint256 i; i < 51; ++i) c51[i] = PayrollBatch.ClaimDeposit(address(usd6), vm.addr(linkPk + i), 1e6);
        vm.expectRevert(PayrollBatch.TooManyLines.selector);
        batch.executePayroll(_oneToken(address(usd6), 101e6), address(treasury), "", keccak256("m101"), p50, c51);

        // Exactly 100 lines succeeds.
        PayrollBatch.Payout[] memory p100 = new PayrollBatch.Payout[](100);
        for (uint256 i; i < 100; ++i) p100[i] = PayrollBatch.Payout(address(usd6), alice, 1e6);
        _run(_oneToken(address(usd6), 100e6), keccak256("m100"), p100, _noClaims());
        assertEq(usd6.balanceOf(alice), 100e6);
    }

    function test_PayrollBatch_emitsAllEventsAndExactClaimWindow() public {
        uint256 startTs = 100 days;
        vm.warp(startTs);
        uint40 expectedUnlock = uint40(startTs) + batch.CLAIM_WINDOW();
        assertEq(batch.CLAIM_WINDOW(), 30 days);

        PayrollBatch.Payout[] memory payouts = _payouts1(address(usd6), alice, 25e6);
        PayrollBatch.ClaimDeposit[] memory claims = new PayrollBatch.ClaimDeposit[](1);
        claims[0] = PayrollBatch.ClaimDeposit(address(usd6), vm.addr(linkPk), 15e6);
        bytes32 id = keccak256("events-window");

        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(usd6), 40e6);
        bytes memory sig = _sign(permit, batch.witnessOf(address(treasury), id, payouts, claims), quorumPk);

        vm.expectEmit(true, true, true, true);
        emit PayrollBatch.PayrollPayout(id, address(usd6), alice, 25e6);
        vm.expectEmit(true, true, true, true);
        emit PayrollBatch.PayrollClaimDeposited(id, address(usd6), vm.addr(linkPk), 15e6, 0, expectedUnlock);
        vm.expectEmit(true, true, false, true);
        emit PayrollBatch.PayrollExecuted(id, address(treasury), 1, 1);

        batch.executePayroll(permit, address(treasury), sig, id, payouts, claims);
        assertEq(vault.getDeposit(0).reclaimableAfter, expectedUnlock);

        vm.warp(expectedUnlock);
        vm.prank(address(treasury));
        vm.expectRevert("TOO EARLY TO RECLAIM");
        vault.withdrawDepositSender(0);

        vm.warp(uint256(expectedUnlock) + 1);
        vm.prank(address(treasury));
        vault.withdrawDepositSender(0);
    }

    function test_PayrollBatch_recipientWithPriorBalanceAndOverDeliveringTokensRevert() public {
        // Recipient with non-zero prior balance verifies `- balBefore` (kills `+ balBefore` mutant).
        usd6.mint(alice, 777);
        _run(_oneToken(address(usd6), 10e6), keccak256("prior-bal"), _payouts1(address(usd6), alice, 10e6), _noClaims());
        assertEq(usd6.balanceOf(alice), 10e6 + 777);

        // Pull over-delivery (`received > owed[i]`): reverts ShortReceipt.
        PBOverDeliverPullToken ovPull = new PBOverDeliverPullToken(address(batch));
        ovPull.mint(address(treasury), 1_000e18);
        vm.prank(vm.addr(quorumPk));
        treasury.approveMax(address(ovPull), address(PERMIT2));
        ISignatureTransfer.PermitBatchTransferFrom memory pPull = _oneToken(address(ovPull), 100e18);
        PayrollBatch.Payout[] memory linesPull = _payouts1(address(ovPull), alice, 100e18);
        bytes memory sigPull = _sign(pPull, batch.witnessOf(address(treasury), keccak256("ovp"), linesPull, _noClaims()), quorumPk);
        vm.expectRevert(abi.encodeWithSelector(PayrollBatch.ShortReceipt.selector, address(ovPull), 100e18, 100e18 + 1));
        batch.executePayroll(pPull, address(treasury), sigPull, keccak256("ovp"), linesPull, _noClaims());

        // Payout over-delivery (`received > p.amount`): reverts ShortReceipt.
        PBOverDeliverPayoutToken ovOut = new PBOverDeliverPayoutToken(address(batch));
        ovOut.mint(address(treasury), 1_000e18);
        vm.prank(vm.addr(quorumPk));
        treasury.approveMax(address(ovOut), address(PERMIT2));
        ISignatureTransfer.PermitBatchTransferFrom memory pOut = _oneToken(address(ovOut), 100e18);
        PayrollBatch.Payout[] memory linesOut = _payouts1(address(ovOut), bob, 100e18);
        bytes memory sigOut = _sign(pOut, batch.witnessOf(address(treasury), keccak256("ovo"), linesOut, _noClaims()), quorumPk);
        vm.expectRevert(abi.encodeWithSelector(PayrollBatch.ShortReceipt.selector, address(ovOut), 100e18, 100e18 + 1));
        batch.executePayroll(pOut, address(treasury), sigOut, keccak256("ovo"), linesOut, _noClaims());
    }

    function test_PayrollBatch_vaultDrainingPriorBalanceRevertsRetained() public {
        PayrollBatch drainBatch = new PayrollBatch(PERMIT2, new PBDrainingVault());
        PBDrainToken drn = new PBDrainToken();
        drn.mint(address(treasury), 1_000e18);
        drn.mint(address(drainBatch), 10); // pre-existing donation
        vm.prank(vm.addr(quorumPk));
        treasury.approveMax(address(drn), address(PERMIT2));

        PayrollBatch.ClaimDeposit[] memory c = new PayrollBatch.ClaimDeposit[](1);
        c[0] = PayrollBatch.ClaimDeposit(address(drn), vm.addr(linkPk), 50e18);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(drn), 50e18);
        bytes32 witness = drainBatch.witnessOf(address(treasury), keccak256("drain"), new PayrollBatch.Payout[](0), c);

        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, address(drn), 50e18));
        bytes32 typehash = keccak256(
            abi.encodePacked(
                "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,",
                drainBatch.WITNESS_TYPE_STRING()
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(typehash, keccak256(abi.encodePacked(hashes)), address(drainBatch), permit.nonce, permit.deadline, witness)
        );
        bytes memory sig = sign(quorumPk, keccak256(abi.encodePacked("\x19\x01", PERMIT2.DOMAIN_SEPARATOR(), structHash)));

        vm.expectRevert(abi.encodeWithSelector(PayrollBatch.Retained.selector, address(drn)));
        drainBatch.executePayroll(permit, address(treasury), sig, keccak256("drain"), new PayrollBatch.Payout[](0), c);
    }

    function test_PayrollBatch_reentrancyGuardBlocksExecuteReenteringCancel() public {
        PBReentrantToken reToken = new PBReentrantToken(batch);
        reToken.mint(address(treasury), 1_000e18);
        vm.prank(vm.addr(quorumPk));
        treasury.approveMax(address(reToken), address(PERMIT2));

        bytes32 reenterId = keccak256("reenter-cancel");
        uint256 cancelDeadline = block.timestamp + 1 hours;
        bytes memory cancelSig = sign(quorumPk, batch.cancelPayrollDigest(address(treasury), reenterId, cancelDeadline));
        reToken.arm(address(treasury), reenterId, cancelDeadline, cancelSig);

        PayrollBatch.Payout[] memory p = _payouts1(address(reToken), alice, 10e18);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneToken(address(reToken), 10e18);
        bytes32 id = keccak256("reenter-outer");
        bytes memory sig = _sign(permit, batch.witnessOf(address(treasury), id, p, _noClaims()), quorumPk);

        vm.expectRevert("ReentrancyGuard: reentrant call");
        batch.executePayroll(permit, address(treasury), sig, id, p, _noClaims());
    }
}
