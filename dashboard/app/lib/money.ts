// Money as the dashboard shows it, and the figures it is measured against. The token counts cents; these
// mirror services/src/books.ts and the minimums in docs/plan.md open question 9.

// One Hong Kong dollar, in the token's cents.
export const HKD = 100n
// The settlement account on the opening balance sheet in docs/scenarios.md.
export const OPENING_SETTLEMENT = 1_000_000n * HKD
// The capital and liquidity ratios' minimums, in per cent.
export const MIN_CAPITAL = 8
export const MIN_LIQUIDITY = 25

// Cents as Hong Kong dollars, such as HK$2,000, HK$12.50 or −HK$93,000.
export function hkd(cents: string | bigint | undefined): string {
  if (cents === undefined) return ''
  const value = BigInt(cents)
  const negative = value < 0n
  const abs = negative ? -value : value
  const rest = abs % HKD
  return `${negative ? '−' : ''}HK$${(abs / HKD).toLocaleString('en-HK')}${rest === 0n ? '' : `.${rest.toString().padStart(2, '0')}`}`
}
