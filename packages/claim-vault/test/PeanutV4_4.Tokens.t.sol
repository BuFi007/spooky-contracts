// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {PeanutV4} from "../src/V4/PeanutV4.4.sol";
import {ClaimSigs} from "./utils/ClaimSigs.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Dec is ERC20 {
    uint8 immutable d;
    constructor(uint8 d_) ERC20("T", "T") { d = d_; }
    function decimals() public view override returns (uint8) { return d; }
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// USDT-style: transfer/transferFrom return nothing.
contract NoReturn {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external { allowance[msg.sender][s] = a; }
    function transfer(address to, uint256 a) external { balanceOf[msg.sender] -= a; balanceOf[to] += a; }
    function transferFrom(address f, address to, uint256 a) external {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a;
    }
}

/// Returns false (does not revert) on transfer to a flagged address.
contract FalseOnBlocked is ERC20 {
    address public blocked;
    constructor() ERC20("F", "F") {}
    function setBlocked(address b) external { blocked = b; }
    function mint(address to, uint256 a) external { _mint(to, a); }
    function transfer(address to, uint256 a) public override returns (bool) {
        if (to == blocked) return false;
        return super.transfer(to, a);
    }
}

/// 1% fee on every transfer.
contract FeeOnTransfer is ERC20 {
    constructor() ERC20("FEE", "FEE") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function _transfer(address f, address t, uint256 a) internal override {
        uint256 fee = a / 100;
        super._transfer(f, address(0xdead), fee);
        super._transfer(f, t, a - fee);
    }
}

/// Answers the coordinator's question: does the vault's ERC-20 deposit path handle
/// 6/8/18-dp tokens and non-standard returns? (Yes; inexact receipts are rejected.)
contract PeanutV44TokensTest is ClaimSigs {
    PeanutV4 vault;
    uint256 linkPk = 0xA11CE;
    uint256 authPk = 0xB0B;
    address sender = makeAddr("sender");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.chainId(5042002);
        vault = new PeanutV4(address(0), vm.addr(authPk));
    }

    function _roundTrip(address token, uint256 amount) internal {
        vm.prank(sender);
        uint256 idx = vault.makeMFADeposit(token, 1, amount, 0, vm.addr(linkPk));
        bytes memory link = sign(linkPk, linkDigest(block.chainid, address(vault), idx, alice, MODE_ANYONE));
        bytes memory mfa = sign(authPk, mfaDigest(block.chainid, address(vault), idx, alice));
        vault.withdrawMFADeposit(idx, alice, link, mfa);
    }

    function test_decimals_6_8_18() public {
        uint8[3] memory ds = [uint8(6), 8, 18];
        for (uint256 i; i < 3; ++i) {
            Dec t = new Dec(ds[i]);
            uint256 amount = 123 * 10 ** ds[i] + 7; // odd base units, no scaling anywhere
            t.mint(sender, amount);
            vm.prank(sender);
            t.approve(address(vault), amount);
            _roundTrip(address(t), amount);
            assertEq(t.balanceOf(alice), amount);
            assertEq(t.balanceOf(address(vault)), 0);
            vm.prank(alice);
            t.transfer(address(1), amount); // reset for next loop
        }
    }

    function test_noReturnToken_works() public {
        NoReturn t = new NoReturn();
        t.mint(sender, 5e18);
        vm.prank(sender);
        t.approve(address(vault), 5e18);
        _roundTrip(address(t), 5e18);
        assertEq(t.balanceOf(alice), 5e18);
    }

    function test_falseReturningToken_revertsClaim() public {
        FalseOnBlocked t = new FalseOnBlocked();
        t.mint(sender, 1e6);
        vm.prank(sender);
        t.approve(address(vault), 1e6);
        t.setBlocked(alice);
        vm.prank(sender);
        uint256 idx = vault.makeMFADeposit(address(t), 1, 1e6, 0, vm.addr(linkPk));
        bytes memory link = sign(linkPk, linkDigest(block.chainid, address(vault), idx, alice, MODE_ANYONE));
        bytes memory mfa = sign(authPk, mfaDigest(block.chainid, address(vault), idx, alice));
        vm.expectRevert("SafeERC20: ERC20 operation did not succeed");
        vault.withdrawMFADeposit(idx, alice, link, mfa);
        assertFalse(vault.getDeposit(idx).claimed); // whole claim reverted, still claimable
    }

    /// BUFI: inexact receipts cannot create liabilities against another user's funds.
    function test_feeOnTransfer_depositRevertsWithoutLiability() public {
        FeeOnTransfer t = new FeeOnTransfer();
        t.mint(sender, 100e18);
        vm.prank(sender);
        t.approve(address(vault), 100e18);
        vm.prank(sender);
        vm.expectRevert("INEXACT TOKEN RECEIPT");
        vault.makeMFADeposit(address(t), 1, 100e18, 0, vm.addr(linkPk));
        assertEq(vault.getDepositCount(), 0);
        assertEq(t.balanceOf(address(vault)), 0);
        assertEq(t.balanceOf(sender), 100e18);
    }
}
