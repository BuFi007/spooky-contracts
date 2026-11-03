// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PeanutV4} from "../src/V4/PeanutV4.4.sol";
import {PayrollBatch} from "../src/payroll/PayrollBatch.sol";
import {IPeanutV4MFAVault} from "../src/interfaces/IPeanutV4MFAVault.sol";
import {ISignatureTransfer} from "../src/interfaces/ISignatureTransfer.sol";
import {PayrollPermit2, Treasury1271} from "./utils/PayrollPermit2.sol";

/// 18-dp token (Ripio wFX shape) that burns 1 wei-per-mille on every transfer.
contract Fee18 is ERC20 {
    constructor() ERC20("FEE18", "FEE18") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function _transfer(address f, address t, uint256 a) internal override {
        uint256 fee = a / 1000;
        super._transfer(f, t, a - fee);
        if (fee > 0) _burn(f, fee);
    }
}

contract Plain18 is ERC20 {
    constructor() ERC20("W18", "W18") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// A vault that records the deposit but never pulls the tokens: the batch would keep them.
contract NonPullingVault is IPeanutV4MFAVault {
    function makeCustomDeposit(
        address,
        uint8,
        uint256,
        uint256,
        address,
        address,
        bool,
        address,
        uint40,
        bool,
        bytes calldata
    ) external payable returns (uint256) {
        return 0;
    }
}

/// ShortReceipt and Retained at 18 decimals, offline (the Arc mainnet fork suite repeats the
/// Retained case against real wARS).
contract PayrollBatchReceipt18dpTest is PayrollPermit2 {
    uint256 quorumPk = uint256(keccak256("treasury quorum 18"));
    uint256 authPk = uint256(keccak256("mfa 18"));
    Treasury1271 treasury;
    address alice = makeAddr("alice");

    function setUp() public {
        vm.chainId(5042);
        vm.etch(address(PERMIT2), vm.parseBytes(vm.trim(vm.readFile("test/fixtures/permit2.arc-testnet.runtime.hex"))));
        treasury = new Treasury1271(vm.addr(quorumPk));
    }

    function _fund(address token) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", address(treasury), 1_000_000e18));
        require(ok);
        vm.prank(vm.addr(quorumPk));
        treasury.approveMax(token, address(PERMIT2));
    }

    function test_shortReceipt_18dpFeeToken_revertsWholePayroll() public {
        PayrollBatch batch =
            new PayrollBatch(PERMIT2, IPeanutV4MFAVault(address(new PeanutV4(address(0), vm.addr(authPk)))));
        Fee18 fee = new Fee18();
        _fund(address(fee));
        uint256 amount = 1_234_567_890_123_456_789_000;
        address[] memory to = new address[](1);
        uint256[] memory a = new uint256[](1);
        (to[0], a[0]) = (alice, amount);
        PayrollBatch.Payout[] memory p = _payouts(address(fee), to, a);
        PayrollBatch.ClaimDeposit[] memory none = new PayrollBatch.ClaimDeposit[](0);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneTokenPermit(address(fee), amount);
        bytes memory sig = _signPayroll(batch, permit, "s", p, none, quorumPk);

        vm.expectRevert(
            abi.encodeWithSelector(PayrollBatch.ShortReceipt.selector, address(fee), amount, amount - amount / 1000)
        );
        batch.executePayroll(permit, address(treasury), sig, "s", p, none);
        assertEq(fee.balanceOf(address(treasury)), 1_000_000e18);
        assertFalse(batch.payrollExecuted(address(treasury), "s"));
    }

    function test_retained_vaultThatDoesNotPull_revertsWholePayroll() public {
        PayrollBatch batch = new PayrollBatch(PERMIT2, new NonPullingVault());
        Plain18 w = new Plain18();
        _fund(address(w));
        PayrollBatch.Payout[] memory none = new PayrollBatch.Payout[](0);
        PayrollBatch.ClaimDeposit[] memory c = _claim(address(w), makeAddr("link"), 500e18);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneTokenPermit(address(w), 500e18);
        bytes memory sig = _signPayroll(batch, permit, "r", none, c, quorumPk);

        vm.expectRevert(abi.encodeWithSelector(PayrollBatch.Retained.selector, address(w)));
        batch.executePayroll(permit, address(treasury), sig, "r", none, c);
        assertEq(w.balanceOf(address(treasury)), 1_000_000e18);
        assertEq(w.balanceOf(address(batch)), 0);
    }
}
