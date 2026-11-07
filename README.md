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

### Post-Remediation Live Deployments (`F-01`..`F-30`, 2026-11-07)

All 57 remediated contract instances (`F-01` through `F-30`) are deployed deterministically via Arachnid CREATE2 (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) across Arc Mainnet (`5042`), Avalanche C-Chain (`43114`), Arc Testnet (`5042002`), and Base Mainnet (`8453`). Full addresses, bytecode hashes, and Safe execution receipts are recorded in `deployments/addresses.json`, `deployments/live-receipts-2026-11-07.json`, and `deployments/safe-tx-builder/MANIFEST.json`.

| Chain | Safe / Target | Step | Transaction Hash | Block | Contracts Deployed & Wired |
| --- | --- | --- | --- | --- | --- |
| Arc Mainnet (`5042`) | `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09` | `arc-5042-1a` | `0xa19e419530ce10bfd989019ce2ddb1109abd08525553ab6561322c6b81742e2c` | `29967604` | `TreasuryConduit` (`0x6B33A6E3078F961892eC2A27797F2Bd1efF07327`), `TreasuryConduitPermit2` (`0xE7b973C68678888eD4824154529362AcFaC10278`), `TreasuryBridgeConduitV2` (`0x3552726aacf5A2761991a270CdE2dba9dc2f5FCc`), `TreasuryRedeemConduit` (`0x5f47FEEE01B89D8B1A1FAb4e8A52B0C4C2b7EeAa`), `TreasuryConduitV3` (`0xe11FD30ff39997F20bEAac2aDAB3f5Ae2Ca24484`) + 24 allowlists |
| Arc Mainnet (`5042`) | `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09` | `arc-5042-1b` | `0x247a56c6426550954bc08cca4e605e9d4a22e9c0d24f9ef3ed6d12d0ce6c239d` | `29967627` | `TreasuryBridgeConduit` (`0x582CB729D16b97868A4670Db921aa33A13c148f8`), `TreasuryBridgeConduitPermit2` (`0x936F8a287363B03e29e2c089a57672A47D686A33`), `TreasuryRedeemConduitV3` (`0x78DCE8E25B092E5956d7DF4314AAa8d0b6bF60e5`), `TreasurySwapAndDeposit` (`0x8Ae5ed45E5E365eEfF1d93c70433ddC642C5E10B`) + 14 allowlists |
| Arc Mainnet (`5042`) | `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09` | `arc-5042-2a` | `0x9b01a9b2357f1ddfe53dc55a43d4eb27a1a0a6b737345b78da800b4d6aa11bf0` | `29967640` | `BUFIIdentityRegistry` (`0x6730b8f3FF0eF85E097Af01eC8a3e450d30e466d`), `BUFIReputationRegistry` (`0x2D7125b1cf826bE4ad6D0b043F6B4675897EB2e9`), `WorkspaceTierRegistry` (`0x9a3029Be2323695647A24DD2aB6014887E04A4C7`), `WorkspaceOperatingReserve` (`0x9075121f006CC0646bf1799993AC29B4aBF096f4`), `InvoiceShelf` (`0x90eCDd402C0E357362b7805173191A153b876DF4`), `BINV` (`0xd692453558A92C712b74cFad13C0b769F4AC3037`), `BIFTrancheSenior_bIF_A` (`0xE29590E4A240CEDc5438531f3A4284309064aA8e`), `BIFTrancheMezzanine_bIF_B` (`0xbA4368e30E83D5087E1257f7Db08918691dF773c`), `BIFTrancheJunior_bIF_C` (`0x06215695D37CB9a43aa9B2bb3057fcf5fcb507f5`) |
| Arc Mainnet (`5042`) | `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09` | `arc-5042-2b` | `0x1e4895accadb23103797620a1d67930b0dd12c665cfc51c0ddcadb28de9243a2` | `29967656` | `MultiTokenReceivableEscrow` (`0x4772d02a36cfBfF5c139C8d3b5F2DACc82FFAE96`), `RecibuMemoRouter` (`0x652D1eD9c519bf7582bFE55AEB504De3f48B7545`), `MemoConduit` (`0x0f531Cf6E1F54585Db080d51c9a0B32C9b89a684`), `MemoConduitV1` (`0x5730E6E727B6e476bf243dFeab64A8E7dCC00009`), `DocumentReceivableRegistry` (`0x7B5a94C59313371BDD3CffA8c165D7fb1C31423C`), `CctpDepositForwarderImplementation` (`0x1612F9A755e833Daf626BFD6952deCE9a76BAf4C`), `CctpDepositForwarderFactory` (`0x4de4E8c8a15809264Db7AA4DcE0746b2d405edfC`) |
| Arc Mainnet (`5042`) | `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09` | `arc-5042-3` | `0xc04d9e7943a2031e0343e3ad81584190921be4f3d9d13c38a98c57796e4dd199` | `29967672` | `ClaimVaultDeployer` (`0xE57695e4CE920eB24d80697c3369aE80fa275E6a`), `PeanutV4` (`0xeA06BF5AD08b70E4c107f3925CBC618662f88965`), `PayrollBatch` (`0xE9b96103Ddc1268F1184667F4c3E85Da75340E10`), `AgentGatewayAccountFactory` (`0xC4c3886A7f66E49fF95d7A15a12958b4cBa0eA3C`) |
| Avalanche C-Chain (`43114`) | `0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B` | `avax-43114-1a` | `0x1a12b3bbee99e0d9096ca5d839ba1dc3e504c88eba3579f68048ab16608df05d` | `99652109` | `TreasuryConduit` (`0xB97469C9380d4Da3668c9B068E835f7AE45c82aA`), `TreasuryConduitPermit2` (`0x7BA852528f6c3F84Eac3fb7dCcF26BfE16b4f34f`), `TreasuryBridgeConduitV2` (`0x21c572275F468Ad8CE333B248e63d8E9E5Bf8e5B`), `TreasuryBridgeConduit` (`0xDcC32B42D3B19E9196CaB6bA6bF67d17a65B530c`) + 15 allowlists |
| Avalanche C-Chain (`43114`) | `0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B` | `avax-43114-1b` | `0xa57f2f711573e14a7719daac4d394e3f479c30dceb96ccdb0227e411677f9e17` | `99652114` | `TreasuryBridgeConduitPermit2` (`0xfA9F49Df7dc0B1E0f17cec20fd6B6eb971f77a3C`), `SpokeMemoConduit` (`0x273B51467f3e84eda3B443a2Ee81cafD4622f775`), `MemoConduit` (`0x52Dd9c372C6ea4afB29747f49436F628A1f21E32`), `CctpDepositForwarderImplementation` (`0x1612F9A755e833Daf626BFD6952deCE9a76BAf4C`), `CctpDepositForwarderFactory` (`0x47Be2882B335Eba84C3908a2f01705cb09d296CA`) + 6 allowlists |
| Avalanche C-Chain (`43114`) | `0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B` | `avax-43114-1c` | `0xe887c57fe87449d5f43a398ccf0a8c7db14b4fe14f1857b9ed2c38d83b89afe2` | `99652117` | `ClaimVaultDeployer` (`0x5BC58Ea1721A5976e68468b89019920b71C73CD5`), `PeanutV4` (`0x6bd53a40ff9b37543174553531C00C1c32E16B6b`), `PayrollBatch` (`0x60906130C29B3899b14b9EB04e8ca9F915Eb86E4`) |
| Arc Testnet (`5042002`) | `0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B` | `arc-testnet-5042002-1a` | `0xa546acf282727448ce6ba99e70f0670436ce07d2a2d396825c7ba099e55255b7` | `71157851` | `TreasuryConduit` (`0xB97469C9380d4Da3668c9B068E835f7AE45c82aA`), `TreasuryConduitPermit2` (`0x7BA852528f6c3F84Eac3fb7dCcF26BfE16b4f34f`), `TreasuryBridgeConduitV2` (`0x21c572275F468Ad8CE333B248e63d8E9E5Bf8e5B`), `AgentGatewayAccountFactory` (`0xbeF3d87dB69490115a8B83512E1e1D0e2e38D7f9`), `DocumentReceivableRegistry` (`0x4955cb7B853860a40F075957C30513257210EDB3`), `MemoConduit` (`0xf31E0557505deb66B31571591cAacAbcD7D6AD71`), `CctpDepositForwarderImplementation` (`0x1612F9A755e833Daf626BFD6952deCE9a76BAf4C`), `CctpDepositForwarderFactory` (`0xEcbe7DC7db6fD6193F83C0B38ccd420e327a56aD`) |
| Arc Testnet (`5042002`) | `0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B` | `arc-testnet-5042002-1b` | `0x97ac77d0b8eff40f995006008da276f27ee7497f5c705c0ec0eb96e228f7c7f0` | `71157867` | `ClaimVaultDeployer` (`0x5BC58Ea1721A5976e68468b89019920b71C73CD5`), `PeanutV4` (`0x6bd53a40ff9b37543174553531C00C1c32E16B6b`), `PayrollBatch` (`0x60906130C29B3899b14b9EB04e8ca9F915Eb86E4`) |
| Base Mainnet (`8453`) | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` | `base-8453` | `0x00bcd410f6055d95c61bdc8d6ef7d70d0ae1d8dcbc7b5f36c9af573ddd687dbd` | `54220240` | `CctpDepositForwarderImplementation` (`0x1612F9A755e833Daf626BFD6952deCE9a76BAf4C`), `CctpDepositForwarderFactory` (`0xf56Fe0bA9B9D951035f3422bb11D030D0c557AdF`), `ClaimVaultDeployer` (`0xE57695e4CE920eB24d80697c3369aE80fa275E6a`), `PeanutV4` (`0xeA06BF5AD08b70E4c107f3925CBC618662f88965`), `PayrollBatch` (`0xE9b96103Ddc1268F1184667F4c3E85Da75340E10`) |

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
