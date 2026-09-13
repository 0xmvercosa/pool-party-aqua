import type { Hex } from 'viem';
import { DEPLOYER, requireThat } from './config.ts';
import { nextStage, type Progress, type Review } from './service.ts';

export type Pending = { reviewId: string; review: Review; signingStarted: boolean; hash: Hex | null };
export type State = Progress & {
  version: 1; owner: typeof DEPLOYER; buildHash: Hex; pending: Pending | null; operations: unknown[];
};
export function canPrepare(state: State) {
  requireThat(!state.pending, 'Resolve the saved operation before preparing another transaction.');
  requireThat(nextStage(state), 'All three steps are already verified.');
}
export function requirePending(state: State, reviewId: unknown): Pending {
  requireThat(state.pending && state.pending.reviewId === reviewId,
    'Review changed in another tab. Reload and inspect the current operation.');
  return state.pending;
}
export function cancelUnsigned(state: State, reviewId: unknown) {
  const p = requirePending(state, reviewId);
  requireThat(!p.signingStarted && !p.hash,
    'Signing may already have started. Recover the hash from Rabby Activity; an uncertain transaction cannot be cleared.');
  state.operations.push({ status: 'unsigned-review-cancelled', review: p.review, recordedAt: new Date().toISOString() });
  state.pending = null;
}
export function recordHash(state: State, reviewId: unknown, hash: Hex) {
  const p = requirePending(state, reviewId);
  requireThat(p.signingStarted, 'No matching signing request was started.');
  requireThat(!p.hash || p.hash === hash, 'A different hash is already saved. Verify a replacement hash through receipt recovery.');
  p.hash = hash;
}
export function advance(state: State, review: Review) {
  requireThat(nextStage(state) === review.stage, 'Verified receipt is out of sequence.');
  if (review.stage === 'factory') state.factory = review.expectedAddress;
  if (review.stage === 'approval') state.approved = true;
  if (review.stage === 'vault') state.vault = review.expectedAddress;
}
