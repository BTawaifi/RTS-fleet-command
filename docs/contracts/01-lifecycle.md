# 01 — Lifecycle, shutdown and frame budget

**Subsystem:** `core/data/scripts/fs2rts_lifecycle.lua` (873 lines)
**Also:** `fs2rts_factions.lua` (`ResetState`, :840-887), `fs2rts.lua` (load order)
**Prefix:** `LC-`

## PROMISES

**LC-1.** The mod activates only in an RTS mission. `OnGameplayStart` sets
`self.Enabled=false` and returns unless `IsRTSMission()` (`fs2rts_lifecycle.lua:456`).
Every other entry point checks `Enabled` first (`fs2rts_lifecycle.lua:603`).

**LC-2.** `Shutdown` is idempotent and safe to re-enter. It clears `Enabled` on its
first statement (`:533`), and a second call returns at the guard (`:532`), because
a state-end hook can fire again on the way out.

**LC-3.** `Shutdown` releases every engine handle the mod holds. `ReleaseObjectHandles`
(`:575`) wipes 18 signature-keyed tables (`:581-586`), the pooled waypoint tables
(`:589-590`), 5 pending-work tables (`:592`), the ship cache (`:594`) and 5
projection tables (`:597-599`). Each wipe is individually `pcall`-guarded (`:578`)
so one failure cannot abort the remaining steps.

**LC-4.** *Aspiration, and load-bearing.* `ReleaseObjectHandles` is the **only**
thing standing between a second mission in one session and a use-after-free. FSO
never tears down scripting state between missions: `luaL_openlibs` runs at startup
and there is no `lua_close`, and the global hook table exposes no mission-cleanup
hook (`fs2rts_lifecycle.lua:557-560`). Signatures are recycled per-mission
(`:567-570`). The contract is therefore absolute: **if a table can hold a ship
handle or be keyed by signature, it must appear in the wipe list.**

**LC-5.** Transient game states do not tear the session down. `OnStateEnd` (`:521`)
returns early for the 16 names in `TRANSIENT_GAME_STATES` (`:502-519`); anything
else calls `Shutdown`.

**LC-6.** Player-owned engine state is restored. `Shutdown` restores button control
mode (`:546`), `AllButtonPolling` (`:547`) and `io.MouseControlStatus` (`:549`),
each only if a previous value was captured (`:547`, `:549`).

**LC-7.** The scenario has exactly one clock. Escalation, economy and AI difficulty
all read `GetScenarioElapsed` (`fs2rts_factions.lua:17`), which is mission time.
The wall-clock accumulator that used to drive tiers is gone, deliberately
(`fs2rts_factions.lua:22-28`).

## REFUSES

**LC-8.** `Shutdown` refuses to run twice (`:532`).

**LC-9.** `OnStateEnd` refuses to act on a nil new-state name (`:523`) and on any
transient state (`:524`).

**LC-10.** `OnFrame` refuses to advance the simulation while cinematic (`:611`),
post-battle (`:638`) or paused (`:645`) — the pause gate is what stops
mission-time systems drifting on frames that still run for input and HUD.

**LC-11.** `StartScenario` refuses to start with fewer than two factions
(`:414`), leaving `SetupActive` true so the player returns to setup.

**LC-12.** Stabilization of a dying station is refused unless the resolved object
really is a command station in its death roll (`:693`). A recycled signature
resolving to an unrelated live ship drops out of the table instead (`:696`).

## MUST NEVER

**LC-13.** **Never abort the rest of `OnFrame` on a single subsystem's error.**
FSO only logs a Lua exception; an uncaught raise silently truncates the frame.
This is why `UpdateBuildQueue` `pcall`s the whole spawn
(`fs2rts_production.lua:250`) — the `table.remove` that retires a queue item is the
only thing that does, so a raise there caused duplicate hulls on every subsequent
frame until the fleet cap latched (`fs2rts_production.lua:242-249`).

**LC-14.** **Never leave `Enabled=true` after a partial teardown.** That is why
LC-2 clears the flag first (`:533`) rather than last.

**LC-15.** **Never retain a ship handle across mission boundaries.** CI-3.

**LC-16.** **Never put `#` comments in `data/tables/fs2rts-sct.tbm`.** The SCT
parser reads `optional_string("#Conditional Hooks")`, which skips whitespace only,
so prose before the marker makes it skip the whole block; inside the block a `#`
line is consumed as a *condition* and rejected, disabling the hook it precedes. The
reasoning therefore lives in Lua beside the table it explains
(`fs2rts_lifecycle.lua:491-501`).

## INVARIANTS

**LC-I1 — Elimination ordering.** Blue is checked **last** in `OnFrame`
(`:673` RED, `:674` GOLD, `:675` BLUE, then `:676` `EvaluateFactionVictory`).
*Algebraically:* if a single frame eliminates two factions, the second elimination's
report snapshot is taken before `BattleVictor` is set, so the surviving-or-eliminated
row is correct rather than reporting a mutual kill as a survival. Grounded in the
comment at `:667-672`; the ordering is the invariant.

**LC-I2 — Blue-victor gate.** `EvaluateFactionVictory` (`:676`) runs only when
`SetupActive` is false and `BattleVictor` is nil (`:666`). Hence: *at most one
`BattleVictor` transition per frame, and it is the last thing `OnFrame` does.*

**LC-I3 — Reset completeness.** `ResetState` (`fs2rts_factions.lua:866-887`) must
clear every table that `ReleaseObjectHandles` knows about, because `OnGameplayStart`
calls `ResetState` (`:458`) but **not** `ReleaseObjectHandles` — that only runs on
shutdown. *Algebraically:* for every name `N` in the wipe list at
`fs2rts_lifecycle.lua:581-586`, `ResetState` assigns `self[N] = {}`.
Verified for `AIStates`, `AIOrderState`, `StationBaseHull`, `StaticDefenseSignatures`,
`DyingStations`, `RTSWings`, `WingBySignature` (`:876-877`).

**LC-I4 — Mission-scoped evidence is never carried across a restart.**
`self.BeamRangeByClass=nil` (`fs2rts_factions.lua:883`), with the reason stated:
carrying learned beam reach across a restart is the `DyingStations` defect class
(`:880-882`).

**LC-I5 — Frame budget (algebraic).** Per-frame full-fleet walks must be zero, or
bounded by a cadence. The frame calls, in order (`:646-664`): economy, build queue,
enemy waves, AI production, stations, fleet services, move facings, reconcile,
strategic objectives, world-position audit, escalation announcement, default policy.
The cadence-governed ones: `UpdateAIProduction` samples the fleet cap on the think
cadence, not per frame (`fs2rts_ai_production.lua:421`), because advancing
`nextThink` inside the capped branch meant a capped faction re-walked the whole ship
list every frame for the rest of the match (`fs2rts_ai_production.lua:414-420`).

## Currently UNVERIFIED

- **LC-I1 (ordering).** `_Unverified._` No test asserts that a single frame
  eliminating two factions produces a correct report. `test_station.py` has no
  mutual-kill case. **Would verify it:** construct two factions with dead stations,
  call the elimination block in one frame, assert `PostBattleResult` shows both as
  eliminated and `BattleSummary` recorded both.
- **LC-I3 (reset completeness).** `_Partially verified._` Verified by reading the
  reset assignment list against the wipe list; no automated cross-check exists.
  **Would verify it:** a test that parses both lists out of the two files and
  asserts every wipe name is assigned in `ResetState`.
- **LC-4 (handle release).** `_Unverified as an absolute._` There is no test that
  asserts no signature-keyed table holding a handle is absent from the wipe list.
  **Would verify it:** the same cross-file check as LC-I3, run in reverse — scan
  every `self.<Name>[<signature>]` assignment in the mod and require `Name` to be
  in the wipe list.
- **LC-5 (transient states).** Verified indirectly: `test_station.py`
  `test_on_state_start_survives_a_nil_state` covers the nil case. The 16-entry list
  itself is unpinned.

## VIOLATIONS

None confirmed in this subsystem.

**Not a violation — checked and cleared:** `fs2rts_ai_planning.lua:912` still
initialises `damageDealt='unknown'` in the record constructor, but
`fs2rts_ai_planning.lua:935-936` overwrites both fields with resolved telemetry
totals before the record is emitted (`:1061`). The `'unknown'` initialiser is dead,
not live; a batch captured before `:935` existed is what produced the historical
`'unknown'` values. Recorded in [08-strategy-planning.md](08-strategy-planning.md)
as V-8.

**Not a violation — checked and cleared:** `combatantValue` was reported missing by
a peer agent. It is emitted at `fs2rts_ai_planning.lua:963` as an alias of
`replacementValue`. A batch predating that line is the explanation, not a defect.