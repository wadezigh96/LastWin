# Threat model and audit notes

## Assets at risk
- The prize pot held by `LastBuyerWinsCustomData` (native, wrapped native, quote ERC20).
- Migration correctness (raised quote and liquidity tokens), handled by Core/Vault/adapter.

## Trust assumptions
- `fourCore` is the real OpenFourCore and is the only caller of `afterHook`, `onMigrate`, `evaluate` (migrate) and `executeMigration`.
- `IOpenFourCore.tokens(token)` returns the true creator and quote asset.
- FeeRouter pushes FeeTier fees to the recipient at trade time (to be confirmed by OpenFour).

## Threats and mitigations

| Threat | Mitigation |
| --- | --- |
| Fake hook calls to steal the lead | `onlyFourCore` + bound token check |
| Re-initialising a clone or the implementation | OZ `initializer`; constructor disables initializers |
| Reentrancy during payout | `nonReentrant` lock; balances read before transfers; tested with a reentering winner |
| Winner contract rejects native and blocks creator payout | 50k gas native send, fallback to wrapped native |
| Pot fee push runs out of gas | empty `receive()` |
| Endless game | `hardDeadline` from creation, `maxGameDuration ≤ 30 days`; fuzz-tested bound |
| Clock inflation by spam buys | extension capped at `maxRemaining` from now; dust buys below `minQualifyingQuote` ignored |
| Buys after zero stealing the pot | afterHook ignores `timestamp >= deadline`; post-round buys capped |
| Tampered `hookData` in migration | `executeMigration` re-reads `isSoldOut()` and the deadline; quote re-capped to `totalRaised` |
| Excessive fees | pot fee ≤ 10% per side; validator cross-checks |
| Griefing settle timing | settle is permissionless and idempotent; repeated calls only sweep new balance |

## Accepted risks (inherent to the game)
- **Last-second MEV**: a searcher can front-run the final buy. Each counting buy adds time, so the last
  block is rarely final; `maxRemaining` keeps rounds short. Private mempools are the user-side remedy.
- **Validator timestamp drift**: a few seconds on BSC; immaterial with minute-scale extensions.
- **Wash buys by one wallet**: allowed by design; every buy pays the pot fee, so this only grows the pot.

## Out of scope
- Core, FeeRouter, Vault, BondingCurve and PCS adapter (official OpenFour contracts).

## Recommended before mainnet
- Independent audit (offered by the OpenFour program).
- Fork test against BSC mainnet Core once the preset is registered on testnet.
- Confirm fee delivery path and migration trigger with the OpenFour team.
