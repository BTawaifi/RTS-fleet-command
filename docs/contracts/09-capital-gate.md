# 09 — Capital-aware station gate

**Subsystem:** `core/data/scripts/fs2rts_station.lua` (`RTS:UpdateStationAI`)
**Config:** `Config.Station.AI.CapitalAwareInvestment`,
`Config.Station.AI.CapitalAwareInvestmentMaxSeconds`
**Prefix:** `CG-`

Companion to [04-station-economy.md](04-station-economy.md). It addresses a defect
that document recorded as V-2 without fixing: `StationReserveCap` clips the fleet
producer's `productionReserve` away, so the reserve documented as protecting the
saving goal protects nothing.

## The defect

`RTS:UpdateStationAI` folds the producer's saving target into one number and then
throws most of it away:

```lua
reserve = math.max(reserve, production.productionReserve or 0)   -- the whole bankTarget
...
stationReserve = math.min(reserve, StationReserveCap)             -- clipped to 1500
return self:GetFactionCP(kind) >= cost + stationReserve
```

`productionReserve` **is** `decision.bankTarget` — the full price of the role
package being saved for (`fs2rts_ai_production.lua:181`). With
`StationReserveCap = 1500`, a 600 s capital save window therefore leaves the base
free to buy any upgrade at `cp >= cost + 1500`: roughly 75 purchases inside the
window, against a bank climbing 180-230 CP per think.

Measured per faction per 3000 s match: station upgrades 59,100-77,450 CP (29-38%
of income), sentries 6,750-27,500 CP (3-13%), fleet hulls 95,425-153,750 CP. The
bank peaked at 4,056-5,859 CP against capital targets of 7,700-31,275, and
capital/heavy/juggernaut production was 0 in 4 of 4 headless matches. The upgrade
tree costs 21,225 CP in total (`fs2rts_config.lua:576-587`), about 47% of a
faction's lifetime income, and it was being paid out of the capital bank.

**CG-1.** This is a bug, not a balance choice: the value is folded in, commented
as existing for this purpose, and then discarded by the cap. The two are not in
conflict — see CG-3.

## The gate

Behind `Station.AI.CapitalAwareInvestment`, **default false**. With the flag off
no line of the block executes and the station AI is byte-for-byte as it shipped
(pinned by `test_capital_gate_off_keeps_the_shipped_drain`).

Base **upgrades** are deferred while all of these hold:

1. the producer could buy something now — `AIStates[kind]` exists, nothing
   queued, under fleet cap (the same condition the reserve fold uses, hoisted);
2. `production.savingRole` is set — the producer has opened a save window;
3. `production.productionReserve > GetFactionCP(kind)` — the bank cannot afford
   the role yet;
4. the deferral is younger than the escape bound (CG-4).

The gate sits in `tryUpgrade`, which is the single chokepoint for all three
upgrade paths (damaged-station armour, the opening LOGISTICS L1, and the
`logistics/defenses/command/armor` priority loop). It is deliberately **not**
inside `affordable()`, which stays shared with the sentry scan.

## Position on sentries: not deferred

Sentries are only 3-13% of income against the upgrade tree's 29-38%, so stopping
the tree is where the bank is actually going. More importantly, while the producer
is in a save window it fields **nothing** (`AI.FieldCheapHullWhileSaving` ships
false), so the sentry ring is the base's only defence for the length of that
window. The batch that took sentry builds from 67 to 7 per 4 matches cost 220-270
unit losses; repeating that trade to fund a capital is a design decision that
needs its own A/B, not a side effect of fixing the reserve.

`StationReserveCap` is left exactly as it is. It is load-bearing for sentry
recovery and this change does not weaken it.

## Escapes

**CG-2 — Affordability.** Condition 3 lifts the moment the bank can pay for the
role, which is the same tick the producer buys the hull. Holding the base back
after that buys nothing.

**CG-3 — The producer stops saving.** `savingRole` is cleared on every purchase
and on a rising emergency (`fs2rts_ai_production.lua:241`, `:327`), and
`productionReserve` drops to 0 on an emergency. A producer that is not saving
never holds the base back.

**CG-4 — A bound on each contiguous deferral.** `CapitalAwareInvestmentMaxSeconds`
defaults to `max(MaxProductionSavingSeconds, CapitalSavingSeconds,
HeavyCapitalSavingSeconds, JuggernautSavingSeconds)` = 900 at tier 4: the
producer's own longest declared save window. The base therefore never waits longer
than the fleet that is outbidding it. A missing or zero bound fails **open** (no
deferral at all), so an emptied config cannot freeze the base.

It cannot hang because the clock is local (`state.capitalGateSince`), monotonic,
and reset **only** when the condition stops holding — not on each deferred think.
A flickering condition cannot extend the deferral; it can only end it and start a
fresh, separately bounded one.

The `Limit` is not a budget for the match: worst case at tier 4 is 900 s of held
upgrades per save window, and each window ends in a purchase or an expiry.

## Verification

| Claim | Test | Mutation |
|---|---|---|
| ships off | `test_capital_aware_investment_defaults_off` | `CapitalAwareInvestment` default flipped → **RED** |
| off == shipped drain | `test_capital_gate_off_keeps_the_shipped_drain` | consumer removed → GREEN (control) |
| upgrades deferred | `test_capital_gate_defers_upgrades_while_the_fleet_saves` | consumer removed → **RED** |
| sentries still built | `test_capital_gate_does_not_starve_the_defence_ring` | — |
| affordability escape | `test_capital_gate_releases_once_the_bank_can_afford_the_role` | bound removed → GREEN (by construction) |
| producer-idle escape | `test_capital_gate_releases_when_the_producer_stops_saving` | — |
| bounded, fail-open | `test_capital_gate_deferral_is_bounded` | bound removed → **RED** |

Registered in `killcheck.py` as three guards:
`station_capital_aware_investment_gate` (consumer), 
`station_capital_aware_investment_default` (the shipped default),
`station_capital_gate_deferral_bound` (the escape). All three report **KILLED**.

## Unverified

- **Balance.** Nothing here has been run in the engine. The deferral changes when
  upgrades are bought relative to income; only an A/B batch can say whether
  capital production actually rises.
- **The bound's value.** 900 s is derived, not measured. A faction whose income
  cannot reach even the cheapest capital target inside 900 s will defer every
  window and then buy an upgrade anyway, spending nothing and gaining nothing.
  `AI.BoundBankTarget` is the knob that addresses that case, and it ships off.
- **Interaction with `StationReserveCap`.** Untested below its 1500 floor — see
  04-station-economy.md V-2, which this change does not resolve.
