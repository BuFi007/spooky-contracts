# BUFI vNext BugPoCer Safe Redeploy and Rewire Runbook

This runbook provides ready-to-drop Safe Transaction Builder JSON batches and an ordered operator checklist to apply the immediate live Arc Mainnet hotfix (`5.2.2`) and roll out all BugPoCer audit-remediated vNext contracts across Arc Testnet (`5042002`), Arc Mainnet (`5042`), Avalanche C-Chain (`43114`), and Base Mainnet (`8453`).

## 1. Release Provenance and Verification Summary

- **Repository and branch.** `spooky-contracts` on `fix/bugpocer-audit-remediation` (source commit `baa6fb56a5844b1438a0ce0f9404156171d4e9d8`).
- **Batch directory.** [`deployments/safe-tx-builder/vnext-bugpocer/`](deployments/safe-tx-builder/vnext-bugpocer/) and [`MANIFEST.json`](deployments/safe-tx-builder/vnext-bugpocer/MANIFEST.json). Historical Nov 7 manifests (`deployments/addresses.json`, `deployments/bytecode-hashes.json`, `deployments/live-receipts-2026-11-07.json`, and `deployments/safe-tx-builder/MANIFEST.json`) remain untouched.
- **Generator script.** [`script/generate_vnext_safe_tx_builder.py`](script/generate_vnext_safe_tx_builder.py).
- **Compiler mode.** Canonical `solc` via `./script/build-all.sh` (`forge 1.10.0`), guaranteeing deterministic CREATE2 addresses and explorer source verification across ArcScan, Snowtrace, BaseScan, and Sourcify:
  - `default` and `treasury-v3`: `solc 0.8.24` (`paris`, `via_ir=true`, `optimizer_runs=200`, `bytecode_hash=ipfs`).
  - `fx-hub` and `fx-cctp-forwarder`: `solc 0.8.26` (`cancun`, `via_ir=true`, `optimizer_runs=200`, `bytecode_hash=ipfs`).
  - `claim-vault`: `solc 0.8.23` (`paris`, `optimizer_runs=99999`).
- **CREATE2 factory and salt namespace.** Arachnid Deterministic Deployment Proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C` with suffix `.bugpocer.vnext` appended to every salt label so zero addresses collide with live Nov 7 deployments.
- **Simulation proof.** [`deployments/safe-tx-builder/vnext-bugpocer/verify/VNextSafeBatches.t.sol`](deployments/safe-tx-builder/vnext-bugpocer/verify/VNextSafeBatches.t.sol) parses every JSON file directly from disk, executes every transaction from the target Safe, and asserts exact predicted CREATE2 addresses, spawned CREATE child addresses (`BINV`, `bIF-A/B/C`, `PeanutV4`), EIP-170 runtime sizes (`<= 24,576` bytes), and all post-deploy state and role wiring.

### Live On-Chain Verification Findings (Arc Mainnet `5042`, Measured 2026-11-23)

1. **Arc Mainnet EURC address corrected.** Historical Nov 7 batches passed `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` on Arc Mainnet `5042`. Live `eth_getCode` proved that address has `0` bytes on Arc Mainnet (it is Arc Testnet `5042002` EURC). Live Arc Mainnet EURC is `0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1` (`1,798` bytes, `symbol="EURC"`, `decimals=6`, confirmed by Circle mainnet `CCTPX.resolveTokenManager(0x6ca9...41c).token()`). Every Arc Mainnet vNext batch binds `0xbEf5...21c1`.
2. **CCTPx EURC token IDs separated by network.** Mainnet (`5042`, `43114`) uses `0x6ca9e29fa53becc29becaf4a90b9ca7a995ad4d2234880da13ca38c657fb241c`. Arc Testnet (`5042002`) uses `0x2587821a0ee7daa174b95436b5dab1731cfa1844775b010217d3c0dd02a4eecd`. Both resolve to live Circle `TokenManager` contracts matching chain EURC.
3. **Live Arc `0x3600...` precompile floor division confirmed (`5.2.5`).** Live Arc Mainnet deployer `0x4a74F022893E3F1237Ef530DA2Df1d9b4AFF4772` holds `7807216708564000000` native wei (non-zero remainder `708564000000`) and `0x3600...::balanceOf` returns `7807216` (`== nativeWei / 1e12` exact integer floor). The `inputAfterBurn == nativeBefore / 1e12` invariant in `TreasuryBridgeConduit` and `TreasuryBridgeConduitV2` holds without adjustment.
4. **Live Arc Mainnet CCTPx `FeeManager` exact-payment proof (`5.2.7`).** Live `CCTPX(0x43187122...42BC).feeService()` resolves to `0x88e0FEE76fE71F467009DFddcfa759dDc6B1a575` (`paused == false`, `feeCollectionAddress == 0x171546b665904adB7647429939614b5d6A254A6E`). Fork execution against live bytecode proved:
   - `FeeManager.decodeQuote(bytes)` parses live 929-byte `0x01`-prefixed IRIS quotes into the exact `ICctpXFeeManager.Quote` struct (`FORWARD`, `PRE_FINALITY`, `PROTOCOL`, `expiry`, `feeToken = address(0)`, `nonce = 0`, 65-byte ECDSA signature).
   - `FeeManager.collectFeesWithQuote` enforces exact native payment (`msg.value == quoteTotal`), reverting with `IncorrectNativePayment(uint256,uint256)` (`0xd7b4ffad`) on both excess and short `msg.value`, routing exact `feeAmt` to `feeCollectionAddress`, and returning `0` wei to the caller (`conduit.balance == nativeBefore`).
   - `FeeManager.collectFeesWithQuote` checks `0x3600...::isBlacklisted(claim.refundAddress)` before signature validation. Our conduits pass `payable(msg.sender)` as `refundAddress`, so the relayer EOA must not be blocklisted.
5. **Live Nov 7 Arc Mainnet state.** Safe `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09` (`threshold=1`, `nonce=11`). Live Nov 7 `InvoiceShelf` (`0x90eCDd40...6DF4`) has `nextInvoiceId == 1` (`0` active invoices) and live Nov 7 `PeanutV4` (`0xeA06BF5A...8965`) has `0` deposits, so vNext cutover starts with clean state and zero fund migration.
6. **Base Mainnet (`8453`) Safe status.** `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09` currently has `0` code bytes on Base `8453`. Base deployment is therefore split into `04a` (CREATE2 deploys runnable via `MultiSendCallOnly` or Base Safe) and `04b` (`PeanutV4.acceptOwnership()`, run from Base Safe once deployed).
7. **Operational MFA authorizer check (`5.2.20`).** `0x9c8515333aFdB567C31CDF53CD60868f3B64b724` has `0` code bytes (EOA) on all four chains, satisfying the `PeanutV4` constructor EOA guard.

## 2. Master Safe Batch Schedule

All execution gas figures were measured via Foundry simulation (`VNextSafeBatches.t.sol`). Every batch stays well below both the chain block gas limit and the EIP-7825 single-transaction cap (`16,777,216` gas).

| Order | File in `deployments/safe-tx-builder/vnext-bugpocer/` | Chain | Safe Address | Txs | Measured Gas | Chain Block Gas Limit |
| --- | --- | --- | --- | ---: | ---: | ---: |
| Phase 0 | `00-arc-5042-hotfix-5-2-2-grant-ops-role.json` | Arc Mainnet (`5042`) | `0x47Dc7D18...0D09` | 1 | `51,779` | `30,000,000` |
| Phase 1A | `01a-arc-testnet-5042002-vnext-conduits-v2.json` | Arc Testnet (`5042002`) | `0xA3a40fa2...468B` | 24 | `8,184,375` | `30,000,000` |
| Phase 1B | `01b-arc-testnet-5042002-vnext-conduits-v3.json` | Arc Testnet (`5042002`) | `0xA3a40fa2...468B` | 29 | `10,451,483` | `30,000,000` |
| Phase 1C | `01c-arc-testnet-5042002-vnext-claim-vault-and-forwarder.json` | Arc Testnet (`5042002`) | `0xA3a40fa2...468B` | 5 | `8,886,872` | `30,000,000` |
| Phase 2A | `02a-arc-5042-vnext-conduits-v2.json` | Arc Mainnet (`5042`) | `0x47Dc7D18...0D09` | 32 | `8,578,347` | `30,000,000` |
| Phase 2B | `02b-arc-5042-vnext-conduits-v3.json` | Arc Mainnet (`5042`) | `0x47Dc7D18...0D09` | 39 | `10,945,429` | `30,000,000` |
| Phase 2C | `02c-arc-5042-vnext-fx-hub-part1.json` | Arc Mainnet (`5042`) | `0x47Dc7D18...0D09` | 12 | `10,366,963` | `30,000,000` |
| Phase 2D | `02d-arc-5042-vnext-fx-hub-part2.json` | Arc Mainnet (`5042`) | `0x47Dc7D18...0D09` | 10 | `4,474,564` | `30,000,000` |
| Phase 2E | `02e-arc-5042-vnext-claim-vault.json` | Arc Mainnet (`5042`) | `0x47Dc7D18...0D09` | 3 | `7,612,396` | `30,000,000` |
| Phase 3A | `03a-avalanche-43114-vnext-conduits-v2.json` | Avalanche (`43114`) | `0xA3a40fa2...468B` | 28 | `8,382,837` | `80,000,000` |
| Phase 3B | `03b-avalanche-43114-vnext-conduits-v3-and-forwarder.json` | Avalanche (`43114`) | `0xA3a40fa2...468B` | 28 | `9,044,246` | `80,000,000` |
| Phase 3C | `03c-avalanche-43114-vnext-claim-vault.json` | Avalanche (`43114`) | `0xA3a40fa2...468B` | 3 | `7,612,324` | `80,000,000` |
| Phase 4A | `04a-base-8453-vnext-cctp-forwarder-and-claim-vault.json` | Base (`8453`) | `0x47Dc7D18...0D09` (or `MultiSendCallOnly`) | 4 | `8,853,290` | `40,000,000` |
| Phase 4B | `04b-base-8453-vnext-claim-vault-accept-ownership.json` | Base (`8453`) | `0x47Dc7D18...0D09` (once deployed) | 1 | `36,298` | `40,000,000` |

## 3. Phase 0: Immediate Live Arc Mainnet Hotfix (`5.2.2`)

Execute this batch immediately before starting any vNext redeploy. It resolves BugPoCer finding `5.2.2` on the currently live Nov 7 Arc Mainnet hub so `InvoiceShelf.resolveDefault(..., Restructured)` no longer reverts with `AccessControlUnauthorizedAccount`.

- **Safe wallet.** Arc Mainnet (`5042`) Safe `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09`.
- **File to drop in Safe Transaction Builder.** `deployments/safe-tx-builder/vnext-bugpocer/00-arc-5042-hotfix-5-2-2-grant-ops-role.json`.
- **Transaction contents.** Calls `BUFIReputationRegistry(0x2D7125b1cf826bE4ad6D0b043F6B4675897EB2e9).grantRole(0x65aa5eac1b32fde55d4db583460221274367300ae805596cf543907b5d458c00, 0x90eCDd402C0E357362b7805173191A153b876DF4)`.

### Phase 0 Checklist

- [ ] Open Safe App on Arc Mainnet (`5042`) for `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09`.
- [ ] Open Transaction Builder and upload `00-arc-5042-hotfix-5-2-2-grant-ops-role.json`.
- [ ] Confirm the target is `0x2D7125b1cf826bE4ad6D0b043F6B4675897EB2e9` and `account` is `0x90eCDd402C0E357362b7805173191A153b876DF4`.
- [ ] Sign and execute (`threshold = 1`).
- [ ] Verify immediately with `cast` (must return `true`):

```bash
OPS_ROLE=$(cast keccak "OPS_ROLE")
cast call --rpc-url "$ARC_MAINNET_RPC_URL" \
  0x2D7125b1cf826bE4ad6D0b043F6B4675897EB2e9 \
  "hasRole(bytes32,address)(bool)" \
  "$OPS_ROLE" \
  0x90eCDd402C0E357362b7805173191A153b876DF4
```

**Note on live Nov 7 `MemoConduit` (`0x0f531Cf6E1F54585Db080d51c9a0B32C9b89a684`).** That contract is unchanged by the audit and stays live, but its constructor enabled Arc Testnet EURC (`0x89B5...D72a`) instead of Arc Mainnet EURC (`0xbEf5...21c1`). USDC checkout works today. If you need EURC checkout on `MemoConduit` on Arc Mainnet, submit an optional Safe call to `0x0f531Cf6E1F54585Db080d51c9a0B32C9b89a684` calling `setSupportedToken(0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1, true)` (only if supported by `MemoConduit`, otherwise redeploy `MemoConduit` with mainnet EURC).

## 4. Phase 1: Arc Testnet (`5042002`) vNext Rehearsal

Execute all three batches in order on Arc Testnet (`5042002`) Safe `0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B`. Batch `01a` must confirm before `01b` because `01b` registers `TreasurySwapAndDeposit` as a Permit2 route on the `TreasuryConduitPermit2` deployed in `01a`.

### Phase 1 Checklist

- [ ] Drop and execute `01a-arc-testnet-5042002-vnext-conduits-v2.json` (24 txs, ~8.18M gas). Wait for confirmation.
- [ ] Drop and execute `01b-arc-testnet-5042002-vnext-conduits-v3.json` (29 txs, ~10.45M gas). Wait for confirmation.
- [ ] Drop and execute `01c-arc-testnet-5042002-vnext-claim-vault-and-forwarder.json` (5 txs, ~8.89M gas). Wait for confirmation.
- [ ] Run Phase 4 verification commands for `5042002` and confirm every contract matches the predicted table below.

### Predicted Arc Testnet (`5042002`) vNext Addresses

| Contract | Predicted Address | Batch |
| --- | --- | --- |
| `TreasuryConduit` (v2) | `0xe7E3592A5c911C094c401743E5727122579AF153` | `01a` |
| `TreasuryConduitPermit2` (v2) | `0xfd39bD3147b7dB1382164642c1CC0453395fC6A8` | `01a` |
| `TreasuryBridgeConduitV2` (v2) | `0xB72563dC5eB2D63e3eE7b0d7e01327018F922ff1` | `01a` |
| `TreasuryConduit` (v3) | `0xB1C941ca3aB87dF0E187BC49f5134634924a3f70` | `01b` |
| `TreasuryBridgeConduit` (v3) | `0x5891A451F60C36d74367b047D385E360D70f3242` | `01b` |
| `TreasuryBridgeConduitPermit2` (v3) | `0x92580aDb23973567C8590978aA202768606d26b9` | `01b` |
| `TreasurySwapAndDeposit` (v3) | `0x02c2FC1C7a8C9436670387ed4079A0C7d6c909cB` | `01b` |
| `CctpDepositForwarder` (impl) | `0xDe831fe5175D9aBeF63516ff7EA4f02c81223221` | `01c` |
| `CctpDepositForwarderFactory` | `0x0d89a614F7Ec3A2452fDf9C39eEb01F69a926c98` | `01c` |
| `ClaimVaultDeployer` | `0x05c14dfd71bD9028909ce42c7F6dC645D6DfA927` | `01c` |
| `PeanutV4` (spawned `CREATE` nonce 1) | `0x334c0c981fbBFff5D93A26F7429a86d97F03778e` | `01c` |
| `PayrollBatch` | `0x0eD7f2a1edb378fB8407c1B7E187fd1b5daC25Cf` | `01c` |

## 5. Phase 2: Mainnet Rollout

### 5.1 Arc Mainnet (`5042`)

- **Safe wallet.** `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09`.
- **Execution dependencies.** Run `02a` before `02b` (`02b` registers `TreasurySwapAndDeposit` on `TreasuryConduitPermit2` from `02a`). Run `02c` before `02d` (`02d` calls `InvoiceShelf.setEscrow` on the shelf deployed in `02c`). Batch `02e` is independent.
- **Included wiring highlights.**
  - `setToken(0x3600...0000, true)` and `setToken(0xbEf5...21c1, true)` on all six v2 and v3 ERC-3009 conduits (`5.2.1`).
  - `setCctpxToken(0x6ca9...41c, 0xbEf5...21c1)` on all three bridge conduits. `0x3600...` is never bound (`5.2.5`).
  - `BUFIReputationRegistry` wired to live Nov 7 `BUFIIdentityRegistry` (`0x6730b8f3FF0eF85E097Af01eC8a3e450d30e466d`) and grants `ATTESTOR_ROLE` to Safe plus both `SETTLEMENT_ROLE` and `OPS_ROLE` to vNext `InvoiceShelf` (`5.2.2`).
  - `InvoiceShelf` wired to vNext `WorkspaceOperatingReserve` and `MultiTokenReceivableEscrow`, with `SERVICER_ROLE` and `SETTLEMENT_ROLE` granted to Safe and `OPS_ROLE` granted to Telarana Keeper EOA (`0xcA02Be6cDBb806d4a327FC92E094D1A44EC37445`).
  - `MultiTokenReceivableEscrow` and `RecibuMemoRouter` enable Arc Mainnet USDC (`0x3600...`) and EURC (`0xbEf5...21c1`, `CAP_3009 | CAP_PERMIT = 3`).
  - `PeanutV4.acceptOwnership()` completes `Ownable2Step` ownership handover to Safe `0x47Dc...0D09`.

#### Arc Mainnet (`5042`) Checklist

- [ ] Drop and execute `02a-arc-5042-vnext-conduits-v2.json` (32 txs, ~8.58M gas). Wait for confirmation.
- [ ] Drop and execute `02b-arc-5042-vnext-conduits-v3.json` (39 txs, ~10.95M gas). Wait for confirmation.
- [ ] Drop and execute `02c-arc-5042-vnext-fx-hub-part1.json` (12 txs, ~10.37M gas). Wait for confirmation.
- [ ] Drop and execute `02d-arc-5042-vnext-fx-hub-part2.json` (10 txs, ~4.47M gas). Wait for confirmation.
- [ ] Drop and execute `02e-arc-5042-vnext-claim-vault.json` (3 txs, ~7.61M gas). Wait for confirmation.
- [ ] Record all five transaction hashes and block numbers.

#### Predicted Arc Mainnet (`5042`) vNext Addresses

| Contract | Predicted Address | Batch |
| --- | --- | --- |
| `BUFIIdentityRegistry` (reused live Nov 7) | `0x6730b8f3FF0eF85E097Af01eC8a3e450d30e466d` | Reused |
| `TreasuryConduit` (v2) | `0x5dD2e0112B10681e799155676486E1D8aD8c77d7` | `02a` |
| `TreasuryConduitPermit2` (v2) | `0xc87dfe14675D2F973ED99961cf0b5a82e357FfE6` | `02a` |
| `TreasuryBridgeConduitV2` (v2) | `0xE74C0A896F52015c3e8f474c30C52C00c56DB3d8` | `02a` |
| `TreasuryConduit` (v3) | `0xbe4b7524576BD9AB2E6D88A8BE74773CcBa4B4E7` | `02b` |
| `TreasuryBridgeConduit` (v3) | `0xfdC52570590dD8F9801cF501CffFC17C29D7f77e` | `02b` |
| `TreasuryBridgeConduitPermit2` (v3) | `0xE8C1A1B56FDF3628a30e4EB18274274A12cac3D6` | `02b` |
| `TreasurySwapAndDeposit` (v3) | `0x3541BfbD564058Be47A0cfFD00291a93A8bd6670` | `02b` |
| `BUFIReputationRegistry` | `0x3627cFFF52a1a895Dc2198971B10D3d64d312215` | `02c` |
| `WorkspaceTierRegistry` | `0x77E2837370f431F0C52bC5236B86BF92EAC2BE06` | `02c` |
| `WorkspaceOperatingReserve` | `0x3cDEC911Df8345D8d6bFB83d34dCBBfeB4d67605` | `02c` |
| `InvoiceShelf` | `0xD2FaA2B5044819fda138c7D3B0cfAF3b06E60E8C` | `02c` |
| `BINV` (spawned `CREATE` nonce 1) | `0xB841BF47FEfcb4cAd2cBF7584c2DcB62255ace8D` | `02c` |
| `BIFTranche` Senior `bIF-A` (nonce 2) | `0xDdA5AaDD985f9f16650841979BE9BD9477d82A2D` | `02c` |
| `BIFTranche` Mezzanine `bIF-B` (nonce 3) | `0x1136B27a2bfd328f99A9De5E146A55b72036d3a1` | `02c` |
| `BIFTranche` Junior `bIF-C` (nonce 4) | `0x73aB46451999854B515BB875fd7F6cbFFa597689` | `02c` |
| `MultiTokenReceivableEscrow` | `0x4Aa12CfadAe9e32e55111caD9c98A24C784d9E52` | `02d` |
| `RecibuMemoRouter` | `0xB9eA41D9a9a9BF2F81a4FC9d22994226F4645b52` | `02d` |
| `CctpDepositForwarder` (impl) | `0xDe831fe5175D9aBeF63516ff7EA4f02c81223221` | `02d` |
| `CctpDepositForwarderFactory` | `0x4C3D9249C8FEE9d35B045B09b97fc99CE6CEB8E5` | `02d` |
| `ClaimVaultDeployer` | `0xA8376Fe8Ef5a6640e39f047c751d7740C10f2cEA` | `02e` |
| `PeanutV4` (spawned `CREATE` nonce 1) | `0x75EbdB0065729849bb1A8807718B753374AD2Ca1` | `02e` |
| `PayrollBatch` | `0x7DFBb79878a70d1981D0DF76c8262fDddd883FEc` | `02e` |

#### Unchanged Nov 7 Contracts Kept Live (Do Not Redeploy)

Zero audit changes touched these contracts, so their live Nov 7 addresses stay active:
- Arc Mainnet (`5042`): `TreasuryRedeemConduit` v2 (`0x5f47FEEE01B89D8B1A1FAb4e8A52B0C4C2b7EeAa`), `TreasuryRedeemConduit` v3 (`0x78DCE8E25B092E5956d7DF4314AAa8d0b6bF60e5`), `BUFIIdentityRegistry` (`0x6730b8f3FF0eF85E097Af01eC8a3e450d30e466d`), `DocumentReceivableRegistry` (`0x7B5a94C59313371BDD3CffA8c165D7fb1C31423C`), `MemoConduit` (`0x0f531Cf6E1F54585Db080d51c9a0B32C9b89a684`), `MemoConduitV1` (`0xE29a9e12A845C736B6C916f6488321b5520c64F1`), `AgentGatewayAccountFactory` (`0xC4c3886A7f66E49fF95d7A15a12958b4cBa0eA3C`).
- Avalanche (`43114`): `SpokeMemoConduit` (`0x8e578D1F823015E76f67D6a8E2248d1e7240903E`), `MemoConduit` (`0x5eA348573432070F13f29a92a55e7B88240E2102`).
- Arc Testnet (`5042002`): `AgentGatewayAccountFactory` (`0xbeF3d87dB69490115a8B83512E1e1D0e2e38D7f9`), `DocumentReceivableRegistry` (`0xE67432aE99c7212b9e2b6bC09C91D1A46eF78f15`), `MemoConduit` (`0xF785Ce181349f2B4D360897B35931a3d0a0c42a3`).

### 5.2 Avalanche C-Chain (`43114`)

- **Safe wallet.** `0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B`.
- **Cross-chain address parity.** Because Avalanche uses the same Safe address as Arc Testnet, all shared conduits, `ClaimVaultDeployer`, `PeanutV4`, and `PayrollBatch` land at identical addresses on both chains.

#### Avalanche (`43114`) Checklist

- [ ] Drop and execute `03a-avalanche-43114-vnext-conduits-v2.json` (28 txs, ~8.38M gas). Wait for confirmation.
- [ ] Drop and execute `03b-avalanche-43114-vnext-conduits-v3-and-forwarder.json` (28 txs, ~9.04M gas). Wait for confirmation.
- [ ] Drop and execute `03c-avalanche-43114-vnext-claim-vault.json` (3 txs, ~7.61M gas). Wait for confirmation.
- [ ] Record all three transaction hashes and block numbers.

#### Predicted Avalanche (`43114`) vNext Addresses

| Contract | Predicted Address | Batch |
| --- | --- | --- |
| `TreasuryConduit` (v2) | `0xe7E3592A5c911C094c401743E5727122579AF153` | `03a` |
| `TreasuryConduitPermit2` (v2) | `0xfd39bD3147b7dB1382164642c1CC0453395fC6A8` | `03a` |
| `TreasuryBridgeConduitV2` (v2) | `0xB72563dC5eB2D63e3eE7b0d7e01327018F922ff1` | `03a` |
| `TreasuryBridgeConduit` (v3) | `0x5891A451F60C36d74367b047D385E360D70f3242` | `03b` |
| `TreasuryBridgeConduitPermit2` (v3) | `0x92580aDb23973567C8590978aA202768606d26b9` | `03b` |
| `CctpDepositForwarder` (impl) | `0xDe831fe5175D9aBeF63516ff7EA4f02c81223221` | `03b` |
| `CctpDepositForwarderFactory` | `0x1E4B7346FbBadAd0b63e7b424f36A6A4C3690354` | `03b` |
| `ClaimVaultDeployer` | `0x05c14dfd71bD9028909ce42c7F6dC645D6DfA927` | `03c` |
| `PeanutV4` (spawned `CREATE` nonce 1) | `0x334c0c981fbBFff5D93A26F7429a86d97F03778e` | `03c` |
| `PayrollBatch` | `0x0eD7f2a1edb378fB8407c1B7E187fd1b5daC25Cf` | `03c` |

### 5.3 Base Mainnet (`8453`)

**Important prerequisite.** Safe `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09` is not deployed on Base `8453` yet (`eth_getCode == 0x`). Choose one path:

- **Path A (deploy contracts now, accept Safe ownership later).** Execute the four Arachnid CREATE2 calls in `04a-base-8453-vnext-cctp-forwarder-and-claim-vault.json` via `MultiSendCallOnly` (`0x9641d764fc13c8B624c04430C7356C1C7C8102e2`) or an EOA deployer, matching the Nov 7 Base procedure. `PeanutV4` spawns with `pendingOwner = 0x47Dc7D18A6E3a79F696714E7D47456a49B430D09`. Once the Safe is deployed at `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09` on Base, drop `04b-base-8453-vnext-claim-vault-accept-ownership.json` into that Safe to complete `Ownable2Step`.
- **Path B (deploy Base Safe first).** Deploy Safe `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09` on Base `8453`, then drop `04a` followed by `04b` into Safe Transaction Builder.

#### Base Mainnet (`8453`) Checklist

- [ ] Execute `04a-base-8453-vnext-cctp-forwarder-and-claim-vault.json` (4 txs, ~8.85M gas).
- [ ] Once Base Safe `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09` exists on chain `8453`, drop and execute `04b-base-8453-vnext-claim-vault-accept-ownership.json` (1 tx, ~36k gas).

#### Predicted Base Mainnet (`8453`) vNext Addresses

| Contract | Predicted Address | Batch |
| --- | --- | --- |
| `CctpDepositForwarder` (impl) | `0xDe831fe5175D9aBeF63516ff7EA4f02c81223221` | `04a` |
| `CctpDepositForwarderFactory` | `0x15d3A8C8Cd938D57D211BaFf2987FacA3B81fd1C` | `04a` |
| `ClaimVaultDeployer` | `0xA8376Fe8Ef5a6640e39f047c751d7740C10f2cEA` | `04a` |
| `PeanutV4` (spawned `CREATE` nonce 1) | `0x75EbdB0065729849bb1A8807718B753374AD2Ca1` | `04a` / `04b` |
| `PayrollBatch` | `0x7DFBb79878a70d1981D0DF76c8262fDddd883FEc` | `04a` |

## 6. Phase 3: Off-Chain `desk-v1` Cutover Checklist

Flip `desk-v1` to the vNext addresses only after shipping the four breaking ABI and calldata updates below in the same release PR.

### 6.1 Breaking Contract Behavior Changes in `desk-v1`

1. **`PayrollBatch` binds `address from` in `payrollHash` and `witnessOf` (`5.2.14`) plus `cancelPayroll`.**
   - `packages/services/src/payroll-batch-witness.ts` lines `72-110`: add `treasury: Address` parameter to `payrollBatchHash` and `payrollBatchWitness`, encoding `(chainId, payrollBatch, from, payrollId, payouts, claims)`.
   - `apps/shiva/src/services/treasury-payroll-permit2.service.ts` lines `129` and `335-341`: update `PAYROLL_BATCH_ABI` `witnessOf(address,bytes32,(address,address,uint256)[],(address,address,uint256)[])`, add `cancelPayroll` / `cancelPayrollDigest` / `PayrollCancelled` entries, and pass `input.treasury` into `payrollBatchHash`.
   - `packages/services/src/disbursement-run.ts` lines `266-272`: pass `treasury` into `payrollBatchHash`.
   - Update pinned witness test vectors in `apps/shiva/src/services/treasury-payroll-permit2.service.test.ts` (lines `12-13`, `85-133`, `897-964`) and `packages/services/src/disbursement-run.test.ts` (lines `173-185`).

2. **`TreasuryConduit` requires `tokenOut` delivery to `address(conduit)` (`5.1.13`).**
   - `apps/shiva/src/controllers/treasury-conduit.controller.ts`:
     - Line `284` (`openTreasuryConduitSwap`): already passes `walletAddress: input.conduit`. Verify all swap venues deliver `tokenOut` to the conduit.
     - Lines `867-871` (`openTreasuryConduitEarnDeposit`): change `ERC4626.deposit(amount, account)` receiver from `account` to `onchainConduit`. The conduit measures its own share balance delta and forwards shares to `account`.
     - Lines `1021-1030` (`openTreasuryConduitEarnSwapDeposit`): change `encodeTreasurySwapDepositRun({ ..., beneficiary: account, ... })` beneficiary from `account` to `onchainConduit`.
     - Lines `1191-1197` (`openTreasuryConduitEarnAaveSupply`): change `encodeAaveV3Supply({ ..., onBehalfOf: account })` and `assertPositionMintsTo` to `onchainConduit` before enabling Aave supply on vNext conduits.
   - `packages/wallets/src/treasury-conduit-intent.ts` lines `31-38` and `132-156`: add `tokens(address) view returns (bool)` to `TREASURY_CONDUIT_ABI` for optional pre-flight allowlist checks.

3. **Bridge conduits enforce ERC-3009 `tokens(address)` allowlist (`5.2.1`) and exact CCTPx `msg.value == quoteTotal` (`5.2.7`).**
   - `apps/shiva/src/services/treasury-bridge-conduit-onchain.service.ts` lines `16-24` and `packages/wallets/src/treasury-bridge-intent.ts`: ensure relayer sends exact `msg.value = quoteTotal` (`<= intent.maxFee`) on CCTPx calls (live Circle `FeeManager` reverts `IncorrectNativePayment` on any mismatch) and never routes `0x3600...` over CCTPx.

4. **`PeanutV4.acceptMFAAuthorizer(bytes)` requires an ECDSA key proof (`5.2.20`).**
   - No runtime caller in `desk-v1` calls `acceptMFAAuthorizer`. Update internal key-rotation scripts to read `mfaAcceptanceDigest(newAuthorizer)` from `PeanutV4`, sign with `newAuthorizer`, and submit `acceptMFAAuthorizer(signature)`. Regenerated ABI lives at [`packages/claim-vault/abi/bufi-PeanutV4.4.abi.json`](packages/claim-vault/abi/bufi-PeanutV4.4.abi.json).

### 6.2 `desk-v1` Address Registry Files to Flip to vNext

- `packages/env/src/conduit.ts` (lines `29`, `41-44`, `82-83`, `109-143`, `151-154`): update `TreasuryConduit` (v2/v3), `TreasuryConduitPermit2`, and `TreasurySwapAndDeposit` for `5042002`, `5042`, `43114`. Keep `TreasuryRedeemConduit` unchanged.
- `packages/env/src/bridge-conduit.ts` (lines `88`, `284-288`): update `TreasuryBridgeConduitV2`, `TreasuryBridgeConduit` (v3), and `TreasuryBridgeConduitPermit2` for `5042002`, `5042`, `43114`.
- `packages/env/src/payroll-batch.ts` (lines `65-85`, `98-115`, `152-156`): update `PAYROLL_BATCH_ADDRESSES` and `CLAIM_VAULT_ADDRESSES` (`PeanutV4`) across `5042002`, `5042`, `43114`, `8453`. Keep `CLAIM_VAULT_MFA_AUTHORIZERS` at `0x9c8515333aFdB567C31CDF53CD60868f3B64b724`.
- `packages/env/src/cctp-deposit-forwarder.ts` (lines `66-79`, `215`): update `CctpDepositForwarder` implementation (`0xDe831fe5175D9aBeF63516ff7EA4f02c81223221`) and per-chain `CctpDepositForwarderFactory` addresses across `5042002`, `5042`, `43114`, `8453`.
- `packages/env/src/recibu-hub.ts` (lines `47-63`): update `BUFIReputationRegistry`, `WorkspaceTierRegistry`, `WorkspaceOperatingReserve`, `InvoiceShelf`, `BINV`, `bIF-A/B/C`, and `MultiTokenReceivableEscrow` on `5042`. Keep `BUFIIdentityRegistry` (`0x6730b8f3FF0eF85E097Af01eC8a3e450d30e466d`).
- `packages/env/src/recibu.ts`: update `RECIBU_MEMO_ROUTER_ADDRESSES` env JSON to `0xB9eA41D9a9a9BF2F81a4FC9d22994226F4645b52` on `5042`.
- `packages/env/src/tokens.ts` (line `70`): confirm Arc Mainnet EURC is `0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1` (already matches).
- `contracts/deployments.json` and `contracts/DEPLOYMENTS.md`: append post-execution receipts and block numbers once all Safe batches confirm.

## 7. Phase 4: Post-Deploy Verification Commands

### 7.1 Local and Live-Fork Re-Verification in `spooky-contracts`

```bash
# Offline verification of all 14 Safe Transaction Builder JSON batches
forge test --profile vnext-safe-verify -vv

# Live Arc Mainnet (5042) fork verification (hotfix 5.2.2 + batches 02a-02e + live CCTPx FeeManager)
ARC_MAINNET_FORK=1 ARC_MAINNET_RPC_URL="$ARC_MAINNET_RPC_URL" \
  forge test --profile vnext-safe-verify -vv
```

### 7.2 Live On-Chain State Checks After Safe Execution

Run each block after its chain batches confirm.

```bash
# Arc Testnet (5042002)
RPC="$ARC_TESTNET_RPC_URL"
cast call --rpc-url "$RPC" 0xe7E3592A5c911C094c401743E5727122579AF153 "tokens(address)(bool)" 0x3600000000000000000000000000000000000000
cast call --rpc-url "$RPC" 0x5891A451F60C36d74367b047D385E360D70f3242 "cctpxTokens(bytes32)(address)" 0x2587821a0ee7daa174b95436b5dab1731cfa1844775b010217d3c0dd02a4eecd
cast call --rpc-url "$RPC" 0x334c0c981fbBFff5D93A26F7429a86d97F03778e "owner()(address)"
cast call --rpc-url "$RPC" 0x0eD7f2a1edb378fB8407c1B7E187fd1b5daC25Cf "VAULT()(address)"
cast call --rpc-url "$RPC" 0x0d89a614F7Ec3A2452fDf9C39eEb01F69a926c98 "implementation()(address)"

# Arc Mainnet (5042)
RPC="$ARC_MAINNET_RPC_URL"
OPS_ROLE=$(cast keccak "OPS_ROLE")
SETTLEMENT_ROLE=$(cast keccak "SETTLEMENT_ROLE")
cast call --rpc-url "$RPC" 0x5dD2e0112B10681e799155676486E1D8aD8c77d7 "tokens(address)(bool)" 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1
cast call --rpc-url "$RPC" 0xfdC52570590dD8F9801cF501CffFC17C29D7f77e "cctpxTokens(bytes32)(address)" 0x6ca9e29fa53becc29becaf4a90b9ca7a995ad4d2234880da13ca38c657fb241c
cast call --rpc-url "$RPC" 0x3627cFFF52a1a895Dc2198971B10D3d64d312215 "hasRole(bytes32,address)(bool)" "$OPS_ROLE" 0xD2FaA2B5044819fda138c7D3B0cfAF3b06E60E8C
cast call --rpc-url "$RPC" 0x3627cFFF52a1a895Dc2198971B10D3d64d312215 "hasRole(bytes32,address)(bool)" "$SETTLEMENT_ROLE" 0xD2FaA2B5044819fda138c7D3B0cfAF3b06E60E8C
cast call --rpc-url "$RPC" 0xD2FaA2B5044819fda138c7D3B0cfAF3b06E60E8C "escrow()(address)"
cast call --rpc-url "$RPC" 0xB9eA41D9a9a9BF2F81a4FC9d22994226F4645b52 "tokenConfig(address)(bool,uint8)" 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1
cast call --rpc-url "$RPC" 0x75EbdB0065729849bb1A8807718B753374AD2Ca1 "owner()(address)"
cast call --rpc-url "$RPC" 0x7DFBb79878a70d1981D0DF76c8262fDddd883FEc "VAULT()(address)"
cast call --rpc-url "$RPC" 0x4C3D9249C8FEE9d35B045B09b97fc99CE6CEB8E5 "implementation()(address)"

# Avalanche C-Chain (43114)
RPC="https://api.avax.network/ext/bc/C/rpc"
cast call --rpc-url "$RPC" 0xe7E3592A5c911C094c401743E5727122579AF153 "tokens(address)(bool)" 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E
cast call --rpc-url "$RPC" 0x5891A451F60C36d74367b047D385E360D70f3242 "cctpxTokens(bytes32)(address)" 0x6ca9e29fa53becc29becaf4a90b9ca7a995ad4d2234880da13ca38c657fb241c
cast call --rpc-url "$RPC" 0x334c0c981fbBFff5D93A26F7429a86d97F03778e "owner()(address)"
cast call --rpc-url "$RPC" 0x1E4B7346FbBadAd0b63e7b424f36A6A4C3690354 "usdc()(address)"

# Base Mainnet (8453)
RPC="https://mainnet.base.org"
cast call --rpc-url "$RPC" 0x15d3A8C8Cd938D57D211BaFf2987FacA3B81fd1C "usdc()(address)"
cast call --rpc-url "$RPC" 0x75EbdB0065729849bb1A8807718B753374AD2Ca1 "owner()(address)"
cast call --rpc-url "$RPC" 0x75EbdB0065729849bb1A8807718B753374AD2Ca1 "pendingOwner()(address)"
cast call --rpc-url "$RPC" 0x7DFBb79878a70d1981D0DF76c8262fDddd883FEc "VAULT()(address)"
```

### 7.3 Block Explorer Source Verification Templates

Every contract uses canonical `solc` settings from `foundry.toml`. Replace `<CHAIN_ID>`, `<ADDRESS>`, `<CONTRACT_PATH>`, and `<CONSTRUCTOR_ARGS>` per contract:

```bash
# Treasury conduits v2 (default) and v3 (treasury-v3): solc 0.8.24, paris, via-ir, 200 runs
forge verify-contract --profile treasury-v3 --chain-id <CHAIN_ID> \
  --compiler-version 0.8.24 --evm-version paris --via-ir --num-of-optimizations 200 \
  --constructor-args <CONSTRUCTOR_ARGS> <ADDRESS> <CONTRACT_PATH>

# FX-Recibu hub (fx-hub) and CCTP forwarder (fx-cctp-forwarder): solc 0.8.26, cancun, via-ir, 200 runs
forge verify-contract --profile fx-hub --chain-id <CHAIN_ID> \
  --compiler-version 0.8.26 --evm-version cancun --via-ir --num-of-optimizations 200 \
  --constructor-args <CONSTRUCTOR_ARGS> <ADDRESS> <CONTRACT_PATH>

# ClaimVault (PeanutV4.4) and PayrollBatch (claim-vault): solc 0.8.23, paris, 99999 runs (no via-ir)
forge verify-contract --profile claim-vault --chain-id <CHAIN_ID> \
  --compiler-version 0.8.23 --evm-version paris --num-of-optimizations 99999 \
  --constructor-args <CONSTRUCTOR_ARGS> <ADDRESS> <CONTRACT_PATH>
```
