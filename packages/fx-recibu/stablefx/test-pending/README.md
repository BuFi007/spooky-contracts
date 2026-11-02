# GuardHook tests are not compiled

`GuardHook.t.sol` is the fx-recibu `main` test at commit `7330e6c`. It is in scope as the intended test for `RecibuSettlementGuardHook`, and it is outside the Foundry compile set.

The test imports the fx-recibu main layout (`src/identity/BUFIIdentityRegistry.sol`, `src/identity/BUFIReputationRegistry.sol`, `src/invoice/InvoiceShelf.sol`, `test/utils/StrictAuthorityInvoiceVerifier.sol`, and the other hub files next to those). This monorepo keeps the verified hub under `packages/fx-recibu/hub` and does not include the identity or reputation implementations, or `StrictAuthorityInvoiceVerifier`. Those imports do not resolve here, so the file lives in `test-pending/` instead of `test/`.

`forge test --profile fx-stablefx` compiles the hook and does not compile this file. Move it back under `test/` when those sources are imported.
