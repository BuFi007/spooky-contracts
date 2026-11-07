// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {TreasuryBridgeConduit} from "../src/bufi/conduit/TreasuryBridgeConduit.sol";
import {TreasuryConduit} from "../src/bufi/conduit/TreasuryConduit.sol";
import {TreasuryRedeemConduit} from "../src/bufi/conduit/TreasuryRedeemConduit.sol";
import {TreasurySwapAndDeposit} from "../src/bufi/conduit/TreasurySwapAndDeposit.sol";

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MinimalERC20 is IERC20 {
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public override totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ConduitGovernanceGuardsTest is Test {
    address internal constant BOOTSTRAP = address(0xB00);
    address internal constant SAFE = address(0x5AFE);
    address internal constant STRANGER = address(0xBAD);

    TreasuryConduit internal conduit;
    TreasuryRedeemConduit internal redeem;
    TreasurySwapAndDeposit internal adapter;
    TreasuryBridgeConduit internal bridgeV1;
    MinimalERC20 internal usdc;

    event Rescued(address indexed token, address indexed to, uint256 amount);

    function setUp() public {
        usdc = new MinimalERC20();
        conduit = new TreasuryConduit(BOOTSTRAP);
        redeem = new TreasuryRedeemConduit(BOOTSTRAP);
        adapter = new TreasurySwapAndDeposit(BOOTSTRAP, address(usdc));
        bridgeV1 = new TreasuryBridgeConduit(BOOTSTRAP);
    }

    function test_conduit_setTarget_refuses_zero() public {
        vm.prank(BOOTSTRAP);
        vm.expectRevert(TreasuryConduit.ZeroAddress.selector);
        conduit.setTarget(address(0), true);
    }

    function test_conduit_rescue_refuses_zero_token_and_zero_recipient() public {
        usdc.mint(address(conduit), 1e6);
        vm.startPrank(BOOTSTRAP);
        vm.expectRevert(TreasuryConduit.ZeroAddress.selector);
        conduit.rescue(address(0), SAFE);
        vm.expectRevert(TreasuryConduit.ZeroAddress.selector);
        conduit.rescue(address(usdc), address(0));
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(conduit)), 1e6, "nothing moved");
    }

    function test_conduit_rescue_emits_Rescued() public {
        usdc.mint(address(conduit), 3e6);
        vm.expectEmit(true, true, false, true, address(conduit));
        emit Rescued(address(usdc), SAFE, 3e6);
        vm.prank(BOOTSTRAP);
        conduit.rescue(address(usdc), SAFE);
        assertEq(usdc.balanceOf(SAFE), 3e6);
    }

    function test_redeem_setVault_refuses_zero() public {
        vm.prank(BOOTSTRAP);
        vm.expectRevert(TreasuryRedeemConduit.ZeroAddress.selector);
        redeem.setVault(address(0), true);
    }

    function test_constructors_refuse_zero_owner() public {
        bytes memory err = abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0));
        vm.expectRevert(err);
        new TreasuryConduit(address(0));
        vm.expectRevert(err);
        new TreasuryRedeemConduit(address(0));
        vm.expectRevert(err);
        new TreasurySwapAndDeposit(address(0), address(usdc));
        vm.expectRevert(err);
        new TreasuryBridgeConduit(address(0));
    }

    function test_handover_bootstrap_to_safe_is_two_step_on_every_contract() public {
        _assertTwoStep(Ownable2Step(address(conduit)));
        _assertTwoStep(Ownable2Step(address(redeem)));
        _assertTwoStep(Ownable2Step(address(adapter)));
        _assertTwoStep(Ownable2Step(address(bridgeV1)));
    }

    function test_after_handover_the_bootstrap_key_has_no_power() public {
        vm.prank(BOOTSTRAP);
        conduit.transferOwnership(SAFE);
        vm.prank(SAFE);
        conduit.acceptOwnership();

        vm.prank(BOOTSTRAP);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", BOOTSTRAP));
        conduit.setTarget(address(0x1234), true);

        vm.prank(SAFE);
        conduit.setTarget(address(0x1234), true);
        assertTrue(conduit.targets(address(0x1234)));
    }

    function test_renounceOwnership_reverts_on_every_v3_contract() public {
        _assertRenounceDisabled(address(conduit), abi.encodeWithSelector(TreasuryConduit.RenounceDisabled.selector));
        _assertRenounceDisabled(
            address(redeem), abi.encodeWithSelector(TreasuryRedeemConduit.RenounceDisabled.selector)
        );
        _assertRenounceDisabled(
            address(adapter), abi.encodeWithSelector(TreasurySwapAndDeposit.RenounceDisabled.selector)
        );
    }

    function test_renounceOwnership_reverts_for_the_safe_after_handover() public {
        vm.prank(BOOTSTRAP);
        conduit.transferOwnership(SAFE);
        vm.prank(SAFE);
        conduit.acceptOwnership();
        vm.prank(SAFE);
        vm.expectRevert(TreasuryConduit.RenounceDisabled.selector);
        conduit.renounceOwnership();
        assertEq(conduit.owner(), SAFE, "Safe still owns");
    }

    function test_renounceOwnership_does_not_clear_a_pending_handover() public {
        vm.prank(BOOTSTRAP);
        adapter.transferOwnership(SAFE);
        vm.prank(BOOTSTRAP);
        vm.expectRevert(TreasurySwapAndDeposit.RenounceDisabled.selector);
        adapter.renounceOwnership();
        assertEq(adapter.pendingOwner(), SAFE, "handover intact");
    }

    function _assertRenounceDisabled(address c, bytes memory err) internal {
        address[2] memory callers = [BOOTSTRAP, STRANGER];
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(err);
            Ownable2Step(c).renounceOwnership();
        }
        assertEq(Ownable2Step(c).owner(), BOOTSTRAP, "owner unchanged");
    }

    function _assertTwoStep(Ownable2Step c) internal {
        vm.prank(BOOTSTRAP);
        c.transferOwnership(SAFE);
        assertEq(c.owner(), BOOTSTRAP, "owner unchanged until accepted");
        assertEq(c.pendingOwner(), SAFE, "safe pending");

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", STRANGER));
        c.acceptOwnership();

        vm.prank(SAFE);
        c.acceptOwnership();
        assertEq(c.owner(), SAFE);
        assertEq(c.pendingOwner(), address(0));
    }

    function test_F22_swapAndDepositRevertsOnZeroSharesAndRedeemChecksReturnedAssets() public {
        ZeroShareMockVault zeroVault = new ZeroShareMockVault(usdc);
        vm.prank(BOOTSTRAP);
        adapter.setDest(address(zeroVault), true);

        usdc.mint(address(this), 100e6);
        usdc.approve(address(adapter), 100e6);

        vm.expectRevert(TreasurySwapAndDeposit.ZeroShares.selector);
        adapter.run(
            address(usdc),
            100e6,
            address(0),
            "",
            TreasurySwapAndDeposit.DestKind.Vault4626,
            address(zeroVault),
            SAFE,
            100e6
        );
    }

    function test_F23_rescueEnforcesNonReentrantZeroAddressGuardsAndCeiEventOrder() public {
        usdc.mint(address(bridgeV1), 5e6);
        vm.startPrank(BOOTSTRAP);
        vm.expectRevert(TreasuryBridgeConduit.ZeroAddress.selector);
        bridgeV1.rescue(address(0), SAFE);

        vm.expectRevert(TreasuryBridgeConduit.ZeroAddress.selector);
        bridgeV1.rescue(address(usdc), address(0));

        bridgeV1.rescue(address(usdc), SAFE);
        vm.stopPrank();
        assertEq(usdc.balanceOf(SAFE), 5e6);
    }
}

contract ZeroShareMockVault {
    MinimalERC20 public immutable assetToken;

    constructor(MinimalERC20 assetToken_) {
        assetToken = assetToken_;
    }

    function noopSwap() external {}

    function deposit(uint256 assets, address) external returns (uint256) {
        assetToken.transferFrom(msg.sender, address(this), assets);
        return 0;
    }
}
