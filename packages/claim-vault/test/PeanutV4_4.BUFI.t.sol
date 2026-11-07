// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {PeanutV4} from "../src/V4/PeanutV4.4.sol";
import {MockUSDC} from "./utils/MockUSDC.sol";
import {ClaimSigs} from "./utils/ClaimSigs.sol";

contract PeanutV44BufiTest is ClaimSigs {
    // Arc: the 6-decimal USDC ERC-20 interface. NOT 0x1800… (18-dp native gas).
    address constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    uint256 constant ARC_TESTNET_CHAIN_ID = 5042002;
    uint256 constant AMOUNT = 1_500_000; // 1.50 USDC (6 dp)

    PeanutV4 vault;
    MockUSDC usdc;

    address owner = makeAddr("owner");
    address sender = makeAddr("sender");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address relayer = makeAddr("relayer");

    uint256 linkPk = uint256(keccak256("link key"));
    address linkPub;
    uint256 authPk = uint256(keccak256("mfa authorizer"));
    address authorizer;
    uint256 auth2Pk = uint256(keccak256("mfa authorizer 2"));
    address authorizer2;

    event MFAAuthorizerTransferStarted(address indexed previousAuthorizer, address indexed newAuthorizer);
    event MFAAuthorizerTransferred(address indexed previousAuthorizer, address indexed newAuthorizer);
    event WithdrawEvent(uint256 indexed _index, uint8 indexed _contractType, uint256 _amount, address indexed _recipientAddress);

    function setUp() public {
        vm.chainId(ARC_TESTNET_CHAIN_ID);
        linkPub = vm.addr(linkPk);
        authorizer = vm.addr(authPk);
        authorizer2 = vm.addr(auth2Pk);

        vm.etch(ARC_USDC, address(new MockUSDC()).code);
        usdc = MockUSDC(ARC_USDC);

        vm.prank(owner);
        vault = new PeanutV4(address(0), authorizer);

        usdc.mint(sender, 1_000 * 1e6);
        vm.prank(sender);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ---------------------------------------------------------------- helpers

    function _mfaDeposit() internal returns (uint256 idx) {
        vm.prank(sender);
        idx = vault.makeMFADeposit(ARC_USDC, 1, AMOUNT, 0, linkPub);
    }

    function _linkSig(uint256 idx, address to) internal view returns (bytes memory) {
        return sign(linkPk, linkDigest(block.chainid, address(vault), idx, to, MODE_ANYONE));
    }

    function _mfaSig(uint256 pk, uint256 idx, address to) internal view returns (bytes memory) {
        return sign(pk, mfaDigest(block.chainid, address(vault), idx, to));
    }

    // ----------------------------------------------------------- construction

    function test_usdcIsTheSixDecimalErc20() public view {
        assertEq(usdc.decimals(), 6);
        assertEq(address(usdc), ARC_USDC);
        assertEq(block.chainid, ARC_TESTNET_CHAIN_ID);
    }

    function test_constructor_setsAuthorizerAndOwner() public view {
        assertEq(vault.MFA_AUTHORIZER(), authorizer);
        assertEq(vault.owner(), owner);
        assertEq(vault.pendingMFAAuthorizer(), address(0));
        assertEq(vault.PEANUT_SALT(), SALT);
        assertEq(vault.RECIPIENT_WITHDRAWAL_MODE(), MODE_RECIPIENT);
    }

    function test_constructor_rejectsZeroAuthorizer() public {
        vm.expectRevert("ZERO MFA AUTHORIZER");
        new PeanutV4(address(0), address(0));
    }

    function test_constructor_emitsAuthorizerEvent() public {
        vm.expectEmit(true, true, false, false);
        emit MFAAuthorizerTransferred(address(0), authorizer2);
        new PeanutV4(address(0), authorizer2);
    }

    // --------------------------------------------------- MFA happy / sad path

    function test_mfaDeposit_withdrawMFADeposit_validAuthorizer_succeeds() public {
        uint256 idx = _mfaDeposit();
        assertEq(usdc.balanceOf(address(vault)), AMOUNT);
        PeanutV4.Deposit memory d = vault.getDeposit(idx);
        assertTrue(d.requiresMFA);
        assertEq(d.senderAddress, sender);
        assertEq(d.amount, AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit WithdrawEvent(idx, 1, AMOUNT, alice);
        vm.prank(relayer); // anyone may submit; funds go to the signed recipient
        bool ok = vault.withdrawMFADeposit(idx, alice, _linkSig(idx, alice), _mfaSig(authPk, idx, alice));

        assertTrue(ok);
        assertEq(usdc.balanceOf(alice), AMOUNT);
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(relayer), 0);
        assertTrue(vault.getDeposit(idx).claimed);
    }

    function test_withdrawMFADeposit_wrongAuthorizer_reverts() public {
        uint256 idx = _mfaDeposit();
        bytes memory link = _linkSig(idx, alice);
        vm.expectRevert("WRONG MFA SIGNATURE");
        vault.withdrawMFADeposit(idx, alice, link, _mfaSig(auth2Pk, idx, alice));
        // the link key itself is not an authorizer either
        vm.expectRevert("WRONG MFA SIGNATURE");
        vault.withdrawMFADeposit(idx, alice, link, _mfaSig(linkPk, idx, alice));
    }

    function test_withdrawMFADeposit_absentMfaSignature_reverts() public {
        uint256 idx = _mfaDeposit();
        bytes memory link = _linkSig(idx, alice);
        vm.expectRevert("ECDSA: invalid signature length");
        vault.withdrawMFADeposit(idx, alice, link, "");
    }

    function test_withdrawMFADeposit_garbageMfaSignature_reverts() public {
        uint256 idx = _mfaDeposit();
        bytes memory link = _linkSig(idx, alice);
        bytes memory junk = new bytes(65); // r = s = 0, v = 0
        vm.expectRevert("ECDSA: invalid signature");
        vault.withdrawMFADeposit(idx, alice, link, junk);
    }

    function test_mfaDeposit_cannotBypassMfaViaOtherWithdrawPaths() public {
        uint256 idx = _mfaDeposit();
        vm.expectRevert("REQUIRES AUTHORIZATION");
        vault.withdrawDeposit(idx, alice, _linkSig(idx, alice));

        bytes memory recSig = sign(linkPk, linkDigest(block.chainid, address(vault), idx, alice, MODE_RECIPIENT));
        vm.prank(alice);
        vm.expectRevert("REQUIRES AUTHORIZATION");
        vault.withdrawDepositAsRecipient(idx, alice, recSig);
    }

    function test_withdrawMFADeposit_wrongLinkKey_reverts() public {
        uint256 idx = _mfaDeposit();
        bytes memory badLink = sign(auth2Pk, linkDigest(block.chainid, address(vault), idx, alice, MODE_ANYONE));
        vm.expectRevert("WRONG SIGNATURE");
        vault.withdrawMFADeposit(idx, alice, badLink, _mfaSig(authPk, idx, alice));
    }

    /// The authorizer (and the owner who rotates it) can never pay out without the link key.
    function test_authorizerAlone_cannotWithdraw() public {
        uint256 idx = _mfaDeposit();
        bytes memory mfa = _mfaSig(authPk, idx, alice);
        vm.expectRevert("WRONG SIGNATURE"); // empty link sig => signer treated as address(0)
        vault.withdrawMFADeposit(idx, alice, "", mfa);
        // authorizer signing the link digest itself does not help either
        bytes memory fake = sign(authPk, linkDigest(block.chainid, address(vault), idx, alice, MODE_ANYONE));
        vm.expectRevert("WRONG SIGNATURE");
        vault.withdrawMFADeposit(idx, alice, fake, mfa);
    }

    // ------------------------------------------------------------------ replay

    function test_replay_sameSignatures_reverts() public {
        uint256 idx = _mfaDeposit();
        bytes memory link = _linkSig(idx, alice);
        bytes memory mfa = _mfaSig(authPk, idx, alice);
        vault.withdrawMFADeposit(idx, alice, link, mfa);
        vm.expectRevert("DEPOSIT ALREADY WITHDRAWN");
        vault.withdrawMFADeposit(idx, alice, link, mfa);
        assertEq(usdc.balanceOf(alice), AMOUNT);
    }

    function test_replay_mfaSigForOneIndex_cannotUnlockAnother() public {
        uint256 idx0 = _mfaDeposit();
        uint256 idx1 = _mfaDeposit(); // same link key on purpose (worst case)
        bytes memory mfa0 = _mfaSig(authPk, idx0, alice);
        vm.expectRevert("WRONG MFA SIGNATURE");
        vault.withdrawMFADeposit(idx1, alice, _linkSig(idx1, alice), mfa0);
    }

    function test_replay_crossContract_reverts() public {
        vm.prank(owner);
        PeanutV4 other = new PeanutV4(address(0), authorizer);
        vm.prank(sender);
        usdc.approve(address(other), type(uint256).max);
        vm.prank(sender);
        uint256 idx = other.makeMFADeposit(ARC_USDC, 1, AMOUNT, 0, linkPub);
        _mfaDeposit(); // same idx on the first vault

        // signatures minted for `vault` must not work on `other`
        bytes memory link = _linkSig(idx, alice);
        bytes memory mfa = _mfaSig(authPk, idx, alice);
        vm.expectRevert("WRONG MFA SIGNATURE");
        other.withdrawMFADeposit(idx, alice, link, mfa);
    }

    function test_replay_crossChain_reverts() public {
        uint256 idx = _mfaDeposit();
        bytes memory mfaOtherChain = sign(authPk, mfaDigest(5042, address(vault), idx, alice)); // Arc mainnet id
        vm.expectRevert("WRONG MFA SIGNATURE");
        vault.withdrawMFADeposit(idx, alice, _linkSig(idx, alice), mfaOtherChain);
    }

    // -------------------------------------------------------- recipient binding

    function test_recipientBinding_mfaForA_cannotPayB() public {
        uint256 idx = _mfaDeposit();
        // attacker sees A's signatures in the mempool and re-targets to B
        bytes memory linkA = _linkSig(idx, alice);
        bytes memory mfaA = _mfaSig(authPk, idx, alice);
        vm.expectRevert("WRONG MFA SIGNATURE");
        vault.withdrawMFADeposit(idx, bob, linkA, mfaA);
    }

    function test_recipientBinding_linkForA_mfaForB_cannotPayB() public {
        uint256 idx = _mfaDeposit();
        vm.expectRevert("WRONG SIGNATURE");
        vault.withdrawMFADeposit(idx, bob, _linkSig(idx, alice), _mfaSig(authPk, idx, bob));
    }

    function testFuzz_recipientBinding(address signedFor, address paidTo) public {
        vm.assume(signedFor != paidTo);
        uint256 idx = _mfaDeposit();
        bytes memory link = _linkSig(idx, signedFor);
        bytes memory mfa = _mfaSig(authPk, idx, signedFor);
        vm.expectRevert("WRONG MFA SIGNATURE");
        vault.withdrawMFADeposit(idx, paidTo, link, mfa);
    }

    function testFuzz_mfaBindsIndex(uint8 signedIdx, uint8 depositsToMake) public {
        uint256 n = bound(depositsToMake, 2, 8);
        for (uint256 i; i < n; ++i) _mfaDeposit();
        uint256 s = bound(signedIdx, 0, n - 1);
        uint256 target = (s + 1) % n;
        bytes memory mfa = _mfaSig(authPk, s, alice);
        vm.expectRevert("WRONG MFA SIGNATURE");
        vault.withdrawMFADeposit(target, alice, _linkSig(target, alice), mfa);
    }

    // ---------------------------------------------------- selfless + reclaim

    function test_selflessMfaDeposit_reclaimerIsOnBehalfOf_notDepositor() public {
        vm.prank(sender);
        uint256 idx = vault.makeSelflessMFADeposit(ARC_USDC, 1, AMOUNT, 0, linkPub, treasury);
        assertEq(vault.getDeposit(idx).senderAddress, treasury);

        vm.prank(sender);
        vm.expectRevert("NOT THE SENDER");
        vault.withdrawDepositSender(idx);

        // reclaimableAfter = 0 (selfless deposit): the window is already open, so the
        // designated reclaimer can pull the funds back immediately — as upstream.
        vm.prank(treasury);
        assertTrue(vault.withdrawDepositSender(idx));
        assertEq(usdc.balanceOf(treasury), AMOUNT);

        vm.expectRevert("DEPOSIT ALREADY WITHDRAWN");
        vault.withdrawMFADeposit(idx, alice, _linkSig(idx, alice), _mfaSig(authPk, idx, alice));
    }

    /// BUFI change: a BEARER link (no recipient) deposited with a 30-day window cannot
    /// be pulled back inside it — the claimant can still claim — and is refundable after.
    function test_reclaimWindow_bearerLink_enforced_BUFI() public {
        uint40 reclaimAfter = uint40(block.timestamp + 30 days);
        vm.prank(sender);
        uint256 idx = vault.makeCustomDeposit(
            ARC_USDC, 1, AMOUNT, 0, linkPub, treasury, true, address(0), reclaimAfter, false, ""
        );

        vm.prank(treasury);
        vm.expectRevert("TOO EARLY TO RECLAIM");
        vault.withdrawDepositSender(idx);

        vm.warp(reclaimAfter); // strict `>`: equal is still too early
        vm.prank(treasury);
        vm.expectRevert("TOO EARLY TO RECLAIM");
        vault.withdrawDepositSender(idx);

        vm.warp(uint256(reclaimAfter) + 1);
        vm.prank(treasury);
        assertTrue(vault.withdrawDepositSender(idx));
        assertEq(usdc.balanceOf(treasury), AMOUNT);
    }

    /// Inside the window the claim path is unaffected.
    function test_reclaimWindow_bearerLink_claimableInsideWindow_BUFI() public {
        uint40 reclaimAfter = uint40(block.timestamp + 30 days);
        vm.prank(sender);
        uint256 idx = vault.makeCustomDeposit(
            ARC_USDC, 1, AMOUNT, 0, linkPub, treasury, true, address(0), reclaimAfter, false, ""
        );
        vm.warp(block.timestamp + 10 days);
        assertTrue(
            vault.withdrawMFADeposit(idx, alice, _linkSig(idx, alice), _mfaSig(authPk, idx, alice))
        );
        assertEq(usdc.balanceOf(alice), AMOUNT);

        vm.warp(uint256(reclaimAfter) + 1);
        vm.prank(treasury);
        vm.expectRevert("DEPOSIT ALREADY WITHDRAWN");
        vault.withdrawDepositSender(idx);
    }

    /// The only time lock v4.4 has: address-bound deposits via makeCustomDeposit.
    function test_reclaimWindow_addressBound_beforeFails_afterWorks() public {
        uint40 reclaimAfter = uint40(block.timestamp + 30 days);
        vm.prank(sender);
        uint256 idx = vault.makeCustomDeposit(
            ARC_USDC, 1, AMOUNT, 0, linkPub, treasury, true, alice, reclaimAfter, false, ""
        );

        vm.prank(treasury);
        vm.expectRevert("TOO EARLY TO RECLAIM");
        vault.withdrawDepositSender(idx);

        vm.warp(reclaimAfter); // boundary: strict `>` so equal is still too early
        vm.prank(treasury);
        vm.expectRevert("TOO EARLY TO RECLAIM");
        vault.withdrawDepositSender(idx);

        vm.warp(uint256(reclaimAfter) + 1);
        vm.prank(sender); // depositor is not the reclaimer
        vm.expectRevert("NOT THE SENDER");
        vault.withdrawDepositSender(idx);

        vm.prank(treasury);
        assertTrue(vault.withdrawDepositSender(idx));
        assertEq(usdc.balanceOf(treasury), AMOUNT);
    }

    function test_addressBound_claimStillWorksAfterWindow_untilReclaimed() public {
        uint40 reclaimAfter = uint40(block.timestamp + 30 days);
        vm.prank(sender);
        uint256 idx = vault.makeCustomDeposit(
            ARC_USDC, 1, AMOUNT, 0, linkPub, treasury, true, alice, reclaimAfter, false, ""
        );
        vm.warp(uint256(reclaimAfter) + 365 days); // the window is NOT an expiry for the claimant
        vault.withdrawMFADeposit(idx, alice, _linkSig(idx, alice), _mfaSig(authPk, idx, alice));
        assertEq(usdc.balanceOf(alice), AMOUNT);
        vm.prank(treasury);
        vm.expectRevert("DEPOSIT ALREADY WITHDRAWN");
        vault.withdrawDepositSender(idx);
    }

    function test_addressBound_otherRecipientRejected() public {
        vm.prank(sender);
        uint256 idx = vault.makeCustomDeposit(
            ARC_USDC, 1, AMOUNT, 0, linkPub, treasury, true, alice, uint40(block.timestamp + 30 days), false, ""
        );
        vm.expectRevert("WRONG RECIPIENT");
        vault.withdrawMFADeposit(idx, bob, _linkSig(idx, bob), _mfaSig(authPk, idx, bob));
    }

    function test_gaslessReclaim_byDesignatedReclaimerSignature() public {
        uint256 treasuryPk = uint256(keccak256("treasury key"));
        address t = vm.addr(treasuryPk);
        vm.prank(sender);
        uint256 idx = vault.makeSelflessMFADeposit(ARC_USDC, 1, AMOUNT, 0, linkPub, t);

        bytes32 structHash = keccak256(abi.encode(keccak256("GaslessReclaim(uint256 depositIndex)"), idx));
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Peanut"),
                keccak256("4.2"),
                block.chainid,
                address(vault)
            )
        );
        assertEq(vault.DOMAIN_SEPARATOR(), domain);
        bytes memory sig = sign(treasuryPk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));

        vm.prank(relayer);
        vault.withdrawDepositSenderGasless(PeanutV4.GaslessReclaim(idx), t, sig);
        assertEq(usdc.balanceOf(t), AMOUNT);
    }

    // ------------------------------------------------------ authorizer rotation

    function test_rotation_onlyOwnerCanPropose() public {
        vm.prank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.transferMFAAuthorizer(authorizer2);
        vm.prank(authorizer); // the current authorizer cannot rotate itself
        vm.expectRevert("Ownable: caller is not the owner");
        vault.transferMFAAuthorizer(authorizer2);
    }

    function test_rotation_twoStep_oldValidUntilAccept_thenInvalid() public {
        uint256 idx0 = _mfaDeposit();
        uint256 idx1 = _mfaDeposit();
        bytes memory oldMfa1 = _mfaSig(authPk, idx1, alice);

        vm.expectEmit(true, true, false, false);
        emit MFAAuthorizerTransferStarted(authorizer, authorizer2);
        vm.prank(owner);
        vault.transferMFAAuthorizer(authorizer2);
        assertEq(vault.pendingMFAAuthorizer(), authorizer2);
        assertEq(vault.MFA_AUTHORIZER(), authorizer); // not yet rotated

        // proposed-but-unaccepted key is NOT yet an authorizer
        vm.expectRevert("WRONG MFA SIGNATURE");
        vault.withdrawMFADeposit(idx0, alice, _linkSig(idx0, alice), _mfaSig(auth2Pk, idx0, alice));
        // old key still works during the pending window
        vault.withdrawMFADeposit(idx0, alice, _linkSig(idx0, alice), _mfaSig(authPk, idx0, alice));

        // only the pending authorizer can accept (not owner, not anyone)
        vm.prank(owner);
        vm.expectRevert("NOT THE PENDING MFA AUTHORIZER");
        vault.acceptMFAAuthorizer();
        vm.prank(bob);
        vm.expectRevert("NOT THE PENDING MFA AUTHORIZER");
        vault.acceptMFAAuthorizer();

        vm.expectEmit(true, true, false, false);
        emit MFAAuthorizerTransferred(authorizer, authorizer2);
        vm.prank(authorizer2);
        vault.acceptMFAAuthorizer();
        assertEq(vault.MFA_AUTHORIZER(), authorizer2);
        assertEq(vault.pendingMFAAuthorizer(), address(0));

        // an old signature issued before rotation is now dead
        vm.expectRevert("WRONG MFA SIGNATURE");
        vault.withdrawMFADeposit(idx1, alice, _linkSig(idx1, alice), oldMfa1);
        // the new key works
        vault.withdrawMFADeposit(idx1, alice, _linkSig(idx1, alice), _mfaSig(auth2Pk, idx1, alice));
        assertEq(usdc.balanceOf(alice), 2 * AMOUNT);

        // accept cannot be replayed
        vm.prank(authorizer2);
        vm.expectRevert("NOT THE PENDING MFA AUTHORIZER");
        vault.acceptMFAAuthorizer();
    }

    function test_rotation_ownerCanCancelPending() public {
        vm.prank(owner);
        vault.transferMFAAuthorizer(authorizer2);
        vm.prank(owner);
        vault.cancelMFAAuthorizerTransfer();
        vm.prank(authorizer2);
        vm.expectRevert("NOT THE PENDING MFA AUTHORIZER");
        vault.acceptMFAAuthorizer();
        assertEq(vault.MFA_AUTHORIZER(), authorizer);
    }

    function test_rotation_zeroAuthorizerCanNeverBeInstalled() public {
        vm.prank(owner);
        vm.expectRevert("ZERO MFA AUTHORIZER");
        vault.transferMFAAuthorizer(address(0));
        vm.prank(address(0));
        vm.expectRevert("NOT THE PENDING MFA AUTHORIZER");
        vault.acceptMFAAuthorizer();
    }

    function test_ownership_isTwoStep() public {
        vm.prank(owner);
        vault.transferOwnership(bob);
        assertEq(vault.owner(), owner);
        assertEq(vault.pendingOwner(), bob);

        vm.prank(bob); // not owner until accepted
        vm.expectRevert("Ownable: caller is not the owner");
        vault.transferMFAAuthorizer(authorizer2);

        vm.prank(alice);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        vault.acceptOwnership();

        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.owner(), bob);

        vm.prank(owner);
        vm.expectRevert("Ownable: caller is not the owner");
        vault.transferMFAAuthorizer(authorizer2);
        vm.prank(bob);
        vault.transferMFAAuthorizer(authorizer2);
    }

    /// Rotation power cannot touch funds: owner + a colluding authorizer, without the link key,
    /// cannot move a non-MFA deposit or an MFA deposit.
    function test_ownerAndAuthorizer_cannotTakeFunds() public {
        vm.prank(sender);
        uint256 plain = vault.makeDeposit(ARC_USDC, 1, AMOUNT, 0, linkPub);
        uint256 mfa = _mfaDeposit();

        uint256 evilPk = uint256(keccak256("evil"));
        address evil = vm.addr(evilPk);
        vm.prank(owner);
        vault.transferMFAAuthorizer(evil);
        vm.prank(evil);
        vault.acceptMFAAuthorizer();

        bytes memory evilLink = sign(evilPk, linkDigest(block.chainid, address(vault), mfa, evil, MODE_ANYONE));
        vm.expectRevert("WRONG SIGNATURE");
        vault.withdrawMFADeposit(mfa, evil, evilLink, _mfaSig(evilPk, mfa, evil));

        bytes memory evilPlain = sign(evilPk, linkDigest(block.chainid, address(vault), plain, evil, MODE_ANYONE));
        vm.expectRevert("WRONG SIGNATURE");
        vault.withdrawDeposit(plain, evil, evilPlain);

        vm.prank(owner);
        vm.expectRevert("NOT THE SENDER");
        vault.withdrawDepositSender(mfa);

        assertEq(usdc.balanceOf(address(vault)), 2 * AMOUNT);
    }

    // ------------------------------------------- upstream behaviour pinned for findings

    /// FINDING F-2: a deposit whose pubKey20 is address(0) and recipient is address(0) is now rejected.
    function test_finding_zeroPubKey_isClaimableByAnyoneWithMfa() public {
        vm.prank(sender);
        vm.expectRevert("ZERO PUBKEY20 REQUIRES RECIPIENT");
        vault.makeMFADeposit(ARC_USDC, 1, AMOUNT, 0, address(0));
    }

    /// FINDING F-02 (was F-3): native value attached to an ERC-20 deposit is now rejected.
    function test_finding_nativeValueWithErc20Deposit_isStranded() public {
        vm.deal(sender, 1 ether);
        vm.prank(sender);
        vm.expectRevert("NO ETH FOR TOKEN DEPOSITS");
        vault.makeMFADeposit{value: 1 ether}(ARC_USDC, 1, AMOUNT, 0, linkPub);
        assertEq(address(vault).balance, 0);
    }

    function test_F02_nativeValueRejectedOnTokenAndGaslessDeposits() public {
        vm.deal(sender, 1 ether);
        vm.startPrank(sender);
        vm.expectRevert("NO ETH FOR TOKEN DEPOSITS");
        vault.makeDeposit{value: 1 wei}(ARC_USDC, 1, AMOUNT, 0, linkPub);
        vm.expectRevert("NO ETH FOR TOKEN DEPOSITS");
        vault.makeCustomDeposit{value: 1 wei}(
            ARC_USDC, 1, AMOUNT, 0, linkPub, address(0), true, alice, 0, false, ""
        );
        vm.stopPrank();
        assertEq(address(vault).balance, 0);
    }

    function test_F03_authorizerRotationInvalidatesPriorMfaSignatures() public {
        uint256 idx = _mfaDeposit();
        bytes memory oldMfaSig = _mfaSig(authPk, idx, alice);

        vm.prank(owner);
        vault.transferMFAAuthorizer(authorizer2);
        vm.prank(authorizer2);
        vault.acceptMFAAuthorizer();

        vm.expectRevert("WRONG MFA SIGNATURE");
        vault.withdrawMFADeposit(idx, alice, _linkSig(idx, alice), oldMfaSig);

        vault.withdrawMFADeposit(idx, alice, _linkSig(idx, alice), _mfaSig(auth2Pk, idx, alice));
        assertEq(usdc.balanceOf(alice), AMOUNT);
    }

    function test_F13_directNftTransferRevertsExplicitly() public {
        vm.expectRevert("DIRECT NFT SENDS NOT SUPPORTED");
        vault.onERC721Received(sender, sender, 1, "");
        vm.expectRevert("DIRECT NFT SENDS NOT SUPPORTED");
        vault.onERC1155Received(sender, sender, 1, 1, "");
        uint256[] memory ids = new uint256[](1);
        uint256[] memory vals = new uint256[](1);
        vm.expectRevert("DIRECT NFT SENDS NOT SUPPORTED");
        vault.onERC1155BatchReceived(sender, sender, ids, vals, "");
    }

    function test_F19_deprecatedDepositEntrypointsStillCallable() public {
        vm.prank(sender);
        uint256 idx = vault.makeSelflessDeposit(ARC_USDC, 1, AMOUNT, 0, linkPub, sender);
        assertEq(vault.getDeposit(idx).amount, AMOUNT);
    }

    function test_F22_getAllDepositsForAddressReturnsSenderDeposits() public {
        uint256 idx = _mfaDeposit();
        PeanutV4.Deposit[] memory all = vault.getAllDeposits();
        assertEq(all.length, 1);
        assertEq(all[0].amount, AMOUNT);
        PeanutV4.Deposit[] memory senderDeps = vault.getAllDepositsForAddress(sender);
        assertEq(senderDeps.length, 1);
        assertEq(senderDeps[0].senderAddress, sender);
        assertEq(idx, 0);
    }

    function test_F24_withdrawRequiresValidSignatureOrSender() public {
        uint256 idx = _mfaDeposit();
        vm.prank(alice);
        vm.expectRevert("NOT THE SENDER");
        vault.withdrawDepositSender(idx);
    }

    function test_F26_tokenDepositMeasuresExactIntraTxBalanceDelta() public {
        usdc.mint(address(vault), 777);
        uint256 idx = _mfaDeposit();
        assertEq(vault.getDeposit(idx).amount, AMOUNT);
        assertEq(usdc.balanceOf(address(vault)), AMOUNT + 777);
    }

    function test_F28_addressBoundWithdrawWithoutLinkSignature() public {
        vm.prank(sender);
        uint256 idx = vault.makeCustomDeposit(
            ARC_USDC, 1, AMOUNT, 0, address(0), sender, false, alice, 0, false, ""
        );
        vault.withdrawDeposit(idx, alice, "");
        assertEq(usdc.balanceOf(alice), AMOUNT);
    }

    function test_F29_zeroEcoAndCancelMfaRotationAllowed() public {
        assertEq(vault.ecoAddress(), address(0));
        vm.startPrank(owner);
        vault.transferMFAAuthorizer(authorizer2);
        assertEq(vault.pendingMFAAuthorizer(), authorizer2);
        vm.expectRevert("ZERO MFA AUTHORIZER");
        vault.transferMFAAuthorizer(address(0));
        vault.cancelMFAAuthorizerTransfer();
        assertEq(vault.pendingMFAAuthorizer(), address(0));
        vm.stopPrank();
    }

    function test_F31_reclaimableAfterTimestampBoundary() public {
        uint40 unlockAt = uint40(block.timestamp + 1 days);
        vm.prank(sender);
        uint256 idx = vault.makeCustomDeposit(
            ARC_USDC, 1, AMOUNT, 0, linkPub, treasury, true, address(0), unlockAt, false, ""
        );
        vm.warp(unlockAt);
        vm.prank(treasury);
        vm.expectRevert("TOO EARLY TO RECLAIM");
        vault.withdrawDepositSender(idx);

        vm.warp(unlockAt + 1);
        vm.prank(treasury);
        vault.withdrawDepositSender(idx);
        assertEq(usdc.balanceOf(treasury), AMOUNT);
    }

    function test_F32_F33_F34_vaultImplementsInterfaceAndImmutables() public view {
        assertTrue(vault.DOMAIN_SEPARATOR() != bytes32(0));
        assertEq(vault.ecoAddress(), address(0));
    }

    /// FINDING F-5: MFA signature has no expiry/nonce — valid until the deposit is claimed.
    function test_finding_mfaSignatureDoesNotExpire() public {
        uint256 idx = _mfaDeposit();
        bytes memory mfa = _mfaSig(authPk, idx, alice);
        vm.warp(block.timestamp + 3650 days);
        vault.withdrawMFADeposit(idx, alice, _linkSig(idx, alice), mfa);
        assertEq(usdc.balanceOf(alice), AMOUNT);
    }

    /// Upstream `withdrawMFADeposit` checks ONLY the ANYONE-mode link signature: a
    /// RECIPIENT-mode link signature is rejected there.
    function test_withdrawMFADeposit_recipientModeLinkSig_rejected() public {
        uint256 idx = _mfaDeposit();
        bytes memory recSig = sign(linkPk, linkDigest(block.chainid, address(vault), idx, alice, MODE_RECIPIENT));
        vm.expectRevert("WRONG SIGNATURE");
        vault.withdrawMFADeposit(idx, alice, recSig, _mfaSig(authPk, idx, alice));
    }
}
