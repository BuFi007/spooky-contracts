# fx-recibu

Arc factoring hub, the CCTP spoke, and v1 MemoConduit. First-party sources are Apache-2.0. Compiler: solc 0.8.26, optimizer 200 runs, viaIR, evm version cancun, metadata bytecode hash ipfs.

The live mainnet sources are not what `fx-recibu` `main` contains. This package vendors the Sourcify-verified compiler inputs. The private `BuFi007/fx-recibu` git tree was not readable from this environment, so those commits were not subtree-imported. The deployments correspond to:

- Hub, including `MultiTokenReceivableEscrow` and `RecibuMemoRouter`: branch `feat/recibu-memo-router-mainnet`, commit `1525532`.
- `SpokeMemoConduit` `0x7b5b1425bb621b014b7257a0d0caf88c453e33c8` and its CCTP `MemoConduit` parent: branch `feat/memo-conduit-cctp-mainnet`, commit `8aab86a`.
- v1 `MemoConduit`, kept as deployed: Arc `0x516340a244132c62bedae5f886fd35845af16ba2` and Avalanche `0x536268d0a6c32a7161ba146f5673dfcf13f1ffe2`.

v1 `MemoConduit.sol` and the CCTP parent are different contracts (about 6 KB and about 30 KB). `IERC3009.sol` also differs between the hub and the spoke. They live in separate trees:

- `hub/` — InvoiceShelf and the contracts it compiles with, plus `MultiTokenReceivableEscrow`, `RecibuMemoRouter`, `BUFIIdentityRegistry`, and `BUFIReputationRegistry`.
- `spoke-cctp/` — SpokeMemoConduit, CCTP MemoConduit, MemoConduitCctpConfig.
- `memo-v1/` — the non-CCTP MemoConduit.
- `stablefx/` — `RecibuSettlementGuardHook`, its `fx-recibu@7330e6c` support tree, and `test/unit/GuardHook.t.sol`.
- `cctp-forwarder/` — `CctpDepositForwarder` and `CctpDepositForwarderFactory` from `BuFi007/fx-recibu` branch `feat/cctp-deposit-forwarder` (PR #10), verified on Base Sepolia (`84532`).
- `doc-registry/` — `DocumentReceivableRegistry` from `BuFi007/fx-recibu` branch `feat/document-receivable-registry` (PR #9).

`lib/openzeppelin-contracts/` is shared by the three trees. It is the 0.8.26-era snapshot from the verifications, and it is not the treasury snapshot.

The hub admin Safe on Arc mainnet is `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09`. It holds `DEFAULT_ADMIN_ROLE` on `MultiTokenReceivableEscrow`.

## Not imported

Testnet-only contracts were left out: BUFIOracle, InvoiceMemoRouter, InvoiceSettlement, the old ReceivableEscrow, BUAttestation, and KybWorkspacePolicy. CRE extractors removed in fx-recibu PR #12 are not here.

`stablefx/` holds `RecibuSettlementGuardHook`, `IV4Types`, `IInvoiceShelf`, and the `fx-recibu` `main` `7330e6c` support contracts and test (`test/unit/GuardHook.t.sol`). The hook is in scope and undeployed. Foundry profile `fx-stablefx` compiles and tests it with solc 0.8.26, cancun, viaIR, optimizer 200, and with Solar.

Comments inside `InvoiceShelf` still name Fantasmita, InvoiceMemoRouter, InvoiceSettlement, and BUFIOracle. Those comments are part of the deployed source and were not edited.

## Deployed addresses

| Contract | Chain | Address | Bytecode |
| --- | --- | --- | --- |
| InvoiceShelf | Arc 5042 | [`0x8d3006f7be5b5e6e5b7709889a2e5d9ee4d3cd0a`](https://explorer.arc.io/address/0x8d3006f7be5b5e6e5b7709889a2e5d9ee4d3cd0a) | immutables |
| WorkspaceTierRegistry | Arc 5042 | [`0xfe06281b464d53f00cceca504114263c689e56fe`](https://explorer.arc.io/address/0xfe06281b464d53f00cceca504114263c689e56fe) | immutables |
| MultiTokenReceivableEscrow | Arc 5042 | [`0xbb4b6bbdaeb3136571d33742385a1ae59cee57ab`](https://explorer.arc.io/address/0xbb4b6bbdaeb3136571d33742385a1ae59cee57ab) | exact |
| RecibuMemoRouter | Arc 5042 | [`0x208fbdf4268c87c475189d9ecd7d59b4766e75cb`](https://explorer.arc.io/address/0x208fbdf4268c87c475189d9ecd7d59b4766e75cb) | immutables |
| BUFIIdentityRegistry | Arc 5042 | [`0xe3d6de22135bbd463c0a97a5196782cbcc3f3322`](https://explorer.arc.io/address/0xe3d6de22135bbd463c0a97a5196782cbcc3f3322) | exact |
| BUFIReputationRegistry | Arc 5042 | [`0x30015db351747e39102da3f65f51ce0207052415`](https://explorer.arc.io/address/0x30015db351747e39102da3f65f51ce0207052415) | immutables |
| SpokeMemoConduit | Avalanche 43114 | [`0x7b5b1425bb621b014b7257a0d0caf88c453e33c8`](https://snowtrace.io/address/0x7b5b1425bb621b014b7257a0d0caf88c453e33c8) | immutables |
| MemoConduit v1 | Avalanche 43114 | [`0x536268d0a6c32a7161ba146f5673dfcf13f1ffe2`](https://snowtrace.io/address/0x536268d0a6c32a7161ba146f5673dfcf13f1ffe2) | immutables |
| MemoConduit v1 | Arc 5042 | [`0x516340a244132c62bedae5f886fd35845af16ba2`](https://explorer.arc.io/address/0x516340a244132c62bedae5f886fd35845af16ba2) | immutables |
| CctpDepositForwarder | Base Sepolia 84532 | `0x23CCCf9e090937DF0F97f166DBF7302A94A653Ea` | exact (Sourcify) |
| CctpDepositForwarderFactory | Base Sepolia 84532 | `0x4035b61123367428ECFd8D4f6FD2bd74e00038ec` | exact (Sourcify) |

`BINV`, `BIFTranche`, `WorkspaceOperatingReserve`, `Params`, `ReceivableCommitment`, and `FactoringEvidenceV1` are in the hub compile because `InvoiceShelf` imports them. The bytecode check covers the contracts that were found as their own mainnet deployments.

Foundry profiles, from the repository root: `fx-hub`, `fx-spoke`, `fx-memo-v1`, `fx-stablefx`, `fx-cctp-forwarder`, `fx-doc-registry`.
