// The custodian, simulated only as far as milestone 3 needs it: an outside party holding the bank's liquid
// securities, which issues a holdings statement (semt.002) each day, signed with its own key, which the
// bank's partner key register holds. Until the bank sells securities nothing moves them, so its books are
// the opening holding, and its statements follow on from the last one the bank accepted. The lending guard
// needs the figure current to lend. The custodian simulator with the stablecoin reserve follows at
// milestone 4. See docs/architecture.md#services.

import { partnerKey, type Bank } from './bank.ts'
import { Ledger, Opening } from './books.ts'
import { relayStatement } from './clearing.ts'
import type { Outcome } from './submission.ts'

// The day's holdings statement as of `asOf`, which finance relays to be compared with the ledger's
// securities at that time.
export async function custodianStatement(bank: Bank, asOf: bigint): Promise<Outcome> {
  const figure = await bank.read('Attestations', bank.contracts.attestations, 'figure', [Ledger.Securities])
  const partner = { key: partnerKey.custodian, account: Ledger.Securities, kind: 'semt.002', by: 'the custodian' }
  return relayStatement(bank, partner, figure.sequence + 1n, Opening.securities, asOf)
}
