# Verification record — LastWin (2026-11-20)

Checked by Spark on 2026-11-20 against commit `20fa50b` (`fix: track payout totals per asset (#1)`,
12 Nov 2026). Repo: https://github.com/wadezigh96/LastWin

## What passes

| Check | Result |
| --- | --- |
| `forge build --sizes` (solc 0.8.24, optimizer 200, via-IR) | ✅ Pass, warnings only (lint hints in tests + one `bytes8` cast note). Largest contract: `LastBuyerWinsCustomData` 10,334 B runtime, well under the 24,576 B limit |
| `forge test` | ✅ **31/31 pass, 0 fail** (28 unit + fuzz with 256 runs + 3 end-to-end games through a simulated Core buy path: timer end, sell-out, post-round cap) |
| GitHub Actions CI (`test` workflow) | ✅ Green — latest run 12 Nov 2026, `test completed success` (runs 43212117798, 43211984666, 43211602544) |
| `forge script script/Deploy.s.sol` dry-run vs BSC testnet (chain 97) | ✅ Simulation succeeds. Predicted impl addresses with Foundry's default sender (not the real deployer): CustomData `0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519`, Trade `0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496`, Migrate `0x34A1D3fff3958843C43aD80F30b94c510645C316`, Validator `0x90193C961A926261B756D1E5bb255e67ff9498A1`. Estimated gas 7,427,357 |
| Deploy cost (BSC testnet gas price 0.1 gwei, checked live) | ≈ **0.00074 tBNB** for all four contracts. Even at 3 gwei it is ≈ 0.022 tBNB |
| OpenFour Core / Registry live on BSC testnet | ✅ Verified on-chain 2026-11-20: Registry `0xE5014c0616e528B0ABF7CC120A58032c1FbE7060` → `openFourCore()` = `0xd6DAC7815A3B007822E0829bcDB3f193041285Db`, `openFourTool()` = `0xdECbE01E91A3c0Abf841d3E32c1587a3b62E38c6` (matches openfour-docs `developer/fork-deploy/source/bsctestnet.json`, deployed 2026-11-02). Core is an EIP-1967 proxy. Existing fork presets: bondingV1 `1778027615722`, bondingTaxV1 `1778027615723`, stock4TaxV1 `1778027615733` |
| Interface compatibility vs openfour-docs HEAD (`079a45e`) | ✅ Function signatures used by LastWin match the current official interfaces (only parameter-name / comment differences, which do not change selectors). The copied interfaces are from an older snapshot: official `IOpenFourVault` has since added `sellViaVault()` / `collectSellAsset()` and `OpenFourTypes` gained `TradeNotAllowed` + `revertIfDisallowed` — LastWin does not call any of those, so nothing breaks. Worth a re-sync before the official audit, not before the fork test |

## What is NOT done yet (honest gaps)

1. **No real on-chain deploy yet.** `Deploy.s.sol` only deploys the four implementations + validator.
   A broadcast needs the deployer's own wallet signing — Spark never takes a private key / seed,
   so this step is Ibet's (one command, see `docs/FORK_LIVE_TEST.md` §1).
2. **No live game yet.** A token can only be created through OpenFourCore with a registered preset.
   On the official testnet Registry that registration is governance-only (`presetId = TBD`),
   so the full live game runs first on a **developer-owned fork** (own Core/Registry proxy set,
   `npm run fork` in openfour-docs) — see `docs/FORK_LIVE_TEST.md`. `script/RegisterForkPreset.s.sol`
   (added 2026-11-20) does the fork registration: 3× `upsertModule` + `upsertPreset`, reusing the
   fork bonding preset's token / vault / curve / token-impl slots.
3. **Two open integration questions** (already in the README, still unconfirmed): whether FeeTier
   pot fees are pushed immediately to the custom-data module, and whether the registered
   `BondingCurveModule` / `StandardVault` / PCS V2 adapter compose into this preset. The fork test
   (§4–5 of the runbook) is what confirms both — that is the point of running it.
4. **No independent audit yet.** The threat model recommends one before mainnet (offered by the
   OpenFour program). The fork test + audit report are the two items of the official submit pack.

## Files added 2026-11-20 (not yet pushed)

- `script/RegisterForkPreset.s.sol` — fork-only preset registration (compiles; see `forge build`)
- `docs/FORK_LIVE_TEST.md` — step-by-step runbook: deploy → fork → register → create → play → settle → submit
- `docs/VERIFICATION.md` — this file
