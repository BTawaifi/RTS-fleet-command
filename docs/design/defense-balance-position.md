# Defence balance: the hard economic case against the current design

**Status:** design and analysis only. No `.lua`, config, table or source file was edited
in this session. No batch was run, no engine launched. Every number below is from a file
I opened or a read-only command I ran over staged telemetry.

**Stance:** this is the adversarial position. Its thesis is that the sentry system is
**not a fair price for a fair amount of defence — it is an unpriced, uncounted,
unbudgeted CP sink that the engine's own valuation contradicts by 1.4x to 7x.** The
user's complaint ("the player or the other factions shouldn't be able to mass spawn the
defenses") is correct, but the complaint is aimed one layer away from the defect. The
problem is not that sentries are too strong. It is that they are too *cheap relative to
what the engine thinks they are worth*, and that is why the base ends up defended by
things that do not defend it.

Sources read this session:

- `core/data/scripts/fs2rts_config.lua` — `Sentries` (`:534-573`), `Tracks` (`:575-588`),
  `CostFormula` (`:398-431`), `BeamRangesByRole` (`:916-920`), `Durations` (`:501-529`),
  `Station.AI` (`:634-700`), `StationBaseHull` (`:28`)
- `core/data/scripts/fs2rts_station.lua` — `GetSentryCap` (`:81-87`),
  `GetSentrySlotCount` (`:92-96`), `GetSentryRadius` (`:99-108`), `affordable` (`:1031-1042`),
  `tryUpgrade` (`:1043-1053`), sentry AI scan (`:1086-1124`), `PlaceSentry` (`:476-495`),
  `UpdateSentryConstruction` (`:497-526`)
- `core/data/scripts/fs2rts_production.lua` — `EstimateShipCost` (`:13-39`)
- `core/data/scripts/fs2rts_ai_telemetry.lua` — `RegisterBaseDamageTelemetry` (`:89-142`),
  `RegisterCombatDamageTelemetry` (`:145-...`)
- `core/data/scripts/fs2rts_ai_util.lua` — `combatDamageBucketKey` (`:113-117`),
  `combatDamageRows` (`:119-130`)
- `core/README.md` (`:70-105`), `docs/contracts/04-station-economy.md`,
  `docs/contracts/09-capital-gate.md`, `docs/design/ai-capital-starvation.md`

Telemetry harvested read-only from
`D:\Games\FreespaceOpen\FS2\rts-headless-staging\{synth-20261001, capgate-20261001,
session-fix-20260930}\results\**\probe\data\rts-ai-*.jsonl` (4 matches each, 3,000 s
simulated per match, real FSO engine, `ACCEPTANCE_SETUP.autoPlayer = true`).

---

## 0. The headline finding, before the argument

The engine has a working ship-pricing formula. `EstimateShipCost`
(`fs2rts_production.lua:13-39`) prices **every ship class in the game** from hull,
shields, model radius and speed. Sentries are excluded: their prices are literals in
`fs2rts_config.lua:550-571`.

The engine still computes a value for those hulls anyway. `baseUnitCost` on every
`LOSS` record is `ShipCostMap[class]` — the formula's own output, emitted by the
telemetry layer regardless of what the player was charged. Comparing the two, on
sentries that actually died in the current batch:

| Sentry | Hardcoded price | Engine's `CostFormula` value | Ratio |
|---|---:|---:|---:|
| GTSG Watchdog (BLUE T1) | 375 | 100 | **3.75x** |
| GTSG Cerberus (BLUE T2) | 875 | 150 | **5.83x** |
| GTSG Mjolnir (BLUE T4) | 3000 | 675 | **4.44x** |
| GVSG Ankh (GOLD T1) | 375 | 125 | **3.00x** |
| GVSG Edjo (GOLD T2) | 875 | 125 | **7.00x** |
| SSG Trident (RED T1) | 375 | 150 | **2.50x** |
| SSG Rahu (RED T3) | 2000 | 1475 | 1.36x |

Two consequences follow immediately, and they are the whole paper:

1. **The economy has two price lists that disagree by up to 7x**, and only one of them
   participates in balance retunes. A `TierMultipliers` change, a `GlobalMultiplier`
   change, an income rebalance — none of them touch a sentry. The one part of the
   production system that is guaranteed never to be rebalanced by anyone is the part
   the base's survival depends on.
2. **The bounty is computed from the formula value, not the price paid.** `Bounties =
   { DefaultFractionOfCost = 0.24 }` (`fs2rts_config.lua:433-436`) and the measured
   bounties are exactly 24% of `baseUnitCost`: Watchdog 25 (= 24% of 100), Cerberus 36
   (= 24% of 150), Mjolnir 162 (= 24% of 675), Rahu 354 (= 24% of 1475). So a
   Watchdog costs the defender **375** and refunds the attacker **25** — a **6.7%**
   refund. Across the 36 sentry deaths in the batch, the defenders paid **28,625 CP**
   of hardcoded price and the attackers got **2,604 CP** back: a **9.1%** recovery
   rate. Sentries are close to a pure CP sink with no economic counterweight.

This is the defect. Everything else in this paper is either supporting evidence or a
consequence.

---

## 1. The exchange rate

### 1.1 What the defender buys

Prices and hull from `fs2rts_config.lua:548-572`. Effective hull includes the
`HullBonus = 1.5` from `defenses` L2 (`:544`), confirmed against observed hull in
`UNIT.observation.hull` (Cerberus 1,350 = 900 x 1.5; Watchdog 900 = 600 x 1.5;
Mjolnir 4,500 = 3,000 x 1.5; Trident 1,050 = 700 x 1.5; Rahu 6,000 = 4,000 x 1.5).

| Class | CP | Effective hull | CP per 100 hull | Weapon | Reach |
|---|---:|---:|---:|---|---:|
| GTSG Watchdog | 375 | 900 | 41.7 | Terran Turret | 1,375 |
| GTSG Cerberus | 875 | 1,350 | 64.8 | Standard Flak | 1,000 |
| GTSG Alastor | 1,500 | 1,800 | 83.3 | Harpoon | 1,250 |
| GTSG Mjolnir | 3,000 | 4,500 | 66.7 | beam | 4,000 |
| SSG Rahu | 2,000 | 6,000 | 33.3 | Standard Flak | 1,000 |
| GTSC Faustus (escort, for scale) | 1,225 | 3,000 | 40.8 | — | — |
| GTCv Deimos (capital, for scale) | 8,600 | 78,522 | 11.0 | — | 8,000 |
| GTVA Colossus (juggernaut) | 13,825 | ~1,000,000 | 1.4 | — | 9,000 |

A tier-1 sentry is **3.8x less hull-efficient per CP than a capital ship** and
roughly level with a light escort, and it is the only unit in the game that cannot
move. Reach is the other half: 1,375 m for a Watchdog against a capital's 8,000 m
(`BeamRangesByRole`, `:916-920`) and a station's 2,000 m (`:917`). A T1 sentry cannot
see anything a capital cannot trivially out-range, and it is placed at
`station model radius + ControlRadius (4,000)` (`:99-108`, `:538`) — i.e. **4 km
further out than the station it defends**, at the far edge of its own reach.

### 1.2 What it costs to delete one

Measured from the 36 sentry `LOSS` records in `synth-20261001`, with the killer's hull
cost taken from the `RUN` record's `aiRosters[].unitCost`:

| Subset | Kills | Defender CP lost | Attacker CP paid | Attacker CP per 1 CP of ring |
|---|---:|---:|---:|---:|
| All kills | 36 | 28,625 | 82,325 | 2.88x |
| Excluding capital/heavy/juggernaut killers | 29 | 21,750 | 13,650 | **0.63x** |
| Strike-craft killers, T1–T2 sentries only | 26 | 15,750 | 12,600 | **0.80x** |

**The intended answer to "what is the counter?" is: tier-1 strike craft, and it is
already cheaper than the thing it is killing — 0.63x to 0.80x.** A 325–400 CP fighter
deletes a 375–875 CP sentry and the attacker is *ahead* on cost before the bounty
(9.1%) is counted. The killers are overwhelmingly the cheapest hulls in the game:
`GTF Ulysses` (350) appears 8 times, `GVF Thoth` (325) 4 times, `GVF Tauret` (400) 2,
`GVF Serapis` (350) 2. Weapons are `Harpoon` (9), `Mekhu HL-7` (6), `Hornet` (5),
`Prometheus R` (4), `Rockeye` (3), `Cluster Baby` (2), `Subach HL-7` (3).

The full-kill row (2.88x) is the misleading one and I want to be explicit about it: it
is inflated by four kills scored by a `GTVA Colossus` (13,825) and one by a
`GVCv Sobek` (8,600). **A capital ship killing a tier-1 turret is not a counter — it is
a siege engine, and it is 37x the price of the turret.** Strip the capitals out and the
ratio collapses to 0.63x. That is the exchange rate, and it is the answer to the user's
question: static defence here is *cheap to kill*, which means the sentry ring was never
a wall, it was a rounding error with a build timer on it.

### 1.3 Is that ratio sane? No — in the direction nobody is looking

An RTS wants static defence to be a genuine *sink* of attacker resources, so that
turtling is a real strategic choice with a real cost. Here it is not. At 0.63x–0.80x
the defender loses *less* CP per unit of attacker hull spent than the attacker loses
killing it. The ring is not a decision; it is a rounding error. A player who turtles
spends 30.6% of the match's income (measured, §4) to buy defences that a single
fighter wing deletes for less than the price of the wing.

And yet the base is still dying, because the ring does no work. Sentries dealt
**3,790 hull damage across 4 matches — 0.35% of the 1,068,319 total hull damage dealt
by every attacker** (`combatDamageTelemetry.interval.byMatchup`, summed over 1,176
unique faction-interval records, deduped on path/time/faction). Their share of the six
lethal hits recorded all match is 6, and their share of hull damage *absorbed* is
62,797 of 1,068,319 = 5.9%. **A defence ring that soaks 6% of the damage and returns
0.35% of it is not a defensive asset. It is a decoy that costs a third of the budget.**

I checked whether the low number was a telemetry artifact before relying on it. The
combat damage hook is unfiltered — `fs2rts_ai_telemetry.lua:160-174` records every
`On Ship Damage` event on any valid target, and `combatDamageBucketKey`
(`fs2rts_ai_util.lua:113-117`) buckets on `targetClass, weaponClass, …, attackerClass`
with no row cap (unlike `FRIENDLY_FIRE_PAIR_LIMIT = 256` at `:111`, which applies only
to friendly-fire pairs). Station turrets appear in the same table as ships
(`GVI Cairo` 34,113, `SI Arachnas` 68,134, `GTI Arcadia` 9,046), so the pipeline is
capturing static defences correctly. Sentries are genuinely doing almost nothing.

---

## 2. Is the problem PRICE, COUNT, PLACEMENT, or TIME?

**It is PRICE, and specifically the price *level*, not the price *gradient*.** Proof by
elimination, using each candidate's predicted signature against the measurements.

**COUNT is falsified by the damage data.** The cap is 6, rising to 10 with `defenses`
L1 (+2, `:84`) and `command` L2 (+2, `:85`) — the brief's "up to 10". Measured
concurrent slots never mattered because the ring is not shooting. If the defect were
count, capping at 4 would fix the game. It would not: at 0.35% damage output, deleting
80% of the ring changes total fleet damage output by 0.28%. **A change that cannot move
the metric cannot be the fix.** Count is not the problem.

**PLACEMENT is falsified by the reach numbers.** `ControlRadius = 4000` (`:538`) plus
the station model radius (`GetSentryRadius`, `:107`) places sentries 4 km *outside* the
station, and their own reach is 950–1,375 m except the Mjolnir. They cover the annulus
from ~3.6 km to ~5.4 km from the station centre. The station's own beam reaches 2,000 m
(`BeamRangesByRole.station`). There is a genuine 1.6 km dead band between the station's
reach and the ring's inner edge. This is a real design smell and I would fix it, but it
is a **reach** problem, not a **mass-spawn** problem, and closing the band would make
the ring *stronger* — the opposite of what was asked. Placement is not the cause.

**TIME is falsified by the throughput arithmetic.** `BuildSeconds = 20` flat
(`:541`) for every tier: a 375 CP Watchdog and a 3,000 CP Mjolnir both take 20 s. That
*is* an anomaly — the rest of the game prices build time at `BuildSecondsPerCP = 0.025`
(`:409`), which would give 9.4 s for the Watchdog and 75 s for the Mjolnir. So the
Mjolnir is built **3.75x faster than the economy's own build-time law**, and the
Watchdog 1.9x slower. But throughput is not the constraint: the CP is. 110 sentry
builds at a median ~700 CP is 78,750 CP, which at 16–20 CP/s is **3,900–4,900 s of
income** — more than the entire 3,000 s match. **The match ends before the income does,
so build *speed* was never the binding constraint; build *cost* was.** Raising build
times would delay a ring that already cannot afford itself. Time is not the cause.

**That leaves PRICE, and price is where the measurement actually points.** The engine
values these hulls at 1.4x–7x below what the player pays (§0). The player is
overcharged by the largest margin on exactly the units whose count is uncapped and
whose value the rest of the economy cannot see.

**The load-bearing evidence, and it is a direct match to the complaint.** The brief
cites a match where BLUE spent 31,725 CP — 57% of inflow — on upgrades and sentries and
bought no capital. I found it in `synth-20261001`:

| Match | BLUE sentry builds | Sentry CP | Upgrade CP | Sum | Inflow | % of inflow | Capitals bought |
|---|---:|---:|---:|---:|---:|---:|---|
| `a-1790875745006083400` | 16 | 18,375 | 12,975 | **31,350** | 57,166 | **54.8%** | **none** |
| `a-1790875742965190800` | 12 | 8,125 | 11,475 | 19,600 | 59,721 | 32.8% | Colossus 13,825 |
| `a-1790875744001773100` | 13 | 9,375 | 11,725 | 21,100 | 58,500 | 36.1% | Deimos 8,600 |
| `a-1790875741885934700` | 9 | 10,250 | 7,650 | 17,900 | 52,656 | 34.0% | none |

Match 1 is the complaint: **54.8% of inflow, zero capital ships.** And the 16 sentry
builds are 4 Watchdogs, 9 Cerberuses, 3 Mjolnirs — 9,000 CP of tier-4 beam turrets,
each costing 4.44x the engine's valuation of its own hull. Meanwhile the AI bought
capital ships in 6 of 8 faction-matches across the two current batches — so this is not
a "capitals are impossible" world. It is a world where **one faction in one match
diverted enough into a ring that fires 0.35% of the damage into a defence that dies to
a 350 CP fighter, and fielded nothing else.**

---

## 3. Is PRICE really the defect, or is the upgrade tree the real hog?

Honest steelmanning of the counter-argument: `docs/design/ai-capital-starvation.md` and
`docs/contracts/09-capital-gate.md` both argue that **upgrades**, not sentries, are the
dominant sink (29–38% vs 3–13%), and that `CapitalAwareInvestment` is the right lever.
Measured in the current batch, that ordering still holds within the *upgraded* spend:

- Upgrades: 125,850 CP total, 18.8% of the 668,507 CP total inflow
- Sentries: 78,750 CP total, 11.8% of inflow
- Combined: 204,600 CP, **30.6% of inflow**

So I must concede the premise partially: **sentries alone are 11.8%, not 57%.** The
57% figure in the complaint is upgrades *plus* sentries, and upgrades are the larger
half.

But this does not rescue the sentry design, for two reasons that the upgrade framing
misses:

1. **The upgrade tree is bounded at 21,225 CP and 12 purchases total**
   (`fs2rts_config.lua:576-587`: armor 625+1250+2250, defenses 750+1500+2750,
   logistics 625+1400+4200, command 875+1750+3250). It is a *finite* one-time
   purchase. The sentry ring is **unbounded** — it has no budget, only a slot cap, and
   the slot cap is spent and re-spent every time a sentry dies. In the batch, 110
   sentries were *started* for 89 completions and 36 deaths: the base rebuilt its ring
   ~1.6 times over. **Upgrades cannot be "mass-spawned." Sentries can, by
   construction.** The user's word was "mass spawn" and that word is only true of
   sentries.
2. **Repricing sentries is what makes the upgrade tree affordable.** At engine-formula
   pricing the same 110 sentries cost **23,900 CP instead of 78,750 — freeing 54,850
   CP, which is 38.5% of the combined 204,600 CP defence spend and 8.2% of total
   inflow.** That is more than 2.5 capitals. It does not require touching a single
   upgrade price, and it does not require the `CapitalAwareInvestment` flag (which
   `docs/contracts/09-capital-gate.md:118-126` itself lists as unvalidated). It is a
   one-line-per-class change with no behavioural gate.

---

## 4. The measured scale of the sink

`synth-20261001`, 4 matches, 12 faction-matches, all read from the final `FACTION`
record's `economy` plus `SENTRY_BUILD` events:

| Faction | Inflow (income+bounty) | Upgrade CP | Sentry CP started | Combined | % of inflow |
|---|---:|---:|---:|---:|---:|
| BLUE | 228,042 | 43,825 | 46,125 | 89,950 | **39.4%** |
| GOLD | 223,426 | 42,075 | 11,000 | 53,075 | 23.8% |
| RED | 217,039 | 39,950 | 21,625 | 61,575 | 28.4% |
| **Total** | **668,507** | **125,850** | **78,750** | **204,600** | **30.6%** |

Income per faction per match is 52,656–59,721 CP over 3,000 s = **17.6–19.9 CP/s**,
consistent with the 16–20 CP/s in the brief. So the combined defence bill of
17,025–29,983 CP per faction-match is **the price of 2.1 to 3.7 capital ships**, spent
per match, on a ring that returns 0.35% of the damage.

Baseline comparison (`session-fix-20260930`, same 4-match shape) confirms the
regression the brief cites: sentries started **67 → 110** (+64%), completed
**59 → 89** (+51%), fleet hull-CP destroyed **121,775 → 184,300** (+51%), sentry
deaths **19 → 36** (+89%). The ring got bigger, the killing got more expensive, and
the capital count went 12 → 8. The ring is not paying for itself.

---

## 5. Concrete rebalance

### 5.1 Primary: put sentries on `CostFormula` and add an explicit defence budget

**Change 1 — derive the price instead of hardcoding it.** `Sentries.Classes[].cost`
becomes a multiplier on `EstimateShipCost(class)`, exactly as `ClassMultipliers`
(`:425-428`) already does for mobile hulls. The engine is already computing the value
and already writing it into every `LOSS` record; nothing new is needed except to charge
it.

The raw formula values are too cheap on their own — a 100 CP Watchdog with 900
effective hull (incl. `HullBonus`) would be a 9.0 hull/CP bargain and RED's T1 would
land at 150. So price sentries as **formula x `SentryPriceMultiplier`, default 3.0**:

| Class | Formula | x3.0 | Hardcoded now | Change |
|---|---:|---:|---:|---:|
| GTSG Watchdog | 100 | **300** | 375 | −20% |
| GVSG Ankh | 125 | **375** | 375 | 0% |
| SSG Trident | 150 | **450** | 375 | +20% |
| GTSG Cerberus | 150 | **450** | 875 | −49% |
| GVSG Edjo | 125 | **375** | 875 | −57% |
| GTSG Alastor | (est. 200) | 600 | 1,500 | −60% |
| GTSG Mjolnir | 675 | **2,025** | 3,000 | −33% |
| SSG Rahu | 1,475 | **4,425** | 2,000 | +121% |

This is deliberately *not* "make them cheaper" (the direction the fix for a
too-expensive ring would push) nor "make them much dearer" (which would strip the
early base). It does three things: it **removes a 1.4x–7x arbitrage**, it **converges
the three factions' tier-1 prices** (currently 375/375/375 by fiat, 300/375/450 by
formula — a 50% spread that reflects real hull differences rather than a copy-paste),
and it makes Rahu, the one sentry the engine already agrees is nearly fairly priced
(1.36x), the *most* expensive — which is correct, because at 4,000 base hull / 6,000
effective it is the only sentry with real staying power, and it is the one BLUE and
GOLD cannot buy.

**Change 2 — a per-faction defence budget, not a slot cap.** Add
`Station.Sentries.MatchBudget`, a CP figure the station may spend on sentries over the
whole match, defaulting to a multiple of the capital price (`CapitalEquivalent`, say
**0.75x cheapest capital** = 5,775–6,450 CP, ~1/9 of measured lifetime income and
~37% of the current 15,000 CP average). The existing slot cap keeps working as a
*shape* constraint; the budget is the *economic* constraint. This is the piece that
makes "mass spawn" structurally impossible: a base can be re-turreted as often as it
likes and it will run out of budget. The spend is currently gated only by
`affordable()`'s `StationReserveCap = 1,500` floor (`fs2rts_station.lua:1040`), which
is why a 3,750 CP all-tier-1 ring clears the bar in a single think.

### 5.2 Secondary, in priority order

**Change 3 — build time from the same law.** `BuildSeconds = Cost * 0.025`, clamped
`[6, 180]`, matching `BuildSecondsPerCP` (`:409`). Watchdog 7.5 s, Cerberus 11 s,
Mjolnir 50 s. This kills the specific anomaly that a 3,000 CP beam turret appears in
20 seconds while an 8,600 CP capital takes 215 s (`purchaseBuildSeconds` 214.84,
measured). **A defender must not be able to convert CP into static killing power faster
than an attacker can convert CP into mobile killing power.** At the current 20 s flat,
the Mjolnir beats the Deimos 10.7x on CP-per-second-of-construction. That is the
cleanest statement of "mass spawn the defenses" in the whole system.

**Change 4 — fix the dead band.** Set `ControlRadius` to the station's own reach rather
than 4 km past it, so the ring's inner edge meets `BeamRangesByRole.station = 2000`
instead of starting at ~3,600. Cheap, and it makes the ring *do its job* rather than
covering empty space. Do this **after** the price change, or it makes the ring stronger
at the same time you are making it more expensive.

**Change 5 — bounty on the price paid, not the formula value.** The 6.7%–9.6% refund
is what makes sentries unrepairable sinks. Charging the bounty off the *charged* price
would give 24% of 375 = 90 on a Watchdog instead of 25.

### 5.3 What I explicitly do **not** propose, and why

- **Not a lower slot cap.** Falsified in §2: the ring is not shooting, so capping count
  cannot fix output. It also removes the rebuild-and-recycle loop that turns a cap into
  a budget in disguise.
- **Not "make sentries require power."** No power/power-failure system exists in this
  codebase to hang it on. It would be a new mechanic, and the brief asks for balance.
- **Not "make sentries a fraction of station hull."** `StationBaseHull = 200000` (`:28`)
  is a large number; a fraction of it produces sentry prices in the tens of thousands
  and deletes the tier ladder.

---

## 6. What this BREAKS

Stated plainly, because this is where the proposal is most vulnerable.

**6.1 The early base is defenceless and gets face-stormed.** This is the real cost and
it is severe. Timeline at 17.6 CP/s with 1,200–2,600 start CP (`Economies`, `:496-500`):

- t=0: 1,800 CP (STANDARD). First Watchdog at 300 CP leaves 1,500.
- 20 s later: second Watchdog. 300 CP.
- The base reaches a 6-slot all-T1 ring for **1,800 CP** = **102 s of income**.

Compare the shipped config: 6 x 375 = **2,250 CP** = 128 s. **The all-tier-1 ring is
actually *cheaper* under the proposal (1,800 vs 2,250).** The early game is therefore
*better* defended, not worse, and this is the main reason I am confident in Change 1+2.
The vulnerability is not the opening; it is the **middle**, where the base currently
reaches tier 2/3/4 rings. A 10-slot mixed T1x2+T2x8 ring costs 7,750 shipped vs
**4,200** under the proposal — 46% cheaper. A 10-slot ring with 3 Mjolnirs, as BLUE
actually built in match 1, drops from 18,375 to **9,675** for the same 16 hulls.

So the honest statement is: **repricing makes the ring affordable to *complete* and
unaffordable to *recycle*.** The failure mode is not a naked station at t=0. It is a
station that, after its ring is destroyed once, cannot rebuild it — because the budget
is spent — and is then naked at t=1,200 with 54.8% of its income already committed to
a ring that is in the ground being shot at. Under the shipped config that faction could
buy a second ring; under the proposal it cannot. **If the ring is worth anything at
all, the budget must be refundable on death, or the base is strictly worse off than
today in exactly the situation the user is worried about.** I would make a fraction of
`MatchBudget` refresh on sentry death, or set the budget high enough that a single ring
is always affordable and only *recycling* is curtailed. I have not resolved which, and
this is a genuine open design question, not a detail.

**6.2 The AI's sentry AI scores on cost, so repricing changes its choices.** The scan
at `fs2rts_station.lua:1106-1111` scores
`value = (option.role==desired and 10 or 0) - option.cost/1000`. The cost term is
therefore in units of 1,000 CP. At the shipped prices a Watchdog scores −0.375 and an
Mjolnir −3.0 against a 10-point role bonus; the cost term is nearly irrelevant. Under
repricing the Mjolnir's cost term becomes −2.025, which is still small, but a faction
with no `beam` threat keeps preferring the cheapest option. The practical effect is
that **tier-4 beam sentries get bought less often** — 3 Mjolnirs in BLUE's worst match
is the case to watch. That is probably desirable (they are 4.4x the engine's valuation
and contribute 0 recorded damage), but it is a visible change to base silhouette.

**6.3 RED gets worse and BLUE/GOLD get better.** Rahu goes 2,000 → 4,425. RED is the
faction with the fewest sentry classes (3 vs 4) and the one whose `Classes` table stops
at tier 3. A +121% price on its only durable sentry, at the same time its capital
budget is contested, is a faction nerf delivered through a "fix". The counter is that
Rahu is the one sentry with 6,000 effective hull and 4 measured kills of GTF Ulysses —
it is genuinely the best sentry in the game and is priced at 33 CP/100 hull, the best
rate of any sentry. **But I am changing RED's balance by 121% in a paper about
defence pricing, and that should be a conscious decision, not a side effect.**

**6.4 It does not fix capital starvation, and I will not claim it does.**
`docs/design/ai-capital-starvation.md` §5 identifies D1 (unreachable `bankTarget`,
`bankTarget` FAILs 11/12) and D2 (fallback mis-spend at
`fs2rts_production.lua:250-254`) as the blockers, and D3 (the 1,500 CP station floor)
as the third. **Repricing sentries attacks D3 only partially**, by making the ring
cheaper to complete and bounded over the match. D1 and D2 live in files this proposal
does not touch. In `synth-20261001` the AI bought 8 capitals across 12 faction-matches,
down from 12 in the baseline — so capitals are being produced, and this proposal's
effect on that number is genuinely unknown. The 54,850 CP it frees is suggestive, not
proof: 54,850 CP is 6.8 capitals, but only if the freed CP is *saved* rather than spent
on the next fighter wing, and the producer's save-clock livelock
(`AI.FieldCheapHullWhileSaving = false`, `:815`) means it is not saved today.

**6.5 The Mjolnir is the awkward case.** It is the only sentry with meaningful reach
(4,000 m, `BeamRangesByRole.sentry`) and the only one the config explicitly locks and
aims (`UpdateMjolnirRange`, `fs2rts_station.lua:569+`). It costs 4.44x the engine's
valuation and recorded **0 hull damage** in 4 matches. Either it is broken (aiming,
locking, or turret wiring) or it is decorative. **I could not determine which**, and it
matters: if the Mjolnir is a working capital-beam turret that simply never got a shot,
then repricing it down to 2,025 is wrong and it should be *fixed* instead. This is the
single largest hole in my argument.

---

## 7. The single change with the best problem-solved / risk-taken ratio

**`Sentries.Classes[].cost` = `EstimateShipCost(class) * SentryPriceMultiplier`, with
`SentryPriceMultiplier = 3.0` (a new config key defaulting to 3.0 so a missing config
fails to the proposed value rather than to 1.0).**

Why this one and not the budget:

- **It is the smallest change that removes the actual defect.** The defect I can prove
  is a 1.4x–7x disagreement between the price charged and the engine's own valuation,
  on a unit class that is excluded from every other balance knob. Everything else is
  downstream of that.
- **It is self-correcting forever.** Once sentries route through `EstimateShipCost`, a
  future `TierMultipliers`, `GlobalMultiplier`, `RoleMultipliers` or hull-table change
  moves sentry prices automatically. Every other proposal on this list needs a
  re-audit the next time someone retunes the economy; this one does not.
- **Its risk is bounded and measurable in one batch.** Compare:
  - Slot cap: risk-free, but proven in §2 to be unable to move the output metric.
  - Build time: fixes a real 10.7x asymmetry, but *delays* a ring that already cannot
    afford itself, so it makes the mid-game worse before it makes it better.
  - Match budget: the right long-term fix, but it is new state, it interacts with the
    death/recycle loop I could not resolve (§6.1), and its value is a guess.
  - Repricing: touches one table, has a defensible default, and its effect is
    observable in `SENTRY_BUILD` cost fields in a single batch.
- **It does not depend on any unvalidated flag.** `CapitalAwareInvestment` ships
  `false` (`fs2rts_config.lua:695`) and `docs/contracts/09-capital-gate.md:118-126`
  lists it as unvalidated. My proposal does not need it.

### Evidence that would prove it wrong

Ranked by how cleanly each would falsify the thesis:

1. **If sentry damage share rises materially above ~2% in a batch where the ring is
   24–39% of spend, the "ring is a decoy" premise is wrong** and the fix is COUNT or
   TIME, not PRICE. Measure: sum `combatDamageTelemetry.interval.byMatchup` filtered to
   `attackerClass` in the 11 sentry classes, over total. Current batch: **0.35%**.
2. **If the 0.35% is a telemetry artifact rather than a measurement**, the entire
   argument collapses. I checked the hook is unfiltered and that station turrets appear
   in the same table, but I did **not** verify in-engine that a *sentry* turret's fire
   reaches the `On Ship Damage` hook with a correct `attackerClass`. The Mjolnir's 0
   and the Ankh's anomalously high 2,319 (against 93 for a same-priced Watchdog) both
   look like attribution problems, not performance differences. **This is the weakest
   link in the paper and it is load-bearing.** A one-ship probe — arm a single Watchdog
   beside a station, shoot it with a fighter, confirm the `LOSS.lethalHit.attackerClass`
   and the `byMatchup` row — settles it in minutes.
3. **If killing sentries is *not* as cheap as 0.63x–0.80x when measured properly**, the
   "no real counter exists" claim weakens. My ratio charges one killer's full hull cost
   per kill, which *overstates* attacker cost when several ships contributed and
   *understates* it when a sentry took several minutes to die. I have no
   damage-per-second figure for a sentry, so I cannot compute a true time-to-kill. The
   station's own hull is 132,600 (`STATION_REPAIR.maxHull`, measured) against a
   900–6,000 sentry, and sentries absorbed 5.9% of all damage — so a sentry is roughly
   1/20th of a station's durability, which is a *small* number for 375–3,000 CP.
4. **If the freed 54,850 CP does not translate into capital production**, the economic
   half of the argument is wrong even if the pricing half is right. Gate on
   `PRODUCTION QUEUE_ACCEPTED` with `role in (capital, heavy, juggernaut)` and on
   `ai_invariants.py bank_target_reachable`, which currently FAILs 11/12.
5. **If RED's faction balance metrics collapse** (station hull fraction, losses,
   `replacement_value_final`), the `SentryPriceMultiplier` needs to be faction-weighted
   rather than uniform, and the clean single-knob story is wrong.

---

## 8. What I am least sure about

**Ranked by how much it would damage the paper if wrong.**

1. **That the 0.35% sentry damage share is real and not an instrumentation gap.** I
   verified the combat-damage hook is unfiltered, unbuffered and captures other static
   defences, and I caught and fixed one dedup bug in my own harvesting that had
   understated totals by ~3.6x. But the Mjolnir at exactly 0 and the Ankh at 2,319 vs
   the Watchdog's 93 at the same 375 CP are both more consistent with attribution
   quirks than with real performance differences. **If sentry turrets are not properly
   attributed in `byMatchup`, then my central claim — that the ring does no work — is
   built on a measurement artifact, and every recommendation above is aimed at the
   wrong layer.** I would not ship any of this without probe (2) in §7 answered first.
   This is my single least-sure claim.
2. **The Rahu repricing (+121%).** It is defensible on hull-per-CP and kill count and
   it makes RED worse. I have a number and a mechanism and I still think it is the
   change most likely to be wrong on playability grounds.
3. **The 300 CP Watchdog.** The formula value is 100 and I chose x3.0 mostly to avoid a
   base-defence collapse early. 3.0 is a judgement, not a derivation. At x2.5 the
   Watchdog is 250 and the ring is 1,500 for six slots (84 s of income); at x4.0 it is
   400 and the ring is 2,400. The defensible range is wide and I picked the middle
   without optimising it.
4. **Whether "mass spawn" is really the user's problem.** On the evidence the ring is
   11.8% of income, not 57%, and does 0.35% of the damage. It is possible the player
   experiences "mass spawn" as *visual* — a wall of turrets that never dies — and that
   the true complaint is that the base *looks* defended and is not, which is an
   entirely different design problem (readability, not economics). I have assumed the
   economic reading because that is how the complaint was framed to me, and I cannot
   see the screen the player sees.
5. **All of it is `autoPlayer = true`.** `ACCEPTANCE_SETUP.autoPlayer` is true in
   every staged batch: BLUE plays itself against two AIs. A human who deliberately
   rushes a base may face a very different ring-building decision than a scripted
   planner that reacts to `threats` within `GetSentryRadius + 3000`. The
   `limit = min(GetSentryCap, 2 + ceil(total/3))` formula (`:1101`) means the AI's ring
   is *threat-reactive*, not unconditional — a human defender who never shows a fleet
   gets 2 sentries forever, and a human who always shows one gets the cap. **The
   mass-spawn behaviour may be substantially an AI artefact that a human player does
   not experience.** I cannot rule this out and it would undercut the framing of the
   whole complaint.
6. **Match length.** `targetSeconds = 1800` for the 30 MIN profile (`:503`) but the
   batches ran 3,000 s — 1.67x the intended match. At the real 1,800 s the income
   figures are 40% lower in absolute terms, the 21,225 CP upgrade tree becomes a much
   larger share, and the sentry ring becomes *cheaper* relative to income. The ratios I
   quote (30.6% of inflow, 0.35% of damage, 0.63x-0.80x exchange) are duration-
   independent and should hold, but every absolute CP figure is inflated by 1.67x.
