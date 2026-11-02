// Live round trip on Arc TESTNET against a deployed vault:
//   approve -> makeSelflessMFADeposit(0.01 USDC) -> verify both sigs with the contract's own
//   getSigner() -> withdrawMFADeposit.
// PRIVATE_KEY must be the vault's current MFA_AUTHORIZER (true while the placeholder = deployer).
// Why not `forge script`: forge simulates locally first and revm cannot execute Arc's USDC
// precompiles (0x1800…), so every USDC transfer "fails" in simulation. The RPC runs it fine.
//   PRIVATE_KEY=0x… VAULT=0x… node script/smoke-arc-testnet.mjs
import { createPublicClient, createWalletClient, http, parseAbi, parseEventLogs, hashMessage, toBytes } from 'viem';
import { privateKeyToAccount, generatePrivateKey } from 'viem/accounts';
import { defineChain } from 'viem';
import { linkInnerHash, mfaInnerHash, signLinkClaim, signMfa } from '../examples/claim-signatures.mjs';

const arcTestnet = defineChain({
  id: 5042002, name: 'Arc Testnet', nativeCurrency: { name: 'USDC', symbol: 'USDC', decimals: 18 },
  rpcUrls: { default: { http: [process.env.ARC_TESTNET_RPC ?? 'https://rpc.testnet.arc.network'] } },
});
const USDC = '0x3600000000000000000000000000000000000000'; // 6-dp ERC-20 interface
const AMOUNT = 10_000n; // 0.01 USDC
const vault = process.env.VAULT;
const me = privateKeyToAccount(process.env.PRIVATE_KEY);
const link = privateKeyToAccount(generatePrivateKey()); // throwaway link key

const abi = parseAbi([
  'function approve(address,uint256) returns (bool)',
  'function MFA_AUTHORIZER() view returns (address)',
  'function makeSelflessMFADeposit(address,uint8,uint256,uint256,address,address) payable returns (uint256)',
  'function withdrawMFADeposit(uint256,address,bytes,bytes) returns (bool)',
  'function getSigner(bytes32,bytes) pure returns (address)',
  'event DepositEvent(uint256 indexed _index, uint8 indexed _contractType, uint256 _amount, address indexed _senderAddress)',
  'event WithdrawEvent(uint256 indexed _index, uint8 indexed _contractType, uint256 _amount, address indexed _recipientAddress)',
]);
const pub = createPublicClient({ chain: arcTestnet, transport: http() });
const wal = createWalletClient({ chain: arcTestnet, transport: http(), account: me });
const send = async (label, req) => {
  const hash = await wal.writeContract(req);
  const rcpt = await pub.waitForTransactionReceipt({ hash });
  if (rcpt.status !== 'success') throw new Error(`${label} reverted: ${hash}`);
  console.log(`${label}: ${hash}`);
  return rcpt;
};

if ((await pub.readContract({ address: vault, abi, functionName: 'MFA_AUTHORIZER' })) !== me.address)
  throw new Error('PRIVATE_KEY is not the MFA authorizer');

await send('approve', { address: USDC, abi, functionName: 'approve', args: [vault, AMOUNT] });
const dep = await send('makeSelflessMFADeposit', {
  address: vault, abi, functionName: 'makeSelflessMFADeposit', args: [USDC, 1, AMOUNT, 0n, link.address, me.address],
});
const [{ args: { _index: depositIndex } }] = parseEventLogs({ abi, logs: dep.logs, eventName: 'DepositEvent' });

const claim = { chainId: arcTestnet.id, vault, depositIndex, recipient: me.address };
const linkSig = await signLinkClaim(link, claim);
const mfaSig = await signMfa(me, claim);
// Independent check against the contract's own recover:
const onchainLinkSigner = await pub.readContract({ address: vault, abi, functionName: 'getSigner', args: [hashMessage({ raw: toBytes(linkInnerHash(claim)) }), linkSig] });
const onchainMfaSigner = await pub.readContract({ address: vault, abi, functionName: 'getSigner', args: [hashMessage({ raw: toBytes(mfaInnerHash(claim)) }), mfaSig] });
if (onchainLinkSigner !== link.address || onchainMfaSigner !== me.address) throw new Error('digest mismatch vs contract');

const w = await send('withdrawMFADeposit', { address: vault, abi, functionName: 'withdrawMFADeposit', args: [depositIndex, me.address, linkSig, mfaSig] });
const [ev] = parseEventLogs({ abi, logs: w.logs, eventName: 'WithdrawEvent' });
console.log(JSON.stringify({ depositIndex: depositIndex.toString(), linkPubKey20: link.address, linkInner: linkInnerHash(claim), mfaInner: mfaInnerHash(claim), withdrawnTo: ev.args._recipientAddress, amount: ev.args._amount.toString() }, null, 2));
