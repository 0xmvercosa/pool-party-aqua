import { buildArtifacts } from './cash-plus-deploy/artifacts.ts';
import { createService } from './cash-plus-deploy/service.ts';
import { DEPLOYER, json, safeError } from './cash-plus-deploy/config.ts';

try {
  const artifacts = buildArtifacts();
  // This command only compiles and encodes; it neither requires roles nor contacts an RPC.
  const service = createService(artifacts, { governance: DEPLOYER, keeper: DEPLOYER, guardian: DEPLOYER }, 'https://arb1.arbitrum.io/rpc');
  console.log(json({ status: 'PASS', mode: 'offline-build-check', compiler: artifacts.CashPlusVault.metadata.compiler,
    settings: artifacts.CashPlusVault.metadata.settings,
    vaultRuntimeBytes: (artifacts.CashPlusVault.deployedBytecode.object.length - 2) / 2,
    vaultInitcodeBytes: (service.initCode.length - 2) / 2, initCodeHashWithExampleRoles: service.initCodeHash,
    note: 'Example role addresses are only used to measure initcode. Live roles require explicit environment configuration.' }));
} catch (error) { console.error(safeError(error)); process.exitCode = 1; }
