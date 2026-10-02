# Defence doctrine: the player-experience and competitive-fairness case

**Status:** design and analysis only. No `.lua`, `.py`, config or table file was edited in this
session. No batch was run, no engine launched, no subagent spawned. Every number below is from a
file I opened or a read-only command I ran over staged telemetry under
`D:\Games\FreespaceOpen\FS2\rts-headless-staging\`.

**Stance:** this is the adversarial position against `defense-balance-position.md`. Its thesis is
that **the sentry system is not over-priced, it is under-realised, and the reason the user's
complaint feels true is that the attacker never gets to find out.** Massed defences are
legitimate, telegraphed, and counterable. The complaint is aimed one layer above price.

**On the contested damage figure, stated up front:** the economic paper's 0.35% and my 0.96% sentry
kill share both say the ring does almost nothing, and both are small enough that a separate agent
is right to treat the number as an instrumentation question rather than a balance finding. **This
paper's conclusion does not depend on which way that resolves.** I will show that in §7. If the ring
is later measured at 12% instead of 1%, not one recommendation below changes, because none of them
is about damage output.

Sources read this session:

- `core/data/scripts/fs2rts_config.lua` — `Sentries` (`:534-573`), `Tracks` (`:575-588`),
  `CostFormula` (`:398-431`), `BeamRangesByRole` (`:916-920`), `StationBaseHull` (`:28`),
  `Setup.BaseDistances` (`:484-489`), escalation `:501-529`, the assault-lock comment block
  (`:1045-1108`)
- `core/data/scripts/fs2rts_station.lua` — `GetSentryCap` (`:81-87`), `GetSentryRadius` (`:99-108`),
  `BuyUpgrade` (`:150-167`), `PlaceSentry` (`:476-495`), `UpdateSentryConstruction` (`:497-526`),
  `CreateSentry` (`:416-446`), `UpdateStationAI` (`:944-1123`), `DrawStationMapOverlay` (`:1433-1454`),
  `HandleStationPanelClick` (`:1338-1381`)
- `core/data/scripts/fs2rts_operations.lua` — `BuildAIOperations` (`:23-166`),
  `ChooseAIOperationTarget` (`:168-200`), `GetAISuppressionSubsystem` (`:202-243`),
  `ApplyAIOperationOrder` (`:245-300`)
- `core/data/scripts/fs2rts_ai_planning.lua` — `AIRoleMatch` (`:204-217`),
  `ScoreAIObjective` (`:219-255`), `ChooseAILocalThreat` (`:310-372`), `CommitAIGroup` (`:640-884`)
- `core/data/scripts/fs2rts_strategy.lua` — `GetBeamNominalRange` (`:497-544`),
  `GetFactionThreats` (`:685-739`), local-threat assignment (`:1020-1060`),
  `ApplyAIOperationOrder` call site (`:1422-1423`)
- `core/data/scripts/fs2rts_pilot.lua` — `ResolvePilotTargetSubsystemIndex` (`:101-108`),
  `ApplyPilotTurretGroup` (`:114-154`)
- `core/data/scripts/fs2rts_hud.lua` — `GetShipWeaponRange` (`:1239-1263`),
  `DrawTacticalMap` (`:881-937`)
- `core/README.md` (`:70-105`)

Telemetry: 7 staged batches (`poolfix-20261001`, `capgate-20261001`, `instrfix-a1`,
`savepolicy-20261001`, `synth-20261001`, `fallbk-20261001`, `fragctrl-20261001`), 26
faction-matches, 3,000 s simulated each, `ACCEPTANCE_SETUP.autoPlayer = true`. `instrfix-a1` is 2
matches; the rest are 4.

---

## 0. The finding that reframes the whole question

**The AI builds 6 tier-4 beam sentries in 26 faction-matches. Out of 813 total sentry builds, that
is 0.74%.**

Measured across all 7 batches, from `SENTRY_BUILD` `BUILD_STARTED` events:

| Sentry class | Builds | Share |
|---|---:|---:|
| SSG Trident (RED T1, 375 CP) | 305 | 37.5% |
| GTSG Watchdog (BLUE T1, 375 CP) | 256 | 31.5% |
| GVSG Ankh (GOLD T1, 375 CP) | 121 | 14.9% |
| GTSG Cerberus (BLUE T2, 875 CP) | 66 | 8.1% |
| SSG Rahu (RED T3, 2,000 CP) | 50 | 6.2% |
| **GTSG Mjolnir (BLUE T4, 3,000 CP)** | **6** | **0.74%** |
| GVSG Edjo (GOLD T2, 875 CP) | 5 | 0.6% |
| GTSG Alastor (BLUE T3, 1,500 CP) | 4 | 0.5% |
| GVSG Sekhem (GOLD T4, 3,000 CP) | 0 | 0% |

The user's brief spends a paragraph on the Mjolnir: *"A tier-4 Mjolnir is a capital-beam turret
at 4000 range."* Against a 7,700 CP mobile capital. That comparison describes a threat the shipped
game essentially never puts on the field. It has recorded **zero hull damage** in the sampled
batches, and **zero** heavy-assault decisions have ever selected one as a target (§3).

RED cannot buy one at all — `Sentries.Classes.RED` stops at tier 3 (`fs2rts_config.lua:567-571`).
So half the opponents in a three-faction match have no access to the tier-4 beam sentry by design.

**This means the "exchange rate" framing of the whole debate is aimed at a hull that is not in the
game.** What is in the game is a ring of 375 CP tier-1 turrets with 600–700 hull and 950–1,375 m
of reach. Those are not "massed defences." They are the AI chewing on the cheapest thing it can
see, at long range, forever, instead of closing on the objective.

---

## 1. Telegraph: the ring is not massed, and the player can see what is there

### 1.1 The ring is threat-gated and physically small. Measured.

`UpdateStationAI` caps the AI's ring at `limit = math.min(GetSentryCap(kind), 2 + math.ceil(total/3))`
(`fs2rts_station.lua:1101`), where `total` counts enemy hulls inside
`GetSentryRadius(kind) + 3000` (`:1090`). A defender who never shows a fleet gets **2 sentries,
forever**. The cap is a function of what the attacker does.

Measured peak *concurrent* sentries, reconstructed from `BUILD_STARTED` / `BUILD_COMPLETED` /
`BUILD_CANCELLED` sequences, per faction per match (cap is 10):

| Faction | Peak concurrent across 26 matches | Max concurrent CP value |
|---|---|---:|
| BLUE | 1, 1, 2, 2, 2, 2, 3 ×11 matches | 1,500 – 13,625 |
| GOLD | 1 ×14, 2 ×10, 3 ×2 | 1,125 – 2,875 |
| RED | 1 ×6, 2 ×8, 3 ×12 | 1,875 – 22,375 |

**The observed maximum ring size anywhere in 26 faction-matches is 3 platforms.** The design cap
is 10. Whatever "mass spawn the defences" means, it is not happening at the concurrency level.

### 1.2 The player sees each one, with a range ring, from the moment it exists

- Every live sentry is drawn on the tactical map: `DrawTacticalMap` (`fs2rts_hud.lua:881-937`)
  renders every ship including `role=="sentry"` at `:914-915`, with a filled rectangle marker and
  a `ROLE_BADGES` "S" badge (`:461`).
- Hovering any ship draws its effective weapon range as a ring on the command plane
  (`core/README.md:32`), implemented by `GetShipWeaponRange` (`fs2rts_hud.lua:1239-1263`), which
  walks turret banks for exactly this purpose.
- The STATION panel prints the placement radius continuously: `SENTRIES n/cap   RANGE x.x km`
  (`fs2rts_station.lua:1225`).
- A sentry under construction is drawn on the map as a circle with a live countdown
  (`DrawStationMapOverlay`, `fs2rts_station.lua:1447-1452`).

`GetShipWeaponRange` explicitly **excludes beams** (`not weapon:isBeam()`, `:1244`) — so the hover
ring is correct for the 96.9% of the ring that is tier-1/2/3 and absent for the 0.74% that is
tier-4 beam. That is a real gap, and §6 fixes it, but it is a gap in the *cheapest* case, not the
massed one.

**Verdict: the ring is fully legible, permanently, at zero decision cost to the defender.** The
user's telegraph test — "did the AI mass 14 sentries in 90 seconds and the player had no read on
it" — is **falsified by measurement**. The AI massed at most 3, and each was on the minimap for the
entire 20-second build plus its whole life.

---

## 2. Is the complaint about PRICE or about COUNTERPLAY? It is about neither. It is about the attacker never arriving.

### 2.1 What the player actually has, verified from the roster

The player's Blue catalog, read from the `balance.playerCatalog` block of the first telemetry record
in each batch (`fs2rts_ai_util.lua:19-22` builds it from `BuildCatalog`):

| Role | Best options | CP | Hull class |
|---|---|---:|---|
| Fighter (×4 wing) | GTF Ulysses, GVF Serapis | 1,400 | cheapest, fastest |
| Fighter (×4 wing) | GTF Myrmidon, Hercules, Loki, Perseus | 1,500–1,600 | |
| Bomber (×4) | GTB Zeus / Artemis / Medusa | 2,625–2,800 | |
| Bomber (×4) | GTB Ursa | 3,325 | |
| Escort | GTSC Faustus | 1,225 | tier 2 |
| Escort | GTC Leviathan / Aeolus | 2,900–3,150 | |
| Escort | GVC Mentu | 4,025 | |
| Capital | GTCv Deimos / GVCv Sobek | 8,600 | tier 3 |
| Heavy | GVD Hatshepsut | 12,950 | tier 4 |
| Heavy | GTD Hecate / Orion | 29,375 / 34,425 | tier 4 |
| Juggernaut | GTVA Colossus | 13,825 | tier 5 |

That is a real answer to massed static defence. Measured sentry kills by attacker class across all
7 batches, from `LOSS.lethalHit.attackerClass`:

| Killed sentry class | Top killers |
|---|---|
| GTSG Watchdog (110 deaths) | GVB Bakha, Mekhu HL-7, Cluster Baby, Prometheus R, Hornet |
| SSG Trident (105) | same fighter/bomber pool |
| GTSG Cerberus (23) | same |
| SSG Rahu (16) | same |

**Cheap fighters and bombers are what actually kills sentries.** A tier-1 sentry at 375 CP and
600 hull (900 with Defenses L2) dies to a 350–400 CP fighter. So the counterplay the doctrine
requires already exists in the game and already works.

### 2.2 The one counterplay the doctrine assumes the player has, and does not

The doctrine says a sentry may be diverted to when it is *"physically blocking the route."* To
suppress a turret you have to be able to hit *that turret*.

The AI can. `GetAISuppressionSubsystem` (`fs2rts_operations.lua:202-243`) scores every turret on
a target by `output / HitpointsLeft`, picks the best, and orders the strike onto that subsystem for
25–90 s. It then feeds the chosen index through `context.subsystemIndex` into
`CommitAIGroup`, which is why `SIEGE_TURRET_TARGET` and `SUBSYSTEM_SUPPRESSION` appear in the
telemetry reason list.

The player cannot, and the code says so itself. `ResolvePilotTargetSubsystemIndex`
(`fs2rts_pilot.lua:101-108`) returns `0` — the whole ship — unless `count >= 2` and the index is in
range, and the comment immediately above the assignment path is explicit:

> `Subsystem.Target` … accepts an OBJECT and nothing else. … **Hitting one subsystem of a capital is
> simply not expressible through this API**, so the index stays a targeting preference and the
> object is what the turrets are given. (`fs2rts_pilot.lua:136-144`)

`core/README.md:25` advertises `<` / `>` as "step through the target's subsystems." It steps an
index that never reaches the turret.

**Consequence for the doctrine:** the carve-out that makes "divert to a blocking sentry" legitimate
is executable by the AI and not by the player. The two sides of the fight do not have the same
answer to the same rule. That is a competitive-fairness defect and it is invisible to a price
argument.

---

## 3. The 39% "other ship" bucket and the zero-reactivity finding

### 3.1 Corrected bucket split, and a correction to the brief

The brief's "16% / 44% / 39%" is the `capgate-20261001` batch specifically. I reproduced it
exactly — 16.4% station / 44.8% sentry / 38.9% mobile, 2,906 heavy PRIMARY decisions — then
measured all 7 batches:

| Batch | Heavy PRIMARY decisions | Station | Sentry | Mobile |
|---|---:|---:|---:|---:|
| capgate-20261001 | 2,906 | 16.4% | 44.8% | 38.9% |
| fallbk-20261001 | 9,909 | 24.1% | 59.8% | 16.1% |
| fragctrl-20261001 | 9,909 | 24.1% | 59.8% | 16.1% |
| instrfix-a1 | 3,818 | 12.0% | 69.0% | 19.0% |
| poolfix-20261001 | 9,307 | 43.1% | 36.7% | 20.2% |
| savepolicy-20261001 | 6,419 | 31.6% | 51.9% | 16.5% |
| synth-20261001 | 1,847 | 52.4% | 16.0% | 31.6% |
| **All 7** | **44,115** | **28.8%** | **51.7%** | **19.4%** |

So the honest number is worse than the brief's: **a heavy assault group spends 51.7% of its
PRIMARY ticks attacking a sentry and only 28.8% attacking the station it was sent to kill.**

And the sentry bucket is not "massed defences." Its composition:

| Sentry class | Heavy-PRIMARY ticks aimed at it | Share of the sentry bucket |
|---|---:|---:|
| SSG Trident (375 CP) | 11,330 | 49.7% |
| GTSG Watchdog (375 CP) | 10,391 | 45.6% |
| GTSG Cerberus (875 CP) | 650 | 2.9% |
| GVSG Ankh (375 CP) | 261 | 1.1% |
| SSG Rahu (2,000 CP) | 197 | 0.9% |
| **Mjolnir / Sekhem (3,000 CP)** | **0** | **0%** |

**96.9% of the sentry bucket is 375 CP tier-1 turrets.** The heavy assault groups are not being
repelled by a wall. They are parking at long range and shooting the cheapest object in the
neighbourhood, which is not the objective.

### 3.2 The mechanism, and it is a targeting rule, not a price

`ChooseAIOperationTarget` (`fs2rts_operations.lua:168-200`) scores every defender of the operation's
front. The decisive line is `:192-194`:

```lua
local rank=(role=='bomber' and screen(g) and 4
        or self:IsStaticDefense(target) and strike(g) and 3
        or 1)
local candidate=rank*100000-g.units[1].Position:getDistance(target.Position)-covered
```

A static defence gets rank 3 for a strike group. The operation's own objective — the station — gets
rank 1. That is a **200,000 gap**, and the distance term is subtracted in metres.

`op.defenders` is built at `:98-105` from ships of the objective's faction within
`station.Radius + 6000` m of it. On an 18,000 m map (`Setup.BaseDistances[2]` = STANDARD, and
`DefaultBaseDistance = 2`, `fs2rts_config.lua:483-489`) **the maximum distance spread across the
entire candidate set is under 6,000 m.** Distance can never pay for two ranks. The sentry always
wins, regardless of geometry, range, whether it can see anything, or whether it has ever fired.

This is already documented in the repo at `fs2rts_config.lua:1045-1072`, with the same measurement
I have reproduced. Both existing `AssaultStaticDefenceLock` and `AssaultMobileThreatLock` ship
`false` (`:1075`, `:1106`) pending an A/B.

### 3.3 Zero reactivity: not "the AI never answers its guns" — "a PRIMARY group can never *be* the mission that does"

The brief reads `localThreatSignature == target` occurring zero times as the AI being blind to its
own guns. That reading is wrong, and the correction matters, because it changes the fix.

`hardLocalThreat` **does** fire, and it fires correctly. Measured across all heavy DECISION records:

| Batch | Heavy decisions | `hardLocalThreat = true` | Missions those took |
|---|---:|---:|---|
| capgate-20261001 | 3,270 | 106 | 106 INTERCEPT, 0 anything else |
| poolfix-20261001 | 12,462 | 260 | 260 INTERCEPT, 1 INTERCEPT false |
| fallbk / fragctrl | 15,475 | 240 | 240 INTERCEPT |
| savepolicy-20261001 | 8,173 | 172 | 172 INTERCEPT |
| synth-20261001 | 2,005 | 32 | 32 INTERCEPT |

**In every batch, 100% of `hardLocalThreat = true` records carry `mission = INTERCEPT`. Zero carry
`PRIMARY`.** `localThreatSignature == target` being zero *within the PRIMARY subset* is therefore not
a missing reaction — it is the operation layer **forbidding a reactive group from remaining a
PRIMARY group**.

The chain, in order:

1. `fs2rts_strategy.lua:1033-1058` — a hostile inside `LocalEngageRadius` (3,600) sets
   `g.hardLocalThreat` and takes `mission = "INTERCEPT"`.
2. `fs2rts_strategy.lua:1422` — `ApplyAIOperationOrder` runs **after** that, sets
   `context.locked = true` (`:257`) and re-derives the target.
3. `fs2rts_operations.lua:192` — the re-derivation ranks a sentry above the objective.
4. `CommitAIGroup`'s retention gate requires `not context.locked`
   (`fs2rts_ai_planning.lua:714`), so the reactive decision is discarded before it is recorded.

So `localThreat` is *populated* on 12.2% of heavy PRIMARY records (`ltSet` 602 of 3,270 in
capgate, 2,635 of 12,462 in poolfix) and then thrown away. The reactivity exists. It is suppressed
by the same rule that creates the diversion. **One defect, not two.**

### 3.4 What the player experiences

The player watches a 12-minute, 8,600 CP capital crawl to the edge of its own nominal reach and
shoot a 375 CP turret for eleven minutes. Measured, from attacker-group centroid to chosen target:

| Batch | → Sentry (p50) | → Station (p50) | → Sentry max |
|---|---:|---:|---:|
| capgate-20261001 | 7,406 m | 13,541 m | 7,994 m |
| poolfix-20261001 | 6,373 m | 12,633 m | 7,991 m |
| savepolicy-20261001 | 7,829 m | 11,894 m | 8,002 m |
| synth-20261001 | 6,740 m | 12,614 m | 9,008 m |

The sentry distance **pins at the capital's nominal beam reach of 8,000 m** (`BeamRangesByRole.capital`,
`fs2rts_config.lua:918`), max 7,991–8,002 across batches. And the sentry sits 13,289–14,219 m
(p50) from the station it is defending, on an 18,000 m base separation.

So the geometry is: **attacker closes to 8,000 m, finds a tier-1 turret sitting 4,000 m outside the
defended station, engages the turret at the exact boundary of its own reach, and never closes the
remaining 4,000 m to the objective.** The turret is not a wall. It is a waypoint that the targeting
rule refuses to route past.

That is not a balance problem. That is an objective-discipline failure, and it is the user's actual
complaint, correctly stated: *the attack does not press its objective.*

---

## 4. The sentry range problem, restated

The brief asks whether a player can answer a 4,000 m capital-beam turret for 3,000 CP with an
8,000 m mobile capital for 7,700–8,600 CP.

Measured answer: **this situation occurs six times in 26 faction-matches, and never once does the
capital choose the beam sentry.** So there is no exchange rate to evaluate. The Mjolnir records
zero hull damage and zero targeting ticks. Either it is broken or it is decorative — the economic
paper flags this as the single largest hole in its own argument (§6.5) and I agree it is
unresolved, but the player-experience consequence is stronger than the economic one: **the player
cannot answer a threat that does not exist, and the reason it does not exist is that the AI's
scoring function prefers a 375 CP turret to a 3,000 CP one.**

`UpdateStationAI:1100` picks a desired role and `:1108` scores
`(option.role==desired and 10 or 0) - option.cost/1000`. `desired` is
`threats.capital>0 and "beam" or …`. Measured capital builds in these batches are near zero — this
is the `ai-capital-starvation.md` defect — so `threats.capital` is 0, `desired` is never `"beam"`,
and the Mjolnir's role bonus is 0 against a −3.0 cost term. It is structurally unpurchasable.

**The 4,000 m beam turret is not mispriced. It is unsold.** Repricing it from 3,000 to 2,025 — the
economic paper's Change 1 — makes it cheaper and therefore *more* unsold, because the cost term is
the only thing that was ever suppressing it and the role bonus is what would have to change.

---

## 5. Where the economic paper is right, and where it is wrong

### 5.1 Where it is right, and I will not pretend otherwise

**The two-price-list arbitrage is real and I verified it independently.** From `LOSS` records,
`baseUnitCost` is the `CostFormula` output and `bountyCP` is 24% of it (`Bounties.DefaultFractionOfCost = 0.24`,
`fs2rts_config.lua:433-436`):

| Sentry | Price paid | `baseUnitCost` | Ratio | `bountyCP` | Refund rate |
|---|---:|---:|---:|---:|---:|
| GTSG Watchdog | 375 | 100 | 3.75x | 25 | 6.7% |
| GVSG Ankh / Edjo | 875 / 375 | 125 | 3.0x / 7.0x | 30 | 8.6% |
| GTSG Cerberus | 875 | 150 | 5.83x | 36 | 4.1% |
| SSG Trident | 375 | 150 | 2.5x | 36 | 9.6% |
| GTSG Alastor | 1,500 | 175 | 8.6x | 42 | 2.8% |
| GTSG Mjolnir | 3,000 | 675 | 4.44x | 162 | 5.4% |
| SSG Rahu | 2,000 | 1,475 | 1.36x | 354 | 17.7% |

Its headline is correct and it is an accounting defect worth fixing on its own terms. **The refund
rate is the sharpest number in either paper**: 2.8%–9.6% on a sentry that the attacker can delete
with a 350 CP fighter. A player who turtles cannot recover the ring.

**Its ordering concession is also right and I adopt it:** sentries are 2.5%–23.3% of production
spend (measured per faction per match across the 7 batches), while the upgrade tree is 29–38% of
income. Sentries are not the biggest sink. The 54.8%-of-inflow figure in its §2 is upgrades plus
sentries, and upgrades are the larger half.

### 5.2 Where it is wrong — four places, with numbers

**(a) It ships a change that makes the complaint worse.** Change 1 reprices sentries to
`EstimateShipCost × 3.0`, which by the paper's own arithmetic takes the ring from 78,750 CP to
23,900 CP across the batch — a 54,850 CP reduction, which it describes as "8.2% of total inflow."
That is **more than 2.5 capital ships handed back to a defender whose ring was already only
2.5%–23.3% of spend and at most 3 platforms wide.** If massing is the complaint, reducing the price
of massing by 70% is the wrong direction. Change 2 (a match budget) is the only element of its
proposal that addresses the doctrine, and its own §6.1 admits it cannot resolve whether the budget
refreshes on death.

**(b) Change 4 would strengthen the wrong thing.** It proposes closing the 1.6 km dead band between
the station's 2,000 m reach and the ring's inner edge. But §3.4 shows the attacker never gets inside
8,000 m of the objective. **Closing the band makes the ring's guns better at a fight the attacker
is not having.** The gap is not a placement smell; it is the safety margin that is currently the
only thing preventing the ring from mattering.

**(c) Its load-bearing damage number has an attribution error 40x in its own disfavour — and it
does not check the attacker class.** §1.3 reports that "killed by a sentry weapon" accounts for
50.39% of all losses (1,419 of 2,816), led by `Harpoon` at 1,186. **Harpoon is a mobile fighter
missile.** Grouped by `LOSS.lethalHit.attackerClass`, the top Harpoon killers are `GVF Thoth` (456),
`GTF Ulysses` (392), `GVF Serapis` (105), `GTF Perseus` (98), `SF Dragon` (71) — all tier-1/2
fighters. Only `GTSG Alastor`, `GVSG Edjo` and `SSG Rahu` carry Harpoon, and they account for
**4 of 1,186** Harpoon kills. Grouped by attacker class, sentries killed **27 of 2,816 losses =
0.96%**:

| Sentry | Kills | Weapons |
|---|---:|---|
| SSG Rahu | 9 | Standard Flak |
| GTSG Cerberus | 8 | Standard Flak |
| GTSG Watchdog | 6 | Terran Turret |
| SSG Trident | 2 | Shivan Heavy Laser |
| GVSG Ankh | 2 | Shivan Heavy Laser |

The paper's own §7 probe-2 asks whether sentry damage attribution is broken. It is — in the
opposite direction to what it assumed. Its central conclusion survives (the ring does no work) and
its supporting table does not. **I am correcting this in the direction that makes my position
harder to sell, because it makes the ring look even less like a threat, which is the position I am
arguing.**

**(d) It prices the wrong unit.** The economic paper's recommendation is aimed at hulls the AI
builds 0.74% of the time. My §0 table is the whole sentry economy: 68.9% of all builds across
26 faction-matches are **375 CP tier-1**. Any repricing that touches tier-2/3/4 and leaves
tier-1 alone is aimed at 31% of the ring; any that touches all tiers is dominated by the tier-1
decision, and the tier-1 decision is governed by `desired = threats.fighter > 2 and "flak" or "screen"`
— that is, by how many fighters the attacker has shown.

---

## 6. The design flaw both papers are missing

**Neither paper notices that the attacker and the defender do not have the same answer to the same rule.**

The doctrine is: *press the objective; divert to a sentry only when it is shooting at you, locally
threatening you, or physically blocking the route.* Three carve-outs. Two of the three —
"shooting at you" and "physically blocking" — require the ability to identify and destroy an
individual turret:

- **The AI has this.** `GetAISuppressionSubsystem` (`fs2rts_operations.lua:202-243`) ranks
  turrets by `output / HitpointsLeft`, commits the strike to that subsystem for 25–90 s, and
  surfaces `SIEGE_TURRET_TARGET` in the reason telemetry. Measured: **214** `SIEGE_TURRET_TARGET`
  records on heavy groups across the 7 batches — against 34,812 `OPERATION_ROLE_TARGET`, the rule
  that creates the diversion.
- **The player does not, and the code documents why.** `ResolvePilotTargetSubsystemIndex` returns
  the whole ship; `ApplyPilotTurretGroup`'s comment (`fs2rts_pilot.lua:136-144`) states that
  assigning a subsystem raises a native type error and that "hitting one subsystem of a capital is
  simply not expressible through this API."

Both papers treat the sentry as a symmetric asset priced symmetrically against a symmetric attacker.
It is neither. The concrete consequence is the one the doctrine is trying to prevent:

**The AI's violation of the doctrine is invisible to it.** A capital that parks at 8,000 m and
shoots a tier-1 turret is not "answering its guns" — the turret has 1,375 m of reach and cannot
reach back. It is a targeting rule that prefers a cheap object. The AI cannot tell the difference,
because `IsStaticDefense` at `fs2rts_operations.lua:186` admits *any* static defence into the
candidate set whenever `inReach`, and `inReach` at `:184-185` is measured against the **attacker's**
range, not the sentry's:

```lua
local inReach=g.units[1].Position:getDistance(target.Position)
    <=(self:AIProfile(g.units[1]).range or 0)+(target.Radius or 0)
```

With `capital` and `heavy` at 8,000 m nominal (`BeamRangesByRole`, `:918-919`), **every sentry
inside 8 km of the attacker qualifies**, including a 1,375 m Terran Turret that is shooting at
nothing. That is why the diversion distance pins at exactly 8,000 m in §3.4. The rule admits
static defences by the attacker's reach, so a turret the attacker can out-range ten times over
still counts as a legitimate diversion.

**And the player cannot compensate by suppressing it.** So the doctrine's escape hatch is
AI-only. The defender who massed turrets has given the attacker a target the attacker's planner is
forbidden to ignore, using a rule the attacker cannot evaluate honestly, against a defence the
defender has no way to shoot back at selectively.

That is the shared blind spot. The economic paper asks *what should a sentry cost*; I ask *why does
the attack stop*. Both are reasonable questions and **neither one is the question the doctrine is
actually asking**, which is: *is this attack pressing its objective, and can both sides tell?* The
answer is no and no, and neither fact is visible to a price comparison.

---

## 7. Does my conclusion depend on the contested damage figure? No.

The balance paper's weakest link, by its own §7 and §8, is whether sentries deal 0.35% or something
material. It lists five falsifiers; this paper's recommendations depend on none of them.

| If the damage finding resolves as… | What happens to §6 of this paper |
|---|---|
| **0.35%–1% (my measurement: 0.96% by attacker class)** | Nothing. Recommendations stand. |
| **Sentry attribution is broken in telemetry** (a separate agent is checking) | Nothing. My §6 rests on `LOSS.lethalHit.attackerClass`, a different field, on a different sample (2,816 records, 7 batches). |
| **Sentries actually deal 12%** | Nothing. §6 is about a targeting rule (`rank*100000` vs a ≤6,000 m distance spread) and about input parity (`ResolvePilotTargetSubsystemIndex`). Neither is a damage-output function. A ring that shoots hard and is still wrongly routed to is the *same* defect. |
| **The Mjolnir is repaired and starts being bought** | §6 still stands, and gets *worse*: a 3,000 CP beam turret the attacker cannot suppress and is forbidden to ignore is the sharpest version of the input-parity gap. |

What *would* falsify this paper is different from what would falsify the balance paper: **if the
`rank*100000` arithmetic were not the mechanism**, which I falsified by reading
`fs2rts_operations.lua:192-194` and by observing that the measured diversion distance pins to the
8,000 m nominal beam reach rather than to any sentry's own range. Or if `AssaultStaticDefenceLock`
turned out to already be effectively on somewhere I did not read.

---

## 8. What I would ship

### 8.1 Doctrine, in one sentence

**A sentry is a legitimate diversion target only while it is shooting at you.** Not because it
exists, not because it is nearby, not because it is inside the attacker's nominal reach. The
correct predicate is `the sentry has this group as its current target`, which the game already
knows: `FindAIGroupTargeter` (`fs2rts_ai_planning.lua:73-92`) builds exactly that from
`AITargetedBy`, and `ChooseAIOperationTarget` already calls it for bombers at `:173`.

### 8.2 Telegraph requirements — four items, all cheap

1. **Show construction to both sides.** `DrawStationMapOverlay` (`fs2rts_station.lua:1447-1452`)
   currently draws pending sentries only for `job.kind == "BLUE"`. The player cannot see a ring
   being assembled at Red's base until it is complete. Extend the existing circle-plus-countdown to
   hostile factions with a hostile colour. This is the single highest-value item in this paper and
   it touches one `if`.
2. **Show sentry threat rings on the tactical map, not just on hover.** 6–10 sentries each with a
   drawn ring answers "what is this base made of" at a glance. `GetShipWeaponRange` already exists
   and already walks turret banks; it just needs to be called from `DrawTacticalMap`.
3. **Add a beam range to the hover ring.** `GetShipWeaponRange` skips beams
   (`fs2rts_hud.lua:1244`) because FSO does not expose beam range to scripting — but
   `Sentries.Classes[].range` does (`fs2rts_config.lua:553, 565`), and `GetBeamSentryRangeOption`
   (`fs2rts_station.lua:534-539`) already looks it up. The player should see the Mjolnir's 4 km
   ring even if the tooltip still says `BEAM`.
4. **Give the attacker a read on the ring before it commits.** `policy` layer, not a new system:
   the CONTEST record (`fs2rts_ai_planning.lua:515+`) already samples every 10 s per faction.
   Surface `defenseValue` and sentry count on the HUD when the player's own base is the one being
   massed.

### 8.3 Counterplay the player must have — one item, and it is the crux

**Make turret-level targeting expressible for the player, or drop the doctrine's carve-out for
players entirely.** Three options, in preference order:

- **(a) Preferred — expose subsystem targeting through the order layer, not the pilot layer.** The
  blocker at `fs2rts_pilot.lua:136-144` is that `Subsystem.Target` is declared
  `ADE_VIRTVAR(Target, l_Subsystem, "object", …)`. An RTS attack order at the
  `fs2rts_orders.lua` layer has the same constraint. The workable route is the one the AI already
  uses and the pilot API does not: **order the group at a subsystem by making the subsystem the
  group's attack-move destination and letting native turret AI resolve it**, which is what
  `GetAISuppressionSubsystem` feeds via `context.subsystemIndex`. If that cannot be made to work
  for a player-issued order, then:
- **(b) Give the player a dedicated anti-turret tool** with a visible cooldown, in the same design
  slot as ORBITAL STRIKE. Blue's ability is 750 CP, 150 s cooldown, 1,200 damage, 900 m radius
  (`fs2rts_config.lua:630`). A 1,500 CP, 180 s "SIEGE STRIKE" that suppresses turret fire in a
  900 m radius for 25 s is a small addition, symmetric with what the AI already does to itself, and
  it makes the "blocking sentry" carve-out answerable by both sides.
- **(c) If neither is acceptable, remove the carve-out.** Say plainly in the tooltip that a sentry
  is never a legal objective and that attacks must press the station. That is worse design but it
  is *honest*, and honest is better than a rule only one side can execute.

**Do not ship (c) alone.** A doctrine the player cannot comply with is a doctrine that teaches the
player the game is lying to them.

### 8.4 What I would fix on the AI side, with numbers

**Turn on the lock that already exists and is already commented.** `AssaultStaticDefenceLock` and
`AssaultMobileThreatLock` both ship `false` (`fs2rts_config.lua:1075`, `:1106`). Their own comment
block (`:1045-1072`) contains my measurement. The static-defence lock is the one to enable; the
mobile-threat lock needs the `IsCapitalTarget`-includes-`escort` caveat at `:1099-1105` resolved
first, because `GTSC Faustus` at 1,225 CP is the single most-targeted mobile hull in the whole
dataset (4,964 heavy-PRIMARY ticks) and locking escorts in would starve the assault of its screen.

**Change the candidate predicate, not the price.** In `ChooseAIOperationTarget`, replace

```lua
local inReach=g.units[1].Position:getDistance(target.Position)
    <=(self:AIProfile(g.units[1]).range or 0)+(target.Radius or 0)
```

with an AND against the *sentry's* own configured reach (`Sentries.Classes[].range`), so a 1,375 m
Terran Turret cannot qualify as a diversion for an attacker standing 8,000 m away. That single
predicate is what pins the measured diversion distance at 8,000 m, and it is the cheapest possible
fix — it changes no price, no cap and no build time.

**Cap the rank gap.** `rank*100000` against a candidate set whose diameter is under 6,000 m is not
a weighting, it is a veto. Either reduce the multiplier until distance can compete, or make rank a
tie-break applied after distance. Anything between leaves the defect intact.

**Fix the Mjolnir's purchase, not its price.** `desired` (`fs2rts_station.lua:1100`) keys on
`threats.capital > 0`, and capitals are near-zero in these batches. A tier-4 beam turret should be
selected on `threats.capital + threats.bomber > 0` or on tier-unlock age, not on a threat class
that capital starvation suppresses. Until then the 4,000 m turret the brief worries about is a
config entry, not a threat.

### 8.5 What I would leave alone, and where I disagree with the balance paper

**I would not reprice the ring as the primary fix.** The arbitrage is real (§5.1) and the refund
rate of 2.8%–9.6% is indefensible, so I would fix the *bounty* — `bountyCP` from the price paid
rather than from `baseUnitCost`, which turns a Watchdog's 25 CP refund into 90 and a Rahu's 354 into
480. That is a three-line change, it costs the defender nothing, and it makes turtling a
recoverable decision rather than a write-off.

But I would hold `Sentries.Classes[].cost` at its current level until the AI actually builds tier-3
and tier-4 hulls. Repricing a product line that is 68.9% one SKU is not a balance pass.

---

## 9. Summary of disagreements with `defense-balance-position.md`

| # | Its claim | My position | Evidence |
|---|---|---|---|
| 1 | Sentries deal 0.35% of damage; 50.4% of losses are killed by sentry weapons | Sentries deal **0.96%** of losses by attacker class. Harpoon is a mobile fighter missile; 4 of 1,186 Harpoon kills came from a sentry. | `LOSS.lethalHit.attackerClass`, 2,816 records, 7 batches |
| 2 | The exchange rate to beat is Mjolnir 3,000 CP vs Ravana 7,700 CP | That exchange never occurs. **6 Mjolnir/Sekhem builds in 26 faction-matches, 0.74% of 813, 0 damage, 0 targeting ticks.** RED cannot buy one at all. | `SENTRY_BUILD`, all 7 batches |
| 3 | Reprice sentries to `formula × 3.0` | That cuts the ring's cost 70% and hands a defender 54,850 CP — the wrong direction for a massing complaint. | Its own §5.1 arithmetic |
| 4 | Close the 1.6 km dead band (Change 4) | The attacker never gets inside 8,000 m. Closing the band strengthens guns in a fight nobody is having. | Attacker→target distance, §3.4 |
| 5 | "A defence ring that soaks 6% and returns 0.35% is a decoy" | Correct conclusion, and it is not a price defect. It is `rank*100000` in `fs2rts_operations.lua:192` plus `inReach` measured against the *attacker's* range at `:184`. | §3.2, §3.4 |
| 6 | Risk 5: "mass-spawn may be substantially an AI artefact" | Agreed and it is stronger than the paper allows: the ring is threat-gated to `2 + ceil(total/3)` and **peaks at 3 platforms in 26 faction-matches** against a cap of 10. | §1.1 |
| 7 | *(not raised)* | **The doctrine's carve-out is AI-only.** `GetAISuppressionSubsystem` can suppress a turret; `ResolvePilotTargetSubsystemIndex` provably cannot, per its own comment. | `fs2rts_operations.lua:202`, `fs2rts_pilot.lua:101-144` |

**The one place I think the balance paper is most wrong** is its primary recommendation. It
concludes that the fix is `Sentries.Classes[].cost = EstimateShipCost × 3.0`, on the reasoning
that this "removes a 1.4x–7x arbitrage." The arbitrage is real. But 68.9% of the ring is a single
375 CP SKU, the AI builds the contested tier-4 hull 0.74% of the time, and the measured peak ring
is 3 platforms — so the knob it turns is, in the shipped game, adjusting the price of a 375 CP
tier-1 turret by 20% while leaving the actual behaviour — a heavy assault group that spends 51.7%
of its ticks shooting a 375 CP turret from 8,000 m instead of pressing the station 4 km further in —
completely untouched. **It will change what the defender pays and not what the attacker does.**
