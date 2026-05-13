# Welcome!

Welcome to the repo for the Fintech and Cryptocurrency course ECO5037W assignment. The repo has been designed to provide you with information and links to any new concepts required for this assignment as well as the objectives and requirements for the assignment.

The assignment is based on Fungible Tokens that follow the ERC20 standard. In class we learnt about the ERC721 standard for Non Fungible Tokens (NFTs). You are going to apply many aspects of what we learnt from the tutorials to complete the assignment. After completing the assignment you should have a basic understanding of the ERC20 standard and Decentralized Exchanges (DEXs).

> NOTE: This is an individual assignment and plagiarism will be penalized. Use of AI is allowed but understanding of concepts should be demonstrated by your own comments. Any new concepts will have links provided for you to read through before attempting the assignment. Please read the wiki for each part of the assignment.

## Requirements

- The submission is your private repository. Setup instructions are in the setup section.

- Due date is `22 May 2026`

## Setup

1. Fork this repository to your own GitHub account: [FinHubSA/ethereum-class-assignment-2026](https://github.com/FinHubSA/ethereum-class-assignment-2026).
2. Clone your **fork** (not the original class repository) to your local machine.
3. Complete the assignment work in your forked repository.
4. For submission, add `takundachirema` as a collaborator to your personal repository.

## Assignment Folders

- `01-order-book/`: build ERC20 tokens and an order book DEX.
- `02-uniswap-v4/`: build reward-token market infrastructure using Uniswap v4 concepts.

## 01: Order Book Assignment

In `01-order-book/`, use the wiki as your study and implementation guide:

- `01-order-book/wiki/README.md`
- `01-order-book/wiki/01-erc20-tokens.md`
- `01-order-book/wiki/02-decentralized-exchanges.md`
- `01-order-book/wiki/03-assignment.md`

Assignment focus:

- Create `PNPToken` (`PNPT`) and `FNBToken` (`FNBT`) ERC20 contracts.
- Build an order book contract to trade these reward tokens.

## 02: Uniswap v4 Assignment

In `02-uniswap-v4/`, use the wiki as your study and implementation guide:

- `02-uniswap-v4/wiki/README.md`
- `02-uniswap-v4/wiki/01-automated-market-makers.md`
- `02-uniswap-v4/wiki/02-uniswap-v4.md`
- `02-uniswap-v4/wiki/03-assignment.md`

Assignment focus:

- Install and use `@uniswap/v4-core`.
- Create and initialize a pool via `PoolManager` for `PNPT`/`FNBT`.
- Mint a liquidity position in the configured fee tier and tick spacing.
