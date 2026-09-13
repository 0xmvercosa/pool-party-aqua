/** Loopback-only preparation and verification. Signing/broadcast exist only in the Rabby browser. */
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile, rename, open } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { erc20Abi, isHash, encodeAbiParameters, type Hex } from 'viem';
import { buildArtifacts } from './cash-plus-deploy/artifacts.ts';
import { createService, nextStage, type VaultVerification } from './cash-plus-deploy/service.ts';
import { liveManifest } from './cash-plus-deploy/manifest.ts';
import { canPrepare, requirePending, cancelUnsigned, recordHash, advance, type State } from './cash-plus-deploy/state.ts';
import { DEPLOYER, ORIGIN, OUTPUT, OFFICIAL, POLICY, SEED, config, rolesFromEnv, liveRpcUrl, json, requireThat, safeError } from './cash-plus-deploy/config.ts';

let ownedServer: ReturnType<typeof createServer> | undefined;
async function main() {
  requireThat(!process.env.VERCEL, 'This deployment assistant must run locally.');
  const roles = rolesFromEnv();
  const rpcUrl = liveRpcUrl();
  console.log('CASH+ / RABBY DEPLOYMENT\nArbitrum One · 3 transactions · 1,000 USDC permanently locked seed');
  console.log('Rebuilding with the cashplus compiler profile…');
  const artifacts = buildArtifacts();
  const service = createService(artifacts, roles, rpcUrl);
  // Take the fixed port before reading or mutating the durable journal.
  const server = createServer((_req, res) => { res.statusCode = 503; res.end('Initializing local deployment state.'); });
  ownedServer = server;
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(3211, '127.0.0.1', resolve); });
  await mkdir(OUTPUT, { recursive: true, mode: 0o700 });
  let state: State = { version: 1, owner: DEPLOYER, buildHash: service.buildHash,
    salt: `0x${randomBytes(32).toString('hex')}`, factory: null, approved: false, vault: null, pending: null, operations: [] };
  try {
    const saved = JSON.parse(await readFile(`${OUTPUT}/deployment.json`, 'utf8')) as State;
    const pristine = saved.version === 1 && !saved.factory && !saved.approved && !saved.vault && !saved.pending && Array.isArray(saved.operations) && saved.operations.length === 0;
    requireThat(saved.version === 1 && saved.owner === DEPLOYER && (saved.buildHash === service.buildHash || pristine) && isHash(saved.salt) &&
      Array.isArray(saved.operations), 'Saved journal belongs to another wallet, roles or build. Preserve it and use the original checkout.');
    if (saved.pending) service.assertReview(saved.pending.review);
    if (saved.buildHash === service.buildHash) state = saved;
  } catch (error) {
    if (!(error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT')) throw error;
  }
  async function save() {
    const temp = `${OUTPUT}/deployment.tmp`;
    const file = await open(temp, 'w', 0o600);
    try { await file.writeFile(`${json(state)}\n`); await file.sync(); } finally { await file.close(); }
    await rename(temp, `${OUTPUT}/deployment.json`);
    const dir = await open(OUTPUT, 'r');
    try { await dir.sync(); } finally { await dir.close(); }
  }
  await save();
  const constructor = artifacts.CashPlusVault.abi.find(item => item.type === 'constructor');
  requireThat(constructor?.type === 'constructor', 'Vault constructor ABI missing.');
  await writeFile(`${OUTPUT}/vault-constructor-args.hex`, encodeAbiParameters(constructor.inputs, service.vaultArgs) + '\n', { mode: 0o600 });
  await writeFile(`${OUTPUT}/factory-constructor-args.hex`, '0x\n', { mode: 0o600 });
  await writeFile(`${OUTPUT}/configuration.json`, json({ owner: DEPLOYER, chainId: 42161, config: config(roles), policy: POLICY,
    seed: SEED, permanentSeed: true, managementFeeBps: 0, performanceFeeBps: 0, buildHash: service.buildHash,
    initCodeHash: service.initCodeHash, compiler: artifacts.CashPlusVault.metadata.compiler,
    settings: artifacts.CashPlusVault.metadata.settings }) + '\n', { mode: 0o600 });
  // Standard JSON contains source code and compiler settings only, never the RPC URL.
  for (const [label, name] of [['factory', 'CashPlusDeploymentFactory'], ['vault', 'CashPlusVault'],
    ['oracle', 'CashPlusOracle'], ['adapter', 'CashPlusAaveAdapter'], ['pricing', 'CashPlusPricing'],
    ['program-factory', 'CashPlusProgramFactory'], ['lens', 'CashPlusLens']] as const) {
    const standard = execFileSync(process.env.FORGE_BIN || 'forge', ['verify-contract', DEPLOYER,
      `src/cashplus/${name}.sol:${name}`, '--root', 'contracts', '--show-standard-json-input'],
    { env: { ...process.env, FOUNDRY_PROFILE: 'cashplus', ARBISCAN_API_KEY: '', ARBITRUM_RPC_URL: '' },
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 8_000_000 });
    JSON.parse(standard);
    await writeFile(`${OUTPUT}/${label}-standard-input.json`, standard, { mode: 0o600 });
  }
  const token = randomBytes(32).toString('hex');
  let busy = false;
  const publicFiles: Record<string, [string, string]> = {
    '/': ['index.html', 'text/html; charset=utf-8'], '/app.js': ['app.js', 'text/javascript; charset=utf-8'], '/style.css': ['style.css', 'text/css; charset=utf-8'],
  };
  server.removeAllListeners('request');
  server.on('request', async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'no-referrer');
    res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'");
    const reply = (value: unknown, status = 200) => { res.statusCode = status; res.setHeader('Content-Type', 'application/json'); res.end(json(value)); };
    if (req.headers.host !== '127.0.0.1:3211' || (req.headers.origin && req.headers.origin !== ORIGIN)) {
      reply({ error: 'Exact loopback origin required.' }, 403); return;
    }
    const path = new URL(req.url || '/', ORIGIN).pathname;
    try {
      if (req.method === 'GET' && publicFiles[path]) {
        const [file, type] = publicFiles[path]; res.setHeader('Content-Type', type); res.end(await readFile(`scripts/cash-plus-deploy/${file}`)); return;
      }
      if (req.method === 'GET' && path === '/api/state') {
        let balances: { eth: string; usdc: string } | null = null;
        try {
          const [eth, usdc] = await Promise.all([service.client.getBalance({ address: DEPLOYER }),
            service.client.readContract({ address: OFFICIAL.usdc, abi: erc20Abi, functionName: 'balanceOf', args: [DEPLOYER] })]);
          balances = { eth: String(eth), usdc: String(usdc) };
        } catch { /* Missing read is displayed as unavailable, never zero. */ }
        reply({ state, token, balances, roles, config: config(roles), policy: POLICY, nextStage: nextStage(state), reportPath: `${OUTPUT}/deployment.json` }); return;
      }
      if (req.method === 'GET' && path === '/report.json') {
        res.setHeader('Content-Disposition', 'attachment; filename="cash-plus-deployment.json"'); reply(state); return;
      }
      if (req.method === 'GET' && path === '/manifest.json') {
        requireThat(state.vault, 'Verify the vault deployment before exporting a live manifest.');
        res.setHeader('Content-Disposition', 'attachment; filename="deployment.live.json"');
        reply(JSON.parse(await readFile(`${OUTPUT}/deployment.live.json`, 'utf8'))); return;
      }
      if (req.method !== 'POST' || req.headers.origin !== ORIGIN || req.headers['x-cash-plus-session'] !== token ||
        !req.headers['content-type']?.startsWith('application/json')) { reply({ error: 'Use the local deployment page.' }, 403); return; }
      if (busy) { reply({ error: 'Another operation is in progress.' }, 409); return; }
      busy = true;
      try {
        let body = '';
        for await (const chunk of req) { body += chunk; requireThat(body.length <= 4096, 'Request too large.'); }
        const input = JSON.parse(body || '{}') as Record<string, unknown>;
        if (path === '/api/prepare') {
          canPrepare(state);
          const review = await service.prepare(state);
          state.pending = { reviewId: randomBytes(16).toString('hex'), review, signingStarted: false, hash: null };
          await save();
          await writeFile(`${OUTPUT}/${review.stage}-unsigned.json`, json(review) + '\n', { mode: 0o600 });
          console.log(`PREPARED ${review.stage}; no transaction sent.`);
          reply({ review });
        } else if (path === '/api/begin') {
          const p = requirePending(state, input.reviewId);
          requireThat(!p.signingStarted && !p.hash, 'A signing request is already unresolved. Recover its hash.');
          requireThat(input.seedAcknowledged === true && input.rolesAcknowledged === true,
            'Acknowledge the permanent seed and all immutable roles before opening Rabby.');
          await service.revalidate(p.review);
          p.signingStarted = true;
          await save(); // Durable before any browser can call eth_sendTransaction.
          reply({ review: p.review, reviewId: p.reviewId });
        } else if (path === '/api/submitted') {
          requireThat(typeof input.hash === 'string' && isHash(input.hash), 'Invalid transaction hash.');
          recordHash(state, input.reviewId, input.hash);
          await save(); reply({ saved: true });
        } else if (path === '/api/verify') {
          const p = requirePending(state, input.reviewId);
          requireThat(p.signingStarted && typeof input.hash === 'string' && isHash(input.hash), 'A started review and transaction hash are required.');
          const result = await service.verify(p.review, input.hash);
          if (p.review.stage === 'vault' && result.receipt.status === 'success' &&
            (result.verification as VaultVerification).bootstrapStateMatches) {
            const c = (result.verification as VaultVerification).children;
            for (const [label, name, args] of [
              ['oracle', 'CashPlusOracle', [config(roles)]],
              ['usdc-adapter', 'CashPlusAaveAdapter', [p.review.expectedAddress, OFFICIAL.usdc, OFFICIAL.pool, OFFICIAL.usdcAToken]],
              ['secondary-adapter', 'CashPlusAaveAdapter', [p.review.expectedAddress, OFFICIAL.secondary, OFFICIAL.pool, OFFICIAL.secondaryAToken]],
              ['pricing', 'CashPlusPricing', [p.review.expectedAddress, OFFICIAL.router]],
              ['program-factory', 'CashPlusProgramFactory', [p.review.expectedAddress, c.pricing]],
              ['lens', 'CashPlusLens', [p.review.expectedAddress]],
            ] as const) {
              const abi = artifacts[name].abi.find(item => item.type === 'constructor');
              requireThat(abi?.type === 'constructor', 'Component constructor ABI missing.');
              await writeFile(`${OUTPUT}/${label}-constructor-args.hex`, encodeAbiParameters(abi.inputs, args) + '\n', { mode: 0o600 });
            }
            await writeFile(`${OUTPUT}/deployment.live.json`, json(liveManifest(p.review, result.receipt,
              result.verification as VaultVerification)) + '\n', { mode: 0o600 });
          }
          if (result.receipt.status === 'success') advance(state, p.review);
          state.operations.push({ review: p.review, hash: input.hash, ...result });
          state.pending = null;
          await save();
          console.log(`VERIFIED ${p.review.stage}: ${result.receipt.status}; block ${result.receipt.blockNumber}.`);
          reply({ status: result.receipt.status, expectedAddress: p.review.expectedAddress });
        } else if (path === '/api/rejected') {
          // Only explicit EIP-1193 user rejection can clear a started request. Timeouts/close/disconnect cannot.
          const p = requirePending(state, input.reviewId);
          requireThat(p.signingStarted && !p.hash && input.code === 4001, 'Only explicit Rabby rejection can release this signing request.');
          const [pendingNonce, latestNonce] = await Promise.all([
            service.client.getTransactionCount({ address: DEPLOYER, blockTag: 'pending' }),
            service.client.getTransactionCount({ address: DEPLOYER, blockTag: 'latest' }),
          ]);
          requireThat(pendingNonce === p.review.nonce && latestNonce === p.review.nonce, 'Wallet nonce changed. Recover the pending or mined hash.');
          state.operations.push({ review: p.review, status: 'rabby-explicit-user-rejection', recordedAt: new Date().toISOString() });
          state.pending = null; await save(); reply({ rejected: true });
        } else if (path === '/api/cancel') {
          cancelUnsigned(state, input.reviewId); await save(); reply({ cancelled: true });
        } else reply({ error: 'Unknown action.' }, 404);
      } finally { busy = false; }
    } catch (error) { const message = safeError(error); console.error(message); reply({ error: message }, 400); }
  });
  console.log(`READY ${ORIGIN}\nDeployer: ${DEPLOYER}\nOpen in Chrome/Brave with Rabby. Keep this terminal open. No transaction has been sent.`);
}
main().catch(error => { ownedServer?.close(); console.error(safeError(error)); process.exitCode = 1; });
