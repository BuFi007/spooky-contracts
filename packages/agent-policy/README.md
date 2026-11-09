# agent-policy

Agent Gateway Policy Factory (`AgentGatewayAccount`, `AgentGatewayAccountFactory`, `AgentGatewayAccountFactoryArcTestnet`, and `GatewayIntentPolicy`). License on first-party sources is AGPL-3.0-only. Compiler: solc 0.8.24, optimizer 200 runs, viaIR, evm version paris, metadata bytecode hash ipfs.

Provenance:
- `BuFi007/BUFI-6900` commit `1ca76b59540e3de72de3c2ce00c5cf9fa5bf2e64` (recorded in `BuFi007/desk-v1/contracts/deployments/agent-policy-arc-testnet-20261030.json` and `BuFi007/desk-v1/vendor/bufi-6900/manifest.json`).
- Sourcify-verified standard-json input for Arc Testnet (`5042002`) deployment at [`0xe57c1e0de777a57b289493caf313760130cd0ba7`](https://explorer.testnet.arc.io/address/0xe57c1e0de777a57b289493caf313760130cd0ba7).

## Deployed addresses (`spooky-contracts-prod-20261106`)

| Contract | Chain | Address | Administrator Safe | Initial Issuer |
| --- | --- | --- | --- | --- |
| `AgentGatewayAccountFactory` | Arc Mainnet (`5042`) | `0xC4c3886A7f66E49fF95d7A15a12958b4cBa0eA3C` | `0x47Dc7D18A6E3a79F696714E7D47456a49B430D09` | `0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474` |
| `AgentGatewayAccountFactory` | Arc Testnet (`5042002`) | `0xAe5e277f516c4972557554851186ADf5F304799B` | `0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B` | `0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474` |
| `AgentGatewayAccountFactoryArcTestnet` | Arc Testnet (`5042002`) | `0x9342D03D10A545E127A39b69a2ff8fC044D4bFD8` | `0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B` | `0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474` |

Build and test from the repository root with Foundry profile `agent-policy`:

```bash
forge build --profile agent-policy
forge test --profile agent-policy
```
