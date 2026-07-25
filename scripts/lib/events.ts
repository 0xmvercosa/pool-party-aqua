/**
 * Event decoding goes through the SDK's own parsers so the field mapping is never ours to
 * get wrong. viem's Log.topics is a plain array; the SDK wants a non-empty tuple, so the
 * narrowing lives here once instead of at every call site.
 */
import { DockedEvent, PulledEvent, PushedEvent, ShippedEvent } from "@1inch/aqua-sdk";
import { SwappedEvent } from "@1inch/swap-vm-sdk";

type ViemLog = { topics: readonly `0x${string}`[]; data: `0x${string}` };
type LogLike = { topics: [] | [`0x${string}`, ...`0x${string}`[]]; data: `0x${string}` };

export function toLogLike(log: ViemLog): LogLike {
  const [signature, ...rest] = log.topics;
  return {
    topics: signature === undefined ? [] : [signature, ...rest],
    data: log.data,
  };
}

export function topicOf(log: ViemLog): `0x${string}` | undefined {
  return log.topics[0];
}

export const TOPICS = {
  shipped: ShippedEvent.TOPIC.toString(),
  docked: DockedEvent.TOPIC.toString(),
  pulled: PulledEvent.TOPIC.toString(),
  pushed: PushedEvent.TOPIC.toString(),
  swapped: SwappedEvent.TOPIC.toString(),
} as const;

export function parseShipped(log: ViemLog): ShippedEvent {
  return ShippedEvent.fromLog(toLogLike(log));
}

export function parsePulled(log: ViemLog): PulledEvent {
  return PulledEvent.fromLog(toLogLike(log));
}

export function parsePushed(log: ViemLog): PushedEvent {
  return PushedEvent.fromLog(toLogLike(log));
}

export function parseSwapped(log: ViemLog): SwappedEvent {
  return SwappedEvent.fromLog(toLogLike(log));
}
