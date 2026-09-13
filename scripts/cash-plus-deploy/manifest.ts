import type { TransactionReceipt } from 'viem';
import { OFFICIAL, PROTOCOL_HASHES, requireThat } from './config.ts';
import type { Review, VaultVerification } from './service.ts';

/** Schema-compatible frontend export; never copy a credential-bearing operator RPC into client code. */
export function liveManifest(review: Review, receipt: TransactionReceipt, verified: VaultVerification) {
  requireThat(review.stage === 'vault' && receipt.status === 'success' && verified.bootstrapStateMatches,
    'A live manifest requires a verified vault and unchanged bootstrap state.');
  const runId = `${receipt.blockNumber}-${review.expectedAddress.toLowerCase()}`;
  const c = verified.children;
  return {
    schemaVersion: 1, id: `cash-plus-${runId}`, runId, mode: 'live', chainId: 42161,
    networkName: 'Arbitrum One', rpcUrl: 'https://arb1.arbitrum.io/rpc',
    deploymentBlock: String(receipt.blockNumber), deploymentBlockHash: receipt.blockHash,
    vault: review.expectedAddress, aqua: OFFICIAL.aqua, router: OFFICIAL.router, aavePool: OFFICIAL.pool,
    usdc: { address: OFFICIAL.usdc, symbol: 'USDC', decimals: 6 },
    secondary: { address: OFFICIAL.secondary, symbol: 'USD₮0', decimals: 6 },
    usdcAdapter: c.usdcAdapter, secondaryAdapter: c.secondaryAdapter, usdcAToken: OFFICIAL.usdcAToken,
    secondaryAToken: OFFICIAL.secondaryAToken, pricing: c.pricing, programFactory: c.programFactory,
    oracle: c.oracle, usdcFeed: OFFICIAL.usdcFeed, secondaryFeed: OFFICIAL.secondaryFeed, sequencerFeed: OFFICIAL.sequencerFeed,
    explorerUrl: 'https://arbiscan.io',
    codeHashes: [...verified.contracts.map(value => ({ address: value.address, hash: value.runtimeHash })),
      ...Object.entries(PROTOCOL_HASHES).map(([address, hash]) => ({ address, hash }))],
    source: { chainId: 42161, blockNumber: String(receipt.blockNumber), swapVmCommit: '32c687c2b73101fc26549e48fa1ff8a4d73afbac' },
  };
}
