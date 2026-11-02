// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {PeanutV4} from "../src/V4/PeanutV4.4.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ClaimSigs} from "./utils/ClaimSigs.sol";

contract MockECO is ERC20 {
    constructor() ERC20("ECO", "ECO") {}

    function linearInflationMultiplier() external pure returns (uint256) {
        return 2;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract PeanutV44ECOTest is ClaimSigs {
    PeanutV4 vault;
    MockECO eco;
    uint256 constant LINK_PK = 0xA11CE;
    uint256 constant MFA_PK = 0xB0B;
    uint256 constant AMOUNT = 15e18;
    address sender = makeAddr("sender");
    address recipient = makeAddr("recipient");
    address relayer = makeAddr("relayer");

    function setUp() public {
        eco = new MockECO();
        vault = new PeanutV4(address(eco), vm.addr(MFA_PK));
        eco.mint(sender, AMOUNT);
        vm.prank(sender);
        eco.approve(address(vault), AMOUNT);
    }

    function _deposit() internal returns (uint256) {
        vm.prank(sender);
        return vault.makeCustomDeposit(
            address(eco), 4, AMOUNT, 0, vm.addr(LINK_PK), sender, true, recipient, uint40(30 days), false, ""
        );
    }

    function test_ECOClaimPaysSignedRecipient_notSenderOrRelayer() public {
        uint256 idx = _deposit();
        assertEq(vault.getDeposit(idx).amount, 2 * AMOUNT);
        bytes memory link = sign(LINK_PK, linkDigest(block.chainid, address(vault), idx, recipient, MODE_ANYONE));
        bytes memory mfa = sign(MFA_PK, mfaDigest(block.chainid, address(vault), idx, recipient));
        vm.prank(relayer);
        vault.withdrawMFADeposit(idx, recipient, link, mfa);
        assertEq(eco.balanceOf(recipient), AMOUNT);
        assertEq(eco.balanceOf(sender), 0);
        assertEq(eco.balanceOf(relayer), 0);
        assertEq(eco.balanceOf(address(vault)), 0);
    }

    function test_ECOReclaimStillPaysSender_andHonorsWindow() public {
        uint256 idx = _deposit();
        vm.prank(sender);
        vm.expectRevert("TOO EARLY TO RECLAIM");
        vault.withdrawDepositSender(idx);
        vm.warp(30 days + 1);
        vm.prank(sender);
        vault.withdrawDepositSender(idx);
        assertEq(eco.balanceOf(sender), AMOUNT);
        assertEq(eco.balanceOf(recipient), 0);
        assertEq(eco.balanceOf(address(vault)), 0);
    }
}
