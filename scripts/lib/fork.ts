/**
 * Anvil fork helpers: funding, impersonation, and the ERC-20 surface the rehearsal needs.
 * Nothing here ever runs against mainnet; every function asserts the local fork endpoint.
 */
import { http, createTestClient, createWalletClient, erc20Abi, parseEther, publicActions } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { AAVE_A_USDC, TOKENS } from "./addresses.ts";
import { anvilArbitrumFork } from "./clients.ts";
import { forkRpcUrl } from "./env.ts";

/** Anvil's deterministic dev accounts. Public test keys, never used off a local fork. */
export const MAKER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;
export const TAKER_KEY = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d" as const;

export const makerAccount = privateKeyToAccount(MAKER_KEY);
export const takerAccount = privateKeyToAccount(TAKER_KEY);

export function testClient() {
  return createTestClient({
    chain: anvilArbitrumFork,
    mode: "anvil",
    transport: http(forkRpcUrl()),
  }).extend(publicActions);
}

export function walletFor(account: typeof makerAccount) {
  return createWalletClient({
    account,
    chain: anvilArbitrumFork,
    transport: http(forkRpcUrl()),
  }).extend(publicActions);
}

export const WETH_ABI = [
  ...erc20Abi,
  { type: "function", name: "deposit", inputs: [], outputs: [], stateMutability: "payable" },
] as const;

/** Candidate USDC holders on Arbitrum, tried in order until one has enough. */
const USDC_SOURCES = [
  AAVE_A_USDC,
  "0x47c031236e19d024b42f8AE6780E44A573170703", // GMX V2 market
  "0x1eED63EfBA1b62540fCb8E1a4172F4544f5D8b21", // Camelot / misc treasury
] as const;

/** Give an account ETH, then WETH by depositing, then USDC from an impersonated holder. */
export async function fund(
  address: `0x${string}`,
  opts: { eth?: bigint; weth?: bigint; usdc?: bigint },
): Promise<void> {
  const test = testClient();
  await test.setBalance({ address, value: opts.eth ?? parseEther("100") });

  if (opts.weth && opts.weth > 0n) {
    // Mint WETH the honest way so no storage slot has to be guessed.
    const account = address === makerAccount.address ? makerAccount : takerAccount;
    const wallet = walletFor(account);
    const hash = await wallet.writeContract({
      address: TOKENS.WETH,
      abi: WETH_ABI,
      functionName: "deposit",
      value: opts.weth,
    });
    await test.waitForTransactionReceipt({ hash });
  }

  if (opts.usdc && opts.usdc > 0n) {
    await transferFromWhale(TOKENS.USDC, address, opts.usdc);
  }
}

/** Move tokens out of a live holder by impersonating it on the fork. */
export async function transferFromWhale(
  token: `0x${string}`,
  to: `0x${string}`,
  amount: bigint,
): Promise<void> {
  const test = testClient();

  for (const source of USDC_SOURCES) {
    const balance = await test.readContract({
      address: token,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [source],
    });
    if (balance < amount) continue;

    await test.impersonateAccount({ address: source });
    await test.setBalance({ address: source, value: parseEther("1") });
    const wallet = createWalletClient({
      account: source,
      chain: anvilArbitrumFork,
      transport: http(forkRpcUrl()),
    });
    const hash = await wallet.writeContract({
      address: token,
      abi: erc20Abi,
      functionName: "transfer",
      args: [to, amount],
    });
    await test.waitForTransactionReceipt({ hash });
    await test.stopImpersonatingAccount({ address: source });
    return;
  }
  throw new Error(`No configured holder of ${token} has ${amount}; add one to USDC_SOURCES`);
}
