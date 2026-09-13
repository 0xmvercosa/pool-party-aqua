import { getAddress, isAddress, zeroAddress, type Address } from 'viem';

export const DEPLOYER = getAddress('0x67Fd51e5082205AF0bD97039a6124Ff3368aD0da');
export const CHAIN_ID = 42161;
export const ORIGIN = 'http://127.0.0.1:3211';
export const OUTPUT = '.runtime/cash-plus-deployment';
export const SEED = 1_000_000_000n;
export const SEED_HOLDER = '0x0000000000000000000000000000000000000001' as Address;
export const OFFICIAL = {
  usdc: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831',
  secondary: '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9',
  aqua: '0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a',
  router: '0x111111338c5091E8440b67B168bAe16a668AC0De',
  pool: '0x794a61358D6845594F94dc1DB02A252b5b4814aD',
  usdcAToken: '0x724dc807b04555b71ed48a6896b6F41593b8C637',
  secondaryAToken: '0x6ab707Aca953eDAeFBc4fD23bA73294241490620',
  usdcFeed: '0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3',
  secondaryFeed: '0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7',
  sequencerFeed: '0xFdB631F5EE196F0ed6FAa767959853A9F217697D',
} as const satisfies Record<string, Address>;
export const PROTOCOL_HASHES = {
  [OFFICIAL.aqua]: '0x720bc02d220db318164dc3bade86eec1f3655bdc00fc1174de7d816a95c341f8',
  [OFFICIAL.router]: '0x7cb8785de84b35bced79fbecbbc6336f473623568cba28b7af3ed001b20d580e',
} as const;
export type Roles = { governance: Address; keeper: Address; guardian: Address };
export function requireThat(ok: unknown, message: string): asserts ok {
  if (!ok) throw new DeploymentError(message);
}
export class DeploymentError extends Error {}
export function safeError(error: unknown): string {
  return error instanceof DeploymentError ? error.message :
    'RPC or local operation failed. No transaction is resent. Check connectivity, balances and Rabby Activity; retain any transaction hash.';
}
export const json = (value: unknown) => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2);
export function rolesFromEnv(env: NodeJS.ProcessEnv = process.env): Roles {
  const role = (key: string): Address => {
    const value = env[key]?.trim();
    requireThat(value && isAddress(value) && value.toLowerCase() !== zeroAddress,
      `Set ${key} to an explicit nonzero public address. Roles are immutable; review them before deployment.`);
    return getAddress(value);
  };
  return { governance: role('CASH_PLUS_GOVERNANCE'), keeper: role('CASH_PLUS_KEEPER'), guardian: role('CASH_PLUS_GUARDIAN') };
}
export function liveRpcUrl(input = process.env.CASH_PLUS_RPC_URL): string {
  const value = input?.trim() || 'https://arb1.arbitrum.io/rpc';
  let url: URL;
  try { url = new URL(value); } catch { throw new DeploymentError('CASH_PLUS_RPC_URL must be an HTTPS Arbitrum RPC URL.'); }
  requireThat(url.protocol === 'https:' && !url.username && !url.password && !url.hash,
    'The live deployment assistant requires an HTTPS RPC URL without basic authentication or a fragment.');
  return value;
}
export const config = (roles: Roles) => ({ ...OFFICIAL,
  usdcMaxAge: 90000, secondaryMaxAge: 90000, maxFeedSkew: 90000, sequencerGrace: 3600,
  pegDeviationBps: 50, ...roles, hardDepositCap: 1_000_000_000_000n,
});
export const POLICY = {
  depositCap: 1_000_000_000_000n, minDeposit: 1_000_000n, maxFillBps: 100, dailyBudgetBps: 2000,
  secondaryTargetBps: 1000, secondaryCapBps: 2000, baseSpreadBps: 5, maxSurchargeBps: 10,
  hotUsdcBps: 500, hotSecondaryBps: 0,
} as const;
