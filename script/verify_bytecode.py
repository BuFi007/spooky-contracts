#!/usr/bin/env python3

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

EXPECTED_HISTORICAL_INSTANCES = 57
EXPECTED_VNEXT_ARTIFACTS = 20
EXPECTED_VNEXT_BATCHES = 14
EXPECTED_VNEXT_CHAIN_COUNTS = {
    "5042": 22,
    "43114": 10,
    "8453": 5,
}
EXPECTED_VNEXT_LIVE_CONTRACTS = 37
EXPECTED_VNEXT_RECEIPTS = 11


@dataclass(frozen=True)
class VerificationResult:
    errors: list[str]
    historical_artifacts: int
    historical_instances: int
    historical_chains: int
    vnext_artifacts_checked: int
    vnext_artifacts_total: int
    vnext_batches: int
    vnext_live_contracts: int
    vnext_receipts: int

    @property
    def ok(self) -> bool:
        return not self.errors


def sha256_hex(raw: bytes) -> str:
    return "0x" + hashlib.sha256(raw).hexdigest()


def strip_0x(hex_str: str) -> str:
    return hex_str[2:] if hex_str.startswith("0x") else hex_str


def load_json(path: pathlib.Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def verify_historical(root: pathlib.Path) -> tuple[list[str], int, int, int]:
    errors: list[str] = []
    deployments_dir = root / "deployments"
    hashes_doc = load_json(deployments_dir / "bytecode-hashes.json")
    addresses_doc = load_json(deployments_dir / "addresses.json")
    receipts_doc = load_json(deployments_dir / "live-receipts-2026-11-07.json")
    manifest_doc = load_json(deployments_dir / "safe-tx-builder" / "MANIFEST.json")

    contracts = hashes_doc.get("contracts", {})
    manifest_hashes = manifest_doc.get("bytecodeHashes", {})

    if not contracts:
        errors.append("ERROR: deployments/bytecode-hashes.json has no contracts")
        return errors, 0, 0, 0

    for name, entry in sorted(contracts.items()):
        if manifest_hashes.get(name) != entry:
            errors.append(
                f"MISMATCH: MANIFEST.json bytecodeHashes[{name}] != bytecode-hashes.json"
            )

    for extra in sorted(set(manifest_hashes) - set(contracts)):
        errors.append(
            f"MISMATCH: MANIFEST.json bytecodeHashes[{extra}] missing from bytecode-hashes.json"
        )

    chains = addresses_doc.get("chains", {})
    total_instances = sum(len(c.get("contracts", {})) for c in chains.values())
    if total_instances != EXPECTED_HISTORICAL_INSTANCES:
        errors.append(
            f"MISMATCH: expected {EXPECTED_HISTORICAL_INSTANCES} historical contract instances, "
            f"found {total_instances}"
        )

    verified_count = sum(len(c) for c in receipts_doc.get("chains", {}).values())
    if verified_count != EXPECTED_HISTORICAL_INSTANCES:
        errors.append(
            f"MISMATCH: live-receipts-2026-11-07.json chains contract count={verified_count}, "
            f"expected {EXPECTED_HISTORICAL_INSTANCES}"
        )

    return errors, len(contracts), total_instances, len(chains)


def verify_vnext(
    root: pathlib.Path,
    *,
    require_out: bool = False,
) -> tuple[list[str], int, int, int, int, int]:
    errors: list[str] = []
    vnext_dir = root / "deployments" / "safe-tx-builder" / "vnext-bugpocer"
    vnext_manifest = load_json(vnext_dir / "MANIFEST.json")
    vnext_receipts = load_json(
        root / "deployments" / "live-receipts-2026-11-23-vnext-bugpocer.json"
    )
    out_dir = root / "out"

    vnext_hashes = vnext_manifest.get("bytecodeHashes", {})
    if len(vnext_hashes) != EXPECTED_VNEXT_ARTIFACTS:
        errors.append(
            f"MISMATCH: vnext-bugpocer/MANIFEST.json bytecodeHashes count={len(vnext_hashes)}, "
            f"expected {EXPECTED_VNEXT_ARTIFACTS}"
        )

    checked_artifacts = 0
    if require_out and not out_dir.is_dir():
        errors.append(f"MISSING: {out_dir} does not exist (--require-out)")
    elif out_dir.is_dir():
        for name, entry in sorted(vnext_hashes.items()):
            artifact_rel = entry["artifact"]
            artifact_path = out_dir / artifact_rel
            if not artifact_path.is_file():
                errors.append(f"MISSING: out/{artifact_rel} for vNext contract {name}")
                continue
            art = load_json(artifact_path)
            init_bytes = bytes.fromhex(strip_0x(art["bytecode"]["object"]))
            run_bytes = bytes.fromhex(strip_0x(art["deployedBytecode"]["object"]))
            if (
                len(init_bytes) != entry["initcodeBytes"]
                or sha256_hex(init_bytes) != entry["initcodeSha256"]
            ):
                errors.append(
                    f"MISMATCH: out/{artifact_rel} initcode != vNext manifest for {name}"
                )
            if (
                len(run_bytes) != entry["runtimeBytes"]
                or sha256_hex(run_bytes) != entry["runtimeSha256"]
            ):
                errors.append(
                    f"MISMATCH: out/{artifact_rel} runtime != vNext manifest for {name}"
                )
            checked_artifacts += 1

    batches = vnext_manifest.get("batches", {})
    if len(batches) != EXPECTED_VNEXT_BATCHES:
        errors.append(
            f"MISMATCH: vnext-bugpocer/MANIFEST.json batches count={len(batches)}, "
            f"expected {EXPECTED_VNEXT_BATCHES}"
        )
    for filename, entry in sorted(batches.items()):
        batch_path = vnext_dir / filename
        if not batch_path.is_file():
            errors.append(f"MISSING: vnext-bugpocer batch file {filename}")
            continue
        actual_sha256 = sha256_hex(batch_path.read_bytes())
        if actual_sha256 != entry["sha256"]:
            errors.append(
                f"MISMATCH: vnext-bugpocer/{filename} sha256={actual_sha256} != {entry['sha256']}"
            )

    manifest_chains = vnext_manifest.get("chains", {})
    chains = vnext_receipts.get("chains", {})
    if set(chains.keys()) != set(EXPECTED_VNEXT_CHAIN_COUNTS.keys()):
        errors.append(
            f"MISMATCH: live-receipts-2026-11-23-vnext-bugpocer.json chain keys="
            f"{sorted(chains.keys())}, expected {sorted(EXPECTED_VNEXT_CHAIN_COUNTS.keys())}"
        )

    total_live = sum(len(c) for c in chains.values())
    for chain_id, expected_count in sorted(EXPECTED_VNEXT_CHAIN_COUNTS.items()):
        chain_contracts = chains.get(chain_id, {})
        manifest_contracts = manifest_chains.get(chain_id, {}).get("contracts", {})
        actual_count = len(chain_contracts)
        if actual_count != expected_count:
            errors.append(
                f"MISMATCH: vNext live receipts chain {chain_id} count={actual_count}, "
                f"expected {expected_count}"
            )
        for contract_name, contract_info in sorted(chain_contracts.items()):
            if contract_info.get("sourcify") != "exact_match":
                errors.append(
                    f"MISMATCH: vNext live receipt {chain_id}/{contract_name} "
                    f"sourcify={contract_info.get('sourcify')!r}, expected 'exact_match'"
                )
            manifest_addr = manifest_contracts.get(contract_name)
            receipt_addr = contract_info.get("address")
            if not manifest_addr or not receipt_addr or manifest_addr.lower() != receipt_addr.lower():
                errors.append(
                    f"MISMATCH: vNext live receipt {chain_id}/{contract_name} "
                    f"address={receipt_addr!r} != manifest {manifest_addr!r}"
                )

    if total_live != EXPECTED_VNEXT_LIVE_CONTRACTS:
        errors.append(
            f"MISMATCH: vNext live receipts total contracts={total_live}, "
            f"expected {EXPECTED_VNEXT_LIVE_CONTRACTS}"
        )

    txs = vnext_receipts.get("transactions", {})
    if len(txs) != EXPECTED_VNEXT_RECEIPTS:
        errors.append(
            f"MISMATCH: vNext live receipts transactions count={len(txs)}, "
            f"expected {EXPECTED_VNEXT_RECEIPTS}"
        )
    for tx_id, tx in sorted(txs.items()):
        if tx.get("status") != 1:
            errors.append(
                f"MISMATCH: vNext live receipt {tx_id} status={tx.get('status')!r}, expected 1"
            )

    return errors, checked_artifacts, len(vnext_hashes), len(batches), total_live, len(txs)


def verify_repo(root: pathlib.Path = ROOT, *, require_out: bool = False) -> VerificationResult:
    hist_errors, hist_artifacts, hist_instances, hist_chains = verify_historical(root)
    (
        vnext_errors,
        vnext_checked,
        vnext_total,
        vnext_batches,
        vnext_live,
        vnext_receipts,
    ) = verify_vnext(root, require_out=require_out)
    return VerificationResult(
        errors=hist_errors + vnext_errors,
        historical_artifacts=hist_artifacts,
        historical_instances=hist_instances,
        historical_chains=hist_chains,
        vnext_artifacts_checked=vnext_checked,
        vnext_artifacts_total=vnext_total,
        vnext_batches=vnext_batches,
        vnext_live_contracts=vnext_live,
        vnext_receipts=vnext_receipts,
    )


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify historical Nov 7 manifests and BugPoCer vNext canonical solc artifacts."
    )
    parser.add_argument(
        "--require-out",
        action="store_true",
        help="Fail if out/ or any compiled vNext artifact is missing.",
    )
    parser.add_argument(
        "--root",
        type=pathlib.Path,
        default=ROOT,
        help="Repository root directory.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    result = verify_repo(args.root, require_out=args.require_out)
    if not result.ok:
        for err in result.errors:
            print(err, file=sys.stderr)
        return 1

    print(
        f"bytecode and manifest check passed ("
        f"nov7: {result.historical_artifacts} manifest entries, "
        f"{result.historical_instances} live instances across {result.historical_chains} chains; "
        f"vnext-bugpocer: {result.vnext_artifacts_checked}/{result.vnext_artifacts_total} solc artifacts, "
        f"{result.vnext_batches} batches, {result.vnext_live_contracts} verified mainnet contracts, "
        f"{result.vnext_receipts} Safe receipts)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
