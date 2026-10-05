# Scenarios

What the demo runs, and what each run is meant to show. There are two kinds.

| | Daily operation | Adverse scenario |
|---|---|---|
| Question it answers | What does this bank do? | What stops it going wrong? |
| How it runs | Loops over business days as the baseline | Injected by the operator on top of the baseline, one at a time |
| What success is | The books balance, the day closes, reconciliation matches | The named control fires with the expected outcome |
| Scored | No | Yes, pass or fail |

Both are presets: scripted sequences of [control panel](architecture.md#control-panel) commands, so a run can be replayed identically. Before milestone 5 scripted actors play every role; from then on AI agents play the main ones. The routines and scenarios are the same either way.

A third preset, the [guided tour](#guided-tour), runs some of each in a fixed order as one presentation.

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

Jumping time moves block time, so the resume's time lock opens with it; see [open question 11](plan.md#open-questions). Channel [failures](architecture.md#failure-scenarios) are driven by hand from the control panel and are not scored presets.

### Financial stress

| Scenario | Trigger | Control that fires | What the viewer sees | Passes when | Milestone |
|---|---|---|---|---|---|
| **Lending stopped by the capital ratio** | Loans are drawn until the next one would breach the capital ratio | Lending guard | The capital ratio falls towards its minimum, then a drawdown is refused naming it | The drawdown creates no tokens; a smaller loan within the ratio still goes through | 3 |
| **Loan in arrears** | A borrower's account is empty when instalments fall due | Scheduled collection, loan status and the loss allowance | The collection fails, the loan goes into arrears and then default, the allowance rises and retained earnings fall | Status and allowance move at the set rates and the books balance | 3 |
| **Run on deposits** | Many customers withdraw and pay out at once | Payments queue when the settlement account is short; liquidity ratio | The queue grows, the liquidity ratio falls, treasury sells securities and the queue drains. The bank stays solvent throughout. | No payment is released beyond the settlement balance; every queued payment goes through once funded; lending is refused while the ratio is below its minimum | 3 |
| **Buffer exhausted, then custodian silent** | Conversions outpace the custodian's confirmations. Later the custodian stops confirming. | Funds in transit capped by the buffer; mint guard on a stale confirmation | The reserve panel: funds in transit reach the buffer and conversions are refused; a confirmation restores them; then the confirmation ages out and all issuance stops | Supply never exceeds the confirmed reserve; redemption at par works throughout | 4 |
| **Redemption surge** | Many holders redeem at once, one of them frozen | Conversion at par; funds due from the reserve not counted as liquid | Stablecoin outstanding and the reserve fall together. Funds due back rise, then clear. The frozen holder's redemption is shown as held, with its reason. | Every redemption is at par in one transaction; the custodian returns no more than was burned | 4 |

## Guided tour

The [five-minute pitch](plan.md#1-the-five-minute-pitch) as a preset. It runs the routines and scenarios above in a fixed order, one beat at a time, and waits for the presenter before the next. Each beat makes one claim and puts it on screen.

| # | Beat | Runs | The presenter points at | The claim | Milestone |
|---|---|---|---|---|---|
| 1 | **An ordinary day** | Counter and ATM day | The story view and the waiting strip: cash in, an ATM withdrawal, a paper slip waiting for the supervisor | It reads like a bank, in plain sentences | 2 |
| 2 | **Books that cannot disagree** | One cash deposit from the same routine, opened under the hood | The ledger entry it posted, the two balance sheet rows it highlights, and the invariant strip | The token and the ledger entry are one transaction | 2 |
| 3 | **Try to break it** | Red team | One refusal after another, each with its reason | The chain decides; an agent's instructions are not the control | 2 |
| 4 | **Fraud, with a way back** | Forged paper slip | The scenario card, the transfer waiting for an approver, the freeze, the reversal waiting for compliance, then the pass | No member of staff acts alone, and a wrong is reversed on the record | 2 |
| 5 | **Money creation and stress** | Lending stopped by the capital ratio, then run on deposits | The capital ratio falling to its minimum and the refused drawdown; the payment queue growing, then draining as treasury sells securities | Lending creates money only within limits; a bank can be solvent and still run short | 3 |
| 6 | **Anyone can check the bank** | No preset: any story line under the hood, then the same kind of transaction on the public deployment's block explorer | The signer, role check and transaction; the same checks on a public chain the bank does not run | The bank cannot rewrite its history, and anyone can check it without the bank's help | 6 |

- **It grows with the milestones.** The tour runs the beats the current milestone has reached, so it is four beats long at milestone 2.
- **Not scored as a whole.** The adverse scenarios inside it are scored as usual and their cards show pass or fail.
- **Beat 3 from milestone 5.** The presenter can also type an instruction of their own to an agent, for example "approve your own operation", and watch it refused.
- **Beat 6 is online.** The tour runs on the local chain; beat 6 opens the public deployment and needs a connection. The first five run offline.
- **The stablecoin is left out.** Its scenarios are a follow-up for an audience that asks, not part of the five minutes.

## Opening balance sheet

The seed every run starts from, in Hong Kong dollars. It is tuned so that the [financial stress](#financial-stress) scenarios reach their limits within a few actions while daily operation stays clear of them.

| Assets | | Liabilities and equity | |
|---|---|---|---|
| Settlement account | 1,000,000 | Deposits | 12,300,000 |
| Cash | 500,000 | Equity | 907,000 |
| Liquid securities | 2,500,000 | | |
| Loans | 9,300,000 | | |
| Loan loss allowance | −93,000 | | |

It opens at a capital ratio of 9.85% against a minimum of 8%, and a liquidity ratio of 32.5% against 25%. Tour beat 5 then runs:

| Step | Capital | Liquidity | Outcome |
|---|---|---|---|
| Loans of 500,000, one by one | 9.29%, 8.79%, 8.34% | 31.3%, 30.1%, 29.0% | All three drawn |
| A fourth loan of 500,000 | Would be 7.92% | | Refused, naming capital |
| A loan of 300,000 | 8.08% | 28.4% | Drawn |
| Ten customers pay out 150,000 each at the counter | Unchanged | 23.5% after six are paid | Four queue; lending is refused naming liquidity |
| Treasury sells 600,000 of securities | Unchanged | Unchanged | The queue drains; liquidity ends at 19.8% |

Lending stays stopped after the run until payments in or repayments lift liquidity back over its minimum.

The run's payments go through a teller on each customer's own device, each approved by the supervisor as the [branch approval ladder](roles.md#branch-approval-ladder) requires at 150,000, because the app limit would refuse them first. Each loan is to a different borrower, within the 600,000 per-customer cap, and the total lending cap of 12,000,000 is above the 11,100,000 the beat reaches, so in both cases the ratio, not a [limit](roles.md#limits), is what stops the bank.

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
| Conflicting roles | Left to tests |
| High-risk changes | Pause and resume |
| Request checked before sending | Every refusal in the story view is reported by the submission service |
