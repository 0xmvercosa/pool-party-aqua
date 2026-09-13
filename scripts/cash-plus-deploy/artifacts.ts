import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { keccak256, toHex, type Abi, type Hex } from 'viem';
import { requireThat } from './config.ts';

export const CONTRACTS = ['CashPlusDeploymentFactory', 'CashPlusVault', 'CashPlusOracle',
  'CashPlusAaveAdapter', 'CashPlusPricing', 'CashPlusProgramFactory', 'CashPlusLens'] as const;
export type ContractName = typeof CONTRACTS[number];
export type Artifact = {
  abi: Abi;
  bytecode: { object: Hex; linkReferences: Record<string, unknown> };
  deployedBytecode: { object: Hex; immutableReferences: Record<string, { start: number; length: number }[]>; linkReferences: Record<string, unknown> };
  metadata: { compiler: { version: string }; settings: { optimizer: { enabled: boolean; runs: number }; evmVersion: string; viaIR?: boolean } };
  ast: unknown;
};
export type Artifacts = Record<ContractName, Artifact>;
export function buildArtifacts(): Artifacts {
  execFileSync(process.env.FORGE_BIN || 'forge', ['build', '--root', 'contracts', '--ast', '--sizes'], {
    env: { ...process.env, FOUNDRY_PROFILE: 'cashplus' }, stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 8_000_000,
  });
  return Object.fromEntries(CONTRACTS.map(name => {
    const a = JSON.parse(readFileSync(`contracts/out/${name}.sol/${name}.json`, 'utf8')) as Artifact;
    a.deployedBytecode.immutableReferences ??= {};
    const m = a.metadata;
    requireThat(m.compiler.version === '0.8.28+commit.7893614a' && m.settings.optimizer.enabled &&
      m.settings.optimizer.runs === 200 && m.settings.viaIR === true && m.settings.evmVersion === 'cancun',
    'Unexpected compiler settings. Cash+ requires solc 0.8.28, viaIR, optimizer 200, Cancun.');
    requireThat(a.ast && /^0x[0-9a-f]+$/i.test(a.bytecode.object) &&
      Object.keys(a.bytecode.linkReferences).length === 0 && Object.keys(a.deployedBytecode.linkReferences).length === 0,
    'Artifact is missing AST or contains unresolved libraries.');
    requireThat((a.deployedBytecode.object.length - 2) / 2 <= 24576, `${name} exceeds EIP-170.`);
    return [name, a];
  })) as Artifacts;
}

/** Replace every compiler immutable slot with independently derived values, never wildcard bytes. */
export function expectedRuntime(a: Artifact, values: Record<string, string | bigint | number>): Hex {
  const declarations = new Map<string, string>();
  const visit = (node: unknown) => {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) { for (const child of node) visit(child); return; }
    const n = node as Record<string, unknown>;
    if (n.nodeType === 'VariableDeclaration' && n.mutability === 'immutable' && typeof n.name === 'string')
      declarations.set(String(n.id), n.name);
    for (const value of Object.values(n)) visit(value);
  };
  visit(a.ast);
  let code = a.deployedBytecode.object.slice(2);
  const used = new Set<string>();
  const occupied = new Set<number>();
  for (const [id, slots] of Object.entries(a.deployedBytecode.immutableReferences)) {
    const name = declarations.get(id);
    requireThat(name && Object.hasOwn(values, name), `Missing independently expected immutable: ${name || id}.`);
    const value = values[name];
    requireThat(value !== undefined, `Missing immutable ${name}.`);
    const encoded = toHex(BigInt(value), { size: 32 }).slice(2);
    used.add(name);
    for (const slot of slots) {
      requireThat(slot.length === 32 && Number.isInteger(slot.start) && slot.start >= 0 &&
        (slot.start + slot.length) * 2 <= code.length, 'Invalid immutable reference range.');
      for (let i = slot.start; i < slot.start + slot.length; i++) {
        requireThat(!occupied.has(i), 'Overlapping immutable references.'); occupied.add(i);
      }
      code = code.slice(0, slot.start * 2) + encoded + code.slice((slot.start + slot.length) * 2);
    }
  }
  requireThat(Object.keys(values).every(name => used.has(name)), 'Expected immutable was not found in the compiled runtime.');
  return `0x${code}`;
}
export function assertRuntime(actual: Hex | undefined, a: Artifact, values: Record<string, string | bigint | number>): Hex {
  const expected = expectedRuntime(a, values);
  requireThat(actual && actual.toLowerCase() === expected.toLowerCase(), 'Onchain runtime or immutable configuration differs from the reviewed build.');
  return keccak256(actual);
}
