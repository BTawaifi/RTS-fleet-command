# Why the AI builds zero capitals — mechanism analysis and candidate designs

**Status:** analysis only. No source file was edited. Every number below is from a
tool run or a file read in this session; the batch names are the ones in
`D:\Games\FreespaceOpen\FS2\rts-headless-staging`.

**Corrections applied after peer review (both verified in source this session):**
- The escalation schedule is `tierUnlocks = {0, 240, 570, 1050, 1380}` for the
  30 MIN profile (`fs2rts_config.lua:506`) and `{0, 480, 1140, 2160, 2760}` for
  the long one (`:516`). The `{0,300,900,1800}` in circulation is a dead
  fallback at `fs2rts_factions.lua:34`, reached only when `GetDurationProfile()`
  returns nil. All tier-window arithmetic below uses the real schedule.
- Income is ~16-18 CP/s per faction per match (48,122-53,716 CP over 3,000 s,
  measured). Base is 10 x 1.12 duration x 0.95 AI scale = 10.64, ramped. Any
  60-85 CP/s figure is unsourced and is not used here.

## 1. The premise is wrong in one specific and important way

The brief says "the base drains the bank the fleet is trying to accumulate" and
asks for sentry-quota mechanisms. That is measurably not where the CP goes.

Per faction per 3000 s match, batch `savepolicy-20261001`, from
`FACTION.economy.flowCumulative` + `economy.upgradeSpend` + `PRODUCTION
QUEUE_ACCEPTED.cost` + `SENTRY_BUILD BUILD_STARTED.cost`:

| sink | BLUE | GOLD | RED | % of that faction's income |
|---|---|---|---|---|
| fleet builds | 100,400 | 153,750 | 95,425 | 39-76 % |
| **station upgrades** | **75,700** | **59,100** | **77,450** | **29-38 %** |
| sentries | 27,500 | 6,750 | 17,125 | 3-13 % |
| total income | 212,387 | 201,540 | 204,596 | — |

The upgrade tree costs **21,225 CP to max out**
(`fs2rts_config.lua:576-587`: armor 625+1250+2250, defenses 750+1500+2750,
logistics 625+1400+4200, command 875+1750+3250). Nine of twelve
faction-matches finish with armor 3 / defenses 3 / command 3 bought. A single
`logistics 3` costs **4,200 CP — more than the 7,700 CP capital** and **11× a
375 CP sentry**.

Sentries are 3-13 % of income. Upgrades are 29-38 %. Any design that
de-denominates sentries is treating the smaller sink. This is not a claim that
sentries are wrong — only that they are not the constraint.

## 2. The actual blocker: the save window ages out before the target, then
## spends the bank on a cheap hull and restarts

`ChooseAIBuild` (`fs2rts_ai_production.lua:182-239`):

```lua
if bankTarget<math.huge and state.cp<bankTarget and tier>=2 and not emergencyBuild then
    state.savingRole=goal
    if state.savingSince==nil then state.savingSince=now end
    if now-state.savingSince<savingSeconds then
        local during={}
        if self.Config.AI.FieldCheapHullWhileSaving==true then ... end   -- :196
        if #during==0 then decision.reason="SAVING_FOR_DESIRED_ROLE"; return nil,decision end  -- :228
```

`FieldCheapHullWhileSaving = false` (`fs2rts_config.lua:757`), so `during` stays
empty and the producer **goes dark** for the whole window. That is the shipped
default and the batch agrees with the contract's reading of it.

When the window expires, `:234-236` sets `savingFallback` and
`bankTarget = cheapestDesired`, and `:250-254` restricts candidates to the
desired category. `cheapestDesired` for RED is **7,700** (SD Ravana, tier 3).
Measured, all four matches, every capital-desired fallback:

```
match  BLUE  t=2542.0 FALLBACK des=capital cp=3177  bt=8600  -> sel=GTF Hercules Mark II cost=2800
match  BLUE  t=2607.7 FALLBACK des=capital cp=6047  bt=8600  -> sel=GTB Artemis          cost=2800
match  GOLD  t=1870.3 FALLBACK des=capital cp=4061  bt=8600  -> sel=GVF Thoth            cost=1300
match  RED   t=2383.2 FALLBACK des=capital cp=2820  bt=7700  -> sel=SF Basilisk         cost=1800
match  RED   t=2263.8 FALLBACK des=capital cp=5320  bt=7700  -> sel=SB Taurvi            cost=3150
```

`des=capital`, `bt=7700` (the fallback target), and the purchase is a fighter or
a bomber. Because at the fallback moment cp (2,820-6,047) is below the cheapest
capital (7,700-8,600), the capital is not in `candidates` at all
(`affordable` is checked at `:122`), so the category filter at `:252` matches
nothing and `candidates` stays as the full affordable set. `:290` then picks by
weight. **The fallback spends the bank on a cheap hull and `:305` clears
`savingSince`, so the next 600-900 s window starts from ~zero again.**

That is a closed loop. Measured capital-save run lengths (consecutive
`desiredRole=="capital"` decisions), current vs baseline:

```
CURRENT   BLUE  runs=16  median 269s  max 1431s   runs>=600s: 7
CURRENT   GOLD  runs=23  median  88s  max  933s   runs>=600s: 1
CURRENT   RED   runs=23  median 283s  max 1216s   runs>=600s: 3
BASELINE  BLUE  runs=24  median  96s  max 1161s   runs>=600s: 5
BASELINE  GOLD  runs=15  median 334s  max  933s   runs>=600s: 3
BASELINE  RED   runs=17  median 177s  max  948s   runs>=600s: 4
```

Same window lengths, same income. The baseline's runs reach higher peaks
(9,816-13,896 CP) because the baseline **bought the capital inside the window**.
Current runs peak at 4,056-11,379.

## 3. And the bank cannot hold a capital anyway: total out exceeds total income

Per faction per match, current batch:

```
BLUE  income=53244  fleet=24775 sentry=3750 upgrade=21225   sum=93% of income
RED   income=48122  fleet=31700 sentry=6000 upgrade=13775   sum=107%
GOLD  income=50401  fleet=46125 sentry=1500 upgrade=10775   sum=116%
```

The AI spends 93-116 % of its income. It cannot bank 7,700 CP on top of a fleet
and a maxed upgrade tree, because there is no CP left. `cp_drift_not_persistently_negative`
PASSES with `netRate=-0.560` for BLUE — a faction that claims to be saving is
net *losing* ground.

The upgrade tree is the reason: it is a **21,225 CP fixed obligation** competing
one-for-one with capital hulls, and the station buys it eagerly because
`tryUpgrade` (`:974-977`) and the sentry loop (`:1032`) both test only
`affordable()`, whose floor is `stationReserve = min(reserve, StationReserveCap)`
= **1,500 CP** (`fs2rts_station.lua:971`). A 4,200 CP logistics upgrade clears a
1,500 CP floor at 5,700 CP banked. There is no coupling at all between
"the fleet is 4,000 CP short of a capital" and "the station may buy upgrades".

## 4. The cleanest statement of the bug

Three independent defects compose into zero capitals:

- **D1 (target unreachable).** `bankTarget` aims at the *newest* tier's cheapest
  capital (`hasCurrentDesired and cheapestCurrentDesired or cheapestDesired`,
  `:133`): 12,675-31,275 CP at tier 4-5. Measured income 16-20 CP/s, so that is
  630-1,950 s of income — longer than the 600-900 s window
  (`CapitalSavingSeconds`/`HeavyCapitalSavingSeconds`,
  `fs2rts_config.lua:788-790`). `ai_invariants.py bank_target_reachable` FAILs
  11/12 faction-matches with `peakOverTarget` 0.507-0.681 (baseline 1.15-1.61).
- **D2 (fallback mis-spend).** At expiry the fallback cannot buy the goal
  (`cheapestDesired` is not yet affordable) and instead spends the bank on a
  cheap hull, clearing the clock (`:305`). The window is designed to end in a
  purchase and it never does.
- **D3 (station has no capital awareness).** 21,225 CP of upgrades + up to
  8,625 CP of sentries are bought against a 1,500 CP floor while the fleet is
  4,000-7,000 CP short.

D1 and D2 are in `fs2rts_ai_production.lua` (files another agent owns). D3 is in
`fs2rts_station.lua`.

## 5. Ranked candidates

### M1 — Fallback buys the goal or nothing (fix D2)

**Touches:** `fs2rts_ai_production.lua:250-254`, the `savingFallback` branch.

When `savingFallback` fires and `state.cp < cheapestDesired`, do **not** fall
through to the weighted draw over cheap hulls. Either (a) extend the window, or
(b) return `nil` with a distinct reason and leave the bank intact.

```lua
if decision.savingFallback then
    local replacements={}
    for _,c in ipairs(candidates) do if c.category==desired then replacements[#replacements+1]=c end end
    if #replacements>0 then candidates=replacements
    elseif state.cp < cheapestDesired then
        -- The goal is not affordable yet. Keep the bank and keep the clock.
        decision.reason="SAVING_FOR_DESIRED_ROLE"; decision.savingExtended=true
        return nil, decision
    end
end
```

**Effect on 0-capitals:** directly removes the 2,820-6,047 CP per expiry that
currently resets the bank. Over a 1,200 s run with two expiries that is
~9,000 CP returned to the bank — enough for one capital.
**Trade-off:** the AI goes dark for longer stretches. `build_purchase_rate`
already fell 5.6 %→4.8 % vs baseline; this pushes it lower. A faction that
cannot bank its goal in 600 s now may bank nothing at all for a full 1,800 s.
**Risk:** needs `savingSeconds` to be reachable, or it is a permanent blackout.
Must ship *with* M2 or the AI simply stops producing.
**Verdict: BUG FIX.** The fallback's stated purpose (`:231-233`) is "prefer that
role when affordable, otherwise buy an affordable role" — it currently does not
do that; it buys a role that is not affordable-for-the-goal at all, because the
filter falls through silently. Behaviour-preserving against its own contract.

### M2 — Make the save target the *bankable* goal (fix D1)

**Touches:** `fs2rts_ai_production.lua:133` and `:139-143`;
config `fs2rts_config.lua:730, 788-790`.

Aim `bankTarget` at `cheapestDesired` (7,700-8,600) rather than
`cheapestCurrentDesired` (12,675-31,275), or shorten the window so the target is
reachable: 7,700 CP at 18 CP/s needs ~430 s of *uninterrupted* saving, inside
the 600 s `CapitalSavingSeconds`.

`BoundBankTarget` (`fs2rts_config.lua:787`, default `false`) is the existing
version of this and `ai_production.lua:153-162`. It was A/B'd and the config
comment at `:753-756` records that it did **not** rescue capital production —
because with `FieldCheapHullWhileSaving=false` the drain was not the policy, it
was the fallback mis-spend. **M2 alone will not work. M2 + M1 together might.**

**Effect:** makes the window's goal reachable, so the fallback at M1 has
something to buy.
**Trade-off:** the AI buys a tier-3 capital (Deimos/Ravana/Sobek, 7,700-8,600)
rather than a tier-5 juggernaut. Design-wise this is the *right* call — a
tier-5 Colossus at 13,825 costs 2.6× a capital's build time
(`purchaseBuildSeconds` 345 vs 215 in the RUN record) and would arrive after
the match decided itself. It also means the tier-5 roster entries
(`fs2rts_config.lua:395`, `ClassMultipliers.juggernaut = 0.14`) stay decorative.
**Verdict: BALANCE.** It changes what the AI fields, visibly, in front of the
player. Needs an A/B with `replacement_value_final` and `losses_units` as gates.

### M3 — Reprice tier 4 heavies (the mispricing fix)

**Touches:** `fs2rts_config.lua:425-428` (`ClassMultipliers`). Add
`Hecate`/`Orion`/`Typhon`/`Demon` alongside the five already there.

Tier 4 lasts 330 s and unlocks hulls costing 29,375-34,425 CP = 1,728-2,025 s
of income (table in M6). Following the existing precedent —
`Hatshepsut = 0.30` produced GOLD a tier-4 hull at 12,950, the only one any
faction could conceivably bank — those four want roughly **0.30-0.40**, landing
at 9,000-14,000 CP.

**Effect on 0-capitals:** converts a guaranteed-dead 330 s into a viable one.
It does not by itself fix tier 3 (0.94× of the window's income) or tier 5,
where the real blocker is the fallback mis-spend.
**Trade-off:** Hecate at 29,375 currently has `purchaseBuildSeconds` 734 s. At
0.30 that becomes ~220 s, in line with a capital's 208-215 s. That is the honest
cost: **the AI gets heavies at capital prices.** If heavies are meant to feel
like a late-match commitment, this destroys that. The counter is that they
currently feel like nothing at all, because no faction has ever bought one.
**Second trade-off:** `TierMultipliers[4] = 4.50` also feeds `GetPurchaseEstimate`
for the *player* (`fs2rts_production.lua`), so this is a player-facing price
change, not an AI-only one. That makes it BALANCE for Blue even though it is a
BUG FIX for the AI.
**Verdict: BUG FIX for the AI's behaviour, BALANCE for the player's economy.**
Gate on `roster_escalation` and on `cp_spent_production`.

### M4 — Capital-aware station gate (fix D3)

**Touches:** `fs2rts_station.lua:962-973` (`affordable`) and the two call sites
`:1032` (sentry) and `:976` (`tryUpgrade`).

Make the station's floor *rise* when the fleet producer holds an unmet capital
goal, instead of being capped at 1,500:

```lua
local stationReserve = math.min(reserve, math.max(0, tonumber(aiCfg.StationReserveCap) or 1500))
-- NEW: if the producer is mid-save for a goal it cannot afford, back off.
if production and production.savingSince and (production.savingRole or ""):find("capital") then
    stationReserve = math.max(stationReserve, (production.bankTarget or 0) - (production.cp or 0))
end
```

**Effect:** the largest single lever. Frees 21,225 CP of upgrades + sentries
across a match, which is 2.5 capitals' worth.
**Trade-off, and this is the honest one:** the station buys **no upgrades for
600-900 s at a time**. Armor L3 buys +60 % hull and ARMOR L2 unlocks the
out-of-combat repair that the peer agent measured as taking
`station_hull_final_frac` 0.853→0.950 in the current batch. Suppressing it
likely walks that metric back toward the baseline. That is *not* obviously bad —
the baseline also built capitals, and it also had 67 losses instead of 132 —
but it means this candidate trades base durability for capital presence, and a
player who relies on turtling will feel it.
**Second trade-off:** this is the mechanism most likely to make the AI feel
defenceless mid-match. A faction with no sentries and no armor upgrades for ten
minutes is a faction a player can kill.
**Verdict: BALANCE.** High gameplay-visible effect; needs `station_hull_*`,
`losses_units`, `station_beam_hits` as gates.

### M5 — Sentry quota separated from the pool

**Touches:** `fs2rts_station.lua:1029-1039`.

Per-tier cap, or a separate `sentryBudget` funded from income rather than the
bank.
**Effect on 0-capitals: small.** Sentries are 3,000-8,625 CP per faction-match.
Suppressing them entirely frees less than one capital.
**Trade-off:** a per-tier cap directly weakens the base-defence answer that
just got fixed. Current batch already shows `station_hull_final_frac` 0.9584 and
`station_hull_min_frac` 0.6881 (down from 0.8149 — a *regression* the
regression gate flags). Capping sentries attacks the metric that is already
worse.
**Verdict: BALANCE, low value.** Only worth doing if the goal is base
*identity* rather than capital production.

### M6 — Cheaper sentries

Same objection as M4 with extra cost: a new T0 sentry class needs a ship entry,
a weapon, and turret wiring (`fs2rts_station.lua:450-457` resolves the weapon
class onto every turret bank). It also undercuts the existing hull-value balance
that `RoleMultipliers` (`fs2rts_config.lua:415-422`) is built around.
**Verdict: BALANCE, not justified by the data.**

### M7 — Capital cost reduction (tier 3)

**Touches:** `fs2rts_config.lua:411` (`TierMultipliers`), `:425-428`
(`ClassMultipliers`).

Is 7,700 correct? Income is **16-0-18 CP/s** per faction
(`FACTION.economy.flowCumulative`: 48,122-53,716 CP over 3,000 s = 16.04-17.91
CP/s). Lifetime income for a 1,800 s 30 MIN match at the *target* duration is
~29,000-32,000 CP. A 7,700 CP capital is **24-27 % of a whole match's income** —
about 7.7 minutes of production, while a tier-1 fighter wing (1,300-1,600 CP) is
45 seconds.

The `Duration = "30 MIN"` profile has `targetSeconds = 1800` but
`max_sim_time = 3000` in `batch.plan.json`. The batch runs **1.67× the intended
match length** and still produces zero capitals. That is the strongest single
argument that the tier-3 capital price is *not* the problem: at 1.67× duration
with 93-116 % of income already committed, the AI has no slack at any price above
~1,000 CP.

**The tier-4 tier is a genuine mispricing bug, and it is worse than the
mechanism.** Measured against the real unlock schedule
(`tierUnlocks = {0,240,570,1050,1380}`, income 17 CP/s):

| tier | window | income earned in that window | cheapest tier hull | price as multiple of the window's income |
|---|---|---|---|---|
| 3 | 570-1,050 s (480 s) | 8,160 CP | Ravana 7,700 | **0.94×** — marginal |
| 4 | 1,050-1,380 s (**330 s**) | 5,610 CP | Typhon/Hecate 29,375 | **5.2×** |
| 5 | 1,380-3,000 s (1,620 s) | 27,540 CP | Sathanas 12,675 | **0.46×** — fine |

Tier 4 lasts **330 seconds** and unlocks hulls costing 29,375-34,425 CP, which
is 1,728-2,025 s of income. The `bankTarget` histogram by tier confirms the AI
spends that whole window aiming at an impossible price:

```
BLUE tier=4 n=41 bankTargets={29375.0: 41}     RED tier=4 n=37 bankTargets={31275.0: 36}
GOLD tier=4 n=41 bankTargets={12950.0: 33}     (GOLD's Hatshepsut is 0.46x -- the only viable t4)
```

GOLD is the only faction whose tier-4 hull is affordable (Hatshepsut 12,950 via
`ClassMultipliers = 0.30`, `fs2rts_config.lua:426`), and even GOLD built nothing.
So tier 4 is a dead 330 s for every faction, and tier 3 at 0.94× is too tight to
land a purchase before escalation moves the target again.

`TierMultipliers[4] = 4.50` against `[3] = 2.75` and `[5] = 6.50`
(`fs2rts_config.lua:411`) compounds the hull-size jump with a 1.64× price jump.
The `ClassMultipliers` table already reprices five outliers downward
(`Hatshepsut` 0.30, `Ravana` 0.30, `Colossus` 0.50, `Sathanas` 0.65); **Hecate,
Orion, Typhon and Demon are the ones left at 1.00.** They are not expensive
because they are strong — they are expensive because nobody repriced them.

**Verdict: repricing tier 4 is a BUG FIX** (the price is provably outside the
window it is offered in), and it is the highest-value single number change
available. Repricing tier 3 is a BALANCE change and the data does not support it.

## 6. Recommendation

**M1 + M2, shipped together, with M3 (tier-4 repricing) as an independent
one-number change and M4 (station gate) behind a flag.**

The pairing is forced, not preferred. M1 alone leaves the window expiring
against an unreachable target, which is a permanent blackout. M2 alone leaves
the fallback spending the bank on a cheap hull, which is the measured
mechanism. Only together do they make the window end in the purchase it exists
to enable — which is what PR-11 promises and PR-19 forbids breaking.

M3 is separate because it is one config number and it fixes a different tier
than M2. M2 fixes tier 5 (target 12,675 in a 1,620 s window = 0.46×, fine).
M3 fixes tier 4 (target 29,375 in a 330 s window = 5.2×, impossible). They do
not overlap, so they can be A/B'd independently.

M4 is the largest lever on the CP budget — 21,225 CP of upgrades, 40 % of
lifetime income — but also the one a player would feel most, so it wants its
own A/B rather than riding along.

### Strongest argument against

**M1 + M2 make the AI build one capital per faction per match and stop there —
and the batch data says that is the *ceiling*, not the floor.** Baseline is the
control here: it built 1-3 capitals per faction per match and lost
`losses_units` 67 with `losses_capital` 30.5. A capital-class hull dying is a
far bigger event than a fighter dying. The current batch's
`losses_capital` = 1 is an artifact of building none, not a safety record.

More concretely: RED in match `a-1790853256945607800` banked from 7,795 to
**11,379 CP** across 21 consecutive decisions at the end of the match, with
14-15 affordable options, a 7,700 CP capital unlocked and in the roster, and
`slots=65` of a 72 cap. Under M1+M2 that becomes a capital. Under M4 it also
becomes a capital. But it also means the AI arrives at the player's base with
7,700-8,600 CP of hull it did not have before, in a match where
`unengaged_fraction` is already 0.9121 — the AI is barely fighting. Making the
opponent suddenly able to siege is a difficulty change disguised as a bug fix,
and `replacement_value_final` already moved +31.5 % in the safe direction
without a single capital.

The counter to that counter: `engage` behaviour is doctrine
(`fs2rts_config.lua:816-886`), not production. A capital that never leaves the
station is 8,600 CP of nothing. But I cannot prove from this telemetry that
the strategic layer would *use* it — `unengaged_fraction` 0.9121 is the reason
this is an open question rather than a settled one.

## 7. Cheapest to validate in one batch

**M2 alone, as a one-line config default flip.** `BoundBankTarget` already
exists at `fs2rts_config.lua:787`. Setting it `true` runs the M2 logic through
`fs2rts_ai_production.lua:153-162` with zero source edits and produces a direct
A/B against `savepolicy-20261001` on identical seeds. It is *expected to fail*
(it does not include M1), which makes it a useful **falsification test**: if
`BoundBankTarget=true` still yields zero capitals, D1 is not the blocker and my
ranking is wrong. That is the highest-information single run available, and it
costs one batch.

Runner: `ai_invariants.py` for `roster_escalation` + `bank_target_reachable`,
`compare_batches.py` against `session-fix-20260930` (which does build capitals)
for `losses_units`, `replacement_value_final`, `station_hull_*`.

Note the baseline's runs were 2,569-2,813 s and the current 3,000 s, so
`compare_batches` flags `DISJOINT DURATION RANGES` and every unnormalized total
is unusable. Gate on rates and on the two invariant checks, not on totals.

## 8. What I could not determine

- **Whether upgrades or sentries caused the regression.** Both rose.
  `cp_upgrade_spend` has no baseline value (`compare_batches` reports baseline
  0) because the baseline batch predates the emitter fix at
  `fs2rts_ai_planning.lua:1056-1058`. Baseline `FACTION` records have
  `upgradeLevels = None`. So the 29-38 % upgrade share is **current-batch only**;
  I cannot say whether the baseline also spent 21,225 CP on upgrades and simply
  bought capitals anyway by accident. This is the single biggest gap and it
  changes the ranking of M3.
- **Whether the bank ever *would* hold 8,600 CP if the fallback stopped
  spending.** I can compute that the fallback spends 2,820-6,047 CP per expiry
  and that runs are 600-1,400 s long, but I cannot prove the resulting trajectory
  without running M1.
- **`production_spend_reconciles` FAILS at 22-50 % residual in all 12
  faction-matches** (`flow-above-build-events`). Adding `upgradeSpend` closes
  most of it — e.g. BLUE match 1: flow 56,972, build events 24,775 + sentry
  3,750 + upgrade 21,225 = 49,750, residual 7,222. The remainder is the ~10 %
  unattributed spend a peer agent already flagged and did not resolve. Not
  mine, but it means the 93-116 % income-coverage figure has ~10 % uncertainty.
- **Whether `damageDealt`/`stationDamageDealt` still being the string
  `'unknown'`** (`fs2rts_ai_planning.lua:836`) affects this batch.
  `compare_batches` reports `damage_dealt_known` 0 baseline → 294 candidate, so
  the candidate batch predates that fix too. Damage dealt is not measurable here.
- **The Blue-player experience.** `Setup.DefaultAutoMode = false`
  (`fs2rts_config.lua:480`), and these batches run `autoPlayer: true` with
  `setup.autoPlayer` in the RUN record. Blue is playing itself in all four
  matches. Any statement about the human experience is extrapolation.
- **Whether the 30 MIN profile is the one players actually use.**
  `DefaultDuration = 1` → 30 MIN, `targetSeconds = 1800`, but batches ran 3,000 s.
  If real play is 1,800 s, every income figure above is 40 % too high in
  absolute terms and the capital is *less* affordable, not more — and the
  tier-window table in M3 gets strictly worse, because a 330 s tier-4 window is
  the same 330 s but the surrounding income is gone. The ratios (upgrade share,
  income coverage, tier-4 window multiple) are duration-independent and hold.
- **Whether the player's own `GetPurchaseEstimate` reads the same
  `ClassMultipliers`.** If yes, M3's tier-4 repricing is a live price change for
  Blue and needs a balance A/B, not a bug-fix merge. I read
  `fs2rts_production.lua:150` guarding the deduct but did not trace the estimate
  function's config path end to end.
