# agents-on-contract-bank

A locally runnable simulation of a bank that runs on a blockchain in place of a core banking system. Account balances are tokenised deposits, the bank's books are a general ledger on the same chain, lending creates money within capital and liquidity limits, and customers pay and are paid by people at other banks. A fully reserved HKD-referenced stablecoin is offered beside the deposit. AI agents play customers and staff, the chain enforces who may do what, and a dashboard explains each event in plain language and shows the bank as a small live town in 3D.

It is a portfolio project showing institutional web3 architecture: contracts that run on any EVM chain and are deployed to a public testnet, role and device based access control, segregated duties, an on-chain balance sheet, and reserve rules in the spirit of the HKMA stablecoin issuer regime.

## Status

The documents and working demo milestones are done: every daily routine of the working demo runs, every adverse scenario passes, and the guided tour's first four beats play on the dashboard. The repository holds the documentation, the core contracts (the role numbers, the deposit token, the general ledger, the multi-signer account that staff, machines, customers and governance act from, the staff roles module, the hold register, the partner key register, the payments module, attested figures, the cash module, the customer limits, branch approvals, assisted operations, account recovery, dispute reversal and the incident log), the services the scripted actors act through (a signer, a submission service that simulates each request and records refusals, a clearing system simulator, and the control service the dashboard drives), the presets that play the daily routines and adverse scenarios and score them, the dashboard, and a toolchain spike. Run the tests and the presets with `pnpm install` and `pnpm check`, the presets alone with `pnpm scenarios`, which plays each from the same start and then all of them in order on one bank, and the tests against Base Sepolia with `pnpm check:base-sepolia`. To run the demo, start a local chain with `pnpm hardhat node`, open the bank on it with `pnpm demo`, which serves the control service, and run the dashboard with `pnpm --filter dashboard dev`. From the dashboard's control panel, move the guided tour on beat by beat, start and stop daily operation, inject any adverse scenario while it runs, pause, pace, close the day or move time on, and reset to the opening balance sheet; no API key is needed.

## Documents

| Document | Contents |
|---|---|
| [Plan](docs/plan.md) | Primary use cases, scope, milestones, what is left out, open questions |
| [Architecture](docs/architecture.md) | Layers, network, channels, account and money model, key flows, controls |
| [Scenarios](docs/scenarios.md) | Daily routines, adverse scenarios, the guided tour, and which control each one shows |
| [Roles](docs/roles.md) | Tentative roles, agent and script split, draft permission matrix, separation of duties |
| [Standards and contracts](docs/standards.md) | Which ERCs and OpenZeppelin contracts are used, what is written here, what was rejected |
| [HKMA mapping](docs/hkma-mapping.md) | How each stablecoin and banking requirement is reflected, and what is deliberately not done |

## Not a real bank

This is a simulation for demonstration. It is not audited, not a licensed product, and not legal or regulatory advice. The regulatory mapping is a design exercise, not a compliance assessment.
