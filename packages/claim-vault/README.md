# claim-vault

This package is a pointer, not a source tree.

`contracts/claim-vault` was removed from `BuFi007/desk-v1` `main` on 2026-10-31. The intended import is desk-v1 commit `c22110966e`, which is the tree on branch `cursor/remove-dead-solidity-4bd4` ([desk-v1 PR #1081](https://github.com/BuFi007/desk-v1/pull/1081)). That repository was not readable with the credential available to this import, so the Solidity was not copied and git history was not preserved.

When that tree can be read, import it here and keep these two files outside the compile set:

- `upstream/PeanutV4.4.upstream.sol`
- `bufi.diff`

`lib/` from that import stays out of `AUDIT_SCOPE.md`. Do not replace the BUFI sources with the public `peanut-contracts` tree. PayrollBatch on Arc testnet is unverified and is not a mainnet deployment, so it was not reconstructed from bytecode.
