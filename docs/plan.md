# Plan

## Goal

A demo that a salesperson or a developer with no web3 background can start locally and understand, and that an institutional reviewer can inspect and find credible. It should show:

- a bank whose account balances are tokens, with its books kept on the same ledger, so the two cannot disagree;
- lending that creates money only within capital and liquidity limits the chain enforces;
- a stablecoin beside the deposit that cannot be issued beyond its reserve;
- customers paying and being paid by people at other banks;
- every movement of money as a signed, attributable transaction;
- access decided by a person's role and the channel they act through, not by who holds a key;
- staff, devices and customers changing over time without accounts changing;
- customers served both on their own devices and by tellers acting on their instruction, including on paper;
- AI agents working inside those rules, including one trying to break them.

## Primary use cases

### 1. The five-minute pitch

A presenter runs the demo from the dashboard for an audience with no web3 background. An institutional reviewer may be in the room, or inspects it afterwards.

**The pitch.** This is a bank whose rules live in the ledger. Its staff jobs can be handed to AI agents, including a hostile one, and it still refuses what it should.

The presenter leads with the bank and its refusals, not with the blockchain. The chain comes in as the answer to the two questions the audience asks.

| Question | Answer | Where the dashboard shows it |
|---|---|---|
| Why can't the agent just do it anyway? | An agent's instructions are not the control. The contracts check every signature and role, and refuse what the role does not allow. | Refused lines in the story view, each naming the rule that stopped it |
| Why not a database? | A balance and the bank's books change in one transaction, so they cannot disagree. Every change is signed by a named person or machine. The chain is public and not run by the bank, so the bank cannot rewrite it, and anyone, the auditor and the regulator included, can check every block without the bank's help. | The invariant strip, the ledger entry under the hood of each story line, and the same transaction on the public block explorer |

**What the presenter needs**

- **One preset for the whole pitch.** The [guided tour](scenarios.md#guided-tour) runs the beats in order and waits for the presenter between them.
- **The same outcome every run.** The tour is scripted, so the same refusals fall in the same places.
- **No setup beyond starting it locally.** The first four beats need no API key.
- **Every claim on screen, not narrated.** The [invariant strip](architecture.md#dashboard), and the ledger entry behind each story line.

## Scope

**Transactions**
- Cash deposit and withdrawal at a teller desk or ATM.
- Transfer between customers.
- Payments to and from any account at other banks through a simulated clearing system.
- Standing orders under a signed mandate.

**Products**
- Savings account: an interest-bearing deposit, paying the bank's savings rate.
- Simple loans: unsecured, fixed rate, fixed term, equal instalments.
- Stablecoin: converted from and back to a deposit balance at par.

**Money model**
- Customer balances are deposit tokens: claims on the bank, created by cash paid in, payments received and lending.
- The bank's books are a general ledger on chain. Lending is refused when it would breach the capital or liquidity ratio.
- The stablecoin is a separate product, fully backed by reserve at a custodian plus a buffer, and pays no interest.
- The bank sets its savings and loan rates and stands between depositors and borrowers.

**Customer authorisation**
- Own device, card and PIN, or a paper instruction at a counter.
- Self-service is limited by amount. The branch has no cap; approvals escalate with the amount.
- The bank can move money or replace an account's signers without the customer's signature only through named modules: paper instructions, support, dispute reversal, account recovery.

**Simulation**
- AI agents for the main roles, scripts for machines, outside parties and secondary roles.
- A scenario clock that advances time and injects events.
- Daily routines that run as the baseline, and adverse scenarios injected on top and scored. See [scenarios](scenarios.md).
- A guided tour that runs both in a fixed order as one presentation.
- A dashboard with a plain-language story view, an under-the-hood toggle and an invariant strip.
- A control panel to instruct agents, trigger scenarios, control time, and stop or start channel gateways.

## Milestones

| # | Milestone | Outcome | New on screen |
|---|---|---|---|
| 1 | Documents | This folder, plus the open questions below resolved | The documents; nothing runs yet |
| 2 | Working demo | Deposit token with the general ledger, accounts, roles, cash and transfers by all three authorisation modes, payments in and out with the clearing simulator and its signature checked on chain, forced transfer and account recovery, second-person approval, scripted actors, story view, invariant strip, balance sheet, scenario triggers, the guided tour and time controls. Runs with no API key. | The dashboard's daily and adverse views, with the invariant strip showing that the books balance. Tour beats 1 to 4. |
| 3 | Products | Loans with the lending guard and the loss allowance, savings account, standing orders, bank-set rates, pause and resume through governance, with an income statement on the dashboard | The income statement, loans on the balance sheet with the two ratios moving against their minimums, governance changes in the waiting strip. Tour beat 5. |
| 4 | Stablecoin | Conversion to and from deposits, mint guard, buffer, custodian simulator, reserve panel | The reserve panel, and the reserve check on the invariant strip |
| 5 | AI agents | Default set of six first, then the optional six, with plain-language instructions from the control panel. Needs an Anthropic API key. | The same routines and scenarios played by AI agents, the red team's own attempts in the story view, and an instruction typed by the operator carried out or refused. Tour beat 3 taken live. |
| 6 | Institutional layer | Deployment to Base Sepolia with a seeded run, channel gateways on separate network zones with channel failure controls, signer service with key inventory and logs, passkey devices. The single-key exposure inventory and the expansion paper are written alongside. | Block explorer links under the hood, channel controls on the control panel, taking over a role with a passkey. Tour beat 6. |

A milestone is done when its [daily routines](scenarios.md#daily-operation) run and its [adverse scenarios](scenarios.md#adverse-scenarios) pass. Every milestone after the first ends with something new to see on the dashboard, named in the last column.

Milestone 2 is the first point at which the project is demonstrable on its own: the [guided tour](scenarios.md#guided-tour) runs its first four beats. Milestone 3 is the first at which it behaves like a bank and not a payment account, because lending is what creates money.

## Out of scope

- More than one branch, currency or ATM in the default demo. The design supports more.
- The token on a second chain, other banks, bonds, mortgages, investments and insurance. See [expansion](#expansion).
- Card payments at merchants and cheques. Each needs another network (a card scheme, a cheque clearing house) that adds little the clearing simulator does not already show.
- Cross-border wires. A correspondent bank would work as the clearing simulator does, more slowly.
- Running the chain. Nodes, validators and consensus belong to whoever runs it, so their failures are not simulated. See [network](architecture.md#network).
- Mainnet. Real gas buys nothing a testnet does not show.
- Offline approvals at ATMs.
- Limits by the device that signed. Limits follow the channel a request arrives through.
- Court orders and other legal process. Dispute reversal already shows a forced transfer that takes frozen money under a second approval.
- Collateral, credit scoring, variable-rate loans, early repayment fees.
- Real capital and liquidity rules. The two ratios are simplified stand-ins, with no risk weights, capital tiers or stressed outflow assumptions.
- Real loss provisioning. The allowance is a rate per loan status, not an expected credit loss model.
- Accrual accounting. Loan interest is booked when an instalment is collected, not day by day.
- Term notes. A second interest-bearing product would show nothing the savings account does not.
- Direct debits. Loan instalments and standing orders already show collection under a signed mandate.
- Insolvency, resolution and deposit protection payouts. The dashboard shows insolvency; what follows is legal.
- A business calendar. Every day is a business day.
- Regulatory returns, tax, foreign exchange.
- A running cloud deployment of the services. The contracts are deployed to a public testnet; the services run locally, with reference manifests only.
- Real compliance integrations. Screening and reporting are simulated.
- ERC-4337 bundler flow and credential exchange protocols. See [standards](standards.md#considered-and-not-used).

## Expansion

The core is built so that new products plug in as modules without changing it. None of this is in scope; it is recorded so the core does not rule it out, and will be written up in milestone 6.

### Cross-chain

Ordinary payments stay with the clearing simulator, because that is what a payment is. Cross-chain is about the stablecoin itself leaving the bank's home chain. The deposit token stays home: it is a claim only the bank's own customers can hold.

**Step 1: the bank's stablecoin on a shared chain**

One issuer, one reserve, and a token contract on each chain.

- **New tokens are issued only on the home chain**, where the reserve is checked.
- **Moving between chains is burn on one, issue on the other.** The bank attests its own burns, so holders trust no one they did not already trust.
- **Supply across chains stays within the one reserve.** A move does not change the total; the home chain counts what has moved out.
- **Controls.** Attestation by several signers held as significant keys; a cap on how much can move per period in each direction; the same freeze, block-list and pause on every chain.
- **Not atomic.** The burn comes first and the issue follows. If the message is delayed or the far side is paused, the funds wait and are not lost, because the burn is on record.
- **It ends the closed perimeter on the shared side.** Non-customers can hold the token there. Tellers, ATMs, products and redemption for money stay on the home chain. See [HKMA mapping](hkma-mapping.md#if-the-token-leaves-the-perimeter).

**Step 2: other banks on the shared chain**

The shared chain acts as the hub. Each bank brings its own token there by its own burn-and-issue link, so each bank needs one link, not one per counterparty.

- A customer of another bank can simply hold this bank's token.
- Two banks' tokens can be swapped atomically in a single transaction, because both are on the same ledger.

The production analogue is banks settling with each other on one shared ledger, in central bank money or in each other's tokens, as in Hong Kong's Project Ensemble.

**Considered and set aside**

| Approach | Why not |
|---|---|
| Each bank holding an account on every other bank's chain | Relationships grow with the square of the number of banks. Real banks avoid this through correspondents and hubs. |
| Hash time-locked swaps between two banks' chains | Each side must be able to claim within its window, and a pause, a freeze or a chain halt on either side can prevent that. It also needs each bank to watch the other's chain. Unnecessary once both tokens are on one shared chain. |
| Third-party bridges that lock the token and issue a wrapped copy | The wrapped copy is the bridge operator's liability, not the bank's. The HKMA guideline names wrapped versions of an issuer's token as a risk. |
| Bridging one bank's token into another's | Each token is its own bank's liability with its own reserve, so one cannot be turned into the other without moving reserve assets. |

### Products

- **Bonds.** A second token with coupon payments and atomic settlement against the stablecoin.
- **Mortgages and investments.** Depend on facts from outside the chain (property title, market prices), brought in as attestations by a role.
- **Insurance.** Weak fit; the chain adds little beyond premium and payout movements.

## Open questions

1. **Chain compatibility.** Tested on the local chain: the deposit token's base, the multi-signer customer account, the role-controlled bank account and the recovery module build for the Cancun rules and pass the [compatibility tests](../test/compat/Spike.t.sol). Cancun is the floor: OpenZeppelin itself uses the `mcopy` instruction, beside the token extension's transient storage, and a Shanghai build fails. Still open: passkey signers, and the same tests against Base Sepolia.
2. **OpenZeppelin community library versioning.** Resolved. Pinned to commit `2add94e` as a git dependency. That commit builds against OpenZeppelin Contracts v5.7.0 exactly, which is pinned beside it. v5.7.0 is published under npm's `dev` tag, not `latest`, so it has to be asked for by version.
3. **Development toolchain.** Resolved. Hardhat 3 with pnpm. Contract tests are written in Solidity with forge-std, which Hardhat 3 runs itself, so Foundry is not needed. TypeScript tests remain available for the services.
4. **A stablecoin beside deposits.** Interest is paid on deposits under banking rules, not on the stablecoin. Whether the HKMA would accept both from one issuer is a legal question left open. See [HKMA mapping](hkma-mapping.md).
5. **Anti-money-laundering guideline.** Not read. Needed only if the compliance agent's rules should be faithful.
6. **Freezes on savings shares.** `ERC20uRWA` has been read and fits the two tokens. Whether it combines cleanly with `ERC4626` for the savings shares has not been checked. See [standards](standards.md#tokens).
7. **Recovery hook on the account.** Resolved without a fork. `MultiSignerERC7913` leaves the public signer functions to the account built on it, so the account opens them to itself and to one recovery module fixed at deployment. The module has no other way in: it cannot execute calls through the account or move its tokens. Covered by the compatibility tests.
8. **General ledger shape.** Resolved. The chain keeps a running balance per account and emits each entry as an event, which the indexer turns into the timeline. The ledger is the only contract that creates or destroys deposit tokens, and the Deposits balance is read from the token's supply, not kept beside it. Storing every entry raised the cost of a posting by a half to three quarters, and storing a hash of each added a sixth to a quarter, for a look back at past entries that no contract needs. Entries are posted with signed amounts that must sum to zero, and a random sequence of postings keeps the books balanced. Covered by the [ledger tests](../test/compat/Ledger.t.sol).
9. **Ratio calibration.** Minimum capital and liquidity ratios that make the lending-stopped and run scenarios reachable in a short demo.
10. **Banking rules.** The capital, liquidity and exposure rules and the HKMA's guidance on tokenised deposits have been read, and the banking side of the [HKMA mapping](hkma-mapping.md#banking-side) cites them. Still open: whether deposit protection covers tokenised deposits, on which neither the HKMA nor the Deposit Protection Board has said anything, and whether a deposit token on a public chain would be accepted at all, since the HKMA's guidance allows it only with compensating controls and its material on Hong Kong's live tokenised deposits assumes bank-run or permissioned platforms.
11. **Time.** Resolved. There is one clock, the block's. Time locks, access manager delays, signature validity windows and rate limits in the standard contracts all read block time and cannot be given another, so the business day is worked out from block time too, not stored beside it. A stored date the scheduler advanced would move while every time lock and limit stayed where it was. On the local chain the scenario's time controls move block time forward, and the business day, pending time locks, expiring authorisations and refilling limits all move with it. Block time cannot go back, so the day moves forward only. Scheduled work runs every day missed since its last run, so a jump of several days misses none. Base Sepolia's time cannot be moved, so the seeded run there uses real time with short governance delays set at deployment, and the guided tour runs locally. Covered by the [clock tests](../test/compat/Clock.t.sol).
12. **Partner signatures.** Which key type the partners sign with and exactly which fields are signed. See [standards](standards.md#accounts-and-signatures).

## Risks

- **Scope.** The plan has grown well beyond a small proof of concept. The milestone order is the main control: each one must be demonstrable before the next starts.
- **Dependency maturity.** Several OpenZeppelin pieces are drafts or community contracts. See [standards](standards.md#maturity).
- **Agent cost and legibility.** Twelve AI agents are expensive to run and hard to follow, so six run by default.
- **Bank-initiated movement.** Paper instructions, support, reversals and recovery act without the customer's own cryptographic consent. The controls around them need the most careful testing.
- **Money creation.** A bug in the ledger or the lending guard creates money from nothing. Every path that creates deposit tokens needs a test that the books still balance.
- **Two monies.** Carrying a stablecoin beside deposits doubles the token surface. It sits in its own milestone so the bank is demonstrable without it.
