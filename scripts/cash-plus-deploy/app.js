/* Browser is the only signer and broadcaster. No wallet RPC is proxied by the server. */
const $ = id => document.getElementById(id);
const walletAddress = '0x67fd51e5082205af0bd97039a6124ff3368ad0da';
const chainHex = '0xa4b1';
let provider;
let snapshot;
let busy = false;
const discovered = [];
window.addEventListener('eip6963:announceProvider', event => {
  if (event.detail?.info?.rdns === 'io.rabby' || event.detail?.provider?.isRabby) discovered.push(event.detail.provider);
});
window.dispatchEvent(new Event('eip6963:requestProvider'));
const stages = { factory: 'Deploy factory', approval: 'Approve exactly 1,000 USDC', vault: 'Deploy & seed Cash+' };
function message(text, kind = '') { $('message').textContent = text; $('message').className = kind; }
function units(raw, decimals, places = 5) {
  const amount = BigInt(raw), base = 10n ** BigInt(decimals);
  return `${(amount / base).toLocaleString('en-US')}.${(amount % base).toString().padStart(decimals, '0').slice(0, places)}`;
}
function row(target, key, value, code = false) {
  const div = document.createElement('div'), dt = document.createElement('dt'), dd = document.createElement('dd');
  dt.textContent = key;
  if (code) { const node = document.createElement('code'); node.textContent = value; dd.append(node); } else dd.textContent = value;
  div.append(dt, dd); target.append(div);
}
const storageKey = id => `pool-party.cash-plus.deployment.${id}`;
async function api(path, data) {
  const response = await fetch(`/api/${path}`, data === undefined ? {} : {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Cash-Plus-Session': snapshot.token }, body: JSON.stringify(data),
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || 'Local operation failed.');
  return result;
}
function controls() {
  const p = snapshot?.state.pending;
  for (const id of ['connect', 'prepare', 'refresh', 'verify', 'cancel']) $(id).disabled = busy;
  $('sign').disabled = busy || !provider || !$('seed-ack').checked || !$('roles-ack').checked || !p || p.signingStarted || Date.now() >= p.review.expiresAt;
}
function render() {
  const s = snapshot.state, p = s.pending;
  $('owner').textContent = s.owner;
  $('eth').textContent = snapshot.balances ? `${units(snapshot.balances.eth, 18)} ETH` : 'Unavailable';
  $('usdc').textContent = snapshot.balances ? `${units(snapshot.balances.usdc, 6, 2)} USDC` : 'Unavailable';
  for (const stage of Object.keys(stages)) {
    const done = stage === 'approval' ? s.approved : !!s[stage];
    const element = $(`step-${stage}`);
    element.classList.toggle('done', done); element.classList.toggle('active', !done && snapshot.nextStage === stage);
    element.querySelector('.status').textContent = done ? 'Verified onchain' : p?.review.stage === stage ? p.signingStarted ? 'Awaiting receipt / recovery' : 'Ready for review' : 'Not started';
  }
  $('roles').replaceChildren();
  for (const [key, value] of Object.entries(snapshot.roles)) row($('roles'), key[0].toUpperCase() + key.slice(1), value, true);
  $('configuration').textContent = JSON.stringify({ config: snapshot.config, policy: snapshot.policy }, null, 2);
  $('prepare').hidden = !!p || !!s.vault;
  $('sign').hidden = !p || p.signingStarted;
  $('cancel').hidden = !p || p.signingStarted;
  $('recovery').hidden = !p?.signingStarted;
  $('review-content').hidden = !p;
  $('review-title').textContent = p ? stages[p.review.stage] : s.vault ? 'Cash+ deployment verified.' : 'Ready when you are.';
  $('review-help').textContent = p ? p.signingStarted ? 'A signing request was started. Verify its receipt or recover its hash before continuing.' :
    'Simulation passed. Check the address, exact data and permanent seed before opening Rabby.' : s.vault ?
    'Save the report and publish the source on Arbiscan. This does not activate the frontend or an operator.' :
    'Prepare the next step to validate protocol addresses, simulate the exact transaction and estimate gas. Preparation does not send a transaction.';
  if (p) {
    const r = p.review;
    $('review-fields').replaceChildren();
    row($('review-fields'), 'Transaction', stages[r.stage]);
    row($('review-fields'), 'Network', 'Arbitrum One · 42161');
    row($('review-fields'), 'To', r.to || 'New contract (CREATE)', true);
    row($('review-fields'), r.stage === 'approval' ? 'Spender' : 'Expected address', r.expectedAddress, true);
    row($('review-fields'), 'Wallet nonce', String(r.nonce));
    row($('review-fields'), 'Native value', '0 ETH');
    row($('review-fields'), 'Estimated gas fee incl. buffer', `${units(r.estimatedFeeWei, 18, 8)} ETH`);
    row($('review-fields'), 'Review expires', new Date(r.expiresAt).toLocaleTimeString());
    if (r.stage !== 'factory') row($('review-fields'), r.stage === 'approval' ? 'USDC approval' : 'Permanent sponsor seed', '1,000 USDC');
    $('review-json').textContent = JSON.stringify({ review: r, config: snapshot.config, policy: snapshot.policy }, null, 2);
    let saved;
    try { saved = localStorage.getItem(storageKey(p.reviewId)); } catch { /* Server hash still available. */ }
    if (!$('hash').value) $('hash').value = p.hash || saved || '';
  } else $('hash').value = '';
  $('record').replaceChildren();
  const operations = s.operations.filter(op => op.receipt);
  $('manifest').hidden = !operations.some(op => op.review.stage === 'vault' && op.receipt.status === 'success' && op.verification?.bootstrapStateMatches);
  if (!operations.length) $('record').textContent = 'No verified transactions yet.';
  for (const op of operations) {
    const entry = document.createElement('div'); entry.className = 'entry';
    const strong = document.createElement('strong'); strong.textContent = `${stages[op.review.stage]} · ${op.receipt.status}`;
    const a = document.createElement('a'); a.href = `https://arbiscan.io/tx/${op.hash}`; a.target = '_blank'; a.rel = 'noopener noreferrer'; a.textContent = op.hash;
    entry.append(strong, document.createElement('br'), a);
    if (op.review.stage === 'vault' && op.receipt.status === 'success') {
      const address = document.createElement('p'); address.textContent = `Vault: ${op.review.expectedAddress}`; entry.append(address);
      const note = document.createElement('p'); note.textContent = op.verification.stateNote; entry.append(note);
    }
    $('record').append(entry);
  }
  controls();
}
async function refresh() { snapshot = await api('state'); render(); }
async function walletIdentity() {
  if (!provider) throw new Error('Connect Rabby first.');
  const [accounts, chain] = await Promise.all([provider.request({ method: 'eth_accounts' }), provider.request({ method: 'eth_chainId' })]);
  if (accounts[0]?.toLowerCase() !== walletAddress) throw new Error('Select the configured deployment wallet in Rabby.');
  if (BigInt(chain) !== 42161n) throw new Error('Select Arbitrum One in Rabby.');
  $('wallet-status').textContent = 'Rabby connected · Arbitrum One';
}
async function run(label, action) {
  if (busy) return;
  busy = true; controls(); message(label);
  const started = Date.now();
  const timer = setInterval(() => message(`${label} ${Math.floor((Date.now() - started) / 1000)}s`), 1000);
  try { await action(); } catch (error) { message(error?.message || 'Operation failed. Inspect Rabby Activity before trying again.', 'error'); }
  finally { clearInterval(timer); busy = false; controls(); }
}
$('connect').addEventListener('click', () => run('Connecting Rabby…', async () => {
  provider = discovered[0] || window.ethereum?.providers?.find(p => p.isRabby) || (window.ethereum?.isRabby ? window.ethereum : undefined);
  if (!provider) throw new Error('Rabby was not found. Open this page in Chrome or Brave with Rabby installed.');
  await provider.request({ method: 'eth_requestAccounts' });
  await provider.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: chainHex }] });
  await walletIdentity();
  provider.on?.('accountsChanged', () => { $('wallet-status').textContent = 'Wallet changed — verify before signing'; });
  provider.on?.('chainChanged', () => { $('wallet-status').textContent = 'Network changed — verify before signing'; });
  message('Connected. No transaction has been sent.', 'success');
}));
$('refresh').addEventListener('click', () => run('Refreshing state…', async () => { await refresh(); message('Local deployment state refreshed.'); }));
$('prepare').addEventListener('click', () => run('Checking contracts and simulating…', async () => {
  await api('prepare', {}); $('seed-ack').checked = false; $('roles-ack').checked = false; await refresh(); message('Simulation passed. Review the exact transaction before signing.', 'success');
}));
$('cancel').addEventListener('click', () => run('Cancelling unsigned review…', async () => { await api('cancel', { reviewId: snapshot.state.pending.reviewId }); await refresh(); message('Unsigned review cancelled. No transaction was sent.'); }));
$('sign').addEventListener('click', () => run('Revalidating and waiting for Rabby…', async () => {
  await walletIdentity();
  const displayed = structuredClone(snapshot.state.pending);
  const id = displayed.reviewId;
  // Test recovery storage before starting an irreversible wallet interaction.
  const probe = `${storageKey(id)}.probe`;
  try { localStorage.setItem(probe, 'ready'); localStorage.removeItem(probe); }
  catch { throw new Error('Browser recovery storage is unavailable. Enable local storage before opening Rabby. No signing request was started.'); }
  const begun = await api('begin', { reviewId: id, seedAcknowledged: $('seed-ack').checked, rolesAcknowledged: $('roles-ack').checked });
  if (begun.reviewId !== id || JSON.stringify(begun.review) !== JSON.stringify(displayed.review)) {
    await refresh();
    throw new Error('The server review differs from the transaction displayed. No wallet request was sent. Preserve the journal for investigation.');
  }
  const r = begun.review;
  let hash;
  try {
    await walletIdentity(); // Fresh after server simulation and immediately before wallet broadcast.
    const tx = { from: r.owner, chainId: chainHex, nonce: `0x${r.nonce.toString(16)}`, data: r.data, value: '0x0', gas: r.gas };
    if (r.to) tx.to = r.to;
    hash = await provider.request({ method: 'eth_sendTransaction', params: [tx] });
  } catch (error) {
    if (Number(error?.code) === 4001) {
      await api('rejected', { reviewId: id, code: 4001 }); await refresh(); message('Rabby explicitly rejected the transaction. No retry was sent.'); return;
    }
    await refresh();
    throw new Error('The signing result is uncertain. Check Rabby Activity and recover the hash. This step remains blocked to prevent a duplicate.');
  }
  $('hash').value = hash;
  try { localStorage.setItem(storageKey(id), hash); } catch { /* Immediately persist to server below. */ }
  try { await api('submitted', { reviewId: id, hash }); }
  catch { await refresh(); throw new Error(`Transaction submitted. Save this hash and use receipt recovery: ${hash}`); }
  await refresh(); message(`Transaction hash saved: ${hash}. Wait for confirmation, then verify the receipt.`, 'success');
}));
$('verify').addEventListener('click', () => run('Verifying canonical receipt, code and configuration…', async () => {
  const id = snapshot.state.pending.reviewId;
  const result = await api('verify', { reviewId: id, hash: $('hash').value.trim() });
  try { localStorage.removeItem(storageKey(id)); } catch { /* Journal is authoritative. */ }
  await refresh(); message(result.status === 'success' ? 'Receipt and onchain effects verified. The next step is ready.' :
    'The transaction reverted. Gas was spent; the deployment step did not complete. Review the reason before preparing again.', result.status === 'success' ? 'success' : 'error');
}));
for (const id of ['seed-ack', 'roles-ack']) $(id).addEventListener('change', controls);
setInterval(controls, 1000);
refresh().then(() => message('Local state loaded. Connect Rabby or prepare a review.')).catch(error => message(error.message, 'error'));
