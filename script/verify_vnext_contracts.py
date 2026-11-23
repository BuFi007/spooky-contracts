#!/usr/bin/env python3
"""Verify all deployed BugPoCer vNext mainnet contracts on Sourcify and Snowtrace (Routescan).

Runs idempotently (checks existing verification before submitting), groups work by
FOUNDRY_PROFILE so parallel forge processes never contend on the same out/cache dir,
and optionally submits to Etherscan v2 (Basescan / Snowscan) when ETHERSCAN_API_KEY is set.
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

SPOOKY_ROOT = Path(__file__).resolve().parents[1]

SAFE_ARC_AND_BASE = "0x47Dc7D18A6E3a79F696714E7D47456a49B430D09"
SAFE_AVAX = "0xA3a40fa2d82C0224c40b1Ed7E07cb474B7D1468B"
PERMIT2 = "0x000000000022D473030F116dDEE9F6B43aC78BA3"
COLD_STORAGE = "0x0000000d81083B16EA76dfab46B0315B0eDBF3d0"
ZERO_ADDR = "0x0000000000000000000000000000000000000000"

ARC_IDENTITY = "0x6730b8f3FF0eF85E097Af01eC8a3e450d30e466d"
ARC_USDC = "0x3600000000000000000000000000000000000000"
AVAX_USDC = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E"
BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
CCTP_TOKEN_MESSENGER = "0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d"
MFA_AUTHORIZER = "0x9c8515333aFdB567C31CDF53CD60868f3B64b724"

FWD_IMPL = "0xDe831fe5175D9aBeF63516ff7EA4f02c81223221"

ARC_REP = "0x3627cFFF52a1a895Dc2198971B10D3d64d312215"
ARC_TIERS = "0x77E2837370f431F0C52bC5236B86BF92EAC2BE06"
ARC_RESERVE = "0x3cDEC911Df8345D8d6bFB83d34dCBBfeB4d67605"
ARC_SHELF = "0xD2FaA2B5044819fda138c7D3B0cfAF3b06E60E8C"
ARC_ESCROW = "0x4Aa12CfadAe9e32e55111caD9c98A24C784d9E52"
ARC_PEANUT = "0x75EbdB0065729849bb1A8807718B753374AD2Ca1"

AVAX_PEANUT = "0x334c0c981fbBFff5D93A26F7429a86d97F03778e"
BASE_PEANUT = "0x75EbdB0065729849bb1A8807718B753374AD2Ca1"


@dataclass(frozen=True)
class Target:
    chain_id: int
    name: str
    address: str
    profile: str
    contract_spec: str
    ctor_sig: str | None = None
    ctor_args: tuple[str, ...] = ()


TARGETS: list[Target] = [
    # --- Arc Mainnet (5042) — 22 vNext contracts ---
    Target(5042, "TreasuryConduit_v2", "0x5dD2e0112B10681e799155676486E1D8aD8c77d7", "default",
           "packages/treasury-conduits/src/bufi/conduit/TreasuryConduit.sol:TreasuryConduit",
           "constructor(address)", (SAFE_ARC_AND_BASE,)),
    Target(5042, "TreasuryConduitPermit2_v2", "0xc87dfe14675D2F973ED99961cf0b5a82e357FfE6", "default",
           "packages/treasury-conduits/src/bufi/conduit/TreasuryConduitPermit2.sol:TreasuryConduitPermit2",
           "constructor(address,address,address)", (SAFE_ARC_AND_BASE, PERMIT2, COLD_STORAGE)),
    Target(5042, "TreasuryBridgeConduitV2", "0xE74C0A896F52015c3e8f474c30C52C00c56DB3d8", "default",
           "packages/treasury-conduits/src/bufi/conduit/TreasuryBridgeConduitV2.sol:TreasuryBridgeConduitV2",
           "constructor(address)", (SAFE_ARC_AND_BASE,)),

    Target(5042, "TreasuryConduit_v3", "0xbe4b7524576BD9AB2E6D88A8BE74773CcBa4B4E7", "treasury-v3",
           "packages/treasury-conduits/v3/src/bufi/conduit/TreasuryConduit.sol:TreasuryConduit",
           "constructor(address)", (SAFE_ARC_AND_BASE,)),
    Target(5042, "TreasuryBridgeConduit_v3", "0xfdC52570590dD8F9801cF501CffFC17C29D7f77e", "treasury-v3",
           "packages/treasury-conduits/v3/src/bufi/conduit/TreasuryBridgeConduit.sol:TreasuryBridgeConduit",
           "constructor(address)", (SAFE_ARC_AND_BASE,)),
    Target(5042, "TreasuryBridgeConduitPermit2_v3", "0xE8C1A1B56FDF3628a30e4EB18274274A12cac3D6", "treasury-v3",
           "packages/treasury-conduits/v3/src/bufi/conduit/TreasuryBridgeConduitPermit2.sol:TreasuryBridgeConduitPermit2",
           "constructor(address,address)", (SAFE_ARC_AND_BASE, PERMIT2)),
    Target(5042, "TreasurySwapAndDeposit_v3", "0x3541BfbD564058Be47A0cfFD00291a93A8bd6670", "treasury-v3",
           "packages/treasury-conduits/v3/src/bufi/conduit/TreasurySwapAndDeposit.sol:TreasurySwapAndDeposit",
           "constructor(address,address)", (SAFE_ARC_AND_BASE, ARC_USDC)),

    Target(5042, "BUFIReputationRegistry", ARC_REP, "fx-hub",
           "packages/fx-recibu/hub/src/identity/BUFIReputationRegistry.sol:BUFIReputationRegistry",
           "constructor(address,address)", (SAFE_ARC_AND_BASE, ARC_IDENTITY)),
    Target(5042, "WorkspaceTierRegistry", ARC_TIERS, "fx-hub",
           "packages/fx-recibu/hub/src/credit/WorkspaceTierRegistry.sol:WorkspaceTierRegistry",
           "constructor(address,address)", (ARC_IDENTITY, ARC_REP)),
    Target(5042, "WorkspaceOperatingReserve", ARC_RESERVE, "fx-hub",
           "packages/fx-recibu/hub/src/rails/WorkspaceOperatingReserve.sol:WorkspaceOperatingReserve",
           "constructor(address,address)", (ARC_USDC, SAFE_ARC_AND_BASE)),
    Target(5042, "InvoiceShelf", ARC_SHELF, "fx-hub",
           "packages/fx-recibu/hub/src/invoice/InvoiceShelf.sol:InvoiceShelf",
           "constructor(address,address,address,address,address,bool)",
           (ARC_USDC, ARC_IDENTITY, ARC_REP, ARC_TIERS, SAFE_ARC_AND_BASE, "false")),
    Target(5042, "BINV", "0xB841BF47FEfcb4cAd2cBF7584c2DcB62255ace8D", "fx-hub",
           "packages/fx-recibu/hub/src/invoice/BINV.sol:BINV",
           "constructor(address)", (ARC_SHELF,)),
    Target(5042, "BIFTranche_bIF_A", "0xDdA5AaDD985f9f16650841979BE9BD9477d82A2D", "fx-hub",
           "packages/fx-recibu/hub/src/invoice/BIFTranche.sol:BIFTranche",
           "constructor(string,string,address)", ("BUFI Invoice Senior", "bIF-A", ARC_SHELF)),
    Target(5042, "BIFTranche_bIF_B", "0x1136B27a2bfd328f99A9De5E146A55b72036d3a1", "fx-hub",
           "packages/fx-recibu/hub/src/invoice/BIFTranche.sol:BIFTranche",
           "constructor(string,string,address)", ("BUFI Invoice Mezzanine", "bIF-B", ARC_SHELF)),
    Target(5042, "BIFTranche_bIF_C", "0x73aB46451999854B515BB875fd7F6cbFFa597689", "fx-hub",
           "packages/fx-recibu/hub/src/invoice/BIFTranche.sol:BIFTranche",
           "constructor(string,string,address)", ("BUFI Invoice Junior", "bIF-C", ARC_SHELF)),
    Target(5042, "MultiTokenReceivableEscrow", ARC_ESCROW, "fx-hub",
           "packages/fx-recibu/hub/src/rails/MultiTokenReceivableEscrow.sol:MultiTokenReceivableEscrow",
           "constructor(address)", (SAFE_ARC_AND_BASE,)),
    Target(5042, "RecibuMemoRouter", "0xB9eA41D9a9a9BF2F81a4FC9d22994226F4645b52", "fx-hub",
           "packages/fx-recibu/hub/src/rails/RecibuMemoRouter.sol:RecibuMemoRouter",
           "constructor(address,address,address)", (ARC_SHELF, ARC_ESCROW, SAFE_ARC_AND_BASE)),

    Target(5042, "CctpDepositForwarder", FWD_IMPL, "fx-cctp-forwarder",
           "packages/fx-recibu/cctp-forwarder/src/rails/cctp/CctpDepositForwarder.sol:CctpDepositForwarder"),
    Target(5042, "CctpDepositForwarderFactory", "0x4C3D9249C8FEE9d35B045B09b97fc99CE6CEB8E5", "fx-cctp-forwarder",
           "packages/fx-recibu/cctp-forwarder/src/rails/cctp/CctpDepositForwarderFactory.sol:CctpDepositForwarderFactory",
           "constructor(address,address,address)", (FWD_IMPL, ARC_USDC, CCTP_TOKEN_MESSENGER)),

    Target(5042, "ClaimVaultDeployer", "0xA8376Fe8Ef5a6640e39f047c751d7740C10f2cEA", "claim-vault",
           "packages/claim-vault/src/deploy/ClaimVaultDeployer.sol:ClaimVaultDeployer",
           "constructor(address,address)", (SAFE_ARC_AND_BASE, MFA_AUTHORIZER)),
    Target(5042, "PeanutV4", ARC_PEANUT, "claim-vault",
           "packages/claim-vault/src/V4/PeanutV4.4.sol:PeanutV4",
           "constructor(address,address)", (ZERO_ADDR, MFA_AUTHORIZER)),
    Target(5042, "PayrollBatch", "0x7DFBb79878a70d1981D0DF76c8262fDddd883FEc", "claim-vault",
           "packages/claim-vault/src/payroll/PayrollBatch.sol:PayrollBatch",
           "constructor(address,address)", (PERMIT2, ARC_PEANUT)),

    # --- Avalanche C-Chain (43114) — 10 vNext contracts ---
    Target(43114, "TreasuryConduit_v2", "0xe7E3592A5c911C094c401743E5727122579AF153", "default",
           "packages/treasury-conduits/src/bufi/conduit/TreasuryConduit.sol:TreasuryConduit",
           "constructor(address)", (SAFE_AVAX,)),
    Target(43114, "TreasuryConduitPermit2_v2", "0xfd39bD3147b7dB1382164642c1CC0453395fC6A8", "default",
           "packages/treasury-conduits/src/bufi/conduit/TreasuryConduitPermit2.sol:TreasuryConduitPermit2",
           "constructor(address,address,address)", (SAFE_AVAX, PERMIT2, COLD_STORAGE)),
    Target(43114, "TreasuryBridgeConduitV2", "0xB72563dC5eB2D63e3eE7b0d7e01327018F922ff1", "default",
           "packages/treasury-conduits/src/bufi/conduit/TreasuryBridgeConduitV2.sol:TreasuryBridgeConduitV2",
           "constructor(address)", (SAFE_AVAX,)),

    Target(43114, "TreasuryBridgeConduit_v3", "0x5891A451F60C36d74367b047D385E360D70f3242", "treasury-v3",
           "packages/treasury-conduits/v3/src/bufi/conduit/TreasuryBridgeConduit.sol:TreasuryBridgeConduit",
           "constructor(address)", (SAFE_AVAX,)),
    Target(43114, "TreasuryBridgeConduitPermit2_v3", "0x92580aDb23973567C8590978aA202768606d26b9", "treasury-v3",
           "packages/treasury-conduits/v3/src/bufi/conduit/TreasuryBridgeConduitPermit2.sol:TreasuryBridgeConduitPermit2",
           "constructor(address,address)", (SAFE_AVAX, PERMIT2)),

    Target(43114, "CctpDepositForwarder", FWD_IMPL, "fx-cctp-forwarder",
           "packages/fx-recibu/cctp-forwarder/src/rails/cctp/CctpDepositForwarder.sol:CctpDepositForwarder"),
    Target(43114, "CctpDepositForwarderFactory", "0x1E4B7346FbBadAd0b63e7b424f36A6A4C3690354", "fx-cctp-forwarder",
           "packages/fx-recibu/cctp-forwarder/src/rails/cctp/CctpDepositForwarderFactory.sol:CctpDepositForwarderFactory",
           "constructor(address,address,address)", (FWD_IMPL, AVAX_USDC, CCTP_TOKEN_MESSENGER)),

    Target(43114, "ClaimVaultDeployer", "0x05c14dfd71bD9028909ce42c7F6dC645D6DfA927", "claim-vault",
           "packages/claim-vault/src/deploy/ClaimVaultDeployer.sol:ClaimVaultDeployer",
           "constructor(address,address)", (SAFE_AVAX, MFA_AUTHORIZER)),
    Target(43114, "PeanutV4", AVAX_PEANUT, "claim-vault",
           "packages/claim-vault/src/V4/PeanutV4.4.sol:PeanutV4",
           "constructor(address,address)", (ZERO_ADDR, MFA_AUTHORIZER)),
    Target(43114, "PayrollBatch", "0x0eD7f2a1edb378fB8407c1B7E187fd1b5daC25Cf", "claim-vault",
           "packages/claim-vault/src/payroll/PayrollBatch.sol:PayrollBatch",
           "constructor(address,address)", (PERMIT2, AVAX_PEANUT)),

    # --- Base Mainnet (8453) — 5 vNext contracts ---
    Target(8453, "CctpDepositForwarder", FWD_IMPL, "fx-cctp-forwarder",
           "packages/fx-recibu/cctp-forwarder/src/rails/cctp/CctpDepositForwarder.sol:CctpDepositForwarder"),
    Target(8453, "CctpDepositForwarderFactory", "0x15d3A8C8Cd938D57D211BaFf2987FacA3B81fd1C", "fx-cctp-forwarder",
           "packages/fx-recibu/cctp-forwarder/src/rails/cctp/CctpDepositForwarderFactory.sol:CctpDepositForwarderFactory",
           "constructor(address,address,address)", (FWD_IMPL, BASE_USDC, CCTP_TOKEN_MESSENGER)),
    Target(8453, "ClaimVaultDeployer", "0xA8376Fe8Ef5a6640e39f047c751d7740C10f2cEA", "claim-vault",
           "packages/claim-vault/src/deploy/ClaimVaultDeployer.sol:ClaimVaultDeployer",
           "constructor(address,address)", (SAFE_ARC_AND_BASE, MFA_AUTHORIZER)),
    Target(8453, "PeanutV4", BASE_PEANUT, "claim-vault",
           "packages/claim-vault/src/V4/PeanutV4.4.sol:PeanutV4",
           "constructor(address,address)", (ZERO_ADDR, MFA_AUTHORIZER)),
    Target(8453, "PayrollBatch", "0x7DFBb79878a70d1981D0DF76c8262fDddd883FEc", "claim-vault",
           "packages/claim-vault/src/payroll/PayrollBatch.sol:PayrollBatch",
           "constructor(address,address)", (PERMIT2, BASE_PEANUT)),
]


def http_get_json(url: str) -> dict | None:
    req = urllib.request.Request(url, headers={"User-Agent": "bufi-verifier/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError):
        return None


def sourcify_status(chain_id: int, address: str) -> str | None:
    data = http_get_json(f"https://sourcify.dev/server/v2/contract/{chain_id}/{address}")
    if data and data.get("match"):
        return str(data["match"])
    return None


def routescan_avax_verified(address: str) -> bool:
    url = (
        "https://api.routescan.io/v2/network/mainnet/evm/43114/etherscan/api"
        f"?module=contract&action=getsourcecode&address={address}"
    )
    data = http_get_json(url)
    if not data or data.get("status") != "1":
        return False
    res = data.get("result") or []
    return bool(res and res[0].get("SourceCode"))


def encode_ctor(target: Target) -> str | None:
    if not target.ctor_sig:
        return None
    out = subprocess.check_output(
        ["cast", "abi-encode", target.ctor_sig, *target.ctor_args],
        text=True,
    ).strip()
    return out


def run_forge_verify(target: Target, verifier: str, extra_flags: list[str]) -> tuple[bool, str]:
    cmd = [
        "forge",
        "verify-contract",
        target.address,
        target.contract_spec,
        "--chain-id",
        str(target.chain_id),
        "--verifier",
        verifier,
        "--watch",
        "--retries",
        "10",
        "--delay",
        "5",
        *extra_flags,
    ]
    ctor_hex = encode_ctor(target)
    if ctor_hex:
        cmd.extend(["--constructor-args", ctor_hex])
    env = os.environ.copy()
    env["FOUNDRY_PROFILE"] = target.profile
    proc = subprocess.run(
        cmd,
        cwd=str(SPOOKY_ROOT),
        env=env,
        capture_output=True,
        text=True,
    )
    combined = (proc.stdout + "\n" + proc.stderr).strip()
    ok = proc.returncode == 0 or "already verified" in combined.lower() or "exact_match" in combined.lower()
    summary_line = ""
    for line in reversed(combined.splitlines()):
        s = line.strip()
        if s:
            summary_line = s
            break
    return ok, summary_line


def verify_profile_group(profile: str, group: list[Target]) -> list[dict]:
    results: list[dict] = []
    etherscan_key = os.environ.get("ETHERSCAN_API_KEY", "").strip()

    for t in group:
        entry = {
            "chainId": t.chain_id,
            "name": t.name,
            "address": t.address,
            "profile": profile,
            "sourcify": None,
            "snowtrace": None,
            "etherscan": None,
        }

        # 1. Sourcify (all 3 chains — feeds Safe, Blockscout, Tenderly, and Etherscan v2)
        existing = sourcify_status(t.chain_id, t.address)
        if existing:
            entry["sourcify"] = f"already:{existing}"
        else:
            ok, msg = run_forge_verify(t, "sourcify", [])
            final = sourcify_status(t.chain_id, t.address)
            entry["sourcify"] = final if final else (f"ok:{msg}" if ok else f"err:{msg}")
        print(f"[sourcify] {t.chain_id} {t.name} ({t.address}): {entry['sourcify']}", flush=True)

        # 2. Snowtrace / Routescan (Avalanche 43114, keyless)
        if t.chain_id == 43114:
            if routescan_avax_verified(t.address):
                entry["snowtrace"] = "already:verified"
            else:
                ok, msg = run_forge_verify(
                    t,
                    "etherscan",
                    [
                        "--verifier-url",
                        "https://api.routescan.io/v2/network/mainnet/evm/43114/etherscan/api",
                        "--etherscan-api-key",
                        "verifyContract",
                    ],
                )
                entry["snowtrace"] = "verified" if (ok or routescan_avax_verified(t.address)) else f"err:{msg}"
            print(f"[snowtrace] {t.chain_id} {t.name} ({t.address}): {entry['snowtrace']}", flush=True)

        # 3. Optional direct Etherscan v2 (Basescan / Snowscan) when ETHERSCAN_API_KEY is configured
        if etherscan_key and t.chain_id in (8453, 43114):
            ok, msg = run_forge_verify(t, "etherscan", ["--etherscan-api-key", etherscan_key])
            entry["etherscan"] = "verified" if ok else f"err:{msg}"
            print(f"[etherscan] {t.chain_id} {t.name} ({t.address}): {entry['etherscan']}", flush=True)

        results.append(entry)

    return results


def main() -> int:
    by_profile: dict[str, list[Target]] = defaultdict(list)
    for t in TARGETS:
        by_profile[t.profile].append(t)

    all_results: list[dict] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(by_profile)) as pool:
        futs = [pool.submit(verify_profile_group, prof, grp) for prof, grp in by_profile.items()]
        for fut in concurrent.futures.as_completed(futs):
            all_results.extend(fut.result())

    all_results.sort(key=lambda r: (r["chainId"], r["profile"], r["name"]))
    print("\n=== FINAL VERIFICATION SUMMARY ===")
    sourcify_ok = 0
    snowtrace_ok = 0
    for r in all_results:
        s = r["sourcify"] or ""
        if s.startswith("exact_match") or s.startswith("match") or s.startswith("already:") or s.startswith("ok:"):
            sourcify_ok += 1
        st = r["snowtrace"] or ""
        if st in ("verified", "already:verified"):
            snowtrace_ok += 1
        extra = f" | snowtrace={st}" if st else ""
        print(f"  {r['chainId']} {r['name']:32s} {r['address']} | sourcify={s}{extra}")

    print(f"\nTotals: Sourcify {sourcify_ok}/{len(all_results)}, Snowtrace(43114) {snowtrace_ok}/10")
    return 0 if sourcify_ok == len(all_results) and snowtrace_ok == 10 else 1


if __name__ == "__main__":
    sys.exit(main())
