`permit2.arc-testnet.runtime.hex` is the runtime bytecode at the canonical Permit2 address
`0x000000000022D473030F116dDEE9F6B43aC78BA3` on Arc testnet (chainId 5042002), fetched with
`cast code … --rpc-url https://rpc.testnet.arc.network` on 2026-09-23.

It is byte-identical to Ethereum mainnet's Permit2 except for the two immutables Permit2
bakes in at construction: `_CACHED_CHAIN_ID` (0x4cef52 = 5042002 vs 0x01) at offset 6974,
and `_CACHED_DOMAIN_SEPARATOR` at offset 6983. So the tests run against the real canonical
contract. Tests that etch it must set `vm.chainId(5042002)`, or Permit2 recomputes its
domain separator for the test chain.

`payroll-batch.arc-testnet.runtime.hex` is the runtime bytecode of the DEPLOYED `PayrollBatch`
at `0x8f4e4d47C0D4F8bF3AAeAcC31C9Cd425476B30C5` on Arc testnet, fetched with `eth_getCode` on
2026-09-28 (plan 386 Phase 0). Its immutables are baked in: `PERMIT2` = canonical,
`VAULT` = `0xb96Cc197F4b15DA762e4c34E1413CECa57FaC4fC`. `PayrollBatchDeployed.t.sol` etches it
at its own address so the log-order and re-open measurements run against the bytes on chain,
not a local compile.
