# treasury-conduits

Production treasury conduits. License on the first-party sources is AGPL-3.0-only, except `IPermit2SignatureTransfer.sol` (MIT). Compiler: solc 0.8.24, optimizer 200 runs, viaIR, evm version paris, metadata bytecode hash ipfs.

These files are the Sourcify-verified compiler inputs for the live deployments. The private `BuFi007/BUFI-6900` git tree was not readable from this environment, so history was not imported with subtree. The branches those deployments came from are:

- `TreasuryConduit` and `TreasuryRedeemConduit`: freeze-branch files, with the dead-code removal in [BUFI-6900 PR #5](https://github.com/BuFi007/BUFI-6900/pull/5) (`cursor/remove-dead-solidity-9111`) as the intended base. The v0.8 gateway module that pull request removed is not in this package.
- `TreasuryConduitPermit2`: branch `codex/permit2-treasury-conduit`.
- `TreasuryBridgeConduitV2`: branch `feat/plan-408-treasury-bridge-conduit`.

`lib/openzeppelin-contracts/` is the OpenZeppelin snapshot from those verifications. It is a different snapshot from `packages/fx-recibu/lib` and must not be remapped onto it. Unused remapping prefixes from the original foundry project (solady, forge-std, account-abstraction, erc6900, circle) are not vendored. They are replayed as strings by `script/verify_bytecode.py` because the metadata CBOR records them.

Not imported, and not in the audit set: gateway-guard, GatewayTreasury, the v0.7 session and recipient hooks, TreasuryEarnVault, and any SwapDeposit adapter or planned v3. None of those appeared in the mainnet verifications recovered for the addresses below.

## Deployed addresses

| Contract | Chain | Address | Bytecode |
| --- | --- | --- | --- |
| TreasuryConduit | Avalanche 43114 | [`0x49c89b198321ed0782a4f9a44de2b237ebd77cf0`](https://snowtrace.io/address/0x49c89b198321ed0782a4f9a44de2b237ebd77cf0) | exact |
| TreasuryConduit | Arc 5042 | [`0xa9817049f0a48d4653719465a7829e85b3a415e7`](https://explorer.arc.io/address/0xa9817049f0a48d4653719465a7829e85b3a415e7) | exact |
| TreasuryConduitPermit2 | Avalanche 43114 | [`0xaebb9c395ab6d627eb0defc3b16e7f49dc30c19f`](https://snowtrace.io/address/0xaebb9c395ab6d627eb0defc3b16e7f49dc30c19f) | immutables |
| TreasuryConduitPermit2 | Arc 5042 | [`0xb63da0934e2a89169f89eed0679c35cc4d5959a5`](https://explorer.arc.io/address/0xb63da0934e2a89169f89eed0679c35cc4d5959a5) | immutables |
| TreasuryBridgeConduitV2 | both | [`0x41422093ef6d03fbd3c0a2e3a6a6f69b1cad4409`](https://snowtrace.io/address/0x41422093ef6d03fbd3c0a2e3a6a6f69b1cad4409) | exact |
| TreasuryRedeemConduit | Arc 5042 | [`0x361340f0b3a8ec00067ea3c024ae6919a2a0d06a`](https://explorer.arc.io/address/0x361340f0b3a8ec00067ea3c024ae6919a2a0d06a) | immutables |

Arc conduits and the Avalanche `TreasuryConduit` are owned by `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09`. Avalanche Permit2 and Bridge are owned by `0xa3a40fa2d82c0224c40b1ed7e07cb474b7d1468b`.

Build and test from the repository root: `forge build` and `forge test` use this package as the default profile. `TreasuryConduitPermit2` is not constructed in the smoke test because its constructor requires the canonical Permit2 and the address book to already have code.
