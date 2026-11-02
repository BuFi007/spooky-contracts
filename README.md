# spooky-contracts

Solar-first Foundry monorepo of BUFI production contracts, assembled for an Olympix audit. One branch, one pull request into `main`. Nothing here is a new deployment.

The private source repositories (`BUFI-6900`, `desk-v1`, `fx-recibu`) were not readable with the credential available for this import (GitHub returns 404). Git history was not preserved with subtree. Each package README names the branch and commit that should have been imported. The Solidity that is present is the Sourcify-verified compiler input for each mainnet address, checked back against `eth_getCode`.

## Package map

| Package | What it is | Foundry profile |
| --- | --- | --- |
| `packages/treasury-conduits` | TreasuryConduit, TreasuryConduitPermit2, TreasuryBridgeConduitV2, TreasuryRedeemConduit | `default` (solc 0.8.24, paris) |
| `packages/fx-recibu/hub` | Arc factoring hub, including MultiTokenReceivableEscrow and RecibuMemoRouter | `fx-hub` (solc 0.8.26, cancun) |
| `packages/fx-recibu/spoke-cctp` | SpokeMemoConduit and the CCTP MemoConduit parent | `fx-spoke` |
| `packages/fx-recibu/memo-v1` | v1 MemoConduit, live on Arc and Avalanche | `fx-memo-v1` |
| `packages/fx-recibu/stablefx` | RecibuSettlementGuardHook, IV4Types, IInvoiceShelf. Undeployed. From fx-recibu `7330e6c` | `fx-stablefx` (solc 0.8.26, cancun) |
| `packages/claim-vault` | PeanutV4.4 BUFI fork and PayrollBatch. From desk-v1 `c22110966e` | `claim-vault` (solc 0.8.23, paris, optimizer 99999) |

Treasury, fx-recibu, and claim-vault each vendor their own OpenZeppelin snapshot under `lib/`. The files are not interchangeable. A single `@openzeppelin/contracts/` remapping would change mainnet bytecode. Treasury and fx-recibu copies come from the verified compiler inputs. claim-vault pins OpenZeppelin v4.9.2 `e50c24f5839db17f46991478384bfda14acfb830` (Peanut v4.4's submodule) and forge-std v1.15.0 `0844d7e1fc5e60d77b68e469bff60265f236c398`. `packages/claim-vault/upstream/` stays outside the compile set.

## Deployed addresses

Chain 5042 is Arc mainnet. Chain 43114 is Avalanche C-Chain. `exact` means compiler runtime bytecode equals `eth_getCode`. `immutables` means equality after the on-chain immutable slots are copied into the compiler template. Full hashes are in `deployments/bytecode-hashes.json`. Machine-readable addresses are in `deployments/addresses.json`.

| Contract | Arc 5042 | Avalanche 43114 | Match |
| --- | --- | --- | --- |
| TreasuryConduit | [`0xa9817049f0a48d4653719465a7829e85b3a415e7`](https://explorer.arc.io/address/0xa9817049f0a48d4653719465a7829e85b3a415e7) | [`0x49c89b198321ed0782a4f9a44de2b237ebd77cf0`](https://snowtrace.io/address/0x49c89b198321ed0782a4f9a44de2b237ebd77cf0) | exact |
| TreasuryConduitPermit2 | [`0xb63da0934e2a89169f89eed0679c35cc4d5959a5`](https://explorer.arc.io/address/0xb63da0934e2a89169f89eed0679c35cc4d5959a5) | [`0xaebb9c395ab6d627eb0defc3b16e7f49dc30c19f`](https://snowtrace.io/address/0xaebb9c395ab6d627eb0defc3b16e7f49dc30c19f) | immutables |
| TreasuryBridgeConduitV2 | [`0x41422093ef6d03fbd3c0a2e3a6a6f69b1cad4409`](https://explorer.arc.io/address/0x41422093ef6d03fbd3c0a2e3a6a6f69b1cad4409) | same address | exact |
| TreasuryRedeemConduit | [`0x361340f0b3a8ec00067ea3c024ae6919a2a0d06a`](https://explorer.arc.io/address/0x361340f0b3a8ec00067ea3c024ae6919a2a0d06a) | — | immutables |
| InvoiceShelf | [`0x8d3006f7be5b5e6e5b7709889a2e5d9ee4d3cd0a`](https://explorer.arc.io/address/0x8d3006f7be5b5e6e5b7709889a2e5d9ee4d3cd0a) | — | immutables |
| WorkspaceTierRegistry | [`0xfe06281b464d53f00cceca504114263c689e56fe`](https://explorer.arc.io/address/0xfe06281b464d53f00cceca504114263c689e56fe) | — | immutables |
| MultiTokenReceivableEscrow | [`0xbb4b6bbdaeb3136571d33742385a1ae59cee57ab`](https://explorer.arc.io/address/0xbb4b6bbdaeb3136571d33742385a1ae59cee57ab) | — | exact |
| RecibuMemoRouter | [`0x208fbdf4268c87c475189d9ecd7d59b4766e75cb`](https://explorer.arc.io/address/0x208fbdf4268c87c475189d9ecd7d59b4766e75cb) | — | immutables |
| SpokeMemoConduit | — | [`0x7b5b1425bb621b014b7257a0d0caf88c453e33c8`](https://snowtrace.io/address/0x7b5b1425bb621b014b7257a0d0caf88c453e33c8) | immutables |
| MemoConduit v1 | [`0x516340a244132c62bedae5f886fd35845af16ba2`](https://explorer.arc.io/address/0x516340a244132c62bedae5f886fd35845af16ba2) | [`0x536268d0a6c32a7161ba146f5673dfcf13f1ffe2`](https://snowtrace.io/address/0x536268d0a6c32a7161ba146f5673dfcf13f1ffe2) | immutables |

Arc factoring admin Safe: [`0x47Dc7D18A6E3a79F696714E7D47456a49B430D09`](https://explorer.arc.io/address/0x47Dc7D18A6E3a79F696714E7D47456a49B430D09). Avalanche Permit2 and Bridge owner Safe: [`0xa3a40fa2d82c0224c40b1ed7e07cb474b7d1468b`](https://snowtrace.io/address/0xa3a40fa2d82c0224c40b1ed7e07cb474b7d1468b). Safe implementations are not in the audit scope.

Out of scope and not imported: gateway-guard, GatewayTreasury, v0.7 session and recipient hooks, TreasuryEarnVault, BUFI identity and reputation registry implementations, BUFIOracle, InvoiceMemoRouter, InvoiceSettlement, the old ReceivableEscrow, BUAttestation, KybWorkspacePolicy, CRE extractors, and the named out-of-scope products (ens, escrow, recibo, fx-telarana, fx-sobre, fx-recibu-loans, fantasmita-ars, fantasmita-passport, kawaii-raindrops, stablecoin-curve-punk-nft, BDACS/KRW1).

`RecibuSettlementGuardHook` is in the audit set and has no mainnet deployment. `GuardHook.t.sol` is in `packages/fx-recibu/stablefx/test-pending/` and is not compiled. SwapDeposit and a planned treasury v3 are still absent. `test_nested_selfAsOwner_refusedAtConstruction` is not in the claim-vault suite.

Notice pull requests on the private repos are handled separately.

## Build and test

Foundry 1.9.0. From the repository root:

```bash
./script/build-all.sh
./script/test-all.sh
./script/build-all.sh --use solar
./script/test-all.sh --use solar
```

Profiles are `default`, `fx-hub`, `fx-spoke`, `fx-memo-v1`, `fx-stablefx`, and `claim-vault`. The smoke tests deploy TreasuryConduit, TreasuryBridgeConduitV2, TreasuryRedeemConduit, and MultiTokenReceivableEscrow. Spoke, v1 MemoConduit, and stablefx compile; stablefx has no compiled tests. claim-vault runs 109 tests under solc 0.8.23 and under Solar, with 9 fork tests skipped unless `ARC_FORK` or `ARC_MAINNET_FORK` is set. Fuzz runs are 1024.

Bytecode check, online against the public RPCs, then offline against the recorded hashes:

```bash
python3 script/verify_bytecode.py
python3 script/verify_bytecode.py --offline
```

The online check needs solc 0.8.24+commit.e11b9ed9 and solc 0.8.26+commit.8a97fa7a (`SOLC_024` and `SOLC_026`). CI runs the offline check.

## Solar

`forge build --use solar` is the default compiler path for development and CI, alongside a solc cross-check. Solar 0.3.0 emits different bytecode from solc. CREATE2 addresses computed from Solar init code will not match the deployments. Reproduce mainnet runtime code with solc and `script/verify_bytecode.py`.

`forge build` from this repository root also names source units under `packages/`. That changes the metadata suffix relative to the original compiler input, whose source units are `src/...` and `lib/...`. The bytecode script replays that original standard-json, including the remapping list stored in the metadata. A shorter remapping list changes the IPFS hash appended to the runtime code even when the opcodes are unchanged.
