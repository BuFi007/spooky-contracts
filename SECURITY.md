# Security

Production sources in this repository are the compiler inputs behind live Arc Mainnet (`5042`), Avalanche C-Chain (`43114`), Arc Testnet (`5042002`), and Base Mainnet (`8453`) deployments (`spooky-contracts-prod-20261106`). A change to those files, or to the vendored OpenZeppelin files they import, changes the bytecode auditors are comparing to live on-chain deployments.

Report a vulnerability through GitHub private vulnerability reporting on [BuFi007/spooky-contracts](https://github.com/BuFi007/spooky-contracts). Do not open a public issue for an undisclosed mainnet bug.

This repository does not hold keys, mnemonics, or RPC credentials. Do not commit `.env` files. CI builds and tests. It does not broadcast transactions.

[`OLYMPIX_SUBMISSION.md`](./OLYMPIX_SUBMISSION.md) is the complete inventory of all 72 Solidity files in scope, with SHA-256 hashes, `F-01` through `F-30` remediations, and test coverage across all 10 Foundry profiles. `packages/*/lib/` is vendored compiler input and is excluded from the first-party audit scope.
