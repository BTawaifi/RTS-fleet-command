# 06 — Orders, pilot possession and wing assignment

**Subsystems:** `core/data/scripts/fs2rts_orders.lua` (948 lines),
`fs2rts_pilot.lua` (671 lines), `fs2rts_player_wing.lua` (125 lines)
**Prefix:** `OR-`

There is **no** `fs2rts_wing.lua` in this tree. Wing state lives in
`fs2rts_selection.lua` (`RegisterLogicalWing` is in `fs2rts_factions.lua:607`) and the
native-wing bridge in `fs2rts_player_wing.lua`. Verified by Glob over all 34 `.lua`
files.

## PROMISES

**OR-1.** A player order is recorded once and is the authority until cleared.
`SetUserOrder` (`fs2rts_orders.lua:36`) writes `UserOrders[sig]` (`:39`) and clears
both `PolicyApplied[sig]` (`:49`) and `AIOrderState[sig]` (`:52`). Rationale at
`:50-51`: a leftover Auto Mode objective lets `OnShipDeath` `clearOrders()` a ship
whose old target died, silently wiping the player's order.

**OR-2.** A fresh manual order genuinely frees the ship from service. `SetUserOrder`
drops the service record's cached slot and the record itself when the new order is not
`'service'` (`fs2rts_orders.lua:43-48`). Rationale: dropping only the record left the
service waypoint and its cached slot live, so the ship kept drifting back to the
station after the player re-tasked it.

**OR-3.** Releasing a ship hands it to whoever owns it by default.
`ReturnToDefaultControl` (`fs2rts_orders.lua:56`) clears first when in Auto Mode
(`:64`) so a stale goal such as `PLAY_DEAD` cannot linger, because
`AssignAIStrategicOrder` can decline when there is no primary target yet (`:62-63`).

**OR-4.** An attack on a wing member retargets the wing. `HandleAttackWingTargetDeath`
(`fs2rts_orders.lua:95`) resolves a replacement from the surviving members
(`:88-91`), and only drops the order when the owner itself is gone (`:104-106`).

**OR-5.** A bomber's single-target goal ends when the target dies.
`EngageShip` records `EngageTargets[sig]` (`fs2rts_orders.lua:29`) specifically so
`OnShipDeath` can re-engage instead of leaving the bomber idle (`:27-28`); the record
is cleared at `:23` on every re-engage.

**OR-6.** A lost move order is re-issued. `ReconcileMoveOrders`
(`fs2rts_orders.lua:679`) scans `UserOrders` every 2 s (`:682`) and reissues a `move`
order whose `ORDER_WAYPOINTS_ONCE` goal is no longer intact (`:706-709`). Rationale at
`:669-678`: a hit makes `ai_ship_hit` fall through into `maybe_set_dynamic_chase`,
switching to `AIM_CHASE` with a 20 s resume, and nothing in the scripting API can
suppress it, so the order evaporated and `UpdateDefaultPolicy` skips anything carrying
a `UserOrder`.

**OR-7.** An attack order on a hull that is no longer hostile is dropped, not
re-issued. `ReissueUserOrder` clears the order and returns to default control
(`fs2rts_orders.lua:652-656`).

**OR-8.** Pilot possession is refused for a ship that is not a movable friendly
hull. `IsPilotableShip` (`fs2rts_pilot.lua:44`) rejects non-friendly (`:45`), all
four command stations and the observer (`:46-47`), and static defenses (`:48`).
`StartPilotMode` additionally requires `GameStatus=="ACTIVE"` (`:348`) and a live
non-dying ship (`:349`).

**OR-9.** Possessing a capital exposes its turret groups **structurally**, not by class
name. `IsPilotableCapital` (`fs2rts_pilot.lua:57`) scans subsystems for a turret
carrying primary or secondary banks. Rationale at `:52-56`: possession was gated on
`ClassPrefixes`/`CapitalClassPrefixes`, which silently excluded every hull it did not
name, including user-made and mission-specific classes.

**OR-10.** Entering pilot mode parks the prior state and stops the AI competing.
`StartPilotMode` saves `PilotPreviousUserOrder` (`fs2rts_pilot.lua:362`), sets a
`{kind="pilot"}` marker (`:363`), clears `AIOrderState` (`:367`) so `OnShipDeath`
cannot strip `PLAY_DEAD` mid-flight (`:365-366`), and issues `ORDER_PLAY_DEAD` (`:381`).

**OR-11.** The observer proxy's own weapons stay locked while possessed
(`fs2rts_pilot.lua:391`). It is `Player_obj`, so the engine would fire its mirrored
banks from the trigger as well, doubling every shot from inside the hull (`:387-390`).

**OR-12.** The possessed hull retains full arsenal access. `EnableFullArsenal`
(`fs2rts_factions.lua:209`) clears `TurretLocked` and sets `BeamFree` on every
subsystem, each under `pcall` (`:221-224`), because retail capitals inherit a
beam-locked turret list.

**OR-13.** The pilot death view is a fixed **real**-time delay.
`PendingPilotEjectRemaining` decrements by `ba.getRealFrametime()` (`fs2rts_pilot.lua:570`,
`:582`), not mission time, so it stays five actual seconds at any time compression
(`:567-569`). Config: `DeathViewSeconds = 5` (`fs2rts_config.lua:255`).

**OR-14.** Native wing attachment is refused wholesale rather than partially.
`JoinPilotNativeWing` (`fs2rts_player_wing.lua:6`) returns `nil` immediately when
`Config.Pilot.NativeWingExtensions==false` (`:7`), which is the shipped default
(`fs2rts_config.lua:252`). Every native call is `pcall`-wrapped (`:15`, `:28`, `:44`,
`:67`), and a mid-loop failure tears down and returns the error (`:56-58`).

**OR-15.** Native wing teardown restores each member's prior order.
`LeavePilotNativeWing` (`fs2rts_player_wing.lua:82`) walks members in reverse (`:86`),
restores `entry.order` unless it was `'service'` (`:100-101`), clears `PolicyApplied`
and `AIOrderState` (`:105-106`), and reissues (`:108`).

**OR-16.** Native wing attachment is all-or-nothing unless the engine itself already
accepted some members. `fs2rts_player_wing.lua:46-59`: if `addPlayerWingMember`
returns false after some members are already in, the partial state is published,
every applied order is set, then `LeavePilotNativeWing` is called and the failure is
returned.

**OR-17.** Button hit-testing is deterministic and topmost-first. `orderedButtonKeys`
(`fs2rts_station.lua:1097`) sorts the rect table with an explicit rank
(`:1100-1108`) rather than iterating `pairs()`, whose order is undefined in Lua. The
rationale at `:1091-1096`: both the click handler and the tooltip walked the same
`pairs()` order and returned on the first containing rect, so overlapping rects made
the click and the tooltip describe different buttons.

## REFUSES

**OR-18.** `SetUserOrder` refuses a non-movable friendly (`fs2rts_orders.lua:37`) and
a nil order.

**OR-19.** `HoldShip` refuses a non-friendly (`:10`). `EngageShip` refuses an invalid
ship (`:18`) and any ship in service (`:19`). `ClearUserOrder` refuses an invalid ship
(`:72`). `ReturnToDefaultControl` refuses an invalid ship (`:57`), a servicing ship
(`:58`), a static defense (`:59`).

**OR-20.** `ReissueUserOrder` refuses a non-friendly ship, a nil order
(`fs2rts_orders.lua:631`) and a ship in service (`:632`). An order it cannot satisfy
falls through to clear + default control (`:664-666`).

**OR-21.** A `'wing'` order is refused outright when no pilot is possessed: the branch
falls through (`:642-647`) to the clear-and-release path (`:664`).

**OR-22.** `ReconcileMoveOrders` refuses entirely while setup, post-battle or pilot
mode is active (`:680`).

**OR-23.** `JoinPilotNativeWing` refuses when the logical wing is missing (`:12`),
the pilot or observer is not alive (`:13`), the native wing API is unavailable
(`:16-16`, `:20`), a wingmate already belongs to another native wing (`:33-35`), or
there are no available wingmates (`:40`).

**OR-24.** `LeavePilotNativeWing` refuses to report success while any member is still
attached (`:122`), so a partial cleanup is visible to the caller.

## MUST NEVER

**OR-25.** **Never let a manual order leak to FSO.** `ShouldOverrideKey`
(`fs2rts_input.lua:1418`) must swallow every bound key; a key bound but not swallowed
fires twice (`core/README.md:127`).

**OR-26.** **Never clear a player order as a side effect of the AI's own bookkeeping.**
This is OR-1's whole point. `OnShipDeath`'s `clearOrders()` sweep over
`AIOrderState`-targeting ships is exactly what OR-1's `AIOrderState[sig]=nil` defuses.

**OR-27.** **Never issue an attack on a friendly.** `AreEnemies`
(`fs2rts_factions.lua:79`) requires different teams (`:85`), different factions
(`:86-87`) and `Team:attacks` (`:88`). Rationale at `:82-84`: FSO's IFF data is global
and another mod can extend it, so the RTS boundary must be explicit or a same-faction
ship could become an AI attack target.

**OR-28.** **Never inspect ship-only properties on a weapon or beam handle**, not even
inside `pcall` — an unattended engine property error throws a native exception
(`core/README.md:105`). `ResolveKillRewardShip` (`fs2rts_lifecycle.lua:701`) branches
on `getBreedName()` first and reads only `Parent`/`ParentShip` (`:705-706`).

**OR-29.** **Never leave a native wing member without an order on teardown.** OR-15's
guarantee; `:107-110` reissues or releases explicitly.

## INVARIANTS

**OR-I1 — One order source per ship.**
*Algebraically:* for any signature `s`, at most one of these is authoritative:
`UserOrders[s]`, `AIOrderState[s]`, `FleetServices[s]` as a service state.
`SetUserOrder` writes `UserOrders[s]` and clears `AIOrderState[s]`
(`fs2rts_orders.lua:39`, `:52`); `BeginFleetService` clears `AIOrderState[s]`
(`fs2rts_service.lua:124`) and stashes any `UserOrders[s]` on the service record
(`:122-123`). So `UserOrders[s]` may coexist with `FleetServices[s]` — that is the
designed parked-order case — but never with `AIOrderState[s]`.

**OR-I2 — Service records are invisible to order issuance.**
`FleetServices[s] ~= nil` ⟹ `EngageShip`, `ReturnToDefaultControl` and
`ReissueUserOrder` all early-return (`fs2rts_orders.lua:19`, `:58`, `:632`).
*Algebraically:* `ServiceFleetShip` is the only path that writes native orders to a
servicing hull.

**OR-I3 — Selection implies an order only if asked.** `SelectLogicalWing` selects all
live members without issuing anything (`fs2rts_factions.lua:627-636`);
`SelectWingForShip` likewise (`fs2rts_selection.lua:30-40`).

**OR-I4 — Waypoint handles are pooled and released.**
`GetOrCreateMoveWaypoint` (`fs2rts_orders.lua:419`) draws from `FreeMoveWaypoints`;
`ReleaseMoveWaypoint` (`:444`) returns it. Both pooled tables are wiped at shutdown
(`fs2rts_lifecycle.lua:589-590`) because FSO exposes no Lua call to delete a waypoint
list (`:587-588`).

**OR-I5 — Formation shapes are distinct and total.**
`GetFormationTypes` (`fs2rts_orders.lua:246`) enumerates; `BuildSafeFormationDestinations`
(`:341`) computes per-shape slot geometry. `core/README.md:127` states a test pins
"each formation shape produces distinct slot geometry". `_Unverified by me._`

**OR-I6 — Possession is single-valued.**
`self.PossessedSignature` is set at exactly one site (`fs2rts_pilot.lua:359`) and
cleared at `ExitPilotMode` (`:437` guard `:438`) and by `Shutdown`
(`fs2rts_lifecycle.lua:540`, `:543`). *Algebraically:* at most one ship is possessed
at a time.

**OR-I7 — Pilot control does not compete with the AI.**
`Order_PLAY_DEAD` is issued at possession (`fs2rts_pilot.lua:381`) and
`AIOrderState[signature] = nil` at `:367`; `UpdatePilotMode` issues
`doManeuver` with duration `1` (never expire, `:641-652`) and the fire calls at
`:658`, `:663`. Rationale at `:638-640`: a finite hold is a game-time timestamp and
lapsed before the next frame under compression or a hitch, letting `PLAY_DEAD` take
over and freezing the craft.

**OR-I8 — Wing membership is the union of live members.**
`GetLogicalWing` (`fs2rts_factions.lua:621`) resolves via `WingBySignature[sig]`
(`:623`); `RegisterLogicalWing` (`:607`) writes both `wing.signatures` and
`WingBySignature[sig]` (`:615`). *Algebraically:*
`sig ∈ WingBySignature ⟹ sig ∈ RTSWings[WingBySignature[sig]].signatures`.
Stale entries are harmless because every read resolves the signature to a live ship
first (`:631-633`).

**OR-I9 — Native wing is off by default.**
`Config.Pilot.NativeWingExtensions == false` (`fs2rts_config.lua:252`), checked at
`fs2rts_player_wing.lua:7`. *Algebraically:* in the shipped configuration,
`JoinPilotNativeWing` always returns nil and `LeavePilotNativeWing` always returns true
(`:84`).

## Currently UNVERIFIED

- **OR-I5 (formation geometry distinctness).** `_Claimed by core/README.md:127, not run
  by me._`
- **OR-I1 (one order source).** `_Unverified._` No test asserts the mutual exclusion.
  **Would verify it:** issue a manual order to an AI-controlled Blue ship in Auto Mode
  and assert `AIOrderState[sig]==nil`; start service and assert the same.
- **OR-I6 (single possession).** `_Unverified._` **Would verify it:** attempt to
  possess a second ship mid-possession and assert the first is unaffected.
- **OR-I9 (native wing off).** `_Partially verified._` `core/README.md:36` states the
  extension "is disabled and is not a mod dependency", consistent with the config.
- **OR-2 (service release on manual order).** `_Unverified as a side effect._** Tests
  assert service completes and restores the order (`test_service.py`), but not that
  issuing a *new* manual order mid-return drops the service record. **Would verify it:**
  begin service, `SetUserOrder` with kind `'move'`, assert `FleetServices[sig]==nil`
  and `s.destination==nil` was cleared.
- **OR-16 (partial native wing rollback).** `_Unverified and unreachable in the shipped
  config._** The path at `fs2rts_player_wing.lua:46-59` cannot execute with
  `NativeWingExtensions=false`, so it is dead code in the shipped build. That is
  deliberate (stock-FSO compatibility), but it means the rollback logic is untested
  and untestable without a flag flip.

## VIOLATIONS

None confirmed.

**Checked and cleared:** the reported `RETICLE_COLOR_SELECTED` scope crash is fixed.
`fs2rts_hud.lua:878` declares the constant; its first use is in
`DrawTacticalMap` at `:881`, i.e. **after** the declaration. `lua_scope_order_check.py`
reports 0 findings on the current tree (per the agent that built it). OR documents do
not cover HUD; see [07-hud-input.md](07-hud-input.md).