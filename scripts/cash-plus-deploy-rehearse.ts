/** TEST ONLY: creates, owns and destroys an isolated Anvil. Every write uses its loopback URL. */
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { randomBytes } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { createPublicClient, http, encodeFunctionData, erc20Abi, toHex, type Hex } from 'viem';
import { buildArtifacts } from './cash-plus-deploy/artifacts.ts';
import { createService } from './cash-plus-deploy/service.ts';
import { advance, canPrepare, recordHash, type State } from './cash-plus-deploy/state.ts';
import { DEPLOYER, OFFICIAL, SEED, json, liveRpcUrl, requireThat, safeError } from './cash-plus-deploy/config.ts';

const pause = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
async function main() {
  const artifacts = buildArtifacts();
  const upstream = liveRpcUrl();
  const source = createPublicClient({ transport: http(upstream, { timeout: 20000, retryCount: 1 }) });
  requireThat(await source.getChainId() === 42161, 'Fork source must be Arbitrum One.');
  const head = await source.getBlock();
  const port = await new Promise<number>((resolve, reject) => {
    const server = createServer(); server.once('error', reject);
    server.listen(0, '127.0.0.1', () => { const address = server.address();
      requireThat(address && typeof address === 'object', 'Could not reserve a local port.'); server.close(() => resolve(address.port)); });
  });
  const localUrl = `http://127.0.0.1:${port}`;
  requireThat(new URL(localUrl).hostname === '127.0.0.1', 'Rehearsal writes must remain loopback.');
  const child = spawn(process.env.ANVIL_BIN || 'anvil', ['--host', '127.0.0.1', '--port', String(port),
    '--chain-id', '42161', '--fork-url', upstream, '--fork-block-number', String(head.number), '--silent'], { stdio: 'ignore' });
  let spawnError: unknown;
  child.on('error', error => { spawnError = error; });
  type Metadata = { instanceId: string; chainId: number; forkedNetwork?: { chainId: number; forkBlockHash: Hex } };
  let instanceId: string | undefined;
  async function rpc<T>(method: string, params: unknown[] = []): Promise<T> {
    requireThat(!spawnError && child.exitCode === null && !child.killed, 'Owned Anvil process is not running.');
    const response = await fetch(localUrl, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: json({ jsonrpc: '2.0', id: 1, method, params }), signal: AbortSignal.timeout(30000) });
    const result = await response.json() as { result?: T; error?: unknown };
    requireThat(!result.error && result.result !== undefined, `Local fork RPC failed: ${method}.`);
    return result.result;
  }
  async function assertOwnedFork() {
    const metadata = await rpc<Metadata>('anvil_metadata');
    requireThat(metadata.chainId === 42161 && metadata.instanceId === instanceId &&
      metadata.forkedNetwork?.chainId === 42161 && metadata.forkedNetwork.forkBlockHash === head.hash,
    'Local fork identity changed. No transaction will be sent.');
  }
  async function write<T>(method: string, params: unknown[] = []) {
    await assertOwnedFork(); return rpc<T>(method, params);
  }
  try {
    for (let i = 0; i < 100; i++) {
      try { const metadata = await rpc<Metadata>('anvil_metadata'); instanceId = metadata.instanceId; break; } catch { await pause(200); }
    }
    requireThat(instanceId, 'Owned Anvil failed to start.');
    await assertOwnedFork();
    console.log(`FORK ONLY · owned Anvil ${localUrl} · source block ${head.number}`);
    console.log('RUN synthetic seed funding on the owned local fork…');
    await write('anvil_setBalance', [DEPLOYER, toHex(10n ** 19n)]);
    await write('anvil_impersonateAccount', [DEPLOYER]);
    await write('anvil_setBalance', [OFFICIAL.usdcAToken, toHex(10n ** 18n)]);
    await write('anvil_impersonateAccount', [OFFICIAL.usdcAToken]);
    const client = createPublicClient({ transport: http(localUrl, { timeout: 30000, retryCount: 0 }) });
    const funded = await write<Hex>('eth_sendTransaction', [{ from: OFFICIAL.usdcAToken, to: OFFICIAL.usdc, value: '0x0',
      data: encodeFunctionData({ abi: erc20Abi, functionName: 'transfer', args: [DEPLOYER, SEED] }) }]);
    requireThat((await client.waitForTransactionReceipt({ hash: funded })).status === 'success', 'Synthetic fork seed funding failed.');
    await write('anvil_stopImpersonatingAccount', [OFFICIAL.usdcAToken]);
    const roles = { governance: DEPLOYER, keeper: DEPLOYER, guardian: DEPLOYER };
    const service = createService(artifacts, roles, localUrl, client);
    let state: State = { version: 1, owner: DEPLOYER, buildHash: service.buildHash, salt: `0x${randomBytes(32).toString('hex')}`,
      factory: null, approved: false, vault: null, pending: null, operations: [] };
    for (const expectedStage of ['factory', 'approval', 'vault']) {
      console.log(`RUN ${expectedStage} preparation and simulation…`);
      await write('evm_setNextBlockTimestamp', [Math.max(Number((await client.getBlock()).timestamp) + 1, Math.floor(Date.now() / 1000))]);
      await write('evm_mine');
      canPrepare(state);
      const review = await service.prepare(state);
      requireThat(review.stage === expectedStage, 'Unexpected rehearsal stage.');
      const reviewId = randomBytes(16).toString('hex');
      state.pending = { reviewId, review, signingStarted: true, hash: null };
      await service.revalidate(review);
      const hash = await write<Hex>('eth_sendTransaction', [{ from: DEPLOYER, chainId: '0xa4b1',
        nonce: toHex(review.nonce), data: review.data, value: '0x0', gas: review.gas, ...(review.to ? { to: review.to } : {}) }]);
      recordHash(state, reviewId, hash);
      // Round-trip the same JSON journal format before verifying, as after a local server restart.
      state = JSON.parse(json(state)) as State;
      const receipt = await client.waitForTransactionReceipt({ hash });
      requireThat(receipt.status === 'success', `Fork ${expectedStage} reverted.`);
      const result = await service.verify(state.pending!.review, hash);
      advance(state, state.pending!.review);
      state.operations.push({ review, hash, ...result }); state.pending = null;
      console.log(`PASS ${expectedStage}: receipt + runtime/effects + restored review; gas ${receipt.gasUsed}`);
    }
    await mkdir('.runtime', { recursive: true });
    await writeFile('.runtime/cash-plus-deployment-rehearsal.json', json({ mode: 'isolated-local-fork',
      mainnetDeployment: false, networkNote: 'The isolated Anvil deliberately uses chain ID 42161 to exercise the exact live receipt checks. These hashes are not Arbitrum transactions.',
      sourceBlock: String(head.number), sourceBlockHash: head.hash, anvilInstanceId: instanceId, state }) + '\n', { mode: 0o600 });
    console.log('PASS all three stages. Report: .runtime/cash-plus-deployment-rehearsal.json. No live transaction sent.');
  } finally {
    child.kill('SIGTERM');
  }
}
main().catch(error => {
  console.error(safeError(error));
  process.exitCode = 1;
});
