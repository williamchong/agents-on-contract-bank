// The guided tour: the five-minute pitch as a preset, one beat at a time, each making one claim and putting
// it on screen. Milestone 2 reaches the first four beats. See docs/scenarios.md#guided-tour.

import { isAddressEqual, zeroAddress, type Address } from 'viem'
import { HKD } from './books.ts'
import { cashDeposit, eventArg, emitted } from './operations.ts'
import { presets, type Check, type Context } from './scenarios.ts'

export interface Beat {
  number: number
  title: string
  // What the presenter points at, and the claim the beat makes.
  pointAt: string
  claim: string
  run(ctx: Context): Promise<Check[]>
}

function preset(name: string) {
  const found = presets.find((p) => p.name === name)
  if (!found) throw new Error(`No preset called ${name}`)
  return found
}

export const beats: Beat[] = [
  {
    number: 1,
    title: 'An ordinary day',
    pointAt:
      'The story view and the waiting strip: cash in, an ATM withdrawal, a paper slip waiting for the supervisor; on the bank map, money moving between the houses, the branch and the ATM',
    claim: 'It reads like a bank, in plain sentences',
    run: (ctx) => preset('Counter and ATM day').run(ctx),
  },
  {
    number: 2,
    title: 'Books that cannot disagree',
    pointAt: 'One cash deposit opened under the hood: the ledger entry it posted, the two balance sheet rows it moved, and the invariant strip',
    claim: 'The token and the ledger entry are one transaction',
    async run(ctx) {
      const deposit = await cashDeposit(ctx.bank, 'Bob', 500n * HKD)
      // One receipt holds both: the tokens created for Bob and the ledger entry posted against cash.
      const together = emitted(deposit, 'Transfer') && emitted(deposit, 'EntryPosted')
      const poster = together ? eventArg<Address>(deposit, 'EntryPosted', 'poster') : zeroAddress
      return [
        { name: 'one cash deposit at the counter', pass: deposit.ok },
        { name: 'the tokens are created and the entry posted in the same transaction', pass: together },
        { name: 'the entry is posted by the cash module', pass: isAddressEqual(poster, ctx.bank.contracts.cash) },
      ]
    },
  },
  {
    number: 3,
    title: 'Try to break it',
    pointAt: 'One refusal after another, each with its reason, and a barrier dropping on the bank map for each',
    claim: "The chain decides; an agent's instructions are not the control",
    run: (ctx) => preset('Red team').run(ctx),
  },
  {
    number: 4,
    title: 'Fraud, with a way back',
    pointAt: 'The scenario card, the transfer waiting for an approver, the freeze, the reversal waiting for compliance, then the pass',
    claim: 'No member of staff acts alone, and a wrong is reversed on the record',
    run: (ctx) => preset('Forged paper slip').run(ctx),
  },
]
