// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {Test, Vm} from "forge-std/Test.sol";
import {DeployTestnet} from "../script/DeployTestnet.s.sol";
import {PeanutV4} from "../src/V4/PeanutV4.4.sol";
import {PayrollBatch} from "../src/payroll/PayrollBatch.sol";

contract DeployTestnetTest is Test {
    // Arachnid deterministic-deployment-proxy runtime.
    bytes constant ARACHNID_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    DeployTestnet script;
    address owner = makeAddr("owner");
    address mfa = makeAddr("mfa");

    uint256[8] TESTNETS = [uint256(5042002), 43113, 11155111, 84532, 421614, 11155420, 1301, 10143];

    function setUp() public {
        script = new DeployTestnet();
        vm.etch(script.ARACHNID_CREATE2(), ARACHNID_RUNTIME);
        vm.etch(script.PERMIT2(), vm.parseBytes(vm.trim(vm.readFile("test/fixtures/permit2.arc-testnet.runtime.hex"))));
    }

    function test_revertsOnNonAllowlistedChains() public {
        // Ethereum, Base, Arbitrum, Optimism, Polygon, Avalanche, Arc mainnet, Monad mainnet-ish, random, Polygon Amoy (dropped).
        uint256[10] memory denied = [uint256(1), 8453, 42161, 10, 137, 43114, 5042, 143, 31337, 80002];
        for (uint256 i; i < denied.length; i++) {
            vm.chainId(denied[i]);
            vm.expectRevert("CHAIN NOT IN TESTNET ALLOWLIST");
            script.deploy(owner, mfa);
        }
    }

    function test_runRevertsOnMainnetBeforeReadingEnv() public {
        vm.chainId(1);
        vm.expectRevert("CHAIN NOT IN TESTNET ALLOWLIST");
        script.run();
    }

    function test_rejectsZeroOwnerAndSigner() public {
        vm.chainId(84532);
        vm.expectRevert("ZERO CLAIM_VAULT_OWNER");
        script.deploy(address(0), mfa);
        vm.expectRevert("ZERO CLAIM_VAULT_MFA_SIGNER");
        script.deploy(owner, address(0));
    }

    function test_predictedAddressesIdenticalAcrossChains() public {
        DeployTestnet.Deployment memory first;
        for (uint256 i; i < TESTNETS.length; i++) {
            uint256 snap = vm.snapshotState();
            vm.chainId(TESTNETS[i]);
            DeployTestnet.Deployment memory p = script.predict(owner, mfa);
            DeployTestnet.Deployment memory d = script.deploy(owner, mfa);
            assertEq(d.vault, p.vault, "deployed vault != predicted");
            assertEq(d.payrollBatch, p.payrollBatch, "deployed batch != predicted");
            assertGt(d.vault.code.length, 0);
            assertGt(d.payrollBatch.code.length, 0);
            if (i == 0) {
                first = d;
            } else {
                assertEq(d.vaultDeployer, first.vaultDeployer);
                assertEq(d.vault, first.vault);
                assertEq(d.payrollBatch, first.payrollBatch);
            }
            vm.revertToState(snap);
        }
    }

    function test_ownershipHandoverAndWiring() public {
        vm.chainId(43113);
        DeployTestnet.Deployment memory d = script.deploy(owner, mfa);
        PeanutV4 vault = PeanutV4(payable(d.vault));
        assertEq(vault.owner(), d.vaultDeployer, "helper owns until accepted");
        assertEq(vault.pendingOwner(), owner);
        assertEq(vault.MFA_AUTHORIZER(), mfa);
        // Helper runtime is only solc's stub (no functions, no fallback): every call reverts,
        // so it can never act as the vault owner while the handover is pending.
        (bool ok,) = d.vaultDeployer.call(abi.encodeWithSignature("transferOwnership(address)", address(this)));
        assertFalse(ok, "helper must expose no callable functions");
        (ok,) = d.vaultDeployer.call("");
        assertFalse(ok, "helper must have no fallback");
        vm.prank(owner);
        vault.acceptOwnership();
        assertEq(vault.owner(), owner);
        assertEq(address(PayrollBatch(d.payrollBatch).VAULT()), d.vault);
        assertEq(address(PayrollBatch(d.payrollBatch).PERMIT2()), script.PERMIT2());
    }

    function test_rerunIsNoOp() public {
        vm.chainId(11155111);
        DeployTestnet.Deployment memory a = script.deploy(owner, mfa);
        bytes32 vaultCode = keccak256(a.vault.code);
        bytes32 batchCode = keccak256(a.payrollBatch.code);
        uint64 helperNonce = vm.getNonce(a.vaultDeployer);
        vm.recordLogs();
        DeployTestnet.Deployment memory b = script.deploy(owner, mfa);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "re-run emitted events (deployed something)");
        assertEq(b.vault, a.vault);
        assertEq(b.payrollBatch, a.payrollBatch);
        assertEq(keccak256(b.vault.code), vaultCode);
        assertEq(keccak256(b.payrollBatch.code), batchCode);
        assertEq(vm.getNonce(a.vaultDeployer), helperNonce);
    }

    function test_differentOwnerGivesDifferentAddresses() public {
        DeployTestnet.Deployment memory a = script.predict(owner, mfa);
        DeployTestnet.Deployment memory b = script.predict(makeAddr("other"), mfa);
        assertTrue(a.vault != b.vault);
    }

    /// Solar 0.2 codegen changes ClaimVaultDeployer initcode when forge script,
    /// forge build and forge test compile different file sets, so this test does
    /// not pin a CREATE2 address. The redeploy address is the one forge script prints.
    /// Contracts already on chain stay in packages/env until that redeploy.
    function test_predictIsStableWithinOneCompilation() public view {
        DeployTestnet.Deployment memory a =
            script.predict(0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474, 0x9c8515333aFdB567C31CDF53CD60868f3B64b724);
        DeployTestnet.Deployment memory b =
            script.predict(0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474, 0x9c8515333aFdB567C31CDF53CD60868f3B64b724);
        assertEq(a.vault, b.vault);
        assertEq(a.payrollBatch, b.payrollBatch);
        assertEq(a.vaultDeployer, b.vaultDeployer);
        assertTrue(a.vault != address(0));
        assertTrue(a.payrollBatch != address(0));
        assertTrue(a.vault != a.payrollBatch);
    }

    function test_F17_deployerHandsOffPendingOwnershipUntilAccepted() public {
        vm.chainId(84532);
        DeployTestnet.Deployment memory d = script.deploy(owner, mfa);
        PeanutV4 vault = PeanutV4(payable(d.vault));
        assertEq(vault.owner(), d.vaultDeployer);
        assertEq(vault.pendingOwner(), owner);
        vm.prank(owner);
        vault.acceptOwnership();
        assertEq(vault.owner(), owner);
        assertEq(vault.pendingOwner(), address(0));
    }
}
