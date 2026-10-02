# 02 — Spawning and placement

**Subsystem:** `core/data/scripts/fs2rts_factions.lua` (`GetSpawnFrame`, :339-605;
`SpawnFactionUnit` callers), `fs2rts_production.lua` (`SpawnFriendly` :161,
`SpawnFactionUnit` :283, `SpawnConfiguredWave` :292)
**Prefix:** `SC-`

## PROMISES

**SC-1.** Every ship the mod creates is created through `GetSpawnFrame`
(`fs2rts_factions.lua:339`), which returns a finite position and an orientation
toward the battlefield (`:604`).

**SC-2.** A spawned hull clears every other hull and the anchor station by a
collision-sized margin. The final sweep tests both the blocker set and the anchor
(`fs2rts_factions.lua:547-553`); `clear()` deliberately skips the anchor during the
search fan (`:391`, tested at `:409-417`) and the dedicated pass exists precisely
because of that (`:547-552`).

**SC-3.** A capital never spawns inside a hostile station's kill ring. Both the
search fan and the pull-back respect `GetEnemyBaseSeparation()`
(`fs2rts_factions.lua:418-426`, `:485-506`); the last-resort fallback uses the full
separation times 1.05 (`:502`).

**SC-4.** A capital that cannot find a usable slot still lands inside its own
station's ring rather than walking toward the enemy. The clamp uses the same `reach`
formula as the placement (`:525-527`), deliberately matching it because the old
ship-only formula (`0.84 * R`) dragged a correctly placed capital back inside its
own hull (`:521-524`).

**SC-5.** The position handed to `mn.createShip` is finite. The last gate before
creation replaces a non-finite result with a plain ring slot on the anchor's own
side (`fs2rts_factions.lua:540-546`). A NaN position makes `ship_create` build a
hull the player can never see or select, with no error anywhere (`:535-539`).

**SC-6.** A spawn that resolves to no usable slot is **logged**, not silently
accepted (`fs2rts_factions.lua:512-513`), with the class, anchor and batch.

**SC-7.** A failed `mn.createShip` is logged with class and position
(`fs2rts_production.lua:174`, `fs2rts_factions.lua:289`). `mn.createShip` hands back
an invalid handle when `ship_create` refuses the class (`fs2rts_production.lua:171-173`).

**SC-8.** Spawn geometry is deterministic for a given batch. The golden-angle scatter
is `(batch * 137.508) % 360` clamped to a forward cone (`:361-362`); an anchor at
the world origin uses a fixed bearing instead of the model's nose vector (`:344-350`).

## REFUSES

**SC-9.** `SpawnFactionUnit` refuses when the anchor is invalid, the team is nil or
invalid, or the class is nil/invalid (`fs2rts_production.lua:284-285`), returning
nil and logging.

**SC-10.** `GetSpawnFrame` refuses to return an offset that is (a) inside any
blocker's radius + 250 m, (b) inside the anchor's own hull, or (c) within
`MinEnemyBaseSeparation` of a living hostile station (`:409-430`, `:547-553`).

**SC-11.** The capital spawn reach is hard-capped at `CapitalSpawn.MaxStationRadius`
= 9000 m regardless of hull size (`fs2rts_config.lua:350`, applied at
`fs2rts_factions.lua:440`, `:443`, `:525`).

## MUST NEVER

**SC-12.** **Never spawn a hull inside the anchor's own station hull.** The reach
must clear anchor *and* incoming hull: `anchorRadius + shipRadius + clearance`
(`fs2rts_factions.lua:441`). Deriving it from the ship's radius alone
(`0.35 * 2.4 * R = 0.84R`) put a 700 m capital ~590 m from the station centre,
inside any station hull wider than that (`:434-439`).

**SC-13.** **Never spawn a capital inside an enemy base ring.** Telemetry caught a
Colossus materialising 9000 m from an enemy base — exactly `0.75 * 12000`
(`:499-500`). A translated retry is what walks a huge hull across the map, so both
constraints live *inside* the fan, not just on its result (`:427-430`).

**SC-14.** **Never accept a player-authored station as an unhandled spawn case.**
The bearing is computed from the anchor's position toward the world centre (`:342`),
which is defined for any anchor; the origin case is handled explicitly (`:344-350`).

**SC-15.** **Never silently drop a hull.** Every failure path either returns nil to a
caller that logs it, or logs at the point of failure (SC-6, SC-7).

## INVARIANTS

**SC-I1 — Blocker snapshot is per-call.** `blockers` (`:389-399`) and
`hostileStations` (`:401-408`) are built once per `GetSpawnFrame` call. *Algebraically:*
`#ADE property crossings for one call is O(#ships), not O(#ships × #candidates)`.
The rationale is at `:382-388`: the old path was ~37,000 crossings for a single
4-ship wing. Nothing moves during one call.

**SC-I2 — Separation applies to the retry, not only the first slot.**
*Algebraically:* `tooClose(pos)` is part of `usable(pos)` (`:430`), and `usable`
gates every attempt of both the main fan (`:478-483`) and the pull-back fan (`:491-494`).

**SC-I3 — Spawn cost is O(ships) per hull, and the blocker set is not rebuilt per
attempt.** Follows from SC-I1. `test_station.py` pins the outcome
(`test_spawn_frame_scatter_avoids_an_occupied_capital_sized_slot`, :659;
`test_spawn_frame_ignores_transient_ships_without_placement_data`, :675) but
`_unverified for the complexity bound_` — no test counts property crossings.

**SC-I4 — Capital spawn distance from own station.**
`dist(pos, anchor) <= min(9000, anchorRadius + shipRadius + 1100 + 0.35 * 2.4 * shipRadius)`
(`:440-442`, `:525-527`, clamped at `:530-533`). Read straight off the config:
`MaxStationRadius=9000`, `MaxStationRadiusFactor=2.4`, `ForwardBias=0.35`
(`fs2rts_config.lua:348-356`).

**SC-I5 — Hostile-station separation.**
`min over living hostile stations of dist(pos, station) >= MinEnemyBaseSeparation`
= 12000 m (`fs2rts_config.lua:353`), with the 1.05 fallback at `:502`.
*Except* at the final fallback, where `ok` may remain false and `pos` is accepted
anyway (`:501-518`) — see V-1.

**SC-I6 — Batch serialisation.** `EnemySerial` increments per faction unit
(`fs2rts_production.lua:286`) and `BuildBatchSerial` per player build
(`fs2rts_production.lua:165`), so the golden angle advances once per batch, not once
per hull within a batch.

## Currently UNVERIFIED

- **SC-I3 (complexity).** `_Unverified._` **Would verify it:** a test double whose
  property accessors count, asserting crossings are linear in ship count for a
  4-hull wing.
- **SC-I5 (separation).** `_Partially verified._` `core/README.md:115` claims
  `analyze_batch.py` reports "capital spawn placement against both the own-base and
  enemy-base limits". I did not run it this session; the invariant is the tool's
  subject, not the tool's guarantee.
- **SC-I4 (own-station distance).** `_Unverified against live geometry._` The
  arithmetic is verified by reading; that no real capital class exceeds it depends
  on loaded model radii, which needs the engine.
- **Spawn placement of *waves*.** `SpawnConfiguredWave`
  (`fs2rts_production.lua:292`) uses the same frame function, but legacy waves are
  off by default (`AI.UseLegacyWaves=false`, `fs2rts_config.lua:717`) and the wave
  path emits `cost=0, economyTreatment="free-reinforcement"` (`:311`) with no fleet-cap
  reservation of its own. `_Unverified._`

## VIOLATIONS

### V-1 — SC-5 and SC-13: a fully unusable spawn slot is accepted anyway

`fs2rts_factions.lua:507-518`. When no candidate satisfies
`clear() AND NOT tooClose()`, the code logs (`:512-513`) and then, if
`ClampCommandPoint` returns a point, uses it regardless (`:515-518`). So the
finite-vector guarantee (SC-5) survives, but the hostile-separation guarantee
(SC-13, SC-I5) does **not** — the hull is handed to `mn.createShip` inside an enemy
base ring.

This is a deliberate, logged trade (the log line names the failure at `:512`), but
the contract sentence says "never", and the code does not honour it. **Violates
SC-13.** Whether a capital spawning inside a hostile kill ring is worse than no
capital at all is a design question this document does not settle.

### V-2 — SC-10: `clear()` cannot see the anchor

`fs2rts_factions.lua:391` excludes the anchor from `blockers`, so during the search
fan `clear(pos)` (`:409-417`) accepts a position inside the anchor's hull. This is
compensated by the dedicated anchor sweep at `:547-553`, so SC-2 holds — but only
because a *later* gate exists. **SC-10 as written overstates what the search fan
enforces.** The contract sentence is stricter than the mechanism; recording that
rather than quietly weakening either.