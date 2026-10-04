# HKMA mapping

The bank issues two kinds of money, which fall under two sets of rules.

- **The deposit token** is a bank deposit. It falls under banking rules, summarised under [banking side](#banking-side).
- **The stablecoin** follows Hong Kong's stablecoin issuer regime: the Stablecoins Ordinance (Cap. 656) and the HKMA Guideline on Supervision of Licensed Stablecoin Issuers (August 2025). Paragraph numbers below refer to that guideline, which was read in full. Everything from [requirements reflected](#requirements-reflected) to [if the token leaves the perimeter](#if-the-token-leaves-the-perimeter) is about the stablecoin only.

This is a design mapping, not a compliance assessment. The separate HKMA guideline on anti-money laundering for stablecoin issuers has not been read.

## Why two monies under two regimes

| | Deposit token | Stablecoin |
|---|---|---|
| What the holder owns | A deposit: an unsecured claim on the bank | A right to redeem at par, backed by a segregated reserve |
| What backs it | The bank's whole balance sheet, mostly loans | Cash and short bills held apart from the bank's assets |
| Who can hold it | The bank's own customers | In the regime's design, anyone; here, customers only |
| Interest | Allowed | Forbidden (2.6.1) |
| How it fails | A run, or credit losses | A reserve shortfall, or a de-peg in secondary markets |
| What the rules require | Capital, liquidity, deposit protection | Full backing, segregation, prompt redemption |

## How this design differs from the regime's assumptions

- **Closed perimeter.** The guideline assumes a token that circulates on open ledgers among holders who may not be customers. Here the token sits on a public chain, but its allow-list admits only onboarded customers, so every holder is one.
- **The issuer is a bank.** For a licensee that is an authorised institution, the capital, liquidity and other-business rules give way to the Banking Ordinance (4.1.3, 5.1.3, 5.2.2). Deposits and lending are that other business, and here they are the main business.
- **Issued only against a deposit.** The guideline pictures funds arriving from outside. Here a customer converts their own deposit balance, and the bank moves the matching funds into the reserve.
- **A stablecoin beside deposits.** The stablecoin pays no interest. Interest is paid on deposits, which are a different product under banking rules. Whether a regulator would accept both from the same issuer, or see the deposit as an "interest-like incentive" (2.6.1) for holding the stablecoin, is a legal question this project does not answer.

## Requirements reflected

### Reserve

| Requirement | Para | How it is reflected |
|---|---|---|
| Market value of reserve at least equal to tokens outstanding, at all times | 2.2.1 | Mint guard refuses issuance above the reserve the custodian last confirmed |
| Appropriate over-collateralisation as a buffer | 2.2.1, 6.4.5 | The bank funds a buffer above full backing; conversions are issued against it while funds are in transit |
| Regular reconciliation of reserve against tokens outstanding | 2.2.1 | Finance reconciles the ledger with the custodian's signed statements; issuance stops if confirmation is stale |
| Frozen tokens remain fully backed | 2.2.3 | Freezing restricts movement and leaves the reserve untouched |
| Reserve in high-quality liquid assets | 2.3.1 | Modelled as cash, short deposits and short government bills at the custodian |
| Reserve segregated from the issuer's own assets, held by a qualified custodian | 2.5.1, 2.5.4 | Reserve sits with a separate custodian party, apart from the bank's own securities, and in its own book outside the bank's general ledger, which carries only the bank's own surplus, ranking behind holders; funds count only once the custodian confirms them |
| Excess transferred to the issuer by a defined mechanism, excess only | 2.5.3 | Withdrawal is possible only above the target level and needs governance |
| No interest on the stablecoin; reserve income belongs to the issuer | 2.6.1 | The token pays nothing; reserve yield goes to the bank |
| Daily statements of tokens outstanding and reserve; weekly report and publication | 2.7.2 | Finance prepares daily; the reserve panel shows it; the regulator script receives it weekly |
| Independent attestation, including a randomly selected day | 2.7.3 | External auditor script |
| Unresolved reconciliation discrepancies reported at once | 2.7.5 | A mismatch raises an incident to the regulator script |

### Issuance and redemption

| Requirement | Para | How it is reflected |
|---|---|---|
| Issue only to customers, promptly on receiving funds, matched by a reserve increase | 3.2.1 | Issuance only by converting a customer's own deposit balance, with the matching funds sent to the reserve |
| Redemption at par, within one business day | 3.3.1, 3.3.3 | Redemption credits the holder's deposit account at par in the same transaction |
| Reserve draw-down matched by a decrease in tokens outstanding | 3.3.5 | Tokens are burned in the same step; the custodian returns to the bank no more than the amount burned |
| Customer onboarding and due diligence before issue and redemption | 3.5.1 | Only onboarded customers hold a deposit account to convert from; onboarding is a distinct role with a second check |
| Delay to redemption only with the regulator's consent | 6.8.21 | A pause or freeze leaves a redemption shown as held, with its reason, not silently extended |

### Risk management and governance

| Requirement | Para | How it is reflected |
|---|---|---|
| Three independent lines of defence | 6.2.3 | [Roles](roles.md#three-lines-of-defence) |
| Internal limits on credit, liquidity and market risk of the reserve, with breach response | 6.4.2 to 6.4.5 | Treasury operates within risk limits; a breach raises an alert |
| Stress tests on severe but plausible scenarios | 6.4.6 | The [financial stress](scenarios.md#financial-stress) scenarios: a redemption surge, and the buffer exhausted with the custodian silent |
| Stablecoin manager appointed where the licensee is a bank | 7.1.5, 7.2.3 | A named governance signer |
| Compliance and internal audit independent of the business | 7.1.6 to 7.1.9 | Separate roles; internal audit is read-only |
| Conflicts of interest managed through segregation of duties | 7.1.11 | [Separation of duties](roles.md#separation-of-duties) |

### Technology

| Requirement | Para | How it is reflected |
|---|---|---|
| Document token standards, ledgers and contract architecture | 6.5.2 | [Standards](standards.md), [architecture](architecture.md) |
| An authorisation level for every token lifecycle operation; no single party for high-risk ones | 6.5.3 | Permission matrix covers deploy, upgrade, mint, burn, pause, resume, freeze, block-list, allow-list; high-risk ones need multi-signature |
| Velocity limits, minting only to allow-listed addresses, time locks, simulation before broadcast | 6.5.3 | Rate limiter, allow-list, time lock, submission service simulation |
| Duties split between staff; immediate revocation; no one in full control of role management | 6.5.4 | Granting needs a second party; revoking is immediate |
| Assess the ledger's consensus, fault tolerance and finality | 6.5.5 | [Network](architecture.md#network): a public layer 2 run by others, which posts its data to Ethereum |
| Monitor the ledger's availability and report failures | 6.5.6 | When the chain is unreachable, every channel stops and signed requests wait; the dashboard says so |
| Key management across the full lifecycle; elevated standards for significant keys | 6.5.7 | Signer service with inventory, usage and failure logs, rotation; significant keys, including partners' signing keys, behind governance |
| Signers can interpret what they approve | 6.5.7(vii) | Typed signatures shown in readable form |
| Funds and tokens only to and from pre-registered accounts in the customer's name | 6.5.9 | Funds for issue and redemption move only from and to the customer's own deposit account at the bank; token only to allow-listed customer accounts. Ordinary payments on the deposit side are open to any payer and payee, as banking is. |
| Two-factor authentication on account operations, with a notification | 6.5.10 | Passkey or card with PIN; a notification after each operation |
| Limit the number of bound devices | 6.5.10 | Device cap per account |
| All customer transactions logged; customers can review them | 6.5.11 | The ledger and the customer's history view |
| Monitoring for fraud; customers can set their own limits | 6.5.12 | Transaction monitoring script; customer-set limits |
| Network segmented into zones, single points of failure minimised | 6.5.18 | Channel zones. The chain's own redundancy rests with its operators. |

### Incidents and continuity

| Requirement | Para | How it is reflected |
|---|---|---|
| Incident classification, detection and response | 6.8.2 to 6.8.4 | Risk can pause at once; resuming needs governance; the pause and resume [scenario](scenarios.md#operational-incident) exercises it |
| Back-up records to allow redemption if the ledger fails irrecoverably | 6.8.7 | Periodic off-chain balance snapshots; every node following the public chain holds a full copy |
| Continuity of critical functions; alternate sites | 6.8.9, 6.8.15 | Channels fail independently and can be stopped and restored; the chain's continuity rests with its operators |
| Regular testing and simulation exercises | 6.8.19 | Replayable, scored [adverse scenarios](scenarios.md#adverse-scenarios) |

### Conduct

| Requirement | Para | How it is reflected |
|---|---|---|
| Records of on-chain and off-chain activity with audit trails | 8.1.1 | Indexer timeline including refusals and operator actions |
| Personal data protection | 8.3.1 | No personal data on chain; names released only by role. Balances are public by address, which a real bank would avoid with its own chain or a privacy layer. |
| Complaints handled by staff not involved, within set times | 8.4.2, 8.4.3 | Support logs and follows complaints; disputed operations can be frozen and reversed |

## Not done

| Requirement | Para | Position |
|---|---|---|
| Trust arrangement over the reserve, with legal opinion | 2.5.2 | The custodian is a simulated party; no legal structure is modelled |
| Holders' rights on insolvency | 3.3.1, 3.3.2 | Legal, not technical |
| Third-party distribution, secondary markets, de-pegging | 3.4, 6.8.6 | Not applicable in a closed perimeter; see below |
| Jurisdiction controls and location spoofing | 3.5.2, 3.5.3 | Onboarding is in person; see below |
| Capital, liquid assets | 5 | Governed by banking rules for a bank; see [banking side](#banking-side) |
| Smart contract audit, annually and on change | 6.5.5 | No audit is performed. Several dependencies are drafts or community contracts. |
| Air-gapped storage and physical security of significant keys | 6.5.7 | The signer service is software |
| Security operations: patching, intrusion detection, penetration tests, change management | 6.5.14 to 6.5.19 | Not modelled |
| Third-party risk management | 6.6 | Not modelled |
| Business exit plan | 6.8.17 | Not modelled |
| Board composition, fitness and propriety | 7.1.2, 7.2 | Out of scope |
| White paper | 8.2.3 | These documents are the nearest equivalent |
| Sanctions screening and travel rule | Separate guideline | Simulated by the compliance role |

## If the token leaves the perimeter

Opening the stablecoin to holders who are not customers, on this chain or another, is a planned [expansion](plan.md#cross-chain), not part of this design. It would bring these requirements into play:

| Requirement | Para | What it would need |
|---|---|---|
| Full backing across everything outstanding | 2.2.1 | Supply on all chains counted against the one reserve |
| Issue and redeem only with customers | 3.2.1, 3.5.1 | Issuance for money stays on the home chain; holders elsewhere redeem by becoming customers |
| Terms that bind all holders, customers or not, including hard forks and when a transfer is final | 3.6.1 | Published terms covering each chain |
| Distribution through third parties, and unlawful jurisdictions | 3.4, 3.5.2 | Controls on who offers the token on the shared chain |
| Every lifecycle operation authorised, on every chain | 6.5.3 | The same freeze, block-list and pause on each chain; the cross-chain attesters treated as significant keys |
| Assessment of each ledger used | 6.5.5 | A second assessment for the shared chain's consensus, finality and track record |
| Watching for wrapped copies issued by others | 6.7.2 | Monitoring, and bridging only through the bank's own burn-and-issue link |
| De-pegging in secondary markets | 6.8.3, 6.8.6 | Price monitoring and a response plan |

## Banking side

The deposit token, savings account and loans are banking business. The rules for it have not been read for this project; this section is from general knowledge of how banks are regulated and names where a real design would have to look. No paragraph numbers are given because none were checked.

| What banking rules ask for | How it is reflected | What is not done |
|---|---|---|
| Books that record every asset and liability | A double-entry general ledger on chain; deposit tokens exist only with a balanced entry | Assets held off chain are taken on signed attestation |
| Capital in proportion to risk | Lending guard: equity over loans net of the loss allowance at or above a minimum | No risk weights, capital tiers or buffers |
| Income and losses recognised as they arise | Interest booked when collected; a loss allowance by loan status | No daily accrual, no expected credit loss model |
| Liquid assets to meet outflows | Lending guard: liquid assets over deposits at or above a minimum; payments queue when the settlement account is short | No stressed outflow assumptions, no central bank facility |
| Limits on large exposures | Per-customer lending cap | No connected-party rules |
| Deposit protection | Balances are labelled as deposits or not | No scheme, levy or payout |
| Tokenised deposits to carry the same rights as ordinary deposits | One token is one dollar owed, redeemable in cash or by payment out at par | Terms and legal opinion |
| Customer due diligence and transaction monitoring | Onboarding with a second check; screening on payments in and out | Simulated rules only |
| Segregation of duties and audit trail | [Roles](roles.md#separation-of-duties); every action signed by a named person | |
| Supervisory reporting | Balance sheet and ratios on the dashboard; the regulator reads the public chain directly | No returns in any real format |
| Resolution and insolvency | The dashboard shows when equity is exhausted | Everything that follows is legal |

## Sources

- [HKMA: Stablecoin issuers](https://www.hkma.gov.hk/eng/key-functions/international-financial-centre/stablecoin-issuers/)
- [HKMA: Guideline on Supervision of Licensed Stablecoin Issuers (PDF)](https://www.hkma.gov.hk/media/eng/doc/key-functions/ifc/stablecoin-issuers/Guideline_on_supervision_of_licensed_stablecoin_issuers_eng.pdf)
- [HKMA: Register of Licensees under the Stablecoins Ordinance](https://www.hkma.gov.hk/eng/regulatory-resources/registers/register-of-licensed-stablecoin-issuers/)
