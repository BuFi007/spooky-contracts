#!/usr/bin/env bash
# Build every profile. Pass extra forge args after --, for example:
#   ./script/build-all.sh --use solar
set -euo pipefail
cd "$(dirname "$0")/.."
args=("$@")
profiles=(default treasury-v3 agent-policy fx-hub fx-spoke fx-memo-v1 fx-stablefx fx-cctp-forwarder fx-doc-registry claim-vault)
for profile in "${profiles[@]}"; do
  echo "== forge build --profile ${profile} ${args[*]:-}"
  forge build --profile "${profile}" ${args[@]+"${args[@]}"}
done
