// The bank as deployed: its contracts, the people and machines that act in it, and the way each of them
// acts. Every staff member, machine and customer acts from a multi-signer account whose keys the signer
// service holds; the submission service relays each signed batch. Deploying follows the contract tests'
// fixture: the deployer wires every function to its role in docs/roles.md, hands the admin role to
// governance and gives up its own, and governance then posts the opening balance sheet in
// docs/scenarios.md, registers the partners' keys and grants the control roles, through its officers'
// signatures and its time lock.

import {
  encodeFunctionData,
  getAbiItem,
  keccak256,
  numberToHex,
  stringToHex,
  toBytes,
  toFunctionSelector,
  zeroAddress,
  zeroHash,
  type AbiFunction,
  type Address,
  type ContractFunctionArgs,
  type ContractFunctionName,
  type ContractFunctionReturnType,
  type Hex,
} from 'viem'
import { encodeCalls } from 'viem/experimental/erc7821'
import { abiOf, bytecodeOf, type AbiOf, type ContractName } from './artifacts.ts'
import { atm, Channel, Customers, drawer, HKD, Holders, Ledger, Opening, vault } from './books.ts'
import { advance, type Chain } from './chain.ts'
import { atBranch, BranchRole, Roles } from './roles.ts'
import { Signer } from './signer.ts'
import { Submission, type Outcome } from './submission.ts'
import { Timeline } from './timeline.ts'

// The demo values in docs/roles.md, local profile.
export const Settings = {
  governanceDelay: 2n * 86_400n,
  governanceThreshold: 3n,
  screeningThreshold: 50_000n * HKD,
  statementMaxAge: 2n * 86_400n,
  drawerLimit: 100_000n * HKD,
  atmLimit: 5_000n * HKD,
  cashReportThreshold: 100_000n * HKD,
  dispenseTimeout: 120n,
  appLimit: 10_000n * HKD,
  unregisteredPayeeLimit: 2_000n * HKD,
  payeeWait: 86_400n,
  // The branch approval ladder's steps.
  ladder: { first: 50_000n * HKD, second: 500_000n * HKD },
} as const

// The partners' identifiers in the key register, as contracts/core/PartnerKeys.sol derives them, and the
// keys they sign with.
export const clearingId = keccak256(toBytes('clearing'))
export const custodianId = keccak256(toBytes('custodian'))
export const partnerKey = { clearing: 'partner:clearing system', custodian: 'partner:custodian' } as const

export interface Call {
  to: Address
  data: Hex
}

type Write = 'nonpayable' | 'payable'
type Read = 'view' | 'pure'

export interface Contracts {
  verifier: Address
  officers: Address
  timelock: Address
  manager: Address
  limits: Address
  token: Address
  ledger: Address
  staffRoles: Address
  holds: Address
  partnerKeys: Address
  payments: Address
  attestations: Address
  cash: Address
  assisted: Address
  recovery: Address
  disputes: Address
  incidents: Address
}

// The account a party acts from, and the keys that sign for it unless others are named.
export interface Party {
  account: Address
  keys: string[]
}

export const Officers = ['chief executive', 'stablecoin manager', 'chief financial officer', 'chief risk officer']

// Who holds which role, by the name the stories use for them.
export const Staff = {
  risk: Roles.RISK,
  compliance: Roles.COMPLIANCE,
  finance: Roles.FINANCE,
  'back office': Roles.BACK_OFFICE,
  support: Roles.SUPPORT,
  'IT security': Roles.IT_SECURITY,
  'branch manager': atBranch(1n, BranchRole.BRANCH_MANAGER),
  teller: atBranch(1n, BranchRole.TELLER),
  supervisor: atBranch(1n, BranchRole.SUPERVISOR),
  'vault custodian': atBranch(1n, BranchRole.VAULT_CUSTODIAN),
  'account opening officer': atBranch(1n, BranchRole.ACCOUNT_OPENING_OFFICER),
  'branch 2 manager': atBranch(2n, BranchRole.BRANCH_MANAGER),
  // Holds a teller role at the second branch only, so branch scoping can be shown refusing it.
  'red team': atBranch(2n, BranchRole.TELLER),
} as const
export type StaffName = keyof typeof Staff

// The roles governance grants itself; the branch roles are granted through the branch manager.
const governanceGrants = ['risk', 'compliance', 'finance', 'back office', 'support', 'IT security', 'branch manager', 'branch 2 manager'] as const

// People hired during a run, with an account but no role yet.
const Hires = ['replacement teller'] as const

export class Bank {
  readonly chain: Chain
  readonly signer: Signer
  readonly submission: Submission
  readonly timeline: Timeline
  readonly contracts: Contracts
  private readonly parties = new Map<string, Party>()

  constructor(chain: Chain, signer: Signer, timeline: Timeline, contracts: Contracts) {
    this.chain = chain
    this.signer = signer
    this.timeline = timeline
    this.submission = new Submission(chain, timeline)
    this.contracts = contracts
    for (const [key, address] of Object.entries(contracts) as [keyof Contracts, Address][]) {
      this.submission.name(address, contractNames[key])
    }
  }

  add(name: string, party: Party): void {
    this.parties.set(name, party)
  }

  account(name: string): Address {
    const party = this.parties.get(name)
    if (!party) throw new Error(`No party called ${name}`)
    return party.account
  }

  now(): Promise<bigint> {
    return this.chain.client.getBlock().then((b) => b.timestamp)
  }

  // A party acts: its keys sign the batch for its account, and the submission service relays it.
  async act(name: string, channel: string, action: string, calls: Call[], keys?: string[]): Promise<Outcome> {
    const party = this.parties.get(name)
    if (!party) throw new Error(`No party called ${name}`)
    const executionData = encodeCalls(calls)
    const nonce = await this.read('MultiSignerAccount', party.account, 'executionNonce', [])
    const signature = this.signer.signExecution(party.account, keys ?? party.keys, executionData, nonce)
    return this.submission.submit({
      actor: name,
      channel,
      action,
      to: party.account,
      data: encodeFunctionData({ abi: abiOf('MultiSignerAccount'), functionName: 'executeSigned', args: [executionData, signature] }),
    })
  }

  // A request whose authority is a signature inside it, relayed with no account of its own, such as a
  // partner's message the partner adapter carries.
  relay(actor: string, channel: string, action: string, call: Call): Promise<Outcome> {
    return this.submission.submit({ actor, channel, action, ...call })
  }

  read<N extends ContractName, const F extends ContractFunctionName<AbiOf<N>, Read>>(
    name: N,
    address: Address,
    functionName: F,
    args: ContractFunctionArgs<AbiOf<N>, Read, F>,
  ): Promise<ContractFunctionReturnType<AbiOf<N>, Read, F>> {
    return this.chain.client.readContract({ address, abi: abiOf(name), functionName, args } as never)
  }

  call<N extends ContractName, const F extends ContractFunctionName<AbiOf<N>, Write>>(
    name: N,
    to: Address,
    functionName: F,
    args: ContractFunctionArgs<AbiOf<N>, Write, F>,
  ): Call {
    return { to, data: encodeFunctionData({ abi: abiOf(name), functionName, args } as never) }
  }
}

const contractNames: Record<keyof Contracts, string> = {
  verifier: 'P256Verifier',
  officers: 'Officers',
  timelock: 'Governance',
  manager: 'AccessManager',
  limits: 'CustomerLimits',
  token: 'DepositToken',
  ledger: 'GeneralLedger',
  staffRoles: 'StaffRoles',
  holds: 'HoldRegister',
  partnerKeys: 'PartnerKeys',
  payments: 'Payments',
  attestations: 'Attestations',
  cash: 'CashOperations',
  assisted: 'AssistedOperations',
  recovery: 'AccountRecovery',
  disputes: 'DisputeReversal',
  incidents: 'IncidentLog',
}

// A short reference as a ledger entry or message carries it, such as "opening".
export function ref(text: string): Hex {
  return stringToHex(text, { size: 32 })
}

// Deploying

export async function deployBank(chain: Chain, timeline = new Timeline()): Promise<Bank> {
  const deployer = new Deployer(chain)
  const verifier = await deployer.deploy('ERC7913P256Verifier', [])
  const signer = new Signer(verifier, chain.chainId)

  const officerKeys = Officers.map((o) => `officer:${o}`)
  const officers = await deployer.account(signer, officerKeys, Settings.governanceThreshold, zeroAddress)
  const timelock = await deployer.deploy('TimelockController', [Settings.governanceDelay, [officers], [zeroAddress], zeroAddress])
  const manager = await deployer.deploy('AccessManager', [chain.relayer])
  const limits = await deployer.deploy('CustomerLimits', [
    manager,
    { app: Settings.appLimit, unregistered: Settings.unregisteredPayeeLimit, payeeWait: Settings.payeeWait },
  ])
  const token = await deployer.deploy('DepositToken', [manager, limits])
  const ledger = await deployer.deploy('GeneralLedger', [manager, token])
  const staffRoles = await deployer.deploy('StaffRoles', [manager, officers])
  const holds = await deployer.deploy('HoldRegister', [manager, token])
  const partnerKeys = await deployer.deploy('PartnerKeys', [manager])
  const payments = await deployer.deploy('Payments', [manager, ledger, partnerKeys, Settings.screeningThreshold])
  const attestations = await deployer.deploy('Attestations', [manager, ledger, partnerKeys, Settings.statementMaxAge])
  const recovery = await deployer.deploy('AccountRecovery', [manager])
  const disputes = await deployer.deploy('DisputeReversal', [manager, token, holds])
  const incidents = await deployer.deploy('IncidentLog', [manager])
  const cash = await deployer.deploy('CashOperations', [
    manager,
    ledger,
    {
      drawer: Settings.drawerLimit,
      atm: Settings.atmLimit,
      cashReport: Settings.cashReportThreshold,
      dispenseTimeout: Settings.dispenseTimeout,
    },
    recovery,
    Settings.ladder,
  ])
  const assisted = await deployer.deploy('AssistedOperations', [manager, token, recovery, Settings.ladder])
  const contracts: Contracts = {
    verifier,
    officers,
    timelock,
    manager,
    limits,
    token,
    ledger,
    staffRoles,
    holds,
    partnerKeys,
    payments,
    attestations,
    cash,
    assisted,
    recovery,
    disputes,
    incidents,
  }
  const bank = new Bank(chain, signer, timeline, contracts)
  bank.add('governance officers', { account: officers, keys: officerKeys.slice(0, Number(Settings.governanceThreshold)) })

  // Every party's account, each with its own keys: a staff token, a machine's module, or a customer's
  // phone and card. A customer signs with their phone unless the card is named.
  for (const name of [...Object.keys(Staff), ...Hires]) {
    const keys = [`staff:${name}`]
    bank.add(name, { account: await deployer.account(signer, keys, 1n, zeroAddress), keys })
  }
  const atmKeys = ['machine:ATM 1']
  bank.add('ATM', { account: await deployer.account(signer, atmKeys, 1n, zeroAddress), keys: atmKeys })
  // A customer's account has the recovery module fixed in it.
  for (const name of Holders) {
    const keys = [`${name}:phone`, `${name}:card`]
    bank.add(name, { account: await deployer.account(signer, keys, 1n, recovery), keys: keys.slice(0, 1) })
  }

  // How movements into the modules count, set while the deployer is still the admin: not at all into
  // those that keep their own channel's limit, and against the app limit only into payments, which
  // checks the payee itself.
  for (const module of [cash, assisted]) await deployer.write('CustomerLimits', limits, 'setChannel', [module, Channel.Own])
  await deployer.write('CustomerLimits', limits, 'setChannel', [payments, Channel.PayeeCheckedThere])
  await wire(deployer, contracts)
  for (const name of Holders) await deployer.write('DepositToken', token, 'allowUser', [bank.account(name)])
  await deployer.write('DepositToken', token, 'allowUser', [payments])
  await deployer.write('DepositToken', token, 'allowUser', [cash])
  await deployer.write('DepositToken', token, 'allowUser', [assisted])
  await deployer.write('AccessManager', manager, 'grantRole', [Roles.ADMIN, timelock, 0])
  await deployer.write('AccessManager', manager, 'grantRole', [Roles.GOVERNANCE, timelock, 0])
  await deployer.write('AccessManager', manager, 'renounceRole', [Roles.ADMIN, chain.relayer])

  await governFirstDay(bank, signer)
  await grantBranchRoles(bank)
  return bank
}

class Deployer {
  private readonly chain: Chain

  constructor(chain: Chain) {
    this.chain = chain
  }

  async deploy(name: ContractName, args: readonly unknown[]): Promise<Address> {
    const hash = await this.chain.wallet.deployContract({
      abi: abiOf(name),
      bytecode: bytecodeOf(name),
      args,
      account: this.chain.relayer,
      chain: null,
    } as never)
    const receipt = await this.chain.client.waitForTransactionReceipt({ hash })
    if (!receipt.contractAddress) throw new Error(`${name} was not deployed`)
    return receipt.contractAddress
  }

  account(signer: Signer, keys: string[], threshold: bigint, recovery: Address): Promise<Address> {
    return this.deploy('MultiSignerAccount', [[signer.verifier], keys.map((k) => signer.signerBytes(k)), threshold, recovery])
  }

  async write<N extends ContractName, const F extends ContractFunctionName<AbiOf<N>, Write>>(
    name: N,
    address: Address,
    functionName: F,
    args: ContractFunctionArgs<AbiOf<N>, Write, F>,
  ): Promise<void> {
    const hash = await this.chain.wallet.sendTransaction({
      account: this.chain.relayer,
      chain: null,
      to: address,
      data: encodeFunctionData({ abi: abiOf(name), functionName, args } as never),
    })
    const receipt = await this.chain.client.waitForTransactionReceipt({ hash })
    if (receipt.status !== 'success') throw new Error(`${name}.${functionName} reverted`)
  }
}

// Each restricted function and the role docs/roles.md gives it, as the fixture wires them.
const wiring: [keyof Contracts, ContractName, string, bigint][] = [
  ['token', 'DepositToken', 'mint', Roles.LEDGER],
  ['token', 'DepositToken', 'burn', Roles.LEDGER],
  ['token', 'DepositToken', 'forcedTransfer', Roles.ENFORCER],
  ['token', 'DepositToken', 'setFrozenTokens', Roles.FREEZER],
  ['token', 'DepositToken', 'blockUser', Roles.COMPLIANCE],
  ['token', 'DepositToken', 'unblockUser', Roles.GOVERNANCE],
  ['ledger', 'GeneralLedger', 'post', Roles.BOOKKEEPER],
  ['ledger', 'GeneralLedger', 'postWithMint', Roles.BOOKKEEPER],
  ['ledger', 'GeneralLedger', 'postWithBurn', Roles.BOOKKEEPER],
  ['ledger', 'GeneralLedger', 'postOpening', Roles.GOVERNANCE],
  ['partnerKeys', 'PartnerKeys', 'setKey', Roles.GOVERNANCE],
  ['partnerKeys', 'PartnerKeys', 'revokeKey', Roles.IT_SECURITY],
  ['payments', 'Payments', 'clearIncoming', Roles.COMPLIANCE],
  ['payments', 'Payments', 'returnIncoming', Roles.COMPLIANCE],
  ['payments', 'Payments', 'clearOutgoing', Roles.COMPLIANCE],
  ['payments', 'Payments', 'returnOutgoing', Roles.COMPLIANCE],
  ['payments', 'Payments', 'setScreeningThreshold', Roles.GOVERNANCE],
  ['attestations', 'Attestations', 'setMaxAge', Roles.GOVERNANCE],
  ['cash', 'CashOperations', 'openCash', Roles.GOVERNANCE],
  ['cash', 'CashOperations', 'setLimits', Roles.GOVERNANCE],
  ['cash', 'CashOperations', 'withdrawAtAtm', Roles.ATM],
  ['cash', 'CashOperations', 'confirmDispense', Roles.ATM],
  ['cash', 'CashOperations', 'reportFailure', Roles.ATM],
  ['cash', 'CashOperations', 'setLadder', Roles.GOVERNANCE],
  ['assisted', 'AssistedOperations', 'setLadder', Roles.GOVERNANCE],
  ['limits', 'CustomerLimits', 'countMovement', Roles.LIMIT_KEEPER],
  ['limits', 'CustomerLimits', 'countPayment', Roles.LIMIT_KEEPER],
  ['limits', 'CustomerLimits', 'enrol', Roles.GOVERNANCE],
  ['limits', 'CustomerLimits', 'setChannel', Roles.GOVERNANCE],
  ['limits', 'CustomerLimits', 'setLimits', Roles.GOVERNANCE],
  ['incidents', 'IncidentLog', 'report', Roles.FINANCE],
]

// Every staff and machine role, for each branch, which the staff roles module administers.
const administered = [
  ...Array.from({ length: Number(Roles.INTERNAL_AUDIT - Roles.RISK) + 1 }, (_, i) => Roles.RISK + BigInt(i)),
  Roles.ATM,
  Roles.SCHEDULER,
  ...[1n, 2n].flatMap((b) => Object.values(BranchRole).map((r) => atBranch(b, r))),
]

async function wire(deployer: Deployer, c: Contracts): Promise<void> {
  for (const [key, name, fn, role] of wiring) {
    const selector = toFunctionSelector(getAbiItem({ abi: abiOf(name), name: fn } as never) as AbiFunction)
    await deployer.write('AccessManager', c.manager, 'setTargetFunctionRole', [c[key], [selector], role])
  }
  await deployer.write('AccessManager', c.manager, 'grantRole', [Roles.LEDGER, c.ledger, 0])
  await deployer.write('AccessManager', c.manager, 'grantRole', [Roles.STAFF_ADMIN, c.staffRoles, 0])
  await deployer.write('AccessManager', c.manager, 'grantRole', [Roles.FREEZER, c.holds, 0])
  await deployer.write('AccessManager', c.manager, 'grantRole', [Roles.BOOKKEEPER, c.payments, 0])
  await deployer.write('AccessManager', c.manager, 'grantRole', [Roles.BOOKKEEPER, c.cash, 0])
  await deployer.write('AccessManager', c.manager, 'grantRole', [Roles.ENFORCER, c.cash, 0])
  await deployer.write('AccessManager', c.manager, 'grantRole', [Roles.ENFORCER, c.assisted, 0])
  await deployer.write('AccessManager', c.manager, 'grantRole', [Roles.LIMIT_KEEPER, c.token, 0])
  await deployer.write('AccessManager', c.manager, 'grantRole', [Roles.LIMIT_KEEPER, c.payments, 0])
  await deployer.write('AccessManager', c.manager, 'grantRole', [Roles.ENFORCER, c.disputes, 0])
  await deployer.write('AccessManager', c.manager, 'grantRole', [Roles.DISPUTE_HOLDER, c.disputes, 0])
  for (const role of administered) await deployer.write('AccessManager', c.manager, 'setRoleAdmin', [role, Roles.STAFF_ADMIN])
}

// Governance's first decision, as one batch through the time lock: the opening balance sheet and its
// cash split, the partners' keys, the control roles governance grants, and the customers enrolled in their
// limits, which the onboarding module will do once it exists.
async function governFirstDay(bank: Bank, signer: Signer): Promise<void> {
  const c = bank.contracts
  const line = (account: number, amount: bigint) => ({ account, amount })
  const calls: Call[] = [
    bank.call('GeneralLedger', c.ledger, 'postOpening', [
      Holders.map((n) => bank.account(n)),
      Holders.map((n) => Opening.deposits[n]),
      [
        line(Ledger.Settlement, Opening.settlement),
        line(Ledger.Cash, Opening.cash),
        line(Ledger.Securities, Opening.securities),
        line(Ledger.Loans, Opening.loans),
        line(Ledger.Allowance, -Opening.allowance),
        line(Ledger.Equity, -Opening.equity),
      ],
      ref('opening'),
    ]),
    bank.call('CashOperations', c.cash, 'openCash', [
      [vault(), drawer(bank.account('teller')), atm(bank.account('ATM'))],
      [Opening.vault, Opening.drawer, Opening.atm],
    ]),
    bank.call('PartnerKeys', c.partnerKeys, 'setKey', [clearingId, signer.signerBytes(partnerKey.clearing)]),
    bank.call('PartnerKeys', c.partnerKeys, 'setKey', [custodianId, signer.signerBytes(partnerKey.custodian)]),
    ...governanceGrants.map((name) => bank.call('StaffRoles', c.staffRoles, 'grant', [bank.account(name), Staff[name]])),
    ...Customers.map((name) => bank.call('CustomerLimits', c.limits, 'enrol', [bank.account(name)])),
  ]
  await govern(bank, 'governance officers', 'open the bank', calls)
}

// A governance decision: three officers sign the time lock's schedule, the time lock holds it for its
// delay, and anyone carries it out.
export async function govern(bank: Bank, by: string, action: string, calls: Call[]): Promise<void> {
  const c = bank.contracts
  const targets = calls.map((x) => x.to)
  const values = calls.map(() => 0n)
  const payloads = calls.map((x) => x.data)
  const salt = numberToHex(await bank.read('MultiSignerAccount', c.officers, 'executionNonce', []), { size: 32 })
  const scheduled = await bank.act(by, 'admin', `schedule: ${action}`, [
    bank.call('TimelockController', c.timelock, 'scheduleBatch', [targets, values, payloads, zeroHash, salt, Settings.governanceDelay]),
  ])
  if (!scheduled.ok) throw new Error(`Governance could not schedule ${action}: ${scheduled.error}`)
  await advance(bank.chain, Settings.governanceDelay)
  const done = await bank.relay(
    'anyone',
    'admin',
    `carry out: ${action}`,
    bank.call('TimelockController', c.timelock, 'executeBatch', [targets, values, payloads, zeroHash, salt]),
  )
  if (!done.ok) throw new Error(`Governance could not carry out ${action}: ${done.error}`)
}

// Branch roles are proposed by the branch manager and approved by IT security; the ATM is enrolled by IT
// security and approved by a supervisor of its branch.
async function grantBranchRoles(bank: Bank): Promise<void> {
  const proposals: [string, StaffName][] = [
    ['branch manager', 'teller'],
    ['branch manager', 'supervisor'],
    ['branch manager', 'vault custodian'],
    ['branch manager', 'account opening officer'],
    ['branch 2 manager', 'red team'],
  ]
  for (const [manager, name] of proposals) {
    await grantThroughBranch(bank, manager, bank.account(name), Staff[name], `grant ${name} their role`)
  }
  const enrolled = await proposeAndApprove(bank, 'IT security', bank.account('ATM'), Roles.ATM, 'supervisor', Staff.supervisor, 'enrol ATM 1')
  if (!enrolled.ok) throw new Error(`Could not enrol ATM 1: ${enrolled.error}`)
}

// A branch manager's grant of a branch role, which IT security approves.
export async function grantThroughBranch(bank: Bank, manager: string, account: Address, role: bigint, action: string): Promise<Outcome> {
  const outcome = await proposeAndApprove(bank, manager, account, role, 'IT security', Roles.IT_SECURITY, action)
  if (!outcome.ok) throw new Error(`Could not ${action}: ${outcome.error}`)
  return outcome
}

async function proposeAndApprove(
  bank: Bank,
  maker: string,
  account: Address,
  role: bigint,
  approver: string,
  approverRole: bigint,
  action: string,
): Promise<Outcome> {
  const c = bank.contracts
  const proposed = await bank.act(maker, 'branch', `propose: ${action}`, [bank.call('StaffRoles', c.staffRoles, 'propose', [account, role, true])])
  if (!proposed.ok) return proposed
  const id = proposed.events.find((e) => e.name === 'Proposed')?.args.id as bigint
  return bank.act(approver, 'branch', `approve: ${action}`, [bank.call('StaffRoles', c.staffRoles, 'approve', [id, approverRole])])
}
