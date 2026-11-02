// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {DeployArcMainnet} from "../script/DeployArcMainnet.s.sol";
import {ClaimVaultCreate2} from "../script/ClaimVaultCreate2.sol";
import {PeanutV4} from "../src/V4/PeanutV4.4.sol";
import {PayrollBatch} from "../src/payroll/PayrollBatch.sol";
import {ISignatureTransfer} from "../src/interfaces/ISignatureTransfer.sol";
import {NonPullingVault} from "./PayrollBatch.Receipt18dp.t.sol";
import {PayrollPermit2, Treasury1271} from "./utils/PayrollPermit2.sol";

/// The Ripio wFX surface these tests drive (upgradeable ERC-20 + AccessControl + Pausable +
/// blocklist, read off the live implementation's selectors).
interface IWfx is IERC20Metadata {
    function MINTER_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);
    function COMPLIANCE_ROLE() external view returns (bytes32);
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function mint(address to, uint256 amount) external;
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
    function blockUser(address user) external;
    function unblockUser(address user) external;
    function isBlocked(address user) external view returns (bool);
    function enforceBlocklist() external view returns (bool);
    function setEnforceBlocklist(bool enforce) external;
}

/// @notice PayrollBatch + claim vault, deployed by DeployArcMainnet onto an Arc MAINNET fork,
///         paying a real Ripio wFX token (18 dp). Opt-in, never broadcasts:
///           script/fork-arc-mainnet.sh  (resolves the token from the bufinance location registry)
///         or by hand: ARC_MAINNET_FORK=1 ARC_WFX_TOKEN=0x… ARC_WFX_DECIMALS=18 \
///           forge test --match-contract ArcMainnetWfxFork -vv
///         Without ARC_MAINNET_FORK every test skips, so CI without network stays green.
///         The token address is deliberately NOT a literal here: the registry owns it.
contract ArcMainnetWfxForkTest is PayrollPermit2 {
    /// OpenZeppelin v5 AccessControlUpgradeable ERC-7201 namespace.
    bytes32 constant ACCESS_CONTROL_STORAGE = 0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800;

    bool fork;
    IWfx wfx;
    DeployArcMainnet script;
    PeanutV4 vault;
    PayrollBatch batch;
    Treasury1271 treasury;
    address safe;

    uint256 quorumPk = uint256(keccak256("arc mainnet fork quorum"));
    uint256 authPk = uint256(keccak256("arc mainnet fork otp attestor"));
    uint256 linkPk = uint256(keccak256("arc mainnet fork link"));
    address ops = makeAddr("wfx role holder (fork only)");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol walletless");

    uint256 constant FUND = 10_000_000e18;

    function setUp() public {
        fork = vm.envOr("ARC_MAINNET_FORK", false);
        if (!fork) return;
        vm.createSelectFork(vm.envOr("ARC_MAINNET_RPC", string("https://rpc.mainnet.arc.io")));
        // Our contracts compile for "paris" (no PUSH0); the live wFX proxies use newer opcodes,
        // so execute the fork under Arc's own fork rules. Compiled bytecode is unchanged.
        vm.setEvmVersion("prague");
        require(block.chainid == 5042, "fork is not Arc mainnet");
        wfx = IWfx(vm.envAddress("ARC_WFX_TOKEN"));

        script = new DeployArcMainnet();
        safe = script.ARC_SAFE();
        ClaimVaultCreate2.Deployment memory d = script.deploy(vm.addr(authPk));
        vault = PeanutV4(payable(d.vault));
        batch = PayrollBatch(d.payrollBatch);
        assertEq(vault.pendingOwner(), safe);
        vm.prank(safe);
        vault.acceptOwnership();
        script.verify(vm.addr(authPk));

        _grant(wfx.DEFAULT_ADMIN_ROLE());
        _grant(wfx.MINTER_ROLE());
        _grant(wfx.PAUSER_ROLE());
        _grant(wfx.COMPLIANCE_ROLE());

        treasury = new Treasury1271(vm.addr(quorumPk));
        vm.prank(ops);
        wfx.mint(address(treasury), FUND);
        vm.prank(vm.addr(quorumPk));
        treasury.approveMax(address(wfx), address(PERMIT2));
    }

    /// Fork-only: give `ops` a wFX role by writing AccessControl storage, then prove it took.
    function _grant(bytes32 role) internal {
        bytes32 roleSlot = keccak256(abi.encode(role, ACCESS_CONTROL_STORAGE));
        vm.store(address(wfx), keccak256(abi.encode(ops, roleSlot)), bytes32(uint256(1)));
        assertTrue(wfx.hasRole(role, ops), "role storage layout changed");
    }

    function _twoPayouts(uint256 a, uint256 b) internal view returns (PayrollBatch.Payout[] memory) {
        address[] memory to = new address[](2);
        uint256[] memory amt = new uint256[](2);
        (to[0], amt[0]) = (alice, a);
        (to[1], amt[1]) = (bob, b);
        return _payouts(address(wfx), to, amt);
    }

    function _noClaims() internal pure returns (PayrollBatch.ClaimDeposit[] memory c) {
        c = new PayrollBatch.ClaimDeposit[](0);
    }

    function _signed(bytes32 id, uint256 total, PayrollBatch.Payout[] memory p, PayrollBatch.ClaimDeposit[] memory c)
        internal
        returns (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory sig)
    {
        permit = _oneTokenPermit(address(wfx), total);
        sig = _signPayroll(batch, permit, id, p, c, quorumPk);
    }

    // ------------------------------------------------------------------ deploy + token facts

    function test_fork_deployedOwnedBySafe_tokenIsWfx18dp() public {
        if (!fork) vm.skip(true);
        assertEq(vault.owner(), safe);
        assertEq(uint256(wfx.decimals()), vm.envUint("ARC_WFX_DECIMALS"));
        assertEq(wfx.decimals(), 18);
        assertFalse(wfx.paused());
    }

    // ------------------------------------------------------------------ 18-dp payout + claim

    function test_fork_wfx18dp_payoutAndMfaClaim_exact() public {
        if (!fork) vm.skip(true);
        uint256 a = 1_234_567_890_123_456_789_012; // 1234.567… with all 18 decimals used
        uint256 b = 1; // 1 wei of wFX
        uint256 claim = 500e18 + 7;
        PayrollBatch.Payout[] memory p = _twoPayouts(a, b);
        PayrollBatch.ClaimDeposit[] memory c = _claim(address(wfx), vm.addr(linkPk), claim);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory sig) =
            _signed("pay", a + b + claim, p, c);

        uint256 depositIndex = vault.getDepositCount();
        batch.executePayroll(permit, address(treasury), sig, "pay", p, c);

        assertEq(wfx.balanceOf(alice), a);
        assertEq(wfx.balanceOf(bob), b);
        assertEq(wfx.balanceOf(address(vault)), claim);
        assertEq(wfx.balanceOf(address(batch)), 0);
        assertEq(wfx.balanceOf(address(treasury)), FUND - a - b - claim);

        bytes memory linkSig = sign(linkPk, linkDigest(5042, address(vault), depositIndex, carol, MODE_ANYONE));
        bytes memory mfaSig = sign(authPk, mfaDigest(5042, address(vault), depositIndex, carol));
        vault.withdrawMFADeposit(depositIndex, carol, linkSig, mfaSig);
        assertEq(wfx.balanceOf(carol), claim);
        assertEq(wfx.balanceOf(address(vault)), 0);
    }

    // ------------------------------------------------------------------ ShortReceipt / Retained

    function test_fork_exactReceipt_donationNeitherShortNorRetained() public {
        if (!fork) vm.skip(true);
        vm.prank(ops);
        wfx.mint(address(batch), 1); // griefing donation
        PayrollBatch.Payout[] memory p = _twoPayouts(3e18, 4e18);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory sig) =
            _signed("don", 7e18, p, _noClaims());
        batch.executePayroll(permit, address(treasury), sig, "don", p, _noClaims());
        assertEq(wfx.balanceOf(alice), 3e18);
        assertEq(wfx.balanceOf(address(batch)), 1, "donation untouched, no ShortReceipt, no Retained");
    }

    function test_fork_retained_realWfx_vaultThatDoesNotPull() public {
        if (!fork) vm.skip(true);
        PayrollBatch rogue = new PayrollBatch(PERMIT2, new NonPullingVault());
        PayrollBatch.Payout[] memory none = new PayrollBatch.Payout[](0);
        PayrollBatch.ClaimDeposit[] memory c = _claim(address(wfx), vm.addr(linkPk), 9e18);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _oneTokenPermit(address(wfx), 9e18);
        bytes memory sig = _signPayroll(rogue, permit, "ret", none, c, quorumPk);
        vm.expectRevert(abi.encodeWithSelector(PayrollBatch.Retained.selector, address(wfx)));
        rogue.executePayroll(permit, address(treasury), sig, "ret", none, c);
        assertEq(wfx.balanceOf(address(treasury)), FUND);
    }

    // ------------------------------------------------------------------ compliance: atomic reverts

    function test_fork_blockedRecipient_revertsAtomically_thenSameSignatureSucceeds() public {
        if (!fork) vm.skip(true);
        vm.startPrank(ops);
        wfx.setEnforceBlocklist(true);
        wfx.blockUser(bob);
        vm.stopPrank();
        assertTrue(wfx.isBlocked(bob));

        PayrollBatch.Payout[] memory p = _twoPayouts(10e18, 20e18);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory sig) =
            _signed("blk", 30e18, p, _noClaims());
        vm.expectRevert();
        batch.executePayroll(permit, address(treasury), sig, "blk", p, _noClaims());

        // Nothing moved, nothing recorded, the Permit2 nonce is still unused.
        assertEq(wfx.balanceOf(alice), 0, "alice was paid although bob's leg reverted");
        assertEq(wfx.balanceOf(address(treasury)), FUND);
        assertEq(wfx.balanceOf(address(batch)), 0);
        assertFalse(batch.payrollExecuted(address(treasury), "blk"));

        vm.prank(ops);
        wfx.unblockUser(bob);
        batch.executePayroll(permit, address(treasury), sig, "blk", p, _noClaims());
        assertEq(wfx.balanceOf(bob), 20e18);
    }

    function test_fork_blockedTreasury_cannotFundPayroll() public {
        if (!fork) vm.skip(true);
        vm.startPrank(ops);
        wfx.setEnforceBlocklist(true);
        wfx.blockUser(address(treasury));
        vm.stopPrank();
        PayrollBatch.Payout[] memory p = _twoPayouts(1e18, 1e18);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory sig) =
            _signed("bt", 2e18, p, _noClaims());
        vm.expectRevert();
        batch.executePayroll(permit, address(treasury), sig, "bt", p, _noClaims());
        assertEq(wfx.balanceOf(address(treasury)), FUND);
    }

    function test_fork_pausedToken_revertsAtomically() public {
        if (!fork) vm.skip(true);
        vm.prank(ops);
        wfx.pause();
        PayrollBatch.Payout[] memory p = _twoPayouts(1e18, 2e18);
        PayrollBatch.ClaimDeposit[] memory c = _claim(address(wfx), vm.addr(linkPk), 3e18);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory sig) = _signed("pz", 6e18, p, c);
        uint256 deposits = vault.getDepositCount();
        vm.expectRevert();
        batch.executePayroll(permit, address(treasury), sig, "pz", p, c);
        assertEq(wfx.balanceOf(address(treasury)), FUND);
        assertEq(vault.getDepositCount(), deposits, "no claim link was created");
        assertFalse(batch.payrollExecuted(address(treasury), "pz"));

        vm.prank(ops);
        wfx.unpause();
        batch.executePayroll(permit, address(treasury), sig, "pz", p, c);
        assertEq(wfx.balanceOf(address(vault)), 3e18);
    }

    // ------------------------------------------------------------------ reclaim with a blocked claimant

    function test_fork_blockedClaimant_cannotClaim_treasuryReclaimsAfterWindow() public {
        if (!fork) vm.skip(true);
        PayrollBatch.ClaimDeposit[] memory c = _claim(address(wfx), vm.addr(linkPk), 42e18);
        PayrollBatch.Payout[] memory none = new PayrollBatch.Payout[](0);
        (ISignatureTransfer.PermitBatchTransferFrom memory permit, bytes memory sig) = _signed("cl", 42e18, none, c);
        uint256 idx = vault.getDepositCount();
        batch.executePayroll(permit, address(treasury), sig, "cl", none, c);

        vm.startPrank(ops);
        wfx.setEnforceBlocklist(true);
        wfx.blockUser(carol);
        vm.stopPrank();

        bytes memory linkSig = sign(linkPk, linkDigest(5042, address(vault), idx, carol, MODE_ANYONE));
        bytes memory mfaSig = sign(authPk, mfaDigest(5042, address(vault), idx, carol));
        vm.expectRevert();
        vault.withdrawMFADeposit(idx, carol, linkSig, mfaSig);
        assertFalse(vault.getDeposit(idx).claimed, "a reverted claim must leave the link open");
        assertEq(wfx.balanceOf(address(vault)), 42e18);

        // Inside the window the treasury still cannot pull it back…
        vm.prank(vm.addr(quorumPk));
        vm.expectRevert("CALL FAILED");
        treasury.call(address(vault), abi.encodeWithSignature("withdrawDepositSender(uint256)", idx));

        // …after 30 days it can, even though the claimant is blocked.
        vm.warp(block.timestamp + 30 days + 1);
        vm.prank(vm.addr(quorumPk));
        treasury.call(address(vault), abi.encodeWithSignature("withdrawDepositSender(uint256)", idx));
        assertTrue(vault.getDeposit(idx).claimed);
        assertEq(wfx.balanceOf(address(treasury)), FUND);
        assertEq(wfx.balanceOf(carol), 0);
    }
}
