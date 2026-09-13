import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { describe, expect, it, vi } from 'vitest';
import { DEPLOYER, config, POLICY, json } from './config.ts';

class Element {
  textContent = ''; className = ''; value = ''; checked = false; disabled = false; hidden = false;
  children: unknown[] = []; events = new Map<string, () => Promise<void>>();
  classList = { toggle: () => {} };
  append(...children: unknown[]) { this.children.push(...children); }
  replaceChildren() { this.children = []; }
  querySelector() { return new Element(); }
  addEventListener(name: string, callback: () => Promise<void>) { this.events.set(name, callback); }
}
type Options = { account?: string; chain?: string; changedReview?: boolean; sendError?: number; storageError?: boolean; changeAccountAfterBegin?: boolean };
async function browser(options: Options = {}) {
  const elements = new Map<string, Element>();
  const element = (id: string) => { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id)!; };
  const roles = { governance: DEPLOYER, keeper: DEPLOYER, guardian: DEPLOYER };
  const hash = `0x${'33'.repeat(32)}`;
  const r = { stage: 'approval', owner: DEPLOYER, chainId: 42161, nonce: 9, to: config(roles).usdc,
    expectedAddress: '0x1111111111111111111111111111111111111111', data: '0x095ea7b3', gas: '0x10000',
    estimatedFeeWei: '1000000', expiresAt: Date.now() + 180000 };
  const pending = { reviewId: 'review-one', review: r, signingStarted: false, hash: null as string | null };
  const state = { owner: DEPLOYER, factory: r.expectedAddress, approved: false, vault: null, pending: pending as typeof pending | null, operations: [] };
  const snap = () => JSON.parse(json({ state, token: 'local-token', balances: null, roles, config: config(roles), policy: POLICY, nextStage: 'approval' }));
  const storage = new Map<string, string>();
  let began = false, hashWasStoredBeforeReport = false;
  const calls: { method: string; params?: unknown[] }[] = [];
  const provider = { isRabby: true, on: () => {}, request: vi.fn(async (request: { method: string; params?: unknown[] }) => {
    calls.push(request);
    if (request.method === 'eth_accounts' || request.method === 'eth_requestAccounts') return [options.changeAccountAfterBegin && began ? '0x0000000000000000000000000000000000000001' : options.account || DEPLOYER];
    if (request.method === 'eth_chainId') return options.chain || '0xa4b1';
    if (request.method === 'eth_sendTransaction') {
      if (options.sendError) throw { code: options.sendError };
      return hash;
    }
    return null;
  }) };
  const fetch = vi.fn(async (url: string, request?: { body: string }) => {
    const path = url.split('/').at(-1);
    if (path === 'state') return { ok: true, json: async () => snap() };
    const input = JSON.parse(request?.body || '{}');
    if (path === 'begin') {
      began = true; pending.signingStarted = true;
      return { ok: true, json: async () => ({ reviewId: pending.reviewId, review: { ...r, ...(options.changedReview ? { nonce: 10 } : {}) } }) };
    }
    if (path === 'submitted') { hashWasStoredBeforeReport = storage.get('pool-party.cash-plus.deployment.review-one') === hash; pending.hash = input.hash; }
    if (path === 'rejected') state.pending = null;
    return { ok: true, json: async () => ({}) };
  });
  runInNewContext(readFileSync('scripts/cash-plus-deploy/app.js', 'utf8'), {
    document: { getElementById: element, createElement: () => new Element() },
    window: { addEventListener: () => {}, dispatchEvent: () => {}, ethereum: provider },
    Event: class {}, structuredClone, fetch, setInterval: () => 1, clearInterval: () => {},
    localStorage: { getItem: (key: string) => storage.get(key), setItem: (key: string, value: string) => {
      if (options.storageError) throw new Error('Quota'); storage.set(key, value);
    }, removeItem: (key: string) => storage.delete(key) },
  });
  await new Promise<void>(resolve => setImmediate(resolve));
  const click = async (id: string) => { await element(id).events.get('click')?.(); };
  await click('connect'); element('seed-ack').checked = true; element('roles-ack').checked = true;
  return { click, calls, state, fetch, element, wasStored: () => hashWasStoredBeforeReport, began: () => began, r, hash };
}
describe('Rabby browser signature boundary', () => {
  it('signs the displayed transaction exactly and saves the returned hash before reporting it', async () => {
    const b = await browser(); await b.click('sign');
    expect(b.calls.filter(c => c.method === 'eth_sendTransaction')).toEqual([{ method: 'eth_sendTransaction', params: [{
      from: DEPLOYER, chainId: '0xa4b1', nonce: '0x9', data: b.r.data, value: '0x0', gas: b.r.gas, to: b.r.to,
    }] }]);
    expect(b.wasStored()).toBe(true); expect(b.state.pending?.hash).toBe(b.hash);
  });
  it.each([{ account: '0x0000000000000000000000000000000000000001' }, { chain: '0x1' }, { storageError: true }])('stops before begin for invalid wallet/network/storage %j', async options => {
    const b = await browser(options); await b.click('sign'); expect(b.began()).toBe(false);
    expect(b.calls.some(c => c.method === 'eth_sendTransaction')).toBe(false);
  });
  it.each([{ changedReview: true }, { changeAccountAfterBegin: true }])('never signs changed review/account after revalidation %j', async options => {
    const b = await browser(options); await b.click('sign'); expect(b.began()).toBe(true);
    expect(b.calls.some(c => c.method === 'eth_sendTransaction')).toBe(false); expect(b.state.pending?.signingStarted).toBe(true);
  });
  it('only releases a started request for an explicit 4001 wallet rejection', async () => {
    const b = await browser({ sendError: 4001 }); await b.click('sign'); expect(b.state.pending).toBeNull();
    expect(b.fetch.mock.calls.some(c => c[0] === '/api/rejected')).toBe(true);
  });
  it('keeps unknown wallet errors blocked without a resend', async () => {
    const b = await browser({ sendError: 4900 }); await b.click('sign');
    expect(b.state.pending?.signingStarted).toBe(true); expect(b.fetch.mock.calls.some(c => c[0] === '/api/rejected')).toBe(false);
    expect(b.calls.filter(c => c.method === 'eth_sendTransaction')).toHaveLength(1);
  });
});
