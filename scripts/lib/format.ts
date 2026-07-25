/** Tiny terminal helpers. No dependency, no colour codes in files we commit as evidence. */

export function heading(text: string): void {
  console.log(`\n=== ${text} ===`);
}

export function pass(text: string): void {
  console.log(`  [PASS] ${text}`);
}

export function fail(text: string): void {
  console.log(`  [FAIL] ${text}`);
}

export function info(text: string): void {
  console.log(`  ${text}`);
}

export function formatUnits(value: bigint, decimals: number, precision = 6): string {
  const negative = value < 0n;
  const abs = negative ? -value : value;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  const frac = (abs % base).toString().padStart(decimals, "0").slice(0, precision).replace(/0+$/, "");
  return `${negative ? "-" : ""}${whole}${frac ? `.${frac}` : ""}`;
}
