// The presets: daily routines and adverse scenarios as scripted sequences, each scored against the pass
// criteria in docs/scenarios.md. A preset whose routine needs a contract still to come runs the part
// that exists and lists the rest in `waitsFor`, so the score never claims more than was run.

import { isAddressEqual, keccak256, numberToHex, toBytes, type Address, type Hex } from 'viem'
import { grantThroughBranch, Settings, Staff, type Bank } from './bank.ts'
import { DisputeStatus, drawer, HKD, Ledger, OperationStatus, Opening, PaymentStatus, vault } from './books.ts'
import { advance } from './chain.ts'
import type { Clearing } from './clearing.ts'
import {
  authorise,
  balanceOf,
  booksBalance,
  cashAt,
  cashDeposit,
  cashSplitMatchesLedger,
  compliance,
  countCash,
  customerTotal,
  decide,
  emitted,
  operationOf,
  eventArg,
  ledgerBalance,
  moveCash,
  openDispute,
  payOut,
  places,
  approveRecovery,
  approveReversal,
  proposeRecovery,
  proposeReversal,
  releasePayments,
  registerPayee,
  reportDispense,
  reportIncident,
  slipHash,
  submitAtmWithdrawal,
  supply,
  transfer,
  transferAtCounter,
  withdrawAtAtm,
} from './operations.ts'
import type { Outcome } from './submission.ts'

// What a teller's drawer keeps for the next customers; the custodian moves cash above it to the vault.
const DRAWER_FLOAT = 10_000n * HKD

export interface Check {
  name: string
  pass: boolean
  detail?: string
}

export interface Context {
  bank: Bank
  clearing: Clearing
}

// The groups adverse scenarios are listed in; see docs/scenarios.md#adverse-scenarios.
export const ScenarioGroups = ['Customer mishap', 'Fraud and attack', 'Operational incident', 'Financial stress'] as const
export type ScenarioGroup = (typeof ScenarioGroups)[number]

// The dashboard panel an adverse scenario concerns, which the adverse view brings forward.
export type Panel = 'story' | 'waiting' | 'balance sheet'

export interface Preset {
  name: string
  kind: 'routine' | 'adverse'
  // For an adverse scenario, its group, what happens in plain words, the control that should fire, and the
  // building on the bank map and the panel it concerns.
  group?: ScenarioGroup
  summary?: string
  control?: string
  building?: string
  panel?: Panel
  waitsFor?: string[]
  run(ctx: Context): Promise<Check[]>
}

function check(name: string, pass: boolean, detail?: string): Check {
  return detail === undefined ? { name, pass } : { name, pass, detail }
}

function refusedWith(name: string, outcome: Outcome, error: string): Check {
  return outcome.ok ? check(name, false, 'it went through') : check(name, outcome.error === error, `refused: ${outcome.error}`)
}

function allowed(name: string, outcome: Outcome): Check {
  return outcome.ok ? check(name, true) : check(name, false, `refused: ${outcome.error}`)
}

// The reference an event carries, or none if the request was refused.
function refOf(outcome: Outcome, event: string): Hex | undefined {
  return emitted(outcome, event) ? eventArg<Hex>(outcome, event, 'ref') : undefined
}

// What every run must leave true: the books balance and the cash split sums to the ledger's cash.
async function invariants(bank: Bank): Promise<Check[]> {
  return [check('the books balance', await booksBalance(bank)), check('the cash split sums to the ledger', await cashSplitMatchesLedger(bank))]
}

// Closes the business day as the scenario clock does: the clearing system issues its statement of the
// day, and finance relays it to be compared with the ledger.
export async function closeDay(ctx: Context): Promise<Outcome> {
  const { bank, clearing } = ctx
  const asOf = await bank.now()
  // A statement must be dated before the block that accepts it.
  await advance(bank.chain, 60n)
  await operator(bank, 'close the business day')
  return clearing.statement(asOf)
}

// An operator command, marked apart from the bank's own events.
export async function operator(bank: Bank, action: string): Promise<void> {
  const block = await bank.chain.client.getBlock()
  bank.timeline.add({ time: block.timestamp, block: block.number, kind: 'operator', actor: 'operator', channel: 'control panel', action, events: [] })
}

// Whether a statement or count matched the ledger, or undefined if it was refused.
function matched(outcome: Outcome, event: 'StatementAccepted' | 'CashCounted'): boolean | undefined {
  return emitted(outcome, event) ? eventArg<boolean>(outcome, event, 'matched') : undefined
}

export const presets: Preset[] = [
  // Daily routines

  {
    name: 'Counter and ATM day',
    kind: 'routine',
    async run(ctx) {
      const { bank } = ctx
      const { drawer, atm } = places(bank)
      const cashBefore = await ledgerBalance(bank, Ledger.Cash)
      const deposit = await cashDeposit(bank, 'Alice', 2_000n * HKD)
      const bob = await balanceOf(bank, 'Bob')
      const atmCash = await cashAt(bank, atm)
      const held = await withdrawAtAtm(bank, 'Bob', 1_000n * HKD)
      const ref = refOf(held, 'WithdrawalHeld')
      // The amount has left Bob's account, and the machine's cash has not moved: it waits for the dispense.
      const waited = ref !== undefined && (await balanceOf(bank, 'Bob')) === bob - 1_000n * HKD && (await cashAt(bank, atm)) === atmCash
      const dispensed = ref ? await reportDispense(bank, ref, true) : held
      const app = await transfer(bank, 'Carol', 'Dave', 500n * HKD)
      // On a paper slip even a small transfer waits for the supervisor.
      const slip = await transferAtCounter(bank, 'Bob', 'Alice', 1_200n * HKD, { slip: "Bob's signed slip, 1,200 to Alice" })
      const slipRef = refOf(slip, 'OperationOpened')
      const slipWaited = slipRef !== undefined && (await bank.read('AssistedOperations', bank.contracts.assisted, 'nextApproverRole', [slipRef])) === Staff.supervisor
      const slipApproved = slipRef ? await decide(bank, 'supervisor', 'assisted', slipRef, 'approve') : slip
      // A larger transfer by card climbs the approval ladder to the supervisor too. Bob pays Carol, and Carol
      // pays him back on a day he is short, so the routine runs day after day.
      const [payer, payee] = (await balanceOf(bank, 'Bob')) >= 60_000n * HKD ? (['Bob', 'Carol'] as const) : (['Carol', 'Bob'] as const)
      const card = await transferAtCounter(bank, payer, payee, 60_000n * HKD, { card: true })
      const cardRef = refOf(card, 'OperationOpened')
      const cardApproved = cardRef ? await decide(bank, 'supervisor', 'assisted', cardRef, 'approve') : card
      const inDrawer = await cashAt(bank, drawer)
      const surplus = inDrawer - DRAWER_FLOAT
      const toVault = surplus > 0n ? await moveCash(bank, drawer, vault(), surplus, 'move surplus drawer cash to the vault') : undefined
      // The custodian counts what is really in the drawer: what it held, less the move.
      const count = await countCash(bank, drawer, surplus > 0n ? DRAWER_FLOAT : inDrawer, "the teller's drawer")
      const close = await closeDay(ctx)
      return [
        allowed('cash paid in at the counter', deposit),
        check('the ATM withdrawal waits for the dispense', waited),
        allowed('cash withdrawn at the ATM', dispensed),
        allowed('a transfer from the app', app),
        check('the paper slip waits for the supervisor', slipWaited),
        check('and goes through once approved', emitted(slipApproved, 'OperationCarriedOut')),
        check('a larger card transfer climbs the ladder', emitted(cardApproved, 'OperationCarriedOut')),
        check('drawer cash above the float moved to the vault under dual control', toVault === undefined || toVault.ok),
        check("the teller's drawer counts as booked", matched(count, 'CashCounted') === true),
        check('cash moved with deposits on the ledger', (await ledgerBalance(bank, Ledger.Cash)) === cashBefore + 1_000n * HKD),
        check('the reconciliation line reports a match', matched(close, 'StatementAccepted') === true),
        ...(await invariants(bank)),
      ]
    },
  },

  {
    name: 'Payments day',
    kind: 'routine',
    async run(ctx) {
      const { bank, clearing } = ctx
      // Alice registers her supplier from her phone, and the payee waiting period passes; on a later day the
      // supplier is on her register already.
      const supplier = 'a supplier at another bank'
      const registered = await registerPayee(bank, 'Alice', supplier)
      if (emitted(registered, 'PayeeRegistered')) await advance(bank.chain, Settings.payeeWait)
      const settlementBefore = await ledgerBalance(bank, Ledger.Settlement)
      const paid = await payOut(bank, 'Alice', supplier, 3_000n * HKD)
      const released = await releasePayments(bank)
      const advice = await clearing.creditAdvice(bank.account('Bob'), 4_500n * HKD)
      const received = await clearing.relayCredit(advice, 'relay a payment for Bob from someone never registered')
      const close = await closeDay(ctx)
      return [
        allowed('Alice registers her supplier as a payee', registered),
        allowed('and pays them more than an unregistered payee could be paid', paid),
        check('the payment leaves through the clearing system', emitted(released, 'PaymentSent')),
        allowed('Bob is paid by someone at another bank', received),
        check(
          'the settlement account and deposits move together',
          (await ledgerBalance(bank, Ledger.Settlement)) === settlementBefore - 3_000n * HKD + 4_500n * HKD,
        ),
        check('the reconciliation line reports a match', matched(close, 'StatementAccepted') === true),
        ...(await invariants(bank)),
      ]
    },
  },

  {
    name: 'Staff and device changes',
    kind: 'routine',
    async run(ctx) {
      const { bank } = ctx
      const c = bank.contracts
      // The teller leaves: their drawer goes back to the vault, the branch manager revokes their role at once
      // and grants it to the one hired, who is issued a drawer of their own.
      const leaving = drawer(bank.account('teller'))
      const inDrawer = await cashAt(bank, leaving)
      const handedBack = inDrawer > 0n ? await moveCash(bank, leaving, vault(), inDrawer, "move the leaving teller's drawer to the vault") : undefined
      const revoked = await bank.act('branch manager', 'branch', 'revoke the leaving teller', [
        bank.call('StaffRoles', c.staffRoles, 'revoke', [bank.account('teller'), Staff.teller]),
      ])
      const afterLeaving = await cashDeposit(bank, 'Alice', 100n * HKD)
      const hired = await grantThroughBranch(bank, 'branch manager', bank.account('replacement teller'), Staff.teller, 'grant the teller hired the role')
      const issued = await moveCash(bank, vault(), drawer(bank.account('replacement teller')), Opening.drawer, "issue the new teller's drawer")
      const replacementServes = await cashDeposit(bank, 'Alice', 100n * HKD, 'replacement teller')
      // Whoever holds the role is the teller from now on, and the one who left is the next to be hired.
      bank.swap('teller', 'replacement teller')
      // Alice loses her phone: her card removes it and enrols her new one.
      const alice = bank.account('Alice')
      const balance = await balanceOf(bank, 'Alice')
      const lost = bank.party('Alice').keys[0]!
      const phone = bank.freshKey('Alice:phone')
      const replaced = await bank.act(
        'Alice',
        'app',
        'revoke the lost phone and enrol a new one',
        [
          bank.call('MultiSignerAccount', alice, 'removeSigners', [[bank.signer.signerBytes(lost)]]),
          bank.call('MultiSignerAccount', alice, 'addSigners', [[bank.signer.signerBytes(phone)]]),
        ],
        [bank.cardOf('Alice')],
      )
      if (replaced.ok) bank.setDevices('Alice', [phone])
      const pay = (keys: string[], action: string) =>
        bank.act('Alice', 'app', action, [bank.call('DepositToken', c.token, 'transfer', [bank.account('Bob'), 1n])], keys)
      const oldPhone = await pay([lost], 'pay from the lost phone')
      const newPhone = await pay([phone], 'pay from the new phone')
      return [
        check("the leaving teller's drawer goes back to the vault", handedBack === undefined || handedBack.ok),
        allowed("the leaving teller's role is revoked at once", revoked),
        refusedWith('the leaving teller can no longer take cash', afterLeaving, 'NotTeller'),
        allowed('the teller hired is granted the role', hired),
        allowed('and issued a drawer', issued),
        allowed('the teller hired takes cash', replacementServes),
        allowed("the customer's card swaps the lost phone for the new one", replaced),
        refusedWith('the lost phone can no longer sign', oldPhone, 'InvalidExecutionSignature'),
        allowed('the new phone signs', newPhone),
        check('the same account keeps its balance', (await balanceOf(bank, 'Alice')) === balance - 1n),
        ...(await invariants(bank)),
      ]
    },
  },

  // Adverse scenarios

  {
    name: 'All devices lost',
    kind: 'adverse',
    group: 'Customer mishap',
    building: 'branch',
    panel: 'waiting',
    summary: 'A customer loses every device and their card, and the bank gives them their account back without letting anyone else in.',
    control: "Recovery module: an account opening officer with a supervisor's approval, signer list only",
    async run(ctx) {
      const { bank } = ctx
      const account = bank.account('Dave')
      const balance = await balanceOf(bank, 'Dave')
      const total = await supply(bank)
      const isSigner = (key: string) => bank.read('MultiSignerAccount', account, 'isSigner', [bank.signer.signerBytes(key)])
      const phone = bank.party('Dave').keys[0]!
      const card = bank.cardOf('Dave')
      const newPhone = bank.freshKey('Dave:phone')
      const newCard = bank.freshKey('Dave:card')
      const proposed = await proposeRecovery(bank, 'Dave', [phone, card], [newPhone, newCard])
      const waited = proposed.ok && (await isSigner(phone)) && !(await isSigner(newPhone))
      const recovered = proposed.ok ? await approveRecovery(bank, proposed) : proposed
      if (recovered.ok) bank.setDevices('Dave', [newPhone], newCard)
      const pay = (key: string) =>
        bank.act('Dave', 'app', `pay from ${key}`, [bank.call('DepositToken', bank.contracts.token, 'transfer', [bank.account('Bob'), 1n])], [key])
      const oldPhone = await pay(phone)
      return [
        check('the recovery waits for the supervisor', waited),
        allowed('then goes through once approved', recovered),
        check('the customer is notified through every contact: the recovery is on record', emitted(recovered, 'AccountRecovered')),
        check('the old signers are gone', !(await isSigner(phone)) && !(await isSigner(card))),
        check('a new phone and card are enrolled', (await isSigner(newPhone)) && (await isSigner(newCard))),
        refusedWith('the lost phone can no longer sign', oldPhone, 'InvalidExecutionSignature'),
        check('the address and balance are unchanged', bank.account('Dave') === account && (await balanceOf(bank, 'Dave')) === balance),
        check('no money moved', (await supply(bank)) === total),
        ...(await invariants(bank)),
      ]
    },
  },

  {
    name: 'ATM fails to dispense',
    kind: 'adverse',
    group: 'Customer mishap',
    building: 'atm',
    panel: 'waiting',
    summary: 'The ATM takes a withdrawal but fails to pay out the cash, and the customer must not lose the money.',
    control: 'ATM hold and confirmation',
    async run(ctx) {
      const { bank } = ctx
      const { atm } = places(bank)
      const amount = 2_000n * HKD
      const before = await balanceOf(bank, 'Carol')
      const atmCash = await cashAt(bank, atm)
      // First run: the ATM reports the failure.
      const first = await withdrawAtAtm(bank, 'Carol', amount)
      const pendingFirst = (await balanceOf(bank, 'Carol')) === before - amount
      const firstRef = refOf(first, 'WithdrawalHeld')
      const failed = firstRef ? await reportDispense(bank, firstRef, false) : first
      const afterFirst = await balanceOf(bank, 'Carol')
      // Second run: the ATM reports nothing; the amount stays pending and flagged until the next count.
      const second = await withdrawAtAtm(bank, 'Carol', amount)
      const secondRef = refOf(second, 'WithdrawalHeld')
      await advance(bank.chain, Settings.dispenseTimeout + 1n)
      const pendingSecond = (await balanceOf(bank, 'Carol')) === before - amount
      const flagged = secondRef !== undefined && (await bank.read('CashOperations', bank.contracts.cash, 'isFlagged', [secondRef]))
      const count = await countCash(bank, atm, atmCash, 'ATM 1 at its refill')
      return [
        check('the amount waits as pending', pendingFirst),
        allowed('the reported failure returns it', failed),
        check('the customer is whole after the first run', afterFirst === before),
        check('with no report it stays pending', pendingSecond),
        check('and is flagged', flagged),
        check('the count returns it', emitted(count, 'WithdrawalReturned')),
        check("the customer's balance is restored in full", (await balanceOf(bank, 'Carol')) === before),
        check('ATM cash is unchanged', (await cashAt(bank, atm)) === atmCash),
        ...(await invariants(bank)),
      ]
    },
  },

  {
    name: 'Payment rejected',
    kind: 'adverse',
    group: 'Customer mishap',
    building: 'clearing-house',
    panel: 'balance sheet',
    summary: 'Another bank rejects a payment a customer sent, and the money must come back to them.',
    control: "Payments module checks the clearing system's signed rejection",
    async run(ctx) {
      const { bank, clearing } = ctx
      const amount = 1_500n * HKD
      const before = await balanceOf(bank, 'Dave')
      const settlement = await ledgerBalance(bank, Ledger.Settlement)
      const paid = await payOut(bank, 'Dave', 'a closed account at another bank', amount)
      const ref = refOf(paid, 'PaymentOrdered')
      const sent = await releasePayments(bank)
      const left = (await balanceOf(bank, 'Dave')) === before - amount
      const rejected = ref ? await clearing.reject(ref, amount) : paid
      const again = ref ? await clearing.reject(ref, amount) : paid
      return [
        allowed('the customer pays', paid),
        check('the payment leaves', emitted(sent, 'PaymentSent') && left),
        allowed('the signed rejection is accepted', rejected),
        refusedWith('the same rejection is accepted only once', again, 'UnknownPayment'),
        check("the customer's balance is back where it started", (await balanceOf(bank, 'Dave')) === before),
        check('the settlement account is back where it started', (await ledgerBalance(bank, Ledger.Settlement)) === settlement),
        ...(await invariants(bank)),
      ]
    },
  },

  {
    name: 'Unknown beneficiary',
    kind: 'adverse',
    group: 'Customer mishap',
    building: 'suspense-lot',
    panel: 'waiting',
    summary: 'Money arrives for an account the bank does not have, so it waits aside and then goes back to the sender.',
    control: 'Suspense account in the payments module',
    async run(ctx) {
      const { bank, clearing } = ctx
      const amount = 700n * HKD
      const customers = await customerTotal(bank)
      const advice = await clearing.creditAdvice(keccak256(toBytes('an account number the bank never issued')), amount)
      const arrived = await clearing.relayCredit(advice, 'relay a payment for an account that does not exist')
      const status = emitted(arrived, 'CreditReceived') ? eventArg<number>(arrived, 'CreditReceived', 'status') : undefined
      const inSuspense = await moduleHolds(bank)
      const returned = await compliance(bank, 'returnIncoming', advice.message.endToEndId, 'return the payment to its sender')
      if (returned.ok) await clearing.debit(amount)
      return [
        check('the funds wait in suspense', status === PaymentStatus.Suspense),
        check('the module holds them meanwhile', inSuspense === amount),
        allowed('compliance returns them to the sender', returned),
        check('no customer is credited', (await customerTotal(bank)) === customers),
        check('suspense is empty after the return', (await moduleHolds(bank)) === 0n),
        ...(await invariants(bank)),
      ]
    },
  },

  {
    name: 'Forged credit advice',
    kind: 'adverse',
    group: 'Fraud and attack',
    building: 'clearing-house',
    panel: 'story',
    summary: 'Someone fakes a message from the clearing system saying money arrived, then replays a real one; neither may create money.',
    control: 'Signature check and unique reference in the payments module',
    async run(ctx) {
      const { bank, clearing } = ctx
      const before = await supply(bank)
      const forged = await clearing.creditAdvice(bank.account('Alice'), 9_000n * HKD, { signedBy: 'a forger' })
      const forgedOutcome = await clearing.relayCredit(forged, 'relay a credit advice the clearing system never signed')
      const afterForged = await supply(bank)
      const genuine = await clearing.creditAdvice(bank.account('Alice'), 800n * HKD)
      const genuineOutcome = await clearing.relayCredit(genuine, 'relay a genuine credit advice')
      const afterGenuine = await supply(bank)
      const replay = await clearing.relayCredit(genuine, 'relay the same advice again')
      return [
        refusedWith('the forged advice is refused, naming the partner key', forgedOutcome, 'InvalidPartnerSignature'),
        check('the forged advice creates no deposit tokens', afterForged === before),
        allowed('the genuine advice is accepted', genuineOutcome),
        refusedWith('the replay is refused, naming the repeated reference', replay, 'ReferenceUsed'),
        check('the replay creates no deposit tokens', (await supply(bank)) === afterGenuine),
        ...(await invariants(bank)),
      ]
    },
  },

  {
    name: 'Flagged payment in',
    kind: 'adverse',
    group: 'Fraud and attack',
    building: 'compliance-yard',
    panel: 'waiting',
    summary: 'A large payment arrives and waits for compliance to clear or return it before the customer can use it.',
    control: 'Screening in the payments module, compliance clearance',
    async run(ctx) {
      const { bank, clearing } = ctx
      const amount = 60_000n * HKD
      const bob = await balanceOf(bank, 'Bob')
      const settlement = await ledgerBalance(bank, Ledger.Settlement)
      const one = await clearing.creditAdvice(bank.account('Bob'), amount)
      const two = await clearing.creditAdvice(bank.account('Bob'), amount)
      const arrivals = [
        await clearing.relayCredit(one, 'relay a large payment for Bob'),
        await clearing.relayCredit(two, 'relay a second large payment for Bob'),
      ]
      const screened = arrivals.every((a) => emitted(a, 'CreditReceived') && eventArg<number>(a, 'CreditReceived', 'status') === PaymentStatus.Screening)
      const settlementRose = (await ledgerBalance(bank, Ledger.Settlement)) === settlement + 2n * amount
      const spend = await transfer(bank, 'Bob', 'Alice', bob + 1n)
      const cleared = await compliance(bank, 'clearIncoming', one.message.endToEndId, "clear the first payment to Bob's account")
      const returned = await compliance(bank, 'returnIncoming', two.message.endToEndId, 'return the second payment to its sender')
      if (returned.ok) await clearing.debit(amount)
      return [
        check('both payments wait for compliance', screened),
        check('the settlement account rises at once', settlementRose),
        refusedWith('the customer cannot spend the amount until it is cleared', spend, 'ERC20InsufficientUnfrozenBalance'),
        allowed('the cleared payment reaches the customer', cleared),
        allowed('the other is returned to its sender', returned),
        check('the customer has the cleared one only', (await balanceOf(bank, 'Bob')) === bob + amount),
        check('the returned one left the settlement account', (await ledgerBalance(bank, Ledger.Settlement)) === settlement + amount),
        ...(await invariants(bank)),
      ]
    },
  },

  {
    name: 'Forged paper slip',
    kind: 'adverse',
    group: 'Fraud and attack',
    building: 'branch',
    panel: 'waiting',
    summary: "A teller moves a customer's money on a slip the customer never signed; the customer disputes it and gets it back.",
    control: 'Second-person approval, then freeze and dispute reversal by forced transfer',
    async run(ctx) {
      const { bank } = ctx
      const amount = 8_000n * HKD
      const before = await balanceOf(bank, 'Alice')
      // The teller makes up a slip Alice never signed, paying an accomplice.
      const slip = 'a slip Alice never signed'
      const opened = await transferAtCounter(bank, 'Alice', 'Dave', amount, { slip })
      const ref = refOf(opened, 'OperationOpened')
      const alone = ref ? await decide(bank, 'teller', 'assisted', ref, 'approve') : opened
      const waiting = ref !== undefined && (await operationOf(bank, 'assisted', ref)).status === OperationStatus.Waiting
      const fooled = ref ? await decide(bank, 'supervisor', 'assisted', ref, 'approve') : opened
      const record = ref ? await operationOf(bank, 'assisted', ref) : undefined
      const left = (await balanceOf(bank, 'Alice')) === before - amount
      // Alice is told, and disputes it: Dave's money is frozen, and the reversal waits for compliance.
      const disputed = ref ? await openDispute(bank, 'Alice', 'Dave', amount, ref) : opened
      const dispute = emitted(disputed, 'DisputeOpened') ? eventArg<bigint>(disputed, 'DisputeOpened', 'id') : undefined
      const moveOn = await transfer(bank, 'Dave', 'Bob', (await balanceOf(bank, 'Dave')) - 1n)
      const proposed = dispute !== undefined ? await proposeReversal(bank, dispute) : disputed
      const waitsForCompliance =
        dispute !== undefined && (await bank.read('DisputeReversal', bank.contracts.disputes, 'dispute', [dispute])).status === DisputeStatus.Proposed
      const reversed = dispute !== undefined && proposed.ok ? await approveReversal(bank, dispute) : proposed
      return [
        check('the transfer waits for an approver', waiting),
        refusedWith('the teller alone cannot complete it', alone, 'NotApprover'),
        allowed('it goes through only once a supervisor approves', fooled),
        check(
          'the teller, approver and slip hash are on record',
          record !== undefined &&
            isAddressEqual(record.teller, bank.account('teller')) &&
            isAddressEqual(record.approvers[0], bank.account('supervisor')) &&
            record.slipHash === slipHash(slip),
        ),
        check(
          "the customer is told at once: the operation's event names her",
          emitted(opened, 'OperationOpened') && isAddressEqual(eventArg<Address>(opened, 'OperationOpened', 'customer'), bank.account('Alice')),
        ),
        check('the money left her account', left),
        allowed('her dispute freezes the money where it went', disputed),
        refusedWith('the recipient cannot move it on', moveOn, 'ERC20InsufficientUnfrozenBalance'),
        allowed('back office proposes the reversal', proposed),
        check('the reversal waits for compliance', waitsForCompliance),
        check('compliance approves it, and the money returns', emitted(reversed, 'DisputeReversed')),
        check('the customer is whole again', (await balanceOf(bank, 'Alice')) === before),
        ...(await invariants(bank)),
      ]
    },
  },

  {
    name: 'Red team',
    kind: 'adverse',
    group: 'Fraud and attack',
    building: 'branch',
    panel: 'story',
    summary: 'An attacker tries one trick after another to exceed their role or steal money, and every attempt should be refused.',
    control: 'Access manager, branch scoping, approval logic, rate limiter, one-use numbers, allow-list, payee register',
    async run(ctx) {
      const { bank } = ctx
      const c = bank.contracts
      // A card authorisation Alice used once, at the ATM, to be replayed.
      const card = await authoriseOnce(ctx)
      const total = (await customerTotal(bank)) + (await supply(bank))
      const stranger = '0x00000000000000000000000000000000000bad00' as const
      // Its own teller role is at branch 2: it opens a paper operation there and tries to approve it itself.
      const own = await transferAtCounter(bank, 'Bob', 'Carol', 100n * HKD, { slip: 'red team slip' }, 'red team', 2n)
      const ownRef = refOf(own, 'OperationOpened')
      const approveOwn = ownRef ? await decide(bank, 'red team', 'assisted', ownRef, 'approve') : own
      // Its own operation is cancelled again, so the money it moved goes back.
      if (ownRef) await bank.act('red team', 'branch', 'cancel it again', [bank.call('AssistedOperations', c.assisted, 'cancel', [ownRef])])
      const forced = await bank.act('red team', 'branch', 'call the forced transfer directly', [
        bank.call('DepositToken', c.token, 'forcedTransfer', [bank.account('Alice'), bank.account('red team'), 100n * HKD]),
      ])
      const atOtherBranch = await bank.act('red team', 'branch', 'take cash in at branch 1 with a teller role for branch 2', [
        bank.call('CashOperations', c.cash, 'deposit', [1n, bank.account('Alice'), 100n * HKD]),
      ])
      const replay = await submitAtmWithdrawal(bank, 'Alice', card)
      const notOnboarded = await bank.act('Alice', 'app', 'send money to an account that is not onboarded', [
        bank.call('DepositToken', c.token, 'transfer', [stranger, 100n * HKD]),
      ])
      // With Alice's phone in hand: more than the app limit, then a stranger above the small limit.
      const overAppLimit = await transfer(bank, 'Alice', 'Bob', Settings.appLimit + HKD)
      const strangerPaid = await payOut(bank, 'Alice', "the red team's account at another bank", Settings.unregisteredPayeeLimit + HKD)
      return [
        // It holds no approving role, so the ladder refuses it before it could approve its own.
        refusedWith('approving its own operation is refused', approveOwn, 'NotApprover'),
        refusedWith('calling the forced transfer directly is refused', forced, 'AccessManagedUnauthorized'),
        refusedWith('acting at this branch with a teller role for another is refused', atOtherBranch, 'NotTeller'),
        refusedWith('replaying a used authorisation is refused, naming the one-use number', replay, 'InvalidAccountNonce'),
        refusedWith('sending to an account that is not onboarded is refused, naming the allow-list', notOnboarded, 'ERC20UserRestricted'),
        refusedWith('more than the app limit is refused', overAppLimit, 'DailyLimitExceeded'),
        refusedWith('a payee never registered is paid no more than the small limit', strangerPaid, 'DailyLimitExceeded'),
        check('no balance changes', (await customerTotal(bank)) + (await supply(bank)) === total),
        ...(await invariants(bank)),
      ]
    },
  },

  {
    name: 'Ledger mismatch',
    kind: 'adverse',
    group: 'Operational incident',
    building: 'water-tower',
    panel: 'balance sheet',
    summary: "An outside statement or a cash count disagrees with the bank's books, and the bank must notice and report it.",
    control: "The attested figures contract's comparison with the ledger; reconciliation by finance",
    async run(ctx) {
      const { bank, clearing } = ctx
      // The clearing system charges a fee the bank never booked.
      await clearing.debit(25n * HKD)
      const entries = await bank.read('GeneralLedger', bank.contracts.ledger, 'entryCount', [])
      const statement = await closeDay(ctx)
      const current = await bank.read('Attestations', bank.contracts.attestations, 'isCurrent', [Ledger.Settlement])
      // A cash count that differs is marked the same way.
      const vaultCash = await cashAt(bank, vault())
      const count = await countCash(bank, vault(), vaultCash - 100n * HKD, 'the vault')
      // Finance reports both to the regulator, each against what it concerns.
      const incidents = () => bank.read('IncidentLog', bank.contracts.incidents, 'incidentCount', [])
      const before = await incidents()
      const statementId = eventArg<Hex>(statement, 'StatementAccepted', 'statementId')
      const countId = numberToHex(eventArg<bigint>(count, 'CashCounted', 'id'), { size: 32 })
      const reported = await reportIncident(bank, 'statement mismatch', statementId, report('the clearing statement'))
      const countReported = await reportIncident(bank, 'cash count mismatch', countId, report('the vault count'))
      // Settled: the clearing system refunds the fee it charged in error, and the vault is counted again.
      await clearing.refund(25n * HKD)
      const recount = await countCash(bank, vault(), vaultCash, 'the vault again')
      const next = await closeDay(ctx)
      return [
        check('the reconciliation line fails', matched(statement, 'StatementAccepted') === false),
        check('the figure is marked, not current', !current),
        check('the cash count that differs is marked too', matched(count, 'CashCounted') === false),
        check('nothing is posted to make them agree', (await bank.read('GeneralLedger', bank.contracts.ledger, 'entryCount', [])) === entries),
        check(
          'the incident is recorded and reported',
          emitted(reported, 'IncidentReported') &&
            eventArg<Hex>(reported, 'IncidentReported', 'subject') === statementId &&
            emitted(countReported, 'IncidentReported') &&
            (await incidents()) === before + 2n,
        ),
        check('once the fee is refunded, the next statement matches', matched(next, 'StatementAccepted') === true),
        check('the vault counted again matches', matched(recount, 'CashCounted') === true),
        ...(await invariants(bank)),
      ]
    },
  },
]

// Alice withdraws once at the ATM, which uses her card's authorisation, and the authorisation is kept to
// be replayed.
async function authoriseOnce(ctx: Context) {
  const { bank } = ctx
  const card = await authorise(bank, 'Alice', { module: 'cash', purpose: 'ATM_WITHDRAWAL', branch: 1n, recipient: bank.account('ATM') }, 100n * HKD)
  const used = await submitAtmWithdrawal(bank, 'Alice', card)
  const ref = refOf(used, 'WithdrawalHeld')
  if (ref) await reportDispense(bank, ref, true)
  return card
}

// The report finance sends the regulator about `what`; only its hash goes on chain.
function report(what: string): string {
  return `finance's report to the regulator of ${what}, which did not match the ledger`
}

function moduleHolds(bank: Bank): Promise<bigint> {
  return bank.read('DepositToken', bank.contracts.token, 'balanceOf', [bank.contracts.payments])
}
