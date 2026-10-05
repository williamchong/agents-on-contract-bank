# agents-on-contract-bank

A locally runnable simulation of a bank that runs on a blockchain in place of a core banking system. Account balances are tokenised deposits, the bank's books are a general ledger on the same chain, lending creates money within capital and liquidity limits, and customers pay and are paid by people at other banks. A fully reserved HKD-referenced stablecoin is offered beside the deposit. AI agents play customers and staff, the chain enforces who may do what, and a dashboard explains each event in plain language.

It is a portfolio project showing institutional web3 architecture: contracts that run on any EVM chain and are deployed to a public testnet, role and device based access control, segregated duties, an on-chain balance sheet, and reserve rules in the spirit of the HKMA stablecoin issuer regime.

## Status

The documents milestone is done, and the working demo is under way. The repository holds the documentation, the core contracts (the role numbers, the deposit token and the general ledger) and a toolchain spike: the pinned OpenZeppelin libraries, a few spike contracts, and tests that check the pieces the first working demo rests on. Run them with `pnpm install` and `pnpm check`, and against Base Sepolia with `pnpm check:base-sepolia`.

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
