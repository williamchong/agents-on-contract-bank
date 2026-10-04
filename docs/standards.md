# Standards and contracts

The rule: adopt a standard where it is widely used and replaces code that would otherwise be written here. Write only bank-specific logic.

OpenZeppelin Contracts is the single base (v5.7.0 at the time of writing, MIT licence), with a few pieces from the OpenZeppelin community library. The contracts named below were read in source to confirm what they do, except where marked "not yet read".

## Used

### Access and governance

| Need | Standard or contract | Library | Notes |
|---|---|---|---|
| Role required per function | `AccessManager`, `AccessManaged` | Main | Roles are numbers scoped per contract function, each with its own admin and optional delays |
| Branch scoping | `AccessManager` roles | Main | "Teller at branch 1" is its own role; a branch's role admin grants only within the branch |
| Time lock on high-risk changes | `TimelockController` | Main | Sits behind the officers' multi-signer account |
| Immediate stop | `Pausable`, `ERC20Pausable` | Main | |

### Tokens

The deposit token and the stablecoin share one base, so accounts, limits, freezes and tooling treat them alike. They differ only in what may create them.

| Need | Standard or contract | Library | Notes |
|---|---|---|---|
| Token | ERC-20: `ERC20`, `ERC20Burnable` | Main | Standard tooling works unmodified |
| Customer-signed movement submitted by a teller or ATM | EIP-3009: `ERC20TransferAuthorization` | Main | One-use number and validity window. Accepts signatures from smart accounts. |
| Typed, readable signatures | EIP-712: `EIP712` | Main | Lets a signer see the meaning of what is signed |
| Freezes, allow-list, block-list and movement without the holder's signature | ERC-7943: `ERC20uRWA` | Community | One contract for all three, built on `ERC20Freezable` and `ERC20Restricted`. The standard is final. See the notes below. |
| Channel and customer-set limits | `RateLimiter` | Main | Rolling-window cap with an independent counter per key; the key is the account and the channel |

What reading `ERC20uRWA` settled:

- **Allow-list.** The default is a block-list. Overriding `canTransact` to require an explicit allow makes it an allow-list, as the contract's own comment shows. Bank-owned accounts and the savings vault must be on it too.
- **Who may force a transfer or freeze** is left to two hooks, `_checkEnforcer` and `_checkFreezer`, which are wired to the access manager here.
- **A forced transfer cuts through a freeze.** It skips the sender's restriction and lowers the frozen amount to fit. That is right for a dispute reversal and wrong for a paper instruction, so the paper and support modules check the unfrozen balance themselves before calling it.
- **The recipient is still checked.** A forced transfer to an account that is not allow-listed fails.
- **One frozen amount per account, overwritten on each call.** It cannot tell a compliance hold from a dispute hold, and two staff setting it at once would race. A small register of named holds, written here, sets the token's figure to their sum.
- **Operational holds are not freezes.** An ATM withdrawal or a pending payment moves the amount to a bank-owned pending account under the customer's own authorisation, and returns it on failure.
- **Mint and burn are not provided** and must apply the same checks. Burning from a frozen or blocked account goes through a forced transfer to a bank-owned account first.
- **It needs transient storage**, so the chain must run the Cancun rules or later and Solidity 0.8.26 or later.
- **Savings shares need the same treatment**, or a freeze or dispute reversal could not reach money a customer has moved into the savings account. The savings vault's share token takes the same extension.

| Token | What may create it | Standard or contract | Library | Notes |
|---|---|---|---|---|
| Deposit token | A balanced entry in the general ledger | Written here | | Creation and destruction are open only to the ledger contract |
| Stablecoin | Conversion from a deposit, within the reserve | `ERC20Collateral`, with `RateLimiter` for the daily issuance cap | Community, main | Refuses issuance above a reported collateral figure, and when that figure is stale |

Withdrawals and outgoing payments use the same signed authorisation as transfers: the customer authorises a transfer to a bank-owned account, and the ledger destroys the tokens from there.

### Products

| Need | Standard or contract | Library | Notes |
|---|---|---|---|
| Savings account | ERC-4626: `ERC4626` | Main | A vault of deposit tokens; shares grow in value as the bank pays interest in |
| Standing orders | A mandate signed with EIP-712, checked on each payment | Written here | No widely used standard fits a recurring payment under a mandate |

### Accounts and signatures

| Need | Standard or contract | Library | Notes |
|---|---|---|---|
| Account with several devices | `Account`, `MultiSignerERC7913` | Main | Mixed signer types with a threshold; covers corporate signing mandates. Signer changes are open to the account itself and to the recovery module. |
| Passkey devices and chip cards | WebAuthn and P-256: `SignerWebAuthn`, `WebAuthn`, `P256` | Main | Includes a contract verifier, so no chain-level support is required |
| Signature checks for smart accounts | ERC-1271, ERC-7913: `SignatureChecker` | Main | Also checks partners' signatures on payment messages and statements. The ERC-7913 verifiers for their key types are not yet read. |
| Bank-owned accounts controlled by a role | `RoleAccount`, `SignerAccessManaged` | Community | Control follows role membership live; each signature names the individual |

Accounts built on `Account` are compatible with ERC-4337, though the bundler flow is not used here.

### Outside the contracts

| Need | Standard or tool |
|---|---|
| Chain | Any EVM chain with the Cancun rules: a local single-process chain, and Base Sepolia for the public deployment. See [network](architecture.md#network). |
| Explorer | The public chain's own block explorer |
| Indexing | A standard indexing framework, to be chosen |
| Payment messages and statements | ISO 20022 message shapes and field names |

## Written here

1. **General ledger.** Double-entry accounts for assets, liabilities and equity; the only contract that may create or destroy deposit tokens; attested figures for assets held off chain, their signatures and their freshness; the loss allowance; the capital and liquidity ratios and the lending guard.
2. **Operations.** Cash deposit and withdrawal with the ATM hold and confirmation, cash counts.
3. **Payments.** Payments in and out through the clearing system, the check of its signature on each credit and rejection, registered payees, the queue when the settlement account is short, suspense, mandates for standing orders.
4. **Assisted operations.** Acting on a paper instruction at a branch, with the approval ladder and the slip hash recorded.
5. **Other bank-initiated movement.** Support moves between a customer's own accounts and dispute reversal, each wired to the forced transfer. Also the register of named holds behind the token's single frozen amount.
6. **Account recovery.** The one module allowed to change a customer account's signers, and nothing else.
7. **Second-person approval.** Amount-based, with the approver required to differ from the maker.
8. **Rates and interest.** Bank-set savings and loan rates; paying savings interest into the vault.
9. **Lending.** Loans that create deposit tokens through the ledger, instalments, arrears and the loan status the allowance follows, write-off.
10. **Stablecoin conversion and reserve bookkeeping.** Conversion at par both ways, confirmed reserve at the custodian, buffer, funds in transit, funds due back after redemptions, the bank's surplus, excess-only withdrawal, and the function that reports the reserve to the mint guard.
11. **Partner keys.** The register of partners' signing keys that the payments module and the ledger check against.
12. **Scheduled work.** Trigger-only entry points that run what is due once per period, and the business date the contracts read.

## Considered and not used

| Standard or project | Why not |
|---|---|
| **A stablecoin as the only money** | The earlier design. A fully reserved token cannot be created by lending, so the result is a payment account beside a lender, not a bank. The stablecoin is kept as a product beside the deposit. |
| **A tokenised deposit with the balance sheet kept off chain** | A bank record on a chain, backed by books the chain cannot see. The general ledger is put on chain instead, with only the assets held outside it taken on attestation. |
| **Algorithmic interest rates and floating-yield vaults** | The bank sets its savings and loan rates as business decisions and stands between depositors and borrowers. |
| **ERC-7540 notice period on savings withdrawals** | The savings vault holds the deposit tokens themselves, so a withdrawal never waits on the vault. Liquidity is managed for the bank as a whole, at the settlement account. |
| **ERC-4337 bundler flow** | Solves paying gas for others through an open market of relayers. The submission service already relays every signed request and pays its gas, and a second relay makes "who signed" and "why refused" harder to show. Can be added later without changing accounts. |
| **Hyperledger Besu, permissioned, with QBFT consensus** | The usual choice for a bank's own chain, with balances private to the bank and validators at its own sites. A production bank would likely choose it, mainly for ledger privacy. Nobody would deploy this demo on one, and a public deployment lets a reviewer check it from a link without running anything. |
| **Verifiable credentials and credential exchange (OpenID4VC)** | Not yet widely used in bank production systems. Adds an issuer service and a second source of truth for roles. |
| **DID documents, methods and resolvers** | Interoperability with outside wallets is never exercised in a closed simulation. |
| **Safe smart accounts** | More widely deployed for institutional custody, and a sound production alternative. Not used so that accounts, token and access share one base. |
| **ERC-3643 permissioned token** | Bundles identity checks, freezing and forced transfers, but is large and built around securities. A candidate for a bond expansion. |
| **`AccessManager` scheduling as the approval engine** | It provides "wait, and a guardian may cancel", not "a second person must approve", and cannot vary by amount. Used for governance delays only. |
| **Limits keyed by the device that signed** | A multi-signer account treats its signers as equal, so the contracts would need glue to learn which one signed. The channel that submitted the request is already known on chain, and limits are keyed by it. |
| **`MultiSignerERC7913Weighted` for device tiers** | Weights count towards the signing threshold only and say nothing about amounts. |
| **`ERC20Custodian`** | Marked deprecated in favour of `ERC20Freezable`. |

## For later: cross-chain

Not in scope; recorded so the core does not rule it out. The design and the approaches set aside are in the [plan](plan.md#cross-chain).

| Need | Candidate | Notes |
|---|---|---|
| The bank's own token issued and burned on a second chain | ERC-7802 bridgeable token: `ERC20Bridgeable`, `ERC20Crosschain` | In OpenZeppelin's main library; not yet read |
| Carrying the bank's burn attestations between chains | ERC-7786 gateway interface | In OpenZeppelin; not yet read. Its adapters target public networks, so a local relayer with several attesters would sit behind the same interface. |
| Cap on movement per period in each direction | `RateLimiter` | Already used for other limits |
| Swapping two banks' tokens on a shared chain | A single-transaction swap | No standard needed; both tokens are ERC-20 on one ledger |
| Besu interoperability in production | Hyperledger Cacti | Named, not used |

## Maturity

| Piece | Status |
|---|---|
| `AccessManager`, `TimelockController`, `ERC20` and its main extensions, `ERC4626`, `EIP712`, `SignatureChecker`, `Pausable` | Main library, long established |
| `Account`, `MultiSignerERC7913`, `SignerWebAuthn`, `ERC20TransferAuthorization`, `RateLimiter` | Main library, recent additions |
| `ERC20Collateral`, `ERC20uRWA` with `ERC20Freezable` and `ERC20Restricted`, `RoleAccount`, `SignerAccessManaged` | Community library: less reviewed, may change, to be pinned by commit |

`ERC20Collateral` compares supply with the reported figure at exactly 100% and takes its freshness window at deployment. The buffer is handled by what the reporting function returns; making the window a governance setting needs a small override.

## Prior art

Repositories reviewed for ideas. None combines a retail bank ledger, role and device control, role-playing agents and a plain-language dashboard.

| Repository | Worth taking |
|---|---|
| [sygnumbank/sba-deposit-token](https://github.com/sygnumbank/sba-deposit-token) | Tenancy model: a manager can add and remove people only within their own organisation |
| [jessedh/t3](https://github.com/jessedh/t3) | Document templates: role authority matrix with conflict pairs, compliance matrix, single-key exposure inventory |
| [circlefin/stablecoin-evm](https://github.com/circlefin/stablecoin-evm) | Production use of EIP-3009 and a minting hierarchy with per-minter allowances |
| [paxosglobal/usdp-contracts](https://github.com/paxosglobal/usdp-contracts) | Published audit reports |
| [rohanshinde24/LedgerFlow](https://github.com/rohanshinde24/LedgerFlow) | The principle that an agent proposes and deterministic code decides; a scripted stand-in for the model |
| [hyperledger-iroha/iroha](https://github.com/hyperledger-iroha/iroha) | The ledger behind Cambodia's Bakong, the closest production system to this design |
