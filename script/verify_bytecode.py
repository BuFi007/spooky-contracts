#!/usr/bin/env python3
"""Verify post-remediation (schemaVersion 2) bytecode hashes and deployment manifests.

Compares `out/` compiler artifacts (when present) and `deployments/safe-tx-builder/MANIFEST.json`
against `deployments/bytecode-hashes.json`, `deployments/addresses.json`, and
`deployments/live-receipts-2026-11-07.json`.
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
HASHES_PATH = ROOT / "deployments" / "bytecode-hashes.json"
ADDRESSES_PATH = ROOT / "deployments" / "addresses.json"
RECEIPTS_PATH = ROOT / "deployments" / "live-receipts-2026-11-07.json"
MANIFEST_PATH = ROOT / "deployments" / "safe-tx-builder" / "MANIFEST.json"
OUT_DIR = ROOT / "out"


def sha256_hex(raw: bytes) -> str:
    return "0x" + hashlib.sha256(raw).hexdigest()


def strip_0x(hex_str: str) -> str:
    return hex_str[2:] if hex_str.startswith("0x") else hex_str


def main() -> int:
    hashes_doc = json.loads(HASHES_PATH.read_text(encoding="utf-8"))
    addresses_doc = json.loads(ADDRESSES_PATH.read_text(encoding="utf-8"))
    receipts_doc = json.loads(RECEIPTS_PATH.read_text(encoding="utf-8"))
    manifest_doc = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))

    failed = False
    contracts = hashes_doc.get("contracts", {})
    manifest_hashes = manifest_doc.get("bytecodeHashes", {})

    if not contracts:
        print("ERROR: deployments/bytecode-hashes.json has no contracts", file=sys.stderr)
        return 1

    for name, entry in sorted(contracts.items()):
        manifest_entry = manifest_hashes.get(name)
        if manifest_entry != entry:
            print(f"MISMATCH: MANIFEST.json bytecodeHashes[{name}] != bytecode-hashes.json", file=sys.stderr)
            failed = True

        artifact_rel = entry["artifact"]
        artifact_path = OUT_DIR / artifact_rel
        if artifact_path.exists():
            art = json.loads(artifact_path.read_text(encoding="utf-8"))
            init_hex = strip_0x(art["bytecode"]["object"])
            run_hex = strip_0x(art["deployedBytecode"]["object"])
            init_bytes = bytes.fromhex(init_hex)
            run_bytes = bytes.fromhex(run_hex)
            if len(init_bytes) != entry["initcodeBytes"] or sha256_hex(init_bytes) != entry["initcodeSha256"]:
                print(f"MISMATCH: out/{artifact_rel} initcode != recorded hash for {name}", file=sys.stderr)
                failed = True
            if len(run_bytes) != entry["runtimeBytes"] or sha256_hex(run_bytes) != entry["runtimeSha256"]:
                print(f"MISMATCH: out/{artifact_rel} runtime != recorded hash for {name}", file=sys.stderr)
                failed = True

    chains = addresses_doc.get("chains", {})
    total_instances = sum(len(c.get("contracts", {})) for c in chains.values())
    if total_instances != 57:
        print(f"MISMATCH: expected 57 post-remediation contract instances, found {total_instances}", file=sys.stderr)
        failed = True

    verified_count = sum(len(c) for c in receipts_doc.get("chains", {}).values())
    if verified_count != 57:
        print(f"MISMATCH: live-receipts-2026-11-07.json chains contract count={verified_count}", file=sys.stderr)
        failed = True

    if failed:
        return 1

    print(
        f"bytecode and manifest check passed ({len(contracts)} artifacts, "
        f"{total_instances} live deployed instances across {len(chains)} chains)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
