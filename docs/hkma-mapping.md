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

The deposit token, savings account and loans are banking business, under the Banking Ordinance (Cap. 155), its rules and the HKMA's Supervisory Policy Manual (SPM). The texts below were read for this project in October 2026; section, rule and paragraph numbers are from them. Where a point rests on a consultation paper, or nothing could be found, the row says so.

### Tokenised deposits

There is no SPM module for tokenised deposits. What the HKMA expects is spread across a circular on distributed ledger technology (DLT), one on tokenised products, and the capital rules for cryptoassets.

| What the HKMA expects | Source | How this design stands |
|---|---|---|
| Taking deposits on a ledger is permitted under the Banking Ordinance | DLT circular, annex para 6 | The deposit token is a deposit taken on a ledger |
| A tokenised claim on a bank gives the same legal rights as the deposit, with nothing that could stop full and timely payment, and no conversion needed to reach those rights | SPM CRP-1 paras 1.3.2, 2.2.2, 2.2.3 | One token is one dollar owed, redeemable at par in cash or by payment out, directly. Terms and legal opinion are not done. |
| Pick the ledger to suit the application. Permissionless networks "need not be ruled out", but a higher-risk choice needs compensating controls, and the bank has little control over open, pseudonymous validators | DLT circular, annex paras 2, 5; CRP-1 para 2.6 | A public layer 2 run by others. The controls are on the token: allow-list, freeze, pause, and no single party able to carry out a high-risk operation. The chain's own consensus is outside the bank's control. This is the design's largest departure from practice: the tokenised deposits launched in Hong Kong went through the HKMA's Supervisory Incubator for DLT, and the HKMA's material on them assumes bank-run or permissioned platforms. |
| Smart contracts fit for purpose: a person decides where judgement is needed; governance over introducing and upgrading contracts; audits before deployment | DLT circular, annex para 3; tokenised products circular, section A | Credit decisions stay with a credit officer and an approver, and the contracts only enforce limits. Upgrades go through governance and a time lock. No audit is performed. |
| Legal risk: settlement finality on a ledger may be less clear-cut than in traditional systems | DLT circular, annex para 4; tokenised products circular, section B | Not addressed. No point of legal finality is defined. |
| Interoperability: a token usable only inside one bank's network adds less value; prefer widely accepted standards | DLT circular, annex para 6 | Standard ERC interfaces. Payments to other banks go through the clearing simulator, not a shared ledger, as in Project Ensemble's first phase, which settles between banks through HKD RTGS. A shared ledger is an [expansion](plan.md#cross-chain). |
| Cybersecurity, private keys, data privacy, including immutability and the transparency of some ledgers | DLT circular, annex paras 7 to 9 | Signer service with a key inventory; no personal data on chain. Balances are public by address; see [conduct](#conduct). |
| Contingency plans for DLT: key loss, forks, congestion and fee spikes, and the ledger unavailable for a time or for good | DLT circular, annex para 10 | A customer's lost devices are the [all devices lost](scenarios.md#customer-mishap) scenario. When the chain is unreachable every channel stops and signed requests wait; see [failure scenarios](architecture.md#failure-scenarios). The indexer keeps balance snapshots. Forks and fees are not simulated, because running the chain is out of scope. |
| Tell customers about DLT risks, whether contracts were audited, legal uncertainty and finality | Tokenised products circular, section B | Not done; there are no customer documents |
| Discuss with the HKMA before launch | Tokenised products circular; strategic review circular | Not applicable to a simulation |

### Prudential rules

| Rule | Source | How it is reflected | What is not done |
|---|---|---|---|
| Capital: common equity tier 1 at least 4.5%, tier 1 6% and total capital 8% of risk-weighted assets, plus buffers that restrict dividends when breached: conservation 2.5% and countercyclical 0.5% for Hong Kong exposures since October 2024 | Cap. 155L ss. 3B, 3G, 3H, 3M, 3Q; HKMA countercyclical buffer announcement | Lending guard: equity over loans net of the loss allowance, at or above a minimum. An unsecured personal loan is weighted 75% if it qualifies as regulatory retail (up to HK$10 million per borrower, in a diversified portfolio) and 100% otherwise, so this ratio treats every loan as unqualified. | One tier of capital; buffers are not separate from the minimum; other assets carry no weight; defaulted loans are not raised to 150% (s. 67) |
| Tokenised assets that meet the classification conditions take the treatment of the asset they represent, from January 2026 | Cap. 155L Part 12, ss. 361, 365; SPM CRP-1 | The bank holds no tokenised assets of others. Its own deposit token is a liability. | |
| Leverage: tier 1 capital at least 3% of exposures | Cap. 155L s. 3Z | Not reflected | Equity over total assets is not checked |
| Liquidity, for a smaller bank (category 2): liquefiable assets at least 25% of one-month liabilities, averaged over each month. Larger banks (category 1) hold high-quality liquid assets for 30 days of stressed outflows instead. | Cap. 155Q rules 4, 7; SPM LM-1 ss. 3.1, 3.2, 6 | Lending guard: settlement balance, cash and liquid securities over deposit tokens, at or above a minimum. The shape is closest to the category 2 ratio, treating every deposit as payable within a month. | Checked at each loan, not averaged; no list of eligible assets or haircuts |
| Tokenised deposits never count as stable retail deposits for the 30-day ratio, and count as wholesale funding if the bank cannot identify every holder at all times | SPM LM-1 Annex 3 para 4 | Every holder is an allow-listed customer, so holders are always known | The 30-day ratio is not used |
| Liquidity risk management: survival period under stress, severe but plausible stress tests, intraday liquidity, a tested contingency funding plan; since January 2026, faster runs through digital channels | SPM LM-2 ss. 2.2, 5.2, 10, 12; HKMA circular on liquidity risk, 7 January 2026 | The [run scenario](scenarios.md#financial-stress): payments queue when the settlement account is short, and treasury sells securities | No survival period, no contingency funding plan, no stress model |
| Central bank liquidity: intraday repo and the discount window against Exchange Fund paper, and a discretionary contingent facility | HKMA liquidity facilities framework | Not modelled; treasury raises liquidity only by selling securities | |
| Large exposures: at most 25% of tier 1 capital to one counterparty or linked group. Connected parties: at most 15% of tier 1 together, 5% for natural persons together, and the lower of HK$20 million or 5% for one natural person. | Cap. 155S rules 44, 87 | Per-customer lending cap, which governance can set as a share of equity | Staff hold accounts, so a loan to staff is to a connected party; no separate limit |
| Loan losses: expected credit loss in three stages under HKFRS 9. Loan grades from pass to loss, at least substandard after three months overdue and doubtful after six. A regulatory reserve from retained earnings when provisions fall below a benchmark. | HKMA guideline on loan classification, para 3; HKMA consultation paper CP 17.02, paras 9 to 11 | A loss allowance by loan status, performing, in arrears or defaulted, which follows the three stages loosely | No expected credit loss model, no five grades, no regulatory reserve. The reserve's mechanism was read only in the consultation paper. |

### Deposit protection and resolution

| Rule | Source | How it is reflected | What is not done |
|---|---|---|---|
| Deposits protected up to HK$800,000 per depositor per bank since 1 October 2024; payout targeted within 7 days; structured deposits, time deposits over five years and virtual assets are not protected; members show the scheme's sign, including on electronic banking | Deposit Protection Scheme Ordinance (Cap. 581); Hong Kong Deposit Protection Board | Each balance is labelled as a deposit or not; the stablecoin is not | No scheme, levy or payout |
| Whether tokenised deposits are protected | Not found. Neither the Deposit Protection Board nor the HKMA has said. | The design treats the deposit token as a deposit, and so as protected | This is an assumption, not an established position |
| Recovery plans with triggers and credible options under capital and liquidity stress; resolution by the HKMA as resolution authority | SPM RE-1 s. 2.1; Financial Institutions (Resolution) Ordinance (Cap. 628) | The dashboard shows when equity is exhausted | No recovery plan; everything after insolvency is legal |

### Not yet read

| Topic | Why it matters |
|---|---|
| Anti-Money Laundering and Counter-Terrorist Financing Ordinance (Cap. 615) and the HKMA's guideline for authorized institutions | Customer due diligence and transaction monitoring are simulated rules, not drawn from these. See open question 5 in the [plan](plan.md#open-questions). |
| The statute text of Cap. 581 and Cap. 628 | Their points above are from HKMA and Deposit Protection Board material, not the ordinances themselves |
| Supervisory reporting returns | The dashboard shows a balance sheet and ratios, not returns in any real format |

## Sources

### Stablecoin

- [HKMA: Stablecoin issuers](https://www.hkma.gov.hk/eng/key-functions/international-financial-centre/stablecoin-issuers/)
- [HKMA: Guideline on Supervision of Licensed Stablecoin Issuers (PDF)](https://www.hkma.gov.hk/media/eng/doc/key-functions/ifc/stablecoin-issuers/Guideline_on_supervision_of_licensed_stablecoin_issuers_eng.pdf)
- [HKMA: Register of Licensees under the Stablecoins Ordinance](https://www.hkma.gov.hk/eng/regulatory-resources/registers/register-of-licensed-stablecoin-issuers/)

### Banking

- [Banking Ordinance (Cap. 155)](https://www.elegislation.gov.hk/hk/cap155), [Banking (Capital) Rules (Cap. 155L)](https://www.elegislation.gov.hk/hk/cap155L), [Banking (Exposure Limits) Rules (Cap. 155S)](https://www.elegislation.gov.hk/hk/cap155S)
- [HKMA circular: Risk management considerations related to the use of DLT, 16 April 2024 (PDF)](https://brdr.hkma.gov.hk/eng/doc-ldg/docId/getPdf/20240416-2-EN/20240416-2-EN.pdf)
- [HKMA circular: Sale and distribution of tokenised products, 20 February 2024 (PDF)](https://brdr.hkma.gov.hk/eng/doc-ldg/docId/getPdf/20240220-10-EN/20240220-10-EN.pdf)
- [HKMA circular: Strategic review of business models amid digital transformation, 9 March 2026 (PDF)](https://brdr.hkma.gov.hk/eng/doc-ldg/docId/getPdf/20260309-1-EN/20260309-1-EN.pdf)
- [HKMA SPM CRP-1: Classification of cryptoassets (PDF)](https://brdr.hkma.gov.hk/chi/doc-ldg/docId/getPdf/20251125-15-EN/CRP-1.pdf)
- [HKMA SPM LM-1: Regulatory framework for supervision of liquidity risk (PDF)](https://brdr.hkma.gov.hk/eng/doc-ldg/docId/getPdf/20251217-7-EN/LM-1.pdf)
- [HKMA SPM LM-2: Sound systems and controls for liquidity risk management (PDF)](https://brdr.hkma.gov.hk/eng/doc-ldg/docId/getPdf/20161125-2-EN/LM-2.pdf)
- [HKMA circular on liquidity risk management, 7 January 2026 (PDF)](https://brdr.hkma.gov.hk/eng/doc-ldg/docId/getPdf/20260107-3-EN/20260107-3-EN.pdf)
- [HKMA SPM RE-1: Recovery planning (PDF)](https://brdr.hkma.gov.hk/eng/doc-ldg/docId/getPdf/20200619-2-EN/20200619-2-EN.pdf)
- [HKMA: Countercyclical capital buffer](https://www.hkma.gov.hk/eng/key-functions/banking/banking-legislation-policies-and-standards-implementation/countercyclical-capital-buffer-ccyb/)
- [HKMA: Hong Kong dollar liquidity facilities framework](https://www.hkma.gov.hk/eng/key-functions/money/liquidity-facility-framework/hong-kong-dollar-liquidity-facility-framework/)
- [HKMA: Guideline on loan classification system (PDF)](https://www.hkma.gov.hk/media/eng/doc/key-functions/banking-stability/banking-policy-and-supervision/regulatory-framework/ma(bs)2aci(app2)_e.pdf)
- [HKMA consultation paper CP 17.02 on regulatory reserve and HKFRS 9 (PDF)](https://brdr.hkma.gov.hk/eng/doc-ldg/docId/getPdf/20170331-5-EN/20170331-5-EN.pdf)
- [HKMA: Project Ensemble, EnsembleTX pilot, 13 November 2025](https://www.hkma.gov.hk/eng/news-and-media/press-releases/2025/11/20251113-3/)
- [Hong Kong Deposit Protection Board: Coverage](https://www.dps.org.hk/en/coverage.html)
