# treasury-conduits

Production treasury conduits. License on the first-party sources is AGPL-3.0-only, except `IPermit2SignatureTransfer.sol` (MIT). Compiler: solc 0.8.24, optimizer 200 runs, viaIR, evm version paris, metadata bytecode hash ipfs.

These files are the Sourcify-verified compiler inputs for the live deployments. The private `BuFi007/BUFI-6900` git tree was not readable from this environment, so history was not imported with subtree. The branches those deployments came from are:

- `TreasuryConduit` and `TreasuryRedeemConduit`: freeze-branch files, with the dead-code removal in [BUFI-6900 PR #5](https://github.com/BuFi007/BUFI-6900/pull/5) (`cursor/remove-dead-solidity-9111`) as the intended base. The v0.8 gateway module that pull request removed is not in this package.
- `TreasuryConduitPermit2`: branch `codex/permit2-treasury-conduit`.
- `TreasuryBridgeConduitV2`: branch `feat/plan-408-treasury-bridge-conduit`.

`lib/openzeppelin-contracts/` is the OpenZeppelin snapshot from those verifications. It is a different snapshot from `packages/fx-recibu/lib` and must not be remapped onto it. Unused remapping prefixes from the original foundry project (solady, forge-std, account-abstraction, erc6900, circle) are not vendored. They are replayed as strings by `script/verify_bytecode.py` because the metadata CBOR records them.

Not imported, and not in the audit set: gateway-guard (except `GatewayIntentPolicy` in `packages/agent-policy`), GatewayTreasury, the v0.7 session and recipient hooks, and TreasuryEarnVault.

The planned v3 treasury conduits (`TreasuryConduit` v3, `TreasuryRedeemConduit` v3, and `TreasurySwapAndDeposit` from `BuFi007/BUFI-6900` branch `cursor/remove-dead-solidity-9111`) and the Permit2 bridge conduit (`TreasuryBridgeConduitPermit2` and its v1 `TreasuryBridgeConduit` parent from `BuFi007/BUFI-6900` branch `codex/permit2-treasury-conduit`) live under `v3/` and compile with Foundry profile `treasury-v3`, keeping the Sourcify-verified v2 mainnet sources in `src/` unchanged.

## Deployed addresses (`spooky-contracts-prod-20261106`)

| Contract | Arc Mainnet (`5042`) | Avalanche C-Chain (`43114`) | Arc Testnet (`5042002`) |
| --- | --- | --- | --- |
| `TreasuryConduit` (v2) | `0x6B33A6E3078F961892eC2A27797F2Bd1efF07327` | `0xB97469C9380d4Da3668c9B068E835f7AE45c82aA` | `0xB97469C9380d4Da3668c9B068E835f7AE45c82aA` |
| `TreasuryConduitPermit2` | `0xE7b973C68678888eD4824154529362AcFaC10278` | `0x7BA852528f6c3F84Eac3fb7dCcF26BfE16b4f34f` | `0x7BA852528f6c3F84Eac3fb7dCcF26BfE16b4f34f` |
| `TreasuryBridgeConduitV2` | `0x3552726aacf5A2761991a270CdE2dba9dc2f5FCc` | `0x21c572275F468Ad8CE333B248e63d8E9E5Bf8e5B` | `0x21c572275F468Ad8CE333B248e63d8E9E5Bf8e5B` |
| `TreasuryRedeemConduit` (v2) | `0x5f47FEEE01B89D8B1A1FAb4e8A52B0C4C2b7EeAa` | — | `0xCf745eAe902494B63e3c3E41F1F29eF29400F9E0` |
| `TreasuryConduit` (v3) | `0xe11FD30ff39997F20bEAac2aDAB3f5Ae2Ca24484` | `0x907A5d73dD97236475890f0aFB1dE7D019091075` | `0x907A5d73dD97236475890f0aFB1dE7D019091075` |
| `TreasuryBridgeConduit` (v3) | `0x582CB729D16b97868A4670Db921aa33A13c148f8` | `0xDcC32B42D3B19E9196CaB6bA6bF67d17a65B530c` | `0xDcC32B42D3B19E9196CaB6bA6bF67d17a65B530c` |
| `TreasuryBridgeConduitPermit2` (v3) | `0x936F8a287363B03e29e2c089a57672A47D686A33` | `0xfA9F49Df7dc0B1E0f17cec20fd6B6eb971f77a3C` | `0xfA9F49Df7dc0B1E0f17cec20fd6B6eb971f77a3C` |
| `TreasuryRedeemConduit` (v3) | `0x78DCE8E25B092E5956d7DF4314AAa8d0b6bF60e5` | — | `0xa1f1DFAA3126b820F7A0D0d3D8e2524c287918d3` |
| `TreasurySwapAndDeposit` (v3) | `0x8Ae5ed45E5E365eEfF1d93c70433ddC642C5E10B` | `0x7C25941D21f7B34e419bdC422a2a0b857E093007` | `0x97136C523199F78b8A9f2570F1c5f9b4d48B7B93` |

Arc Mainnet (`5042`) conduits are owned by `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09`. Avalanche (`43114`) and Arc Testnet (`5042002`) conduits are owned by `0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B`. Full execution receipts live in [`../../deployments/addresses.json`](../../deployments/addresses.json).

Build and test from the repository root: `forge build` and `forge test` use this package as the default profile. `TreasuryConduitPermit2` is not constructed in the smoke test because its constructor requires the canonical Permit2 and the address book to already have code.
