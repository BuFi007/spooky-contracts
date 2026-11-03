#!/usr/bin/env bash
# Runs the Arc MAINNET (5042) fork suite against one Ripio wFX token resolved from the
# registry. Read-only fork: nothing is broadcast.
#   contracts/claim-vault/script/fork-arc-mainnet.sh [WARS|WBRL|WMXN|WCOP|WPEN|WCLP]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_LINE="$(bun "$HERE/arc-mainnet-wfx-env.ts" "${1:-WARS}")"
cd "$HERE/.."
# shellcheck disable=SC2086
env ARC_MAINNET_FORK=1 $ENV_LINE forge test --match-contract ArcMainnetWfxFork -vv
