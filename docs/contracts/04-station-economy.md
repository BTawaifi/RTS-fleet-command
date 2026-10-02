# 04 — Station AI and CP economy

**Subsystem:** `core/data/scripts/fs2rts_station.lua` (1393 lines)
**Config:** `Config.Station.*` (`fs2rts_config.lua:534-663`), `Config.Economy.*` (`:359-365`)
**Prefix:** `ST-`

## PROMISES

**ST-1.** **All CP mutation flows through named chokepoints.**
`SpendFactionCP` (`fs2rts_station.lua:114`) is the single deduct path: it refuses on
insufficient funds (`:115`), deducts from the right pool (`:116-117`) and records the
flow (`:118`). `RefundFactionCP` (`:122`) is the single credit path (`:125`).

**ST-2.** A faction's CP pool is readable in one place: `GetFactionCP` (`:108`),
which returns the player's pool for BLUE (`:109`) and `AIStates[kind].cp` otherwise
(`:110-111`), defaulting to 0 rather than nil.

**ST-3.** Every purchase states its refusal reason. `GetUpgradeOffer` (`:132`) returns
`(nil, reason)` or `(offer, reason)` from `{DESTROYED, MAX, BUSY, TIER, CP}`
(`:133`, `:135`, `:139-141`); `BuyUpgrade` maps them to player status text (`:150-151`).

**ST-4.** Upgrades are cumulative and one-at-a-time. `state.upgrade ~= nil` blocks a
second purchase (`:139`); `ApplyUpgrade` (`:164`) applies the *delta* between the new
and old multiplier for armour (`:168-169`), not the absolute value.

**ST-5.** Armour upgrades add capacity without healing. `HitpointsMax` scales by the
ratio; `HitpointsLeft` is clamped down if it exceeded the new max (`:174-175`), and
never scaled up. Rationale at `:169-173`: scaling `HitpointsLeft` by the same ratio
was a free repair proportional to existing damage, which the absolute `scarHull`
damage cap made worse over a long fight.

**ST-6.** The defence fire-rate boost is applied at most once per hull.
`ApplyDefenseFireRate` (`:186`) guards on `DefenseRateBoosted[sig]` **and**
`SentryRecordMatches(sig, ship)` (`:194`), because the mutation is *not* idempotent —
it multiplies `rof_scaler` (`:213`), so a false positive is permanent.

**ST-7.** A non-positive `FireRateMultiplier` is treated as "no stated rate" and the
multiplier is applied to 1.0 (`:211-212`). Rationale: `0` is the engine's
`$ROF: +Use firingpoints` sentinel (`ship.cpp:5564-5567`), so multiplying it wrote 0
back and the boost silently did nothing.

**ST-8.** The station AI preserves the cost of a mobile production package before
spending on base infrastructure. `reserve` starts at `ReserveCP` (`:947`), is raised
to `fleetReserve` (`:957`) and to `production.productionReserve` (`:960`).

**ST-9.** `fleetReserve` is the cheapest unlocked full roster package: the minimum
`GetPurchaseEstimate` cost over unlocked entries, where fighter/bomber entries are
priced as a full `StrikeWingSize` wing (`:950-955`).

**ST-10.** Base investment is capped independently of the fleet reserve.
`stationReserve = min(reserve, StationReserveCap)` (`:971`), so a large
`productionReserve` cannot require 14000 CP in the bank before a 375 CP sentry.

**ST-11.** Progression cannot be permanently denied. The opening-fleet gate opens
unconditionally after `OpeningFleetSeconds` (`:1009-1010`), so a faction that can
never hold 8 hulls alive is not locked out of sentries and COMMAND L3 forever.

**ST-12.** Sentry construction refunds on every failure. Station lost (`:496`),
invalid spot at completion (`:511`), spawn failure (`:511`), enemy contact
(`:500-506`).

**ST-13.** An orbital strike with no hostile inside its radius is refused
(`:742-746`), and the cost is charged before the strike is queued (`:748`) and carried
on the record (`:757`) so a later config edit cannot change a refund.

## REFUSES

**ST-14.** `PlaceSentry` (`:471`) refuses, in order: an invalid spot (`:472`), the
sentry cap (`:473`), an unmet tier for a *paid* sentry (`:474`), and insufficient CP
for a *paid* sentry (`:475`). Free sentries skip the tier and CP checks (`:474-475`).

**ST-15.** `QueueOrbitalStrike` (`:727`) refuses a non-BLUE faction, an unready
ability, a non-finite position (`:728`), an out-of-range target (`:730-733`), an empty
blast area (`:742`), and insufficient CP (`:748-752`).

**ST-16.** The station AI refuses to act before its think interval (`:940`).

**ST-17.** The station AI refuses to index `Config.Station.AI` bare. `aiCfg` is
hoisted with `or {}` at `:945`, and `:944` records that indexing it bare aborted the
think from two separate per-frame-reachable sites.

**ST-18.** Sentry radius arithmetic never touches a missing `ControlRadius`
(`:102`); the sentry radius is measured from the station's *model* radius (`:97`).

## MUST NEVER

**ST-19.** **Never spend the fleet producer's reserve in a way that stops base
investment.** PR-18's companion. The rationale is at `:963-970`: at tier 5 a 375 CP
sentry needed ~14200 CP in the bank, and headless batches showed every faction
building zero sentries for a whole match while the fleet sat on a capital bank.

**ST-20.** **Never spend on a defence ring before the opening fleet** (`:1009-1010`).

**ST-21.** **Never let the defence fire-rate boost compound.** See ST-6; a false
positive is permanent damage with no HUD indicator.

**ST-22.** **Never let a dying station be spun by its own explosion.** Destructive
stations are held still until they finish exploding; the signature is re-verified as
a real command station in its death roll (`fs2rts_lifecycle.lua:693`).

**ST-23.** **Never credit a bounty for friendly fire, self-kill, unknown killer or a
repeated death callback.** `core/README.md:69` states this; the killer resolution
requires a valid `Ship`, `Weapon` with a valid parent, or `Beam` with a valid
`ParentShip` (`fs2rts_lifecycle.lua:701-708`).

## INVARIANTS

**ST-I1 — CP conservation.** *Algebraically:* for every faction `k`,
`Σ productionSpend + Σ refunds - Σ income - Σ bounty == CommandPoints_now - CommandPoints_start`,
up to float accumulation. Enforcement: `SpendFactionCP` (`:118`) and
`RefundFactionCP` (`:125`) both record; every direct `self.CommandPoints` write in
the codebase is paired with an explicit `RecordAIEconomyFlow` on the same or adjacent
line. See CI-1, CI-2.

**ST-I2 — No negative CP.** `SpendFactionCP` refuses when
`GetFactionCP(kind) < amount` (`:115`), so `cp >= 0` is preserved for every deduct.
Direct deducts elsewhere (`fs2rts_production.lua:152`,
`fs2rts_ai_production.lua:429`) are guarded by a prior affordability check
(`fs2rts_production.lua:150`, `fs2rts_ai_production.lua:122`).

**ST-I3 — Refund equals what was charged.** Sentry refund is the full `job.cost`
(`:496`, `:511`); strike refund is the `strike.cost` captured at queue time (`:757`,
`:779`), guarded by `strike.refunded` so a second resolve cannot pay twice (`:776-777`).
Sentry *sell* is a fraction: `SellRefund=0.5` of the amount actually paid
(`fs2rts_config.lua:543`), and free platforms refund nothing
(`fs2rts_station.lua:464` stores `cost = free and 0`).

**ST-I4 — Upgrade effects are level-relative, not absolute.**
*Algebraically:* for armour, `HitpointsMax_after / HitpointsMax_before == ArmorHull[l+1] / ArmorHull[l]`
(`:168-174`), where `ArmorHull = {1.0, 1.2, 1.4, 1.6}` (`fs2rts_config.lua:589`).

**ST-I5 — Sentry capacity is shared by two tracks.**
`GetSentryCap` (`:76`) adds `CapBonus` for `defenses >= 1` (`:79`) **and** for
`command >= 2` (`:80`). Base `Cap=6`, `CapBonus=2` → 10 at max upgrades. Hence the
AI's upgrade priority at `:1045-1049` puts `defenses` before `command`, with the
reasoning at `:1040-1044`: both add exactly one `CapBonus`, but command L2 costs
1750 against defenses L1's 750, so asking for command first spent 2.3× the CP for an
identical benefit.

**ST-I6 — Reserve is a floor, not a budget.**
`stationReserve = min(reserve, StationReserveCap)` (`:971`) and
`affordable(cost) ⟺ cp >= cost + stationReserve` (`:972`).
*Algebraically:* base spend is permitted whenever
`cp - cost >= min(max(ReserveCP, fleetReserve, productionReserve), StationReserveCap)`.
**This is the invariant V-2 shows is partly inert.**

**ST-I7 — Repair ceiling never exceeds what the scars allow.**
`repairCeiling = max(0, HitpointsMax - scarHull)` (`:894`) and hull is clamped to it
(`:897`). `RecoverableDamageFraction = 0.60` (`fs2rts_config.lua:592`) sets the scar
at `:885`. *Algebraically:* `0 <= HitpointsLeft <= HitpointsMax - scarHull` always.

**ST-I8 — Out-of-combat repair is gated on armour level and quiet time.**
`armor >= 2` **and** `now - lastDamageAt >= ArmorRepairDelay` (30 s)
(`:595`, `fs2rts_config.lua:591`). The delay resets on any observed hull loss,
including sub-0.5 HP fractional damage (`fs2rts_station.lua:881-883` — native armour
can reduce a hit below 0.5 HP, `:879-880`; `core/README.md:101`).

## Currently UNVERIFIED

- **ST-I6 (reserve floor).** `_Verified only at cap == floor._`
  `test_station.py:1174` `test_ai_reserves_mobile_wing_and_limits_idle_defenses`
  pins the *observable* behaviour (at cp=1699 with 8 hulls: no sentry, no spend; at
  cp=10000: exactly 2 sentries, cp=9250). It does not isolate `StationReserveCap`,
  which is why the inertness in V-2 went unnoticed. **Would verify it:** set
  `StationReserveCap` to 0 and 1500 and 100000 with identical state, asserting the
  sentry decision differs.
- **ST-I7 (repair ceiling).** `_Unverified as an inequality._` Tests assert specific
  repair outcomes (`test_raid_damage_leaves_permanent_station_scars`, :200;
  `test_repair_does_not_backfill_upgrade_or_combat_delay`, :262), not the general
  bound. **Would verify it:** sweep `scarHull` and assert
  `HitpointsLeft <= HitpointsMax - scarHull` after every tick.
- **ST-I1 (CP conservation across a full match).** `_Unverified end-to-end._` A peer
  agent reconciled PRODUCTION + SENTRY_BUILD against `economy.flow.productionSpend`
  from real batches and found ~8–17k CP per match (~10%) unattributed, with two
  candidate explanations not yet distinguished (a CP path with no event, or the final
  interval lost because the emitter zeroes `AIEconomyFlow` at the last FACTION
  summary). I did not reproduce this. Note `BuyUpgrade` emits no event of its own
  (`fs2rts_ai_planning.lua:1040-1042` acknowledges this) — the emitter now publishes
  `upgradeSpend` and `upgradeLevels` (`:1056-1058`) so the question is answerable, but
  answering it needs a fresh batch.
- **ST-I4 (upgrade ratios).** `_Verified._` `test_station.py:1208`
  `test_each_upgrade_level_for_every_faction` asserts `HitpointsMax == hull*(1+level*.2)`
  per faction (`:1217`).
- **ST-I5 (sentry cap arithmetic).** `_Verified._` Same test asserts `GetSentryCap` per
  level (`:1216`).
- **ST-I3 (strike refund).** `_Unverified._` The `strike.refunded` guard (`:776-777`)
  has no test. **Would verify it:** resolve the same strike record twice and assert one
  refund.

## VIOLATIONS

### V-1 — ST-13 / ST-15: the orbital strike's refusal reasons are asymmetric

`fs2rts_station.lua:742-746` refuses a strike with zero enemies in the blast area and
calls `NoteAbilityRefusal`. But `NoteAbilityRefusal` is only called for Blue's
failures; for the out-of-range case (`:730-733`) and the CP case (`:748-752`) Blue gets
status text and everyone else gets nothing observable. `_Minor._` Recording because
ST-13 says "refuses a strike with no hostile inside its radius, and the cost is
charged before the strike is queued" — both true; the asymmetry is in *reporting*, not
in the guarantee. Not a break of ST-13. Left here for completeness rather than
promoted to a violation.

### V-2 — ST-10 and ST-I6: `StationReserveCap` is inert below the `fleetReserve` floor

`fs2rts_station.lua:947`, `:957`, `:960`, `:971`:

```lua
local reserve = aiCfg.ReserveCP or 0                 -- :947  = 400
...
if fleetReserve<math.huge then reserve=math.max(reserve,fleetReserve) end   -- :957
reserve=math.max(reserve,production.productionReserve or 0)                 -- :960
...
local stationReserve=math.min(reserve, math.max(0,tonumber(aiCfg.StationReserveCap) or 1500))  -- :971
```

`reserve = max(400, fleetReserve, productionReserve)` and `fleetReserve` is the
cheapest unlocked full roster package (ST-9). With `StrikeWingSize=4`
(`fs2rts_config.lua:363`) and the cheapest unlocked T1 fighter at 375 CP, a peer
agent measured `fleetReserve = 1500` — **exactly** `StationReserveCap`
(`fs2rts_config.lua:661`).

*Algebraically:* `min(max(400, 1500, productionReserve), 1500) == 1500` for **all**
`productionReserve >= 0`. The cap therefore clips `productionReserve` down to 1500 and
can **never** lower the floor below 1500. Lowering `StationReserveCap` below 1500
achieves nothing; `fleetReserve` re-imposes the floor. **Violates the intent of
ST-10** ("base investment is capped *independently* of the fleet reserve") — the cap
is not independent of it.

The config comment at `fs2rts_config.lua:648-661` now says exactly this ("PARTIAL
MITIGATION ONLY, and inert below ~1500"), so the *documentation* is honest; the
knob remains non-functional as a lever. The measured consequence from the peer
agent's batch: T1 sentry hurdle was `375 + 1500 = 1875` CP, i.e. 13× lower than the
uncapped value — so the cap did reduce the symptom without addressing the cause, which
was the producer livelock (see [03-ai-production.md](03-ai-production.md) V-1).

**Violates ST-10 and the independence clause of ST-I6.**