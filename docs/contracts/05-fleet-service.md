# 05 — Fleet service and rearm

**Subsystem:** `core/data/scripts/fs2rts_service.lua` (617 lines)
**Config:** `Config.Station.FleetService` (`fs2rts_config.lua:593-619`)
**Prefix:** `SV-`

## PROMISES

**SV-1.** A service round trip is a round trip. The player's pre-existing order is
parked on the service record at `BeginFleetService` (`:122-123`) and restored at
`FinishFleetService` (`:162`) or on an interrupt (`:351-352`). Rationale at `:117-121`:
`SetUserOrder` refuses to act on a servicing ship, so without this the order stayed
recorded but unreachable and nothing would reissue it.

**SV-2.** Service does not touch the player's `UserOrders` table. `BeginFleetService`
does not clear it (`:122` reads, never writes).

**SV-3.** A docking hull holds no strategic order. `BeginFleetService` nils
`AIOrderState[id]` and `PolicyApplied[id]` (`:124`). This is load-bearing in two
places: the strategic planner excludes serviced ships from group building
(`fs2rts_strategy.lua:680-681`) and the FACTION summary counts them separately
(`fs2rts_ai_planning.lua:954`, `:971`).

**SV-4.** Arrival is physical, not logical. Repair only begins once
`ship.Position:getDistance(point) <= c.ArrivalRadius` (`:255`); before that the phase
is `RETURNING` and the function returns 0 (`:256-260`).

**SV-5.** Travel and queue time accrue no recovery. The repair arithmetic is only
reached after the arrival test (`:255`) and the hold test (`:312`).

**SV-6.** On arrival the hull is actively braked. Linear and rotational velocity are
zeroed (`:278`) and `ORDER_STAY_STILL` is re-asserted every tick while the hold is
intact (`:304-311`). Rationale at `:269-274`: `ORDER_STAY_STILL` is not a brake —
`ai_still()` only calls `turn_towards_point` and never applies longitudinal thrust,
so an arriving hull coasts at cruise forever and sails back out of the arrival radius.

**SV-7.** Completion requires all of: elapsed ≥ `MinimumRecoverySeconds`, hull ≥
`ReadyHull`, ammo ≥ `ReadyAmmo`, subsystem health ≥ `ReadyHull`, quiet for
`QuietSeconds`, and no live threat (`:324-325`).

**SV-8.** Damage resets the quiet clock on hull, shield **or** subsystem loss
(`:232-233`), so light chip damage suppresses work just as effectively as a large hit.

**SV-9.** A manual (player-ordered) SERVICE is never cancelled by the AI. Both abort
paths guard on `not s.manual`: the station-under-attack abort (`:463`) and the
under-fire timeout (`:338`).

**SV-10.** A docked hull that cannot repair is released after a bounded time and
re-enters the fight. `MaxUnderFireSeconds = 240` (`fs2rts_config.lua:606`); on expiry
the record is dropped, the cooldown applied, and the hull re-tasked (`:337-356`).

**SV-11.** A station under attack aborts *every* docked phase, not just the ones it
used to cover. The abort runs before the dispatch loop (`:456-485`) and covers
`REPAIR_REARM`, `WAIT_CP` and `QUEUED` (`:462`).

**SV-12.** Service spend is CP-metered. Every hull, subsystem and ammo increment is
gated on a successful `SpendFactionCP` (`:370`, `:377`, `:392`), and each branch
degrades to zero on failure rather than applying the repair unpaid (`:370`).

**SV-13.** Fractional ammo carries only while actually receiving service. `ammoCredit`
accumulates fractional rounds and the integer part is spent (`:387-391`); native
`AmmoLeft` is integer (`:385`).

**SV-14.** The service pad sits on the ship's own side of the station and is latched
at the start of the run. `GetServiceApproach` returns the unit vector *from the ship
toward the station* (`:174-192`); the pad is placed at `station - approach*separation`
(`:203`), and the latch is at `:251-253`. Rationale at `:246-250`: recomputing the
bearing from a live threat each tick made the pad teleport by twice the separation
whenever the threat changed side, which `MoveFleetServiceShip` read as drift.

**SV-15.** Slot accounting is explicit. Capital/heavy/juggernaut consume
`c.Slots` (both), others 1 (`:362`); a hull needing more than the remaining slots is
`QUEUED` (`:363`).

**SV-16.** Manual service rejects a dead station up front (`:114`) and a possessed
ship (`:109`).

## REFUSES

**SV-17.** `BeginFleetService` refuses for a non-serviceable ship or the possessed
ship (`:109`), for a manual request when the station is not alive (`:114`). A
ship already in service returns `true` without re-entering (`:112`) — idempotent,
not a re-trigger.

**SV-18.** `ReissueUserOrder` refuses any ship currently in service
(`fs2rts_orders.lua:632`), and `EngageShip` / `ReturnToDefaultControl` do the same
(`fs2rts_orders.lua:19`, `:58`).

**SV-19.** `MoveFleetServiceShip` refuses with `NO_SAFE_ROUTE` when no point exists
(`:209`) and `ORDER_FAILED` when the waypoint or the order cannot be installed
(`:215`, `:220`).

**SV-20.** Service never starts for a ship the player has personally tasked, except
on critical hull (`fs2rts_service.lua:553`, and the `not order` guards at `:554-556`).
Rationale at `:549-552`: critical hull overrides because breaking a guard order to
survive is a reflex, not autonomy.

## MUST NEVER

**SV-21.** **Never cancel a player's explicit SERVICE order.** Matched with the
station-alarm path (`fs2rts_config.lua:605`, `:336`).

**SV-22.** **Never park a hull forever.** The livelock this guards against: a docked
hull whose pad stays inside a hostile's `DangerRadius` (4500) can never satisfy
`not alive(threat)` at `:325`, so it sat in `UNDER_FIRE` for the whole mission — never
repaired, never released, reporting `mode=IDLE` the entire time because a ship in
`FleetServices` holds no `AIOrderState`. The station-under-attack abort only covered
`REPAIR_REARM`/`WAIT_CP`/`QUEUED`, so nothing broke the tie. Measured by a peer agent
over batch `sentryfix-20261001`: 216–254 service entries per match still open at run
end, 12–28% of all service ship-time in `UNDER_FIRE` against 0.8–1.4% actually spent
repairing (`fs2rts_config.lua:596-606`, `fs2rts_service.lua:327-336`).

**SV-23.** **Never let a released hull immediately re-park.** The release takes
`FleetServiceCooldown[sid] = now + RetrySeconds` (`:349`), and `retryReady` gates
every non-critical start reason (`:548`).

**SV-24.** **Never charge CP for work that is not applied.** ST-12's mechanism. On
each branch, a failed spend sets the applied amount to zero (`:370`) rather than
applying it free.

**SV-25.** **Never route a rearming ship through the station hull.** SV-14's
mechanism, with the failure named: adding the approach instead of subtracting it
places the pad beyond the station and routes the ship through the hull, which is the
rearm-collision bug (`:169-173`).

## INVARIANTS

**SV-I1 — Slot conservation.**
*Algebraically:* for each faction `k`, at the end of the dispatch loop
`slots[BLUE] + Σ weight(dispatched) == c.Slots`, where `weight ∈ {1, c.Slots}`.
`slots` is initialised to `c.Slots` per faction (`:586`) and decremented by each
`ServiceFleetShip` return (`:591`), and `ServiceFleetShip` returns 0 unless it
actually worked the hull (`:244`, `:260`, `:316`, `:325`, `:356`, `:358`) and
otherwise returns `weight` (`:404`).

**SV-I2 — At most one service record per signature.**
`self.FleetServices[id]` is set once (`:124`), checked before set (`:112`), and
removed at exactly five sites: `CancelFleetServiceForShip` (`:139`),
`FinishFleetService` (`:154`), the station-under-attack abort (`:468`), the under-fire
release (`:342`), and the staleness sweep (`:594`).

**SV-I3 — A serviced ship has no strategic order.**
`AIOrderState[id] == nil` whenever `FleetServices[id] ~= nil`.
Established at `:124` and re-established on every removal (`:139`, `:154`, `:469`,
`:343`); the test at `fs2rts_strategy.lua:680` and `fs2rts_ai_planning.lua:954`
depend on it.

**SV-I4 — Repair never exceeds the ready thresholds.**
`hull <= ReadyHull * HitpointsMax` at completion (`:324`), because `heal` is bounded
by `max(0, ReadyHull*max - HitpointsLeft)` (`:366`); the same bound applies per
subsystem (`:374`) and ammo is bounded by `ceil(ReadyAmmo*max - left)` (`:383`).

**SV-I5 — Repair is gated on quiet time.**
`now - s.quietAt >= QuietSeconds` (8 s, `fs2rts_config.lua:595`) is required at
`:324` and `:326`. `quietAt` is set on any hull/shield/subsystem loss (`:233`) and on
arrival (`:275`).

**SV-I6 — Service spend is bounded by the faction's CP.**
*Algebraically:* `Σ spent <= GetFactionCP(kind)` at all times, because every
increment is behind a successful `SpendFactionCP` and that function refuses when
`cp < amount`. The extra guards are belt-and-braces: `budget/value/HullCostFraction*max`
bounds hull (`:367`), `cp/rate` bounds each subsystem (`:376`), and
`floor(cp/cost)` bounds ammo (`:389`).

**SV-I7 — Phase transitions are monotonic within a tick.**
`SetFleetServicePhase` (`:101`) early-returns when the phase is unchanged (`:102`),
so `FLEET_SERVICE` telemetry is emitted on transitions only, not every tick.

**SV-I8 — A released hull takes a cooldown.**
`FleetServiceCooldown[id] >= now` after any interruption (`:349`, `:474`) and after
completion (`:155`).

## Currently UNVERIFIED

- **SV-I1 (slot conservation).** `_Unverified as an identity._` Tests exercise the
  under-fire release and the quiet completion (`test_service.py:289-303`,
  `:309-317`) but never assert `slots` accounting across a multi-hull dispatch.
  **Would verify it:** three hulls where one is a capital, asserting the third is
  `QUEUED` and that after the capital finishes the third becomes `REPAIR_REARM`.
- **SV-I2 (one record per signature).** `_Unverified._` The idempotent early return at
  `:112` is untested. **Would verify it:** call `BeginFleetService` twice and assert
  `FleetServices[id].started` did not change.
- **SV-I4 (repair thresholds).** `_Verified._` `core/README.md:65` states the exact
  numbers and they match the config (`:607-610`).
- **SV-I5 (quiet-time gate).** `_Verified._` `test_station.py:190`
  `test_fractional_damage_keeps_out_of_combat_repair_delayed`; `test_service.py:309`
  `test_quiet_refit_completes_and_never_reports_under_fire`.
- **SV-I6 (CP bound under a mid-repair faction bankruptcy).** `_Unverified._` No
  test drains CP to zero mid-repair and asserts no negative pool and no unpaid
  repair. **Would verify it:** set `AIStates[kind].cp` between two subsystem repairs.
- **SV-I4 (subsystem ceiling).** `_Unverified._` The subsystem bound (`:374`) and its
  CP cap (`:376`) have no dedicated test.

## VIOLATIONS

None confirmed.

**Checked and cleared:** the two "two definitions of idle" claims are *real and
still live*, but they are an observability-semantics defect in the telemetry layer,
not in this subsystem — a serviced ship reporting `mode=IDLE` is a direct and
intended consequence of SV-3. Recorded in
[08-strategy-planning.md](08-strategy-planning.md) V-6 and V-7.

**Checked and cleared:** a peer agent reported `STATION_REPAIR.totalRepaired` and
`.repaired` as 0 in every record of two batches. That is explained by
`fs2rts_station.lua:895` — station self-repair is gated on `armor >= 2`, and a
faction that never bought it legitimately reports 0 forever. The emitter now
publishes `repairUnlocked` and `upgradeLevels` precisely so this is answerable
(`fs2rts_ai_planning.lua:1058`, `:1043-1047`). Not a defect in this subsystem.