# Claim signatures: the exact spec for `withdrawMFADeposit`

This covers `src/V4/PeanutV4.4.sol`, BUFI's fork of PeanutV4.4. A claim on an MFA deposit needs two
65-byte ECDSA signatures, passed to:

```solidity
function withdrawMFADeposit(
    uint256 _index,            // deposit index (from DepositEvent._index / makeXxxDeposit return value)
    address _recipientAddress, // who receives the funds; anyone may submit the tx
    bytes   _signature,        // LINK key signature (below, §1)
    bytes   _MFASignature      // MFA_AUTHORIZER signature (below, §2)
) returns (bool)
```

Both signatures use the same scheme: **EIP-191 `personal_sign` over a 32-byte inner hash**. The inner
hash is `keccak256` of a **tightly packed** (`abi.encodePacked`) tuple. The signer signs the 32 raw
bytes. Do not sign the 66-character hex string.

```
digest = keccak256( 0x19 || "Ethereum Signed Message:\n32" || innerHash )   // viem: hashMessage({ raw: innerHash })
```

The contract checks signatures with OpenZeppelin 4.9.2 `ECDSA.recover`:

- a signature is exactly 65 bytes, `r || s || v`, with `v ∈ {27, 28}`
- `s` must be in the lower half-order (high-s signatures are rejected)
- the recovered address must not be `address(0)`
- EIP-2098 64-byte compact signatures are **rejected** (`ECDSA: invalid signature length`). OZ 4.9.2
  accepts only 65-byte signatures in the `bytes` overload.

Only EOA signatures work for both digests. The contract uses `ECDSA.recover`, not ERC-1271, so the
MFA authorizer **must be an EOA key**: a KMS/HSM secp256k1 key is fine, a smart account is not.

## Constants

| Name                        | Value                                                                                                                    |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `PEANUT_SALT`               | `0x70adbbeba9d4f0c82e28dd574f15466f75df0543b65f24460fc445813b5d94e0` = `keccak256("Konrad makes tokens go woosh tadam")` |
| `ANYONE_WITHDRAWAL_MODE`    | `0x0000000000000000000000000000000000000000000000000000000000000000`                                                     |
| `RECIPIENT_WITHDRAWAL_MODE` | `0x2bb5bef2b248d3edba501ad918c3ab524cce2aea54d4c914414e1c4401dc4ff4` = `keccak256("only recipient")`                     |

## §1 The LINK key signature (`_signature`)

The signer is the link private key. Its address (the last 20 bytes of `keccak256(pubkey)`) is the
`_pubKey20` stored at deposit time.

```
innerHash_link = keccak256(abi.encodePacked(
    bytes32 PEANUT_SALT,        // 32 bytes
    uint256 block.chainid,      // 32 bytes  (Arc testnet: 5042002 = 0x4cef52)
    address vault,              // 20 bytes  (address(this) — the vault contract)
    uint256 _index,             // 32 bytes
    address _recipientAddress,  // 20 bytes
    bytes32 mode                // 32 bytes  ANYONE_WITHDRAWAL_MODE (0x00…00) for withdrawMFADeposit
))                              // = 168 packed bytes
```

- `withdrawMFADeposit` and `withdrawDeposit` always use `mode = ANYONE_WITHDRAWAL_MODE` (32 zero bytes).
- `withdrawDepositAsRecipient` uses `RECIPIENT_WITHDRAWAL_MODE`. That path **cannot** claim an MFA
  deposit: it always reverts with `REQUIRES AUTHORIZATION`.
- An empty `_signature` passes only when the deposit's `pubKey20 == address(0)` (see finding F-2).
  Never create a deposit with a zero `pubKey20`.

This matches `@squirrel-labs/peanut-sdk` 0.6.x `signWithdrawalMessage` for v4.2+: it uses ethers v5
`solidityKeccak256([bytes32,uint256,address,uint256,address,bytes32], …)`, then
`wallet.signMessage(arrayify(hash))`.

## §2 The MFA_AUTHORIZER signature (`_MFASignature`), which BUFI's OTP server signs

The signer is the key whose address equals `MFA_AUTHORIZER()` **at the time the withdrawal
executes**.

```
innerHash_mfa = keccak256(abi.encodePacked(
    bytes32 PEANUT_SALT,        // 32 bytes
    uint256 block.chainid,      // 32 bytes
    address vault,              // 20 bytes
    uint256 _index,             // 32 bytes
    address _recipientAddress   // 20 bytes
))                              // = 136 packed bytes. There is NO trailing mode word.
```

What this binding means for the OTP server:

- **Bound:** chain, vault contract, deposit index, recipient. A signature for recipient A cannot
  pay B. A signature for index i cannot unlock index j, including another deposit made with the
  same link key. A signature for the testnet vault is useless on mainnet or on another vault.
  Tests: `test_recipientBinding_*`, `testFuzz_*`, `test_replay_cross*`.
- **Not bound:** amount, token, expiry, nonce, or the link signature. The MFA signature stays valid
  until one of two things happens: (a) the deposit is claimed or reclaimed (`claimed = true`, then
  `DEPOSIT ALREADY WITHDRAWN`), or (b) the authorizer is rotated. The OTP server is the only place
  to enforce "OTP verified within N minutes". Sign only after the OTP passes, and sign exactly
  `(chainId, vault, index, recipient)` for the recipient the claimant proved. See F-5.
- The MFA signature alone moves nothing. The link signature must also recover to `pubKey20`.
  Test: `test_authorizerAlone_cannotWithdraw`.
- Domain separation: the MFA preimage is 136 bytes and the link preimage is 168 bytes, so one can
  never be read as the other. Both are plain `personal_sign` messages, though. The authorizer key
  **must be dedicated to this vault** and must never sign arbitrary `personal_sign` payloads for
  any other purpose (F-6).

## Worked example: the real transactions on Arc testnet

Vault `0xa7E5D40A29C350038D676744283426386Ccdf220`, chainId `5042002`, deposit index `0`,
recipient `0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474`. These values come from
`script/smoke-arc-testnet.mjs`. The contract's own `getSigner()` recovered the expected signers,
and `withdrawMFADeposit` then succeeded in tx
`0xf7b48f14a7e5bbf243f3bf1eff151059bd48af4885eec3eeb373ac58c52d8ddf`.

```
link packed (168 B) = 70adbbeba9d4f0c82e28dd574f15466f75df0543b65f24460fc445813b5d94e0   PEANUT_SALT
                      00000000000000000000000000000000000000000000000000000000004cef52   chainId 5042002
                      a7e5d40a29c350038d676744283426386ccdf220                           vault
                      0000000000000000000000000000000000000000000000000000000000000000   index 0
                      09ce8e2b3fede2727da4392ea8fe618305ba0474                           recipient
                      0000000000000000000000000000000000000000000000000000000000000000   ANYONE mode
innerHash_link      = 0xd9f7d4348b2bb2c3487ab8b6c4aecb23d2cf902116ac06b975f03cb823644131
EIP-191 digest      = 0x4758a1ad6069228b93dea1989c286f6fc7d0dc6b6a20c6612d4cf041fc25a93e

mfa packed (136 B)  = the first five fields above, with no mode word
innerHash_mfa       = 0x99cbfc919d8090788f02e40a2962ade88659c9a97c9c5021adb8926447a4aa53
EIP-191 digest      = 0x352fd2dbab8a69132b1d5a7f79c174ba9297ff1c937c94ece60684303ba7d4c6
```

Correction (2026-09-23): the two `EIP-191 digest` lines originally printed here
(`0xc1776d36…d419`, `0x147d8c81…10eb`) were `cast hash-message` of the 66-character hex
STRING (`\n66` prefix), i.e. exactly what this document says never to sign. The values above
are `keccak256("\x19Ethereum Signed Message:\n32" ‖ innerHash)`, which is what
`ECDSA.toEthSignedMessageHash(bytes32)` computes. Proven against the real withdrawal: the MFA
signature in tx `0xf7b48f14…8ddf` recovers to the then-authorizer `0x09Ce…0474` only over
`0x352fd2db…d4c6`. The inner hashes were always right. Pinned by
`packages/transfer-core/src/claim-link.test.ts`.

Three independent implementations agree on these hashes: the Solidity test helper
(`test/utils/ClaimSigs.sol`), viem (`examples/claim-signatures.mjs`), and `cast abi-encode --packed`.

## TypeScript (viem 2.x)

Runnable copy: `examples/claim-signatures.mjs`.

```ts
import {
  encodePacked,
  keccak256,
  toBytes,
  hashMessage,
  zeroHash,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const PEANUT_SALT: Hex = '0x70adbbeba9d4f0c82e28dd574f15466f75df0543b65f24460fc445813b5d94e0';

type Claim = { chainId: number; vault: Address; depositIndex: bigint; recipient: Address };

// §1 — signed by the LINK key (from the claim link's secret)
export const linkInnerHash = (c: Claim): Hex =>
  keccak256(
    encodePacked(
      ['bytes32', 'uint256', 'address', 'uint256', 'address', 'bytes32'],
      [PEANUT_SALT, BigInt(c.chainId), c.vault, c.depositIndex, c.recipient, zeroHash]
    )
  );

// §2 — signed by BUFI's OTP attestor (== vault.MFA_AUTHORIZER())
export const mfaInnerHash = (c: Claim): Hex =>
  keccak256(
    encodePacked(
      ['bytes32', 'uint256', 'address', 'uint256', 'address'],
      [PEANUT_SALT, BigInt(c.chainId), c.vault, c.depositIndex, c.recipient]
    )
  );

const claim: Claim = {
  chainId: 5042002,
  vault: '0xa7E5D40A29C350038D676744283426386Ccdf220',
  depositIndex: 0n,
  recipient: '0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474',
};
// linkInnerHash(claim) === '0xd9f7d4348b2bb2c3487ab8b6c4aecb23d2cf902116ac06b975f03cb823644131'
// mfaInnerHash(claim)  === '0x99cbfc919d8090788f02e40a2962ade88659c9a97c9c5021adb8926447a4aa53'
// hashMessage({ raw: toBytes(mfaInnerHash(claim)) }) === '0x352fd2dbab8a69132b1d5a7f79c174ba9297ff1c937c94ece60684303ba7d4c6'

const attestor = privateKeyToAccount(process.env.MFA_AUTHORIZER_KEY as Hex); // KMS in prod
const mfaSig = await attestor.signMessage({ message: { raw: toBytes(mfaInnerHash(claim)) } }); // raw BYTES
// For a KMS that signs raw digests: sign hashMessage({ raw: toBytes(mfaInnerHash(claim)) }),
// then output r||s||v with v = 27|28 and low-s (normalize s if the KMS does not).
```

## Gasless reclaim (EIP-712, for completeness)

`withdrawDepositSenderGasless(GaslessReclaim{depositIndex}, signer, signature)` checks an EIP-712
signature from the deposit's `senderAddress`. The check uses OZ `SignatureChecker`, so **this** path
does accept ERC-1271 smart accounts such as a treasury MSCA. The domain is
`EIP712Domain(name "Peanut", version "4.2", chainId, verifyingContract = vault)`. The version string
really is `"4.2"` upstream. The type is `GaslessReclaim(uint256 depositIndex)`.

## Custom gasless deposits: custody commitment (2026-10-08)

The hardened `makeCustomDeposit(..., true, args3009)` requires a new nonce format.
This is a **fresh-deployment change**, not an upgrade of the published immutable vaults.
Existing approval deposits, claim signatures, gasless reclaims and the simple
`makeDepositWithAuthorization` ABI/nonce format remain compatible.

All the following encodings use **standard `abi.encode`**, not packed encoding:

```text
custodyHash = keccak256(abi.encode(
    uint256 tokenId, address pubKey20, address onBehalfOf,
    bool withMFA, address recipient, uint40 reclaimableAfter
))
context = keccak256(abi.encode(
    bytes32 keccak256("BUFI.CustomDepositAuthorization.v1"),
    uint256 chainId, address vault, address tokenAddress,
    uint8 contractType, uint256 amount, bytes32 custodyHash
))
authorizationNonce = keccak256(abi.encode(bytes32 context, bytes32 rawNonce))
```

Sign the token's `ReceiveWithAuthorization(from, to, value, validAfter, validBefore, nonce)`
EIP-712 message using `nonce = authorizationNonce`, `from = onBehalfOf`, `to = vault`,
and `value = amount`. Use the token's own EIP-712 domain. The contract only allows
`contractType = 1`, rejects the configured ECO token in this path, and reconstructs
the commitment before invoking the token.

Pass the **rawNonce** into `_args3009`:
`abi.encode(from, rawNonce, validAfter, validBefore, v, r, s)`. Use a fresh 32-byte
random raw nonce for each deposit. A relayer may submit the exact signed intent,
but changing any custody field, chain, vault, token, amount or raw nonce invalidates
the signature. The simple entry point still reconstructs the SDK's legacy
`keccak256(abi.encodePacked(pubKey20, rawNonce))`, so it cannot consume a custom
authorization to strip its recipient/MFA/reclaim restrictions. Legacy custom
authorizations are intentionally rejected by the new custom path.

Client helper: `@bu/transfer-core/custom-deposit-authorization` exports
`customDepositAuthorizationNonce(intent)`. Switch custom signing clients and the
configured vault address together only after deploying and verifying the new vault.
The existing published deployment addresses do **not** receive this source fix.

The cross-language test vector uses chain `5042002`, vault `0x1111…1111`, token
`0x2222…2222`, amount `100000000`, tokenId `7`, pubKey20 `0x3333…3333`, onBehalfOf
`0x4444…4444`, withMFA `true`, recipient `0x5555…5555`, reclaimableAfter `2592000`,
and rawNonce `bytes32(uint256(123))`. Each abbreviated address repeats its digit
for all 40 hex characters. The resulting authorization nonce is
`0x9937293113ce5bd424d564283ebd2eaa02b6ffede7a47808f32eb065984ce23d`.
It is pinned independently in Solidity and TypeScript tests.
