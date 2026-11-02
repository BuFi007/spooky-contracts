/**
 * Prints `ARC_WFX_TOKEN=… ARC_WFX_DECIMALS=…` for one Ripio wFX asset on Arc mainnet (5042),
 * read from the token registry (@bufinance/location via the BUFI overlay), so the Foundry
 * fork suite never carries a token address literal. KRW1 and non-wFX assets are refused.
 *
 *   bun contracts/claim-vault/script/arc-mainnet-wfx-env.ts WARS
 */
import { getDeploymentsForChainWithOverlay } from '@bu/transfer-utils/deployments';

const ARC_MAINNET_CHAIN_ID = 5042;
const WFX = new Set(['WARS', 'WBRL', 'WMXN', 'WCOP', 'WPEN', 'WCLP']);

const symbol = (process.argv[2] ?? 'WARS').toUpperCase();
if (!WFX.has(symbol)) {
  process.stderr.write(`${symbol} is not a Ripio wFX asset (KRW1 stays excluded)\n`);
  process.exit(2);
}
const row = getDeploymentsForChainWithOverlay(ARC_MAINNET_CHAIN_ID).find(d => d.asset === symbol);
if (!row) {
  process.stderr.write(`${symbol} has no registry deployment on chain ${ARC_MAINNET_CHAIN_ID}\n`);
  process.exit(3);
}
process.stdout.write(`ARC_WFX_TOKEN=${row.address} ARC_WFX_DECIMALS=${row.decimals}\n`);
