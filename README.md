# curb (CURB)

A fixed-supply ERC-20 for a custom token launch on Ethereum (chain id 1), paired with IMD.

| Property | Value |
| --- | --- |
| Solidity contract | `CurbToken` (`src/CurbToken.sol`) |
| `name()` | `curb` |
| `symbol()` | `CURB` |
| `decimals()` | `18` |
| Total supply | 1,000,000,000 CURB = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Compiler | solc 0.8.26, optimizer 200 runs, `bytecode_hash = "none"` |

## What it does

The brief says only "Curb", so the token takes the most literal reading that fits a fixed-supply launch:
supply can only be curbed, never grown.

- The constructor mints the whole supply once to `msg.sender`, the launch factory. No other mint path exists.
- Holders can `burn(amount)` their own tokens, or `burnFrom(account, amount)` up to an allowance that
  account granted (OpenZeppelin `ERC20Burnable`). Burning only lowers `totalSupply`.
- Transfers are plain ERC-20 (OpenZeppelin v5.1.0): no fee, tax, burn-on-transfer, pause, blacklist or
  limits, so the factory → distributor, factory → PoolManager, claim and swap flows move exactly what they say.

## Assumptions

- "Curb" is read as "the supply can only be curbed" (holder-initiated burns). No other mechanism was requested.
- No owner or admin role: nothing in the token needs one, so the contract does not inherit `Ownable`.
- The runtime has no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, and calls no library functions
  that need linking.

## Deployment parameters

The launch factory deploys `CurbToken` from its built bytecode with no constructor arguments; the factory
receives all 1,000,000,000 CURB and distributes it per the launch economics (10% swarm via the
MerkleDistributor, 50% seeding the CURB/IMD pool, 40% to the requester's `remainderTo`). This repository
does not deploy, broadcast or hold keys, and writes no `launch.json`; the manifest step does that.

## After launch

Nothing to configure: the token has no settings, setters or owner.

## Operational responsibilities

- No one can mint, pause, freeze or move a holder's balance; there are no admin keys to secure.
- Burns are irreversible and are the holder's own decision (or a spender's within an allowance the holder gave).
- Usual ERC-20 allowance caveats apply: approving a spender lets it transfer or burn up to that amount.
- Tests passing is not an audit. The code is a thin wrapper over OpenZeppelin, but an independent review
  should still happen before release.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

Dependencies are vendored under `lib/` (forge-std v1.9.7, OpenZeppelin Contracts v5.1.0); no network is needed.
