import { describe, expect, it } from 'vitest';
import { encodeFunctionData, decodeFunctionData, erc20Abi, zeroAddress, type Hex } from 'viem';
import { assertRuntime, expectedRuntime, type Artifact } from './artifacts.ts';
import { assertReceiptBinding, children, nextStage, predictVault, type Review, type Progress } from './service.ts';
import { advance, canPrepare, cancelUnsigned, recordHash, requirePending, type State } from './state.ts';
import { rolesFromEnv, liveRpcUrl, DEPLOYER, OFFICIAL, SEED, DeploymentError, safeError } from './config.ts';

const salt = `0x${'11'.repeat(32)}` as Hex;
const blockHash = `0x${'22'.repeat(32)}` as Hex;
const hash = `0x${'33'.repeat(32)}` as Hex;
const factory = '0x1111111111111111111111111111111111111111';
const vault = '0x2222222222222222222222222222222222222222';
const review = (stage: Review['stage'] = 'factory'): Review => ({ stage, owner: DEPLOYER, chainId: 42161,
  nonce: 7, to: stage === 'factory' ? null : stage === 'approval' ? OFFICIAL.usdc : factory,
  expectedAddress: stage === 'factory' || stage === 'approval' ? factory : vault,
  data: stage === 'approval' ? encodeFunctionData({ abi: erc20Abi, functionName: 'approve', args: [factory, SEED] }) : '0x0102',
  value: '0x0', gas: '0x9999', gasEstimate: '30000', gasPriceWei: '1000000', estimatedFeeWei: '30000000000',
  balanceWei: '1000000000000000000', usdcBalance: String(SEED), blockNumber: '100', blockHash, expiresAt: Date.now() + 180000,
  buildHash: hash, factory: stage === 'factory' ? null : factory, salt, initCodeHash: hash,
  roles: { governance: DEPLOYER, keeper: DEPLOYER, guardian: DEPLOYER } });
const state = (): State => ({ version: 1, owner: DEPLOYER, buildHash: hash, salt, factory: null, approved: false, vault: null,
  pending: { reviewId: 'one', review: review(), signingStarted: false, hash: null }, operations: [] });
function receiptData(r: Review): { tx: Parameters<typeof assertReceiptBinding>[1]; receipt: Parameters<typeof assertReceiptBinding>[2] } {
  return { tx: { from: DEPLOYER, to: r.to, input: r.data, value: 0n, nonce: r.nonce, chainId: 42161, blockHash },
    receipt: { status: 'success' as const, contractAddress: r.stage === 'factory' ? factory : null, blockHash } };
}

describe('Cash+ reviewed transactions', () => {
  it.each(['factory', 'approval', 'vault'] as const)('accepts the exact %s transaction', stage => {
    const r = review(stage), { tx, receipt } = receiptData(r); expect(() => assertReceiptBinding(r, tx, receipt)).not.toThrow();
  });
  it('approves exactly the permanent 1,000 USDC seed', () => {
    const decoded = decodeFunctionData({ abi: erc20Abi, data: review('approval').data });
    expect(decoded.functionName).toBe('approve'); expect(decoded.args).toEqual([factory, 1_000_000_000n]);
  });
  it.each(['from', 'to', 'input', 'value', 'nonce', 'chainId', 'blockHash'] as const)('rejects an altered %s', field => {
    const r = review('vault'), { tx, receipt } = receiptData(r);
    const changes = { from: zeroAddress, to: zeroAddress, input: '0xffff', value: 1n, nonce: 8, chainId: 1, blockHash: salt };
    expect(() => assertReceiptBinding(r, { ...tx, [field]: changes[field] }, receipt)).toThrow('does not match');
  });
  it('requires an outer CREATE address only for the factory', () => {
    const r = review(), { tx, receipt } = receiptData(r);
    expect(() => assertReceiptBinding(r, tx, { ...receipt, contractAddress: null })).toThrow('CREATE/CREATE2');
    const v = review('vault'), data = receiptData(v);
    expect(() => assertReceiptBinding(v, data.tx, { ...data.receipt, contractAddress: vault })).toThrow('CREATE/CREATE2');
  });
  it('binds reverted receipts too, without claiming a deployment', () => {
    const r = review(), { tx, receipt } = receiptData(r);
    expect(() => assertReceiptBinding(r, tx, { ...receipt, status: 'reverted', contractAddress: null })).not.toThrow();
    expect(() => assertReceiptBinding(r, { ...tx, nonce: 8 }, { ...receipt, status: 'reverted' })).toThrow();
  });
  it('binds CREATE2 to sponsor, salt, factory and initcode', () => {
    const address = predictVault(factory, DEPLOYER, salt, hash);
    expect(predictVault(factory, DEPLOYER, salt, hash)).toBe(address);
    for (const candidate of [predictVault(factory, zeroAddress, salt, hash), predictVault(factory, DEPLOYER, hash, hash),
      predictVault(vault, DEPLOYER, salt, hash), predictVault(factory, DEPLOYER, salt, blockHash)]) expect(candidate).not.toBe(address);
    expect(new Set(Object.values(children(address))).size).toBe(6);
  });
});
describe('Cash+ durable workflow', () => {
  it('requires factory, exact seed approval, then atomic vault deployment', () => {
    const s = state(); s.pending = null; expect(nextStage(s)).toBe('factory');
    advance(s, review()); expect(nextStage(s)).toBe('approval');
    advance(s, review('approval')); expect(nextStage(s)).toBe('vault');
    advance(s, review('vault')); expect(nextStage(s)).toBeNull(); expect(() => canPrepare(s)).toThrow('already verified');
  });
  it('rejects out-of-order receipt advancement', () => { expect(() => advance(state(), review('vault'))).toThrow('out of sequence'); });
  it('cancels only unsigned reviews', () => { const s = state(); cancelUnsigned(s, 'one'); expect(s.pending).toBeNull(); expect(s.operations).toHaveLength(1); });
  it('blocks uncertain sends and double submission across restarts', () => {
    const s = state(); s.pending!.signingStarted = true;
    const restored = JSON.parse(JSON.stringify(s)) as State;
    expect(() => cancelUnsigned(restored, 'one')).toThrow('uncertain'); expect(() => canPrepare(restored)).toThrow('Resolve');
    recordHash(restored, 'one', hash); expect(restored.pending!.hash).toBe(hash);
    expect(() => recordHash(restored, 'one', salt)).toThrow('different hash');
  });
  it('rejects stale tabs and hashes before signing starts', () => {
    expect(() => requirePending(state(), 'other')).toThrow('another tab'); expect(() => recordHash(state(), 'one', hash)).toThrow('No matching');
  });
});
describe('Cash+ runtime checks have no masked bytes', () => {
  const artifact = { abi: [], bytecode: { object: '0x00', linkReferences: {} },
    metadata: { compiler: { version: 'test' }, settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: 'cancun' } },
    deployedBytecode: { object: `0x60${'00'.repeat(32)}00`, linkReferences: {}, immutableReferences: { '42': [{ start: 1, length: 32 }] } },
    ast: { nodes: [{ id: 42, name: 'VAULT', nodeType: 'VariableDeclaration', mutability: 'immutable' }] } } as Artifact;
  it('fills expected immutable slots and checks every byte', () => {
    const expected = expectedRuntime(artifact, { VAULT: factory });
    expect(() => assertRuntime(expected, artifact, { VAULT: factory })).not.toThrow();
    expect(() => assertRuntime(expected, artifact, { VAULT: vault })).toThrow('runtime or immutable');
    expect(() => assertRuntime(`0x61${expected.slice(4)}`, artifact, { VAULT: factory })).toThrow('runtime or immutable');
  });
  it('rejects missing, extra, overlapping or out-of-range slots', () => {
    expect(() => expectedRuntime(artifact, {})).toThrow('Missing');
    expect(() => expectedRuntime(artifact, { VAULT: factory, ROUTER: factory })).toThrow('not found');
    const clone = structuredClone(artifact); clone.deployedBytecode.immutableReferences['42']!.push({ start: 1, length: 32 });
    expect(() => expectedRuntime(clone, { VAULT: factory })).toThrow('Overlapping');
    clone.deployedBytecode.immutableReferences['42'] = [{ start: 20, length: 32 }];
    expect(() => expectedRuntime(clone, { VAULT: factory })).toThrow('range');
  });
});
describe('Cash+ environment and error boundary', () => {
  const basicAuthRpc = new URL('https://rpc.example');
  basicAuthRpc.username = 'user'; basicAuthRpc.password = 'pass';
  it('requires all immutable role addresses explicitly', () => {
    expect(() => rolesFromEnv({})).toThrow('CASH_PLUS_GOVERNANCE');
    expect(() => rolesFromEnv({ CASH_PLUS_GOVERNANCE: zeroAddress })).toThrow();
    const roles = rolesFromEnv({ CASH_PLUS_GOVERNANCE: DEPLOYER, CASH_PLUS_KEEPER: DEPLOYER, CASH_PLUS_GUARDIAN: DEPLOYER });
    expect(roles).toEqual({ governance: DEPLOYER, keeper: DEPLOYER, guardian: DEPLOYER });
  });
  it.each(['http://127.0.0.1:8545', basicAuthRpc.toString(), 'https://rpc.example/#key', 'not-url'])('rejects live RPC %s', value => {
    expect(() => liveRpcUrl(value)).toThrow();
  });
  it('never exposes raw provider errors or RPC credentials', () => {
    expect(safeError(new Error('request failed https://rpc.example/secret-key'))).not.toContain('secret');
    expect(safeError(new DeploymentError('Known failure.'))).toBe('Known failure.');
  });
});
