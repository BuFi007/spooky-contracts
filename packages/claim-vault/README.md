# claim-vault: BUFI fork of Peanut Protocol PeanutV4.4

A claim-link escrow with MFA-gated withdrawals. The external ABI is a strict superset of the
`v4.4` ABI shipped in `@squirrel-labs/peanut-sdk` 0.6.x. Approval-based and simple
gasless flows retain their signing formats; the hardened custom gasless flow uses
the BUFI custody commitment described in [`SIGNATURES.md`](./SIGNATURES.md).

## Security remediation (2026-10-08) — deployed to Arc testnet

This source closes the custom EIP-3009 custody substitution issue by committing
every stored custody parameter, chain and vault into the token authorization nonce.
It also rejects inexact ERC20 receipts rather than creating pooled liabilities,
and pays ECO claims to the verified recipient while keeping sender reclaims intact.
Fee-on-transfer and no-op tokens are explicitly unsupported for ERC20 deposits;
standard tokens and tokens without return values retain their existing behavior.

Deployed fresh to Arc testnet on 2026-10-08 (see "Current" below); `@bu/env`
`payroll-batch.ts` now points PayrollBatch and the claim vault at the new
addresses. Older vaults are immutable and unchanged.

- Signature spec for the claim link key and the OTP attestor: [`SIGNATURES.md`](./SIGNATURES.md)
- Upstream source, kept for diffing: `upstream/PeanutV4.4.upstream.sol`.
  Original customization snapshot: `upstream/bufi.diff` (predates the security remediation).

## Provenance

|                                                 |                                                                                                                       |
| ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Upstream repo                                   | https://github.com/peanutprotocol/peanut-contracts                                                                    |
| Forked at                                       | `5e94c815b88fe4b043e7d83332ac82ddcb184d01` (HEAD, 2026-08-10)                                                         |
| Last upstream change to `src/V4/PeanutV4.4.sol` | `9b435a81a62d01f046cd9db7fdbb738420e955a4` (2024-03-27, "Remove methods like onERC721Received")                       |
| License                                         | GPL-3.0-or-later (upstream `LICENSE.md` kept; a fork notice is in the file header per GPL §5a)                        |
| OpenZeppelin                                    | v4.9.2 @ `e50c24f5839db17f46991478384bfda14acfb830`, the upstream submodule pin. Vendored without `.git` under `lib/` |
| forge-std                                       | 1.15.0 @ `bb4827bb` (test-only; upstream's 2023 pin needs ds-test)                                                    |

Evidence that this is the SDK's v4.4:

1. **ABI.** `abi/abi-diff.mjs` compares the SDK 0.6.2 `v4.4` ABI (extracted to
   `abi/peanut-sdk-0.6.2-v4.4.abi.json`) with the upstream build: every entry is identical.
2. **Bytecode.** The upstream source, compiled with solc 0.8.23, optimizer 99999 runs and
   evm `paris`, reproduces the runtime bytecode Peanut deployed as `v4.4` on Polygon
   (`0x3B92cB30bc3C9AD8Ae24F16E73dC59e08C520f92`) and Gnosis
   (`0x108476aCb5E7Fad5CD71CC77EbD617e1b9006a76`) byte-for-byte, excluding the CBOR metadata tail.

The monorepo profile `claim-vault` pins solc 0.8.23, optimizer 99999 and paris. Solar is
`forge test --profile claim-vault --use solar` from the repository root (109 passed, 9 fork
tests skipped without RPC). Solar emits different bytecode from solc. Solar 0.2
   codegen still changes that bytecode when `forge script`, `forge build` and `forge test`
   compile different file sets, so the redeploy address is whatever that `forge script`
   invocation prints. `packages/env` and `contracts/deployments.json` still name the solc
   deployments that are on chain.

## Original MFA customization (2026-09-23)

`MFA_AUTHORIZER` was `address public constant 0x3B14…DE7C` (Peanut's key). Now:

- It is a storage variable set by the constructor: `constructor(address _ecoAddress, address _mfaAuthorizer)`.
  A zero address is rejected. The deployer becomes `owner()`.
- The getter `MFA_AUTHORIZER() returns (address)` is unchanged. Its ABI `stateMutability` was
  already `view` upstream, because solc emits `view` for public constants too, so the diff tool
  reports it as identical.
- Rotation is two-step: `transferMFAAuthorizer(new)` (onlyOwner; `address(0)` cancels) then
  `acceptMFAAuthorizer()` called **by the new authorizer**. This proves key control before the
  switch. Old signatures die at acceptance.
- Owner is OpenZeppelin `Ownable2Step` (`transferOwnership` + `acceptOwnership`).
- Events: `MFAAuthorizerTransferStarted(prev, new)`, `MFAAuthorizerTransferred(prev, new)` (also
  emitted at construction), plus OZ `OwnershipTransferStarted` / `OwnershipTransferred`.

The owner's power is limited to choosing who can co-sign MFA withdrawals. It cannot move any
deposit: every withdrawal still needs the link-key signature, and sender reclaim still needs
`senderAddress`. Test: `test_ownerAndAuthorizer_cannotTakeFunds`. `renounceOwnership()` (OZ
default) would freeze rotation. The authorizer at that moment stays in force.

ABI delta against SDK v4.4 (`node abi/abi-diff.mjs abi/peanut-sdk-0.6.2-v4.4.abi.json abi/bufi-PeanutV4.4.abi.json`):

- the constructor gains `address _mfaAuthorizer` (deploy-time only; the SDK never deploys)
- added: `owner`, `pendingOwner`, `transferOwnership`, `acceptOwnership`, `renounceOwnership`,
  `pendingMFAAuthorizer`, `transferMFAAuthorizer`, `acceptMFAAuthorizer`, and the 4 events above
- nothing is removed or altered

## Build, test

```bash
forge build
forge test --no-match-path test/ArcTestnetFork.t.sol                # 69 unit tests incl. 3 fuzz (1024 runs each)
ARC_FORK=1 forge test --match-contract ArcTestnetFork -vv         # real Arc USDC facts (read-only)
node abi/abi-diff.mjs abi/peanut-sdk-0.6.2-v4.4.abi.json abi/bufi-PeanutV4.4.abi.json
```

Foundry cannot run a USDC transfer on an Arc fork. FiatToken at `0x3600…` calls Arc's native
precompiles (`0x1800…0001 isBlocklisted`, `0x1800…0000 transfer`), and revm does not implement
them. The unit suite etches a 6-dp ERC-20 at `0x3600…0000`. The live round trip is
`script/smoke-arc-testnet.mjs`, run with node/viem. `forge script` fails for the same precompile
reason, because it simulates locally before broadcasting.

## Post-Remediation Deployments (`spooky-contracts-prod-20261106`, 2026-11-07)

`ClaimVaultDeployer` deploys `PeanutV4` at `CREATE(ClaimVaultDeployer, 1)` and transfers ownership via `Ownable2Step` to the chain's Owner Safe. `PayrollBatch` is deployed via Arachnid CREATE2 pointing at that `PeanutV4` vault and canonical Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`).

| Contract | Arc Mainnet (`5042`) & Base Mainnet (`8453`) | Avalanche C-Chain (`43114`) & Arc Testnet (`5042002`) |
| --- | --- | --- |
| `ClaimVaultDeployer` | `0xE57695e4CE920eB24d80697c3369aE80fa275E6a` | `0x5BC58Ea1721A5976e68468b89019920b71C73CD5` |
| `PeanutV4` (MFA Claim Vault) | `0xeA06BF5AD08b70E4c107f3925CBC618662f88965` | `0x6bd53a40ff9b37543174553531C00C1c32E16B6b` |
| `PayrollBatch` | `0xE9b96103Ddc1268F1184667F4c3E85Da75340E10` | `0x60906130C29B3899b14b9EB04e8ca9F915Eb86E4` |
| `MFA_AUTHORIZER` (OTP attestor) | `0x9c8515333aFdB567C31CDF53CD60868f3B64b724` | `0x9c8515333aFdB567C31CDF53CD60868f3B64b724` |

Full execution receipts and block numbers live in [`../../deployments/addresses.json`](../../deployments/addresses.json) and [`../../deployments/live-receipts-2026-11-07.json`](../../deployments/live-receipts-2026-11-07.json).

## PayrollBatch

`src/payroll/PayrollBatch.sol` — public payroll in one transaction, for ANY ERC-20 (StableFX
tokens without EIP-3009 included). The treasury MSCA approves Permit2 once per token (a plain
`approve`, admitted by its AddressBook when Permit2 is allowlisted); per payroll the quorum
signs a Permit2 `PermitBatchWitnessTransferFrom` (ERC-1271 against the treasury) with
`spender = PayrollBatch` and witness:

```
WITNESS_TYPE_STRING = "PayrollWitness witness)PayrollWitness(bytes32 payrollId,bytes32 payrollHash)TokenPermissions(address token,uint256 amount)"
payrollHash = keccak256(abi.encode(chainId, PayrollBatch, payrollId, Payout[] payouts, ClaimDeposit[] claims))
witness     = keccak256(abi.encode(keccak256("PayrollWitness(bytes32 payrollId,bytes32 payrollHash)"), payrollId, payrollHash))
Payout       = (address token, address recipient, uint256 amount)
ClaimDeposit = (address token, address linkPubKey20, uint256 amount)
```

`payrollHash()` / `witnessOf()` are public views — the app should read them rather than
re-derive. `executePayroll(permit, treasury, signature, payrollId, payouts, claims)` then pulls
exactly the permitted amounts (balance-delta checked: fee-on-transfer reverts), pays every
payout, deposits each claim into the vault as an MFA bearer link with reclaimer = treasury and
`reclaimableAfter = now + 30 days`, and reverts on any net retention. One execution per
(treasury, payrollId) on top of the Permit2 nonce. Per-token permitted amount must equal the
sum of its lines; tokens must be unique; zero link keys, zero amounts, and recipients 0 /
PayrollBatch / vault are rejected. Max 100 lines.

Gas (forge): 50 payouts + 10 claims ≈ 3.34M.

Tests: `test/PayrollBatch.t.sol`, 15 cases against the REAL Permit2 runtime etched from Arc
testnet (mixed 6/18dp tokens, no-return token, fee-on-transfer reverts, tampered recipient /
payrollId / signer revert, replay, permitted≠owed, duplicate/unknown token, donation does not
block, claim needs link+OTP, treasury refund only after 30 days).

Integration notes: the treasury cannot cancel a signed Permit2 nonce (its AddressBook blocks
the cancel call) — keep permit deadlines short. Circle's MSCA `isValidSignature` may expect a
replay-safe wrapped hash; prove it live before relying on it.
