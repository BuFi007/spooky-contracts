# Audit scope

Olympix audit set for this repository. The sha256 values are the audit basis. `lib/` is excluded. The git commit that introduced these sources is recorded at the bottom of this file once that commit exists. A later edit to this document does not retarget the sources commit.

Sources were taken from Sourcify-verified standard-json inputs and checked against live runtime code. They were not subtree-imported from `BUFI-6900`, `desk-v1`, or `fx-recibu`, because those repositories were not readable. Intended provenance:

- TreasuryConduit and TreasuryRedeemConduit: `BUFI-6900` freeze files, base `cursor/remove-dead-solidity-9111` ([PR #5](https://github.com/BuFi007/BUFI-6900/pull/5)). The v0.8 gateway module that pull request removed is absent.
- TreasuryConduitPermit2: `BUFI-6900` branch `codex/permit2-treasury-conduit`.
- TreasuryBridgeConduitV2: `BUFI-6900` branch `feat/plan-408-treasury-bridge-conduit`.
- Arc hub, including MultiTokenReceivableEscrow and RecibuMemoRouter: `fx-recibu` branch `feat/recibu-memo-router-mainnet`, commit `1525532`.
- SpokeMemoConduit and the CCTP MemoConduit parent: `fx-recibu` branch `feat/memo-conduit-cctp-mainnet`, commit `8aab86a`.
- v1 MemoConduit: the verified sources at the Arc and Avalanche addresses below. Arc `0x516340a244132c62bedae5f886fd35845af16ba2`, Avalanche `0x536268d0a6c32a7161ba146f5673dfcf13f1ffe2`.
- claim-vault: desk-v1 commit `c22110966e` (imported in `ab83e5e`). `upstream/PeanutV4.4.upstream.sol` and `upstream/bufi.diff` stay outside the compile set.
- StableFX `RecibuSettlementGuardHook`, `IV4Types`, and the hook's `IInvoiceShelf`: fx-recibu `main` commit `7330e6c` (imported in `ab83e5e`). Undeployed. No mainnet bytecode check.

## Compiler

| Profile | solc | EVM | Settings |
| --- | --- | --- | --- |
| treasury, permit2 | 0.8.24+commit.e11b9ed9 | paris | optimizer 200, viaIR, bytecodeHash ipfs |
| fx (hub, spoke-cctp, memo-v1, stablefx) | 0.8.26+commit.8a97fa7a | cancun | optimizer 200, viaIR, bytecodeHash ipfs |
| claim-vault | 0.8.23 | paris | optimizer 99999, viaIR off. Solar via `forge --use solar` |

`script/verify_bytecode.py` replays the verified remapping list. That list is part of the metadata CBOR. `forge build` from the repository root uses different source-unit names, so its metadata suffix is not the deployment bytecode. Solar bytecode is not the deployment bytecode, and Solar init code produces different CREATE2 addresses.

## Excluded

- `packages/treasury-conduits/lib/**` and `packages/fx-recibu/lib/**`. Vendored OpenZeppelin files from the verified inputs. Not hashed below.
- `packages/claim-vault/lib/**`. OpenZeppelin contracts v4.9.2 `e50c24f5839db17f46991478384bfda14acfb830` (the Peanut v4.4 submodule gitlink) and forge-std v1.15.0 `0844d7e1fc5e60d77b68e469bff60265f236c398`. The claim-vault README names forge-std `bb4827bb`; that object is not on `foundry-rs/forge-std`, so the v1.15.0 tag is the pin. Not hashed below.
- `packages/claim-vault/upstream/**`. Provenance, outside the compile set. `PeanutV4.4.upstream.sol` sha256 `2824bc0db2de14dea6da66d2abc7970ed28febabd675fbf7df10f9b249743178`. `bufi.diff` sha256 `ac76e42d9bd5df8cb405e948762c830547c9f665d31a1ada69f688fbb548bcbb`.
- Identity and reputation registry implementations. Interfaces imported by InvoiceShelf remain in scope.
- Testnet-only and removed contracts: gateway-guard, GatewayTreasury, v0.7 session and recipient hooks, TreasuryEarnVault, BUFIOracle, InvoiceMemoRouter, InvoiceSettlement, old ReceivableEscrow, BUAttestation, KybWorkspacePolicy, CRE extractors deleted in fx-recibu PR #12.
- ens, escrow, recibo, fx-telarana, fx-sobre, fx-recibu-loans, fantasmita-ars, fantasmita-passport, kawaii-raindrops, stablecoin-curve-punk-nft, BDACS/KRW1.
- Tests under `packages/*/test`, including the claim-vault suite. `test_nested_selfAsOwner_refusedAtConstruction` is not in that suite.
- `packages/fx-recibu/stablefx/test-pending/GuardHook.t.sol` (sha256 `25ae87ff2f1210931c20c36405dd35f24e7d5dcefb14597527630614ca90353f`). It is the fx-recibu `7330e6c` test and it is not compiled: its imports name identity and reputation implementations and `StrictAuthorityInvoiceVerifier`, which are not in this tree. See `test-pending/README.md`.

## Not yet in the tree

SwapDeposit and a planned treasury v3 were not found as verified mainnet deployments and were not invented.

## In-scope sources

sha256 of the file bytes.

| sha256 | Path |
| --- | --- |
| `fc6aa56c6ef16451490f2d56abf583e5e28902f6bc8ac988207f12d0df759042` | `packages/claim-vault/src/V4/PeanutV4.4.sol` |
| `02e10daee28f0898f226ef317dfa03e497f53cdae04fb54bf1fd94df703d67fe` | `packages/claim-vault/src/deploy/ClaimVaultDeployer.sol` |
| `91674840d6e949821e9a0332c5c96daf3a41c80ab60c6289fdef12fe46ba9e21` | `packages/claim-vault/src/interfaces/IPeanutV4MFAVault.sol` |
| `6cbd702a9dc9fc9b82eb36f53bfca2b17b55be4f732222254050136bf2578982` | `packages/claim-vault/src/interfaces/ISignatureTransfer.sol` |
| `7ccf045fdbb810730ea23fd42319888c820bb6e27dabf9636fa12634d552f4a8` | `packages/claim-vault/src/payroll/PayrollBatch.sol` |
| `8fb4f50fcbcb824908fbfa0946ab2f9bae0baacd755cad8ee4d608e9b68306e7` | `packages/claim-vault/src/util/IEIP3009.sol` |
| `2b36e4e1e903f1a18b5480c75d4fa77dc5e0359d4f2545f020ceb6691c57b309` | `packages/claim-vault/src/util/IL2ECO.sol` |
| `841d9afec22f958a7dd24e7cb8a63ec68530f766a4ea73224e58cbb5436f1078` | `packages/fx-recibu/hub/src/credit/WorkspaceTierRegistry.sol` |
| `4ae0f9ef70bae25ab88fd703d6fa02ef409ec97b9c97be27496a2e08aabeb18c` | `packages/fx-recibu/hub/src/interfaces/IBUFIIdentityRegistry.sol` |
| `985bbb7607bb35346c172fc106a6d357646d7342b97ff8c44c5db75d26149cec` | `packages/fx-recibu/hub/src/interfaces/IBUFIReputationRegistry.sol` |
| `67ad836baf28b77e95f024abd3f6e826636dc3841461a39fa56cc50fb1463692` | `packages/fx-recibu/hub/src/interfaces/IERC2612.sol` |
| `0d48699059dc284eee7bdddab65baf552ad9c7353d3ae1c0ae20efdd758079e0` | `packages/fx-recibu/hub/src/interfaces/IERC3009.sol` |
| `08d2c927d7f3a842e61c0d6288cb9ea9db4e93d79b6388969b039ace46514dd3` | `packages/fx-recibu/hub/src/interfaces/IInvoiceShelf.sol` |
| `0ca7620eca8e43672d0ef3a11ed8886df170305aa027b94a6b8d0042ceeed881` | `packages/fx-recibu/hub/src/invoice/BIFTranche.sol` |
| `e186a276ed612e7a74634f347f5aecfa5e51c498ec660e1b08cfa81d2244331b` | `packages/fx-recibu/hub/src/invoice/BINV.sol` |
| `7c82bcfd757508730a76b2c3ce19b86806410a62f3498bc33e77df0e00f63150` | `packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol` |
| `39bddae466909e8bab2d9a77c4ee41b8166c5560f71a7cc507c20b9da1e093ba` | `packages/fx-recibu/hub/src/libraries/FactoringEvidenceV1.sol` |
| `5f334650bddf31b9515637de05ed942896b66805ba2f1ac6aa85f2d6dfc283fc` | `packages/fx-recibu/hub/src/libraries/Params.sol` |
| `f4a9e11785c843442efc8cb8461475ba369e3328a259ddfc4eab65125e16493d` | `packages/fx-recibu/hub/src/libraries/ReceivableCommitment.sol` |
| `f9dc38ac3934ece3f04b2b4718e1fe2c2e5a77024ed6ff93cbe183577ea8e171` | `packages/fx-recibu/hub/src/rails/MultiTokenReceivableEscrow.sol` |
| `9d1faeda260901473d401c86a11d789ea914bb6e3137c12312e693f6629b0f9e` | `packages/fx-recibu/hub/src/rails/RecibuMemoRouter.sol` |
| `00484925f4f3c470668551c8c816fbad59098e80bcc45f39d25a27035047a47f` | `packages/fx-recibu/hub/src/rails/WorkspaceOperatingReserve.sol` |
| `b339c41f44158c051be725187ca1beb5e87d70a79ac5d93198697f097b69bd96` | `packages/fx-recibu/memo-v1/src/interfaces/IERC3009.sol` |
| `848574726a81997b000a21e94f80824e5bb3f7e446ab43155e5c158fa1cc6bb9` | `packages/fx-recibu/memo-v1/src/rails/MemoConduit.sol` |
| `b339c41f44158c051be725187ca1beb5e87d70a79ac5d93198697f097b69bd96` | `packages/fx-recibu/spoke-cctp/src/interfaces/IERC3009.sol` |
| `2e33f96609311446f9ed4ec83c704e010dc7af09df2439444bce62a880b783c2` | `packages/fx-recibu/spoke-cctp/src/rails/MemoConduit.sol` |
| `3b7c96b99895ffef250bcebcfd488d8e81ae327738f81ad12fd4da5017f8cc75` | `packages/fx-recibu/spoke-cctp/src/rails/MemoConduitCctpConfig.sol` |
| `175940ca25f23dbec88cfc7e05e8683ec69bf559a66e05abedc0140bac81de38` | `packages/fx-recibu/spoke-cctp/src/rails/SpokeMemoConduit.sol` |
| `a08e7dccb3c76aa533b8444e6cab4dbe7ee39e2eae56e7c1b78800a8cb05d74a` | `packages/fx-recibu/stablefx/src/hooks/RecibuSettlementGuardHook.sol` |
| `b30eea067f0c68ddffcb1347500af314d04986082c79460408caac7511d27860` | `packages/fx-recibu/stablefx/src/interfaces/IInvoiceShelf.sol` |
| `e3c14a4bff118f449c73cd469f34487f14f2ea0f62f12b6ac947210e280963fe` | `packages/fx-recibu/stablefx/src/interfaces/IV4Types.sol` |
| `2e75ebb42979945831bf6ccbaffe7eaad9f02cd088fdaf9ca7326bb6748e14f6` | `packages/treasury-conduits/src/bufi/conduit/TreasuryBridgeConduitV2.sol` |
| `00617d043d62bf630bbfe1694d6007f24a7788a04fb23f553c800ae83f5c204c` | `packages/treasury-conduits/src/bufi/conduit/TreasuryConduit.sol` |
| `1ffb77f15f131320ecc03f4257b8f2731de8dcd24164d48f6cb3e3c7990609ee` | `packages/treasury-conduits/src/bufi/conduit/TreasuryConduitPermit2.sol` |
| `1bf8988842e79fb0e1326f32b18ee41aa16981aeffecaf05e1f42b368289b570` | `packages/treasury-conduits/src/bufi/conduit/TreasuryRedeemConduit.sol` |
| `6a5d310a2a79877c93b0356c37f233114b06fdd4c28d7b57e8cb0a46d9ecce0e` | `packages/treasury-conduits/src/bufi/conduit/interfaces/IFiatTokenV2.sol` |
| `58cf1cefc1320babc4c22b61a3a969ddebd5f52e2782d4762587d5a62860416a` | `packages/treasury-conduits/src/bufi/conduit/interfaces/IPermit2SignatureTransfer.sol` |

Spoke `IERC3009.sol` and memo-v1 `IERC3009.sol` are the same bytes. Hub `IERC3009.sol` is a different file. v1 `MemoConduit.sol` and the CCTP `MemoConduit.sol` are different files.

## Bytecode vs mainnet

Checked with solc standard-json against `eth_getCode` on 2026-11-02. `exact` is byte-for-byte runtime equality. `immutables` is equality after copying on-chain immutable slots into the compiler template (the compiler leaves those slots zero). Every address below matched. Hashes are also in `deployments/bytecode-hashes.json`.

| Contract | Chain | Address | Result | On-chain runtime sha256 |
| --- | --- | --- | --- | --- |
| TreasuryConduit | 43114 | `0x49c89b198321ed0782a4f9a44de2b237ebd77cf0` | exact | `dc45c6e80d9508f707935c328e2fb06cb002dd87f0b7ff4388803ad7d7140679` |
| TreasuryConduit | 5042 | `0xa9817049f0a48d4653719465a7829e85b3a415e7` | exact | `dc45c6e80d9508f707935c328e2fb06cb002dd87f0b7ff4388803ad7d7140679` |
| TreasuryConduitPermit2 | 43114 | `0xaebb9c395ab6d627eb0defc3b16e7f49dc30c19f` | immutables | `fb5f39f41f2d912645db3efb2103c80f60db87a60f8beb5b58d89827634db735` |
| TreasuryConduitPermit2 | 5042 | `0xb63da0934e2a89169f89eed0679c35cc4d5959a5` | immutables | `fb5f39f41f2d912645db3efb2103c80f60db87a60f8beb5b58d89827634db735` |
| TreasuryBridgeConduitV2 | 43114 | `0x41422093ef6d03fbd3c0a2e3a6a6f69b1cad4409` | exact | `9c2cc342e0dbeafdd82dc0e072a19e0dd90ddedb9862222c22939d0e349caa83` |
| TreasuryBridgeConduitV2 | 5042 | `0x41422093ef6d03fbd3c0a2e3a6a6f69b1cad4409` | exact | `9c2cc342e0dbeafdd82dc0e072a19e0dd90ddedb9862222c22939d0e349caa83` |
| TreasuryRedeemConduit | 5042 | `0x361340f0b3a8ec00067ea3c024ae6919a2a0d06a` | immutables | `84061865202046f2ecc7b886d92634ebb748f0e5d8c5175dd2f9d1f00ea6b31c` |
| InvoiceShelf | 5042 | `0x8d3006f7be5b5e6e5b7709889a2e5d9ee4d3cd0a` | immutables | `09af5094a21b4d1d08b9e1a1ad07ab884f20b431b728e7564b5bff9b27ce87e9` |
| WorkspaceTierRegistry | 5042 | `0xfe06281b464d53f00cceca504114263c689e56fe` | immutables | `4ee5eaf0d41de8b0b8c884427eb264f08b9d4fa1b591f6e1350714582debb1dd` |
| MultiTokenReceivableEscrow | 5042 | `0xbb4b6bbdaeb3136571d33742385a1ae59cee57ab` | exact | `59ccf96bb1032ab191fa8b1d755c2410cdcd3c1a26b8f850e91d0b4c696a59b8` |
| RecibuMemoRouter | 5042 | `0x208fbdf4268c87c475189d9ecd7d59b4766e75cb` | immutables | `a8ce45a6a75fc4b525015bc10aeeb13a865890ce06c2cb247e9b6ae4e90a6653` |
| SpokeMemoConduit | 43114 | `0x7b5b1425bb621b014b7257a0d0caf88c453e33c8` | immutables | `38caaae1ad2c2d0ea929a9690b6100f580cf1e3ab89a008773b3f8c9f21f2841` |
| MemoConduit v1 | 43114 | `0x536268d0a6c32a7161ba146f5673dfcf13f1ffe2` | immutables | `63261aec1127c272bf419cd7503ad82ef23abcb86656d4c220f328aa95a7d683` |
| MemoConduit v1 | 5042 | `0x516340a244132c62bedae5f886fd35845af16ba2` | immutables | `63261aec1127c272bf419cd7503ad82ef23abcb86656d4c220f328aa95a7d683` |

`RecibuSettlementGuardHook` is in scope and undeployed. There is no mainnet address and no bytecode match for it.

## Sources commit

Sources commit: not yet recorded.
