#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import io
import json
import pathlib
import shutil
import sys
import tempfile
import unittest

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import verify_bytecode


def copy_fixture(dst: pathlib.Path, *, include_out: bool = True) -> None:
    shutil.copytree(REPO_ROOT / "deployments", dst / "deployments")
    if include_out:
        manifest = json.loads(
            (dst / "deployments" / "safe-tx-builder" / "vnext-bugpocer" / "MANIFEST.json").read_text(
                encoding="utf-8"
            )
        )
        for entry in manifest["bytecodeHashes"].values():
            rel = pathlib.Path(entry["artifact"])
            src_art = REPO_ROOT / "out" / rel
            dst_art = dst / "out" / rel
            dst_art.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src_art, dst_art)


class VerifyBytecodeTest(unittest.TestCase):
    def test_passing_repo_with_out(self) -> None:
        result = verify_bytecode.verify_repo(REPO_ROOT, require_out=True)
        self.assertTrue(result.ok, msg="\n".join(result.errors))
        self.assertEqual(result.historical_artifacts, 33)
        self.assertEqual(result.historical_instances, 57)
        self.assertEqual(result.vnext_artifacts_checked, 20)
        self.assertEqual(result.vnext_batches, 14)
        self.assertEqual(result.vnext_live_contracts, 37)
        self.assertEqual(result.vnext_receipts, 11)
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = verify_bytecode.main(["--require-out"])
        self.assertEqual(code, 0)
        self.assertIn("vnext-bugpocer: 20/20 solc artifacts", stdout.getvalue())

    def test_tampered_vnext_bytecode_hash_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            copy_fixture(root, include_out=True)
            manifest_path = (
                root / "deployments" / "safe-tx-builder" / "vnext-bugpocer" / "MANIFEST.json"
            )
            doc = json.loads(manifest_path.read_text(encoding="utf-8"))
            doc["bytecodeHashes"]["InvoiceShelf"]["runtimeSha256"] = "0x" + "00" * 32
            manifest_path.write_text(json.dumps(doc), encoding="utf-8")

            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                code = verify_bytecode.main(["--require-out", "--root", str(root)])
            self.assertEqual(code, 1)
            self.assertIn("InvoiceShelf", stderr.getvalue())
            self.assertIn("runtime", stderr.getvalue())

    def test_tampered_vnext_compiled_artifact_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            copy_fixture(root, include_out=True)
            art_path = root / "out" / "fx-hub" / "BINV.sol" / "BINV.json"
            art = json.loads(art_path.read_text(encoding="utf-8"))
            art["bytecode"]["object"] = art["bytecode"]["object"] + "00"
            art_path.write_text(json.dumps(art), encoding="utf-8")

            result = verify_bytecode.verify_repo(root, require_out=True)
            self.assertFalse(result.ok)
            self.assertTrue(
                any("BINV" in err and "initcode" in err for err in result.errors),
                msg=result.errors,
            )

    def test_missing_vnext_artifact_fails_when_out_exists(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            copy_fixture(root, include_out=True)
            (root / "out" / "claim-vault" / "PayrollBatch.sol" / "PayrollBatch.json").unlink()

            result = verify_bytecode.verify_repo(root, require_out=False)
            self.assertFalse(result.ok)
            self.assertTrue(
                any("PayrollBatch" in err and "MISSING" in err for err in result.errors),
                msg=result.errors,
            )

    def test_missing_out_dir_behavior(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            copy_fixture(root, include_out=False)

            without_req = verify_bytecode.verify_repo(root, require_out=False)
            self.assertTrue(without_req.ok, msg=without_req.errors)
            self.assertEqual(without_req.vnext_artifacts_checked, 0)

            with_req = verify_bytecode.verify_repo(root, require_out=True)
            self.assertFalse(with_req.ok)
            self.assertTrue(any("--require-out" in err for err in with_req.errors))

    def test_tampered_vnext_batch_sha256_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            copy_fixture(root, include_out=True)
            batch_path = (
                root
                / "deployments"
                / "safe-tx-builder"
                / "vnext-bugpocer"
                / "00-arc-5042-hotfix-5-2-2-grant-ops-role.json"
            )
            batch_path.write_bytes(batch_path.read_bytes() + b"\n")

            result = verify_bytecode.verify_repo(root, require_out=True)
            self.assertFalse(result.ok)
            self.assertTrue(
                any("00-arc-5042-hotfix-5-2-2-grant-ops-role.json" in err for err in result.errors),
                msg=result.errors,
            )

    def test_tampered_vnext_receipt_status_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            copy_fixture(root, include_out=True)
            receipts_path = (
                root / "deployments" / "live-receipts-2026-11-23-vnext-bugpocer.json"
            )
            doc = json.loads(receipts_path.read_text(encoding="utf-8"))
            doc["transactions"]["base-8453-04b"]["status"] = 0
            receipts_path.write_text(json.dumps(doc), encoding="utf-8")

            result = verify_bytecode.verify_repo(root, require_out=True)
            self.assertFalse(result.ok)
            self.assertTrue(
                any("base-8453-04b" in err and "status=0" in err for err in result.errors),
                msg=result.errors,
            )

    def test_tampered_vnext_chain_count_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            copy_fixture(root, include_out=True)
            receipts_path = (
                root / "deployments" / "live-receipts-2026-11-23-vnext-bugpocer.json"
            )
            doc = json.loads(receipts_path.read_text(encoding="utf-8"))
            del doc["chains"]["5042"]["PayrollBatch"]
            receipts_path.write_text(json.dumps(doc), encoding="utf-8")

            result = verify_bytecode.verify_repo(root, require_out=True)
            self.assertFalse(result.ok)
            self.assertTrue(
                any("chain 5042" in err for err in result.errors),
                msg=result.errors,
            )

    def test_tampered_historical_manifest_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            copy_fixture(root, include_out=True)
            manifest_path = root / "deployments" / "safe-tx-builder" / "MANIFEST.json"
            doc = json.loads(manifest_path.read_text(encoding="utf-8"))
            doc["bytecodeHashes"]["BINV"]["runtimeBytes"] = 1
            manifest_path.write_text(json.dumps(doc), encoding="utf-8")

            result = verify_bytecode.verify_repo(root, require_out=True)
            self.assertFalse(result.ok)
            self.assertTrue(
                any("MANIFEST.json bytecodeHashes[BINV]" in err for err in result.errors),
                msg=result.errors,
            )


if __name__ == "__main__":
    unittest.main()
