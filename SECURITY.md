# Security

Production sources in this repository are the compiler inputs behind live Arc and Avalanche deployments. A change to those files, or to the vendored OpenZeppelin files they import, changes the bytecode auditors are comparing to mainnet.

Report a vulnerability through GitHub private vulnerability reporting on [BuFi007/spooky-contracts](https://github.com/BuFi007/spooky-contracts). Do not open a public issue for an undisclosed mainnet bug.

This repository does not hold keys, mnemonics, or RPC credentials. Do not commit `.env` files. CI builds and tests. It does not broadcast transactions.

`AUDIT_SCOPE.md` is the list of files in scope, with sha256 hashes. `packages/*/lib/` is vendored compiler input and is excluded from that list. `packages/claim-vault/` has no sources yet.
