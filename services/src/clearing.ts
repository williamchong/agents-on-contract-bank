// The clearing system, simulated: an outside party with its own books of the bank's settlement account. It
// credits the bank for payments from other banks' customers, takes payments the bank sends, rejects some,
// and issues a statement of the account each day. It signs every message with its own key, which the
// bank's partner key register holds; the partner adapter relays them and holds no role. Its books follow
// what it actually settled, so they differ from the bank's only when something really happened that the
// bank did not book, which is what the ledger mismatch scenario injects. See docs/architecture.md#services.

import { keccak256, padHex, sliceHex, stringToHex, toBytes, zeroAddress, type Address, type Hex } from 'viem'
import { abiOf } from './artifacts.ts'
import { partnerKey, type Bank } from './bank.ts'
import { Ledger, Opening } from './books.ts'
import type { Outcome } from './submission.ts'

interface Entry {
  time: bigint
  balance: bigint
}

export interface CreditAdvice {
  message: {
    endToEndId: Hex
    amount: bigint
    currency: Hex
    creditorAccount: Hex
    settledAt: bigint
    documentHash: Hex
  }
  signature: Hex
}

// The most blocks Base Sepolia's public endpoint returns logs for in one request.
const LOG_WINDOW = 200n

export class Clearing {
  private readonly bank: Bank
  // The bank's settlement account as the clearing system books it, in time order.
  private readonly book: Entry[]
  private messages = 0n
  private sequence = 0n
  private syncedTo: bigint

  private constructor(bank: Bank, openedAt: bigint, block: bigint) {
    this.bank = bank
    this.book = [{ time: openedAt, balance: Opening.settlement }]
    this.syncedTo = block
  }

  static async open(bank: Bank): Promise<Clearing> {
    const block = await bank.chain.client.getBlock()
    return new Clearing(bank, block.timestamp, block.number)
  }

  balance(at?: bigint): bigint {
    let balance = this.book[0]!.balance
    for (const e of this.book) if (at === undefined || e.time <= at) balance = e.balance
    return balance
  }

  // Books a movement now, after taking in what the bank sent before it, so the book stays in time order.
  private async move(amount: bigint): Promise<bigint> {
    await this.sync()
    const time = await this.bank.now()
    this.book.push({ time, balance: this.balance() + amount })
    return time
  }

  // Takes the payments the bank sent since it last looked, as the clearing system settles them.
  async sync(): Promise<void> {
    const client = this.bank.chain.client
    // Read fresh rather than through the client's cached block number, which can trail the chain.
    const { number: toBlock } = await client.getBlock()
    // A public endpoint answers for a limited range of blocks at a time, and a time lock waited out there
    // spans hundreds, so the range is read a window at a time.
    while (this.syncedTo < toBlock) {
      const fromBlock = this.syncedTo + 1n
      const windowEnd = fromBlock + LOG_WINDOW - 1n < toBlock ? fromBlock + LOG_WINDOW - 1n : toBlock
      const logs = await client.getContractEvents({
        address: this.bank.contracts.payments,
        abi: abiOf('Payments'),
        eventName: 'PaymentSent',
        fromBlock,
        toBlock: windowEnd,
      })
      for (const log of logs) {
        const { timestamp } = await client.getBlock({ blockNumber: log.blockNumber })
        this.book.push({ time: timestamp, balance: this.balance() - log.args.amount! })
      }
      this.syncedTo = windowEnd
    }
  }

  // A payment from another bank's customer: the clearing system credits the bank and sends the advice.
  // `creditor` is the account the payer named, which may be no account of the bank's. A forger's advice,
  // signed by another key, moves nothing in the clearing system's books.
  async creditAdvice(creditor: Address | Hex, amount: bigint, options: { currency?: string; signedBy?: string } = {}): Promise<CreditAdvice> {
    const genuine = options.signedBy === undefined
    const settledAt = genuine ? await this.move(amount) : await this.bank.now()
    const message = {
      endToEndId: keccak256(toBytes(`clearing advice ${++this.messages}`)),
      amount,
      currency: stringToHex(options.currency ?? 'HKD', { size: 3 }),
      creditorAccount: padHex(creditor, { size: 32 }),
      settledAt,
      documentHash: keccak256(toBytes(`camt.054 ${this.messages}`)),
    }
    const signature = this.signPayments(options.signedBy ?? partnerKey.clearing, {
      types: { CreditAdvice: creditAdviceFields },
      primaryType: 'CreditAdvice',
      message,
    })
    return { message, signature }
  }

  relayCredit(advice: CreditAdvice, action: string): Promise<Outcome> {
    return this.bank.relay(
      'partner adapter',
      'partner',
      action,
      this.bank.call('Payments', this.bank.contracts.payments, 'receiveCredit', [advice.message, advice.signature]),
      // The creditor is an address padded to 32 bytes, or a hash where the payer named no account of the bank's.
      { from: zeroAddress, to: sliceHex(advice.message.creditorAccount, 12), amount: advice.message.amount },
    )
  }

  // Money leaving the settlement account that the bank did not send through the payments queue: a payment
  // the bank returned to its sender, which the bank books too, or a fee the clearing system charged, which
  // it does not.
  async debit(amount: bigint): Promise<void> {
    await this.move(-amount)
  }

  // Gives back a fee charged in error, once the bank's reconciliation has raised it.
  async refund(amount: bigint): Promise<void> {
    await this.move(amount)
  }

  // The receiving bank refused a payment the bank sent: the amount comes back, with a signed rejection.
  async reject(ref: Hex, amount: bigint, reason = 'AC04'): Promise<Outcome> {
    const message = {
      originalEndToEndId: ref,
      amount,
      reasonCode: stringToHex(reason, { size: 4 }),
      documentHash: keccak256(toBytes(`pacs.004 ${ref}`)),
    }
    const signature = this.signPayments(partnerKey.clearing, {
      types: { PaymentRejection: rejectionFields },
      primaryType: 'PaymentRejection',
      message,
    })
    const outcome = await this.bank.relay(
      'partner adapter',
      'partner',
      `relay the rejection of payment ${ref.slice(0, 10)}`,
      this.bank.call('Payments', this.bank.contracts.payments, 'rejectPayment', [message, signature]),
    )
    // The money comes back once, however often the rejection is relayed.
    if (outcome.ok) await this.move(amount)
    return outcome
  }

  // The day's statement of the settlement account as of `asOf`, which finance relays to be compared
  // with the ledger's balance at that time.
  async statement(asOf: bigint): Promise<Outcome> {
    await this.sync()
    const message = {
      statementId: keccak256(toBytes(`camt.053 ${++this.sequence}`)),
      sequence: this.sequence,
      closingBalance: this.balance(asOf),
      asOf,
      documentHash: keccak256(toBytes(`camt.053 document ${this.sequence}`)),
    }
    const c = this.bank.contracts
    const signature = this.bank.signer.signAsPartner(partnerKey.clearing, {
      domain: { name: 'Attestations', version: '1', chainId: this.bank.chain.chainId, verifyingContract: c.attestations },
      types: { Statement: statementFields },
      primaryType: 'Statement',
      message,
    })
    return this.bank.relay(
      'finance',
      'head office',
      `reconcile the clearing system's statement ${message.sequence}`,
      this.bank.call('Attestations', c.attestations, 'acceptStatement', [Ledger.Settlement, message, signature]),
    )
  }

  private signPayments(key: string, definition: { types: Record<string, readonly { name: string; type: string }[]>; primaryType: string; message: object }): Hex {
    const domain = { name: 'Payments', version: '1', chainId: this.bank.chain.chainId, verifyingContract: this.bank.contracts.payments }
    return this.bank.signer.signAsPartner(key, { domain, ...definition } as never)
  }
}

const creditAdviceFields = [
  { name: 'endToEndId', type: 'bytes32' },
  { name: 'amount', type: 'uint256' },
  { name: 'currency', type: 'bytes3' },
  { name: 'creditorAccount', type: 'bytes32' },
  { name: 'settledAt', type: 'uint256' },
  { name: 'documentHash', type: 'bytes32' },
] as const

const rejectionFields = [
  { name: 'originalEndToEndId', type: 'bytes32' },
  { name: 'amount', type: 'uint256' },
  { name: 'reasonCode', type: 'bytes4' },
  { name: 'documentHash', type: 'bytes32' },
] as const

const statementFields = [
  { name: 'statementId', type: 'bytes32' },
  { name: 'sequence', type: 'uint256' },
  { name: 'closingBalance', type: 'uint256' },
  { name: 'asOf', type: 'uint256' },
  { name: 'documentHash', type: 'bytes32' },
] as const
