#!/usr/bin/env bash
# Test every profile. Pass extra forge args after the command, for example:
#   ./script/test-all.sh --use solar
set -euo pipefail
cd "$(dirname "$0")/.."
args=("$@")
profiles=(default fx-hub fx-spoke fx-memo-v1)
for profile in "${profiles[@]}"; do
  echo "== forge test --profile ${profile} ${args[*]:-}"
  forge test --profile "${profile}" "${args[@]}"
done
