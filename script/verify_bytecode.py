#!/usr/bin/env python3
"""Recompile each mainnet contract with the verified solc input and compare.

Offline mode compares compiler output to deployments/bytecode-hashes.json.
That file was produced by a run that also compared compiler output to
eth_getCode. Contracts with immutables match once those slots are copied
from the deployed runtime code into the compiler template.
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import subprocess
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
HASHES = ROOT / "deployments" / "bytecode-hashes.json"
SOLC = {
    "0.8.24": os.environ.get("SOLC_024", ""),
    "0.8.26": os.environ.get("SOLC_026", ""),
}

# (profile, package, solc, evm, src_root, lib_root, path, contract, addresses)
# addresses: chainId -> address.
CONTRACTS = [
    (
        "treasury",
        "treasury-conduits",
        "0.8.24",
        "paris",
        "packages/treasury-conduits/src",
        "packages/treasury-conduits/lib",
        "src/bufi/conduit/TreasuryConduit.sol",
        "TreasuryConduit",
        {"43114": "0x49c89b198321ed0782a4f9a44de2b237ebd77cf0", "5042": "0xa9817049f0a48d4653719465a7829e85b3a415e7"},
    ),
    (
        "permit2",
        "treasury-conduits",
        "0.8.24",
        "paris",
        "packages/treasury-conduits/src",
        "packages/treasury-conduits/lib",
        "src/bufi/conduit/TreasuryConduitPermit2.sol",
        "TreasuryConduitPermit2",
        {"43114": "0xaebb9c395ab6d627eb0defc3b16e7f49dc30c19f", "5042": "0xb63da0934e2a89169f89eed0679c35cc4d5959a5"},
    ),
    (
        "treasury",
        "treasury-conduits",
        "0.8.24",
        "paris",
        "packages/treasury-conduits/src",
        "packages/treasury-conduits/lib",
        "src/bufi/conduit/TreasuryBridgeConduitV2.sol",
        "TreasuryBridgeConduitV2",
        {"43114": "0x41422093ef6d03fbd3c0a2e3a6a6f69b1cad4409", "5042": "0x41422093ef6d03fbd3c0a2e3a6a6f69b1cad4409"},
    ),
    (
        "treasury",
        "treasury-conduits",
        "0.8.24",
        "paris",
        "packages/treasury-conduits/src",
        "packages/treasury-conduits/lib",
        "src/bufi/conduit/TreasuryRedeemConduit.sol",
        "TreasuryRedeemConduit",
        {"5042": "0x361340f0b3a8ec00067ea3c024ae6919a2a0d06a"},
    ),
    (
        "fx",
        "fx-recibu/hub",
        "0.8.26",
        "cancun",
        "packages/fx-recibu/hub/src",
        "packages/fx-recibu/lib",
        "src/invoice/InvoiceShelf.sol",
        "InvoiceShelf",
        {"5042": "0x8d3006f7be5b5e6e5b7709889a2e5d9ee4d3cd0a"},
    ),
    (
        "fx",
        "fx-recibu/hub",
        "0.8.26",
        "cancun",
        "packages/fx-recibu/hub/src",
        "packages/fx-recibu/lib",
        "src/credit/WorkspaceTierRegistry.sol",
        "WorkspaceTierRegistry",
        {"5042": "0xfe06281b464d53f00cceca504114263c689e56fe"},
    ),
    (
        "fx",
        "fx-recibu/hub",
        "0.8.26",
        "cancun",
        "packages/fx-recibu/hub/src",
        "packages/fx-recibu/lib",
        "src/rails/MultiTokenReceivableEscrow.sol",
        "MultiTokenReceivableEscrow",
        {"5042": "0xbb4b6bbdaeb3136571d33742385a1ae59cee57ab"},
    ),
    (
        "fx",
        "fx-recibu/hub",
        "0.8.26",
        "cancun",
        "packages/fx-recibu/hub/src",
        "packages/fx-recibu/lib",
        "src/rails/RecibuMemoRouter.sol",
        "RecibuMemoRouter",
        {"5042": "0x208fbdf4268c87c475189d9ecd7d59b4766e75cb"},
    ),
    (
        "fx",
        "fx-recibu/hub",
        "0.8.26",
        "cancun",
        "packages/fx-recibu/hub/src",
        "packages/fx-recibu/lib",
        "src/identity/BUFIIdentityRegistry.sol",
        "BUFIIdentityRegistry",
        {"5042": "0xe3d6de22135bbd463c0a97a5196782cbcc3f3322"},
    ),
    (
        "fx",
        "fx-recibu/hub",
        "0.8.26",
        "cancun",
        "packages/fx-recibu/hub/src",
        "packages/fx-recibu/lib",
        "src/identity/BUFIReputationRegistry.sol",
        "BUFIReputationRegistry",
        {"5042": "0x30015db351747e39102da3f65f51ce0207052415"},
    ),
    (
        "fx",
        "fx-recibu/spoke-cctp",
        "0.8.26",
        "cancun",
        "packages/fx-recibu/spoke-cctp/src",
        "packages/fx-recibu/lib",
        "src/rails/SpokeMemoConduit.sol",
        "SpokeMemoConduit",
        {"43114": "0x7b5b1425bb621b014b7257a0d0caf88c453e33c8"},
    ),
    (
        "fx",
        "fx-recibu/memo-v1",
        "0.8.26",
        "cancun",
        "packages/fx-recibu/memo-v1/src",
        "packages/fx-recibu/lib",
        "src/rails/MemoConduit.sol",
        "MemoConduit",
        {"43114": "0x536268d0a6c32a7161ba146f5673dfcf13f1ffe2", "5042": "0x516340a244132c62bedae5f886fd35845af16ba2"},
    ),
]

RPC = {
    "43114": os.environ.get("AVAX_RPC", "https://api.avax.network/ext/bc/C/rpc"),
    "5042": os.environ.get("ARC_RPC", "https://rpc.mainnet.arc.io"),
}

# The metadata CBOR records the remapping list from the verified standard-json.
# A shorter list changes the IPFS hash appended to the runtime bytecode even
# when the opcodes are identical. These profiles are the verified inputs.
# Unused remapping targets were not vendored; the strings themselves are part
# of the metadata.
PROFILES = {
    "treasury": {
        "metadata": {"bytecodeHash": "ipfs"},
        "remappings": [
            "@account-abstraction/=lib/account-abstraction/",
            "@alchemy-mav1/=lib/alchemy-modular-account/src/",
            "@circle-script/=lib/buidl-wallet-contracts/script/",
            "@circle-test/=lib/buidl-wallet-contracts/test/",
            "@circle/=lib/buidl-wallet-contracts/src/",
            "@erc6900/reference-implementation-v0.8.1/=lib/erc6900-reference-implementation-v0.8.1/src/",
            "@erc6900/reference-implementation/=lib/erc6900-reference-implementation/src/",
            "@eth-infinitism/account-abstraction/=lib/account-abstraction/contracts/",
            "@fcl/=lib/FreshCryptoLib/solidity/src/",
            "@modular-account-libs/=lib/modular-account-libs/src/",
            "@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/",
            "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
            "@solady/=lib/solady/src/",
            "forge-std/=lib/forge-std/",
        ],
    },
    "permit2": {
        "metadata": {"appendCBOR": True, "bytecodeHash": "ipfs", "useLiteralContent": False},
        "remappings": [
            "forge-std/=lib/forge-std/",
            "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
            "@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/",
            "@account-abstraction/=lib/account-abstraction/",
            "@eth-infinitism/account-abstraction/=lib/account-abstraction/contracts/",
            "@modular-account-libs/=lib/modular-account-libs/src/",
            "@solady/=lib/solady/src/",
            "@fcl/=lib/FreshCryptoLib/solidity/src/",
            "@erc6900/reference-implementation/=lib/erc6900-reference-implementation/src/",
            "@circle/=lib/buidl-wallet-contracts/src/",
            "@circle-test/=lib/buidl-wallet-contracts/test/",
            "@circle-script/=lib/buidl-wallet-contracts/script/",
            "@alchemy-mav1/=lib/alchemy-modular-account/src/",
            "@erc6900/reference-implementation-v0.8.1/=lib/erc6900-reference-implementation-v0.8.1/src/",
        ],
    },
    "fx": {
        "metadata": {"bytecodeHash": "ipfs"},
        "remappings": [
            "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
            "erc4626-tests/=lib/openzeppelin-contracts/lib/erc4626-tests/",
            "forge-std/=lib/forge-std/src/",
            "halmos-cheatcodes/=lib/openzeppelin-contracts/lib/halmos-cheatcodes/src/",
            "openzeppelin-contracts/=lib/openzeppelin-contracts/",
        ],
    },
}


def solc_bin(version: str) -> str:
    configured = SOLC.get(version) or ""
    if configured and pathlib.Path(configured).exists():
        return configured
    candidates = [
        pathlib.Path(f"/tmp/solcbin/solc-{version}"),
        pathlib.Path.home() / ".svm" / version / f"solc-{version}",
        pathlib.Path.home() / "Library" / "Application Support" / "svm" / version / f"solc-{version}",
        ROOT / ".tools" / f"solc-{version}",
    ]
    for path in candidates:
        if path.exists():
            return str(path)
    raise SystemExit(f"solc {version} not found; set SOLC_024 / SOLC_026")


def collect_sources(src_root: pathlib.Path, lib_root: pathlib.Path) -> dict:
    sources = {}
    for path in src_root.rglob("*.sol"):
        key = "src/" + str(path.relative_to(src_root))
        sources[key] = {"content": path.read_text()}
    for path in lib_root.rglob("*.sol"):
        key = "lib/" + str(path.relative_to(lib_root))
        sources[key] = {"content": path.read_text()}
    return sources


def compile_one(solc: str, evm: str, sources: dict, path: str, name: str, profile: str) -> dict:
    chosen = PROFILES[profile]
    settings = {
        "remappings": chosen["remappings"],
        "optimizer": {"enabled": True, "runs": 200},
        "metadata": chosen["metadata"],
        "evmVersion": evm,
        "viaIR": True,
        "libraries": {},
        "outputSelection": {
            "*": {"*": ["evm.deployedBytecode.object", "evm.deployedBytecode.immutableReferences"]}
        },
    }
    payload = json.dumps({"language": "Solidity", "sources": sources, "settings": settings}).encode()
    proc = subprocess.run([solc, "--standard-json"], input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise SystemExit(proc.stderr.decode()[:500])
    out = json.loads(proc.stdout)
    errors = [e for e in out.get("errors", []) if e.get("severity") == "error"]
    if errors:
        raise SystemExit(errors[0].get("formattedMessage", str(errors[0]))[:800])
    compiled = out["contracts"][path][name]
    deployed = compiled["evm"]["deployedBytecode"]
    return {
        "object": deployed["object"],
        "immutableReferences": deployed.get("immutableReferences") or {},
    }


def rpc_code(chain: str, address: str) -> str:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getCode", "params": [address, "latest"]}).encode()
    req = urllib.request.Request(
        RPC[chain],
        data=body,
        headers={"content-type": "application/json", "user-agent": "spooky-contracts-bytecode-check"},
    )
    result = json.load(urllib.request.urlopen(req, timeout=40))["result"]
    if not isinstance(result, str) or result in ("0x", None):
        raise SystemExit(f"no code at {chain}:{address}")
    return result[2:]


def slots(refs: dict) -> list[tuple[int, int]]:
    found = []
    for places in refs.values():
        for place in places:
            found.append((place["start"], place["length"]))
    return found


def apply_immutables(template: str, deployed: str, refs: dict) -> str:
    if len(template) != len(deployed):
        return template
    raw = bytearray.fromhex(template)
    live = bytes.fromhex(deployed)
    for start, length in slots(refs):
        raw[start : start + length] = live[start : start + length]
    return raw.hex()


def sha256_hex(bytecode_hex: str) -> str:
    return hashlib.sha256(bytes.fromhex(bytecode_hex)).hexdigest()


def main() -> int:
    offline = "--offline" in sys.argv
    expected = json.loads(HASHES.read_text()) if HASHES.exists() else {"contracts": {}}
    fresh = {"contracts": {}}
    failed = False
    compiled_cache: dict[tuple, dict] = {}

    for profile, package, version, evm, src_rel, lib_rel, path, name, addresses in CONTRACTS:
        key = (src_rel, lib_rel, version, evm)
        if key not in compiled_cache:
            compiled_cache[key] = collect_sources(ROOT / src_rel, ROOT / lib_rel)
        sources = compiled_cache[key]
        compiled = compile_one(solc_bin(version), evm, sources, path, name, profile)
        template = compiled["object"]
        entry = {
            "package": package,
            "compilerProfile": profile,
            "solc": version,
            "evmVersion": evm,
            "path": path,
            "contract": name,
            "compilerDeployedSha256": sha256_hex(template),
            "immutableSlots": len(slots(compiled["immutableReferences"])),
            "chains": {},
        }
        for chain, address in addresses.items():
            chain_entry = {"address": address}
            if not offline:
                live = rpc_code(chain, address)
                patched = apply_immutables(template, live, compiled["immutableReferences"])
                exact = template == live
                immutable_match = patched == live
                chain_entry.update(
                    {
                        "onchainSha256": sha256_hex(live),
                        "exact": exact,
                        "matchAfterImmutables": immutable_match,
                    }
                )
                if not (exact or immutable_match):
                    failed = True
                    print(f"MISMATCH {name} chain {chain} {address}")
                else:
                    kind = "exact" if exact else "immutables"
                    print(f"ok {name} {chain} {address} {kind}")
            else:
                prior = expected.get("contracts", {}).get(f"{path}:{name}", {}).get("chains", {}).get(chain, {})
                chain_entry.update(
                    {
                        "onchainSha256": prior.get("onchainSha256"),
                        "exact": prior.get("exact"),
                        "matchAfterImmutables": prior.get("matchAfterImmutables"),
                    }
                )
                if not prior.get("matchAfterImmutables"):
                    failed = True
                    print(f"RECORDED MISMATCH {name} chain {chain} {address}")
            entry["chains"][chain] = chain_entry
        ident = f"{path}:{name}"
        prior_hash = expected.get("contracts", {}).get(ident, {}).get("compilerDeployedSha256")
        if prior_hash and prior_hash != entry["compilerDeployedSha256"]:
            failed = True
            print(f"COMPILER HASH CHANGED {ident}")
        fresh["contracts"][ident] = entry

    if not offline:
        HASHES.parent.mkdir(parents=True, exist_ok=True)
        HASHES.write_text(json.dumps(fresh, indent=2) + "\n")
        print(f"wrote {HASHES.relative_to(ROOT)}")
    if failed:
        return 1
    print("bytecode check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
