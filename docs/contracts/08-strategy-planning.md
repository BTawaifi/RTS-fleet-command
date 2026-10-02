# 08 — AI strategy, planning and telemetry semantics

**Subsystems:** `core/data/scripts/fs2rts_strategy.lua` (1493 lines),
`fs2rts_ai_planning.lua` (1076 lines), `fs2rts_ai_util.lua` (19 helpers),
`fs2rts_ai_telemetry.lua`
**Prefix:** `AI-`

This document covers the strategic layer **and** the semantics of the telemetry
records, because several defects in this project were not bugs in the AI — they were
bugs in the *measurement* of the AI, which is why every metric-based tool reported a
mixed result while the behaviour was wrong.

## PROMISES

**AI-1.** The planner runs on its own cadence, not per frame.
`UpdateAIStrategicObjectives` (`fs2rts_strategy.lua:1454`) returns until
`StrategicOrderInterval` has elapsed (`:1459`), default 2 s
(`fs2rts_config.lua:773`).

**AI-2.** The three faction plans are spread over adjacent frames. `queue` is built
once (`:1467`) and drained incrementally, with the threat snapshot and execution
observation collected once and shared (`:1463-1465`).

**AI-3.** A shared threat snapshot has exactly one owner. `UpdateFactionStrategicPlan`
takes `ownsSnapshot = (self.StrategicThreatSnapshot==nil)` (`:655`) and builds it if so
(`:656`); `UpdateFleetServices` does the same (`fs2rts_service.lua:415-416`) and drops
the *whole* AI context it built (`:600-604`), not just the snapshot.

**AI-4.** Serviced ships are excluded from group building and counted separately.
`UpdateFactionStrategicPlan` tallies `servicingCount` and `playerControlledCount`
apart from group membership (`fs2rts_strategy.lua:670-671`, `:680-684`).

**AI-5.** The AI context index is read, not rebuilt, on hot paths.
`fs2rts_service.lua:537` reads `self.AIProfileIndex[id]` with the explicit rationale
at `:531-536`: `AIProfile` walks every bank of every turret of every subsystem, so
calling it per ship per service pass would rebuild the whole strategic picture once per
hull.

**AI-6.** A manual player order outranks the AI for that hull.
`AssignAIStrategicOrder` returns early for BLUE when `UserOrders[sig] ~= nil` or the
hull is possessed (`fs2rts_strategy.lua:1403`).

**AI-7.** A dead or no-longer-hostile target is never left as a goal.
`ValidateStrategicOrderTargets` (`fs2rts_strategy.lua:1409`) clears orders and drops
the state for a dying or realigned target (`:1444-1447`), emitting `TARGET_INVALID`
with a reason.

**AI-8.** A valid hostile retarget is left to the engine. Reassertion only happens on
`NATIVE_ORDER_PREEMPTED`, `NATIVE_TARGET_FRIENDLY`, or a `NATIVE_TARGET_LOST` with no
goal present and age ≥ `NativeTargetRepairInterval` (`:1430-1432`), rate-limited by
`lastRepair` (`:1432`).

**AI-9.** Telemetry cadence gates are separate from the planner cadence.
`CohesionSampleSeconds` = 2 s (`fs2rts_config.lua:697`) and
`ContestSampleSeconds` = 10 s (`:701`). Rationale at `:694-696`: sampling cohesion on
every planner tick roughly tripled a headless run's frame cost.

**AI-10.** Every build decision, order transition, service phase change, spawn, bounty
and refusal emits a record. The emitters are `EmitAIEvent` calls throughout; the
decision record is emitted unconditionally at `fs2rts_ai_production.lua:426`.

**AI-11.** Capital spawn placement is observable in telemetry.
`fs2rts_ai_production.lua:388-393` records each hull's coordinates in the `PRODUCTION`
event, because placement is the only proof that capitals land near their own station
(`:385-387`).

**AI-12.** `RecordAIEconomyFlow` is a single accounting sink. All four flow kinds
(`income`, `productionSpend`, `bounty`, `refund`) accumulate in one place, and the
rationale at `fs2rts_ai_telemetry.lua:350-353` states that a CP path which deducts
without routing through it will show up as a reconciliation gap in the tools — i.e. the
gap is the detector.

**AI-13.** `EXECUTION` records are transition-only. Emitted only when
`status` or `mode` changed from the previous sample
(`fs2rts_ai_planning.lua:870`).

## REFUSES

**AI-14.** `UpdateAIStrategicObjectives` refuses when the AI is disabled, setup is
active, or post-battle is active (`fs2rts_strategy.lua:1455`).

**AI-15.** `RecordAIHit` refuses non-ship breeds and disabled/setup/post-battle
sessions (`fs2rts_ai_planning.lua:880-881`) and builds the event only when a trace can
receive it (`:889`).

**AI-16.** `AssignAIStrategicOrder` refuses an invalid hull, a static defense
(`:1400`), a missing station or the station itself (`:1401`), and a BLUE hull with a
live player order (`:1403`).

**AI-17.** `RecordAITransition` (`fs2rts_ai_planning.lua:346`) records only actual
transitions, so `COUNTERS.switches` counts transitions and not samples.

## MUST NEVER

**AI-18.** **Never report a capability the telemetry cannot measure.** Every field a
tool reads must be resolvable from the record. Three fields shipped as permanently
unusable and are the reason this sentence exists — see V-1, V-2, V-4.

**AI-19.** **Never define the same concept twice.** A metric name, an idle definition,
or a field alias that two consumers read differently is a defect even when both
definitions are individually correct. See V-3, V-6.

**AI-20.** **Never build a discarded record.** High-volume telemetry is expensive.
`RecordAIHit` gates event construction on `IsAITraceActive()` (`fs2rts_ai_planning.lua:889`).

**AI-21.** **Never guard a telemetry emitter with an early return if its loop body also
maintains non-telemetry state.** This is the trap `AI-20`'s naive application walks
into. Per a peer agent's analysis of `SummarizeAI`: it also resets `AIEconomyFlow`
(`fs2rts_ai_planning.lua:1062`), `BaseDamageTelemetry.intervalByFaction` (`:1063`) and
`CombatDamageTelemetry.intervalByFaction` (`:1064`), so an early return would freeze
the interval accounting and every interval summary would go permanently empty. Likewise
`EmitContestRecord` keeps the per-group stall baseline and advances the cadence gate. Only
genuinely pure emitters (`EmitAICohesion`, `CommitAIGroup`) are safe to guard.

**AI-22.** **Never let an unserviced hull hold a pad forever.** See
[05-fleet-service.md](05-fleet-service.md) SV-22.

**AI-23.** **Never read ship-only properties on a native weapon or beam handle.**
`GetNativeObjectiveStatus` is documented as the place this matters
(`fs2rts_orders.lua:683-684` cites it as the model for `pcall`-guarded `getSignature`).

## INVARIANTS

**AI-I1 — Snapshot single ownership.**
*Algebraically:* for every `t`, exactly one of {`UpdateAIStrategicObjectives`,
`UpdateFactionStrategicPlan`, `UpdateFleetServices`} owns
`StrategicThreatSnapshot`, and the owner clears it on exit
(`fs2rts_strategy.lua`, `fs2rts_service.lua:601`). Hence no reader can consume a
grid built by a different, up-to-2-s-old pass — which is exactly what the `:595-599`
comment says the previous code did.

**AI-I2 — Group membership is a partition of the owned fleet.**
*Algebraically:*
`ownedCount == servicingCount + playerControlledCount + Σ_g |g.units|`
for each faction, from one `EachShip` with mutually exclusive branches
(`fs2rts_strategy.lua:679`, `:681`, `:683`, `:691`). This is the invariant that makes
"why did this side lose" answerable, because it accounts for every hull.

**AI-I3 — `replacementValueByClass` sums to `replacementValue`.**
`fs2rts_ai_planning.lua:959` increments `replacementValue`, `:964` increments the
per-class bucket by the same `replacement`, inside the same block. *Consequence, and a
trap:* this means `replacementValueByClass` is the **surviving** fleet value by class,
**not** losses. Using it as "value lost" silently duplicates the fleet-value metric.
Real loss value comes from `LOSS` event `replacementCost`.

**AI-I4 — `combatantValue == replacementValue` by construction.**
`fs2rts_ai_planning.lua:963`. Emitted as an *alias* rather than a rename, because
renaming would invalidate every previously captured batch (`:960-962`).

**AI-I5 — Damage dealt is measured, not asserted.**
`fs2rts_ai_planning.lua:935-936` sets `damageDealt` and `stationDamageDealt` from
`CombatDamageTelemetry.totalByFaction[kind].hullDamage` and
`BaseDamageTelemetry.totalByFaction[kind].hullDamage`, defensively via `totalHull`
(`:930-934`), because the telemetry tables are rebuilt on demand and may be empty on a
short run.

**AI-I6 — Sum-of-intervals equals the last cumulative, modulo the reset.**
`AIEconomyFlow[kind]` is zeroed at the end of each FACTION summary
(`fs2rts_ai_planning.lua:1062`), so *the last record's `flow` field is not the running
total — it is the interval since the previous summary.* A consumer reading the last
record's `productionSpend` sees a number near zero while the match spent 1.33e5 CP. This
is a real and currently-live trap; see V-5.

**AI-I7 — `EXECUTION` rate denominators are transitions, not ship-time.**
Because of AI-13, `exec_total` (the denominator of `exec_idle_mode_rate`,
`exec_no_objective_rate`, `exec_unknown_goal_rate`, `exec_pursuit_rate` —
`core/tools/compare_batches.py:1094-1099`) counts *status/mode transitions*, not
samples and not ship-seconds. *Algebraically:* the rate answers "of the transitions into
a new execution state, what fraction entered IDLE", and is therefore scaled by fleet
growth independently of tasking behaviour.

**AI-I8 — Idle is defined once.**
*Algebraically:* `FACTION.idle` and `EXECUTION.mode=="IDLE"` must partition the same
set. `fs2rts_ai_planning.lua:971` excludes serviced ships (`elseif servicing then
s.servicing=s.servicing+1 else s.idle=s.idle+1`); `fs2rts_ai_planning.lua:850` does not
(`local mode=not state and 'IDLE' or ...`, and a serviced ship has
`AIOrderState[id]==nil` by `fs2rts_service.lua:124`). **This invariant is broken.**

**AI-I9 — `STATION_REPAIR.totalRepaired` implies ARMOR L2.**
`fs2rts_station.lua:895` gates station self-repair on `armor >= 2`. A faction that
never bought it reports `totalRepaired 0.0` forever, which is indistinguishable from
"station repair is broken" unless the consumer reads
`FACTION.economy.repairUnlocked` (`fs2rts_ai_planning.lua:1058`) or
`upgradeLevels.armor` (`:1056`). The emitter publishes both for exactly this reason
(`:1043-1047`).

**AI-I10 — Station upgrade spend is attributable.**
`upgradeSpend` (`:1054`) sums `tracks[track].costs[i]` for `i` up to the current level,
over the four tracks, and is published at `:1057`. *Consequence:* `BuyUpgrade` spends
through `SpendFactionCP` so it lands in `productionSpend` but emits no event of its own
(`:1040-1041`); `upgradeSpend` is the reconciliation term for that ~10% gap.

**AI-I11 — COUNTERS is cumulative and pre-seeded.**
`COUNTERS` (`fs2rts_ai_planning.lua:1069`) dumps `AIStats` + `AIOrderTelemetry` and is
**not** an interval. `orders.byMission` is faction → mission →
{success, failed, rejected, unchanged}, and the emitter pre-creates all four outcome
keys per mission, so every mission shows 0-valued failed/rejected/unchanged rows. Those
zeros are an artefact of pre-creation, not a measurement.

## Currently UNVERIFIED

- **AI-I2 (group partition).** `_Unverified._` No test asserts
  `ownedCount == servicing + playerControlled + Σ|units|`. **Would verify it:** one
  faction with a mix of groupable, servicing, and player-ordered hulls; assert the
  identity.
- **AI-I3 (per-class sums to total).** `_Unverified._` **Would verify it:** a faction
  with three distinct classes; assert `Σ replacementValueByClass[v] ==
  replacementValue`.
- **AI-I6 (interval vs cumulative).** `_Verified as a trap, not as a guard._` A peer
  agent reconciled the interval sum (1.33e5 for `session-fix`) against event costs and
  got −194 median on ~64k, under 0.3%, which proves the interval is summed rather
  than read off the last record. `analyze_batch.py` now does this. I did not re-run.
- **AI-I7 (transitions, not ship-time).** `_Verified analytically; reconstructed from
  events by a peer agent, not by me._` Their reconstruction: untasked IDLE ship-time
  6.20% → 2.08%, 99.3–99.7% of non-service IDLE transitions re-tasked at median latency
  0.03–0.07 s (one tick), 84–85% had a destroyed previous target, 0.3–0.7% never
  re-tasked. That reconstruction **refutes** the reading that `exec_idle_mode_rate`
  measured tasking starvation.
- **AI-I8 (one idle definition).** `_Violated._` See V-3. Not unverified — broken.
- **AI-I9 / AI-I10 (station repair and upgrade attribution).** `_Newly addressable,
  unverified._` The fields were added recently; no batch has been captured with them.
- **AI-9 (cadence gates).** `_Verified._` `test_station.py:353`
  `test_restart_reopens_the_cadence_and_contest_cadence_gates`; `core/README.md:127`
  claims per-faction sample cadence is pinned in `test_feature_request.py:764-845`.
- **AI-I11 (pre-seeded zeros).** `_Unverified as a documented artefact._` The emitter's
  pre-creation is the mechanism; whether any tool mistakes the zeros for measurements
  is not asserted anywhere.

## VIOLATIONS

### V-1 — CLEARED: `damageDealt` is no longer the string `'unknown'`

A peer agent reported `damageDealt` and `stationDamageDealt` as the literal string
`'unknown'` in 252/252 `FACTION` samples of one batch and 1025 + 1021 in two others.

**This is fixed in the current source.** `fs2rts_ai_planning.lua:935-936` assigns both
from resolved telemetry totals, with the explanatory comment at `:923-928` and the
defensive helper at `:930-934`. The `:912` constructor still initialises them to
`'unknown'`, but that value is overwritten before the record is emitted at `:1061`.

**Not a live violation.** Recorded because the historical batches are still on disk and
will keep reporting it; a reader comparing a pre-`:935` batch against a current one
will otherwise conclude the field is still broken.

### V-2 — CLEARED: `combatantValue` is emitted

A peer agent reported `analyze_batch.py:146` reading a `combatantValue` that no emitter
wrote, leaving `arms_race` and the balance table permanently `None`.
`core/tools/analyze_batch.py:411-415` now documents the fallback, and `:1263` prints
"(batch predates `combatantValue`; `replacementValue` was used instead)".

**`fs2rts_ai_planning.lua:963` emits it:** `s.combatantValue=s.replacementValue`, with
`:960-962` stating that both are emitted rather than renamed so saved batches stay
valid.

**Not a live violation.**

### V-3 — AI-18, AI-19 and AI-I8: two definitions of "idle"

**`FACTION.idle` excludes serviced ships.** `fs2rts_ai_planning.lua:971`:

```lua
elseif servicing then s.servicing=s.servicing+1 else s.idle=s.idle+1 end
```

with `servicing` computed at `:954` and the comment at `:949-953` explaining that
counting a docking ship as idle "made a healthy withdrawing fleet look uncommanded".

**`EXECUTION.mode` does not.** `fs2rts_ai_planning.lua:850`:

```lua
local mode=not state and 'IDLE' or ...
```

and a ship in `FleetServices` has `AIOrderState[id]==nil` by design
(`fs2rts_service.lua:124`, which is load-bearing for
`fs2rts_strategy.lua:680`). So **every** docked hull reports `mode=IDLE`.

**Violates AI-I8** ("idle is defined once"). Two fields, two definitions, same word.

Measured consequence from a peer agent's batches: `idle_mean` improved 93% while
`exec_idle_mode_rate` rose 22%, on the same runs. The two metrics disagree about the
same fleet because they measure different sets. A further structural problem: the three
`EXECUTION` rates `status==NO_OBJECTIVE`, `mode==IDLE` and `goalPresent=='unknown'` are
**identical by construction** in real batches — the same counts, 1239/316 and 3366 — so
they are one signal, not three, and a tool reporting them as three independent
indicators is over-counting evidence.

**This is an observability defect, not an AI defect.** The underlying AI behaviour was
measured and found mostly healthy (99%+ of non-service IDLE transitions re-tasked within
one tick). Fixing the *definition* is what is missing.

### V-4 — AI-18: an event type outside the documented 22 exists

`OPERATION_RESERVE` — 6 records in `session-verify` — appears in no event-mix
documentation. Found by a peer agent's `analyze_batch.py` event-mix section flagging
anything counted but not analysed. `_Minor, documentation-level._`

**Violates AI-18** in the sense that the documented event set is incomplete. Not a
behaviour defect.

### V-5 — AI-I6: the last `FACTION` record's economy flow is not the match total

`fs2rts_ai_planning.lua:1062` zeroes `AIEconomyFlow[kind]` immediately after emitting the
FACTION record at `:1061`. So `FACTION.economy.flow.productionSpend` on the **last**
record is the interval since the previous summary — measured near `0.0` on runs that
spent 1.33e5 CP. A tool that reads the last record's flow reports the match as having
spent nothing.

A peer agent's tool now sums the interval over the series and reconciles against event
costs (−194 median on ~64k, under 0.3%). **The consumer-side fix is done; the emitter is
unchanged by design**, since the interval semantics are what make per-interval rates
computable at all.

**Violates AI-I6 as stated**, which is the point of stating it: the invariant "sum of
intervals equals the total" is true, and any single-record reading of it is false.
`SENTRY_BUILD` is a **second** spend path missed by summing `PRODUCTION` alone — it
repeated the cost on `BUILD_STARTED`, `BUILD_COMPLETED` and `BUILD_CANCELLED`, so it
must be charged once
(`fs2rts_station.lua:486`, `:513-514`, `:516`).

### V-6 — AI-I6: ~10% of `productionSpend` remains unattributed

`BuyUpgrade` (`fs2rts_station.lua:145`) spends through `SpendFactionCP`, so it lands in
`productionSpend` (`fs2rts_station.lua:118`), but emits no `PRODUCTION` event of its own.
A peer agent measured ~8–17k CP per match (~10%) of `productionSpend` with no matching
event after accounting for `SENTRY_BUILD`.

**Two candidate explanations remain undistinguished** by that agent: a CP path that
spends without emitting an event, or the final interval lost because the run was killed
before the next FACTION summary. The emitter now publishes `upgradeSpend` and
`upgradeLevels` (`fs2rts_ai_planning.lua:1056-1057`) so the first explanation is
answerable from a fresh batch.

**Violates CI-1's completeness as an *observability* property** — the CP is accounted
for in the flow; it is the *event* attribution that is incomplete. Recorded as open.

### V-7 — AI-18: three EXECUTION metrics are one signal

See V-3's final paragraph. `exec_idle_mode_rate`, `exec_no_objective_rate` and
`exec_unknown_goal_rate` are one signal reported three times. **Violates AI-19** (one
definition per concept) at the metric layer.

### V-8 — AI-20 / AI-21 tension is unresolved for four emitters

A peer agent identified `CommitAIGroup`, `EmitContestRecord`, `EmitAICohesion` and
`SummarizeAI` as building records that are discarded when the trace is off, and argued
that guarding two of the four with an early return would **break** the others'
non-telemetry state maintenance (AI-I6, AI-I7's cadence baseline). **This is an open
design question, not a violation**, and it is recorded here so a future reader does not
apply AI-20 mechanically and freeze the interval accounting described at
`fs2rts_ai_planning.lua:1062-1064`.