# Subsystem Contracts

Contracts for the FreeSpace RTS: Fleet Command mod, written **before** the fix.

## Why these exist

Every AI/HUD/service defect in this project was found by **differential review** —
diff against a baseline, read the code, reason about intent. That finds code which
*differs* from what was intended. It cannot find code that was **never written**: a
missing guard, an unenforced precondition, an untested path. It also cannot find
behaviour that was **assumed rather than observed**.

Two shipped defects are the proof:

- **`RETICLE_COLOR_SELECTED`** was declared `local` 147 lines *below* its first use.
  Lua `local` scope does not extend backwards, so every use resolved to a nil
  global and crashed the live game. 370 tests passed and the static
  undefined-global check passed, because both asserted the name existed *somewhere
  in the file*; none asserted it was in scope *at the use site*.
- **`savingSince` cleared after every purchase** meant the AI's save window never
  aged out. The producer built **zero** capital/heavy/juggernaut ships in 4 of 4
  matches while every metric-based tool reported a mixed result. No diff found it:
  the clearing looked deliberate, and its comment said so.

The method change: **write the contract down first**, so every later step is
"does the code satisfy sentence N" rather than "does this look right".

## How to use these

### Writing a contract

1. Pick a subsystem — one Lua module, or one coherent seam across modules.
2. Write the contract **before** reading the code and before the fix. Read enough
   to name the file and its entry points; do not read the implementation looking
   for bugs, that is the old method and it biases the contract toward what the
   code does.
3. Number every sentence. `SP-3`, `SV-7`, `PA-2`. **Tests cite sentence numbers**,
   never line numbers — line numbers rot, sentence numbers are the contract.
4. Ground every sentence in code you actually opened, as `file:line`.
5. Where a sentence is an **aspiration**, say so in the sentence itself:
   `_Aspiration._` If you cannot cite current behaviour, you are describing a wish.
   A contract that lies about current state is worse than no contract.
6. Anything the current code violates goes in the file's **VIOLATIONS** section,
   never silently rewritten as intended behaviour.

### Adding a subsystem

Create `docs/contracts/<NN>-<name>.md` using the same four headings:

| Heading | Contains |
| --- | --- |
| **PROMISES** | Guarantees a caller may rely on. Sentence-numbered. |
| **REFUSES** | Inputs rejected, and the exact site that rejects them. |
| **MUST NEVER** | To a player-authored mission, to shipped balance, to the frame budget. |
| **INVARIANTS** | Must hold at all times. Stated algebraically. Marked verified / unverified. |
| **VIOLATIONS** | Contract sentences the current code breaks, with evidence. |

Add a row to the index below. If the file you want does not exist, **say so and
skip it** — do not invent a subsystem.

### The rule

> **A contract is written BEFORE the fix, and the tests assert sentence numbers.**

A test that asserts a line number, a literal string, or a whole-file shape is a
differential test: it goes red when the code differs from the last time someone
touched it, and green when the code is wrong in a new way. That is exactly how a
nil-scope crash and a livelock both shipped through a fully green suite.

A sentence-numbered test asserts *the guarantee*, not the *implementation*. It
stays green through a refactor and goes red when the promise breaks.

Prefer this shape:

```python
def test_producer_window_ages_out_into_fallback(self):
    # PA-4: a save window MUST age out into savingFallback once
    # savingSeconds elapses, even if every intervening think fielded
    # the cheap alongside hull. Previously savingSince was cleared on
    # every purchase, so the window restarted forever.
```

…over asserting a flag's default value, because a default is an implementation
decision that the sentence does not constrain.

### Red/blue discipline

A test that cannot fail is not a test. For every invariant marked verified, kill-
check it: revert the guard, confirm red, restore, confirm green. Report any test
you could not make red.

## Index

| File | Subsystem | Primary module |
| --- | --- | --- |
| [01-lifecycle.md](01-lifecycle.md) | Lifecycle, shutdown, frame budget, teardown | `fs2rts_lifecycle.lua` |
| [02-spawning.md](02-spawning.md) | Ship spawning and placement | `fs2rts_factions.lua`, `fs2rts_production.lua` |
| [03-ai-production.md](03-ai-production.md) | Fleet production / AI producer | `fs2rts_ai_production.lua` |
| [04-station-economy.md](04-station-economy.md) | Station AI and CP economy | `fs2rts_station.lua` |
| [05-fleet-service.md](05-fleet-service.md) | Fleet service / rearm | `fs2rts_service.lua` |
| [06-orders-pilot-wing.md](06-orders-pilot-wing.md) | Orders, pilot possession, wing assignment | `fs2rts_orders.lua`, `fs2rts_pilot.lua`, `fs2rts_player_wing.lua` |
| [07-hud-input.md](07-hud-input.md) | HUD and input | `fs2rts_hud.lua`, `fs2rts_input.lua` |
| [08-strategy-planning.md](08-strategy-planning.md) | AI strategy, planning, telemetry semantics | `fs2rts_strategy.lua`, `fs2rts_ai_planning.lua` |

### Named in the brief but absent from the tree

Verified by Glob over all 34 `.lua` files under `core/data/scripts` and
`core/tools`. **Not documented, not invented:**

- **`fs2rts_spawn.lua`** — does not exist. Spawning lives in
  `fs2rts_factions.lua` (`GetSpawnFrame`) and `fs2rts_production.lua`
  (`SpawnFriendly`, `SpawnFactionUnit`, `SpawnConfiguredWave`). Covered by
  [02-spawning.md](02-spawning.md).
- **`fs2rts_wing.lua`** — does not exist. Wing state is in `fs2rts_factions.lua`
  (`RegisterLogicalWing`, `GetLogicalWing`), selection in `fs2rts_selection.lua`,
  and the native-wing bridge in `fs2rts_player_wing.lua`. Covered by
  [06-orders-pilot-wing.md](06-orders-pilot-wing.md).

### A real gap, stated rather than filled

**`fs2rts_camera.lua` (430 lines, 21 `RTS:` methods) is not covered by this set.** It
holds the tactical camera, chase mode, follow mode, free cam and the battle director.
The brief's subsystem list did not name it, and it surfaced only through a defect
(`Config.BattleCam`, recorded in [07-hud-input.md](07-hud-input.md) V-1). Writing its
contract requires reading the file in full, which was out of scope for this pass.
Stated so the next reader does not assume the camera is documented.

## Cross-cutting invariants

These hold across subsystems and are the ones most likely to break silently. Each
is stated once, here, and repeated only where a subsystem is the enforcement site.

**CI-1 — CP conservation.** Every command-point decrease increases
`AIEconomyFlow[kind].productionSpend` by exactly the same amount, and every
increase increases `income`, `bounty` or `refund`. *Enforcement site:* all CP
mutation routes through `RTS:SpendFactionCP` (`fs2rts_station.lua:114`),
`RTS:RefundFactionCP` (`:122`) or the explicit `RecordAIEconomyFlow` call
immediately following a direct `CommandPoints` write.

**CI-2 — No write without a flow record.** `_Unverified against future edits._` A
new CP sink that writes `self.CommandPoints` or `AIStates[kind].cp` directly
without a paired `RecordAIEconomyFlow` call breaks CI-1 silently. There is no
static check for this. It would be detected only by a batch reconciliation gap.

**CI-3 — Signature recycling safety.** Any table keyed by ship signature that
stores a handle or per-hull state must either be wiped at shutdown
(`fs2rts_lifecycle.lua:575`) or validate that the resolved object is still the
same hull (`O[sig]==ship` in `RTS:ProjectShip`, `fs2rts_input.lua:106`;
`SentryRecordMatches` in `fs2rts_station.lua`).

**CI-4 — Scope-before-use.** A name read in a function must be in lexical scope at
that line. Enforced by `core/tools/lua_scope_order_check.py`, which walks the
block stack — `undefined_global_check.py` cannot catch a name declared below its
use.

**CI-5 — One definition per concept.** Two fields, tools or configs that mean the
same word must agree. See the two-definitions-of-idle violation in
[08-strategy-planning.md](08-strategy-planning.md).

## Contradictions found in existing project docs

`core/README.md` is the project's public description and is treated as authoritative
by readers. These statements in it are **false against the current tree**. All were
verified this session by reading the cited config, not inferred.

**D-1 — `core/README.md:75-85`: every sentry CP price is wrong.** The table lists
300 / 700 / 1200 / 2400 (BLUE), 300 / 700 (GOLD) and 300 / 650 / 1600 (RED).
`fs2rts_config.lua:550-571` ships **375 / 875 / 1500 / 3000** (BLUE),
**375 / 875** (GOLD, plus Sotar 1500 and Sekhem 3000 that the table omits entirely)
and **375 / 825 / 2000** (RED). Hull values match; only the CP column diverges, and
which side is stale is not determinable from this tree alone — but since the table is
what a player reads and the config is what charges, **the running game charges more
than the documentation says on every sentry.** This matters for balance work: the T1
sentry hurdle is 375 CP, not 300, which is part of why `StationReserveCap` reasoning
has to use 375 (see [04-station-economy.md](04-station-economy.md) V-2).

**D-2 — `core/README.md:115` references a tool that does not exist.** It documents
`python core/tools/plot_ai_maps.py` for "the location heat map, the behavioural heat
map by mission, the group self-coordination matrix and the cohesion time series". A
Glob for `**/plot_ai_maps.py` across the drive root returns nothing. The four analyses
it describes are the ones `core/tools/ai_timeline.py` and `analyze_batch.py` partially
cover, but no file by that name exists.

**D-3 — `core/README.md:1` says `1.4.0`; `mod.json` says `1.4.1`.** Cosmetic, but a
reader diffing a 1.4.1 tree against the 1.4.0 docs will trust the wrong line numbers.

**D-4 — `core/README.md:99` describes saving-window behaviour the shipped default does
not have.** It states "The AI's savings window does not restart when its composition
need changes", which is true, but omits that the window *also* restarts on every
purchase in the shipped default — the livelock. See
[03-ai-production.md](03-ai-production.md) V-1.

**D-5 — Two config comments contradict their own values.**
`fs2rts_config.lua:752` reads "On by default: false = the livelock, for A/B" on a line
whose value is `false`; "on by default" and "false" cannot both hold.
`fs2rts_config.lua:768` reads "On by default: false = current shipped behaviour" on a
line whose value is `true`. Both comments were written when the intent was one thing
and the value was set to the other.

## Reading the VIOLATIONS sections

A violation is a **measured or traced** divergence, not a suspicion. Each entry
carries `file:line`, the sentence ID it breaks, and the evidence. Where the
evidence is a comment or a comment's own cited batch rather than something I ran
this session, it says so — a peer agent's batch numbers are evidence, but they are
not something I independently reproduced, and this file does not claim they are.