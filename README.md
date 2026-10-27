# Last Buyer Wins — an OpenFour launch mechanism

A countdown launch for OpenFour on BNB Chain. Every token starts with a clock. Each qualifying buy
makes the buyer the current "last buyer" and adds time to the clock. A small pot fee on every trade
builds a prize pot on-chain. When the clock hits zero (or the curve sells out), the token graduates to
PancakeSwap and the last buyer takes the pot.

None of the live OpenFour mechanisms (Universal Subscription, Royalty, Creator Incentives, Likwid Dex,
CubePeg, Agent ID Exclusive) is a timer/pot game. The FOMO4D pattern is one of the most proven volume
drivers in crypto: people keep buying near zero to grab the pot, so the final minutes are the busiest.

## Modules

| Slot | Contract | Tag |
| --- | --- | --- |
| Token | reuse `StandardTokenModule` / `OpenFourToken` | `module.token.standard` |
| Vault | reuse `StandardVault` | `module.vault.standard` |
| Curve | reuse `BondingCurveModule` | `module.curve.bonding` |
| Trade | `LastBuyerWinsTradeModule` (new, view-only) | `module.trade.last_buyer_wins` |
| Migrate | `LastBuyerWinsMigrateModule` (new, PCS V2 adapter) | `module.migrate.last_buyer_wins` |
| Custom data | `LastBuyerWinsCustomData` (new, clock + pot) | `module.data.last_buyer_wins` |
| Validator | `LastBuyerWinsPresetValidator` (new) | — |

Only the three slots that change are new; custody, pricing and the token body are reused untouched.

## Rules

- Clock starts at `initialDuration` (default 1 h) at creation.
- A buy counts only if `curveQuote >= minQualifyingQuote` (default 0.01 BNB) and the clock is still running.
- A counting buy adds `extensionPerBuy` (default 60 s), capped so the clock never shows more than
  `maxRemaining` (default 1 h) and never passes `hardDeadline = creation + maxGameDuration` (default 7 days).
  The game always ends.
- Sells, small buys and buys after zero never change the winner.
- Pot fee: `buyPotFeeBps` / `sellPotFeeBps` (default 1% / 2%, hard ceiling 10%) returned as a FeeTier
  whose recipient is the custom-data module.
- Graduation: `soldOut || now >= deadline`. After zero, buys are capped at `postRoundMaxBuy` so the
  next buy triggers Core's post-buy migration check without being able to win.
- Sell-out migration closes the round at that moment (`onMigrate`).
- Settlement: `settle()` is permissionless after the round ends. `winnerBps` (default 90%, min 50%) to
  the last buyer, the rest to the token creator. No buyer → all to creator. Callable again to sweep
  fees that arrive later. Native and ERC20/wrapped-native quotes supported.

## Safety

- Hooks are `onlyFourCore` and check the bound token; hooks record facts and never revert on business rules.
- Trade module is view-only; no state writes.
- `executeMigration` rechecks conditions from the vault (does not trust `hookData` or the context), caps quote.
- Pull-style, reentrancy-locked settlement; balances read before transfers.
- A winner contract that rejects native is paid in wrapped native, so nobody can brick payout.
- `receive()` is empty so FeeRouter pushes never run out of gas.
- All params validated in `init` and again in the preset validator (cross-module: qualifying buy ≤ 10%
  of raise, liquidity ≤ reserve, caps ≤ sale amount).
- Implementations lock initializers in the constructor; clones initialize once.

Known trade-offs (for the audit): last-second MEV/front-running on the final buy is inherent to the
game and mitigated by every counting buy adding time; the `maxRemaining` cap keeps the clock short.

## Tests

`forge test` — 28 tests including a fuzz test that the clock never exceeds its bounds, settlement
in native / wrapped native / ERC20, reentrancy, rejecting recipients, migration rechecks and
validator rules.

## Open integration questions for OpenFour

1. Confirm FeeTier (tax) fees are pushed immediately to the recipient (pot), in native or wrapped native.
2. Confirm the registered `BondingCurveModule`, `StandardVault` and PCS V2 adapter can be composed into
   this preset, and whether a permissionless migrate entry exists (otherwise the first buy after zero triggers it).

## Setup

```bash
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v4.9.6
forge test
```

`src/openfour/` holds the interfaces and types copied from the official
[openfour-docs](https://github.com/four-meme-community/openfour-docs) repository.

## Builder

- Name: Kames
- Telegram: [@ctrxz](https://t.me/ctrxz)
- X: [@0xkames](https://x.com/0xkames)
- Email: xyzkames@gmail.com
