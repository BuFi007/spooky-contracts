#!/usr/bin/env python3
import hashlib
import json
import os
import subprocess
from pathlib import Path

SPOOKY_ROOT = Path("/Users/daniss/coding-dojo/spooky-contracts")
DESK_ROOT = Path("/Users/daniss/coding-dojo/desk-v1")

ARACHNID_CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C"
PERMIT2_CANONICAL = "0x000000000022D473030F116dDEE9F6B43aC78BA3"
COLD_STORAGE_ADDRESS_BOOK = "0x0000000d81083B16EA76dfab46B0315B0eDBF3d0"

SAFE_ARC_MAINNET = "0x47Dc7D18A6E3a79F696714E7D47456a49B430D09"
SAFE_AVALANCHE_AND_TESTNET = "0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B"

ARC_USDC = "0x3600000000000000000000000000000000000000"
ARC_EURC = "0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a"
AVAX_USDC = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E"
AVAX_EURC = "0xC891EB4cbdEFf6e073e859e987815Ed1505c2ACD"
BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

CCTP_MAINNET_TOKEN_MESSENGER = "0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d"
CCTP_MAINNET_MESSAGE_TRANSMITTER = "0x81D40F21F12A8F0E3252Bccb954D722d4c464B64"
CCTP_MAINNET_TOKEN_MINTER = "0xfd78EE919681417d192449715b2594ab58f5D002"
CCTPX_MAINNET_SERVICE = "0x431871229103b780868f8C6BB820cd16ECf942BC"

CCTP_TESTNET_TOKEN_MESSENGER = "0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA"
CCTP_TESTNET_MESSAGE_TRANSMITTER = "0xE737e5cEBEEBa77EFE34D4aa090756590b1CE275"
CCTP_TESTNET_TOKEN_MINTER = "0xb43db544E2c27092c107639Ad201b3dEfAbcF192"
CCTPX_TESTNET_SERVICE = "0x63753E722bd2C2A5DF6EE19C5106662208B81077"
CCTPX_TESTNET_EURC_MANAGER = "0xE5D6eacf2eD5A7F81cC89d2a216F004092c0C2E0"
CCTPX_TESTNET_CIRBTC_MANAGER = "0xb995F4060c38b7608626d0CCaBE547cdc2c7390A"

ARC_LIFI_DIAMOND = "0xA4072583658Fae592A3506A42431cb6316a8d40b"
ARC_UNISWAP_ROUTER = "0x8702463e73f74d0b6765aBceb314Ef07aCb92650"
ARC_UNISWAP_NO_PERMIT2_PROXY = "0x0000000085E102724e78eCd2F45DC9cA239Affad"
ARC_MORPHO_BITWISE_PAPY = "0x7610094B846657dCF166D59e42973db52c7015F9"
ARC_MORPHO_STEAKHOUSE_USDC = "0xbeef0016cb2Fd5C352ea7CA08a9f54739DFa7298"
ARC_ERC8004_MAINNET_IDENTITY = "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432"
ARC_ERC8004_TESTNET_IDENTITY = "0x8004A818BFB912233c491871b3d84c89A494BD9e"

AVAX_LIFI_DIAMOND = "0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE"
AVAX_UNISWAP_UNIVERSAL_ROUTER = "0x661E93cca42AfacB172121EF892830cA3b70F08d"
AVAX_UNISWAP_SWAP_ROUTER_02 = "0xbb00FF08d01D300023C629E8fFfFcb65A5a578cE"

CLAIM_VAULT_MFA_AUTHORIZER = "0x9c8515333aFdB567C31CDF53CD60868f3B64b724"
DEPLOYER_ISSUER_EOA = "0x09Ce8E2B3Fede2727dA4392Ea8Fe618305ba0474"
TELARANA_KEEPER_EOA = "0xcA02Be6cDBb806d4a327FC92E094D1A44EC37445"

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
ZERO_SALT = "0x" + "00" * 32
CREATED_AT_MS = 1793980800000

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
        if ch in "abcdef" and int(dh, 16) >= 8:
            out.append(ch.upper())
        else:
            out.append(ch)
    return "".join(out)


def compute_create2_address(salt_hex: str, initcode_hex: str, deployer: str = ARACHNID_CREATE2_FACTORY) -> str:
    deployer_bytes = bytes.fromhex(deployer.removeprefix("0x"))
    salt_bytes = bytes.fromhex(salt_hex.removeprefix("0x"))
    initcode_bytes = bytes.fromhex(initcode_hex.removeprefix("0x"))
    assert len(salt_bytes) == 32
    init_hash = keccak256(initcode_bytes)
    raw = keccak256(b"\xff" + deployer_bytes + salt_bytes + init_hash)
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
    raw = keccak256(rlp)
    return to_checksum_address("0x" + raw[-20:].hex())


def cast_abi_encode(sig: str, *args: str) -> str:
    cmd = ["cast", "abi-encode", sig, *args]
    res = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return res.stdout.strip().removeprefix("0x")


def cast_calldata(sig: str, *args: str) -> str:
    cmd = ["cast", "calldata", sig, *args]
    res = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return res.stdout.strip()


def load_artifact(rel_path: str) -> dict:
    full = SPOOKY_ROOT / "out" / rel_path
    with open(full, "r", encoding="utf-8") as f:
        data = json.load(f)
    bc = data["bytecode"]["object"].removeprefix("0x")
    dbc = data["deployedBytecode"]["object"].removeprefix("0x")
    bc_bytes = bytes.fromhex(bc)
    dbc_bytes = bytes.fromhex(dbc)
    return {
        "rel_path": rel_path,
        "abi": data["abi"],
        "initcode_hex": "0x" + bc,
        "runtime_hex": "0x" + dbc,
        "initcode_size": len(bc_bytes),
        "runtime_size": len(dbc_bytes),
        "initcode_keccak256": keccak256_hex(bc_bytes),
        "initcode_sha256": sha256_hex(bc_bytes),
        "runtime_keccak256": keccak256_hex(dbc_bytes),
        "runtime_sha256": sha256_hex(dbc_bytes),
    }


def salt_of(label: str) -> tuple[str, str]:
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


def canonical_json(value) -> str:
    if value is None or isinstance(value, (bool, int, float, str)):
        return json.dumps(value, separators=(",", ":"))
    if isinstance(value, list):
        return "[" + ",".join(canonical_json(item) for item in value) + "]"
    if isinstance(value, dict):
        keys = sorted(k for k, v in value.items() if v is not None)
        return "{" + ",".join(f"{json.dumps(k)}:{canonical_json(value[k])}" for k in keys) + "}"
    raise TypeError(f"Unsupported type: {type(value)}")


def main() -> None:
    assert keccak256_hex(b"") == "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"

    arts = {
        "TreasuryConduit": load_artifact("treasury/TreasuryConduit.sol/TreasuryConduit.json"),
        "TreasuryConduitPermit2": load_artifact("treasury/TreasuryConduitPermit2.sol/TreasuryConduitPermit2.json"),
        "TreasuryBridgeConduitV2": load_artifact("treasury/TreasuryBridgeConduitV2.sol/TreasuryBridgeConduitV2.json"),
        "TreasuryRedeemConduit": load_artifact("treasury/TreasuryRedeemConduit.sol/TreasuryRedeemConduit.json"),
        "TreasuryConduitV3": load_artifact("treasury-v3/TreasuryConduit.sol/TreasuryConduit.json"),
        "TreasuryBridgeConduit": load_artifact("treasury-v3/TreasuryBridgeConduit.sol/TreasuryBridgeConduit.json"),
        "TreasuryBridgeConduitPermit2": load_artifact(
            "treasury-v3/TreasuryBridgeConduitPermit2.sol/TreasuryBridgeConduitPermit2.json"
        ),
        "TreasuryRedeemConduitV3": load_artifact("treasury-v3/TreasuryRedeemConduit.sol/TreasuryRedeemConduit.json"),
        "TreasurySwapAndDeposit": load_artifact("treasury-v3/TreasurySwapAndDeposit.sol/TreasurySwapAndDeposit.json"),
        "BUFIIdentityRegistry": load_artifact("fx-hub/BUFIIdentityRegistry.sol/BUFIIdentityRegistry.json"),
        "BUFIReputationRegistry": load_artifact("fx-hub/BUFIReputationRegistry.sol/BUFIReputationRegistry.json"),
        "WorkspaceTierRegistry": load_artifact("fx-hub/WorkspaceTierRegistry.sol/WorkspaceTierRegistry.json"),
        "WorkspaceOperatingReserve": load_artifact(
            "fx-hub/WorkspaceOperatingReserve.sol/WorkspaceOperatingReserve.json"
        ),
        "InvoiceShelf": load_artifact("fx-hub/InvoiceShelf.sol/InvoiceShelf.json"),
        "BINV": load_artifact("fx-hub/BINV.sol/BINV.json"),
        "BIFTranche": load_artifact("fx-hub/BIFTranche.sol/BIFTranche.json"),
        "MultiTokenReceivableEscrow": load_artifact(
            "fx-hub/MultiTokenReceivableEscrow.sol/MultiTokenReceivableEscrow.json"
        ),
        "RecibuMemoRouter": load_artifact("fx-hub/RecibuMemoRouter.sol/RecibuMemoRouter.json"),
        "MemoConduit": load_artifact("fx-spoke/MemoConduit.sol/MemoConduit.json"),
        "SpokeMemoConduit": load_artifact("fx-spoke/SpokeMemoConduit.sol/SpokeMemoConduit.json"),
        "MemoConduitV1": load_artifact("fx-memo-v1/MemoConduit.sol/MemoConduit.json"),
        "DocumentReceivableRegistry": load_artifact(
            "fx-doc-registry/DocumentReceivableRegistry.sol/DocumentReceivableRegistry.json"
        ),
        "CctpDepositForwarder": load_artifact("fx-cctp-forwarder/CctpDepositForwarder.sol/CctpDepositForwarder.json"),
        "CctpDepositForwarderFactory": load_artifact(
            "fx-cctp-forwarder/CctpDepositForwarderFactory.sol/CctpDepositForwarderFactory.json"
        ),
        "RecibuSettlementGuardHook": load_artifact(
            "fx-stablefx/RecibuSettlementGuardHook.sol/RecibuSettlementGuardHook.json"
        ),
        "StrictAuthorityInvoiceVerifier": load_artifact(
            "fx-stablefx/StrictAuthorityInvoiceVerifier.sol/StrictAuthorityInvoiceVerifier.json"
        ),
        "StrictVerifierFactory": load_artifact(
            "fx-stablefx/StrictAuthorityInvoiceVerifier.sol/StrictVerifierFactory.json"
        ),
        "ClaimVaultDeployer": load_artifact("claim-vault/ClaimVaultDeployer.sol/ClaimVaultDeployer.json"),
        "PeanutV4": load_artifact("claim-vault/PeanutV4.4.sol/PeanutV4.json"),
        "PayrollBatch": load_artifact("claim-vault/PayrollBatch.sol/PayrollBatch.json"),
        "AgentGatewayAccount": load_artifact("agent-policy/AgentGatewayAccount.sol/AgentGatewayAccount.json"),
        "AgentGatewayAccountFactory": load_artifact(
            "agent-policy/AgentGatewayAccountFactory.sol/AgentGatewayAccountFactory.json"
        ),
        "GatewayIntentPolicy": load_artifact("agent-policy/GatewayIntentPolicy.sol/GatewayIntentPolicy.json"),
    }

    role_hashes = {
        "ISSUER_ROLE": keccak256_hex(b"ISSUER_ROLE"),
        "ATTESTOR_ROLE": keccak256_hex(b"ATTESTOR_ROLE"),
        "SETTLEMENT_ROLE": keccak256_hex(b"SETTLEMENT_ROLE"),
        "SERVICER_ROLE": keccak256_hex(b"SERVICER_ROLE"),
        "OPS_ROLE": keccak256_hex(b"OPS_ROLE"),
        "ADVANCE_ROLE": keccak256_hex(b"ADVANCE_ROLE"),
        "ROUTER_ROLE": keccak256_hex(b"ROUTER_ROLE"),
        "ARBITER_ROLE": keccak256_hex(b"ARBITER_ROLE"),
        "SHELF_ROLE": keccak256_hex(b"SHELF_ROLE"),
        "WRITER_ROLE": keccak256_hex(b"WRITER_ROLE"),
    }

    # =========================================================================
    # 1. Arc Mainnet (5042) — Treasury Conduits Batch
    # =========================================================================
    arc_treasury_txs: list[dict] = []
    arc_addrs: dict[str, str] = {}

    tc_init = arts["TreasuryConduit"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_ARC_MAINNET)
    tx, addr = make_create2_tx("Deploy TreasuryConduit (v2)", salt_of("bufi.treasury-conduit.v2"), tc_init)
    arc_treasury_txs.append(tx)
    arc_addrs["TreasuryConduit"] = addr

    tcp2_init = arts["TreasuryConduitPermit2"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address)", SAFE_ARC_MAINNET, PERMIT2_CANONICAL, COLD_STORAGE_ADDRESS_BOOK
    )
    tx, addr = make_create2_tx("Deploy TreasuryConduitPermit2", salt_of("bufi.treasury-conduit.permit2.v1"), tcp2_init)
    arc_treasury_txs.append(tx)
    arc_addrs["TreasuryConduitPermit2"] = addr

    tbcv2_init = arts["TreasuryBridgeConduitV2"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_ARC_MAINNET)
    tx, addr = make_create2_tx("Deploy TreasuryBridgeConduitV2", salt_of("bufi.treasury-bridge-conduit.v2"), tbcv2_init)
    arc_treasury_txs.append(tx)
    arc_addrs["TreasuryBridgeConduitV2"] = addr

    trc_init = arts["TreasuryRedeemConduit"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_ARC_MAINNET)
    tx, addr = make_create2_tx("Deploy TreasuryRedeemConduit (v2)", salt_of("bufi.treasury-redeem-conduit.v1"), trc_init)
    arc_treasury_txs.append(tx)
    arc_addrs["TreasuryRedeemConduit"] = addr

    tcv3_init = arts["TreasuryConduitV3"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_ARC_MAINNET)
    tx, addr = make_create2_tx("Deploy TreasuryConduit (v3 Ownable2Step)", salt_of("bufi.treasury-conduit.v3"), tcv3_init)
    arc_treasury_txs.append(tx)
    arc_addrs["TreasuryConduitV3"] = addr

    tbc_init = arts["TreasuryBridgeConduit"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_ARC_MAINNET)
    tx, addr = make_create2_tx("Deploy TreasuryBridgeConduit (v3 Ownable2Step)", salt_of("bufi.treasury-bridge-conduit.v1"), tbc_init)
    arc_treasury_txs.append(tx)
    arc_addrs["TreasuryBridgeConduit"] = addr

    tbcp2_init = arts["TreasuryBridgeConduitPermit2"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", SAFE_ARC_MAINNET, PERMIT2_CANONICAL
    )
    tx, addr = make_create2_tx(
        "Deploy TreasuryBridgeConduitPermit2 (v3 Ownable2Step)",
        salt_of("bufi.treasury-bridge-conduit.permit2.v1"),
        tbcp2_init,
    )
    arc_treasury_txs.append(tx)
    arc_addrs["TreasuryBridgeConduitPermit2"] = addr

    trcv3_init = arts["TreasuryRedeemConduitV3"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_ARC_MAINNET)
    tx, addr = make_create2_tx("Deploy TreasuryRedeemConduit (v3 Ownable2Step)", salt_of("bufi.treasury-redeem-conduit.v3"), trcv3_init)
    arc_treasury_txs.append(tx)
    arc_addrs["TreasuryRedeemConduitV3"] = addr

    tsad_init = arts["TreasurySwapAndDeposit"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", SAFE_ARC_MAINNET, ARC_USDC
    )
    tx, addr = make_create2_tx("Deploy TreasurySwapAndDeposit (v3 Ownable2Step)", salt_of("bufi.treasury-swap-deposit.v3"), tsad_init)
    arc_treasury_txs.append(tx)
    arc_addrs["TreasurySwapAndDeposit"] = addr

    # Post-deploy configuration for Arc Treasury Conduits
    for conduit_key in ["TreasuryConduit", "TreasuryConduitPermit2", "TreasuryConduitV3"]:
        for target_label, target_addr in [
            ("LI.FI Diamond", ARC_LIFI_DIAMOND),
            ("Uniswap 2.1.2 Router", ARC_UNISWAP_ROUTER),
            ("Uniswap No-Permit2 Swap Proxy", ARC_UNISWAP_NO_PERMIT2_PROXY),
            ("Morpho Bitwise PAPY Vault", ARC_MORPHO_BITWISE_PAPY),
            ("Morpho Steakhouse USDC Vault", ARC_MORPHO_STEAKHOUSE_USDC),
        ]:
            arc_treasury_txs.append(
                make_call_tx(
                    arc_addrs[conduit_key],
                    f"{conduit_key}.setTarget({target_label}, true)",
                    "setTarget",
                    [("target", "address", target_addr), ("allowed", "bool", "true")],
                    "setTarget(address,bool)",
                    [target_addr, "true"],
                )
            )

    for target_label, target_addr in [
        ("LI.FI Diamond", ARC_LIFI_DIAMOND),
        ("Uniswap 2.1.2 Router", ARC_UNISWAP_ROUTER),
        ("Morpho Bitwise PAPY Vault", ARC_MORPHO_BITWISE_PAPY),
        ("Morpho Steakhouse USDC Vault", ARC_MORPHO_STEAKHOUSE_USDC),
    ]:
        arc_treasury_txs.append(
            make_call_tx(
                arc_addrs["TreasuryConduitPermit2"],
                f"TreasuryConduitPermit2.setPermit2Route({target_label}, {target_label}, true)",
                "setPermit2Route",
                [
                    ("target", "address", target_addr),
                    ("allowanceTarget", "address", target_addr),
                    ("allowed", "bool", "true"),
                ],
                "setPermit2Route(address,address,bool)",
                [target_addr, target_addr, "true"],
            )
        )

    for bridge_conduit_key in ["TreasuryBridgeConduitV2", "TreasuryBridgeConduit", "TreasuryBridgeConduitPermit2"]:
        arc_treasury_txs.append(
            make_call_tx(
                arc_addrs[bridge_conduit_key],
                f"{bridge_conduit_key}.setTarget(LI.FI Diamond, true)",
                "setTarget",
                [("target", "address", ARC_LIFI_DIAMOND), ("allowed", "bool", "true")],
                "setTarget(address,bool)",
                [ARC_LIFI_DIAMOND, "true"],
            )
        )
        arc_treasury_txs.append(
            make_call_tx(
                arc_addrs[bridge_conduit_key],
                f"{bridge_conduit_key}.setBridge(CctpV2=0, TokenMessengerV2, true)",
                "setBridge",
                [
                    ("kind", "uint8", "0"),
                    ("bridge", "address", CCTP_MAINNET_TOKEN_MESSENGER),
                    ("allowed", "bool", "true"),
                ],
                "setBridge(uint8,address,bool)",
                ["0", CCTP_MAINNET_TOKEN_MESSENGER, "true"],
            )
        )
        arc_treasury_txs.append(
            make_call_tx(
                arc_addrs[bridge_conduit_key],
                f"{bridge_conduit_key}.setBridge(Cctpx=1, CrossChainTokenService, true)",
                "setBridge",
                [
                    ("kind", "uint8", "1"),
                    ("bridge", "address", CCTPX_MAINNET_SERVICE),
                    ("allowed", "bool", "true"),
                ],
                "setBridge(uint8,address,bool)",
                ["1", CCTPX_MAINNET_SERVICE, "true"],
            )
        )

    for bridge_target_label, bridge_target_addr in [
        ("LI.FI Diamond", ARC_LIFI_DIAMOND),
        ("CCTP TokenMessengerV2", CCTP_MAINNET_TOKEN_MESSENGER),
        ("CCTPx CrossChainTokenService", CCTPX_MAINNET_SERVICE),
    ]:
        arc_treasury_txs.append(
            make_call_tx(
                arc_addrs["TreasuryBridgeConduitPermit2"],
                f"TreasuryBridgeConduitPermit2.setPermit2Route({bridge_target_label}, {bridge_target_label}, true)",
                "setPermit2Route",
                [
                    ("target", "address", bridge_target_addr),
                    ("allowanceTarget", "address", bridge_target_addr),
                    ("allowed", "bool", "true"),
                ],
                "setPermit2Route(address,address,bool)",
                [bridge_target_addr, bridge_target_addr, "true"],
            )
        )

    for redeem_key in ["TreasuryRedeemConduit", "TreasuryRedeemConduitV3"]:
        for vault_label, vault_addr in [
            ("Morpho Bitwise PAPY Vault", ARC_MORPHO_BITWISE_PAPY),
            ("Morpho Steakhouse USDC Vault", ARC_MORPHO_STEAKHOUSE_USDC),
        ]:
            arc_treasury_txs.append(
                make_call_tx(
                    arc_addrs[redeem_key],
                    f"{redeem_key}.setVault({vault_label}, true)",
                    "setVault",
                    [("vault", "address", vault_addr), ("allowed", "bool", "true")],
                    "setVault(address,bool)",
                    [vault_addr, "true"],
                )
            )

    arc_treasury_txs.append(
        make_call_tx(
            arc_addrs["TreasurySwapAndDeposit"],
            "TreasurySwapAndDeposit.setVenue(Uniswap No-Permit2 Swap Proxy, true)",
            "setVenue",
            [("venue", "address", ARC_UNISWAP_NO_PERMIT2_PROXY), ("allowed", "bool", "true")],
            "setVenue(address,bool)",
            [ARC_UNISWAP_NO_PERMIT2_PROXY, "true"],
        )
    )
    for vault_label, vault_addr in [
        ("Morpho Bitwise PAPY Vault", ARC_MORPHO_BITWISE_PAPY),
        ("Morpho Steakhouse USDC Vault", ARC_MORPHO_STEAKHOUSE_USDC),
    ]:
        arc_treasury_txs.append(
            make_call_tx(
                arc_addrs["TreasurySwapAndDeposit"],
                f"TreasurySwapAndDeposit.setDest({vault_label}, true)",
                "setDest",
                [("dest", "address", vault_addr), ("allowed", "bool", "true")],
                "setDest(address,bool)",
                [vault_addr, "true"],
            )
        )

    # =========================================================================
    # 2. Arc Mainnet (5042) — FX-Recibú Hub & Registries Batch
    # =========================================================================
    arc_hub_txs: list[dict] = []

    id_init = arts["BUFIIdentityRegistry"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_ARC_MAINNET)
    tx, addr = make_create2_tx("Deploy BUFIIdentityRegistry", salt_of("bufi.identity-registry.v1"), id_init)
    arc_hub_txs.append(tx)
    arc_addrs["BUFIIdentityRegistry"] = addr

    rep_init = arts["BUFIReputationRegistry"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", SAFE_ARC_MAINNET, arc_addrs["BUFIIdentityRegistry"]
    )
    tx, addr = make_create2_tx("Deploy BUFIReputationRegistry", salt_of("bufi.reputation-registry.v1"), rep_init)
    arc_hub_txs.append(tx)
    arc_addrs["BUFIReputationRegistry"] = addr

    tiers_init = arts["WorkspaceTierRegistry"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", arc_addrs["BUFIIdentityRegistry"], arc_addrs["BUFIReputationRegistry"]
    )
    tx, addr = make_create2_tx("Deploy WorkspaceTierRegistry", salt_of("bufi.workspace-tier-registry.v1"), tiers_init)
    arc_hub_txs.append(tx)
    arc_addrs["WorkspaceTierRegistry"] = addr

    res_init = arts["WorkspaceOperatingReserve"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", ARC_USDC, SAFE_ARC_MAINNET
    )
    tx, addr = make_create2_tx("Deploy WorkspaceOperatingReserve", salt_of("bufi.workspace-operating-reserve.v1"), res_init)
    arc_hub_txs.append(tx)
    arc_addrs["WorkspaceOperatingReserve"] = addr

    shelf_init = arts["InvoiceShelf"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address,address,address,bool)",
        ARC_USDC,
        arc_addrs["BUFIIdentityRegistry"],
        arc_addrs["BUFIReputationRegistry"],
        arc_addrs["WorkspaceTierRegistry"],
        SAFE_ARC_MAINNET,
        "false",
    )
    tx, addr = make_create2_tx("Deploy InvoiceShelf (spawns BINV + bIF-A/B/C Tranches)", salt_of("bufi.invoice-shelf.v1"), shelf_init)
    arc_hub_txs.append(tx)
    arc_addrs["InvoiceShelf"] = addr
    arc_addrs["BINV"] = compute_create_address(addr, 1)
    arc_addrs["BIFTrancheSenior_bIF_A"] = compute_create_address(addr, 2)
    arc_addrs["BIFTrancheMezzanine_bIF_B"] = compute_create_address(addr, 3)
    arc_addrs["BIFTrancheJunior_bIF_C"] = compute_create_address(addr, 4)

    escrow_init = arts["MultiTokenReceivableEscrow"]["initcode_hex"] + cast_abi_encode("f(address)", SAFE_ARC_MAINNET)
    tx, addr = make_create2_tx("Deploy MultiTokenReceivableEscrow", salt_of("bufi.multi-token-receivable-escrow.v1"), escrow_init)
    arc_hub_txs.append(tx)
    arc_addrs["MultiTokenReceivableEscrow"] = addr

    router_init = arts["RecibuMemoRouter"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address)",
        arc_addrs["InvoiceShelf"],
        arc_addrs["MultiTokenReceivableEscrow"],
        SAFE_ARC_MAINNET,
    )
    tx, addr = make_create2_tx("Deploy RecibuMemoRouter", salt_of("bufi.recibu-memo-router.v1"), router_init)
    arc_hub_txs.append(tx)
    arc_addrs["RecibuMemoRouter"] = addr

    cctp_mainnet_tuple = (
        f"({CCTP_MAINNET_TOKEN_MESSENGER},{CCTP_MAINNET_MESSAGE_TRANSMITTER},"
        f"{CCTP_MAINNET_TOKEN_MINTER},{CCTPX_MAINNET_SERVICE},{ZERO_ADDRESS},{ZERO_ADDRESS})"
    )
    memo_arc_init = arts["MemoConduit"]["initcode_hex"] + cast_abi_encode(
        "f(address,address[],(address,address,address,address,address,address))",
        COLD_STORAGE_ADDRESS_BOOK,
        f"[{ARC_USDC},{ARC_EURC}]",
        cctp_mainnet_tuple,
    )
    tx, addr = make_create2_tx("Deploy MemoConduit (CCTP v2 + Local ERC-3009)", salt_of("bufi.memo-conduit.cctp.v1"), memo_arc_init)
    arc_hub_txs.append(tx)
    arc_addrs["MemoConduit"] = addr

    memo_v1_arc_init = arts["MemoConduitV1"]["initcode_hex"] + cast_abi_encode(
        "f(address,address[])",
        COLD_STORAGE_ADDRESS_BOOK,
        f"[{ARC_USDC},{ARC_EURC}]",
    )
    tx, addr = make_create2_tx("Deploy MemoConduitV1 (Local ERC-3009 Only)", salt_of("bufi.memo-conduit.v1"), memo_v1_arc_init)
    arc_hub_txs.append(tx)
    arc_addrs["MemoConduitV1"] = addr

    doc_reg_init = arts["DocumentReceivableRegistry"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", SAFE_ARC_MAINNET, ARC_ERC8004_MAINNET_IDENTITY
    )
    tx, addr = make_create2_tx("Deploy DocumentReceivableRegistry", salt_of("bufi.document-receivable-registry.v1"), doc_reg_init)
    arc_hub_txs.append(tx)
    arc_addrs["DocumentReceivableRegistry"] = addr

    cctp_fwd_impl_init = arts["CctpDepositForwarder"]["initcode_hex"]
    tx, addr = make_create2_tx("Deploy CctpDepositForwarder Implementation", salt_of("bufi.cctp-deposit-forwarder.v1.implementation"), cctp_fwd_impl_init)
    arc_hub_txs.append(tx)
    arc_addrs["CctpDepositForwarderImplementation"] = addr

    cctp_fwd_factory_init = arts["CctpDepositForwarderFactory"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address)",
        arc_addrs["CctpDepositForwarderImplementation"],
        ARC_USDC,
        CCTP_MAINNET_TOKEN_MESSENGER,
    )
    tx, addr = make_create2_tx("Deploy CctpDepositForwarderFactory", salt_of("bufi.cctp-deposit-forwarder.v1.factory"), cctp_fwd_factory_init)
    arc_hub_txs.append(tx)
    arc_addrs["CctpDepositForwarderFactory"] = addr

    # Post-deploy role grants and wiring for FX-Recibú Hub
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["BUFIIdentityRegistry"],
            "BUFIIdentityRegistry.grantRole(ISSUER_ROLE, Safe)",
            "grantRole",
            [("role", "bytes32", role_hashes["ISSUER_ROLE"]), ("account", "address", SAFE_ARC_MAINNET)],
            "grantRole(bytes32,address)",
            [role_hashes["ISSUER_ROLE"], SAFE_ARC_MAINNET],
        )
    )
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["BUFIIdentityRegistry"],
            "BUFIIdentityRegistry.grantRole(ISSUER_ROLE, Deployer/Issuer EOA)",
            "grantRole",
            [("role", "bytes32", role_hashes["ISSUER_ROLE"]), ("account", "address", DEPLOYER_ISSUER_EOA)],
            "grantRole(bytes32,address)",
            [role_hashes["ISSUER_ROLE"], DEPLOYER_ISSUER_EOA],
        )
    )
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["BUFIReputationRegistry"],
            "BUFIReputationRegistry.grantRole(ATTESTOR_ROLE, Safe)",
            "grantRole",
            [("role", "bytes32", role_hashes["ATTESTOR_ROLE"]), ("account", "address", SAFE_ARC_MAINNET)],
            "grantRole(bytes32,address)",
            [role_hashes["ATTESTOR_ROLE"], SAFE_ARC_MAINNET],
        )
    )
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["BUFIReputationRegistry"],
            "BUFIReputationRegistry.grantRole(SETTLEMENT_ROLE, InvoiceShelf)",
            "grantRole",
            [("role", "bytes32", role_hashes["SETTLEMENT_ROLE"]), ("account", "address", arc_addrs["InvoiceShelf"])],
            "grantRole(bytes32,address)",
            [role_hashes["SETTLEMENT_ROLE"], arc_addrs["InvoiceShelf"]],
        )
    )
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["WorkspaceOperatingReserve"],
            "WorkspaceOperatingReserve.grantRole(SHELF_ROLE, InvoiceShelf)",
            "grantRole",
            [("role", "bytes32", role_hashes["SHELF_ROLE"]), ("account", "address", arc_addrs["InvoiceShelf"])],
            "grantRole(bytes32,address)",
            [role_hashes["SHELF_ROLE"], arc_addrs["InvoiceShelf"]],
        )
    )
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["InvoiceShelf"],
            "InvoiceShelf.setReserve(WorkspaceOperatingReserve)",
            "setReserve",
            [("reserve_", "address", arc_addrs["WorkspaceOperatingReserve"])],
            "setReserve(address)",
            [arc_addrs["WorkspaceOperatingReserve"]],
        )
    )
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["InvoiceShelf"],
            "InvoiceShelf.setEscrow(MultiTokenReceivableEscrow)",
            "setEscrow",
            [("escrow_", "address", arc_addrs["MultiTokenReceivableEscrow"])],
            "setEscrow(address)",
            [arc_addrs["MultiTokenReceivableEscrow"]],
        )
    )
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["InvoiceShelf"],
            "InvoiceShelf.grantRole(SERVICER_ROLE, Safe)",
            "grantRole",
            [("role", "bytes32", role_hashes["SERVICER_ROLE"]), ("account", "address", SAFE_ARC_MAINNET)],
            "grantRole(bytes32,address)",
            [role_hashes["SERVICER_ROLE"], SAFE_ARC_MAINNET],
        )
    )
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["InvoiceShelf"],
            "InvoiceShelf.grantRole(SETTLEMENT_ROLE, Safe)",
            "grantRole",
            [("role", "bytes32", role_hashes["SETTLEMENT_ROLE"]), ("account", "address", SAFE_ARC_MAINNET)],
            "grantRole(bytes32,address)",
            [role_hashes["SETTLEMENT_ROLE"], SAFE_ARC_MAINNET],
        )
    )
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["InvoiceShelf"],
            "InvoiceShelf.grantRole(OPS_ROLE, Telarana Keeper EOA)",
            "grantRole",
            [("role", "bytes32", role_hashes["OPS_ROLE"]), ("account", "address", TELARANA_KEEPER_EOA)],
            "grantRole(bytes32,address)",
            [role_hashes["OPS_ROLE"], TELARANA_KEEPER_EOA],
        )
    )
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["MultiTokenReceivableEscrow"],
            "MultiTokenReceivableEscrow.setToken(ARC_USDC, true)",
            "setToken",
            [("token", "address", ARC_USDC), ("supported", "bool", "true")],
            "setToken(address,bool)",
            [ARC_USDC, "true"],
        )
    )
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["MultiTokenReceivableEscrow"],
            "MultiTokenReceivableEscrow.setToken(ARC_EURC, true)",
            "setToken",
            [("token", "address", ARC_EURC), ("supported", "bool", "true")],
            "setToken(address,bool)",
            [ARC_EURC, "true"],
        )
    )
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["MultiTokenReceivableEscrow"],
            "MultiTokenReceivableEscrow.grantRole(ROUTER_ROLE, RecibuMemoRouter)",
            "grantRole",
            [("role", "bytes32", role_hashes["ROUTER_ROLE"]), ("account", "address", arc_addrs["RecibuMemoRouter"])],
            "grantRole(bytes32,address)",
            [role_hashes["ROUTER_ROLE"], arc_addrs["RecibuMemoRouter"]],
        )
    )
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["RecibuMemoRouter"],
            "RecibuMemoRouter.setToken(ARC_USDC, true, CAP_3009|CAP_PERMIT=3)",
            "setToken",
            [("token", "address", ARC_USDC), ("allowed", "bool", "true"), ("caps", "uint8", "3")],
            "setToken(address,bool,uint8)",
            [ARC_USDC, "true", "3"],
        )
    )
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["RecibuMemoRouter"],
            "RecibuMemoRouter.setToken(ARC_EURC, true, CAP_3009|CAP_PERMIT=3)",
            "setToken",
            [("token", "address", ARC_EURC), ("allowed", "bool", "true"), ("caps", "uint8", "3")],
            "setToken(address,bool,uint8)",
            [ARC_EURC, "true", "3"],
        )
    )
    arc_hub_txs.append(
        make_call_tx(
            arc_addrs["DocumentReceivableRegistry"],
            "DocumentReceivableRegistry.grantRole(WRITER_ROLE, Safe)",
            "grantRole",
            [("role", "bytes32", role_hashes["WRITER_ROLE"]), ("account", "address", SAFE_ARC_MAINNET)],
            "grantRole(bytes32,address)",
            [role_hashes["WRITER_ROLE"], SAFE_ARC_MAINNET],
        )
    )

    # =========================================================================
    # 3. Arc Mainnet (5042) — ClaimVault (PeanutV4.4) + PayrollBatch + AgentPolicy
    # =========================================================================
    arc_vault_agent_txs: list[dict] = []

    cvd_init = arts["ClaimVaultDeployer"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", SAFE_ARC_MAINNET, CLAIM_VAULT_MFA_AUTHORIZER
    )
    tx, cvd_addr = make_create2_tx(
        "Deploy ClaimVaultDeployer (deploys PeanutV4.4 MFA Vault & initiates transferOwnership to Safe)",
        salt_of("bufi.claim-vault.deployer.v1"),
        cvd_init,
    )
    peanut_v4_addr = compute_create_address(cvd_addr, 1)
    tx["meta"]["spawnedVaultAddress"] = peanut_v4_addr
    arc_vault_agent_txs.append(tx)
    arc_addrs["ClaimVaultDeployer"] = cvd_addr
    arc_addrs["PeanutV4"] = peanut_v4_addr

    arc_vault_agent_txs.append(
        make_call_tx(
            peanut_v4_addr,
            "PeanutV4.acceptOwnership() (completes Ownable2Step handover to Safe)",
            "acceptOwnership",
            [],
            "acceptOwnership()",
            [],
        )
    )

    pb_init = arts["PayrollBatch"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", PERMIT2_CANONICAL, peanut_v4_addr
    )
    tx, pb_addr = make_create2_tx("Deploy PayrollBatch (Permit2 -> PeanutV4.4 Vault)", salt_of("bufi.payroll-batch.v1"), pb_init)
    arc_vault_agent_txs.append(tx)
    arc_addrs["PayrollBatch"] = pb_addr

    agaf_init = arts["AgentGatewayAccountFactory"]["initcode_hex"] + cast_abi_encode(
        "f(address)", SAFE_ARC_MAINNET
    )
    tx, agaf_addr = make_create2_tx("Deploy AgentGatewayAccountFactory", salt_of("bufi.agent-gateway-account-factory.v1"), agaf_init)
    arc_vault_agent_txs.append(tx)
    arc_addrs["AgentGatewayAccountFactory"] = agaf_addr

    for issuer_label, issuer_addr in [
        ("Safe", SAFE_ARC_MAINNET),
        ("Deployer/Issuer EOA", DEPLOYER_ISSUER_EOA),
    ]:
        arc_vault_agent_txs.append(
            make_call_tx(
                agaf_addr,
                f"AgentGatewayAccountFactory.setIssuer({issuer_label}, true)",
                "setIssuer",
                [("issuer", "address", issuer_addr), ("allowed", "bool", "true")],
                "setIssuer(address,bool)",
                [issuer_addr, "true"],
            )
        )

    # =========================================================================
    # 4. Avalanche C-Chain Mainnet (43114) — Conduits, SpokeMemoConduit, CCTP Forwarder
    # =========================================================================
    avax_txs: list[dict] = []
    avax_addrs: dict[str, str] = {}

    avax_tc_init = arts["TreasuryConduit"]["initcode_hex"] + cast_abi_encode(
        "f(address)", SAFE_AVALANCHE_AND_TESTNET
    )
    tx, addr = make_create2_tx("Deploy TreasuryConduit (v2)", salt_of("bufi.treasury-conduit.v2"), avax_tc_init)
    avax_txs.append(tx)
    avax_addrs["TreasuryConduit"] = addr

    avax_tcp2_init = arts["TreasuryConduitPermit2"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address)",
        SAFE_AVALANCHE_AND_TESTNET,
        PERMIT2_CANONICAL,
        COLD_STORAGE_ADDRESS_BOOK,
    )
    tx, addr = make_create2_tx("Deploy TreasuryConduitPermit2", salt_of("bufi.treasury-conduit.permit2.v1"), avax_tcp2_init)
    avax_txs.append(tx)
    avax_addrs["TreasuryConduitPermit2"] = addr

    avax_tbcv2_init = arts["TreasuryBridgeConduitV2"]["initcode_hex"] + cast_abi_encode(
        "f(address)", SAFE_AVALANCHE_AND_TESTNET
    )
    tx, addr = make_create2_tx("Deploy TreasuryBridgeConduitV2", salt_of("bufi.treasury-bridge-conduit.v2"), avax_tbcv2_init)
    avax_txs.append(tx)
    avax_addrs["TreasuryBridgeConduitV2"] = addr

    avax_tbc_init = arts["TreasuryBridgeConduit"]["initcode_hex"] + cast_abi_encode(
        "f(address)", SAFE_AVALANCHE_AND_TESTNET
    )
    tx, addr = make_create2_tx("Deploy TreasuryBridgeConduit (v3 Ownable2Step)", salt_of("bufi.treasury-bridge-conduit.v1"), avax_tbc_init)
    avax_txs.append(tx)
    avax_addrs["TreasuryBridgeConduit"] = addr

    avax_tbcp2_init = arts["TreasuryBridgeConduitPermit2"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", SAFE_AVALANCHE_AND_TESTNET, PERMIT2_CANONICAL
    )
    tx, addr = make_create2_tx(
        "Deploy TreasuryBridgeConduitPermit2 (v3 Ownable2Step)",
        salt_of("bufi.treasury-bridge-conduit.permit2.v1"),
        avax_tbcp2_init,
    )
    avax_txs.append(tx)
    avax_addrs["TreasuryBridgeConduitPermit2"] = addr

    spoke_avax_init = arts["SpokeMemoConduit"]["initcode_hex"] + cast_abi_encode(
        "f(address,address[],(address,address,address,address,address,address))",
        COLD_STORAGE_ADDRESS_BOOK,
        f"[{AVAX_USDC},{AVAX_EURC}]",
        cctp_mainnet_tuple,
    )
    tx, addr = make_create2_tx(
        "Deploy SpokeMemoConduit (Avalanche -> Arc Hub Repayment + Checkout)",
        salt_of("bufi.spoke-memo-conduit.cctp.v1"),
        spoke_avax_init,
    )
    avax_txs.append(tx)
    avax_addrs["SpokeMemoConduit"] = addr

    memo_avax_init = arts["MemoConduit"]["initcode_hex"] + cast_abi_encode(
        "f(address,address[],(address,address,address,address,address,address))",
        COLD_STORAGE_ADDRESS_BOOK,
        f"[{AVAX_USDC},{AVAX_EURC}]",
        cctp_mainnet_tuple,
    )
    tx, addr = make_create2_tx(
        "Deploy MemoConduit (Avalanche <-> Arc Bidirectional Checkout)",
        salt_of("bufi.memo-conduit.cctp.v1"),
        memo_avax_init,
    )
    avax_txs.append(tx)
    avax_addrs["MemoConduit"] = addr

    tx, addr = make_create2_tx(
        "Deploy CctpDepositForwarder Implementation",
        salt_of("bufi.cctp-deposit-forwarder.v1.implementation"),
        cctp_fwd_impl_init,
    )
    avax_txs.append(tx)
    avax_addrs["CctpDepositForwarderImplementation"] = addr

    avax_fwd_factory_init = arts["CctpDepositForwarderFactory"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address)",
        avax_addrs["CctpDepositForwarderImplementation"],
        AVAX_USDC,
        CCTP_MAINNET_TOKEN_MESSENGER,
    )
    tx, addr = make_create2_tx(
        "Deploy CctpDepositForwarderFactory (Avalanche)",
        salt_of("bufi.cctp-deposit-forwarder.v1.factory"),
        avax_fwd_factory_init,
    )
    avax_txs.append(tx)
    avax_addrs["CctpDepositForwarderFactory"] = addr

    for conduit_key in ["TreasuryConduit", "TreasuryConduitPermit2"]:
        for target_label, target_addr in [
            ("LI.FI Diamond", AVAX_LIFI_DIAMOND),
            ("Uniswap Universal Router", AVAX_UNISWAP_UNIVERSAL_ROUTER),
            ("Uniswap SwapRouter02", AVAX_UNISWAP_SWAP_ROUTER_02),
        ]:
            avax_txs.append(
                make_call_tx(
                    avax_addrs[conduit_key],
                    f"{conduit_key}.setTarget({target_label}, true)",
                    "setTarget",
                    [("target", "address", target_addr), ("allowed", "bool", "true")],
                    "setTarget(address,bool)",
                    [target_addr, "true"],
                )
            )
            if conduit_key == "TreasuryConduitPermit2":
                avax_txs.append(
                    make_call_tx(
                        avax_addrs[conduit_key],
                        f"TreasuryConduitPermit2.setPermit2Route({target_label}, {target_label}, true)",
                        "setPermit2Route",
                        [
                            ("target", "address", target_addr),
                            ("allowanceTarget", "address", target_addr),
                            ("allowed", "bool", "true"),
                        ],
                        "setPermit2Route(address,address,bool)",
                        [target_addr, target_addr, "true"],
                    )
                )

    for bridge_conduit_key in ["TreasuryBridgeConduitV2", "TreasuryBridgeConduit", "TreasuryBridgeConduitPermit2"]:
        avax_txs.append(
            make_call_tx(
                avax_addrs[bridge_conduit_key],
                f"{bridge_conduit_key}.setTarget(LI.FI Diamond, true)",
                "setTarget",
                [("target", "address", AVAX_LIFI_DIAMOND), ("allowed", "bool", "true")],
                "setTarget(address,bool)",
                [AVAX_LIFI_DIAMOND, "true"],
            )
        )
        avax_txs.append(
            make_call_tx(
                avax_addrs[bridge_conduit_key],
                f"{bridge_conduit_key}.setBridge(CctpV2=0, TokenMessengerV2, true)",
                "setBridge",
                [
                    ("kind", "uint8", "0"),
                    ("bridge", "address", CCTP_MAINNET_TOKEN_MESSENGER),
                    ("allowed", "bool", "true"),
                ],
                "setBridge(uint8,address,bool)",
                ["0", CCTP_MAINNET_TOKEN_MESSENGER, "true"],
            )
        )
        avax_txs.append(
            make_call_tx(
                avax_addrs[bridge_conduit_key],
                f"{bridge_conduit_key}.setBridge(Cctpx=1, CrossChainTokenService, true)",
                "setBridge",
                [
                    ("kind", "uint8", "1"),
                    ("bridge", "address", CCTPX_MAINNET_SERVICE),
                    ("allowed", "bool", "true"),
                ],
                "setBridge(uint8,address,bool)",
                ["1", CCTPX_MAINNET_SERVICE, "true"],
            )
        )

    for bridge_target_label, bridge_target_addr in [
        ("LI.FI Diamond", AVAX_LIFI_DIAMOND),
        ("CCTP TokenMessengerV2", CCTP_MAINNET_TOKEN_MESSENGER),
        ("CCTPx CrossChainTokenService", CCTPX_MAINNET_SERVICE),
    ]:
        avax_txs.append(
            make_call_tx(
                avax_addrs["TreasuryBridgeConduitPermit2"],
                f"TreasuryBridgeConduitPermit2.setPermit2Route({bridge_target_label}, {bridge_target_label}, true)",
                "setPermit2Route",
                [
                    ("target", "address", bridge_target_addr),
                    ("allowanceTarget", "address", bridge_target_addr),
                    ("allowed", "bool", "true"),
                ],
                "setPermit2Route(address,address,bool)",
                [bridge_target_addr, bridge_target_addr, "true"],
            )
        )

    # =========================================================================
    # 5. Arc Testnet (5042002) — Master Batch
    # =========================================================================
    arc_testnet_txs: list[dict] = []
    arc_testnet_addrs: dict[str, str] = {}

    tx, addr = make_create2_tx("Deploy TreasuryConduit (v2)", salt_of("bufi.treasury-conduit.v2"), avax_tc_init)
    arc_testnet_txs.append(tx)
    arc_testnet_addrs["TreasuryConduit"] = addr

    tx, addr = make_create2_tx("Deploy TreasuryConduitPermit2", salt_of("bufi.treasury-conduit.permit2.v1"), avax_tcp2_init)
    arc_testnet_txs.append(tx)
    arc_testnet_addrs["TreasuryConduitPermit2"] = addr

    tx, addr = make_create2_tx("Deploy TreasuryBridgeConduitV2", salt_of("bufi.treasury-bridge-conduit.v2"), avax_tbcv2_init)
    arc_testnet_txs.append(tx)
    arc_testnet_addrs["TreasuryBridgeConduitV2"] = addr

    testnet_agaf_init = arts["AgentGatewayAccountFactory"]["initcode_hex"] + cast_abi_encode(
        "f(address)", SAFE_AVALANCHE_AND_TESTNET
    )
    tx, addr = make_create2_tx("Deploy AgentGatewayAccountFactory (Arc Testnet)", salt_of("bufi.agent-gateway-account-factory.v1"), testnet_agaf_init)
    arc_testnet_txs.append(tx)
    arc_testnet_addrs["AgentGatewayAccountFactory"] = addr

    for issuer_label, issuer_addr in [
        ("Safe", SAFE_AVALANCHE_AND_TESTNET),
        ("Deployer/Issuer EOA", DEPLOYER_ISSUER_EOA),
    ]:
        arc_testnet_txs.append(
            make_call_tx(
                arc_testnet_addrs["AgentGatewayAccountFactory"],
                f"AgentGatewayAccountFactory.setIssuer({issuer_label}, true)",
                "setIssuer",
                [("issuer", "address", issuer_addr), ("allowed", "bool", "true")],
                "setIssuer(address,bool)",
                [issuer_addr, "true"],
            )
        )

    testnet_doc_reg_init = arts["DocumentReceivableRegistry"]["initcode_hex"] + cast_abi_encode(
        "f(address,address)", SAFE_AVALANCHE_AND_TESTNET, ARC_ERC8004_TESTNET_IDENTITY
    )
    tx, addr = make_create2_tx("Deploy DocumentReceivableRegistry (Arc Testnet)", salt_of("bufi.document-receivable-registry.v1"), testnet_doc_reg_init)
    arc_testnet_txs.append(tx)
    arc_testnet_addrs["DocumentReceivableRegistry"] = addr

    cctp_testnet_tuple = (
        f"({CCTP_TESTNET_TOKEN_MESSENGER},{CCTP_TESTNET_MESSAGE_TRANSMITTER},"
        f"{CCTP_TESTNET_TOKEN_MINTER},{CCTPX_TESTNET_SERVICE},"
        f"{CCTPX_TESTNET_EURC_MANAGER},{CCTPX_TESTNET_CIRBTC_MANAGER})"
    )
    memo_testnet_init = arts["MemoConduit"]["initcode_hex"] + cast_abi_encode(
        "f(address,address[],(address,address,address,address,address,address))",
        COLD_STORAGE_ADDRESS_BOOK,
        f"[{ARC_USDC},{ARC_EURC}]",
        cctp_testnet_tuple,
    )
    tx, addr = make_create2_tx("Deploy MemoConduit (Arc Testnet)", salt_of("bufi.memo-conduit.cctp.v1"), memo_testnet_init)
    arc_testnet_txs.append(tx)
    arc_testnet_addrs["MemoConduit"] = addr

    tx, addr = make_create2_tx(
        "Deploy CctpDepositForwarder Implementation",
        salt_of("bufi.cctp-deposit-forwarder.v1.implementation"),
        cctp_fwd_impl_init,
    )
    arc_testnet_txs.append(tx)
    arc_testnet_addrs["CctpDepositForwarderImplementation"] = addr

    testnet_fwd_factory_init = arts["CctpDepositForwarderFactory"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address)",
        arc_testnet_addrs["CctpDepositForwarderImplementation"],
        ARC_USDC,
        CCTP_TESTNET_TOKEN_MESSENGER,
    )
    tx, addr = make_create2_tx(
        "Deploy CctpDepositForwarderFactory (Arc Testnet)",
        salt_of("bufi.cctp-deposit-forwarder.v1.factory"),
        testnet_fwd_factory_init,
    )
    arc_testnet_txs.append(tx)
    arc_testnet_addrs["CctpDepositForwarderFactory"] = addr

    # =========================================================================
    # 6. Base Mainnet (8453) — CCTP Deposit Forwarder Batch
    # =========================================================================
    base_txs: list[dict] = []
    base_addrs: dict[str, str] = {}

    tx, addr = make_create2_tx(
        "Deploy CctpDepositForwarder Implementation",
        salt_of("bufi.cctp-deposit-forwarder.v1.implementation"),
        cctp_fwd_impl_init,
    )
    base_txs.append(tx)
    base_addrs["CctpDepositForwarderImplementation"] = addr

    base_fwd_factory_init = arts["CctpDepositForwarderFactory"]["initcode_hex"] + cast_abi_encode(
        "f(address,address,address)",
        base_addrs["CctpDepositForwarderImplementation"],
        BASE_USDC,
        CCTP_MAINNET_TOKEN_MESSENGER,
    )
    tx, addr = make_create2_tx(
        "Deploy CctpDepositForwarderFactory (Base Mainnet)",
        salt_of("bufi.cctp-deposit-forwarder.v1.factory"),
        base_fwd_factory_init,
    )
    base_txs.append(tx)
    base_addrs["CctpDepositForwarderFactory"] = addr

    # =========================================================================
    # Write Safe Transaction Builder JSON files to both repositories
    # =========================================================================
    batches = {
        "safe-arc-5042-treasury-conduits.json": build_safe_batch(
            "5042",
            SAFE_ARC_MAINNET,
            "BUFI Arc Mainnet (5042) — Hardened Treasury Conduits Deployment & Allowlist Wiring",
            "Deploys hardened TreasuryConduit (v2/v3), TreasuryConduitPermit2, TreasuryBridgeConduit (v2/v3), TreasuryBridgeConduitPermit2, TreasuryRedeemConduit (v2/v3), and TreasurySwapAndDeposit via CREATE2 and configures target/vault/bridge/Permit2 allowlists.",
            arc_treasury_txs,
        ),
        "safe-arc-5042-fx-recibu-hub.json": build_safe_batch(
            "5042",
            SAFE_ARC_MAINNET,
            "BUFI Arc Mainnet (5042) — Hardened FX-Recibu Hub, MemoConduit & Registries Deployment",
            "Deploys hardened BUFIIdentityRegistry, BUFIReputationRegistry, WorkspaceTierRegistry, WorkspaceOperatingReserve, InvoiceShelf (+ BINV & bIF-A/B/C Tranches), MultiTokenReceivableEscrow, RecibuMemoRouter, MemoConduit, DocumentReceivableRegistry, and CctpDepositForwarderFactory via CREATE2 and configures post-deploy roles.",
            arc_hub_txs,
        ),
        "safe-arc-5042-claim-vault-and-agent-policy.json": build_safe_batch(
            "5042",
            SAFE_ARC_MAINNET,
            "BUFI Arc Mainnet (5042) — Hardened ClaimVault (PeanutV4.4), PayrollBatch & AgentGatewayAccountFactory",
            "Deploys ClaimVaultDeployer (-> PeanutV4.4 MFA Vault), executes acceptOwnership(), and deploys PayrollBatch and AgentGatewayAccountFactory via CREATE2.",
            arc_vault_agent_txs,
        ),
        "safe-all-arc-5042-master-batch.json": build_safe_batch(
            "5042",
            SAFE_ARC_MAINNET,
            "BUFI Arc Mainnet (5042) — Complete Hardened Production Master Deployment & Wiring Batch",
            "Unified Safe Transaction Builder batch deploying and wiring all hardened Arc Mainnet (5042) production contracts (Treasury Conduits, FX-Recibu Hub, ClaimVault PeanutV4.4, PayrollBatch, and AgentGatewayAccountFactory).",
            arc_treasury_txs + arc_hub_txs + arc_vault_agent_txs,
        ),
        "safe-avalanche-43114-conduits-and-spoke.json": build_safe_batch(
            "43114",
            SAFE_AVALANCHE_AND_TESTNET,
            "BUFI Avalanche C-Chain (43114) — Hardened Conduits, SpokeMemoConduit & CCTP Forwarder Batch",
            "Deploys and wires hardened TreasuryConduit, TreasuryConduitPermit2, TreasuryBridgeConduitV2, TreasuryBridgeConduit, TreasuryBridgeConduitPermit2, SpokeMemoConduit, MemoConduit, and CctpDepositForwarderFactory on Avalanche C-Chain (43114).",
            avax_txs,
        ),
        "safe-arc-testnet-5042002-master-batch.json": build_safe_batch(
            "5042002",
            SAFE_AVALANCHE_AND_TESTNET,
            "BUFI Arc Testnet (5042002) — Hardened Conduits, AgentPolicy, MemoConduit & CCTP Forwarder Batch",
            "Deploys hardened Treasury Conduits, AgentGatewayAccountFactory, DocumentReceivableRegistry, MemoConduit, and CctpDepositForwarderFactory on Arc Testnet (5042002).",
            arc_testnet_txs,
        ),
        "safe-base-8453-cctp-forwarder.json": build_safe_batch(
            "8453",
            SAFE_ARC_MAINNET,
            "BUFI Base Mainnet (8453) — Hardened CCTP Deposit Forwarder & Factory Batch",
            "Deploys hardened CctpDepositForwarder implementation and CctpDepositForwarderFactory via CREATE2 on Base Mainnet (8453).",
            base_txs,
        ),
    }

    spooky_safe_dir = SPOOKY_ROOT / "deployments" / "safe-tx-builder"
    desk_safe_dir = DESK_ROOT / "contracts" / "release" / "safe-tx-builder"
    spooky_safe_dir.mkdir(parents=True, exist_ok=True)
    desk_safe_dir.mkdir(parents=True, exist_ok=True)

    for fname, batch_obj in batches.items():
        content = json.dumps(batch_obj, indent=2) + "\n"
        (spooky_safe_dir / fname).write_text(content, encoding="utf-8")
        (desk_safe_dir / fname).write_text(content, encoding="utf-8")

    # =========================================================================
    # Update spooky-contracts/deployments/addresses.json & bytecode-hashes.json
    # =========================================================================
    addresses_manifest = {
        "schemaVersion": 2,
        "updatedAt": "2026-11-06",
        "compiler": {
            "frontend": "solar 0.1.8",
            "forge": "1.6.0-dev",
            "profiles": {
                "default": "solc 0.8.24 (cancun, optimizer_runs=200)",
                "treasury-v3": "solc 0.8.24 (cancun, via_ir=true, optimizer_runs=200)",
                "agent-policy": "solc 0.8.24 (cancun, via_ir=true, optimizer_runs=200)",
                "claim-vault": "solc 0.8.23 (paris, via_ir=true, optimizer_runs=10)",
                "fx-recibu": "solc 0.8.26 (cancun, via_ir=true, optimizer_runs=200)",
            },
        },
        "create2Factory": ARACHNID_CREATE2_FACTORY,
        "chains": {
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
            "5042002": {
                "name": "Arc Testnet",
                "safe": SAFE_AVALANCHE_AND_TESTNET,
                "contracts": arc_testnet_addrs,
            },
            "8453": {
                "name": "Base Mainnet",
                "safe": SAFE_ARC_MAINNET,
                "contracts": base_addrs,
            },
        },
    }
    (SPOOKY_ROOT / "deployments" / "addresses.json").write_text(
        json.dumps(addresses_manifest, indent=2) + "\n", encoding="utf-8"
    )

    bytecode_manifest = {
        "schemaVersion": 2,
        "updatedAt": "2026-11-06",
        "compiler": "solar 0.1.8 / forge 1.6.0-dev",
        "contracts": {
            k: {
                "artifact": v["rel_path"],
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
    (SPOOKY_ROOT / "deployments" / "bytecode-hashes.json").write_text(
        json.dumps(bytecode_manifest, indent=2) + "\n", encoding="utf-8"
    )

    # =========================================================================
    # Update desk-v1 artifacts & ABIs
    # =========================================================================
    # 1. packages/contracts/src/agent-policy-artifact.ts
    aga_art = arts["AgentGatewayAccount"]
    agent_policy_ts = f"""/**
 * Compiled creation bytecode for `AgentGatewayAccount` (from `spooky-contracts/packages/agent-policy`).
 *
 * Pinned artifact for deterministic CREATE2 deployment via `AgentGatewayAccountFactory` and
 * `GatewayIntentPolicy` after F-01..F-30 audit remediation (compiled with Solar 0.1.8 / Forge 1.6.0-dev,
 * Solidity 0.8.24, via_ir = true, optimizer_runs = 200, evm_version = cancun).
 *
 * Update via `python3 script/generate_safe_tx_builder.py` whenever Solidity sources change.
 */
export const AGENT_GATEWAY_ACCOUNT_CREATION_HASH =
  '{aga_art["initcode_keccak256"]}' as const;

export const AGENT_GATEWAY_ACCOUNT_CREATION_CODE =
  '{aga_art["initcode_hex"]}' as const;
"""
    (DESK_ROOT / "packages" / "contracts" / "src" / "agent-policy-artifact.ts").write_text(
        agent_policy_ts, encoding="utf-8"
    )

    # 2. packages/smart-contract-deploy/src/abi/recibu/*.ts
    abi_targets = [
        (
            "cctp-deposit-forwarder.ts",
            "CCTP_DEPOSIT_FORWARDER_ABI",
            "CCTP_DEPOSIT_FORWARDER_ABI_SHA256",
            "CCTP_DEPOSIT_FORWARDER_SOURCE_COMMIT",
            arts["CctpDepositForwarder"]["abi"],
        ),
        (
            "cctp-deposit-forwarder-factory.ts",
            "CCTP_DEPOSIT_FORWARDER_FACTORY_ABI",
            "CCTP_DEPOSIT_FORWARDER_FACTORY_ABI_SHA256",
            "CCTP_DEPOSIT_FORWARDER_FACTORY_SOURCE_COMMIT",
            arts["CctpDepositForwarderFactory"]["abi"],
        ),
        (
            "document-receivable-registry.ts",
            "DOCUMENT_RECEIVABLE_REGISTRY_ABI",
            "DOCUMENT_RECEIVABLE_REGISTRY_ABI_SHA256",
            "DOCUMENT_RECEIVABLE_REGISTRY_SOURCE_COMMIT",
            arts["DocumentReceivableRegistry"]["abi"],
        ),
    ]
    spooky_commit = (
        subprocess.run(
            ["git", "-C", str(SPOOKY_ROOT), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    )
    for filename, const_name, hash_name, commit_name, abi_list in abi_targets:
        canon = canonical_json(abi_list).encode("utf-8")
        abi_sha256 = hashlib.sha256(canon).hexdigest()
        formatted_abi = json.dumps(abi_list, indent=2)
        ts_content = (
            f'export const {commit_name} = "{spooky_commit}" as const;\n\n'
            f"export const {const_name} = {formatted_abi} as const;\n\n"
            f'export const {hash_name} =\n  "{abi_sha256}" as const;\n'
        )
        (DESK_ROOT / "packages" / "smart-contract-deploy" / "src" / "abi" / "recibu" / filename).write_text(
            ts_content, encoding="utf-8"
        )

    # 3. Write MANIFEST.json and copy addresses.json / bytecode-hashes.json into desk-v1/contracts/release/safe-tx-builder/
    manifest_summary = {
        "schemaVersion": 2,
        "generatedAt": "2026-11-06",
        "txBuilderVersion": "1.16.5",
        "compiler": "solar 0.1.8 / forge 1.6.0-dev",
        "create2Factory": ARACHNID_CREATE2_FACTORY,
        "batches": {
            fname: {
                "chainId": batch_obj["chainId"],
                "safeAddress": batch_obj["meta"]["createdFromSafeAddress"],
                "name": batch_obj["meta"]["name"],
                "transactionCount": len(batch_obj["transactions"]),
                "checksum": batch_obj["meta"]["checksum"],
                "sha256": sha256_hex((json.dumps(batch_obj, indent=2) + "\n").encode("utf-8")),
            }
            for fname, batch_obj in batches.items()
        },
        "chains": addresses_manifest["chains"],
        "bytecodeHashes": bytecode_manifest["contracts"],
    }
    manifest_text = json.dumps(manifest_summary, indent=2) + "\n"
    (spooky_safe_dir / "MANIFEST.json").write_text(manifest_text, encoding="utf-8")
    (desk_safe_dir / "MANIFEST.json").write_text(manifest_text, encoding="utf-8")
    (desk_safe_dir / "addresses.json").write_text(
        json.dumps(addresses_manifest, indent=2) + "\n", encoding="utf-8"
    )
    (desk_safe_dir / "bytecode-hashes.json").write_text(
        json.dumps(bytecode_manifest, indent=2) + "\n", encoding="utf-8"
    )

    # 4. Update desk-v1/contracts/release/treasury-permit2-arc-deployment.json
    tp2_release_path = DESK_ROOT / "contracts" / "release" / "treasury-permit2-arc-deployment.json"
    if tp2_release_path.exists():
        tp2_release = json.loads(tp2_release_path.read_text(encoding="utf-8"))
        tp2_release["postAuditRemediationRelease"] = {
            "updatedAt": "2026-11-06",
            "compiler": "solar 0.1.8 / forge 1.6.0-dev (solc 0.8.24, cancun, optimizer_runs=200)",
            "safeBatchFile": "contracts/release/safe-tx-builder/safe-arc-5042-treasury-conduits.json",
            "arcMainnet5042": {
                "safe": SAFE_ARC_MAINNET,
                "TreasuryConduitPermit2": arc_addrs["TreasuryConduitPermit2"],
                "TreasuryBridgeConduitPermit2": arc_addrs["TreasuryBridgeConduitPermit2"],
                "runtimeKeccak256": arts["TreasuryConduitPermit2"]["runtime_keccak256"],
                "initcodeKeccak256": arts["TreasuryConduitPermit2"]["initcode_keccak256"],
            },
            "arcTestnet5042002": {
                "safe": SAFE_AVALANCHE_AND_TESTNET,
                "TreasuryConduitPermit2": arc_testnet_addrs["TreasuryConduitPermit2"],
                "runtimeKeccak256": arts["TreasuryConduitPermit2"]["runtime_keccak256"],
                "initcodeKeccak256": arts["TreasuryConduitPermit2"]["initcode_keccak256"],
            },
        }
        tp2_release_path.write_text(json.dumps(tp2_release, indent=2) + "\n", encoding="utf-8")

    print("Successfully generated 7 Safe Transaction Builder JSON batches and synced desk-v1 artifacts.")
    print("Arc Mainnet (5042) Predicted Addresses:")
    for k, v in arc_addrs.items():
        print(f"  {k}: {v}")
    print("Avalanche C-Chain (43114) Predicted Addresses:")
    for k, v in avax_addrs.items():
        print(f"  {k}: {v}")
    print("Arc Testnet (5042002) Predicted Addresses:")
    for k, v in arc_testnet_addrs.items():
        print(f"  {k}: {v}")
    print("Base Mainnet (8453) Predicted Addresses:")
    for k, v in base_addrs.items():
        print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
