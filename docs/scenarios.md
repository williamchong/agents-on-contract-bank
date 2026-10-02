# Scenarios

What the demo runs, and what each run is meant to show. There are two kinds.

| | Daily operation | Adverse scenario |
|---|---|---|
| Question it answers | What does this bank do? | What stops it going wrong? |
| How it runs | Loops over business days as the baseline | Injected by the operator on top of the baseline, one at a time |
| What success is | The books balance, the day closes, reconciliation matches | The named control fires with the expected outcome |
| Scored | No | Yes, pass or fail |

Both are presets: scripted sequences of [control panel](architecture.md#control-panel) commands, so a run can be replayed identically. Before milestone 5 scripted actors play every role; from then on AI agents play the main ones. The routines and scenarios are the same either way.

A milestone in the [plan](plan.md#milestones) is done when its daily routines run and its adverse scenarios pass.

## Daily operation

The bank at work, with the controls passing quietly. A daily run loops through every routine up to the current milestone and closes each business day.

| Routine | What happens | What the viewer sees | Milestone |
|---|---|---|---|
| **Counter and ATM day** | Customers pay cash in at the counter, withdraw at the ATM, and transfer from the app, by card at the counter and on a paper slip. A larger transfer climbs the approval ladder. | One story line per movement. The paper slip waits for the supervisor, the ATM withdrawal waits for the dispense. Cash and deposits move together on the balance sheet. | 2 |
| **Payments day** | A customer pays a registered payee at another bank. Another receives a payment from someone who was never registered. The day closes and finance reconciles the clearing system's statement. | The settlement account and deposits move together. The reconciliation line reports a match. | 2 |
| **Staff and device changes** | A teller leaves: their roles are revoked at once and a replacement is granted them. A customer loses a phone, revokes it from another device and enrols a new one. | The bank map changes. No account address, balance or history does. | 2 |
| **Lending and savings** | A credit officer proposes a loan, a supervisor approves, the customer accepts and it is drawn. Instalments are collected, savings interest is paid each day and a standing order runs. | Loans and deposits rise together at the drawdown. The income statement fills in. The ratios stay above their minimums. | 3 |
| **Rate change** | Treasury proposes new savings and loan rates and governance approves. | The proposal waits for governance, then applies. Loans already drawn keep their rate. | 3 |
| **Stablecoin day** | Customers convert deposits to stablecoin and back. The custodian confirms the funds sent to the reserve. | The reserve panel: funds in transit rise with each conversion and clear on the confirmation, which restores the buffer. | 4 |

## Adverse scenarios

Each one is aimed at a control in the [controls table](architecture.md#controls). While it runs, the dashboard pins a [scenario card](architecture.md#dashboard) naming the control and the expected outcome.

### Customer mishap

| Scenario | Trigger | Control that fires | What the viewer sees | Passes when | Milestone |
|---|---|---|---|---|---|
| **All devices lost** | A customer reports every device and their card lost | Recovery module: an account opening officer with a supervisor's approval, signer list only | The recovery waits for the supervisor, then the customer is notified through every contact | The old signers are gone and a new one enrolled; the address and balance are unchanged; no money moved | 2 |
| **ATM fails to dispense** | The ATM reports a failed dispense after the amount was held. A second run has it report nothing. | ATM hold and confirmation | The amount waits as pending, then returns. In the second run it stays pending and flagged until the next cash count. | The customer's balance is restored in full and ATM cash is unchanged | 2 |
| **Payment rejected** | The receiving bank rejects a payment out | Payments module checks the clearing system's signed rejection | The payment leaves, the rejection arrives, the tokens are re-created | The customer's balance and the settlement account are back where they started | 2 |
| **Unknown beneficiary** | A payment arrives for an account that does not exist | Suspense account in the payments module | The funds wait in suspense, then return to the sender | No customer is credited; suspense is empty after the return | 2 |

### Fraud and attack

| Scenario | Trigger | Control that fires | What the viewer sees | Passes when | Milestone |
|---|---|---|---|---|---|
| **Forged paper slip** | A teller submits a transfer on a slip the customer never signed. The customer is notified and disputes it. | Second-person approval, then freeze and dispute reversal by forced transfer | The transfer waits for an approver. After the dispute the recipient's funds are frozen and the reversal waits for compliance. | The teller alone cannot complete the transfer; the reversal returns the money; the teller, approver and slip hash are on record | 2 |
| **Red team** | A run of attempts: approve its own operation, call the forced transfer directly, exceed the app limit, replay a used authorisation, send to an account that is not onboarded, pay an unregistered payee above the small limit, act at this branch with a teller role for another | Access manager, branch scoping, approval logic, rate limiter, one-use numbers, allow-list, payee register | One refusal after another, each with its reason | Every attempt is refused and no balance changes | 2 |
| **Forged credit advice** | The partner adapter relays a credit advice not signed by the clearing system's registered key, then replays a genuine one | Signature check and unique reference in the payments module | Two refusals naming the partner key and the repeated reference | Neither message creates deposit tokens | 2 |
| **Flagged payment in** | An incoming payment trips screening. Run twice: compliance clears one and returns the other. | Screening, a named compliance hold, compliance clearance | The payment is credited and frozen, and waits for compliance | The customer cannot spend the amount until it is cleared; the returned one leaves the settlement account | 2 |

The red-team attempts are a fixed script until milestone 5, when the red-team agent adds its own.

### Operational incident

| Scenario | Trigger | Control that fires | What the viewer sees | Passes when | Milestone |
|---|---|---|---|---|---|
| **Ledger mismatch** | The clearing system's statement or a cash count differs from the ledger | Reconciliation by finance | The reconciliation line fails, the figure is marked on the balance sheet, an incident goes to the regulator | The incident is recorded and reported | 2 |
| **Pause and resume** | Risk pauses during an incident, then tries to resume | Pause by risk; resume only by governance multi-signature and time lock | Every movement is refused as paused. The resume waits for its signatures, then its time lock. | Nothing moves while paused; risk cannot resume; the resume takes effect only after the wait | 3 |
| **Network failures** | The operator stops nodes, splits the network or cuts a link | Consensus quorum and channel isolation. See [failure scenarios](architecture.md#failure-scenarios). | The network panel; transactions queue and then go through | Nothing is lost or forked | 6 |

Pause and resume depends on how scenario time maps onto time locks, which is [open question 11](plan.md#open-questions). Network failures are driven by hand from the control panel and are not scored presets.

### Financial stress

| Scenario | Trigger | Control that fires | What the viewer sees | Passes when | Milestone |
|---|---|---|---|---|---|
| **Lending stopped by the capital ratio** | Loans are drawn until the next one would breach the capital ratio | Lending guard | The capital ratio falls towards its minimum, then a drawdown is refused naming it | The drawdown creates no tokens; a smaller loan within the ratio still goes through | 3 |
| **Loan in arrears** | A borrower's account is empty when instalments fall due | Scheduled collection, loan status and the loss allowance | The collection fails, the loan goes into arrears and then default, the allowance rises and retained earnings fall | Status and allowance move at the set rates and the books balance | 3 |
| **Run on deposits** | Many customers withdraw and pay out at once | Payments queue when the settlement account is short; liquidity ratio | The queue grows, the liquidity ratio falls, treasury sells securities and the queue drains. The bank stays solvent throughout. | No payment is released beyond the settlement balance; every queued payment goes through once funded; lending is refused while the ratio is below its minimum | 3 |
| **Buffer exhausted, then custodian silent** | Conversions outpace the custodian's confirmations. Later the custodian stops confirming. | Funds in transit capped by the buffer; mint guard on a stale confirmation | The reserve panel: funds in transit reach the buffer and conversions are refused; a confirmation restores them; then the confirmation ages out and all issuance stops | Supply never exceeds the confirmed reserve; redemption at par works throughout | 4 |
| **Redemption surge** | Many holders redeem at once, one of them frozen | Conversion at par; funds due from the reserve not counted as liquid | Stablecoin outstanding and the reserve fall together. Funds due back rise, then clear. The frozen holder's redemption is shown as held, with its reason. | Every redemption is at par in one transaction; the custodian returns no more than was burned | 4 |

## Coverage

Every row of the [controls table](architecture.md#controls), and where it is shown.

| Control | Shown by |
|---|---|
| Role required for each function | Red team |
| Branch scoping | Red team |
| The books balance | Every daily routine; ledger mismatch |
| Lending within the capital and liquidity ratios | Lending stopped by the capital ratio; run on deposits |
| Stablecoin within the confirmed reserve | Buffer exhausted, then custodian silent |
| Money created against an outside credit, and attested figures | Forged credit advice; payment rejected; ledger mismatch |
| Scheduled work | Lending and savings; loan in arrears. That a repeated trigger does nothing is left to tests. |
| Limits by channel, customer-set limits, daily stablecoin issuance cap | Counter and ATM day; red team. The issuance cap is left to tests. |
| Second-person approval | Counter and ATM day; forged paper slip; red team |
| Only onboarded customers can hold either token | Red team |
| Payments out above a small limit only to registered payees | Payments day; red team |
| Movement without the customer's signature | Counter and ATM day; forged paper slip; red team |
| Signer changes without the customer's signature | All devices lost |
| Freezes and block-listing | Flagged payment in; forged paper slip. Block-listing is left to tests. |
| Stablecoin redemption at par, at once | Stablecoin day; redemption surge |
| Immediate stop | Pause and resume |
| Immediate removal of a staff member's authority | Staff and device changes |
| High-risk changes | Pause and resume |
| Request checked before sending | Every refusal in the story view is reported by the submission service |
