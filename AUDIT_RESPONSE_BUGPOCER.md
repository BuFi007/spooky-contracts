# BUFI Smart Contracts Audit Response (Olympix BugPoCer Lite Scan and Mutation Testing)

**Repository.** `BuFi007/spooky-contracts`
**Scanned Baseline Commit.** `361d31a` on `main` (09 November 2026)
**Remediation Branch.** `fix/bugpocer-audit-remediation`
**Prepared For.** Ignacio Freire (Olympix) and BUFI Engineering

---

## 1. Executive Summary

Every Medium and Low issue in the Olympix BugPoCer Lite Scan Report (39 distinct issues across 56 finding sites) and the Mutation Testing Report (1,069 mutants across 27 contracts) has been triaged, reproduced, and addressed.

### Verdict Summary (Olympix Dashboard Alignment)

| Severity | Total Issues | Total Sites | True Positive (Fixed) | Design Decision (Hardened / Documented) | False Positive |
| --- | ---: | ---: | ---: | ---: | ---: |
| Medium (`5.1.1` to `5.1.19`) | 19 | 27 | 19 (27 sites) | 0 | 0 |
| Low (`5.2.1` to `5.2.20`) | 20 | 29 | 16 (23 sites) | 4 (6 sites: `5.2.3`, `5.2.6`, `5.2.11`, `5.2.13`) | 0 |
| **Total** | **39** | **56** | **35 (50 sites)** | **4 (6 sites)** | **0** |

Note on `5.2.11`: classified as a Design Decision when `maxFastFeeBps > 0` because callers are intentionally allowed to choose fast or standard finality within the configured fee ceiling, and hardened in code so `maxFastFeeBps == 0` now forces the standard finality threshold (`2000`) and emits `Flushed.fast == false`.

### Verification Summary

All 10 Foundry profiles build and pass identically under both canonical `solc` (`0.8.24` / `0.8.26`) and `solar` (`0.3.0-dev+commit.e7a91fc7`).

- **Suite total (`solc`):** 543 passed, 0 failed, 10 skipped (opt-in live fork tests requiring RPC URLs).
- **Suite total (`solar`):** 543 passed, 0 failed, 10 skipped (identical pass/fail/skip parity).
- **EIP-170 runtime size (`InvoiceShelf`):** 23,825 bytes under canonical `solc 0.8.26` (751 bytes below the 24,576-byte EIP-170 limit) and 15,700 bytes under `solar`.
- **Pre-fix baseline:** 301 passed, 4 failed (stale `solar 0.1.8` CREATE2 address pins in `SafeTxBuilder` tests), 10 skipped.
- **New test suites added:** 6 new test files plus expanded regression, invariant, and mutation-killing tests across every low-scoring contract in the mutation testing report.

### Immediate Live-Chain Operational Action (Arc Mainnet 5042)

All deployed contracts in `deployments/live-receipts-2026-11-07.json` are immutable CREATE2 instances, so bytecode fixes ship as vNext deployments. One finding (`5.2.2`) can and should be mitigated immediately on live Arc Mainnet (`5042`) with a single Safe transaction before vNext deploys:

- **Target:** `BUFIReputationRegistry` (`0x2D7125b1cf826bE4ad6D0b043F6B4675897EB2e9`)
- **Call:** `grantRole(keccak256("OPS_ROLE"), 0x90eCDd402C0E357362b7805173191A153b876DF4)` (grants `OPS_ROLE` to the live `hubShelf` so the restructure path works immediately).

### vNext Deployment and Off-Chain Integration Checklist

1. **Conduit token allowlist initialization (`5.2.1`).** Every v2 and v3 ERC-3009 conduit (`TreasuryConduit`, `TreasuryBridgeConduitV2`, v3 `TreasuryConduit`, v3 `TreasuryBridgeConduit`) now gates execution on a Safe-curated `tokens` allowlist. Execute `setToken(token, true)` for USDC and EURC immediately after vNext deployment.
2. **Conduit output custody (`5.1.13`).** `TreasuryConduit` (v2/v3) and `TreasuryConduitPermit2` now enforce `minOut` on the conduit-custodied `tokenOut` delta before forwarding to `recipient`. Swaps, ERC-4626 deposits, and `TreasurySwapAndDeposit` calls routed through `TreasuryConduit` must set the target `beneficiary` / `receiver` to `address(conduit)`.
3. **PayrollBatch signature payload (`5.2.14`).** `PayrollBatch.payrollHash` and `PayrollBatch.witnessOf` now take `address from` as their first parameter. Update off-chain payroll signing services to pass `from` when computing `payrollHash` and the Permit2 witness.
4. **PeanutV4 MFA acceptance signature (`5.2.20`).** `PeanutV4.acceptMFAAuthorizer(bytes calldata _signature)` now requires an ECDSA signature from `pendingMFAAuthorizer` over `mfaAcceptanceDigest(pendingMFAAuthorizer)`. Regenerate `packages/claim-vault/abi/bufi-PeanutV4.4.abi.json` and update `packages/claim-vault/README.md` when cutting the vNext release.
5. **Historical manifests preserved.** `deployments/live-receipts-2026-11-07.json`, `deployments/addresses.json`, and `deployments/bytecode-hashes.json` were intentionally kept unchanged so Nov 7 live receipts stay intact until vNext manifests are generated.

---

## 2. Complete Summary Table (All 39 Issues / 56 Finding Sites)

| ID | Severity | Sites | BugPoCer Title | Verdict | Primary Contract(s) | Verification Test(s) |
| --- | --- | ---: | --- | --- | --- | --- |
| `5.1.1` | Medium | 1 | Dust deposit permanently pins escrow token for an invoice | True positive (Fixed) | `MultiTokenReceivableEscrow.sol`, `RecibuMemoRouter.sol` | `test_BugPoCer_5_1_1_escrowDebitUnbindsOnlyAtZeroAndRouterBlocksWrongPayer` |
| `5.1.2` | Medium | 3 | Hub markDefaulted strands invoice holdbackCollected | True positive (Fixed) | `InvoiceShelf.sol` | `test_BugPoCer_5_1_2_markDefaultedBurnsBinvInBothModes`, `test_BugPoCer_5_1_2_markDefaultedReclassifiesHoldbackWhenOutstandingIsZero` |
| `5.1.3` | Medium | 1 | Par Minting After Booked Loss Dilution | True positive (Fixed) | `InvoiceShelf.sol` | `test_BugPoCer_5_1_3_depositTrancheBlocksUnresolvedLossAndPricesAtNav` |
| `5.1.4` | Medium | 1 | Stranded Excess Holdback | True positive (Fixed) | `InvoiceShelf.sol` | `test_BugPoCer_5_1_4_resolveDefaultNoReplayAndKeepsFrozenUntilLossCured` |
| `5.1.5` | Medium | 1 | Dust Deposit Blocks Default | True positive (Fixed) | `InvoiceShelf.sol`, `RecibuMemoRouter.sol` | `test_BugPoCer_5_1_5_escrowDustNoDefaultDosAndRouterGuards`, `test_BugPoCer_5_1_5_routerRejectsFeeOnTransferBalanceMismatch`, `test_Audit_Medium3_midnightNonUsdcEscrowGetsSettlementBuffer` |
| `5.1.6` | Medium | 1 | Missing Tranche Subordination Capacity Check | True positive (Fixed) | `InvoiceShelf.sol` | `test_BugPoCer_5_1_6_trancheCapacityBlocksJuniorBorrowingFromSenior` |
| `5.1.7` | Medium | 1 | Repayment Dos After Permanent Default | True positive (Fixed) | `InvoiceShelf.sol` | `test_BugPoCer_5_1_7_permanentDefaultAllowsOtherOpenInvoicesToRepayAndSettle` |
| `5.1.8` | Medium | 1 | Reserve Bond No Withdraw Path | True positive (Fixed) | `InvoiceShelf.sol` | `test_BugPoCer_5_1_8_withdrawReserveSurplusEnforcesCleanWorkspace`, `test_Audit_Medium4_fraudResolutionUnbricksExcessReserveBond` |
| `5.1.9` | Medium | 4 | TreasuryConduit leftovers stranded and sweepable by anyone | True positive (Fixed) | `TreasuryConduit.sol` (v2/v3), `TreasuryConduitPermit2.sol` | `test_BugPoCer_5_1_9_v2ConduitDeltaOnlySweepPreservesStrayBalances`, `test_BugPoCer_5_1_9_and_5_1_13_v2Permit2Conduit`, `test_BugPoCer_5_1_9_5_1_13_5_2_1_v3TreasuryConduit` |
| `5.1.10` | Medium | 3 | Value-blind reputation credit in hub installments | True positive (Fixed) | `InvoiceShelf.sol`, `BUFIReputationRegistry.sol`, `Params.sol` | `test_BugPoCer_5_1_10_reputationRampAndPairHistoryHardening` |
| `5.1.11` | Medium | 3 | Hub lacks per-seller default and loss accounting | True positive (Fixed) | `InvoiceShelf.sol` | `test_BugPoCer_5_1_11_defaultHoldbackReclassifiedAndExcessReturnedOnFraud`, `test_BugPoCer_5_1_15_multipleDefaultsRequireAllResolvedAndCured` |
| `5.1.12` | Medium | 1 | Lp Capital No Exit Path | True positive (Fixed) | `InvoiceShelf.sol` | `test_BugPoCer_5_1_12_redeemTrancheExitsIdlePoolAndProtectsHoldbacks` |
| `5.1.13` | Medium | 1 | Third-party tokenOut inflow inflates treasury-balance floor delta | True positive (Fixed) | `TreasuryConduit.sol` (v2/v3), `TreasuryConduitPermit2.sol`, `TreasurySwapAndDeposit.sol` | `test_BugPoCer_5_1_13_v2ConduitRejectsThirdPartyInflowInflation`, `test_BugPoCer_5_1_9_and_5_1_13_v2Permit2Conduit`, `test_integration_v3TreasuryConduit_calls_TreasurySwapAndDeposit_withConduitBeneficiary` |
| `5.1.14` | Medium | 2 | TreasuryBridgeConduitV2 residues swept by any caller | True positive (Fixed) | `TreasuryBridgeConduitV2.sol` | `test_BugPoCer_5_1_14_and_5_2_1_and_5_2_19_v2BridgeDeltaAndAllowlist` |
| `5.1.15` | Medium | 1 | No Post Default Recovery Path | True positive (Fixed) | `InvoiceShelf.sol` | `test_BugPoCer_5_1_15_multipleDefaultsRequireAllResolvedAndCured`, `test_BugPoCer_5_2_7_recoveryUnwindsWaterfallSeniorFirst` |
| `5.1.16` | Medium | 1 | Per Chunk Ceil Rounding Fee Cap Bypass | True positive (Fixed) | `CctpDepositForwarder.sol` | `test_BugPoCer_5_1_16_chunkedFlushUpToCannotBypassMaxFastFeeBps`, `invariant_cumulativeFastMaxFeeWithinBpsCap` |
| `5.1.17` | Medium | 1 | Residual Balance Theft | True positive (Fixed) | `v3/TreasurySwapAndDeposit.sol` | `test_BugPoCer_5_1_17_v3SwapAndDepositDeltaOnlyAndAllPaths` |
| `5.1.18` | Medium | 2 | TreasuryBridgeConduit v3 residues sweepable by anyone | True positive (Fixed) | `v3/TreasuryBridgeConduit.sol` | `test_BugPoCer_5_1_18_5_2_1_5_2_18_v3BridgeConduit` |
| `5.1.19` | Medium | 1 | Partial Payment Clears Inflight Bridge Protection | True positive (Fixed) | `InvoiceShelf.sol` | `test_BugPoCer_5_1_19_bridgeNonceDedupAndPartialPaymentPreservesWindow`, `test_Audit_Low8_notifyCrossChainRepaymentIsMonotonic` |
| `5.2.1` | Low | 2 | Unauthenticated auth.token in TreasuryConduit.execute | True positive (Fixed) | `TreasuryConduit.sol` (v2/v3), `TreasuryBridgeConduitV2.sol`, `v3/TreasuryBridgeConduit.sol` | `test_BugPoCer_5_2_1_v2ConduitTokenAllowlistAndExactPull`, `test_BugPoCer_5_1_14_and_5_2_1_and_5_2_19_v2BridgeDeltaAndAllowlist`, `test_BugPoCer_5_1_9_5_1_13_5_2_1_v3TreasuryConduit`, `test_BugPoCer_5_1_18_5_2_1_5_2_18_v3BridgeConduit` |
| `5.2.2` | Low | 2 | Restructure branch reverts: shelf lacks registry OPS_ROLE | True positive (Fixed) | `BUFIReputationRegistry.sol`, `hub/test/Deploy.t.sol` | `test_BugPoCer_5_2_2_markRestructuredAcceptsSettlementOrOpsRole` |
| `5.2.3` | Low | 1 | Reverted execute leaves nonce live so signature can be retried later | Design decision | `TreasuryConduit.sol` (v2/v3) | Existing atomic retry semantics and FiatToken `cancelAuthorization` |
| `5.2.4` | Low | 1 | Uncallable Privileged Function Refund Lock Inert | True positive (Fixed) | `MultiTokenReceivableEscrow.sol` | `test_BugPoCer_5_2_4_escrowRefundLockActiveBoundedAndNonSliding` |
| `5.2.5` | Low | 2 | Arc native fee breaks Permit2 CCTPX input baseline | True positive (Fixed) | `TreasuryBridgeConduitV2.sol`, `v3/TreasuryBridgeConduit.sol`, `v3/TreasuryBridgeConduitPermit2.sol` | `test_BugPoCer_5_2_5_and_5_2_18_v2BridgeArcNativeUsdcAndQuoteValidation`, `test_BugPoCer_5_2_5_v3BridgePermit2ArcNativeUsdcExactAndNonMultipleOf1e12` |
| `5.2.6` | Low | 3 | Bearer-link reclaim window not enforced in PeanutV4 | Design decision (NatSpec fixed) | `PeanutV4.4.sol` | Existing upstream v4.4 compatibility suite and `PayrollBatch.t.sol` 30-day window tests |
| `5.2.7` | Low | 1 | Defaulted seller can re-borrow full limit right after loss | True positive (Fixed) | `InvoiceShelf.sol` | `test_BugPoCer_5_2_7_recoveryUnwindsWaterfallSeniorFirst`, `test_BugPoCer_5_1_4_resolveDefaultNoReplayAndKeepsFrozenUntilLossCured` |
| `5.2.8` | Low | 2 | Escrow setToken bypasses router token-disable delay | True positive (Fixed) | `MultiTokenReceivableEscrow.sol` | `test_BugPoCer_5_2_8_escrowDisableTimelockWindowAndInFlightContinuity` |
| `5.2.9` | Low | 1 | Missing Input Validation Noncanonical Mint Recipient | True positive (Fixed) | `CctpDepositForwarderFactory.sol` | `test_BugPoCer_5_2_9_factoryRejectsNonCanonicalMintRecipient` |
| `5.2.10` | Low | 1 | Missing Self Dealing Check | True positive (Fixed) | `InvoiceShelf.sol` | `test_BugPoCer_5_2_10_lockInvoiceBlocksSelfDealingSameIdAndSameOwner` |
| `5.2.11` | Low | 1 | Permissionless flusher can force CCTP fast-path fee onto payroll deposit | Design decision (Partially hardened) | `CctpDepositForwarder.sol` | `test_BugPoCer_5_2_11_zeroFeeBpsForcesStandardFinalityThreshold` |
| `5.2.12` | Low | 1 | Relayer can run stale payroll sharing a payrollId, blocking the corrected one | True positive (Fixed) | `PayrollBatch.sol` | `test_BugPoCer_5_2_12_cancelPayrollWithQuorumSignatureBlocksStaleExecution`, `test_BugPoCer_5_2_12_cancelPayrollRejectsExpiredAndWrongSigner`, `test_BugPoCer_5_2_12_cancelPayrollDirectByOwner` |
| `5.2.13` | Low | 1 | Sandwichable treasury swap down to signed minimum output | Design decision | `TreasuryConduit.sol` (v2/v3) | Operational control (tight `minOut`, tight deadline, private RPC) |
| `5.2.14` | Low | 1 | Signature Replay Unbound Owner | True positive (Fixed) | `PayrollBatch.sol` | `test_BugPoCer_5_2_14_payrollHashBindsFromOwner` |
| `5.2.15` | Low | 1 | Unrestricted Payer Pull | True positive (Fixed) | `InvoiceShelf.sol` | `test_BugPoCer_5_2_15_applyPaymentFromRejectsArbitraryPayerInNonMidnight` |
| `5.2.16` | Low | 1 | Missing Renounce Guard Sibling Mismatch | True positive (Fixed) | `v3/TreasuryBridgeConduit.sol`, `v3/TreasuryBridgeConduitPermit2.sol` | `test_renounceOwnership_reverts_on_every_v3_contract` |
| `5.2.17` | Low | 1 | Timelock Bypass Via Caps | True positive (Fixed) | `RecibuMemoRouter.sol` | `test_BugPoCer_5_2_17_routerCapStrippingRequiresTimelockAndWindow` |
| `5.2.18` | Low | 1 | Unbound Unvalidated Bridge Quote | True positive (Fixed) | `TreasuryBridgeConduitV2.sol`, `v3/TreasuryBridgeConduit.sol`, `v3/TreasuryBridgeConduitPermit2.sol` | `test_BugPoCer_5_2_5_and_5_2_18_v2BridgeArcNativeUsdcAndQuoteValidation`, `test_BugPoCer_5_1_18_5_2_1_5_2_18_v3BridgeConduit`, `test_v3BridgePermit2_allValidationQuoteAndAllowanceChecks` |
| `5.2.19` | Low | 1 | Unconstrained Rescue Recipient No Audit Trail | True positive (Fixed) | `TreasuryConduit.sol`, `TreasuryBridgeConduitV2.sol`, `v3/TreasuryBridgeConduit.sol`, `v3/TreasurySwapAndDeposit.sol` | `test_BugPoCer_5_2_19_v2ConduitRescueEmitsEventAndGuards`, `test_BugPoCer_5_1_14_and_5_2_1_and_5_2_19_v2BridgeDeltaAndAllowlist`, `test_F23_rescueEnforcesNonReentrantZeroAddressGuardsAndCeiEventOrder`, `test_adapter_rescue_emits_Rescued_and_enforces_guards` |
| `5.2.20` | Low | 1 | Mfa Rotation Acceptance Does Not Prove Ecdsa Key | True positive (Fixed) | `PeanutV4.4.sol` | `test_BugPoCer_5_2_20_mfaRotationRejectsContractAndInvalidEcdsaProof` |

---

## 3. Detailed Responses to Medium Findings (`5.1.1` to `5.1.19`)

### 5.1.1. Dust deposit permanently pins escrow token for an invoice
- **Verdict.** True positive (Fixed).
- **Affected contracts.** `packages/fx-recibu/hub/src/rails/MultiTokenReceivableEscrow.sol`, `packages/fx-recibu/hub/src/rails/RecibuMemoRouter.sol`.
- **Root cause.** `MultiTokenReceivableEscrow._debit` decremented `escrowedOf[invoiceId]` without clearing `tokenOf[invoiceId]` when the balance returned to zero, and `RecibuMemoRouter` accepted deposits from any `payer` without binding the payer to the invoice debtor. A 1-wei deposit in any allowlisted token permanently pinned `tokenOf[invoiceId]` even after refund or full settlement debit.
- **Remediation.**
  1. `MultiTokenReceivableEscrow._debit` reads `token`, decrements `escrowedOf[invoiceId]` and `totalEscrowedOf[token]`, and deletes `tokenOf[invoiceId]` and `refundUnlockAt[invoiceId]` when `escrowedOf[invoiceId]` reaches zero.
  2. `RecibuMemoRouter` enforces `payer == SHELF.debtorPayerOf(invoiceId)` so third parties cannot grief an invoice's escrow slot.
- **Regression test.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_1_1_escrowDebitUnbindsOnlyAtZeroAndRouterBlocksWrongPayer`).

### 5.1.2. Hub markDefaulted strands invoice holdbackCollected
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol` (3 sites).
- **Root cause.** `markDefaulted` did not reclassify `holdbackCollected` into the frozen holdback accounting bucket or burn the defaulted `BINV` token consistently, leaving collected holdback stranded on the shelf contract.
- **Remediation.** Ported the hardened `stablefx` holdback lifecycle into hub `InvoiceShelf.sol`. On default, `markDefaulted` reclassifies `holdbackCollected` out of `totalHoldbackEscrowed` into `frozenHoldback[invoiceId]` and `totalFrozenHoldback`, reduces `outstanding` and `tranchePrincipal`, burns the `BINV` token in both standard and `MIDNIGHT_MODE`, and emits accurate default accounting state.
- **Regression tests.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_1_2_markDefaultedBurnsBinvInBothModes`, `test_BugPoCer_5_1_2_markDefaultedReclassifiesHoldbackWhenOutstandingIsZero`).

### 5.1.3. Par Minting After Booked Loss Dilution
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol`.
- **Root cause.** `depositTranche` always minted tranche shares 1:1 with USDC regardless of booked `trancheLoss[tranche]`, allowing new deposits after a loss to dilute existing LPs or absorb unearned recovery upside.
- **Remediation.** `depositTranche` now prices deposits at current tranche NAV (`nav = trancheAssets - trancheLoss`) and reverts with `TrancheHasUnresolvedLoss` whenever unresolved loss prevents fair pricing or wipes tranche NAV to zero.
- **Regression test.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_1_3_depositTrancheBlocksUnresolvedLossAndPricesAtNav`).

### 5.1.4. Stranded Excess Holdback
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol`.
- **Root cause.** `resolveDefault` lacked per-invoice resolution state tracking and did not distribute or return frozen holdback exceeding the seller's unrecovered loss, stranding excess holdback permanently on the shelf.
- **Remediation.** Added `defaultResolutionOf[invoiceId]` (`None`, `Restructured`, `Fraud`) to prevent resolution replay and implemented `applyFrozenHoldback` plus clean excess holdback release to the seller once loss is absorbed (and clean release on `Fraud` resolution).
- **Regression test.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_1_4_resolveDefaultNoReplayAndKeepsFrozenUntilLossCured`).

### 5.1.5. Dust Deposit Blocks Default
- **Verdict.** True positive (Fixed).
- **Affected contracts.** `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol`, `packages/fx-recibu/hub/src/rails/RecibuMemoRouter.sol`.
- **Root cause.** `markDefaulted` reverted whenever `escrow.escrowedOf(invoiceId) > 0`, letting a debtor or third party send 1 wei into escrow right before the late deadline to block default indefinitely.
- **Remediation.**
  1. `RecibuMemoRouter` binds deposits to `SHELF.debtorPayerOf(invoiceId)`, caps deposits at `remainingFace`, enforces cumulative late-cure eligibility for USDC (`existing + amount >= openAmount`), rejects non-USDC deposits once past the due boundary, and enforces exact post-transfer `BalanceMismatch` checks.
  2. `InvoiceShelf.markDefaulted` only defers default for an escrow balance when the escrowed asset is USDC covering the open installment (`escrowed >= openAmount`) or when a non-USDC deposit is within `lateBoundary + crossChainBuffer` (in both standard and `MIDNIGHT_MODE`). Dust deposits can no longer block default.
- **Regression tests.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_1_5_escrowDustNoDefaultDosAndRouterGuards`, `test_BugPoCer_5_1_5_routerRejectsFeeOnTransferBalanceMismatch`, `test_Audit_Medium3_midnightNonUsdcEscrowGetsSettlementBuffer`).

### 5.1.6. Missing Tranche Subordination Capacity Check
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol`.
- **Root cause.** `lockInvoice` checked aggregate pool liquidity without enforcing per-tranche `tranchePrincipal[tranche]` capacity against `trancheAssets[tranche]`, allowing junior advances to draw liquidity backing senior LPs.
- **Remediation.** Added `tranchePrincipal[0..2]` tracking synchronized with `totalPrincipal` on every `lockInvoice`, `_applyPayment`, and `markDefaulted`, and enforced `trancheCapacity(tranche)` inside `lockInvoice` so each tranche can only advance against its own unencumbered NAV.
- **Regression test.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_1_6_trancheCapacityBlocksJuniorBorrowingFromSenior`).

### 5.1.7. Repayment Dos After Permanent Default
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol`.
- **Root cause.** Setting `permanentDefault` on a seller blocked subsequent repayments on that seller's other live invoices, causing avoidable losses on unrelated performing receivables.
- **Remediation.** Scoped `permanentDefault` enforcement strictly to new borrowing (`lockInvoice`) and reserve surplus withdrawal while allowing existing open invoices for that seller to continue receiving repayments and settling cleanly.
- **Regression test.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_1_7_permanentDefaultAllowsOtherOpenInvoicesToRepayAndSettle`).

### 5.1.8. Reserve Bond No Withdraw Path
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol`.
- **Root cause.** Sellers had no shelf-mediated path to withdraw surplus `WorkspaceOperatingReserve` collateral once exposure dropped to zero or after a default resolved.
- **Remediation.** Added `withdrawReserveSurplus(bytes32 seller, address to, uint256 amount)` gated on zero active exposure, zero unresolved defaults, zero seller unrecovered loss, and remaining balance above `reserve.requiredOf(seller)`. In addition, `resolveDefault` clears `reserve.setRequired(seller, 0)` before returning on `Fraud` resolution so any remaining excess bond after full loss coverage is never bricked.
- **Regression tests.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_1_8_withdrawReserveSurplusEnforcesCleanWorkspace`, `test_Audit_Medium4_fraudResolutionUnbricksExcessReserveBond`).

### 5.1.9. TreasuryConduit leftovers stranded and sweepable by anyone
- **Verdict.** True positive (Fixed).
- **Affected contracts.** `packages/treasury-conduits/src/bufi/conduit/TreasuryConduit.sol`, `packages/treasury-conduits/src/bufi/conduit/TreasuryConduitPermit2.sol`, `packages/treasury-conduits/v3/src/bufi/conduit/TreasuryConduit.sol` (4 sites).
- **Root cause.** Post-call cleanup swept the contract's entire `balanceOf(address(this))` to `auth.from` or `intent.recipient`, letting any caller (including an attacker using a self-signed authorization) drain stray donations or prior leftovers sitting on the conduit.
- **Remediation.** Switched all v2 and v3 conduits to strict pre-pull snapshots (`inBefore`, `outBefore`), revert with `PriorBalanceConsumed` if an external call dips below the pre-existing balance, sweep only the current call's positive delta (`inAfter - inBefore` and `outAfter - outBefore`), and forbid `target == address(this)` and `target == tokenIn`/`tokenOut`.
- **Regression tests.** `packages/treasury-conduits/test/TreasuryConduitsV2.t.sol` (`test_BugPoCer_5_1_9_v2ConduitDeltaOnlySweepPreservesStrayBalances`, `test_BugPoCer_5_1_9_and_5_1_13_v2Permit2Conduit`), `packages/treasury-conduits/v3/test/TreasuryConduitsV3.t.sol` (`test_BugPoCer_5_1_9_5_1_13_5_2_1_v3TreasuryConduit`).

### 5.1.10. Value-blind reputation credit in hub installments
- **Verdict.** True positive (Fixed).
- **Affected contracts.** `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol`, `packages/fx-recibu/hub/src/identity/BUFIReputationRegistry.sol`, `packages/fx-recibu/hub/src/libraries/Params.sol` (3 sites).
- **Root cause.** Every on-time installment incremented reputation unconditionally regardless of installment value, timing window, or epoch slope, enabling micro-invoice farming to inflate borrowing limits and `pairSettledCount`.
- **Remediation.** Ported the `stablefx` value-and-epoch-capped reputation ramp (`MIN_CREDITED_INSTALLMENT_USDC`, `RAMP_MAX_BPS_PER_EPOCH`, due-window enforcement) into hub `BUFIReputationRegistry` and `InvoiceShelf`, and moved `recordPairSettlement` to `_settle` gated on `face >= MIN_PAIR_SETTLEMENT_USDC`.
- **Regression test.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_1_10_reputationRampAndPairHistoryHardening`).

### 5.1.11. Hub lacks per-seller default and loss accounting
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol` (3 sites).
- **Root cause.** Hub `InvoiceShelf` tracked only aggregate loss and lacked per-seller unresolved default counts and per-seller unrecovered loss ledgers, preventing accurate freeze enforcement and multi-default accounting.
- **Remediation.** Added `unresolvedDefaultCountOf[seller]`, `sellerUnrecoveredLossOf[seller]`, `unrecoveredLossOf[invoiceId]`, and `defaultResolutionOf[invoiceId]`, keeping all per-seller and per-invoice ledgers synchronized across `markDefaulted`, `resolveDefault`, `applyFrozenHoldback`, and `recoverDefault`.
- **Regression tests.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_1_11_defaultHoldbackReclassifiedAndExcessReturnedOnFraud`, `test_BugPoCer_5_1_15_multipleDefaultsRequireAllResolvedAndCured`).

### 5.1.12. Lp Capital No Exit Path
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol`.
- **Root cause.** LPs could deposit into tranches via `depositTranche` but had no `redeemTranche` function to withdraw idle principal.
- **Remediation.** Implemented `redeemTranche(uint8 tranche, uint256 shares, address to)` burning `BIFTranche` shares at current NAV while bounding payouts to idle unencumbered tranche liquidity (`idleTrancheLiquidity`) so active advances and escrowed/frozen holdbacks remain fully protected.
- **Regression test.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_1_12_redeemTrancheExitsIdlePoolAndProtectsHoldbacks`).

### 5.1.13. Third-party tokenOut inflow inflates treasury-balance floor delta
- **Verdict.** True positive (Fixed).
- **Affected contracts.** `packages/treasury-conduits/src/bufi/conduit/TreasuryConduit.sol`, `packages/treasury-conduits/src/bufi/conduit/TreasuryConduitPermit2.sol`, `packages/treasury-conduits/v3/src/bufi/conduit/TreasuryConduit.sol`, `packages/treasury-conduits/v3/src/bufi/conduit/TreasurySwapAndDeposit.sol`.
- **Root cause.** Measuring `minOut` on `recipient`'s balance delta allowed a malicious or reentrant hook during `target.call` to observe unrelated third-party inflows to `recipient` as swap proceeds, satisfying `minOut` while under-delivering actual swap output.
- **Remediation.** `TreasuryConduit` (v2 and v3) and `TreasuryConduitPermit2` now enforce `minOut` strictly on the conduit-custodied `tokenOut` delta (`conduitOutAfter - conduitOutBefore >= minOut`), then forward that exact delta to `recipient` and verify `recipientAfter - recipientBefore >= minOut` immediately around the transfer on both distinct-token and same-token branches. Updated `TreasurySwapAndDeposit` NatSpec and added an end-to-end integration test routing `TreasuryConduit -> TreasurySwapAndDeposit` with `beneficiary = address(conduit)`.
- **Regression tests.** `packages/treasury-conduits/test/TreasuryConduitsV2.t.sol` (`test_BugPoCer_5_1_13_v2ConduitRejectsThirdPartyInflowInflation`, `test_BugPoCer_5_1_9_and_5_1_13_v2Permit2Conduit`), `packages/treasury-conduits/v3/test/TreasuryConduitsV3.t.sol` (`test_BugPoCer_5_1_9_5_1_13_5_2_1_v3TreasuryConduit`, `test_integration_v3TreasuryConduit_calls_TreasurySwapAndDeposit_withConduitBeneficiary`).

### 5.1.14. TreasuryBridgeConduitV2 residues swept by any caller
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/treasury-conduits/src/bufi/conduit/TreasuryBridgeConduitV2.sol` (2 sites).
- **Root cause.** `execute` and `executePersonal` swept the full conduit balance of `tokenIn` and `bridgeToken` rather than the per-call delta, allowing any caller to exfiltrate pre-existing residues.
- **Remediation.** Snapshot `tokenInBefore` and `bridgeBefore` before pulling funds, revert `PriorBalanceConsumed` if any step reduces balance below the snapshot, and refund/bridge only the call's positive delta.
- **Regression test.** `packages/treasury-conduits/test/TreasuryConduitsV2.t.sol` (`test_BugPoCer_5_1_14_and_5_2_1_and_5_2_19_v2BridgeDeltaAndAllowlist`).

### 5.1.15. No Post Default Recovery Path
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol`.
- **Root cause.** Hub `InvoiceShelf` lacked a post-default recovery function to unwind booked tranche losses (`trancheLoss[0..2]`) and seller unrecovered loss when off-chain collections or restructurings recover funds.
- **Remediation.** Implemented `recoverDefault(bytes32 invoiceId, uint256 amount)` and `_recoverLossSeniorFirst`, pulling recovery USDC into the shelf, unwinding booked losses senior-tranche-first (`tranche 0 -> 1 -> 2`), decrementing `unrecoveredLossOf[invoiceId]` and `sellerUnrecoveredLossOf[seller]`, and keeping sellers frozen until all defaults are resolved and cured.
- **Regression tests.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_1_15_multipleDefaultsRequireAllResolvedAndCured`, `test_BugPoCer_5_2_7_recoveryUnwindsWaterfallSeniorFirst`).

### 5.1.16. Per Chunk Ceil Rounding Fee Cap Bypass
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/cctp-forwarder/src/rails/cctp/CctpDepositForwarder.sol`.
- **Root cause.** `_computeMaxFee` used `Math.Rounding.Ceil`, which is super-additive across splits. Repeatedly calling `flushUpTo(2)` paid `maxFee = 1` per 2-unit chunk (5,000 bps), bypassing the `MAX_FAST_FEE_BPS_CAP` (100 bps).
- **Remediation.** Changed `_computeMaxFee` to `Math.Rounding.Floor`. Because floor is sub-additive (`floor(a*r) + floor(b*r) <= floor((a+b)*r)`), splitting a deposit into arbitrary `flushUpTo` chunks can never exceed the configured `maxFastFeeBps` ceiling. Added `flushUpTo` to the invariant handler and verified `invariant_cumulativeFastMaxFeeWithinBpsCap`.
- **Regression tests.** `packages/fx-recibu/cctp-forwarder/test/unit/CctpDepositForwarder.t.sol` (`test_BugPoCer_5_1_16_chunkedFlushUpToCannotBypassMaxFastFeeBps`), `packages/fx-recibu/cctp-forwarder/test/invariant/CctpDepositForwarderInvariants.t.sol` (`invariant_cumulativeFastMaxFeeWithinBpsCap`).

### 5.1.17. Residual Balance Theft
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/treasury-conduits/v3/src/bufi/conduit/TreasurySwapAndDeposit.sol`.
- **Root cause.** `run` deposited and refunded full contract balances rather than per-call deltas, allowing a caller to steal stray `tokenIn` or `asset` balances sitting on the adapter.
- **Remediation.** Added pre-pull balance snapshots (`inBefore`, `assetBefore`), enforced `PriorBalanceConsumed`, deposited only `assetAfter - assetBefore`, refunded only `inAfter - inBefore`, blocked self/token swap targets, and added Safe-gated `rescue()`.
- **Regression test.** `packages/treasury-conduits/v3/test/TreasuryConduitsV3.t.sol` (`test_BugPoCer_5_1_17_v3SwapAndDepositDeltaOnlyAndAllPaths`).

### 5.1.18. TreasuryBridgeConduit v3 residues sweepable by anyone
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/treasury-conduits/v3/src/bufi/conduit/TreasuryBridgeConduit.sol` (2 sites).
- **Root cause.** Same full-balance sweep root cause as `5.1.14` in the v3 bridge conduit.
- **Remediation.** Applied strict pre-pull delta-only refunds and bridge amounts with `PriorBalanceConsumed` guards and added `ZeroBridgeFloor` validation.
- **Regression test.** `packages/treasury-conduits/v3/test/TreasuryConduitsV3.t.sol` (`test_BugPoCer_5_1_18_5_2_1_5_2_18_v3BridgeConduit`).

### 5.1.19. Partial Payment Clears Inflight Bridge Protection
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol`.
- **Root cause.** `_applyPayment` unconditionally cleared `pendingBridgeUntil[invoiceId]` on any payment, letting a 1-wei partial payment erase an active cross-chain bridge grace window; `notifyCrossChainRepayment` also lacked nonce deduplication and could shorten an active window.
- **Remediation.** Added `bridgeNonce` deduplication (`usedBridgeNonce[bridgeNonce]`), made `pendingBridgeUntil[invoiceId]` strictly monotonic so a shorter notification cannot shrink an active protection window, and cleared `pendingBridgeUntil[invoiceId]` in `_applyPayment` and `recordRepaymentSettled` only when the invoice settles or the current installment is no longer past its late boundary.
- **Regression tests.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_1_19_bridgeNonceDedupAndPartialPaymentPreservesWindow`, `test_Audit_Low8_notifyCrossChainRepaymentIsMonotonic`).

---

## 4. Detailed Responses to Low Findings (`5.2.1` to `5.2.20`)

### 5.2.1. Unauthenticated auth.token in TreasuryConduit.execute
- **Verdict.** True positive (Fixed).
- **Affected contracts.** `packages/treasury-conduits/src/bufi/conduit/TreasuryConduit.sol`, `packages/treasury-conduits/src/bufi/conduit/TreasuryBridgeConduitV2.sol`, `packages/treasury-conduits/v3/src/bufi/conduit/TreasuryConduit.sol`, `packages/treasury-conduits/v3/src/bufi/conduit/TreasuryBridgeConduit.sol` (2 sites plus sibling bridge conduits).
- **Root cause.** `execute` (and `executePersonal`) accepted arbitrary `auth.token` / `intent.tokenIn` addresses without an allowlist or pull-delta check, letting an attacker supply a spoofed token contract to forge `Executed` events or invoke registered targets.
- **Remediation.** Added Safe-curated `tokens` allowlist (`setToken(address, bool)`) and exact pull-delta verification (`inAfter - inBefore == amount`) across v2/v3 `TreasuryConduit`, `TreasuryBridgeConduitV2` (both `execute` and `executePersonal`), and v3 `TreasuryBridgeConduit`. Also blocked binding `ARC_NATIVE_USDC` (`0x3600...`) in `setCctpxToken`.
- **Regression tests.** `test_BugPoCer_5_2_1_v2ConduitTokenAllowlistAndExactPull`, `test_BugPoCer_5_1_14_and_5_2_1_and_5_2_19_v2BridgeDeltaAndAllowlist`, `test_BugPoCer_5_1_9_5_1_13_5_2_1_v3TreasuryConduit`, `test_BugPoCer_5_1_18_5_2_1_5_2_18_v3BridgeConduit`.

### 5.2.2. Restructure branch reverts: shelf lacks registry OPS_ROLE
- **Verdict.** True positive (Fixed in code + live Safe operational mitigation).
- **Affected contracts.** `packages/fx-recibu/hub/src/identity/BUFIReputationRegistry.sol`, `packages/fx-recibu/hub/test/Deploy.t.sol` (2 sites).
- **Root cause.** `InvoiceShelf.resolveDefault` called `REPUTATION.markRestructured`, which required `OPS_ROLE`, while deployment scripts only granted `SETTLEMENT_ROLE` to `hubShelf`.
- **Remediation.** Updated `BUFIReputationRegistry.markRestructured` to accept either `SETTLEMENT_ROLE` or `OPS_ROLE` (matching `setPermanentDefault`), updated `Deploy.t.sol` to also grant `OPS_ROLE` to `hubShelf`, and documented the immediate Safe transaction for live Arc 5042 (`grantRole(keccak256("OPS_ROLE"), 0x90eCDd402C0E357362b7805173191A153b876DF4)`).
- **Regression test.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_2_2_markRestructuredAcceptsSettlementOrOpsRole`).

### 5.2.3. Reverted execute leaves nonce live so signature can be retried later
- **Verdict.** Design decision.
- **Affected contracts.** `packages/treasury-conduits/src/bufi/conduit/TreasuryConduit.sol` (v2 and v3).
- **Rationale.** Atomic EVM revert semantics are intentional and documented in `TreasuryConduit` NatSpec. A transaction reverting on transient slippage or target liquidity must not leave user funds pulled without delivery. Replay window exposure is bounded by short `validBefore` timestamps signed by the treasury quorum, and an obsolete ERC-3009 authorization can be explicitly invalidated on-chain via FiatToken `cancelAuthorization`.

### 5.2.4. Uncallable Privileged Function Refund Lock Inert
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/rails/MultiTokenReceivableEscrow.sol`.
- **Root cause.** `refundUnlockAt` remained `0` unless set via a privileged call that no operational contract invoked, leaving the escrow refund lock inert.
- **Remediation.** `MultiTokenReceivableEscrow.deposit` now auto-arms `refundUnlockAt[invoiceId]` (default `1 hour`, bounded `[5 minutes, 7 days]`) only when `escrowedOf[invoiceId] == 0` prior to the deposit so follow-up dust deposits cannot slide the lock. `setRefundLock` accepts `DEFAULT_ADMIN_ROLE` or `ROUTER_ROLE` with a 7-day ceiling and an extend-only rule for `ROUTER_ROLE`.
- **Regression test.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_2_4_escrowRefundLockActiveBoundedAndNonSliding`).

### 5.2.5. Arc native fee breaks Permit2 CCTPX input baseline
- **Verdict.** True positive (Fixed).
- **Affected contracts.** `packages/treasury-conduits/src/bufi/conduit/TreasuryBridgeConduitV2.sol`, `packages/treasury-conduits/v3/src/bufi/conduit/TreasuryBridgeConduit.sol`, `packages/treasury-conduits/v3/src/bufi/conduit/TreasuryBridgeConduitPermit2.sol` (2 sites plus sibling bridge conduits).
- **Root cause.** On Arc (`5042` / `5042002`), the native gas token (`msg.value`, 18 decimals) aliases the ERC-20 USDC precompile (`0x3600...`, 6 decimals). Passing `msg.value` as a CCTPX native fee increased `IERC20(0x3600...).balanceOf(address(this))` by `msg.value / 1e12` before the swap and dropped it after `_burn`, breaking the post-burn `tokenIn` baseline check.
- **Remediation.** Refund any unspent `tokenIn` delta before `_burn` on swap-then-bridge paths, enforce exact 18-decimal native conservation (`address(this).balance == nativeBefore`), require `inputAfterBurn == nativeBefore / 1e12` when `tokenIn == ARC_NATIVE_USDC` (zero slack), and enforce strict `inputAfterBurn == tokenInBefore` for every non-Arc ERC-20 token.
- **Regression tests.** `test_BugPoCer_5_2_5_and_5_2_18_v2BridgeArcNativeUsdcAndQuoteValidation`, `test_BugPoCer_5_2_5_v3BridgePermit2ArcNativeUsdcExactAndNonMultipleOf1e12`.

### 5.2.6. Bearer-link reclaim window not enforced in PeanutV4
- **Verdict.** Design decision (NatSpec corrected).
- **Affected contract.** `packages/claim-vault/src/V4/PeanutV4.4.sol` (3 sites).
- **Rationale.** `PayrollBatch` and BUFI's `makeCustomDeposit` flow cryptographically enforce the 30-day `CLAIM_WINDOW` (`reclaimableAfter = block.timestamp + CLAIM_WINDOW`). Legacy upstream Peanut v4.4 entry points intentionally accept `reclaimableAfter == 0` for backward compatibility with existing Peanut SDK callers and upstream test suites. Corrected the stale `"after 24 hours"` NatSpec comment in `PeanutV4.4.sol` and clarified the BUFI fork notice so documented invariants match runtime behavior.

### 5.2.7. Defaulted seller can re-borrow full limit right after loss
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol`.
- **Root cause.** A defaulted seller could immediately lock a new invoice before booked LP losses were resolved and recovered.
- **Remediation.** `lockInvoice` now reverts with `Frozen` whenever `unresolvedDefaultCountOf[seller] > 0` or `sellerUnrecoveredLossOf[seller] > 0`, blocking all new borrowing until every default is resolved and 100% of LP loss is recovered (while preserving SPEC 3.3/4.8 earned limit `L(w)` once LPs are made whole).
- **Regression tests.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_2_7_recoveryUnwindsWaterfallSeniorFirst`, `test_BugPoCer_5_1_4_resolveDefaultNoReplayAndKeepsFrozenUntilLossCured`).

### 5.2.8. Escrow setToken bypasses router token-disable delay
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/rails/MultiTokenReceivableEscrow.sol` (2 sites).
- **Root cause.** `MultiTokenReceivableEscrow.setToken(token, false)` disabled an active token immediately without a timelock, bypassing the router's 1-day disable delay and stranding in-flight invoice repayments.
- **Remediation.** Implemented a 1-day `TOKEN_DISABLE_DELAY` with a 7-day execution window (`scheduleTokenDisable`, `executeTokenDisable`, `cancelTokenDisable`) on `MultiTokenReceivableEscrow`, while permitting deposits to already-bound in-flight escrow invoices (`tokenOf[invoiceId] == token`).
- **Regression test.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_2_8_escrowDisableTimelockWindowAndInFlightContinuity`).

### 5.2.9. Missing Input Validation Noncanonical Mint Recipient
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/cctp-forwarder/src/rails/cctp/CctpDepositForwarderFactory.sol`.
- **Root cause.** `_validate` checked `mintRecipient != bytes32(0)` but did not verify that the upper 96 bits were zero for EVM destination domains, risking permanent funds loss on non-canonical EVM addresses.
- **Remediation.** Added `error NonCanonicalMintRecipient(bytes32 mintRecipient)` and rejected any `uint256(mintRecipient) >> 160 != 0` inside `_validate` (covering `predict`, `deploy`, `deployAndFlush`, and caller-restricted variants).
- **Regression test.** `packages/fx-recibu/cctp-forwarder/test/unit/CctpDepositForwarder.t.sol` (`test_BugPoCer_5_2_9_factoryRejectsNonCanonicalMintRecipient`).

### 5.2.10. Missing Self Dealing Check
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol`.
- **Root cause.** `lockInvoice` did not prevent a seller from factoring an invoice against itself or against another workspace owned by the same identity owner.
- **Remediation.** Added self-dealing guards in `lockInvoice` rejecting both `seller == debtor` and `IDENTITY.ownerOf(seller) == IDENTITY.ownerOf(debtor)`.
- **Regression test.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_2_10_lockInvoiceBlocksSelfDealingSameIdAndSameOwner`).

### 5.2.11. Permissionless flusher can force CCTP fast-path fee onto payroll deposit
- **Verdict.** Design decision (Partially hardened for `maxFastFeeBps == 0`).
- **Affected contract.** `packages/fx-recibu/cctp-forwarder/src/rails/cctp/CctpDepositForwarder.sol`.
- **Rationale and hardening.** When a forwarder is configured with `maxFastFeeBps > 0`, allowing any permissionless relayer to trigger fast-finality settlement up to that bounded fee cap is intentional design. However, payroll forwarders configured with `maxFastFeeBps == 0` should never request fast finality. Hardened `_flush` so `effectiveFast = fast && cfg.maxFastFeeBps > 0`, forcing the standard finality threshold (`2000`) and emitting `Flushed.fast == false` whenever `maxFastFeeBps == 0`.
- **Regression test.** `packages/fx-recibu/cctp-forwarder/test/unit/CctpDepositForwarder.t.sol` (`test_BugPoCer_5_2_11_zeroFeeBpsForcesStandardFinalityThreshold`).

### 5.2.12. Relayer can run stale payroll sharing a payrollId, blocking the corrected one
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/claim-vault/src/payroll/PayrollBatch.sol`.
- **Root cause.** `PayrollBatch` provided no on-chain cancellation path for a treasury MSCA constrained by an AddressBook allowlist to invalidate an unexecuted `payrollId` before a relayer submits a stale signature.
- **Remediation.** Inherited `EIP712("PayrollBatch", "1")` and added `cancelPayroll(address from, bytes32 payrollId, uint256 deadline, bytes calldata signature)` supporting direct calls from `from` as well as relayed EOA/ERC-1271 quorum signatures via `SignatureChecker`, with `CancelExpired`, `InvalidCancelSignature`, and `PayrollCancelled`.
- **Regression tests.** `packages/claim-vault/test/PayrollBatch.t.sol` (`test_BugPoCer_5_2_12_cancelPayrollWithQuorumSignatureBlocksStaleExecution`, `test_BugPoCer_5_2_12_cancelPayrollRejectsExpiredAndWrongSigner`, `test_BugPoCer_5_2_12_cancelPayrollDirectByOwner`).

### 5.2.13. Sandwichable treasury swap down to signed minimum output
- **Verdict.** Design decision.
- **Affected contracts.** `packages/treasury-conduits/src/bufi/conduit/TreasuryConduit.sol` (v2 and v3).
- **Rationale.** Public-mempool AMM sandwiching down to a signed `minOut` is an inherent EVM DEX execution property rather than a contract bug. BUFI mitigates MEV operationally through tight quorum-signed `minOut` quotes, short authorization deadlines, private RPC / Flashbots Protect submission, and RFQ/solver venues where available.

### 5.2.14. Signature Replay Unbound Owner
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/claim-vault/src/payroll/PayrollBatch.sol`.
- **Root cause.** `payrollHash` did not commit to `address from`, leaving the witness hash independent of the paying treasury account.
- **Remediation.** Added `address from` as the first parameter of `payrollHash` and `witnessOf`, added a `ZeroAddress()` guard on `from`, and bound `from` into the keccak256 commitment verified during `executePayroll`.
- **Regression test.** `packages/claim-vault/test/PayrollBatch.t.sol` (`test_BugPoCer_5_2_14_payrollHashBindsFromOwner`).

### 5.2.15. Unrestricted Payer Pull
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol`.
- **Root cause.** `applyPaymentFrom` allowed `SETTLEMENT_ROLE` to specify an arbitrary `payer` address, potentially pulling USDC from any user or LP who had granted an allowance to `InvoiceShelf`.
- **Remediation.** Outside `MIDNIGHT_MODE`, `applyPaymentFrom` now strictly requires `payer == msg.sender`, keeping `payer == address(escrow)` only for record-only `MIDNIGHT_MODE` accounting.
- **Regression test.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_2_15_applyPaymentFromRejectsArbitraryPayerInNonMidnight`).

### 5.2.16. Missing Renounce Guard Sibling Mismatch
- **Verdict.** True positive (Fixed).
- **Affected contracts.** `packages/treasury-conduits/v3/src/bufi/conduit/TreasuryBridgeConduit.sol`, `packages/treasury-conduits/v3/src/bufi/conduit/TreasuryBridgeConduitPermit2.sol`.
- **Root cause.** v3 `TreasuryBridgeConduit` omitted the `RenounceDisabled` override present on sibling v2 and v3 conduits, allowing accidental `renounceOwnership()` to brick governance and rescue controls.
- **Remediation.** Added the `renounceOwnership()` `RenounceDisabled` override to v3 `TreasuryBridgeConduit` (covering inherited `TreasuryBridgeConduitPermit2`) and expanded `ConduitGovernanceGuards.t.sol` to cover every v3 conduit contract. Also replaced the `_checkingPermit2Burn` storage flag workaround with an explicit `bool verifyAllowance` parameter on `_burn`.
- **Regression test.** `packages/treasury-conduits/v3/test/ConduitGovernanceGuards.t.sol` (`test_renounceOwnership_reverts_on_every_v3_contract`).

### 5.2.17. Timelock Bypass Via Caps
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/fx-recibu/hub/src/rails/RecibuMemoRouter.sol`.
- **Root cause.** Updating a token's capability bitmask (`caps`) could strip active capabilities immediately without waiting for `TOKEN_DISABLE_DELAY`, bypassing the timelock.
- **Remediation.** Enforced `TOKEN_DISABLE_DELAY` (with a 7-day execution window and `cancelTokenDisable`) whenever any currently active bit is removed from `caps`, and forced `caps = 0` when a scheduled disable executes.
- **Regression test.** `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol` (`test_BugPoCer_5_2_17_routerCapStrippingRequiresTimelockAndWindow`).

### 5.2.18. Unbound Unvalidated Bridge Quote
- **Verdict.** True positive (Fixed).
- **Affected contracts.** `packages/treasury-conduits/src/bufi/conduit/TreasuryBridgeConduitV2.sol`, `packages/treasury-conduits/v3/src/bufi/conduit/TreasuryBridgeConduit.sol`, `packages/treasury-conduits/v3/src/bufi/conduit/TreasuryBridgeConduitPermit2.sol`.
- **Root cause.** Bridge conduits forwarded caller-supplied `quoteData` to Circle CCTPX without validating that the quote requested a native fee matching `msg.value`, risking unexpected ERC-20 fee deductions or unbound fee terms.
- **Remediation.** Validated every CCTPX quote via `ccts.feeService().decodeQuote(quoteData)` (matching `spoke-cctp/MemoConduit.sol`), requiring native-only fee quotes matching `msg.value` and reverting on malformed, non-native, or mismatched quotes.
- **Regression tests.** `test_BugPoCer_5_2_5_and_5_2_18_v2BridgeArcNativeUsdcAndQuoteValidation`, `test_BugPoCer_5_1_18_5_2_1_5_2_18_v3BridgeConduit`, `test_v3BridgePermit2_allValidationQuoteAndAllowanceChecks`.

### 5.2.19. Unconstrained Rescue Recipient No Audit Trail
- **Verdict.** True positive (Fixed).
- **Affected contracts.** `packages/treasury-conduits/src/bufi/conduit/TreasuryConduit.sol`, `packages/treasury-conduits/src/bufi/conduit/TreasuryBridgeConduitV2.sol`, `packages/treasury-conduits/v3/src/bufi/conduit/TreasuryBridgeConduit.sol`, `packages/treasury-conduits/v3/src/bufi/conduit/TreasurySwapAndDeposit.sol`.
- **Root cause.** Rescue functions lacked uniform `Rescued(address indexed token, address indexed to, uint256 amount)` audit events in CEI order and `TreasurySwapAndDeposit` had no owner `rescue()` path.
- **Remediation.** Added `Rescued` events emitted before external transfers (CEI order) alongside `nonReentrant` and zero-address guards across v2 `TreasuryConduit`, `TreasuryBridgeConduitV2`, v3 `TreasuryBridgeConduit`, and newly added `TreasurySwapAndDeposit.rescue()`.
- **Regression tests.** `test_BugPoCer_5_2_19_v2ConduitRescueEmitsEventAndGuards`, `test_BugPoCer_5_1_14_and_5_2_1_and_5_2_19_v2BridgeDeltaAndAllowlist`, `test_F23_rescueEnforcesNonReentrantZeroAddressGuardsAndCeiEventOrder`, `test_adapter_rescue_emits_Rescued_and_enforces_guards`.

### 5.2.20. Mfa Rotation Acceptance Does Not Prove Ecdsa Key
- **Verdict.** True positive (Fixed).
- **Affected contract.** `packages/claim-vault/src/V4/PeanutV4.4.sol`.
- **Root cause.** `acceptMFAAuthorizer()` accepted the pending authorizer via `msg.sender == pendingMFAAuthorizer` without proving the new address can produce an ECDSA signature compatible with `withdrawMFADeposit` (`getSigner`), allowing a smart contract address (including a constructor call where `extcodesize == 0`) to become `MFA_AUTHORIZER` and brick MFA claims.
- **Remediation.** Added `code.length == 0` checks in `constructor`, `transferMFAAuthorizer`, and `acceptMFAAuthorizer`, and required `acceptMFAAuthorizer(bytes calldata _signature)` to verify an ECDSA signature from `pendingMFAAuthorizer` over `mfaAcceptanceDigest(pendingMFAAuthorizer)`.
- **Regression test.** `packages/claim-vault/test/PeanutV4_4.BUFI.t.sol` (`test_BugPoCer_5_2_20_mfaRotationRejectsContractAndInvalidEcdsaProof`).

---

## 5. Mutation Testing Remediation Summary

### Root Cause of the 33% Baseline Score (356 / 1,069 Killed)

Inspection of `BUFI - Mutation Testing Results.csv` showed that the 713 survived mutants clustered in five structural coverage gaps in the monorepo test suite at commit `361d31a`:

1. `packages/fx-recibu/memo-v1/test/` and `packages/fx-recibu/spoke-cctp/test/` contained only `.gitkeep` placeholders (0% and 31% scores).
2. `packages/treasury-conduits` (v2 and v3) contained only deployment and governance smoke tests while full functional execution tests lived outside the monorepo (0% to 38% scores across 8 conduit contracts).
3. `packages/fx-recibu/hub` lacked dedicated boundary tests for `WorkspaceOperatingReserve` (0%), `WorkspaceTierRegistry` (12%), `InvoiceShelf` (29%), `BUFIReputationRegistry` (30%), `BIFTranche` (33%), and `MultiTokenReceivableEscrow` (35%).
4. `packages/claim-vault/src/deploy/ClaimVaultDeployer.sol` (0%) had no direct failure/event assertions, and `PayrollBatch.t.sol` (0% in the mutation harness) relied on an etched Permit2 runtime fixture (`test/fixtures/permit2.arc-testnet.runtime.hex`) plus missing edge-case coverage on `PeanutV4.4.sol` (62%).
5. `packages/agent-policy/src/bufi/agent-policy/AgentGatewayAccountFactory.sol` (38%) lacked full precondition, post-register invariant, reentrancy, and `onERC721Received` guard assertions.

### New and Expanded Mutation-Killing Test Coverage

| Package / Contract Group | Baseline Score (Survived) | Added / Expanded Test Suite | Verified Test Count |
| --- | --- | --- | ---: |
| `treasury-conduits` v2 (`TreasuryBridgeConduitV2`, `TreasuryRedeemConduit`, `TreasuryConduitPermit2`, `TreasuryConduit`) | 0% to 38% (124 survived) | `packages/treasury-conduits/test/TreasuryConduitsV2.t.sol`, `Deploy.t.sol` | 19 passed (`default`) |
| `treasury-conduits` v3 (`TreasuryBridgeConduitPermit2`, `TreasuryBridgeConduit`, `TreasuryRedeemConduit`, `TreasuryConduit`, `TreasurySwapAndDeposit`) | 0% to 35% (129 survived) | `packages/treasury-conduits/v3/test/TreasuryConduitsV3.t.sol`, `ConduitGovernanceGuards.t.sol` | 21 passed (`treasury-v3`) |
| `fx-recibu/hub` (all 9 hub contracts) | 0% to 59% (258 survived) | `packages/fx-recibu/hub/test/BugPoCerHubRemediation.t.sol`, `HubMutationCoverage.t.sol`, `Deploy.t.sol` | 49 passed (`fx-hub`) |
| `fx-recibu/spoke-cctp` (`MemoConduit`, `SpokeMemoConduit`) | 31% (95 survived) | `packages/fx-recibu/spoke-cctp/test/MemoConduit.t.sol` | 20 passed (`fx-spoke`) |
| `fx-recibu/memo-v1` (`MemoConduit`) | 0% (13 survived) | `packages/fx-recibu/memo-v1/test/MemoConduit.t.sol` | 13 passed (`fx-memo-v1`) |
| `claim-vault` (`PayrollBatch`, `ClaimVaultDeployer`, `PeanutV4.4`) | 0% to 62% (59 survived) | `PayrollBatch.t.sol`, `PeanutV4_4.BUFI.t.sol`, `PeanutV4_4.ECO.t.sol`, `PeanutV4_4.GaslessCustody.t.sol` | 134 passed (`claim-vault`) |
| `agent-policy` (`AgentGatewayAccountFactory`) | 38% (20 survived) | `packages/agent-policy/test/AgentGatewayAccountFactory.t.sol` | 12 passed (`agent-policy`) |
| `fx-recibu/cctp-forwarder` (`CctpDepositForwarder`, `Factory`) | 74% to 100% (7 survived) | `CctpDepositForwarder.t.sol`, `CctpDepositForwarderInvariants.t.sol` | 73 passed (`fx-cctp-forwarder`) |

### Non-Vacuous Broken-Control Verification

In addition to green test runs, live fault-injection checks were executed and reverted cleanly across all four modified contract packages to prove every new guard and reentrancy check kills real mutations:

- `fx-cctp-forwarder`: 12/12 injected mutants killed (all 7 previously survived mutants plus 5 new rounding and canonical-address boundary mutants).
- `claim-vault`: removing `from` from `PayrollBatch.payrollHash` immediately failed `test_BugPoCer_5_2_14_payrollHashBindsFromOwner`.
- `treasury-conduits` v2 and v3: removing `nonReentrant` on v2 `TreasuryConduit.execute` and v3 `TreasurySwapAndDeposit.run` immediately failed their respective real-callback reentrancy tests.
- `fx-hub`: removing `trancheCapacity` in `InvoiceShelf.lockInvoice` immediately failed `test_BugPoCer_5_1_6_trancheCapacityBlocksJuniorBorrowingFromSenior`.

---

## 6. Full 10-Profile Build and Test Verification Matrix

Executed at the final remediation state using `./script/build-all.sh && ./script/test-all.sh` (`solc`) and `./script/build-all.sh --use solar && ./script/test-all.sh --use solar` (`solar 0.3.0-dev+commit.e7a91fc7`).

| Foundry Profile | `solc` Passed | `solc` Failed | `solc` Skipped | `solar` Passed | `solar` Failed | `solar` Skipped |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `default` | 19 | 0 | 0 | 19 | 0 | 0 |
| `treasury-v3` | 21 | 0 | 0 | 21 | 0 | 0 |
| `agent-policy` | 12 | 0 | 0 | 12 | 0 | 0 |
| `fx-hub` | 49 | 0 | 0 | 49 | 0 | 0 |
| `fx-spoke` | 20 | 0 | 0 | 20 | 0 | 0 |
| `fx-memo-v1` | 13 | 0 | 0 | 13 | 0 | 0 |
| `fx-stablefx` | 39 | 0 | 0 | 39 | 0 | 0 |
| `fx-cctp-forwarder` | 73 | 0 | 1 | 73 | 0 | 1 |
| `fx-doc-registry` | 163 | 0 | 0 | 163 | 0 | 0 |
| `claim-vault` | 134 | 0 | 9 | 134 | 0 | 9 |
| **Total** | **543** | **0** | **10** | **543** | **0** | **10** |

Skipped tests (10 total) are exclusively opt-in live-RPC fork tests (`CctpDepositForwarderFork.t.sol` on Base Sepolia and `ArcMainnetWfxFork.t.sol` / `PayrollBatchDeployed.t.sol` live fork specs when fork RPC URLs are unset).

---

## 7. Note on Contract-Header Invariants for BugPoCer Re-Scan

Because BugPoCer infers invariants from NatSpec and documentation in addition to contract code, stale contract-header invariant comments were updated on v2/v3 `TreasuryConduit`, `TreasuryBridgeConduitV2`, v3 `TreasuryBridgeConduit`, `TreasurySwapAndDeposit`, hub `InvoiceShelf`, and `PeanutV4.4` so future scans reflect the exact post-remediation invariants.
