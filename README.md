# Genesis Agents (GENESIS)

A fixed-supply, plain ERC-20 token for an ordinary launch on Ethereum mainnet through the IdentityMD
launch factory, with its pool on Uniswap v4 paired with IMD.

| Item | Value |
| --- | --- |
| Contract | `GENESISToken` (`src/GENESISToken.sol`) |
| Name / symbol | Genesis Agents / GENESIS |
| Decimals | 18 |
| Total supply | 1,000,000,000 GENESIS = `1000000000000000000000000000` minor units (1e27) |
| Constructor arguments | none |
| Minting after deployment | none (no mint function exists) |
| Burning | none (no burn function exists; supply never changes) |
| Transfer rules | plain ERC-20: no fee, tax, limit, pause, blacklist or hook |
| Owner / admin | none; every parameter is a compile-time constant |
| Upgradeability | none: no proxy, no `delegatecall`, no `selfdestruct`, no external calls |

## Layout

```
foundry.toml          solc 0.8.26, evm_version cancun, optimizer on, bytecode_hash = "none"
remappings.txt        forge-std/ -> lib/forge-std/src/
src/GENESISToken.sol  the token, self-contained (no inherited library)
test/                 Foundry tests
lib/forge-std/        vendored forge-std 1.17.0 (tests only; plain files, no submodule)
launch.json           launch manifest (custom_token)
```

Build and test:

```
forge build
forge test
forge fmt --check
```

## Design

The contract is written from scratch rather than inheriting a library so that the deployed bytes are
exactly what is in `src/GENESISToken.sol`, with nothing hidden behind an import. It implements the
ERC-20 surface: `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `allowance`, `approve`,
`transfer`, `transferFrom`, and the `Transfer` and `Approval` events.

- `totalSupply()` returns the constant `TOTAL_SUPPLY`. Nothing writes it, so the supply cannot grow or
  shrink.
- The constructor mints the whole supply to `msg.sender` and emits `Transfer(0, msg.sender, supply)`.
  It takes no arguments and calls no other contract, so it deploys on an empty chain.
- Transfers to or from the zero address revert with `ZeroAddress`. There is no burn path.
- Insufficient balance reverts with `InsufficientBalance(from, balance, amount)`; insufficient allowance
  reverts with `InsufficientAllowance(owner, spender, allowance, amount)`.
- An allowance of `type(uint256).max` is treated as infinite and is not decremented.
- There is no `receive` or `fallback`, so ETH sent to the token and unknown selectors revert.

## Launch parameters (launch.json)

The launch factory, not this contract, distributes the supply. The token mints all 1e27 units to its
deployer, which at launch is the factory. The factory then:

1. sends the swarm's 10% to the launch's Merkle distributor;
2. seeds the Uniswap v4 pool with `economics.poolBps` = 9000 (90% of the supply), single-sided, paired
   with IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), at the price it derives from
   `economics.initialMarketCapWei` = 2500 IMD for the whole supply and the deployed currency order;
3. forwards any remainder to `economics.remainderTo` = `0x000000000000000000000000000000000000dead`.

Pool parameters: fee 12500 (1.25%), tick spacing 60, swaps through the PoolManager at
`0x000000000004444c5dc75cB358380D2e3dE08A90`. `pool.initialPrice` is provenance only.

Nothing in this repository subtracts the swarm share or sends tokens anywhere: the constructor mints
the entire supply to the deployer, as the protected launch invariants require.

## Assumptions

- Chain: Ethereum mainnet (chain id 1), set by the order.
- The deployer at launch is the launch factory; the token trusts nobody and exempts nobody, since plain
  transfers already move exactly the amount requested for every caller, including the factory, the
  PoolManager and the distributor.
- No application contracts accompany the token (`contracts: []`).

## Operational responsibilities

- There are no post-launch settings: no owner, no setter, nothing to configure after deployment.
- Deployment and broadcasting are the launch deployer's. This repository contains no scripts that
  broadcast and holds no keys.
- Explorer verification uses the pinned compiler settings in `foundry.toml` (solc 0.8.26, cancun,
  optimizer on with 200 runs, no metadata hash).
- Tests passing are not a security audit. A separate adversarial review before release remains owed.

## Tests

`test/GENESISToken.t.sol` is the smoke suite: metadata, supply minted to the deployer, the mint event,
CREATE2 deployment with no arguments, a runtime opcode scan for `DELEGATECALL`, `CALLCODE` and
`SELFDESTRUCT`, exact-amount transfers and transfer chains, revert paths (insufficient balance, zero
address, insufficient allowance), allowance semantics including infinite allowance, a sweep of common
admin and mint selectors confirming none exist, and that the deployer has no power over holders.
The full fuzz and invariant suite is written in a separate assignment.
