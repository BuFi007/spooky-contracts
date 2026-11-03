// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {PeanutV4} from "../src/V4/PeanutV4.4.sol";
import {ClaimSigs} from "./utils/ClaimSigs.sol";
import {MockAuthorizationToken} from "./utils/MockAuthorizationToken.sol";

contract PeanutV44GaslessCustodyTest is ClaimSigs {
    struct Intent {
        address token;
        uint8 contractType;
        uint256 amount;
        uint256 tokenId;
        address pubKey20;
        address onBehalfOf;
        bool withMFA;
        address recipient;
        uint40 reclaimableAfter;
    }
    uint256 constant PAYER_PK = 0x123456;
    uint256 constant MFA_PK = 0x654321;
    uint256 constant LINK_PK = 0xabcdef;
    uint256 constant AMOUNT = 100_000_000;
    uint256 constant VALID_AFTER = 0;
    uint256 constant VALID_BEFORE = 1_000_000;
    bytes32 constant RAW_NONCE = bytes32(uint256(123));
    PeanutV4 vault;
    MockAuthorizationToken token;
    MockAuthorizationToken otherToken;
    address payer;
    address recipient = makeAddr("recipient");
    address attacker = makeAddr("attacker");

    function setUp() public {
        vm.chainId(5042002);
        vm.warp(100);
        payer = vm.addr(PAYER_PK);
        token = new MockAuthorizationToken();
        otherToken = new MockAuthorizationToken();
        vault = new PeanutV4(address(0), vm.addr(MFA_PK));
        token.mint(payer, 10 * AMOUNT);
        otherToken.mint(payer, 10 * AMOUNT);
    }

    function _intent(address key) internal view returns (Intent memory) {
        return Intent(address(token), 1, AMOUNT, 7, key, payer, true, recipient, uint40(30 days));
    }

    // Independent implementation of the documented signing format.
    function _nonce(Intent memory intent, uint256 chainId, address target) internal pure returns (bytes32) {
        bytes32 custodyHash = keccak256(
            abi.encode(
                intent.tokenId,
                intent.pubKey20,
                intent.onBehalfOf,
                intent.withMFA,
                intent.recipient,
                intent.reclaimableAfter
            )
        );
        bytes32 context = keccak256(
            abi.encode(
                keccak256("BUFI.CustomDepositAuthorization.v1"),
                chainId,
                target,
                intent.token,
                intent.contractType,
                intent.amount,
                custodyHash
            )
        );
        return keccak256(abi.encode(context, RAW_NONCE));
    }

    function _signature(Intent memory intent, bytes32 signedNonce) internal view returns (uint8, bytes32, bytes32) {
        return vm.sign(
            PAYER_PK,
            token.authorizationDigest(payer, address(vault), intent.amount, VALID_AFTER, VALID_BEFORE, signedNonce)
        );
    }

    function _args(Intent memory intent, bytes32 signedNonce) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = _signature(intent, signedNonce);
        return abi.encode(payer, RAW_NONCE, VALID_AFTER, VALID_BEFORE, v, r, s);
    }

    function _submit(Intent memory intent, bytes memory args) internal returns (uint256) {
        return vault.makeCustomDeposit(
            intent.token,
            intent.contractType,
            intent.amount,
            intent.tokenId,
            intent.pubKey20,
            intent.onBehalfOf,
            intent.withMFA,
            intent.recipient,
            intent.reclaimableAfter,
            true,
            args
        );
    }

    function _assertUnconsumed(bytes32 nonce) internal view {
        assertFalse(token.authorizationState(payer, nonce));
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.getDepositCount(), 0);
    }

    function _verifyAndClaim(Intent memory intent, bytes memory args) internal {
        vm.prank(attacker); // Untrusted relay is allowed, but it cannot change custody.
        uint256 idx = _submit(intent, args);
        PeanutV4.Deposit memory deposit = vault.getDeposit(idx);
        assertEq(deposit.tokenAddress, intent.token);
        assertEq(deposit.contractType, intent.contractType);
        assertEq(deposit.amount, intent.amount);
        assertEq(deposit.pubKey20, intent.pubKey20);
        assertEq(deposit.tokenId, intent.tokenId);
        assertEq(deposit.recipient, recipient);
        assertEq(deposit.senderAddress, payer);
        assertEq(deposit.reclaimableAfter, intent.reclaimableAfter);
        assertTrue(deposit.requiresMFA);
        bytes memory link = intent.pubKey20 == address(0)
            ? bytes("")
            : sign(LINK_PK, linkDigest(block.chainid, address(vault), idx, recipient, MODE_ANYONE));
        vm.expectRevert("REQUIRES AUTHORIZATION");
        vault.withdrawDeposit(idx, recipient, link);
        bytes memory mfa = sign(MFA_PK, mfaDigest(block.chainid, address(vault), idx, recipient));
        vault.withdrawMFADeposit(idx, recipient, link, mfa);
        assertEq(token.balanceOf(recipient), AMOUNT);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function testFuzz_everyCustomFieldBound_beforeLegitimateRelay(bool keyed, uint40 newWindow, uint256 newTokenId)
        public
    {
        Intent memory intent = _intent(keyed ? vm.addr(LINK_PK) : address(0));
        bytes32 nonce = _nonce(intent, block.chainid, address(vault));
        bytes memory args = _args(intent, nonce);
        for (uint256 field; field < 9; ++field) {
            Intent memory changed = _intent(intent.pubKey20);
            if (field == 0) changed.recipient = attacker;
            if (field == 1) changed.withMFA = false;
            if (field == 2) {
                changed.reclaimableAfter = newWindow == intent.reclaimableAfter ? newWindow + 1 : newWindow;
            }
            if (field == 3) changed.pubKey20 = attacker;
            if (field == 4) changed.tokenId = newTokenId == intent.tokenId ? newTokenId + 1 : newTokenId;
            if (field == 5) changed.onBehalfOf = attacker;
            if (field == 6) changed.amount = intent.amount + 1;
            if (field == 7) changed.token = address(otherToken);
            if (field == 8) changed.contractType = 4;
            vm.expectRevert();
            _submit(changed, args);
            _assertUnconsumed(nonce);
        }
        _verifyAndClaim(intent, args);
    }

    function test_customAuthorizationCannotBeConsumedBySimpleEntry() public {
        Intent memory intent = _intent(vm.addr(LINK_PK));
        bytes32 nonce = _nonce(intent, block.chainid, address(vault));
        (uint8 v, bytes32 r, bytes32 s) = _signature(intent, nonce);
        vm.expectRevert("INVALID AUTHORIZATION");
        vault.makeDepositWithAuthorization(
            address(token), payer, AMOUNT, intent.pubKey20, RAW_NONCE, VALID_AFTER, VALID_BEFORE, v, r, s
        );
        _assertUnconsumed(nonce);
        _verifyAndClaim(intent, abi.encode(payer, RAW_NONCE, VALID_AFTER, VALID_BEFORE, v, r, s));
    }

    function test_simpleLegacyAuthorizationCannotBeConsumedByCustomEntry() public {
        Intent memory intent = _intent(vm.addr(LINK_PK));
        bytes32 nonce = keccak256(abi.encodePacked(intent.pubKey20, RAW_NONCE));
        (uint8 v, bytes32 r, bytes32 s) = _signature(intent, nonce);
        vm.expectRevert("INVALID AUTHORIZATION");
        _submit(intent, abi.encode(payer, RAW_NONCE, VALID_AFTER, VALID_BEFORE, v, r, s));
        _assertUnconsumed(nonce);
        uint256 idx = vault.makeDepositWithAuthorization(
            address(token), payer, AMOUNT, intent.pubKey20, RAW_NONCE, VALID_AFTER, VALID_BEFORE, v, r, s
        );
        assertFalse(vault.getDeposit(idx).requiresMFA);
        assertEq(vault.getDeposit(idx).recipient, address(0));
        bytes memory link = sign(LINK_PK, linkDigest(block.chainid, address(vault), idx, recipient, MODE_ANYONE));
        vault.withdrawDeposit(idx, recipient, link);
        assertEq(token.balanceOf(recipient), AMOUNT);
    }

    function test_customNonceBindsChainAndVaultEvenWithValidTokenDomain() public {
        Intent memory intent = _intent(address(0));
        bytes32 wrongChain = _nonce(intent, block.chainid + 1, address(vault));
        bytes memory args = _args(intent, wrongChain);
        vm.expectRevert("INVALID AUTHORIZATION");
        _submit(intent, args);
        _assertUnconsumed(wrongChain);
        bytes32 wrongVault = _nonce(intent, block.chainid, attacker);
        args = _args(intent, wrongVault);
        vm.expectRevert("INVALID AUTHORIZATION");
        _submit(intent, args);
        _assertUnconsumed(wrongVault);
        _verifyAndClaim(intent, _args(intent, _nonce(intent, block.chainid, address(vault))));
    }

    function test_customAuthorizationReplayRejected() public {
        Intent memory intent = _intent(address(0));
        bytes memory args = _args(intent, _nonce(intent, block.chainid, address(vault)));
        _submit(intent, args);
        vm.expectRevert("AUTHORIZATION USED");
        _submit(intent, args);
        assertEq(vault.getDepositCount(), 1);
        assertEq(token.balanceOf(address(vault)), AMOUNT);
    }

    function test_gaslessReceiptMustBeExact_andAuthorizationRollsBack() public {
        Intent memory intent = _intent(address(0));
        bytes32 nonce = _nonce(intent, block.chainid, address(vault));
        bytes memory args = _args(intent, nonce);
        token.setChargeFee(true);
        vm.expectRevert("INEXACT TOKEN RECEIPT");
        _submit(intent, args);
        _assertUnconsumed(nonce);
        token.setChargeFee(false);
        token.setSkipTransfer(true);
        vm.expectRevert("INEXACT TOKEN RECEIPT");
        _submit(intent, args);
        _assertUnconsumed(nonce);
        token.setSkipTransfer(false);
        _verifyAndClaim(intent, args);
    }

    function test_rawNonceSubstitutionRejected() public {
        Intent memory intent = _intent(address(0));
        bytes32 nonce = _nonce(intent, block.chainid, address(vault));
        (uint8 v, bytes32 r, bytes32 s) = _signature(intent, nonce);
        bytes memory changedArgs = abi.encode(payer, bytes32(uint256(124)), VALID_AFTER, VALID_BEFORE, v, r, s);
        vm.expectRevert("INVALID AUTHORIZATION");
        _submit(intent, changedArgs);
        _assertUnconsumed(nonce);
        _verifyAndClaim(intent, abi.encode(payer, RAW_NONCE, VALID_AFTER, VALID_BEFORE, v, r, s));
    }

    function test_customNonceMatchesPublishedClientVector() public pure {
        Intent memory intent = Intent(
            0x2222222222222222222222222222222222222222,
            1,
            AMOUNT,
            7,
            0x3333333333333333333333333333333333333333,
            0x4444444444444444444444444444444444444444,
            true,
            0x5555555555555555555555555555555555555555,
            uint40(30 days)
        );
        assertEq(
            _nonce(intent, 5042002, 0x1111111111111111111111111111111111111111),
            0x9937293113ce5bd424d564283ebd2eaa02b6ffede7a47808f32eb065984ce23d
        );
    }

    function test_F01_legacyAuthRejectsPubKeySubstitutionButLacksCustomCustodyParams() public {
        Intent memory intent = _intent(vm.addr(LINK_PK));
        bytes32 nonce = keccak256(abi.encodePacked(intent.pubKey20, RAW_NONCE));
        (uint8 v, bytes32 r, bytes32 s) = _signature(intent, nonce);

        // Substituting pubKey20 invalidates the legacy nonce derivation
        vm.expectRevert("INVALID AUTHORIZATION");
        vault.makeDepositWithAuthorization(
            address(token), payer, AMOUNT, attacker, RAW_NONCE, VALID_AFTER, VALID_BEFORE, v, r, s
        );

        // Legacy entrypoint creates a non-MFA bearer deposit with reclaimableAfter == 0
        uint256 idx = vault.makeDepositWithAuthorization(
            address(token), payer, AMOUNT, intent.pubKey20, RAW_NONCE, VALID_AFTER, VALID_BEFORE, v, r, s
        );
        assertFalse(vault.getDeposit(idx).requiresMFA);
        assertEq(vault.getDeposit(idx).reclaimableAfter, 0);
        assertEq(vault.getDeposit(idx).recipient, address(0));
    }
}
