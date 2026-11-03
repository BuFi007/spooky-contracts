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

## Deterministic EVM testnet deployment (2026-10-11)

`script/DeployTestnet.s.sol` deploys the vault and `PayrollBatch` at the SAME
address on every allowlisted testnet (Arachnid CREATE2; the vault is
`CREATE(ClaimVaultDeployer, 1)` so ownership can be handed over with
Ownable2Step). It reverts on any chain outside its allowlist, mainnets and
Polygon Amoy included (Amoy was dropped as a supported chain on 2026-10-11).

|                               |                                                                            |
| ----------------------------- | -------------------------------------------------------------------------- |
| Vault (PeanutV4 BUFI fork)    | `0xC2DDB11c6d105e10d46052E2D5CF983eC3a97Db4`                               |
| PayrollBatch                  | `0x2f64F18764f3A68faAa76d918cEB7cbF68495A9F`                               |
| ClaimVaultDeployer            | `0x39bab18441ddd046bd198d355842889f91d54e23`                               |
| owner                         | `0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474` — testnet deployer            |
| MFA_AUTHORIZER (OTP attestor) | `0x9c8515333aFdB567C31CDF53CD60868f3B64b724` — same attestor as Arc        |
| Live on                       | Avalanche Fuji, Base / Arbitrum / OP / Unichain Sepolia, Monad testnet     |
| Not on                        | Ethereum Sepolia (broadcast failed), Arc testnet (legacy deployment below) |

Read back on every chain 2026-10-11: `VAULT()` = vault, `PERMIT2()` = canonical,
`owner()` = deployer, `MFA_AUTHORIZER()` = attestor. Per-chain deploy txs are in
`contracts/deployments.json`; addresses are pinned in `packages/env/src/payroll-batch.ts`.

## Arc testnet deployment (chainId 5042002)

**Current (2026-10-08, includes the custody/receipt/ECO remediation):**

|                               |                                                                                                                        |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Vault (PeanutV4 BUFI fork)    | `0x07084cFC01B930091619c256A05E951aB52d6d53` — tx `0x2a5fe78438aadd438f44dd0a3f2dcf0848c387464f20624151c693d1d69efbcf` |
| PayrollBatch                  | `0x1d7436f5e2fAC61FbE38c8e875301059531539B0` — tx `0x0631e3bbb6570e299deea16e2ec546c856769965f2df0691dc899f4cc6de3495` |
| owner                         | `0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474` — testnet deployer                                                        |
| MFA_AUTHORIZER (OTP attestor) | `0x9c8515333aFdB567C31CDF53CD60868f3B64b724` — set at construction (same attestor DCW as below; no rotation needed)    |
| Checked on-chain              | runtime == local build (metadata stripped); `VAULT()` = vault, `PERMIT2()` = canonical, `CLAIM_WINDOW()` = 2592000     |

Deployed via `https://rpc.drpc.testnet.arc.network` (the public RPC 403s some IPs).

**Superseded (2026-09-23, includes change 2 — reclaim window enforced for every deposit; pre-remediation).**
It still held two unclaimed testnet deposits (indexes 0 and 1, 0.5 and 0.3 USDC) at the switch;
their senders reclaim on-chain after the window.

|                               |                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Vault (PeanutV4 BUFI fork)    | `0xb96Cc197F4b15DA762e4c34E1413CECa57FaC4fC` — tx `0x9f645693532af4ffa2c1cd982113b1cfca93054f207daaeb68af1194c82334f8`                                                                                                                                                                                                                                                                                                                                                                                                                    |
| PayrollBatch                  | `0x8f4e4d47C0D4F8bF3AAeAcC31C9Cd425476B30C5` — tx `0x1d4baa042e82220c338704c124e1258b81a9590d5e13e9822e1e29fa767d68a2`                                                                                                                                                                                                                                                                                                                                                                                                                    |
| Permit2 (canonical)           | `0x000000000022D473030F116dDEE9F6B43aC78BA3`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| owner                         | `0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474` — testnet deployer                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| MFA_AUTHORIZER (OTP attestor) | `0x9c8515333aFdB567C31CDF53CD60868f3B64b724` — dedicated Circle DCW **EOA** (ARC-TESTNET, sandbox entity, wallet id `ab2908f2-ca85-5457-ae25-cd85d8af66b2`). Rotated two-step 2026-09-23: propose `0x697672b1b2d46b31ab3b3f86b065c1b179498f57e6900d241b99836f6a1a8095`, accept from the DCW `0x67c2740e98caa9238f2d1ce672f57e30589a30ceae93cf32f81cab55189a251f`. Circle `signMessage({ encodedByHex: true })` over the 32-byte MFA inner hash yields the 65-byte EIP-191 signature the vault verifies. Never sign anything else with it. |
| Checked on-chain              | code present; `PayrollBatch.VAULT()` = vault, `PERMIT2()` = canonical, `CLAIM_WINDOW()` = 2592000                                                                                                                                                                                                                                                                                                                                                                                                                                         |

The first deployment below (`0xa7E5…f220`) predates change 2 — a bearer link there is
reclaimable immediately. **Superseded; do not use.**

### Superseded first deployment

|                                       |                                                                                                                                                                                                                                                     |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Vault                                 | `0xa7E5D40A29C350038D676744283426386Ccdf220`                                                                                                                                                                                                        |
| Deploy tx                             | `0xfa64a45a39f1384af8bf4e3842ea504f116904c6e6c87314bfc8acd7a6dcae36` (block 63656574, 4,414,219 gas)                                                                                                                                                |
| owner / MFA_AUTHORIZER                | `0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474`. This is the testnet deployer, a **placeholder** to rotate to the OTP attestor                                                                                                                         |
| ecoAddress                            | `0x0000000000000000000000000000000000000000`                                                                                                                                                                                                        |
| On-chain runtime == local build       | yes (compared byte-for-byte)                                                                                                                                                                                                                        |
| Smoke (0.01 USDC MFA deposit → claim) | approve `0xf690529375af5d7ec23fd33e625b5b82c7a30c78afebb85f49e244f313004e06`, deposit `0x0bf023f0746b7d18bccfd33f576b5b9cb4dfbf5c0bf22a9d05551a130e10faa1`, withdrawMFADeposit `0xf7b48f14a7e5bbf243f3bf1eff151059bd48af4885eec3eeb373ac58c52d8ddf` |

Explorer: https://testnet.arcscan.app/address/0xa7E5D40A29C350038D676744283426386Ccdf220
(it redirects to `explorer.testnet.arc.io`). Source verification is still to do. On 2026-09-23
the explorer's indexer was about 23k blocks behind the chain and did not yet know the contract.
Retry once it catches up:

```bash
forge verify-contract 0xa7E5D40A29C350038D676744283426386Ccdf220 src/V4/PeanutV4.4.sol:PeanutV4 \
  --chain-id 5042002 --verifier blockscout --verifier-url 'https://explorer.testnet.arc.io/api/' \
  --constructor-args $(cast abi-encode "c(address,address)" 0x0000000000000000000000000000000000000000 0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474)
```

To rotate to the OTP attestor, do both steps on-chain:

```bash
cast send $VAULT "transferMFAAuthorizer(address)" $ATTESTOR --private-key $OWNER_KEY --rpc-url arc_testnet
cast send $VAULT "acceptMFAAuthorizer()" --private-key $ATTESTOR_KEY --rpc-url arc_testnet   # attestor needs gas (USDC)
```

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
