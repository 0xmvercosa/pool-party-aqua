/**
 * Thin helpers over @1inch/swap-vm-sdk. Every program in this repo is produced by
 * AquaProgramBuilder; nothing here hand-writes an opcode byte.
 */
import { AquaProgramBuilder, HexString, Order, instructions } from "@1inch/swap-vm-sdk";

/**
 * The Aqua instruction set as the SDK mirrors it. Array index IS the on-chain opcode byte
 * (the deployed gen-2 router uses pre-OpcodeList array dispatch), so this doubles as the
 * opcode table we assert the deployed router against.
 */
export const AQUA_INSTRUCTION_SET = instructions.aquaInstructions;

/** Human-readable opcode table: index -> symbol description, empty slots included. */
export function aquaOpcodeTable(): Array<{ index: number; hex: string; name: string }> {
  return AQUA_INSTRUCTION_SET.map((opcode, index) => ({
    index,
    hex: `0x${index.toString(16).padStart(2, "0")}`,
    name: describeOpcode(opcode),
  }));
}

function describeOpcode(opcode: { id: symbol } | undefined): string {
  if (!opcode) return EMPTY_SLOT;
  const described = opcode.id.description;
  if (!described || described.toLowerCase() === "empty") return EMPTY_SLOT;
  return described;
}

/** Label used for slots the deployed array reserves but does not implement. */
export const EMPTY_SLOT = "EMPTY";

/** True when the Aqua instruction set exposes an opcode whose name matches the predicate. */
export function aquaOpcodeIndexByName(name: string): number {
  return AQUA_INSTRUCTION_SET.findIndex((opcode) => opcode?.id.description === name);
}

/** Decode a program's bytes into the instruction list the builder would have produced. */
export function decodeProgram(programHex: string) {
  return AquaProgramBuilder.decode(new HexString(programHex) as never);
}

/** Render a decoded program as one line per instruction, for evidence in docs. */
export function renderInstructions(builder: AquaProgramBuilder): string[] {
  return builder.getInstructions().map((ix, position) => {
    const index = AQUA_INSTRUCTION_SET.findIndex((o) => o?.id === ix.opcode.id);
    const hex = `0x${index.toString(16).padStart(2, "0")}`;
    const args = JSON.stringify(ix.args.toJSON());
    return `#${position} ${hex} ${describeOpcode(ix.opcode)} ${args}`;
  });
}

/** Ship bytes are the ABI-encoded Order struct, not the bare program (PRG-R9). */
export function decodeShipBytes(shipBytes: string): Order {
  return Order.decode(new HexString(shipBytes));
}
