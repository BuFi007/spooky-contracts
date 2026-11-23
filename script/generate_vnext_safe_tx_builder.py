#!/usr/bin/env python3
"""Generate vNext BugPoCer Safe Transaction Builder batches from canonical solc artifacts.

Writes exclusively to `deployments/safe-tx-builder/vnext-bugpocer/` so historical
Nov 7 live manifests (`deployments/addresses.json`, `deployments/bytecode-hashes.json`,
`deployments/live-receipts-2026-11-07.json`, and `deployments/safe-tx-builder/MANIFEST.json`)
remain untouched.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path

SPOOKY_ROOT = Path(__file__).resolve().parents[1]
OUT_ROOT = SPOOKY_ROOT / "out"
VNEXT_DIR = SPOOKY_ROOT / "deployments" / "safe-tx-builder" / "vnext-bugpocer"

EIP170_LIMIT = 24_576
CREATED_AT_MS = 1795392000000  # 2026-11-23T00:00:00Z

# Shared canonical infrastructure
ARACHNID_CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C"
PERMIT2_CANONICAL = "0x000000000022D473030F116dDEE9F6B43aC78BA3"
COLD_STORAGE_ADDRESS_BOOK = "0x0000000d81083B16EA76dfab46B0315B0eDBF3d0"

# Chain Safes
SAFE_ARC_MAINNET = "0x47Dc7D18A6E3a79F696714E7D47456a49B430D09"
SAFE_AVALANCHE_AND_TESTNET = "0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B"

# Live Nov 7 Arc Mainnet (5042) addresses referenced by hotfix or reused unchanged
LIVE_ARC_5042_IDENTITY_REGISTRY = "0x6730b8f3FF0eF85E097Af01eC8a3e450d30e466d"
LIVE_ARC_5042_REPUTATION_REGISTRY = "0x2D7125b1cf826bE4ad6D0b043F6B4675897EB2e9"
LIVE_ARC_5042_INVOICE_SHELF = "0x90eCDd402C0E357362b7805173191A153b876DF4"

# Verified canonical tokens per chain
ARC_USDC = "0x3600000000000000000000000000000000000000"
ARC_MAINNET_EURC = "0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1"
ARC_TESTNET_EURC = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a"
AVAX_USDC = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E"
AVAX_EURC = "0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD"
BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

# Circle CCTP V2 & CCTPx contracts and token IDs
CCTP_MAINNET_TOKEN_MESSENGER = "0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d"
CCTPX_MAINNET_SERVICE = "0x431871229103b780868f8C6BB820cd16ECf942BC"
CCTPX_EURC_MAINNET_TOKEN_ID = "0x6ca9e29fa53becc29becaf4a90b9ca7a995ad4d2234880da13ca38c657fb241c"

CCTP_TESTNET_TOKEN_MESSENGER = "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA"
CCTPX_TESTNET_SERVICE = "0x63753E722bd2C2A5DF6EE19C5106662208B81077"
CCTPX_EURC_TESTNET_TOKEN_ID = "0x2587821a0ee7daa174b95436b5dab1731cfa1844775b010217d3c0dd02a4eecd"

# Arc Mainnet (5042) venues and vaults
ARC_LIFI_DIAMOND = "0xA4072583658Fae592A3506A42431cb6316a8d40b"
ARC_UNISWAP_ROUTER = "0x8702463e73f74d0b6765aBceb314Ef07aCb92650"
ARC_UNISWAP_NO_PERMIT2_PROXY = "0x0000000085E102724e78eCd2F45DC9cA239Affad"
ARC_MORPHO_BITWISE_PAPY = "0x7610094B846657dCF166D59e42973db52c7015F9"
ARC_MORPHO_STEAKHOUSE_USDC = "0xbeef0016cb2Fd5C352ea7CA08a9f54739DFa7298"

# Arc Testnet (5042002) venues and vaults
ARC_TESTNET_CIRCLE_ADAPTER = "0xBBD70b01a1CAbc96d5b7b129Ae1AAabdf50dd40b"
ARC_TESTNET_LIFI_DIAMOND = "0xFf70F4A1d11995621854F3692acF286d8aCd04b2"
ARC_TESTNET_USDC_VAULT = "0x0a9a082C24364B90B73e20E57d7625A3aa798bCa"

# Avalanche C-Chain (43114) venues
AVAX_LIFI_DIAMOND = "0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE"
AVAX_UNISWAP_UNIVERSAL_ROUTER = "0x661E93cca42AfacB172121EF892830cA3b70F08d"
AVAX_UNISWAP_SWAP_ROUTER_02 = "0xbb00FF08d01D300023C629E8fFfFcb65A5a578cE"
AVAX_UNISWAP_NO_PERMIT2_PROXY = "0x0000000085E102724e78eCd2F45DC9cA239Affad"

# Operational EOAs
CLAIM_VAULT_MFA_AUTHORIZER = "0x9c8515333aFdB567C31CDF53CD60868f3B64b724"
TELARANA_KEEPER_EOA = "0xcA02Be6cDBb806d4a327FC92E094D1A44EC37445"

SALT_SUFFIX = ".bugpocer.vnext"

RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]

ROT = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
]


def _rol64(val: int, shift: int) -> int:
    return ((val << shift) | (val >> (64 - shift))) & 0xFFFFFFFFFFFFFFFF


def keccak256(data: bytes) -> bytes:
    rate = 136
    state = [0] * 25
    padded = bytearray(data)
    padded.append(0x01)
    while len(padded) % rate != 0:
        padded.append(0x00)
    padded[-1] |= 0x80

    for offset in range(0, len(padded), rate):
        for i in range(rate // 8):
            lane = int.from_bytes(padded[offset + 8 * i : offset + 8 * (i + 1)], "little")
            state[i] ^= lane
        for rnd in range(24):
            c = [state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] for x in range(5)]
            d = [c[(x - 1) % 5] ^ _rol64(c[(x + 1) % 5], 1) for x in range(5)]
            for x in range(5):
                for y in range(5):
                    state[x + 5 * y] ^= d[x]
            b = [0] * 25
            for x in range(5):
                for y in range(5):
                    b[y + 5 * ((2 * x + 3 * y) % 5)] = _rol64(state[x + 5 * y], ROT[x][y])
            for x in range(5):
                for y in range(5):
                    state[x + 5 * y] = b[x + 5 * y] ^ ((~b[(x + 1) % 5 + 5 * y]) & b[(x + 2) % 5 + 5 * y])
            state[0] ^= RC[rnd]

    out = bytearray()
    for i in range(4):
        out.extend(state[i].to_bytes(8, "little"))
    return bytes(out)


def keccak256_hex(data: bytes) -> str:
    return "0x" + keccak256(data).hex()


def sha256_hex(data: bytes) -> str:
    return "0x" + hashlib.sha256(data).hexdigest()


def to_checksum_address(addr: str) -> str:
    clean = addr.lower().removeprefix("0x")
    assert len(clean) == 40, f"Invalid address: {addr}"
    digest = keccak256(clean.encode("ascii")).hex()
    out = ["0x"]
    for ch, dh in zip(clean, digest):
        out.append(ch.upper() if ch in "abcdef" and int(dh, 16) >= 8 else ch)
    return "".join(out)


def compute_create2_address(salt_hex: str, initcode_hex: str, deployer: str = ARACHNID_CREATE2_FACTORY) -> str:
    deployer_bytes = bytes.fromhex(deployer.removeprefix("0x"))
    salt_bytes = bytes.fromhex(salt_hex.removeprefix("0x"))
    initcode_bytes = bytes.fromhex(initcode_hex.removeprefix("0x"))
    assert len(salt_bytes) == 32
    raw = keccak256(b"\xff" + deployer_bytes + salt_bytes + keccak256(initcode_bytes))
    return to_checksum_address("0x" + raw[-20:].hex())


def compute_create_address(deployer: str, nonce: int) -> str:
    deployer_bytes = bytes.fromhex(deployer.removeprefix("0x"))
    assert len(deployer_bytes) == 20
    if nonce == 0:
        nonce_rlp = b"\x80"
    elif nonce < 0x80:
        nonce_rlp = bytes([nonce])
    else:
        nb = nonce.to_bytes((nonce.bit_length() + 7) // 8, "big")
        nonce_rlp = bytes([0x80 + len(nb)]) + nb
    payload = b"\x94" + deployer_bytes + nonce_rlp
    rlp = bytes([0xC0 + len(payload)]) + payload
    return to_checksum_address("0x" + keccak256(rlp)[-20:].hex())


def cast_abi_encode(sig: str, *args: str) -> str:
    res = subprocess.run(["cast", "abi-encode", sig, *args], capture_output=True, text=True, check=True)
    return res.stdout.strip().removeprefix("0x")


def cast_calldata(sig: str, *args: str) -> str:
    res = subprocess.run(["cast", "calldata", sig, *args], capture_output=True, text=True, check=True)
    return res.stdout.strip()


def load_artifact(rel_path: str) -> dict:
    full = OUT_ROOT / rel_path
    assert full.exists(), f"Missing canonical solc artifact: {full}. Run rm -rf out && ./script/build-all.sh first."
    data = json.loads(full.read_text(encoding="utf-8"))
    bc = data["bytecode"]["object"].removeprefix("0x")
    dbc = data["deployedBytecode"]["object"].removeprefix("0x")
    bc_bytes = bytes.fromhex(bc)
    dbc_bytes = bytes.fromhex(dbc)
    assert 0 < len(dbc_bytes) <= EIP170_LIMIT, (
        f"Artifact {rel_path} runtime size {len(dbc_bytes)} exceeds EIP-170 ({EIP170_LIMIT})"
    )
    compiler_ver = data.get("metadata", {}).get("compiler", {}).get("version", "unknown")
    assert "solar" not in compiler_ver.lower(), f"Expected canonical solc artifact, got {compiler_ver} for {rel_path}"
    return {
        "rel_path": rel_path,
        "compiler": compiler_ver,
        "initcode_hex": "0x" + bc,
        "runtime_hex": "0x" + dbc,
        "initcode_size": len(bc_bytes),
        "runtime_size": len(dbc_bytes),
        "initcode_keccak256": keccak256_hex(bc_bytes),
        "initcode_sha256": sha256_hex(bc_bytes),
        "runtime_keccak256": keccak256_hex(dbc_bytes),
        "runtime_sha256": sha256_hex(dbc_bytes),
    }


def salt_of(base_label: str) -> tuple[str, str]:
    label = base_label + SALT_SUFFIX
    return label, keccak256_hex(label.encode("utf-8"))


def make_create2_tx(label: str, salt_pair: tuple[str, str], initcode_hex: str) -> tuple[dict, str]:
    salt_label, salt_hex = salt_pair
    predicted = compute_create2_address(salt_hex, initcode_hex)
    data = "0x" + salt_hex.removeprefix("0x") + initcode_hex.removeprefix("0x")
    tx = {
        "to": ARACHNID_CREATE2_FACTORY,
        "value": "0",
        "data": data,
        "contractMethod": None,
        "contractInputsValues": None,
        "meta": {
            "label": label,
            "deploymentKind": "CREATE2",
            "saltLabel": salt_label,
            "salt": salt_hex,
            "predictedAddress": predicted,
            "initcodeKeccak256": keccak256_hex(bytes.fromhex(initcode_hex.removeprefix("0x"))),
        },
    }
    return tx, predicted


def make_call_tx(
    to_addr: str,
    label: str,
    fn_name: str,
    inputs: list[tuple[str, str, str]],
    sig: str,
    call_args: list[str],
) -> dict:
    calldata = cast_calldata(sig, *call_args)
    return {
        "to": to_checksum_address(to_addr),
        "value": "0",
        "data": calldata,
        "contractMethod": {
            "inputs": [{"internalType": t, "name": n, "type": t} for (n, t, _) in inputs],
            "name": fn_name,
            "payable": False,
        },
        "contractInputsValues": {n: val for (n, _, val) in inputs},
        "meta": {
            "label": label,
        },
    }


def tx_set_token(addr: str, contract_label: str, token_label: str, token_addr: str) -> dict:
    return make_call_tx(
        addr,
        f"{contract_label}.setToken({token_label}, true)",
        "setToken",
        [("token", "address", to_checksum_address(token_addr)), ("allowed", "bool", "true")],
        "setToken(address,bool)",
        [to_checksum_address(token_addr), "true"],
    )


def tx_set_target(addr: str, contract_label: str, target_label: str, target_addr: str) -> dict:
    return make_call_tx(
        addr,
        f"{contract_label}.setTarget({target_label}, true)",
        "setTarget",
        [("target", "address", to_checksum_address(target_addr)), ("allowed", "bool", "true")],
        "setTarget(address,bool)",
        [to_checksum_address(target_addr), "true"],
    )


def tx_set_permit2_route(
    addr: str,
    contract_label: str,
    target_label: str,
    target_addr: str,
    allowance_addr: str | None = None,
) -> dict:
    t = to_checksum_address(target_addr)
    a = to_checksum_address(allowance_addr or target_addr)
    return make_call_tx(
        addr,
        f"{contract_label}.setPermit2Route({target_label}, {target_label}, true)",
        "setPermit2Route",
        [("target", "address", t), ("allowanceTarget", "address", a), ("allowed", "bool", "true")],
        "setPermit2Route(address,address,bool)",
        [t, a, "true"],
    )


def tx_set_bridge(addr: str, contract_label: str, kind: int, kind_label: str, bridge_addr: str) -> dict:
    b = to_checksum_address(bridge_addr)
    return make_call_tx(
        addr,
        f"{contract_label}.setBridge({kind_label}={kind}, {b}, true)",
        "setBridge",
        [("kind", "uint8", str(kind)), ("bridge", "address", b), ("allowed", "bool", "true")],
        "setBridge(uint8,address,bool)",
        [str(kind), b, "true"],
    )


def tx_set_cctpx_token(addr: str, contract_label: str, token_label: str, token_id: str, token_addr: str) -> dict:
    t = to_checksum_address(token_addr)
    assert t.lower() != ARC_USDC.lower(), "NEVER bind ARC_NATIVE_USDC (0x3600...) to CCTPx"
    return make_call_tx(
        addr,
        f"{contract_label}.setCctpxToken({token_label}, {t})",
        "setCctpxToken",
        [("tokenId", "bytes32", token_id), ("token", "address", t)],
        "setCctpxToken(bytes32,address)",
        [token_id, t],
    )


def tx_grant_role(addr: str, contract_label: str, role_name: str, role_hash: str, account_label: str, account: str) -> dict:
    acc = to_checksum_address(account)
    return make_call_tx(
        addr,
        f"{contract_label}.grantRole({role_name}, {account_label})",
        "grantRole",
        [("role", "bytes32", role_hash), ("account", "address", acc)],
        "grantRole(bytes32,address)",
        [role_hash, acc],
    )


def build_safe_batch(
    chain_id: str,
    safe_address: str,
    name: str,
    description: str,
    transactions: list[dict],
) -> dict:
    payload = {
        "version": "1.0",
        "chainId": str(chain_id),
        "createdAt": CREATED_AT_MS,
        "meta": {
            "name": name,
            "description": description,
            "txBuilderVersion": "1.16.5",
            "createdFromSafeAddress": to_checksum_address(safe_address),
            "createdFromOwnerAddress": "",
        },
        "transactions": transactions,
    }
    serialized = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    payload["meta"]["checksum"] = keccak256_hex(serialized)
    return payload


def main() -> None:
    assert keccak256_hex(b"") == "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"

    arts = {
        "TreasuryConduit": load_artifact("treasury/TreasuryConduit.sol/TreasuryConduit.json"),
        "TreasuryConduitPermit2": load_artifact("treasury/TreasuryConduitPermit2.sol/TreasuryConduitPermit2.json"),
        "TreasuryBridgeConduitV2": load_artifact("treasury/TreasuryBridgeConduitV2.sol/TreasuryBridgeConduitV2.json"),
        "TreasuryConduitV3": load_artifact("treasury-v3/TreasuryConduit.sol/TreasuryConduit.json"),
        "TreasuryBridgeConduit": load_artifact("treasury-v3/TreasuryBridgeConduit.sol/TreasuryBridgeConduit.json"),
        "TreasuryBridgeConduitPermit2": load_artifact(
            "treasury-v3/TreasuryBridgeConduitPermit2.sol/TreasuryBridgeConduitPermit2.json"
        ),
        "TreasurySwapAndDeposit": load_artifact("treasury-v3/TreasurySwapAndDeposit.sol/TreasurySwapAndDeposit.json"),
        "BUFIReputationRegistry": load_artifact("fx-hub/BUFIReputationRegistry.sol/BUFIReputationRegistry.json"),
        "WorkspaceTierRegistry": load_artifact("fx-hub/WorkspaceTierRegistry.sol/WorkspaceTierRegistry.json"),
        "WorkspaceOperatingReserve": load_artifact("fx-hub/WorkspaceOperatingReserve.sol/WorkspaceOperatingReserve.json"),
        "InvoiceShelf": load_artifact("fx-hub/InvoiceShelf.sol/InvoiceShelf.json"),
        "BINV": load_artifact("fx-hub/BINV.sol/BINV.json"),
        "BIFTranche": load_artifact("fx-hub/BIFTranche.sol/BIFTranche.json"),
        "MultiTokenReceivableEscrow": load_artifact(
            "fx-hub/MultiTokenReceivableEscrow.sol/MultiTokenReceivableEscrow.json"
        ),
        "RecibuMemoRouter": load_artifact("fx-hub/RecibuMemoRouter.sol/RecibuMemoRouter.json"),
        "CctpDepositForwarder": load_artifact("fx-cctp-forwarder/CctpDepositForwarder.sol/CctpDepositForwarder.json"),
        "CctpDepositForwarderFactory": load_artifact(
            "fx-cctp-forwarder/CctpDepositForwarderFactory.sol/CctpDepositForwarderFactory.json"
        ),
        "ClaimVaultDeployer": load_artifact("claim-vault/ClaimVaultDeployer.sol/ClaimVaultDeployer.json"),
        "PeanutV4": load_artifact("claim-vault/PeanutV4.4.sol/PeanutV4.json"),
        "PayrollBatch": load_artifact("claim-vault/PayrollBatch.sol/PayrollBatch.json"),
    }

    roles = {
        "ATTESTOR_ROLE": keccak256_hex(b"ATTESTOR_ROLE"),
        "SETTLEMENT_ROLE": keccak256_hex(b"SETTLEMENT_ROLE"),
        "SERVICER_ROLE": keccak256_hex(b"SERVICER_ROLE"),
        "OPS_ROLE": keccak256_hex(b"OPS_ROLE"),
        "SHELF_ROLE": keccak256_hex(b"SHELF_ROLE"),
        "ROUTER_ROLE": keccak256_hex(b"ROUTER_ROLE"),
    }

    # Shared ownerless implementation initcode
    cctp_fwd_impl_init = arts["CctpDepositForwarder"]["initcode_hex"]

    # =========================================================================
    # Batch 00: Arc Mainnet (5042) Immediate Hotfix for BugPoCer 5.2.2
    # =========================================================================
    hotfix_5_2_2_txs = [
        tx_grant_role(
            LIVE_ARC_5042_REPUTATION_REGISTRY,
            "BUFIReputationRegistry (live Nov 7)",
            "OPS_ROLE",
            roles["OPS_ROLE"],
            "InvoiceShelf (live Nov 7)",
            LIVE_ARC_5042_INVOICE_SHELF,
        )
    ]

    # =========================================================================
    # Phase 1: Arc Testnet (5042002)
    # =========================================================================
    t_addrs: dict[str, str] = {}
    t_1a_txs: list[dict] = []
    t_1b_txs: list[dict] = []
    t_1c_txs: list[dict] = []

    # Precompute v3 TreasurySwapAndDeposit address for target wiring
    t_tsad_init = arts["TreasurySwapAndDeposit"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", SAFE_AVALANCHE_AND_TESTNET, ARC_USDC
    )
    t_tsad_tx, t_tsad_addr = make_create2_tx(
        "Deploy TreasurySwapAndDeposit vNext (v3 Ownable2Step)",
        salt_of("bufi.treasury-swap-deposit.v3"),
        t_tsad_init,
    )

    # 1a: v2 conduits on Arc Testnet
    t_tc_init = arts["TreasuryConduit"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_AVALANCHE_AND_TESTNET)
    tx, addr = make_create2_tx("Deploy TreasuryConduit vNext (v2)", salt_of("bufi.treasury-conduit.v2"), t_tc_init)
    t_1a_txs.append(tx)
    t_addrs["TreasuryConduit"] = addr

    t_tcp2_init = arts["TreasuryConduitPermit2"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address)", SAFE_AVALANCHE_AND_TESTNET, PERMIT2_CANONICAL, COLD_STORAGE_ADDRESS_BOOK
    )
    tx, addr = make_create2_tx(
        "Deploy TreasuryConduitPermit2 vNext (v2)", salt_of("bufi.treasury-conduit.permit2.v1"), t_tcp2_init
    )
    t_1a_txs.append(tx)
    t_addrs["TreasuryConduitPermit2"] = addr

    t_tbcv2_init = arts["TreasuryBridgeConduitV2"]["initcode_hex"] + cast_abi_encode(
        "f(address)", SAFE_AVALANCHE_AND_TESTNET
    )
    tx, addr = make_create2_tx(
        "Deploy TreasuryBridgeConduitV2 vNext (v2)", salt_of("bufi.treasury-bridge-conduit.v2"), t_tbcv2_init
    )
    t_1a_txs.append(tx)
    t_addrs["TreasuryBridgeConduitV2"] = addr

    for k in ["TreasuryConduit", "TreasuryConduitPermit2", "TreasuryBridgeConduitV2"]:
        t_1a_txs.append(tx_set_token(t_addrs[k], k, "ARC_USDC", ARC_USDC))
        t_1a_txs.append(tx_set_token(t_addrs[k], k, "ARC_TESTNET_EURC", ARC_TESTNET_EURC))

    for k in ["TreasuryConduit", "TreasuryConduitPermit2"]:
        for t_lbl, t_addr in [
            ("Circle AppKit Adapter", ARC_TESTNET_CIRCLE_ADAPTER),
            ("LI.FI Diamond (Testnet)", ARC_TESTNET_LIFI_DIAMOND),
            ("BUFI Arc Testnet USDC Vault", ARC_TESTNET_USDC_VAULT),
            ("TreasurySwapAndDeposit vNext", t_tsad_addr),
        ]:
            t_1a_txs.append(tx_set_target(t_addrs[k], k, t_lbl, t_addr))
    for t_lbl, t_addr in [
        ("Circle AppKit Adapter", ARC_TESTNET_CIRCLE_ADAPTER),
        ("LI.FI Diamond (Testnet)", ARC_TESTNET_LIFI_DIAMOND),
        ("BUFI Arc Testnet USDC Vault", ARC_TESTNET_USDC_VAULT),
    ]:
        t_1a_txs.append(tx_set_permit2_route(t_addrs["TreasuryConduitPermit2"], "TreasuryConduitPermit2", t_lbl, t_addr))

    t_1a_txs.append(tx_set_target(t_addrs["TreasuryBridgeConduitV2"], "TreasuryBridgeConduitV2", "LI.FI Diamond (Testnet)", ARC_TESTNET_LIFI_DIAMOND))
    t_1a_txs.append(tx_set_bridge(t_addrs["TreasuryBridgeConduitV2"], "TreasuryBridgeConduitV2", 0, "CCTP_V2", CCTP_TESTNET_TOKEN_MESSENGER))
    t_1a_txs.append(tx_set_bridge(t_addrs["TreasuryBridgeConduitV2"], "TreasuryBridgeConduitV2", 1, "CCTPX", CCTPX_TESTNET_SERVICE))
    t_1a_txs.append(
        tx_set_cctpx_token(
            t_addrs["TreasuryBridgeConduitV2"],
            "TreasuryBridgeConduitV2",
            "EURC_TESTNET",
            CCTPX_EURC_TESTNET_TOKEN_ID,
            ARC_TESTNET_EURC,
        )
    )

    # 1b: v3 conduits + TreasurySwapAndDeposit on Arc Testnet
    t_tcv3_init = arts["TreasuryConduitV3"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_AVALANCHE_AND_TESTNET)
    tx, addr = make_create2_tx("Deploy TreasuryConduit vNext (v3 Ownable2Step)", salt_of("bufi.treasury-conduit.v3"), t_tcv3_init)
    t_1b_txs.append(tx)
    t_addrs["TreasuryConduitV3"] = addr

    t_tbc_init = arts["TreasuryBridgeConduit"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_AVALANCHE_AND_TESTNET)
    tx, addr = make_create2_tx(
        "Deploy TreasuryBridgeConduit vNext (v3 Ownable2Step)", salt_of("bufi.treasury-bridge-conduit.v1"), t_tbc_init
    )
    t_1b_txs.append(tx)
    t_addrs["TreasuryBridgeConduit"] = addr

    t_tbcp2_init = arts["TreasuryBridgeConduitPermit2"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", SAFE_AVALANCHE_AND_TESTNET, PERMIT2_CANONICAL
    )
    tx, addr = make_create2_tx(
        "Deploy TreasuryBridgeConduitPermit2 vNext (v3 Ownable2Step)",
        salt_of("bufi.treasury-bridge-conduit.permit2.v1"),
        t_tbcp2_init,
    )
    t_1b_txs.append(tx)
    t_addrs["TreasuryBridgeConduitPermit2"] = addr

    t_1b_txs.append(t_tsad_tx)
    t_addrs["TreasurySwapAndDeposit"] = t_tsad_addr

    for k in ["TreasuryConduitV3", "TreasuryBridgeConduit", "TreasuryBridgeConduitPermit2"]:
        t_1b_txs.append(tx_set_token(t_addrs[k], k, "ARC_USDC", ARC_USDC))
        t_1b_txs.append(tx_set_token(t_addrs[k], k, "ARC_TESTNET_EURC", ARC_TESTNET_EURC))

    for t_lbl, t_addr in [
        ("Circle AppKit Adapter", ARC_TESTNET_CIRCLE_ADAPTER),
        ("LI.FI Diamond (Testnet)", ARC_TESTNET_LIFI_DIAMOND),
        ("BUFI Arc Testnet USDC Vault", ARC_TESTNET_USDC_VAULT),
        ("TreasurySwapAndDeposit vNext", t_tsad_addr),
    ]:
        t_1b_txs.append(tx_set_target(t_addrs["TreasuryConduitV3"], "TreasuryConduitV3", t_lbl, t_addr))
    t_1b_txs.append(
        tx_set_permit2_route(
            t_addrs["TreasuryConduitPermit2"], "TreasuryConduitPermit2", "TreasurySwapAndDeposit vNext", t_tsad_addr
        )
    )

    for k in ["TreasuryBridgeConduit", "TreasuryBridgeConduitPermit2"]:
        t_1b_txs.append(tx_set_target(t_addrs[k], k, "LI.FI Diamond (Testnet)", ARC_TESTNET_LIFI_DIAMOND))
        t_1b_txs.append(tx_set_bridge(t_addrs[k], k, 0, "CCTP_V2", CCTP_TESTNET_TOKEN_MESSENGER))
        t_1b_txs.append(tx_set_bridge(t_addrs[k], k, 1, "CCTPX", CCTPX_TESTNET_SERVICE))
        t_1b_txs.append(tx_set_cctpx_token(t_addrs[k], k, "EURC_TESTNET", CCTPX_EURC_TESTNET_TOKEN_ID, ARC_TESTNET_EURC))
    for t_lbl, t_addr in [
        ("LI.FI Diamond (Testnet)", ARC_TESTNET_LIFI_DIAMOND),
        ("CCTP Testnet TokenMessengerV2", CCTP_TESTNET_TOKEN_MESSENGER),
        ("CCTPx Testnet CrossChainTokenService", CCTPX_TESTNET_SERVICE),
    ]:
        t_1b_txs.append(
            tx_set_permit2_route(t_addrs["TreasuryBridgeConduitPermit2"], "TreasuryBridgeConduitPermit2", t_lbl, t_addr)
        )

    t_1b_txs.append(
        make_call_tx(
            t_tsad_addr,
            "TreasurySwapAndDeposit.setVenue(Circle AppKit Adapter, true)",
            "setVenue",
            [("venue", "address", ARC_TESTNET_CIRCLE_ADAPTER), ("allowed", "bool", "true")],
            "setVenue(address,bool)",
            [ARC_TESTNET_CIRCLE_ADAPTER, "true"],
        )
    )
    t_1b_txs.append(
        make_call_tx(
            t_tsad_addr,
            "TreasurySwapAndDeposit.setVenue(LI.FI Diamond Testnet, true)",
            "setVenue",
            [("venue", "address", ARC_TESTNET_LIFI_DIAMOND), ("allowed", "bool", "true")],
            "setVenue(address,bool)",
            [ARC_TESTNET_LIFI_DIAMOND, "true"],
        )
    )
    t_1b_txs.append(
        make_call_tx(
            t_tsad_addr,
            "TreasurySwapAndDeposit.setDest(BUFI Arc Testnet USDC Vault, true)",
            "setDest",
            [("dest", "address", ARC_TESTNET_USDC_VAULT), ("allowed", "bool", "true")],
            "setDest(address,bool)",
            [ARC_TESTNET_USDC_VAULT, "true"],
        )
    )

    # 1c: ClaimVault + PayrollBatch + CCTP Forwarder on Arc Testnet
    tx, addr = make_create2_tx(
        "Deploy CctpDepositForwarder Implementation vNext",
        salt_of("bufi.cctp-deposit-forwarder.v1.implementation"),
        cctp_fwd_impl_init,
    )
    t_1c_txs.append(tx)
    t_addrs["CctpDepositForwarderImplementation"] = addr

    t_fwd_factory_init = arts["CctpDepositForwarderFactory"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address)", addr, ARC_USDC, CCTP_TESTNET_TOKEN_MESSENGER
    )
    tx, addr = make_create2_tx(
        "Deploy CctpDepositForwarderFactory vNext (Arc Testnet)",
        salt_of("bufi.cctp-deposit-forwarder.v1.factory"),
        t_fwd_factory_init,
    )
    t_1c_txs.append(tx)
    t_addrs["CctpDepositForwarderFactory"] = addr

    t_cvd_init = arts["ClaimVaultDeployer"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", SAFE_AVALANCHE_AND_TESTNET, CLAIM_VAULT_MFA_AUTHORIZER
    )
    tx, cvd_addr = make_create2_tx(
        "Deploy ClaimVaultDeployer vNext (spawns PeanutV4.4 MFA Vault)",
        salt_of("bufi.claim-vault.deployer.v1"),
        t_cvd_init,
    )
    t_peanut_addr = compute_create_address(cvd_addr, 1)
    tx["meta"]["spawnedVaultAddress"] = t_peanut_addr
    t_1c_txs.append(tx)
    t_addrs["ClaimVaultDeployer"] = cvd_addr
    t_addrs["PeanutV4"] = t_peanut_addr

    t_1c_txs.append(
        make_call_tx(
            t_peanut_addr,
            "PeanutV4.acceptOwnership() (completes Ownable2Step handover to Safe)",
            "acceptOwnership",
            [],
            "acceptOwnership()",
            [],
        )
    )

    t_pb_init = arts["PayrollBatch"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", PERMIT2_CANONICAL, t_peanut_addr
    )
    tx, addr = make_create2_tx("Deploy PayrollBatch vNext", salt_of("bufi.payroll-batch.v1"), t_pb_init)
    t_1c_txs.append(tx)
    t_addrs["PayrollBatch"] = addr

    # =========================================================================
    # Phase 2: Arc Mainnet (5042)
    # =========================================================================
    arc_addrs: dict[str, str] = {
        "BUFIIdentityRegistry_ReusedLiveNov7": LIVE_ARC_5042_IDENTITY_REGISTRY,
    }
    arc_2a_txs: list[dict] = []
    arc_2b_txs: list[dict] = []
    arc_2c_txs: list[dict] = []
    arc_2d_txs: list[dict] = []
    arc_2e_txs: list[dict] = []

    # Precompute Arc Mainnet v3 TreasurySwapAndDeposit address
    arc_tsad_init = arts["TreasurySwapAndDeposit"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", SAFE_ARC_MAINNET, ARC_USDC
    )
    arc_tsad_tx, arc_tsad_addr = make_create2_tx(
        "Deploy TreasurySwapAndDeposit vNext (v3 Ownable2Step)",
        salt_of("bufi.treasury-swap-deposit.v3"),
        arc_tsad_init,
    )

    # 2a: Arc Mainnet v2 conduits
    arc_tc_init = arts["TreasuryConduit"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_ARC_MAINNET)
    tx, addr = make_create2_tx("Deploy TreasuryConduit vNext (v2)", salt_of("bufi.treasury-conduit.v2"), arc_tc_init)
    arc_2a_txs.append(tx)
    arc_addrs["TreasuryConduit"] = addr

    arc_tcp2_init = arts["TreasuryConduitPermit2"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address)", SAFE_ARC_MAINNET, PERMIT2_CANONICAL, COLD_STORAGE_ADDRESS_BOOK
    )
    tx, addr = make_create2_tx(
        "Deploy TreasuryConduitPermit2 vNext (v2)", salt_of("bufi.treasury-conduit.permit2.v1"), arc_tcp2_init
    )
    arc_2a_txs.append(tx)
    arc_addrs["TreasuryConduitPermit2"] = addr

    arc_tbcv2_init = arts["TreasuryBridgeConduitV2"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_ARC_MAINNET)
    tx, addr = make_create2_tx(
        "Deploy TreasuryBridgeConduitV2 vNext (v2)", salt_of("bufi.treasury-bridge-conduit.v2"), arc_tbcv2_init
    )
    arc_2a_txs.append(tx)
    arc_addrs["TreasuryBridgeConduitV2"] = addr

    for k in ["TreasuryConduit", "TreasuryConduitPermit2", "TreasuryBridgeConduitV2"]:
        arc_2a_txs.append(tx_set_token(arc_addrs[k], k, "ARC_USDC", ARC_USDC))
        arc_2a_txs.append(tx_set_token(arc_addrs[k], k, "ARC_MAINNET_EURC", ARC_MAINNET_EURC))

    arc_conduit_targets = [
        ("LI.FI Diamond", ARC_LIFI_DIAMOND),
        ("Uniswap 2.1.2 Router", ARC_UNISWAP_ROUTER),
        ("Uniswap No-Permit2 Swap Proxy", ARC_UNISWAP_NO_PERMIT2_PROXY),
        ("Morpho Bitwise PAPY Vault", ARC_MORPHO_BITWISE_PAPY),
        ("Morpho Steakhouse USDC Vault", ARC_MORPHO_STEAKHOUSE_USDC),
    ]
    for k in ["TreasuryConduit", "TreasuryConduitPermit2"]:
        for t_lbl, t_addr in arc_conduit_targets + [("TreasurySwapAndDeposit vNext", arc_tsad_addr)]:
            arc_2a_txs.append(tx_set_target(arc_addrs[k], k, t_lbl, t_addr))
    for t_lbl, t_addr in arc_conduit_targets:
        arc_2a_txs.append(tx_set_permit2_route(arc_addrs["TreasuryConduitPermit2"], "TreasuryConduitPermit2", t_lbl, t_addr))

    for t_lbl, t_addr in [
        ("LI.FI Diamond", ARC_LIFI_DIAMOND),
        ("Uniswap 2.1.2 Router", ARC_UNISWAP_ROUTER),
        ("Uniswap No-Permit2 Swap Proxy", ARC_UNISWAP_NO_PERMIT2_PROXY),
    ]:
        arc_2a_txs.append(tx_set_target(arc_addrs["TreasuryBridgeConduitV2"], "TreasuryBridgeConduitV2", t_lbl, t_addr))
    arc_2a_txs.append(tx_set_bridge(arc_addrs["TreasuryBridgeConduitV2"], "TreasuryBridgeConduitV2", 0, "CCTP_V2", CCTP_MAINNET_TOKEN_MESSENGER))
    arc_2a_txs.append(tx_set_bridge(arc_addrs["TreasuryBridgeConduitV2"], "TreasuryBridgeConduitV2", 1, "CCTPX", CCTPX_MAINNET_SERVICE))
    arc_2a_txs.append(
        tx_set_cctpx_token(
            arc_addrs["TreasuryBridgeConduitV2"],
            "TreasuryBridgeConduitV2",
            "EURC_MAINNET",
            CCTPX_EURC_MAINNET_TOKEN_ID,
            ARC_MAINNET_EURC,
        )
    )

    # 2b: Arc Mainnet v3 conduits + TreasurySwapAndDeposit
    arc_tcv3_init = arts["TreasuryConduitV3"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_ARC_MAINNET)
    tx, addr = make_create2_tx(
        "Deploy TreasuryConduit vNext (v3 Ownable2Step)", salt_of("bufi.treasury-conduit.v3"), arc_tcv3_init
    )
    arc_2b_txs.append(tx)
    arc_addrs["TreasuryConduitV3"] = addr

    arc_tbc_init = arts["TreasuryBridgeConduit"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_ARC_MAINNET)
    tx, addr = make_create2_tx(
        "Deploy TreasuryBridgeConduit vNext (v3 Ownable2Step)", salt_of("bufi.treasury-bridge-conduit.v1"), arc_tbc_init
    )
    arc_2b_txs.append(tx)
    arc_addrs["TreasuryBridgeConduit"] = addr

    arc_tbcp2_init = arts["TreasuryBridgeConduitPermit2"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", SAFE_ARC_MAINNET, PERMIT2_CANONICAL
    )
    tx, addr = make_create2_tx(
        "Deploy TreasuryBridgeConduitPermit2 vNext (v3 Ownable2Step)",
        salt_of("bufi.treasury-bridge-conduit.permit2.v1"),
        arc_tbcp2_init,
    )
    arc_2b_txs.append(tx)
    arc_addrs["TreasuryBridgeConduitPermit2"] = addr

    arc_2b_txs.append(arc_tsad_tx)
    arc_addrs["TreasurySwapAndDeposit"] = arc_tsad_addr

    for k in ["TreasuryConduitV3", "TreasuryBridgeConduit", "TreasuryBridgeConduitPermit2"]:
        arc_2b_txs.append(tx_set_token(arc_addrs[k], k, "ARC_USDC", ARC_USDC))
        arc_2b_txs.append(tx_set_token(arc_addrs[k], k, "ARC_MAINNET_EURC", ARC_MAINNET_EURC))

    for t_lbl, t_addr in arc_conduit_targets + [("TreasurySwapAndDeposit vNext", arc_tsad_addr)]:
        arc_2b_txs.append(tx_set_target(arc_addrs["TreasuryConduitV3"], "TreasuryConduitV3", t_lbl, t_addr))
    arc_2b_txs.append(
        tx_set_permit2_route(
            arc_addrs["TreasuryConduitPermit2"], "TreasuryConduitPermit2", "TreasurySwapAndDeposit vNext", arc_tsad_addr
        )
    )

    for k in ["TreasuryBridgeConduit", "TreasuryBridgeConduitPermit2"]:
        for t_lbl, t_addr in [
            ("LI.FI Diamond", ARC_LIFI_DIAMOND),
            ("Uniswap 2.1.2 Router", ARC_UNISWAP_ROUTER),
            ("Uniswap No-Permit2 Swap Proxy", ARC_UNISWAP_NO_PERMIT2_PROXY),
        ]:
            arc_2b_txs.append(tx_set_target(arc_addrs[k], k, t_lbl, t_addr))
        arc_2b_txs.append(tx_set_bridge(arc_addrs[k], k, 0, "CCTP_V2", CCTP_MAINNET_TOKEN_MESSENGER))
        arc_2b_txs.append(tx_set_bridge(arc_addrs[k], k, 1, "CCTPX", CCTPX_MAINNET_SERVICE))
        arc_2b_txs.append(
            tx_set_cctpx_token(arc_addrs[k], k, "EURC_MAINNET", CCTPX_EURC_MAINNET_TOKEN_ID, ARC_MAINNET_EURC)
        )

    for t_lbl, t_addr in [
        ("LI.FI Diamond", ARC_LIFI_DIAMOND),
        ("Uniswap 2.1.2 Router", ARC_UNISWAP_ROUTER),
        ("Uniswap No-Permit2 Swap Proxy", ARC_UNISWAP_NO_PERMIT2_PROXY),
        ("CCTP TokenMessengerV2", CCTP_MAINNET_TOKEN_MESSENGER),
        ("CCTPx CrossChainTokenService", CCTPX_MAINNET_SERVICE),
    ]:
        arc_2b_txs.append(
            tx_set_permit2_route(arc_addrs["TreasuryBridgeConduitPermit2"], "TreasuryBridgeConduitPermit2", t_lbl, t_addr)
        )

    for v_lbl, v_addr in [
        ("Uniswap No-Permit2 Swap Proxy", ARC_UNISWAP_NO_PERMIT2_PROXY),
        ("Uniswap 2.1.2 Router", ARC_UNISWAP_ROUTER),
        ("LI.FI Diamond", ARC_LIFI_DIAMOND),
    ]:
        arc_2b_txs.append(
            make_call_tx(
                arc_tsad_addr,
                f"TreasurySwapAndDeposit.setVenue({v_lbl}, true)",
                "setVenue",
                [("venue", "address", v_addr), ("allowed", "bool", "true")],
                "setVenue(address,bool)",
                [v_addr, "true"],
            )
        )
    for d_lbl, d_addr in [
        ("Morpho Bitwise PAPY Vault", ARC_MORPHO_BITWISE_PAPY),
        ("Morpho Steakhouse USDC Vault", ARC_MORPHO_STEAKHOUSE_USDC),
    ]:
        arc_2b_txs.append(
            make_call_tx(
                arc_tsad_addr,
                f"TreasurySwapAndDeposit.setDest({d_lbl}, true)",
                "setDest",
                [("dest", "address", d_addr), ("allowed", "bool", "true")],
                "setDest(address,bool)",
                [d_addr, "true"],
            )
        )

    # 2c: Arc Mainnet FX-Recibu Hub Part 1 (Reputation, Tier, Reserve, InvoiceShelf + BINV + bIF-A/B/C + core roles)
    rep_init = arts["BUFIReputationRegistry"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", SAFE_ARC_MAINNET, LIVE_ARC_5042_IDENTITY_REGISTRY
    )
    tx, addr = make_create2_tx("Deploy BUFIReputationRegistry vNext", salt_of("bufi.reputation-registry.v1"), rep_init)
    arc_2c_txs.append(tx)
    arc_addrs["BUFIReputationRegistry"] = addr

    tiers_init = arts["WorkspaceTierRegistry"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", LIVE_ARC_5042_IDENTITY_REGISTRY, arc_addrs["BUFIReputationRegistry"]
    )
    tx, addr = make_create2_tx("Deploy WorkspaceTierRegistry vNext", salt_of("bufi.workspace-tier-registry.v1"), tiers_init)
    arc_2c_txs.append(tx)
    arc_addrs["WorkspaceTierRegistry"] = addr

    res_init = arts["WorkspaceOperatingReserve"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", ARC_USDC, SAFE_ARC_MAINNET
    )
    tx, addr = make_create2_tx(
        "Deploy WorkspaceOperatingReserve vNext", salt_of("bufi.workspace-operating-reserve.v1"), res_init
    )
    arc_2c_txs.append(tx)
    arc_addrs["WorkspaceOperatingReserve"] = addr

    shelf_init = arts["InvoiceShelf"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address,address,address,bool)",
        ARC_USDC,
        LIVE_ARC_5042_IDENTITY_REGISTRY,
        arc_addrs["BUFIReputationRegistry"],
        arc_addrs["WorkspaceTierRegistry"],
        SAFE_ARC_MAINNET,
        "false",
    )
    tx, shelf_addr = make_create2_tx(
        "Deploy InvoiceShelf vNext (spawns BINV + bIF-A/B/C Tranches)",
        salt_of("bufi.invoice-shelf.v1"),
        shelf_init,
    )
    tx["meta"]["spawnedChildren"] = {
        "BINV": compute_create_address(shelf_addr, 1),
        "BIFTrancheSenior_bIF_A": compute_create_address(shelf_addr, 2),
        "BIFTrancheMezzanine_bIF_B": compute_create_address(shelf_addr, 3),
        "BIFTrancheJunior_bIF_C": compute_create_address(shelf_addr, 4),
    }
    arc_2c_txs.append(tx)
    arc_addrs["InvoiceShelf"] = shelf_addr
    arc_addrs["BINV"] = compute_create_address(shelf_addr, 1)
    arc_addrs["BIFTrancheSenior_bIF_A"] = compute_create_address(shelf_addr, 2)
    arc_addrs["BIFTrancheMezzanine_bIF_B"] = compute_create_address(shelf_addr, 3)
    arc_addrs["BIFTrancheJunior_bIF_C"] = compute_create_address(shelf_addr, 4)

    arc_2c_txs.append(
        tx_grant_role(
            arc_addrs["BUFIReputationRegistry"],
            "BUFIReputationRegistry",
            "ATTESTOR_ROLE",
            roles["ATTESTOR_ROLE"],
            "Safe",
            SAFE_ARC_MAINNET,
        )
    )
    arc_2c_txs.append(
        tx_grant_role(
            arc_addrs["BUFIReputationRegistry"],
            "BUFIReputationRegistry",
            "SETTLEMENT_ROLE",
            roles["SETTLEMENT_ROLE"],
            "InvoiceShelf vNext",
            shelf_addr,
        )
    )
    arc_2c_txs.append(
        tx_grant_role(
            arc_addrs["BUFIReputationRegistry"],
            "BUFIReputationRegistry",
            "OPS_ROLE",
            roles["OPS_ROLE"],
            "InvoiceShelf vNext",
            shelf_addr,
        )
    )
    arc_2c_txs.append(
        tx_grant_role(
            arc_addrs["WorkspaceOperatingReserve"],
            "WorkspaceOperatingReserve",
            "SHELF_ROLE",
            roles["SHELF_ROLE"],
            "InvoiceShelf vNext",
            shelf_addr,
        )
    )
    arc_2c_txs.append(
        make_call_tx(
            shelf_addr,
            "InvoiceShelf.setReserve(WorkspaceOperatingReserve vNext)",
            "setReserve",
            [("reserve_", "address", arc_addrs["WorkspaceOperatingReserve"])],
            "setReserve(address)",
            [arc_addrs["WorkspaceOperatingReserve"]],
        )
    )
    arc_2c_txs.append(
        tx_grant_role(shelf_addr, "InvoiceShelf", "SERVICER_ROLE", roles["SERVICER_ROLE"], "Safe", SAFE_ARC_MAINNET)
    )
    arc_2c_txs.append(
        tx_grant_role(shelf_addr, "InvoiceShelf", "SETTLEMENT_ROLE", roles["SETTLEMENT_ROLE"], "Safe", SAFE_ARC_MAINNET)
    )
    arc_2c_txs.append(
        tx_grant_role(
            shelf_addr, "InvoiceShelf", "OPS_ROLE", roles["OPS_ROLE"], "Telarana Keeper EOA", TELARANA_KEEPER_EOA
        )
    )

    # 2d: Arc Mainnet FX-Recibu Hub Part 2 (Escrow, RecibuMemoRouter, CCTP Forwarder + wiring)
    escrow_init = arts["MultiTokenReceivableEscrow"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_ARC_MAINNET)
    tx, escrow_addr = make_create2_tx(
        "Deploy MultiTokenReceivableEscrow vNext",
        salt_of("bufi.multi-token-receivable-escrow.v1"),
        escrow_init,
    )
    arc_2d_txs.append(tx)
    arc_addrs["MultiTokenReceivableEscrow"] = escrow_addr

    router_init = arts["RecibuMemoRouter"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address)", shelf_addr, escrow_addr, SAFE_ARC_MAINNET
    )
    tx, router_addr = make_create2_tx("Deploy RecibuMemoRouter vNext", salt_of("bufi.recibu-memo-router.v1"), router_init)
    arc_2d_txs.append(tx)
    arc_addrs["RecibuMemoRouter"] = router_addr

    tx, fwd_impl_addr = make_create2_tx(
        "Deploy CctpDepositForwarder Implementation vNext",
        salt_of("bufi.cctp-deposit-forwarder.v1.implementation"),
        cctp_fwd_impl_init,
    )
    arc_2d_txs.append(tx)
    arc_addrs["CctpDepositForwarderImplementation"] = fwd_impl_addr

    arc_fwd_factory_init = arts["CctpDepositForwarderFactory"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address)", fwd_impl_addr, ARC_USDC, CCTP_MAINNET_TOKEN_MESSENGER
    )
    tx, fwd_factory_addr = make_create2_tx(
        "Deploy CctpDepositForwarderFactory vNext (Arc Mainnet)",
        salt_of("bufi.cctp-deposit-forwarder.v1.factory"),
        arc_fwd_factory_init,
    )
    arc_2d_txs.append(tx)
    arc_addrs["CctpDepositForwarderFactory"] = fwd_factory_addr

    arc_2d_txs.append(
        make_call_tx(
            shelf_addr,
            "InvoiceShelf.setEscrow(MultiTokenReceivableEscrow vNext)",
            "setEscrow",
            [("escrow_", "address", escrow_addr)],
            "setEscrow(address)",
            [escrow_addr],
        )
    )
    arc_2d_txs.append(
        make_call_tx(
            escrow_addr,
            "MultiTokenReceivableEscrow.setToken(ARC_USDC, true)",
            "setToken",
            [("token", "address", ARC_USDC), ("supported", "bool", "true")],
            "setToken(address,bool)",
            [ARC_USDC, "true"],
        )
    )
    arc_2d_txs.append(
        make_call_tx(
            escrow_addr,
            "MultiTokenReceivableEscrow.setToken(ARC_MAINNET_EURC, true)",
            "setToken",
            [("token", "address", ARC_MAINNET_EURC), ("supported", "bool", "true")],
            "setToken(address,bool)",
            [ARC_MAINNET_EURC, "true"],
        )
    )
    arc_2d_txs.append(
        tx_grant_role(
            escrow_addr,
            "MultiTokenReceivableEscrow",
            "ROUTER_ROLE",
            roles["ROUTER_ROLE"],
            "RecibuMemoRouter vNext",
            router_addr,
        )
    )
    arc_2d_txs.append(
        make_call_tx(
            router_addr,
            "RecibuMemoRouter.setToken(ARC_USDC, true, CAP_3009|CAP_PERMIT=3)",
            "setToken",
            [("token", "address", ARC_USDC), ("allowed", "bool", "true"), ("caps", "uint8", "3")],
            "setToken(address,bool,uint8)",
            [ARC_USDC, "true", "3"],
        )
    )
    arc_2d_txs.append(
        make_call_tx(
            router_addr,
            "RecibuMemoRouter.setToken(ARC_MAINNET_EURC, true, CAP_3009|CAP_PERMIT=3)",
            "setToken",
            [("token", "address", ARC_MAINNET_EURC), ("allowed", "bool", "true"), ("caps", "uint8", "3")],
            "setToken(address,bool,uint8)",
            [ARC_MAINNET_EURC, "true", "3"],
        )
    )

    # 2e: Arc Mainnet ClaimVault (PeanutV4.4) + PayrollBatch
    arc_cvd_init = arts["ClaimVaultDeployer"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", SAFE_ARC_MAINNET, CLAIM_VAULT_MFA_AUTHORIZER
    )
    tx, arc_cvd_addr = make_create2_tx(
        "Deploy ClaimVaultDeployer vNext (spawns PeanutV4.4 MFA Vault)",
        salt_of("bufi.claim-vault.deployer.v1"),
        arc_cvd_init,
    )
    arc_peanut_addr = compute_create_address(arc_cvd_addr, 1)
    tx["meta"]["spawnedVaultAddress"] = arc_peanut_addr
    arc_2e_txs.append(tx)
    arc_addrs["ClaimVaultDeployer"] = arc_cvd_addr
    arc_addrs["PeanutV4"] = arc_peanut_addr

    arc_2e_txs.append(
        make_call_tx(
            arc_peanut_addr,
            "PeanutV4.acceptOwnership() (completes Ownable2Step handover to Safe)",
            "acceptOwnership",
            [],
            "acceptOwnership()",
            [],
        )
    )

    arc_pb_init = arts["PayrollBatch"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", PERMIT2_CANONICAL, arc_peanut_addr
    )
    tx, arc_pb_addr = make_create2_tx("Deploy PayrollBatch vNext", salt_of("bufi.payroll-batch.v1"), arc_pb_init)
    arc_2e_txs.append(tx)
    arc_addrs["PayrollBatch"] = arc_pb_addr

    # =========================================================================
    # Phase 3: Avalanche C-Chain Mainnet (43114)
    # =========================================================================
    avax_addrs: dict[str, str] = {}
    avax_3a_txs: list[dict] = []
    avax_3b_txs: list[dict] = []
    avax_3c_txs: list[dict] = []

    # 3a: v2 conduits on Avalanche
    tx, addr = make_create2_tx("Deploy TreasuryConduit vNext (v2)", salt_of("bufi.treasury-conduit.v2"), t_tc_init)
    avax_3a_txs.append(tx)
    avax_addrs["TreasuryConduit"] = addr

    tx, addr = make_create2_tx(
        "Deploy TreasuryConduitPermit2 vNext (v2)", salt_of("bufi.treasury-conduit.permit2.v1"), t_tcp2_init
    )
    avax_3a_txs.append(tx)
    avax_addrs["TreasuryConduitPermit2"] = addr

    tx, addr = make_create2_tx(
        "Deploy TreasuryBridgeConduitV2 vNext (v2)", salt_of("bufi.treasury-bridge-conduit.v2"), t_tbcv2_init
    )
    avax_3a_txs.append(tx)
    avax_addrs["TreasuryBridgeConduitV2"] = addr

    for k in ["TreasuryConduit", "TreasuryConduitPermit2", "TreasuryBridgeConduitV2"]:
        avax_3a_txs.append(tx_set_token(avax_addrs[k], k, "AVAX_USDC", AVAX_USDC))
        avax_3a_txs.append(tx_set_token(avax_addrs[k], k, "AVAX_EURC", AVAX_EURC))

    avax_venues = [
        ("LI.FI Diamond", AVAX_LIFI_DIAMOND),
        ("Uniswap Universal Router", AVAX_UNISWAP_UNIVERSAL_ROUTER),
        ("Uniswap SwapRouter02", AVAX_UNISWAP_SWAP_ROUTER_02),
        ("Uniswap No-Permit2 Swap Proxy", AVAX_UNISWAP_NO_PERMIT2_PROXY),
    ]
    for k in ["TreasuryConduit", "TreasuryConduitPermit2", "TreasuryBridgeConduitV2"]:
        for t_lbl, t_addr in avax_venues:
            avax_3a_txs.append(tx_set_target(avax_addrs[k], k, t_lbl, t_addr))
    for t_lbl, t_addr in avax_venues:
        avax_3a_txs.append(
            tx_set_permit2_route(avax_addrs["TreasuryConduitPermit2"], "TreasuryConduitPermit2", t_lbl, t_addr)
        )
    avax_3a_txs.append(tx_set_bridge(avax_addrs["TreasuryBridgeConduitV2"], "TreasuryBridgeConduitV2", 0, "CCTP_V2", CCTP_MAINNET_TOKEN_MESSENGER))
    avax_3a_txs.append(tx_set_bridge(avax_addrs["TreasuryBridgeConduitV2"], "TreasuryBridgeConduitV2", 1, "CCTPX", CCTPX_MAINNET_SERVICE))
    avax_3a_txs.append(
        tx_set_cctpx_token(
            avax_addrs["TreasuryBridgeConduitV2"],
            "TreasuryBridgeConduitV2",
            "EURC_MAINNET",
            CCTPX_EURC_MAINNET_TOKEN_ID,
            AVAX_EURC,
        )
    )

    # 3b: v3 bridge conduits + CCTP Forwarder on Avalanche
    tx, addr = make_create2_tx(
        "Deploy TreasuryBridgeConduit vNext (v3 Ownable2Step)", salt_of("bufi.treasury-bridge-conduit.v1"), t_tbc_init
    )
    avax_3b_txs.append(tx)
    avax_addrs["TreasuryBridgeConduit"] = addr

    tx, addr = make_create2_tx(
        "Deploy TreasuryBridgeConduitPermit2 vNext (v3 Ownable2Step)",
        salt_of("bufi.treasury-bridge-conduit.permit2.v1"),
        t_tbcp2_init,
    )
    avax_3b_txs.append(tx)
    avax_addrs["TreasuryBridgeConduitPermit2"] = addr

    tx, addr = make_create2_tx(
        "Deploy CctpDepositForwarder Implementation vNext",
        salt_of("bufi.cctp-deposit-forwarder.v1.implementation"),
        cctp_fwd_impl_init,
    )
    avax_3b_txs.append(tx)
    avax_addrs["CctpDepositForwarderImplementation"] = addr

    avax_fwd_factory_init = arts["CctpDepositForwarderFactory"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address)", addr, AVAX_USDC, CCTP_MAINNET_TOKEN_MESSENGER
    )
    tx, addr = make_create2_tx(
        "Deploy CctpDepositForwarderFactory vNext (Avalanche)",
        salt_of("bufi.cctp-deposit-forwarder.v1.factory"),
        avax_fwd_factory_init,
    )
    avax_3b_txs.append(tx)
    avax_addrs["CctpDepositForwarderFactory"] = addr

    for k in ["TreasuryBridgeConduit", "TreasuryBridgeConduitPermit2"]:
        avax_3b_txs.append(tx_set_token(avax_addrs[k], k, "AVAX_USDC", AVAX_USDC))
        avax_3b_txs.append(tx_set_token(avax_addrs[k], k, "AVAX_EURC", AVAX_EURC))
        for t_lbl, t_addr in avax_venues:
            avax_3b_txs.append(tx_set_target(avax_addrs[k], k, t_lbl, t_addr))
        avax_3b_txs.append(tx_set_bridge(avax_addrs[k], k, 0, "CCTP_V2", CCTP_MAINNET_TOKEN_MESSENGER))
        avax_3b_txs.append(tx_set_bridge(avax_addrs[k], k, 1, "CCTPX", CCTPX_MAINNET_SERVICE))
        avax_3b_txs.append(
            tx_set_cctpx_token(avax_addrs[k], k, "EURC_MAINNET", CCTPX_EURC_MAINNET_TOKEN_ID, AVAX_EURC)
        )
    for t_lbl, t_addr in avax_venues + [
        ("CCTP TokenMessengerV2", CCTP_MAINNET_TOKEN_MESSENGER),
        ("CCTPx CrossChainTokenService", CCTPX_MAINNET_SERVICE),
    ]:
        avax_3b_txs.append(
            tx_set_permit2_route(avax_addrs["TreasuryBridgeConduitPermit2"], "TreasuryBridgeConduitPermit2", t_lbl, t_addr)
        )

    # 3c: ClaimVault + PayrollBatch on Avalanche (same Safe -> identical addresses to Arc Testnet)
    tx, cvd_addr = make_create2_tx(
        "Deploy ClaimVaultDeployer vNext (spawns PeanutV4.4 MFA Vault)",
        salt_of("bufi.claim-vault.deployer.v1"),
        t_cvd_init,
    )
    avax_peanut_addr = compute_create_address(cvd_addr, 1)
    tx["meta"]["spawnedVaultAddress"] = avax_peanut_addr
    avax_3c_txs.append(tx)
    avax_addrs["ClaimVaultDeployer"] = cvd_addr
    avax_addrs["PeanutV4"] = avax_peanut_addr

    avax_3c_txs.append(
        make_call_tx(
            avax_peanut_addr,
            "PeanutV4.acceptOwnership() (completes Ownable2Step handover to Safe)",
            "acceptOwnership",
            [],
            "acceptOwnership()",
            [],
        )
    )
    tx, addr = make_create2_tx("Deploy PayrollBatch vNext", salt_of("bufi.payroll-batch.v1"), t_pb_init)
    avax_3c_txs.append(tx)
    avax_addrs["PayrollBatch"] = addr

    # =========================================================================
    # Phase 4: Base Mainnet (8453)
    # =========================================================================
    base_addrs: dict[str, str] = {}
    base_4a_txs: list[dict] = []
    base_4b_txs: list[dict] = []

    tx, addr = make_create2_tx(
        "Deploy CctpDepositForwarder Implementation vNext",
        salt_of("bufi.cctp-deposit-forwarder.v1.implementation"),
        cctp_fwd_impl_init,
    )
    base_4a_txs.append(tx)
    base_addrs["CctpDepositForwarderImplementation"] = addr

    base_fwd_factory_init = arts["CctpDepositForwarderFactory"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address)", addr, BASE_USDC, CCTP_MAINNET_TOKEN_MESSENGER
    )
    tx, addr = make_create2_tx(
        "Deploy CctpDepositForwarderFactory vNext (Base Mainnet)",
        salt_of("bufi.cctp-deposit-forwarder.v1.factory"),
        base_fwd_factory_init,
    )
    base_4a_txs.append(tx)
    base_addrs["CctpDepositForwarderFactory"] = addr

    tx, base_cvd_addr = make_create2_tx(
        "Deploy ClaimVaultDeployer vNext (spawns PeanutV4.4 MFA Vault)",
        salt_of("bufi.claim-vault.deployer.v1"),
        arc_cvd_init,
    )
    base_peanut_addr = compute_create_address(base_cvd_addr, 1)
    tx["meta"]["spawnedVaultAddress"] = base_peanut_addr
    base_4a_txs.append(tx)
    base_addrs["ClaimVaultDeployer"] = base_cvd_addr
    base_addrs["PeanutV4"] = base_peanut_addr

    tx, base_pb_addr = make_create2_tx("Deploy PayrollBatch vNext", salt_of("bufi.payroll-batch.v1"), arc_pb_init)
    base_4a_txs.append(tx)
    base_addrs["PayrollBatch"] = base_pb_addr

    base_4b_txs.append(
        make_call_tx(
            base_peanut_addr,
            "PeanutV4.acceptOwnership() (completes Ownable2Step handover once Base Safe 0x47Dc...0D09 is deployed)",
            "acceptOwnership",
            [],
            "acceptOwnership()",
            [],
        )
    )

    # =========================================================================
    # Write Safe Transaction Builder JSON files
    # =========================================================================
    batches = {
        "00-arc-5042-hotfix-5-2-2-grant-ops-role.json": build_safe_batch(
            "5042",
            SAFE_ARC_MAINNET,
            "BUFI Arc 5042 Immediate Hotfix (BugPoCer 5.2.2): Grant OPS_ROLE to Live InvoiceShelf",
            "Grants OPS_ROLE on live Nov 7 BUFIReputationRegistry (0x2D7125b1cf826bE4ad6D0b043F6B4675897EB2e9) to live Nov 7 InvoiceShelf (0x90eCDd402C0E357362b7805173191A153b876DF4) so resolveDefault Restructured succeeds immediately.",
            hotfix_5_2_2_txs,
        ),
        "01a-arc-testnet-5042002-vnext-conduits-v2.json": build_safe_batch(
            "5042002",
            SAFE_AVALANCHE_AND_TESTNET,
            "BUFI Arc Testnet 5042002 vNext Batch 1A: Treasury Conduits v2 + Token/Target/Bridge/CCTPx Wiring",
            "Deploys BugPoCer-remediated TreasuryConduit (v2), TreasuryConduitPermit2, and TreasuryBridgeConduitV2 via fresh CREATE2 salts and configures USDC/EURC token allowlists (5.2.1), targets, Permit2 routes, bridges, and CCTPx EURC.",
            t_1a_txs,
        ),
        "01b-arc-testnet-5042002-vnext-conduits-v3.json": build_safe_batch(
            "5042002",
            SAFE_AVALANCHE_AND_TESTNET,
            "BUFI Arc Testnet 5042002 vNext Batch 1B: Treasury Conduits v3 + SwapAndDeposit + Wiring",
            "Deploys BugPoCer-remediated TreasuryConduit (v3), TreasuryBridgeConduit (v3), TreasuryBridgeConduitPermit2 (v3), and TreasurySwapAndDeposit via CREATE2 and configures token allowlists (5.2.1), targets, venues, dests, Permit2 routes, bridges, and CCTPx EURC.",
            t_1b_txs,
        ),
        "01c-arc-testnet-5042002-vnext-claim-vault-and-forwarder.json": build_safe_batch(
            "5042002",
            SAFE_AVALANCHE_AND_TESTNET,
            "BUFI Arc Testnet 5042002 vNext Batch 1C: CCTP Forwarder, ClaimVault (PeanutV4.4) & PayrollBatch",
            "Deploys BugPoCer-remediated CctpDepositForwarder implementation and factory, ClaimVaultDeployer -> PeanutV4.4 (accepts Ownable2Step ownership), and PayrollBatch.",
            t_1c_txs,
        ),
        "02a-arc-5042-vnext-conduits-v2.json": build_safe_batch(
            "5042",
            SAFE_ARC_MAINNET,
            "BUFI Arc Mainnet 5042 vNext Batch 2A: Treasury Conduits v2 + Token/Target/Bridge/CCTPx Wiring",
            "Deploys BugPoCer-remediated TreasuryConduit (v2), TreasuryConduitPermit2, and TreasuryBridgeConduitV2 on Arc Mainnet and configures USDC/EURC (0xbEf5...21c1) token allowlists (5.2.1), targets, Permit2 routes, bridges, and mainnet CCTPx EURC.",
            arc_2a_txs,
        ),
        "02b-arc-5042-vnext-conduits-v3.json": build_safe_batch(
            "5042",
            SAFE_ARC_MAINNET,
            "BUFI Arc Mainnet 5042 vNext Batch 2B: Treasury Conduits v3 + SwapAndDeposit + Wiring",
            "Deploys BugPoCer-remediated TreasuryConduit (v3), TreasuryBridgeConduit (v3), TreasuryBridgeConduitPermit2 (v3), and TreasurySwapAndDeposit on Arc Mainnet and configures token allowlists (5.2.1), targets, venues, Morpho dests, Permit2 routes, bridges, and mainnet CCTPx EURC.",
            arc_2b_txs,
        ),
        "02c-arc-5042-vnext-fx-hub-part1.json": build_safe_batch(
            "5042",
            SAFE_ARC_MAINNET,
            "BUFI Arc Mainnet 5042 vNext Batch 2C: FX-Recibu Hub Part 1 (Reputation, Tier, Reserve, InvoiceShelf + Roles)",
            "Deploys BugPoCer-remediated BUFIReputationRegistry (wired to live BUFIIdentityRegistry), WorkspaceTierRegistry, WorkspaceOperatingReserve, and InvoiceShelf (spawning BINV and bIF-A/B/C), and grants SETTLEMENT_ROLE + OPS_ROLE (5.2.2) and operational roles.",
            arc_2c_txs,
        ),
        "02d-arc-5042-vnext-fx-hub-part2.json": build_safe_batch(
            "5042",
            SAFE_ARC_MAINNET,
            "BUFI Arc Mainnet 5042 vNext Batch 2D: FX-Recibu Hub Part 2 (Escrow, MemoRouter, CCTP Forwarder + Wiring)",
            "Deploys BugPoCer-remediated MultiTokenReceivableEscrow, RecibuMemoRouter, CctpDepositForwarder implementation and factory on Arc Mainnet, binds escrow on InvoiceShelf, and enables Arc Mainnet USDC and EURC (0xbEf5...21c1).",
            arc_2d_txs,
        ),
        "02e-arc-5042-vnext-claim-vault.json": build_safe_batch(
            "5042",
            SAFE_ARC_MAINNET,
            "BUFI Arc Mainnet 5042 vNext Batch 2E: ClaimVault (PeanutV4.4) + acceptOwnership + PayrollBatch",
            "Deploys BugPoCer-remediated ClaimVaultDeployer -> PeanutV4.4 MFA Vault, executes acceptOwnership() from Safe 0x47Dc...0D09, and deploys PayrollBatch.",
            arc_2e_txs,
        ),
        "03a-avalanche-43114-vnext-conduits-v2.json": build_safe_batch(
            "43114",
            SAFE_AVALANCHE_AND_TESTNET,
            "BUFI Avalanche 43114 vNext Batch 3A: Treasury Conduits v2 + Token/Target/Bridge/CCTPx Wiring",
            "Deploys BugPoCer-remediated TreasuryConduit (v2), TreasuryConduitPermit2, and TreasuryBridgeConduitV2 on Avalanche C-Chain and configures USDC/EURC token allowlists (5.2.1), swap targets, Permit2 routes, bridges, and mainnet CCTPx EURC.",
            avax_3a_txs,
        ),
        "03b-avalanche-43114-vnext-conduits-v3-and-forwarder.json": build_safe_batch(
            "43114",
            SAFE_AVALANCHE_AND_TESTNET,
            "BUFI Avalanche 43114 vNext Batch 3B: Treasury Bridge Conduits v3 + CCTP Forwarder + Wiring",
            "Deploys BugPoCer-remediated TreasuryBridgeConduit (v3), TreasuryBridgeConduitPermit2 (v3), CctpDepositForwarder implementation, and CctpDepositForwarderFactory on Avalanche C-Chain and configures token allowlists (5.2.1), venues, Permit2 routes, bridges, and mainnet CCTPx EURC.",
            avax_3b_txs,
        ),
        "03c-avalanche-43114-vnext-claim-vault.json": build_safe_batch(
            "43114",
            SAFE_AVALANCHE_AND_TESTNET,
            "BUFI Avalanche 43114 vNext Batch 3C: ClaimVault (PeanutV4.4) + acceptOwnership + PayrollBatch",
            "Deploys BugPoCer-remediated ClaimVaultDeployer -> PeanutV4.4 MFA Vault, executes acceptOwnership() from Safe 0xA3a4...468B, and deploys PayrollBatch.",
            avax_3c_txs,
        ),
        "04a-base-8453-vnext-cctp-forwarder-and-claim-vault.json": build_safe_batch(
            "8453",
            SAFE_ARC_MAINNET,
            "BUFI Base Mainnet 8453 vNext Batch 4A: CCTP Forwarder, ClaimVault (PeanutV4.4) & PayrollBatch",
            "Deploys BugPoCer-remediated CctpDepositForwarder implementation and factory, ClaimVaultDeployer -> PeanutV4.4 (pendingOwner = 0x47Dc...0D09), and PayrollBatch via CREATE2. Executable from MultiSendCallOnly or Base Safe 0x47Dc...0D09.",
            base_4a_txs,
        ),
        "04b-base-8453-vnext-claim-vault-accept-ownership.json": build_safe_batch(
            "8453",
            SAFE_ARC_MAINNET,
            "BUFI Base Mainnet 8453 vNext Batch 4B: PeanutV4.acceptOwnership() from Base Safe",
            "Completes Ownable2Step ownership handover on Base Mainnet PeanutV4.4 once Safe 0x47Dc7D18A6E3a79F696714E7D47456a49B430D09 is deployed on Base 8453.",
            base_4b_txs,
        ),
    }

    VNEXT_DIR.mkdir(parents=True, exist_ok=True)
    batch_index: dict[str, dict] = {}
    for fname, batch_obj in batches.items():
        text = json.dumps(batch_obj, indent=2) + "\n"
        (VNEXT_DIR / fname).write_text(text, encoding="utf-8")
        batch_index[fname] = {
            "chainId": batch_obj["chainId"],
            "safeAddress": batch_obj["meta"]["createdFromSafeAddress"],
            "name": batch_obj["meta"]["name"],
            "transactionCount": len(batch_obj["transactions"]),
            "checksum": batch_obj["meta"]["checksum"],
            "sha256": sha256_hex(text.encode("utf-8")),
        }

    head_sha = subprocess.check_output(
        ["git", "-C", str(SPOOKY_ROOT), "rev-parse", "HEAD"], text=True
    ).strip()
    forge_ver = subprocess.check_output(["forge", "--version"], text=True).strip().splitlines()[0]

    manifest = {
        "schemaVersion": 3,
        "release": "vnext-bugpocer",
        "generatedAt": "2026-11-23",
        "sourceBranch": "fix/bugpocer-audit-remediation",
        "sourceCommit": head_sha,
        "txBuilderVersion": "1.16.5",
        "compiler": {
            "mode": "canonical-solc",
            "forge": forge_ver,
            "profiles": {
                "default": "solc 0.8.24 (paris, via_ir=true, optimizer_runs=200, bytecode_hash=ipfs)",
                "treasury-v3": "solc 0.8.24 (paris, via_ir=true, optimizer_runs=200, bytecode_hash=ipfs)",
                "fx-hub": "solc 0.8.26 (cancun, via_ir=true, optimizer_runs=200, bytecode_hash=ipfs)",
                "fx-cctp-forwarder": "solc 0.8.26 (cancun, via_ir=true, optimizer_runs=200, bytecode_hash=ipfs)",
                "claim-vault": "solc 0.8.23 (paris, optimizer_runs=99999)",
            },
        },
        "create2Factory": ARACHNID_CREATE2_FACTORY,
        "saltSuffix": SALT_SUFFIX,
        "batches": batch_index,
        "chains": {
            "5042002": {
                "name": "Arc Testnet",
                "safe": SAFE_AVALANCHE_AND_TESTNET,
                "contracts": t_addrs,
            },
            "5042": {
                "name": "Arc Mainnet",
                "safe": SAFE_ARC_MAINNET,
                "contracts": arc_addrs,
            },
            "43114": {
                "name": "Avalanche C-Chain Mainnet",
                "safe": SAFE_AVALANCHE_AND_TESTNET,
                "contracts": avax_addrs,
            },
            "8453": {
                "name": "Base Mainnet",
                "safe": SAFE_ARC_MAINNET,
                "notes": "0x47Dc7D18...0D09 has 0 code bytes on Base 8453 as of 2026-11-23; deploy 04a via MultiSendCallOnly (0x9641...02e2) or Base Safe once deployed, then run 04b from Base Safe.",
                "contracts": base_addrs,
            },
        },
        "bytecodeHashes": {
            k: {
                "artifact": v["rel_path"],
                "compiler": v["compiler"],
                "initcodeBytes": v["initcode_size"],
                "runtimeBytes": v["runtime_size"],
                "initcodeKeccak256": v["initcode_keccak256"],
                "initcodeSha256": v["initcode_sha256"],
                "runtimeKeccak256": v["runtime_keccak256"],
                "runtimeSha256": v["runtime_sha256"],
            }
            for k, v in sorted(arts.items())
        },
    }
    (VNEXT_DIR / "MANIFEST.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"Generated {len(batches)} vNext Safe Transaction Builder batches in {VNEXT_DIR}")
    for cid, cinfo in manifest["chains"].items():
        print(f"\n=== Chain {cid} ({cinfo['name']}, Safe={cinfo['safe']}) ===")
        for k, v in cinfo["contracts"].items():
            print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
