// The custodian, simulated only as far as milestone 3 needs it: an outside party holding the bank's liquid
// securities, which issues a holdings statement (semt.002) each day and settles the bank's sales, each signed
// with its own key, which the bank's partner key register holds. A sale settles delivery against payment:
// the bills leave its books and the clearing system credits the bank's settlement account together, and the
// custodian confirms the settlement (sese.025), which the partner adapter relays. Its books follow what it
// settled, as the clearing system's do. Its statements follow on from the last one the bank accepted. The
// lending guard needs the figure current to lend. The custodian simulator with the stablecoin reserve
// follows at milestone 4. See docs/architecture.md#services and open question 27 in docs/plan.md.

import { keccak256, toBytes, type Hex } from 'viem'
import { partnerKey, type Bank } from './bank.ts'
import { Ledger, Opening } from './books.ts'
import { relayStatement, type Clearing } from './clearing.ts'
import type { Outcome } from './submission.ts'

export interface SettlementConfirmation {
  message: {
    tradeRef: Hex
    amount: bigint
    settledAt: bigint
    documentHash: Hex
  }
  signature: Hex
}

const confirmationFields = [
  { name: 'tradeRef', type: 'bytes32' },
  { name: 'amount', type: 'uint256' },
  { name: 'settledAt', type: 'uint256' },
  { name: 'documentHash', type: 'bytes32' },
] as const

export class Custodian {
  private readonly bank: Bank
  private readonly clearing: Clearing
  private readonly book: { time: bigint; holding: bigint }[]
  private confirmations = 0n

  private constructor(bank: Bank, clearing: Clearing, openedAt: bigint) {
    this.bank = bank
    this.clearing = clearing
    this.book = [{ time: openedAt, holding: Opening.securities }]
  }

  static async open(bank: Bank, clearing: Clearing): Promise<Custodian> {
    return new Custodian(bank, clearing, await bank.now())
  }

  holding(at?: bigint): bigint {
    let holding = this.book[0]!.holding
    for (const e of this.book) if (at === undefined || e.time <= at) holding = e.holding
    return holding
  }

  // Settles a sale the bank instructed and approved, delivery against payment, and confirms it.
  async settle(tradeRef: Hex, amount: bigint): Promise<SettlementConfirmation> {
    if (amount > this.holding()) throw new Error(`The custodian holds ${this.holding()}, less than the ${amount} sold`)
    const settledAt = await this.clearing.settleDelivery(amount)
    this.book.push({ time: settledAt, holding: this.holding() - amount })
    const message = { tradeRef, amount, settledAt, documentHash: keccak256(toBytes(`sese.025 ${++this.confirmations}`)) }
    const signature = this.bank.signer.signAsPartner(partnerKey.custodian, {
      domain: { name: 'SecuritiesSales', version: '1', chainId: this.bank.chain.chainId, verifyingContract: this.bank.contracts.sales },
      types: { SettlementConfirmation: confirmationFields },
      primaryType: 'SettlementConfirmation',
      message,
    } as never)
    return { message, signature }
  }

  // The partner adapter relays a settlement confirmation, which books the sale.
  relay(confirmation: SettlementConfirmation): Promise<Outcome> {
    return this.bank.relay(
      'partner adapter',
      'partner',
      'relay the custodian’s settlement confirmation',
      this.bank.call('SecuritiesSales', this.bank.contracts.sales, 'settle', [confirmation.message, confirmation.signature]),
    )
  }

  // The day's holdings statement as of `asOf`, which finance relays to be compared with the ledger's
  // securities at that time.
  async statement(asOf: bigint): Promise<Outcome> {
    const figure = await this.bank.read('Attestations', this.bank.contracts.attestations, 'figure', [Ledger.Securities])
    const partner = { key: partnerKey.custodian, account: Ledger.Securities, kind: 'semt.002', by: 'the custodian' }
    return relayStatement(this.bank, partner, figure.sequence + 1n, this.holding(asOf), asOf)
  }
}
