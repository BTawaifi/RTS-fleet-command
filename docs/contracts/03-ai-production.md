# 03 — Fleet production / AI producer

**Subsystem:** `core/data/scripts/fs2rts_ai_production.lua` (446 lines)
**Config:** `Config.AI.*` (`fs2rts_config.lua:673-990`), `Config.Station.AI.*`
(`:634-662`)
**Prefix:** `PR-`

This is the subsystem that shipped the livelock. Read PR-4 and PR-11 before
changing anything here.

## PROMISES

**PR-1.** The producer spends a faction's CP only through one decision function.
`ChooseAIBuild` (`:73`) is the sole chooser; `UpdateAIProduction` (`:350`) calls it
at `:425` and applies the result at `:429`.

**PR-2.** Every build decision is recorded. `ChooseAIBuild` returns a `decision`
table for every path, including the no-purchase paths (`:228`, `:248`), and
`UpdateAIProduction` emits it as `AI_BUILD_DECISION` (`:426`).

**PR-3.** A purchase charges CP once and records the flow once. `:429` decrements
`state.cp`; `:433` records `productionSpend`. The queue carries `entry`, `estimate`,
`count` and a `finishTime` (`:431-432`).

**PR-4.** **A save window must age out.** `state.savingSince` is the only thing that
ages `SAVING_FOR_DESIRED_ROLE` into `savingFallback` (`:185-186`, checked at `:186`,
fallback at `:234`). *Algebraically:*
`exists t1<t2 : t2 - t1 >= savingSeconds AND savingFallback fired at t2`,
for any sequence of thinks that does not itself purchase the goal.

**PR-5.** The saving window length is bounded and tier-aware: `MaxProductionSavingSeconds`
= 120 s default, `CapitalSavingSeconds` = 600 s at tier ≥ 3,
`HeavyCapitalSavingSeconds` = 900 s at tier ≥ 4, `JuggernautSavingSeconds` = 600 s at
tier ≥ 5 (`:138-143`; `fs2rts_config.lua:730`, `:770-772`).

**PR-6.** A rising emergency edge cancels the save window exactly once. The gate is
edge-triggered via `emergencyState.wasEmergencyBuild` (`:179-180`) and clears
`savingRole`, `savingSince` and `productionReserve` (`:241`).

**PR-7.** A faction at its fleet cap does not re-walk the ship list every frame.
`nextThink` is advanced inside *both* branches (`:422`, `:440`).

**PR-8.** Blue's automatic production stops when Auto Mode is switched off
(`:358`, `:372`), and a diagnostic event is emitted at most once per
`BlueAutoStateLeakInterval` (`:359-365`).

**PR-9.** Role counting and value counting agree. `CountAIRoleUnits` (`:45`) returns
`counts` and `values` where both are incremented in the same block (`:55`, `:58`),
and `counts.total` is incremented exactly when `values.total` is.

**PR-10.** The role category collapse is consistent: `heavy`, `juggernaut` and
`capital` all map to the `"capital"` category in the chooser (`:53`, `:84`, `:97`).

**PR-11.** **A producer that cannot afford its goal must still make progress.** Either
the goal becomes affordable and the window ends in that purchase, or the window
expires and the producer buys the cheapest affordable role. *Aspiration:* the
producer must never be in a state where every think repeats the same non-purchase
while an affordable option exists. `:228` returns nil with
`reason="SAVING_FOR_DESIRED_ROLE"` only when `#during==0`, which is the intended
"actually save" behaviour — but see V-1.

**PR-12.** Build placement is observable. Every `PRODUCTION` event carries
`placements[]` with each hull's spawn coordinates (`:388-393`), because placement is
the only proof that capitals land near their own station.

## REFUSES

**PR-13.** `ChooseAIBuild` refuses any option that is unlocked-but-unavailable
(`class:isValid()` false, `:107`), does not fit the fleet cap (`fitsFleetCap`,
`:110`, gate at `:116`), or is unaffordable (`affordable`, `:112`, gate at `:122`).

**PR-14.** It refuses to consider a role the faction has not unlocked:
`(entry.tier or 1) <= tier` (`:83`).

**PR-15.** A strike wing larger than the free slots is trimmed to fit rather than
abandoned: `if slots>0 and count>slots then count=slots` (`:105`). Rationale at
`:99-104`: with fewer free slots than a wing, no fighter/bomber option can satisfy
`count<=slots`, so the AI silently fell through to single-hull capitals and its
strike force decayed monotonically.

**PR-16.** An empty candidate set is refused with a specific reason, not a silent
nil: `NO_UNLOCKED_OPTIONS` / `FLEET_CAP` / `INSUFFICIENT_CP` (`:244-246`).

**PR-17.** A player-economy faction (Blue under Auto Mode) is excluded from the
bank-target bound (`:153-156`). `rate` is 0 for such a faction because this function
does not model the player's income, so the bound would silently change what Blue
builds. The same reasoning guards `canBank` (`:217-221`).

## MUST NEVER

**PR-18.** **Never restart a save window on a purchase that is itself the window's
alongside output.** This is the livelock. `savingSince` is cleared at `:305` on
every purchase; with `FieldCheapHullWhileSaving=true` (`fs2rts_config.lua:739`) the
purchase the window deliberately fields *alongside* an unmet goal is that very
purchase, so the clock restarts every think, the goal never ages out,
`savingFallback` never runs, and the bank never accumulates. Measured by a peer
agent over batch `sentrybudget-a` (4 matches × 3000 s, real engine):
`desiredRole=capital` in 2346 of 3792 build decisions, `bankTarget` median 8600 CP,
per-faction CP bank peak 1300–2494 CP, **zero** capital builds in 4 of 4 matches,
against a baseline of 1 capital per faction per match (`:296-301`).

**PR-19.** **Never aim `bankTarget` at a price the faction cannot reach inside one
window.** The newest-tier cheapest capital is 12675 CP at tier 4 and 13825 at tier
5, up to 31275 for a juggernaut, while the measured per-faction bank peaks near
2300 CP (`:144-152`). With `FieldCheapHullWhileSaving` false the producer banked
~7700 CP for ~2600 s and built nothing at all (`:208-210`).

**PR-20.** **Never clear the save clock on every frame of a sustained emergency.**
A routine weapon lock during a committed assault spans many 2 s strategic frames;
clearing on each meant the more committed the assault, the less the AI ever built a
capital (`:174-178`).

**PR-21.** **Never charge Blue's player CP while Auto Mode is off** (`:372`).

**PR-22.** **Never exceed the fleet cap.** `slots = cap - CountCommittedCombatants`
(`:76`); `CountCommittedCombatants` includes the AI queue (`:69`) and, for Blue, the
manual build queue (`:67`).

## INVARIANTS

**PR-I1 — Sum-of-counts identity.**
`counts.total == Σ_cat counts[cat]` and `values.total == Σ_cat values[cat]`, over
`cat ∈ {fighter, bomber, escort, capital}`. Both sides are incremented in the same
`EachShip` iteration (`:55`, `:58`), with no early `return` between them. Note
`counts.juggernaut` is a *sub-count* of `counts.capital` (`:56`), not a fifth
category — so the sum runs over the four categories only.

**PR-I2 — Affordability is checked against the cap, not just CP.**
A chosen option satisfies `cost <= state.cp` (`:122`) **and** `count <= slots`
(`:116`). *Algebraically:* for every `PRODUCTION/QUEUE_ACCEPTED` event,
`selectedCost <= cpBefore` and `selectedCount <= slots`.

**PR-I3 — Queue accounting.** Exactly one of `state.queue == nil` or
`state.queue ~= nil` holds per faction at the end of `UpdateAIProduction`.
`state.queue=nil` at `:405`; the `blockedAt` branch (`:406-411`) leaves it set. No
other site assigns it. The player `BuildQueue` is `#`-indexed and only ever appended
(`fs2rts_production.lua:154`) and removed (`:277`).

**PR-I4 — CP conservation.** Every CP decrease is paired with a
`RecordAIEconomyFlow` call: `:429` with `:433`, plus `SpendFactionCP`
(`fs2rts_station.lua:118`). Income at `:377`. See CI-1.

**PR-I5 — Selection is a probability distribution.**
`decision.selectedProbability == weight/total` (`:285`) and
`Σ candidates' probability == 1` up to float error, because the draw is
`math.random() * total` with `total = Σ weight` (`:279-280`).
`selected` falls back to `candidates[1]` if the cumulative subtraction never goes
non-positive (`:290`), so selection is total.

**PR-I6 — The save window is bounded in wall time.**
`0 <= now - state.savingSince <= savingSeconds` while `reason ==
"SAVING_FOR_DESIRED_ROLE"`. Direct consequence of `:186`. **This is the invariant
the livelock broke** — it is the one to write a test against.

**PR-I7 — Fleet-cap enforcement is monotone.**
`CountFactionCombatants(kind) + queued.count <= cap` is required to spawn
(`:382`); otherwise `blockedAt` is set once (`:406-407`) and the queue is retained.

**PR-I8 — Income ramp is shared.** One function, `GetAIIncomeRamp` (`:338`), used by
both the producer (`:354`, `:376`) and the bank-target bound (`:157`, `:216`).
`GetIncomeMultiplier` (`fs2rts_station.lua:64`) is the single upgrade-driven
multiplier. Rationale at `:326-337`: the AI used to run `26.1` CP/s against the
player's `17.6`, and Blue led combatant value in 0% of samples across 32 matches.

## Currently UNVERIFIED

- **PR-I6 (window ages out).** `_Tested but gated on a flag that ships off._`
  `test_station.py:1027` `test_saving_clock_survives_fielding_a_cheap_hull` sets
  `PreserveSavingClockWhileFielding=true` explicitly (`:1047`). The shipped default
  is `false` (`fs2rts_config.lua:753`). **The invariant is only asserted for
  behaviour that is not the default.** See V-1.
- **PR-I1 (sum identity).** `_Unverified._` `test_station.py:1160-1164` asserts
  `counts.total==0` and `counts.total==1`, which a broken sum would also satisfy.
  **Would verify it:** a fixture with one hull of each of the five roles, asserting
  `counts.total == counts.fighter+counts.bomber+counts.escort+counts.capital` and
  that `counts.juggernaut <= counts.capital`.
- **PR-I5 (probability sums to 1).** `_Unverified._` No test asserts
  `Σ probability == 1`. **Would verify it:** seed `math.random`, force a fixed
  candidate set, assert the sum.
- **PR-I7 (cap is monotone).** `_Unverified._` **Would verify it:** set
  `CountFactionCombatants` to `cap-1` with `queued.count=2`, assert no `UNIT_SPAWNED`
  and exactly one `BUILD_BLOCKED`.
- **PR-I8 (one ramp).** `_Unverified structurally._` Both call sites read
  `GetAIIncomeRamp`; no test asserts the player and AI curves are the same function,
  which is the point of the change.

## VIOLATIONS

### V-1 — PR-4 and PR-18 are violated in the shipped default

`fs2rts_ai_production.lua:302-305`:

```lua
local fieldingAlongside = decision.savingAlongside==true
    and self.Config.AI.PreserveSavingClockWhileFielding==true
state.productionReserve=0
if not fieldingAlongside then state.savingRole=nil; state.savingSince=nil end
```

With `AI.PreserveSavingClockWhileFielding = false` (`fs2rts_config.lua:753`),
`fieldingAlongside` is false on every purchase, so `savingSince` is cleared on every
purchase — exactly the mechanism PR-18 forbids. `savingSince` remains the only thing
that ages the window (`:293`, `:296-298`).

**Violates PR-4, PR-6's sibling guarantee, and PR-18.**

The fix exists and is correct; it is behind a flag whose default is the bug. Two
independent corroborations that this is live rather than theoretical:

- `test_station.py:1090` asserts `PreserveSavingClockWhileFielding==false`
  (`test_saving_clock_default_keeps_the_pre_flag_clearing_behaviour`, :1075) — the
  suite **pins the livelock as required behaviour**. The test's own comment (`:1076`)
  calls `false` "what shipped", which was true before the flag existed.
- `test_station.py:1024` asserts `BoundBankTarget==false`
  (`test_bound_bank_target_defaults_off`, :1023). **SUPERSEDED — this is no longer a
  violation.** An earlier revision of this contract recorded the config as shipping
  `BoundBankTarget = true` and reported the test as failing. That was a transient
  state captured mid-A/B by a concurrent agent, not a standing fact: the flag
  ships `false` (`fs2rts_config.lua:787`) and the suite is green. Recorded here
  because a contract that reports a transient as a live violation is worse than
  no contract, and a future maintainer must not "fix" this flag on the strength
  of the earlier claim.

So the two config defaults and the tests that describe them now AGREE. The
`PreserveSavingClockWhileFielding` assertion above remains a real observation
about test intent - see the note on it - but there is no live test/config
disagreement. `_Reported, not fixed — I do not own these files._`