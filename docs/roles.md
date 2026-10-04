# Roles

Tentative. The role list and the permission matrix are the specification the contracts, agent tools and dashboard explanations are derived from, so they should be settled before code is written.

## Three lines of defence

| Line | Purpose | Roles |
|---|---|---|
| **Business** | Serve customers and process transactions | Teller, supervisor, branch manager, back office, support, credit officer, vault custodian, account opening officer |
| **Control** | Set limits and check the business | Compliance, risk, treasury, finance, IT security |
| **Assurance** | Review both independently | Internal audit, external auditor |

## Role list

| Role | Within scope, they | How played |
|---|---|---|
| **Retail customer** | Hold an account, act from their own devices or card, or instruct a teller; manage their devices and limits | AI agent |
| **Corporate customer** | As above, with several authorised signatories and a signing threshold | AI agent (optional) |
| **Teller** | Take cash in and out, act on customers' instructions (device, card or paper), help with products | AI agent |
| **Supervisor** | Approve teller operations, including every debit on a paper instruction; unfreeze accounts; approve loans | AI agent |
| **Branch manager** | Further approver for large branch operations; grants and revokes roles within the branch | Script |
| **Back office** | Handle payment exceptions, reverse disputed operations | AI agent |
| **Compliance** | Clear flagged payments and large cash, place and lift compliance holds, block-list, record suspicious activity | AI agent |
| **Support** | Freeze, revoke devices and cards, stop a pending payment, open disputes, lower limits, move money between a customer's own accounts, log and follow complaints. Cannot pay out to others. | AI agent (optional) |
| **Credit officer** | Propose loans | AI agent (optional) |
| **Risk** | Pause the system in an incident; advise on limits and loss allowance rates | AI agent (optional) |
| **Treasury** | Keep the settlement account funded, manage liquid securities and the stablecoin reserve and buffer within risk limits, propose savings and loan rates | AI agent (optional) |
| **Internal audit** | Review staff actions, sample paper instructions against their scans; read-only | AI agent (optional) |
| **Red team** | Try to exceed a role or steal funds | AI agent |
| **Vault custodian** | Issue cash to teller drawers and the ATM, count it, bank surplus cash to the settlement account, under dual control | Script |
| **Account opening officer** | Onboard customers, enrol their first device and card, recover accounts, with a second check | Script |
| **Finance** | Reconcile the general ledger against clearing and custodian statements and cash counts, prepare the balance sheet and the reserve statement | Script |
| **IT security** | Enrol and retire ATMs and staff terminals, keep the key inventory, rotate compromised keys | Script |
| **Transaction monitoring** | Flag patterns for compliance | Script |
| **External auditor** | Attest the reserve periodically, including a random day; check the ledger from the public chain | Script |
| **ATM** | Take and dispense cash against a card authorisation, confirm or report each dispense | Script |
| **Scheduler** | Trigger work that is due and advance the business date; cannot choose amounts or parties | Script |
| **Partner adapter** | Relay partners' signed messages to the chain; holds no role | Script |
| **Clearing system** | Hold the bank's settlement account, carry payments to and from other banks, issue statements | Script |
| **Other banks and their customers** | Pay the bank's customers, receive payments from them | Script |
| **Custodian** | Hold the bank's liquid securities and, apart from them, the stablecoin reserve; confirm holdings, report yield | Script |
| **Regulator** | Receive statements and incident reports; check the ledger from the public chain; read-only | Script |
| **Governance signers** | Chief executive, stablecoin manager, chief financial officer, chief risk officer; approve high-risk changes | Script |

In the one-branch demo the supervisor and branch manager can be the same agent for small scenarios, but they are separate roles so the approval ladder works.

A second branch exists in the contracts as a role scope only, with no premises, staff or customers. The red team holds its teller role, so branch scoping can be shown refusing it at the first branch.

Six AI agents run by default: retail customer, teller, supervisor, back office, compliance, red team. Six more are switchable. Every role exists in the contracts whichever way it is played.

The stablecoin manager is the named officer a bank must appoint when it holds a stablecoin licence.

## Draft permission matrix

Amounts are placeholders in HKD to show the shape, not proposed values. "Customer authorisation" is one of the three modes in the [architecture](architecture.md#customer-authorisation): own device, card and PIN, or paper.

### Customers and devices

| Action | Initiated by | Customer authorisation | Second approval | Limit |
|---|---|---|---|---|
| Onboard customer, enrol first device and card | Account opening officer | In person | Supervisor | |
| Add own device | Customer | Existing device | None | Device cap per account |
| Recover an account whose devices and card are all lost | Account opening officer | In person | Supervisor | Signer list only; cannot move money |
| Revoke device or card | Customer, support | | None | |
| Lower own limits, restrict assisted service | Customer, support | Own device, or verified call | None | |
| Raise own limits | Teller | In person | Supervisor | |
| Freeze account, stop a pending payment | Support, compliance, supervisor | | None | |
| Unfreeze account | Supervisor, compliance | | None | |
| Block-list or remove from block-list | Compliance | | Governance to remove | |

### Money movement

| Action | Initiated by | Customer authorisation | Second approval | Limit |
|---|---|---|---|---|
| Cash deposit | Teller, ATM | None | Compliance report above a cash threshold | Drawer limit |
| Cash withdrawal at ATM | ATM | Card and PIN | None | 5,000 per day |
| Cash withdrawal at counter | Teller | Device, card or paper | Branch approval ladder | Drawer limit, then vault |
| Transfer from own device | Customer | Own device | None | 10,000 per day, or lower if the customer set it |
| Transfer via teller | Teller | Device, card or paper | Branch approval ladder | None |
| Transfer between a customer's own accounts and products | Support | Verified call | None | Same customer on both sides |
| Register payee | Customer, teller | Device, card or paper | Supervisor if on paper | From a device, takes effect after a waiting period |
| Payment out from own device | Customer | Own device | Compliance clearance if flagged | App limit to a registered payee; a small limit to anyone else; settlement account must cover it |
| Payment out via teller | Teller | Device, card or paper | Branch approval ladder, then compliance clearance if flagged | Settlement account must cover it |
| Payment in | Clearing system, by a signed credit advice the adapter relays | None | Compliance clearance if flagged; frozen until then | Any payer; each reference once |
| Set up or cancel a standing order | Customer, teller | Device, card or paper | Supervisor if on paper | Each payment within the mandate |
| Convert deposit to stablecoin | Customer, teller | Device, card or paper | Supervisor if on paper | Mint guard; buffer must cover funds in transit; daily issuance cap |
| Redeem stablecoin to deposit | Customer, teller | Device, card or paper | Supervisor if on paper | None |
| Reverse a disputed operation | Back office | | Compliance | What is still in the recipient's account |

**Branch approval ladder.** There is no amount cap at a branch; the number of approvers grows with the amount.

| Amount | Device or card | Paper |
|---|---|---|
| Up to 50,000 | Teller alone | Teller and supervisor |
| Up to 500,000 | Teller and supervisor | Teller, supervisor and branch manager |
| Above 500,000 | Teller, supervisor and branch manager | Teller, supervisor, branch manager and compliance |

### Products

| Action | Initiated by | Customer authorisation | Second approval | Limit |
|---|---|---|---|---|
| Pay into or withdraw from a savings account | Customer, teller | Device, card or paper | Supervisor if on paper | |
| Propose loan | Credit officer | Customer accepts | Supervisor | Per-customer cap, total lending cap, capital and liquidity ratios |
| Loan write-off | Governance | | Multi-signature and time lock | Against the loss allowance; any shortfall charged to equity |
| Propose savings and loan rates | Treasury | | Governance | |
| Propose loss allowance rates | Risk | | Governance | |

### Scheduled work

The scheduler says when; the contracts decide what, to whom and how much. A trigger that arrives late catches up, and one that arrives twice does nothing.

| Action | Triggered by | Decided by the contracts | Runs |
|---|---|---|---|
| Pay savings interest | Scheduler | The amount, from the savings rate and the vault's balance | Once per day |
| Collect a loan instalment | Scheduler | Amount and date, from the loan, under the borrower's mandate; a failed collection sets the loan's status and loss allowance | Once per instalment |
| Pay a standing order | Scheduler | Payee, amount and date, from the mandate | Once per due date |
| Close the day | Scheduler | The next business date | Forward only, one day at a time |

### Reserve, cash and infrastructure

| Action | Initiated by | Second approval | Limit |
|---|---|---|---|
| Issue cash to drawer or ATM | Vault custodian | Supervisor | |
| Count cash and record the count | Vault custodian | Supervisor | |
| Bank surplus cash to the settlement account | Vault custodian | Supervisor | |
| Move funds between the settlement account and liquid securities | Treasury | Finance | Liquidity ratio |
| Top up the reserve buffer | Treasury | Finance | |
| Return reserve released by redemptions | Custodian, under a standing instruction | None | Up to the amount burned |
| Withdraw excess reserve | Treasury | Governance | Above target only |
| Reconcile, prepare the balance sheet and reserve statement | Finance | None | |
| Enrol or retire ATM and terminals | IT security | Supervisor | |
| Rotate a compromised key | IT security | Risk | |
| Register or replace a partner's signing key | IT security | Governance | |
| Pause | Risk | None | |
| Resume | Governance | Multi-signature and time lock | |
| Revoke a staff member's roles | Role admin for that branch, risk | None; takes effect at once | |
| Grant staff roles | Role admin for that branch | Governance for control and assurance roles | |
| Change limits, thresholds and the capital and liquidity ratios | Governance | Multi-signature and time lock | |
| Deploy or upgrade contracts | Governance | Multi-signature and time lock | |

## Separation of duties

No one person should be able to complete both sides of any of these pairs.

| Conflict | Reason |
|---|---|
| Maker and approver of the same operation | Basic second-person control |
| Taking a paper instruction and approving it | The customer gives no cryptographic consent, so at least two staff must agree, and more as the amount grows |
| Onboarding a customer and transacting for them | Prevents fictitious accounts |
| Recovering an account and transacting for it | A new signer enrolled by staff must not be used by the same staff |
| Relaying a partner's message (adapter) and authorising it (the partner) | A relay must not be able to create money |
| Triggering scheduled work and deciding its amounts | The scheduler's key says when, never how much or to whom |
| Proposing a loan and approving it | Prevents self-approved lending, which here would create money |
| Proposing rates (treasury) and approving them (governance) | Pricing is a business decision with a second look |
| Managing liquid assets and the reserve (treasury) and reconciling them (finance) | The checker of the books must not control the assets |
| Holding cash (vault custodian) and recording its count alone | Cash is an asset the chain cannot see |
| Pausing (risk) and resuming (governance) | An incident stop should not be undone by the same hand |
| Setting limits and operating under them | Limits must bind the people they apply to |
| Enrolling a device (IT security) and using it to transact | Prevents rogue terminals |
| Granting roles and holding them | No one person controls role management |
| Handling a complaint and being its subject | Complaints go to staff not involved in the matter |
| Any business role and internal audit | Assurance must be independent |

## Agent design notes

- Each agent has a persona and only the tools its role permits. The tools call the signer service; agents never see keys.
- The role restrictions in an agent's tool list are a convenience. The contracts are the control, which is what the red-team agent tests.
- The operator can instruct any agent in plain language from the control panel. An instruction is input to the agent, not authority: it changes what the agent attempts, never what the chain allows.
- Scripted roles use the same tools and signer service as AI agents, so any of them can be switched to an AI agent later.
- A fixed set of [adverse scenarios](scenarios.md#adverse-scenarios) scores whether agents stayed within their roles and whether refusals happened where expected.
