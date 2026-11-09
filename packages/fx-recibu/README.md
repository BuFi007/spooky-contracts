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

## Deployed addresses (`spooky-contracts-prod-20261106`)

| Contract | Arc Mainnet (`5042`) | Avalanche C-Chain (`43114`) | Arc Testnet (`5042002`) | Base Mainnet (`8453`) |
| --- | --- | --- | --- | --- |
| `BUFIIdentityRegistry` | `0x6730b8f3FF0eF85E097Af01eC8a3e450d30e466d` | — | `0x7c8E88d157d10F3fEEbBE7e83aEE5D34284eA646` | — |
| `BUFIReputationRegistry` | `0x2D7125b1cf826bE4ad6D0b043F6B4675897EB2e9` | — | `0x05845d05212650C50f823A0a98D0B96fA937e582` | — |
| `WorkspaceTierRegistry` | `0x9a3029Be2323695647A24DD2aB6014887E04A4C7` | — | `0xbAAADc50b9E4f8831807D0B5aF43B21061731572` | — |
| `WorkspaceOperatingReserve` | `0x9075121f006CC0646bf1799993AC29B4aBF096f4` | — | `0x04aD093691f79F3859dD5fb3e08fD92EB1a2F5D4` | — |
| `InvoiceShelf` | `0x90eCDd402C0E357362b7805173191A153b876DF4` | — | `0xa954C9D612155A2e7d06b575B8A559fA340c02bE` | — |
| `BINV` | `0xd692453558A92C712b74cFad13C0b769F4AC3037` | — | `0xbc0E603A3c5267aF35a2EebA2a0bC4278eD0B5f1` | — |
| `BIFTranche` (`bIF-A` / `bIF-B` / `bIF-C`) | `0xE295…aA8e` / `0xbA43…773c` / `0x0621…07f5` | — | `0x9C1a…4D47` / `0x3293…c743` / `0x348D…42bc` | — |
| `MultiTokenReceivableEscrow` | `0x4772d02a36cfBfF5c139C8d3b5F2DACc82FFAE96` | — | `0x9eD55A70580B1C34F1f0206bd0A9559D53e0cEB1` | — |
| `RecibuMemoRouter` | `0x652D1eD9c519bf7582bFE55AEB504De3f48B7545` | — | `0x53d72094B1b15578f24d778e0F89aB1e8f98a6fA` | — |
| `SpokeMemoConduit` | — | `0x273B51467f3e84eda3B443a2Ee81cafD4622f775` | `0x3170d693B50B420e61A20737c66F7166B9f4bF0d` | — |
| `MemoConduit` (CCTP) | `0x0f531Cf6E1F54585Db080d51c9a0B32C9b89a684` | `0x52Dd9c372C6ea4afB29747f49436F628A1f21E32` | `0xf31E0557505deb66B31571591cAacAbcD7D6AD71` | — |
| `MemoConduit` v1 | `0x5730E6E727B6e476bf243dFeab64A8E7dCC00009` | `0x7c8E88d157d10F3fEEbBE7e83aEE5D34284eA646` | `0x6a099C8A2838219337313d15D5D736F50F900f29` | — |
| `DocumentReceivableRegistry` | `0x7B5a94C59313371BDD3CffA8c165D7fb1C31423C` | — | `0x4955cb7B853860a40F075957C30513257210EDB3` | — |
| `CctpDepositForwarder` (impl) | `0x1612F9A755e833Daf626BFD6952deCE9a76BAf4C` | `0x1612F9A755e833Daf626BFD6952deCE9a76BAf4C` | `0x1612F9A755e833Daf626BFD6952deCE9a76BAf4C` | `0x1612F9A755e833Daf626BFD6952deCE9a76BAf4C` |
| `CctpDepositForwarderFactory` | `0x4de4E8c8a15809264Db7AA4DcE0746b2d405edfC` | `0x47Be2882B335Eba84C3908a2f01705cb09d296CA` | `0xEcbe7DC7db6fD6193F83C0B38ccd420e327a56aD` | `0xf56Fe0bA9B9D951035f3422bb11D030D0c557AdF` |

Full addresses and Safe execution receipts are recorded in [`../../deployments/addresses.json`](../../deployments/addresses.json).

Foundry profiles, from the repository root: `fx-hub`, `fx-spoke`, `fx-memo-v1`, `fx-stablefx`, `fx-cctp-forwarder`, `fx-doc-registry`.
