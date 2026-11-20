# Fork live test — Last Buyer Wins, end to end on BSC testnet

Goal: prove the whole game works on a real chain — create a token through OpenFourCore,
buy (clock extends, pot grows), let the clock hit zero, settle the pot — without waiting
for OpenFour governance. Everything below runs on a **developer-owned fork**: your own
Core / Registry proxy set on BSC testnet, where you are the Registry owner. Nothing here
touches the official Registry or mainnet.

Status 2026-11-20: code is verified (`forge test` 31/31, CI green, deploy dry-run OK —
see `docs/VERIFICATION.md`). Steps 1–3 below still need a signing wallet, so they are
Ibet's steps, in his own terminal. Spark never takes a private key or seed phrase.

## 0. Prereqs

- `forge` (Foundry 1.9.0), Node.js 18+, `git`
- BSC testnet RPC, e.g. `https://data-seed-prebsc-1-s1.binance.org:8545`
- tBNB for gas: the 4 LastWin implementations cost ≈ **0.00074 tBNB** at 0.1 gwei
  (7,427,357 gas, dry-run 2026-11-20). The fork proxy set costs a few more txs —
  keep **0.05 tBNB** in the deployer wallet to be safe. Faucet: https://testnet.bnbchain.org/faucet-smart
- `openfour-docs` cloned next to this repo:
  `git clone https://github.com/four-meme-community/openfour-docs.git`

## 1. Deploy the LastWin implementations (BSC testnet, your wallet)

```bash
cd LastWin
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v4.9.6
forge test   # expect: 31 passed, 0 failed
PRESET_ID=0 forge script script/Deploy.s.sol \
  --rpc-url https://data-seed-prebsc-1-s1.binance.org:8545 \
  --private-key $PK --broadcast
```

`PRESET_ID=0` here means "validator accepts any preset" — the real preset id is set
in step 3, where a fresh validator is deployed with that id. Save the four printed
addresses. Then verify them on BscScan (testnet): `forge verify-contract <address>
src/<Contract>.sol:<Contract> --chain 97 --compiler-version 0.8.24 --optimizer-runs 200
--via-ir` — the constructor takes no args for the three modules; the validator takes
`(uint256 presetId)`.

## 2. Fork OpenFour (your own Core + Registry)

```bash
cd ../openfour-docs/developer/fork-deploy
npm install
cp .env.example .env   # set DEPLOYER_PRIVATE_KEY to the SAME wallet as step 1
npm run fork:dry       # reads on-chain implementations, sends nothing
npm run fork           # deploys your proxy set; writes out/fork-deployment.json
cp out/fork-deployment.json ../workbench/data/fork.json
```

Check: `Core.signer()` is your deployer and `Registry.owner()` is your deployer.
The fork Registry address is in `fork.json` — that is the **only** Registry you ever
call `upsert*` on. Never upsert on the official Registry
(`0xE5014c0616e528B0ABF7CC120A58032c1FbE7060`).

Smoke-check the fork first (optional but recommended):

```bash
PRESET=bondingV1 npm run create-test-preset
```

That proves your fork's create → buy → sell-out → migrate path works before LastWin
is involved.

## 3. Register the LastWin preset on your fork

```bash
cd ../../LastWin   # back to this repo
FORK_REGISTRY=<address from fork.json> PRESET_ID=1778027615734 \
  forge script script/RegisterForkPreset.s.sol \
  --rpc-url https://data-seed-prebsc-1-s1.binance.org:8545 \
  --private-key $PK --broadcast
```

What it does: deploys fresh implementations + a validator bound to `1778027615734`
(or reuses `DATA_IMPL` / `TRADE_IMPL` / `MIGRATE_IMPL` / `VALIDATOR` env addresses from
step 1), calls `upsertModule` for the three new modules
(`module.data.last_buyer_wins`, `module.trade.last_buyer_wins`,
`module.migrate.last_buyer_wins`; kinds CustomData 5 / Trade 3 / Migrate 4), then
`upsertPreset`, reusing the fork bonding preset's token / vault / curve / token-impl
slots. It reads back `getModule` / `getPreset` on-chain and reverts the log if the
registration did not stick. `1778027615734` is the next free id after the fork presets
(...722, ...723, ...733) — confirm with `cast call <registry> "getPresetIds() returns
(uint256[])"` if in doubt.

## 4. Create a LastWin token (short game, for the demo)

Create through your **fork Core** (Workbench Create page, or `developer/startup`
`create-and-trade.js` with a preset JSON). The create is signed: `Core.signer()` must
be your wallet. Suggested first-game params (all from `docs/mechanism.md`):

| Slot | Params |
| --- | --- |
| Token | name e.g. `LastWin Demo`, symbol `LWD`, maxSupply `1,000,000,000`, saleAmount `800,000,000`, raiseAmount `1` BNB, quote = **WBNB (ERC20), bukan native** — create dengan quote native ditolak StandardVault (`Vault: quote must be ERC20`, terbukti di fork lokal 2026-11-20), no presale |
| Curve | reuse fork `BondingCurveModule` (default bonding curve params from the fork preset) |
| Custom data | `initialDuration` 3600, `extensionPerBuy` 60, `maxRemaining` 3600, `maxGameDuration` 604800, `minQualifyingQuote` 0.01 BNB, `winnerBps` 9000 |
| Trade | `buyPotFeeBps` 100, `sellPotFeeBps` 200, `maxBuyAmount` 0 (unlimited), `postRoundMaxBuy` 1e18 |
| Migrate | `migrationAdapter` `0x0` for the first run (skips on-chain liquidity, still tests game + settle), `lpRecipient` `0x...dEaD`, `tokenLiquidityAmount` 0, `maxQuoteToUse` 0 |

For a fast demo, use a short clock instead: `initialDuration` 300 (minimum),
`extensionPerBuy` 60, `maxRemaining` 300. Verify after create:
`Core.tokens(token)` shows `exists == true`, the right `presetId`, and non-zero
`customData`; `gameState()` on the custom-data clone shows `timeLeft` ≈ 300.

## 5. Play the game

1. **Buy 1** (≥ 0.01 BNB via `buyByBudget` on the fork Core): check `gameState()` —
   `lastBuyer` is you, `qualifyingBuys` is 1, `deadline` moved +60s, pot > 0.
2. **Buy 2** from a second wallet (or same wallet): `lastBuyer` changes, clock extends again.
3. **Small buy** (< 0.01 BNB): trades, but `lastBuyer` and `qualifyingBuys` do not change.
4. **Wait** until `timeLeft` hits 0 (5 minutes on the short clock). `roundEnded()` is now true.
5. **Buy after zero**: allowed but capped at `postRoundMaxBuy`, does not change the winner.
   Use `buy(token, postRoundMaxBuy)` — `buyByBudget` reverts after zero
   (`CoreErrBudgetNotExecutable`, proven in the local fork run).
6. **`settle()`** (anyone can call, on the custom-data clone): winner gets 90% of the pot,
   creator 10%. Check balances + `PotSettled` event. Call it again: second call only
   sweeps fees that arrived later.
7. Optional: repeat with `migrationAdapter` set to the fork PCS V2 adapter and a
   sell-out buy, to prove graduation + `onMigrate` closing the round.

Record every tx hash + the token address. They are the proof for the submit pack.

## 6. Verify (checklist before submitting)

- [ ] `tokens(token)` modules match the preset; each module `descriptor().tag` matches its registered tag
- [ ] Vault `remainingForSale` fell and `totalRaised` rose with each buy
- [ ] `gameState()` clock / pot / winner match the buys you made
- [ ] `settle()` paid winner 90% / creator 10% (or 100% to creator when no buyer)
- [ ] `migrate` before graduation reverts / `evaluate` returns `canMigrate: false`
- [ ] No Critical / High findings left open (see `docs/threat-model.md`)

## 7. Submit pack (official, after the fork test)

Entry: https://four.meme — Developer Guide §17–§20. Include: module / preset / token
source + commit, gameplay description, composition, risk notes, `descriptor()` tags,
version, schemas, moduleKey source strings, validator rules + tests, the create / buy /
sell / migrate records from §5 (token address + tx hashes), the **fork Registry address**,
and the audit report. Registration on the official Registry is done by OpenFour after
review — do not write to production Registries yourself.
