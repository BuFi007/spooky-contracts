// Reference implementation of the two claim signatures for the BUFI fork of PeanutV4.4.
// Spec: ../SIGNATURES.md. Pure viem; no Peanut SDK needed.
import { encodePacked, keccak256, toBytes, zeroHash } from 'viem';

export const PEANUT_SALT = '0x70adbbeba9d4f0c82e28dd574f15466f75df0543b65f24460fc445813b5d94e0'; // keccak256("Konrad makes tokens go woosh tadam")
export const ANYONE_WITHDRAWAL_MODE = zeroHash;
export const RECIPIENT_WITHDRAWAL_MODE = '0x2bb5bef2b248d3edba501ad918c3ab524cce2aea54d4c914414e1c4401dc4ff4'; // keccak256("only recipient")

/** Inner hash the LINK key signs (then EIP-191 personal_sign). mode = ANYONE for withdrawDeposit/withdrawMFADeposit. */
export function linkInnerHash({ chainId, vault, depositIndex, recipient, mode = ANYONE_WITHDRAWAL_MODE }) {
  return keccak256(
    encodePacked(
      ['bytes32', 'uint256', 'address', 'uint256', 'address', 'bytes32'],
      [PEANUT_SALT, BigInt(chainId), vault, BigInt(depositIndex), recipient, mode],
    ),
  );
}

/** Inner hash the MFA_AUTHORIZER signs (then EIP-191 personal_sign). No mode word. */
export function mfaInnerHash({ chainId, vault, depositIndex, recipient }) {
  return keccak256(
    encodePacked(
      ['bytes32', 'uint256', 'address', 'uint256', 'address'],
      [PEANUT_SALT, BigInt(chainId), vault, BigInt(depositIndex), recipient],
    ),
  );
}

/** account = viem LocalAccount (privateKeyToAccount). Signs the 32 RAW bytes, not the hex string. */
export const signLinkClaim = (account, args) => account.signMessage({ message: { raw: toBytes(linkInnerHash(args)) } });
export const signMfa = (account, args) => account.signMessage({ message: { raw: toBytes(mfaInnerHash(args)) } });
