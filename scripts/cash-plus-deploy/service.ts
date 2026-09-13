import {
  createPublicClient, http, encodeDeployData, encodeFunctionData, encodeAbiParameters, getContractAddress,
  keccak256, stringToHex, erc20Abi, parseAbi, decodeEventLog, type Address, type Hex, type PublicClient,
  type Transaction, type TransactionReceipt,
} from 'viem';
import { arbitrum } from 'viem/chains';
import { config, POLICY, SEED, SEED_HOLDER, DEPLOYER, CHAIN_ID, OFFICIAL, PROTOCOL_HASHES, json, requireThat, type Roles } from './config.ts';
import { assertRuntime, type Artifacts, type ContractName } from './artifacts.ts';

export type Stage = 'factory' | 'approval' | 'vault';
export type Progress = { factory: Address | null; approved: boolean; vault: Address | null; salt: Hex };
export type Review = {
  stage: Stage; owner: Address; chainId: 42161; nonce: number; to: Address | null; expectedAddress: Address;
  data: Hex; value: '0x0'; gas: Hex; gasEstimate: string; gasPriceWei: string; estimatedFeeWei: string;
  balanceWei: string; usdcBalance: string; blockNumber: string; blockHash: Hex; expiresAt: number;
  buildHash: Hex; factory: Address | null; salt: Hex; initCodeHash: Hex; roles: Roles;
};
export function nextStage(progress: Progress): Stage | null {
  return progress.vault ? null : !progress.factory ? 'factory' : !progress.approved ? 'approval' : 'vault';
}
const eq = (a: string | null | undefined, b: string | null | undefined) => a?.toLowerCase() === b?.toLowerCase();
export function predictVault(factory: Address, sponsor: Address, salt: Hex, initCodeHash: Hex): Address {
  const bound = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'bytes32' }], [sponsor, salt]));
  return getContractAddress({ opcode: 'CREATE2', from: factory, salt: bound, bytecodeHash: initCodeHash });
}
export function children(vault: Address) {
  const child = (nonce: bigint) => getContractAddress({ from: vault, nonce });
  return { oracle: child(1n), usdcAdapter: child(2n), secondaryAdapter: child(3n), pricing: child(4n), programFactory: child(5n), lens: child(6n) };
}

/** CREATE2 is internal to factory.deploy: a successful vault receipt has no contractAddress. */
export function assertReceiptBinding(review: Review,
  tx: Pick<Transaction, 'from' | 'to' | 'input' | 'value' | 'nonce' | 'chainId' | 'blockHash'>,
  receipt: Pick<TransactionReceipt, 'status' | 'contractAddress' | 'blockHash'>) {
  requireThat(eq(tx.from, review.owner) && eq(tx.to, review.to) && eq(tx.input, review.data) && tx.value === 0n &&
    tx.nonce === review.nonce && tx.chainId === CHAIN_ID && eq(tx.blockHash, receipt.blockHash),
  'Receipt does not match the reviewed wallet, chain, destination, nonce, value and complete calldata.');
  if (receipt.status === 'success') requireThat(review.stage === 'factory' ?
    eq(receipt.contractAddress, review.expectedAddress) : receipt.contractAddress === null,
  'Unexpected CREATE/CREATE2 receipt contract address.');
}

export function createService(artifacts: Artifacts, roles: Roles, rpcUrl: string, suppliedClient?: PublicClient) {
  // Injection is exclusively used by the isolated fork rehearsal; the HTTP server only accepts HTTPS Arbitrum RPCs.
  const client = suppliedClient || createPublicClient({ chain: arbitrum, transport: http(rpcUrl, { timeout: 20000, retryCount: 1 }) });
  const vaultArgs = [config(roles), POLICY] as const;
  const initCode = encodeDeployData({ abi: artifacts.CashPlusVault.abi, bytecode: artifacts.CashPlusVault.bytecode.object, args: vaultArgs });
  const factoryData = encodeDeployData({ abi: artifacts.CashPlusDeploymentFactory.abi, bytecode: artifacts.CashPlusDeploymentFactory.bytecode.object });
  requireThat((initCode.length - 2) / 2 <= 49152, 'Vault initcode exceeds EIP-3860.');
  const initCodeHash = keccak256(initCode);
  const buildHash = keccak256(stringToHex(json({ factoryData, initCode, roles, chainId: CHAIN_ID, owner: DEPLOYER, seed: SEED,
    artifacts: Object.values(artifacts).map(a => ({ runtime: a.deployedBytecode.object, immutables: a.deployedBytecode.immutableReferences })) })));
  const get = (address: Address, name: ContractName, functionName: string, blockNumber: bigint, args?: readonly unknown[]) =>
    client.readContract({ address, abi: artifacts[name].abi, functionName, args, blockNumber });
  const balance = (token: Address, owner: Address, blockNumber: bigint) => client.readContract({ address: token, abi: erc20Abi, functionName: 'balanceOf', args: [owner], blockNumber });
  const allowance = (factory: Address, blockNumber: bigint) => client.readContract({ address: OFFICIAL.usdc, abi: erc20Abi, functionName: 'allowance', args: [DEPLOYER, factory], blockNumber });

  async function checkContract(address: Address, name: ContractName, values: Record<string, string | number | bigint>, blockNumber: bigint) {
    const code = await client.getCode({ address, blockNumber });
    const runtimeHash = assertRuntime(code, artifacts[name], values);
    await Promise.all(Object.entries(values).map(async ([key, expected]) => {
      const actual = await get(address, name, key, blockNumber);
      requireThat(String(actual).toLowerCase() === String(expected).toLowerCase(), `${name}.${key} getter differs from the expected immutable.`);
    }));
    return { address, runtimeHash, runtimeBytes: (code!.length - 2) / 2, immutables: values };
  }
  const checkFactory = (address: Address, blockNumber: bigint) => checkContract(address, 'CashPlusDeploymentFactory', {}, blockNumber);
  async function preflight() {
    requireThat(await client.getChainId() === CHAIN_ID, 'RPC is not Arbitrum One (42161).');
    const block = await client.getBlock();
    requireThat(Math.abs(Date.now() / 1000 - Number(block.timestamp)) < 120, 'RPC head is stale. Use a fresh Arbitrum RPC.');
    await Promise.all(Object.entries(OFFICIAL).map(async ([name, address]) => {
      const code = await client.getCode({ address, blockNumber: block.number });
      requireThat(code && code !== '0x', `Official ${name} address has no runtime.`);
      const hash = PROTOCOL_HASHES[address as keyof typeof PROTOCOL_HASHES];
      if (hash) requireThat(keccak256(code) === hash, 'Official Aqua/SwapVM runtime differs from the reviewed release.');
    }));
    const reserveAbi = parseAbi(['function UNDERLYING_ASSET_ADDRESS() view returns(address)', 'function POOL() view returns(address)', 'function AQUA() view returns(address)']);
    await Promise.all([[OFFICIAL.usdcAToken, OFFICIAL.usdc], [OFFICIAL.secondaryAToken, OFFICIAL.secondary]].map(async ([token, asset]) => {
      const [underlying, pool] = await Promise.all([
        client.readContract({ address: token!, abi: reserveAbi, functionName: 'UNDERLYING_ASSET_ADDRESS', blockNumber: block.number }),
        client.readContract({ address: token!, abi: reserveAbi, functionName: 'POOL', blockNumber: block.number }),
      ]);
      requireThat(eq(underlying, asset) && eq(pool, OFFICIAL.pool), 'Aave reserve identity differs from the official configuration.');
    }));
    requireThat(eq(await client.readContract({ address: OFFICIAL.router, abi: reserveAbi, functionName: 'AQUA', blockNumber: block.number }), OFFICIAL.aqua), 'SwapVM is not wired to the official Aqua.');
    const feedAbi = parseAbi(['function description() view returns(string)', 'function decimals() view returns(uint8)',
      'function latestRoundData() view returns(uint80,int256,uint256,uint256,uint80)']);
    const times = await Promise.all([[OFFICIAL.usdcFeed, 'USDC/USD'], [OFFICIAL.secondaryFeed, 'USDT/USD']].map(async ([address, description]) => {
      const [actualDescription, decimals, round] = await Promise.all([
        client.readContract({ address: address as Address, abi: feedAbi, functionName: 'description', blockNumber: block.number }),
        client.readContract({ address: address as Address, abi: feedAbi, functionName: 'decimals', blockNumber: block.number }),
        client.readContract({ address: address as Address, abi: feedAbi, functionName: 'latestRoundData', blockNumber: block.number }),
      ]);
      requireThat(actualDescription.replace(/\s/g, '') === description && decimals <= 18, 'Price feed description or decimals differ from the reviewed USD feed.');
      const [id, answer, started, updated, answered] = round;
      requireThat(id > 0n && answer > 0n && answered >= id && updated > 0n && started <= updated &&
        updated <= block.timestamp && block.timestamp - updated <= 90000n, 'Price feed is invalid or stale.');
      const price = answer * 10n ** BigInt(18 - decimals);
      requireThat(price >= 995_000_000_000_000_000n && price <= 1_005_000_000_000_000_000n, 'A stablecoin price exceeds the 0.5% peg guard.');
      return updated;
    }));
    requireThat((times[0]! > times[1]! ? times[0]! - times[1]! : times[1]! - times[0]!) <= 90000n, 'USD feed timestamp skew exceeds the configured limit.');
    const sequence = await client.readContract({ address: OFFICIAL.sequencerFeed, abi: feedAbi, functionName: 'latestRoundData', blockNumber: block.number });
    requireThat(sequence[1] === 0n && sequence[2] > 0n && sequence[2] <= block.timestamp && sequence[3] <= block.timestamp &&
      block.timestamp - sequence[2] > 3600n, 'Arbitrum sequencer is unavailable or still in its one-hour grace period.');
    for (const address of [OFFICIAL.usdc, OFFICIAL.secondary]) requireThat(await client.readContract({ address, abi: erc20Abi,
      functionName: 'decimals', blockNumber: block.number }) === 6, 'This deployment requires both official stablecoins to have six decimals.');
    return block;
  }
  function transaction(stage: Stage, factory: Address | null, salt: Hex) {
    if (stage === 'factory') return { to: null, data: factoryData };
    requireThat(factory, 'Verify the factory first.');
    return stage === 'approval' ? {
      to: OFFICIAL.usdc, data: encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [factory, SEED] }),
    } : { to: factory, data: encodeFunctionData({ abi: artifacts.CashPlusDeploymentFactory.abi, functionName: 'deploy', args: [initCode, OFFICIAL.usdc, SEED, salt] }) };
  }
  function assertReview(review: Review) {
    const expected = transaction(review.stage, review.factory, review.salt);
    requireThat(review.buildHash === buildHash && review.owner === DEPLOYER && review.chainId === CHAIN_ID &&
      review.initCodeHash === initCodeHash && json(review.roles) === json(roles) &&
      review.data === expected.data && review.to === expected.to && review.value === '0x0' &&
      review.expectedAddress === (review.stage === 'factory' ? getContractAddress({ from: DEPLOYER, nonce: BigInt(review.nonce) }) :
        review.stage === 'approval' ? review.factory : predictVault(review.factory!, DEPLOYER, review.salt, initCodeHash)),
    'Saved review differs from this build, roles, wallet or deployment parameters.');
  }
  async function checks(stage: Stage, factory: Address | null, salt: Hex) {
    const block = await preflight();
    if (factory) await checkFactory(factory, block.number);
    const usdcBalance = await balance(OFFICIAL.usdc, DEPLOYER, block.number);
    requireThat(usdcBalance >= SEED, 'The deployer needs at least 1,000 USDC on Arbitrum. The seed is permanently locked.');
    if (stage === 'vault') {
      requireThat(factory && await allowance(factory, block.number) === SEED, 'USDC allowance must equal exactly 1,000 USDC for the verified factory.');
      const vault = predictVault(factory, DEPLOYER, salt, initCodeHash);
      const onchainPrediction = await get(factory, 'CashPlusDeploymentFactory', 'predict', block.number, [DEPLOYER, salt, initCodeHash]);
      requireThat(eq(String(onchainPrediction), vault), 'Factory CREATE2 prediction differs from local calculation.');
      // Constructor rejects prefunding; surface it before asking for a signature.
      for (const address of [vault, ...Object.values(children(vault))]) {
        const [code, b0, b1, b2, b3] = await Promise.all([client.getCode({ address, blockNumber: block.number }),
          ...[OFFICIAL.usdc, OFFICIAL.secondary, OFFICIAL.usdcAToken, OFFICIAL.secondaryAToken].map(token => balance(token, address, block.number))]);
        requireThat((!code || code === '0x') && [b0, b1, b2, b3].every(v => v === 0n),
          'Predicted vault or child is already deployed or prefunded. Preserve this journal and investigate; do not seed manually.');
      }
    }
    const [nonce, latestNonce, ethBalance] = await Promise.all([
      client.getTransactionCount({ address: DEPLOYER, blockTag: 'pending' }),
      client.getTransactionCount({ address: DEPLOYER, blockTag: 'latest' }),
      client.getBalance({ address: DEPLOYER, blockNumber: block.number }),
    ]);
    requireThat(nonce === latestNonce, 'This wallet has a pending transaction. Resolve it in Rabby before preparing a new step.');
    return { block, nonce, ethBalance, usdcBalance };
  }
  async function simulate(stage: Stage, factory: Address | null, salt: Hex) {
    const context = await checks(stage, factory, salt);
    const tx = transaction(stage, factory, salt);
    const request = { account: DEPLOYER, data: tx.data, value: 0n, ...(tx.to ? { to: tx.to } : {}) };
    const [call, gasEstimate, gasPrice] = await Promise.all([client.call(request), client.estimateGas(request), client.getGasPrice()]);
    if (stage === 'approval') requireThat(call.data && BigInt(call.data) === 1n, 'USDC approval simulation did not return true.');
    const gas = (gasEstimate * 120n + 99n) / 100n;
    requireThat(context.ethBalance >= gas * gasPrice, 'Insufficient ETH on Arbitrum for the reviewed gas estimate.');
    return { ...context, ...tx, gas, gasEstimate, gasPrice };
  }
  async function prepare(progress: Progress): Promise<Review> {
    const stage = nextStage(progress);
    requireThat(stage, 'All three deployment steps are already verified.');
    const s = await simulate(stage, progress.factory, progress.salt);
    return { stage, owner: DEPLOYER, chainId: CHAIN_ID, nonce: s.nonce, to: s.to, data: s.data, value: '0x0',
      expectedAddress: stage === 'factory' ? getContractAddress({ from: DEPLOYER, nonce: BigInt(s.nonce) }) :
        stage === 'approval' ? progress.factory! : predictVault(progress.factory!, DEPLOYER, progress.salt, initCodeHash),
      gas: `0x${s.gas.toString(16)}`, gasEstimate: String(s.gasEstimate), gasPriceWei: String(s.gasPrice), estimatedFeeWei: String(s.gas * s.gasPrice),
      balanceWei: String(s.ethBalance), usdcBalance: String(s.usdcBalance), blockNumber: String(s.block.number), blockHash: s.block.hash,
      expiresAt: Date.now() + 180_000, buildHash, factory: progress.factory, salt: progress.salt, initCodeHash, roles };
  }
  async function revalidate(review: Review) {
    assertReview(review);
    requireThat(Date.now() < review.expiresAt, 'Unsigned review expired. Cancel it and prepare a fresh review.');
    const fresh = await simulate(review.stage, review.factory, review.salt);
    requireThat(fresh.nonce === review.nonce, 'Wallet nonce changed. Cancel the unsigned review and prepare again.');
    requireThat(fresh.gasEstimate <= BigInt(review.gas), 'Gas estimate increased beyond the reviewed limit. Prepare a new review.');
    requireThat(fresh.ethBalance >= BigInt(review.gas) * fresh.gasPrice, 'ETH balance no longer covers the reviewed gas.');
    requireThat(Date.now() < review.expiresAt, 'Review expired during revalidation. Prepare again.');
  }
  async function checkVault(vault: Address, factory: Address, blockNumber: bigint) {
    const c = children(vault);
    const decimals = await Promise.all([OFFICIAL.usdcFeed, OFFICIAL.secondaryFeed, OFFICIAL.secondary].map(address =>
      client.readContract({ address, abi: erc20Abi, functionName: 'decimals', blockNumber })));
    requireThat(decimals.every(d => d <= 18), 'Unsupported token/feed decimals.');
    const reports = await Promise.all([
      checkContract(vault, 'CashPlusVault', { USDC: OFFICIAL.usdc, SECONDARY_STABLE: OFFICIAL.secondary, AQUA: OFFICIAL.aqua,
        ROUTER: OFFICIAL.router, GOVERNANCE: roles.governance, KEEPER: roles.keeper, GUARDIAN: roles.guardian, INITIALIZER: factory,
        HARD_DEPOSIT_CAP: config(roles).hardDepositCap, USDC_ADAPTER: c.usdcAdapter, SECONDARY_ADAPTER: c.secondaryAdapter,
        ORACLE: c.oracle, LENS: c.lens, PRICING: c.pricing, PROGRAM_FACTORY: c.programFactory }, blockNumber),
      checkContract(c.oracle, 'CashPlusOracle', { USDC_FEED: OFFICIAL.usdcFeed, SECONDARY_FEED: OFFICIAL.secondaryFeed,
        SEQUENCER_FEED: OFFICIAL.sequencerFeed, USDC_FEED_SCALE: 10n ** BigInt(18 - decimals[0]!), SECONDARY_FEED_SCALE: 10n ** BigInt(18 - decimals[1]!),
        SECONDARY_SCALE: 10n ** BigInt(decimals[2]!), SECONDARY_DECIMALS: decimals[2]!, USDC_MAX_AGE: 90000, SECONDARY_MAX_AGE: 90000,
        MAX_FEED_SKEW: 90000, SEQUENCER_GRACE: 3600, PEG_DEVIATION_BPS: 50 }, blockNumber),
      checkContract(c.usdcAdapter, 'CashPlusAaveAdapter', { VAULT: vault, UNDERLYING: OFFICIAL.usdc, POOL: OFFICIAL.pool, A_TOKEN: OFFICIAL.usdcAToken }, blockNumber),
      checkContract(c.secondaryAdapter, 'CashPlusAaveAdapter', { VAULT: vault, UNDERLYING: OFFICIAL.secondary, POOL: OFFICIAL.pool, A_TOKEN: OFFICIAL.secondaryAToken }, blockNumber),
      checkContract(c.pricing, 'CashPlusPricing', { VAULT: vault, ROUTER: OFFICIAL.router }, blockNumber),
      checkContract(c.programFactory, 'CashPlusProgramFactory', { VAULT: vault, PRICING: c.pricing }, blockNumber),
      checkContract(c.lens, 'CashPlusLens', { VAULT: vault }, blockNumber),
    ]);
    const storage: Record<string, unknown> = {};
    await Promise.all(['initialized', 'totalShares', 'policyVersion', 'policy', 'depositsPaused', 'tradingPaused', 'emergencyMode', 'settlementState'].map(async key => {
      storage[key] = await get(vault, 'CashPlusVault', key, blockNumber);
    }));
    const [seedShares, sponsorShares, vaultBalance, leftApproval] = await Promise.all([
      get(vault, 'CashPlusVault', 'sharesOf', blockNumber, [SEED_HOLDER]), get(vault, 'CashPlusVault', 'sharesOf', blockNumber, [DEPLOYER]),
      balance(OFFICIAL.usdc, vault, blockNumber), allowance(factory, blockNumber),
    ]);
    requireThat(storage.initialized === true && seedShares === SEED * 10n ** 12n &&
      BigInt(String(storage.totalShares)) >= seedShares && leftApproval === 0n,
    'Vault initialization, locked seed shares or consumed approval differs from the expected deployment.');
    // Receipt block reads include later transactions in the same block. Events establish the atomic seed;
    // later deposits, donations or operator actions are disclosed instead of falsely failing runtime identity.
    const bootstrapStateMatches = storage.totalShares === seedShares && sponsorShares === 0n && vaultBalance === SEED &&
      String(storage.policyVersion) === '1' && String(storage.settlementState) === '0' &&
      storage.depositsPaused === false && storage.tradingPaused === false && storage.emergencyMode === false &&
      json((storage.policy as readonly unknown[]).map(String)) === json(Object.values(POLICY).map(String));
    const makerApprovals = await Promise.all([OFFICIAL.usdc, OFFICIAL.secondary].map(token =>
      client.readContract({ address: token, abi: erc20Abi, functionName: 'allowance', args: [vault, OFFICIAL.aqua], blockNumber })));
    requireThat(makerApprovals.every(value => value === 0n), 'Vault has an unexpected standing token approval to Aqua.');
    await get(c.oracle, 'CashPlusOracle', 'prices', blockNumber);
    return { contracts: reports, children: c, storage, seedShares, sponsorShares, vaultBalance, remainingApproval: leftApproval,
      makerApprovals, bootstrapStateMatches, stateNote: bootstrapStateMatches ? 'Receipt block matches the expected bootstrap state.' :
        'Deployment events and runtime are verified, but block-end storage differs from bootstrap. Inspect same-block activity before operating or enabling live deposits.' };
  }
  async function verify(review: Review, hash: Hex) {
    assertReview(review);
    requireThat(await client.getChainId() === CHAIN_ID, 'RPC network changed.');
    const [tx, receipt] = await Promise.all([client.getTransaction({ hash }), client.getTransactionReceipt({ hash })]);
    assertReceiptBinding(review, tx, receipt);
    const canonical = await client.getBlock({ blockNumber: receipt.blockNumber });
    requireThat(canonical.hash === receipt.blockHash, 'Receipt is not in the canonical Arbitrum chain.');
    let verification: unknown = null;
    if (receipt.status === 'success') {
      if (review.stage === 'factory') verification = await checkFactory(review.expectedAddress, receipt.blockNumber);
      else if (review.stage === 'approval') {
        await checkFactory(review.factory!, receipt.blockNumber);
        requireThat(await allowance(review.factory!, receipt.blockNumber) === SEED, 'USDC allowance after approval is not exactly 1,000 USDC.');
        verification = { allowance: SEED, spender: review.factory, token: OFFICIAL.usdc };
      } else {
        await checkFactory(review.factory!, receipt.blockNumber);
        const events = receipt.logs.filter(log => eq(log.address, review.factory)).flatMap(log => {
          try { return [decodeEventLog({ abi: artifacts.CashPlusDeploymentFactory.abi, data: log.data, topics: log.topics })]; } catch { return []; }
        }).filter(event => event.eventName === 'VaultDeployed');
        requireThat(events.length === 1, 'Receipt must contain exactly one VaultDeployed event from the verified factory.');
        const event = events[0]!.args as unknown as { vault: Address; sponsor: Address; initCodeHash: Hex; seed: bigint };
        requireThat(eq(event.vault, review.expectedAddress) && eq(event.sponsor, DEPLOYER) && event.initCodeHash === initCodeHash && event.seed === SEED,
          'VaultDeployed event differs from the reviewed CREATE2 deployment and seed.');
        const seeded = receipt.logs.filter(log => eq(log.address, review.expectedAddress)).flatMap(log => {
          try { return [decodeEventLog({ abi: artifacts.CashPlusVault.abi, data: log.data, topics: log.topics })]; } catch { return []; }
        }).filter(event => event.eventName === 'Seeded');
        requireThat(seeded.length === 1, 'Expected one Seeded event from the predicted vault.');
        const seed = seeded[0]!.args as unknown as { sponsor: Address; assets: bigint; shares: bigint };
        requireThat(eq(seed.sponsor, DEPLOYER) && seed.assets === SEED && seed.shares === SEED * 10n ** 12n, 'Seeded event differs from the locked seed.');
        verification = await checkVault(review.expectedAddress, review.factory!, receipt.blockNumber);
      }
    }
    return { transaction: tx, receipt, verification, verifiedAt: new Date().toISOString(), gasCostWei: receipt.gasUsed * receipt.effectiveGasPrice };
  }
  return { client, buildHash, initCode, initCodeHash, vaultArgs, preflight, prepare, revalidate, verify, checkFactory, checkVault, assertReview };
}
export type VaultVerification = Awaited<ReturnType<ReturnType<typeof createService>['checkVault']>>;
