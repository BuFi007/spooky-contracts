// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {Test, Vm} from "forge-std/Test.sol";
import {DeployArcMainnet} from "../script/DeployArcMainnet.s.sol";
import {DeployTestnet} from "../script/DeployTestnet.s.sol";
import {ClaimVaultCreate2} from "../script/ClaimVaultCreate2.sol";
import {PeanutV4} from "../src/V4/PeanutV4.4.sol";
import {PayrollBatch} from "../src/payroll/PayrollBatch.sol";

/// @notice Offline checks of the Arc MAINNET (5042) deploy script. No RPC: the Arachnid factory,
///         canonical Permit2 and a stand-in for the Arc Safe are etched locally. Nothing here
///         (or anywhere in this suite) broadcasts.
contract DeployArcMainnetTest is Test {
    bytes constant ARACHNID_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    DeployArcMainnet script;
    address safe;
    address mfa = makeAddr("otp attestor eoa");

    function setUp() public {
        script = new DeployArcMainnet();
        safe = script.ARC_SAFE();
        vm.etch(script.ARACHNID_CREATE2(), ARACHNID_RUNTIME);
        vm.etch(script.PERMIT2(), vm.parseBytes(vm.trim(vm.readFile("test/fixtures/permit2.arc-testnet.runtime.hex"))));
        // The real Safe is a proxy with code; any non-empty runtime stands in for "deployed".
        vm.etch(safe, hex"00");
        vm.chainId(5042);
    }

    // ------------------------------------------------------------------ chain + inputs

    function test_ownerIsTheArcSafe() public view {
        assertEq(safe, 0x47Dc7D18A6E3a79F696714E7D47456a49B430D09);
    }

    function test_revertsOffArcMainnet() public {
        uint256[6] memory denied = [uint256(5042002), 1, 43114, 8453, 42161, 31337];
        for (uint256 i; i < denied.length; i++) {
            vm.chainId(denied[i]);
            vm.expectRevert("NOT ARC MAINNET (5042)");
            script.deploy(mfa);
        }
    }

    function test_runRevertsOffArcMainnetBeforeReadingEnv() public {
        vm.chainId(5042002);
        vm.expectRevert("NOT ARC MAINNET (5042)");
        script.run();
    }

    function test_runRequiresMfaAuthorizerEnv_noFallback() public {
        vm.setEnv("CLAIM_VAULT_MFA_AUTHORIZER", "");
        vm.expectRevert();
        script.run();
    }

    function test_runRequiresExplicitConfirmation() public {
        vm.setEnv("CLAIM_VAULT_MFA_AUTHORIZER", vm.toString(mfa));
        vm.setEnv("ARC_MAINNET_DEPLOY_CONFIRM", "yes");
        vm.expectRevert("SET ARC_MAINNET_DEPLOY_CONFIRM=deploy-arc-mainnet-5042");
        script.run();
    }

    function test_rejectsBadMfaAuthorizer() public {
        vm.expectRevert("ZERO MFA AUTHORIZER");
        script.deploy(address(0));
        vm.expectRevert("MFA AUTHORIZER IS THE SAFE");
        script.deploy(safe);
        // The vault checks the OTP co-signature with ecrecover: a contract can never sign it.
        address withCode = makeAddr("contract authorizer");
        vm.etch(withCode, hex"00");
        vm.expectRevert("MFA AUTHORIZER MUST BE AN EOA");
        script.deploy(withCode);
    }

    function test_requiresSafeCreate2AndPermit2Code() public {
        vm.etch(safe, "");
        vm.expectRevert("ARC SAFE HAS NO CODE");
        script.deploy(mfa);
        vm.etch(safe, hex"00");

        vm.etch(script.PERMIT2(), "");
        vm.expectRevert("NO PERMIT2 ON THIS CHAIN");
        script.deploy(mfa);
    }

    function test_sameSaltsAndFactoryAsTestnet() public {
        DeployTestnet testnet = new DeployTestnet();
        assertEq(script.VAULT_DEPLOYER_SALT(), testnet.VAULT_DEPLOYER_SALT());
        assertEq(script.PAYROLL_BATCH_SALT(), testnet.PAYROLL_BATCH_SALT());
        assertEq(script.VAULT_DEPLOYER_SALT(), keccak256("bufi.claim-vault.deployer.v1"));
        assertEq(script.PAYROLL_BATCH_SALT(), keccak256("bufi.payroll-batch.v1"));
        assertEq(script.ARACHNID_CREATE2(), testnet.ARACHNID_CREATE2());
        assertEq(script.PERMIT2(), testnet.PERMIT2());
        // Same init-code recipe: the Safe owner and the mainnet authorizer are its only inputs.
        ClaimVaultCreate2.Deployment memory a = script.predict(safe, mfa);
        ClaimVaultCreate2.Deployment memory b = testnet.predict(safe, mfa);
        assertEq(a.vaultDeployer, b.vaultDeployer);
        assertEq(a.vault, b.vault);
        assertEq(a.payrollBatch, b.payrollBatch);
    }

    // ------------------------------------------------------------------ deploy + Ownable2Step

    function test_deploysPredictedAddresses_withSafePendingOwner() public {
        ClaimVaultCreate2.Deployment memory p = script.predict(safe, mfa);
        ClaimVaultCreate2.Deployment memory d = script.deploy(mfa);
        assertEq(d.vault, p.vault);
        assertEq(d.payrollBatch, p.payrollBatch);

        PeanutV4 vault = PeanutV4(payable(d.vault));
        assertEq(vault.pendingOwner(), safe, "Safe must be pendingOwner");
        assertEq(vault.owner(), d.vaultDeployer, "owner is the inert helper until the Safe accepts");
        assertTrue(vault.owner() != safe, "Safe must NOT own before acceptOwnership");
        assertEq(vault.MFA_AUTHORIZER(), mfa);
        assertEq(address(PayrollBatch(d.payrollBatch).VAULT()), d.vault);
        assertEq(address(PayrollBatch(d.payrollBatch).PERMIT2()), script.PERMIT2());
        assertEq(PayrollBatch(d.payrollBatch).CLAIM_WINDOW(), 30 days);
    }

    function test_ownerBecomesSafeOnlyAfterSafeAccepts() public {
        ClaimVaultCreate2.Deployment memory d = script.deploy(mfa);
        PeanutV4 vault = PeanutV4(payable(d.vault));

        vm.expectRevert("CLAIM VAULT OWNER IS NOT THE ARC SAFE");
        script.verify(mfa);

        // Nobody but the Safe can complete the handover.
        vm.prank(makeAddr("deployer"));
        vm.expectRevert();
        vault.acceptOwnership();
        vm.prank(mfa);
        vm.expectRevert();
        vault.acceptOwnership();
        assertEq(vault.owner(), d.vaultDeployer);

        vm.prank(safe);
        vault.acceptOwnership();
        assertEq(vault.owner(), safe);
        assertEq(vault.pendingOwner(), address(0));
        script.verify(mfa);
    }

    function test_rerunIsNoOp_beforeAndAfterAccept() public {
        ClaimVaultCreate2.Deployment memory a = script.deploy(mfa);
        vm.recordLogs();
        ClaimVaultCreate2.Deployment memory b = script.deploy(mfa);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "re-run deployed something");
        assertEq(b.vault, a.vault);

        vm.prank(safe);
        PeanutV4(payable(a.vault)).acceptOwnership();
        ClaimVaultCreate2.Deployment memory c = script.deploy(mfa);
        assertEq(c.payrollBatch, a.payrollBatch);
    }

    function test_rerunRefusesForeignOwnershipState() public {
        ClaimVaultCreate2.Deployment memory d = script.deploy(mfa);
        PeanutV4 vault = PeanutV4(payable(d.vault));
        vm.prank(safe);
        vault.acceptOwnership();
        address stranger = makeAddr("stranger");
        vm.prank(safe);
        vault.transferOwnership(stranger);
        vm.prank(stranger);
        vault.acceptOwnership();
        vm.expectRevert("CLAIM VAULT OWNERSHIP NOT HEADED TO THE ARC SAFE");
        script.deploy(mfa);
    }

    function test_verifyRejectsWrongAuthorizer() public {
        ClaimVaultCreate2.Deployment memory d = script.deploy(mfa);
        vm.prank(safe);
        PeanutV4(payable(d.vault)).acceptOwnership();
        // A different authorizer predicts different addresses: nothing is deployed there.
        vm.expectRevert("CLAIM VAULT NOT DEPLOYED");
        script.verify(makeAddr("other authorizer"));
    }
}
