# Fleet Command: Philosophy Through Play

**Gameplay design and current implementation · source audit updated 13 October 2026**

**Scope:** RTS Fleet Command 1.4.5, current local working tree.

**Status:** The attachment, recovery, result-separation, player withdrawal, passage, defeated-AI extraction/rearguard and reporting ideas below now have an implementation. Focused tests and native probes verify selected boundaries; matchup balance and presentation still require broader playtesting.

## Final recommendation

**Scenario premise:** a configurable set of rival factions is locked into an escalating survival conflict after diplomatic, political or interspecies tensions break down. Each command pursues victory while protecting its people. Mirror factions can be opposing detachments or splinter commands. This is skirmish narrative context, not an implemented diplomacy system or a universal canonical historical war. The [revised introduction contract](AI_ACCEPTANCE_AND_INVARIANTS.md#scenario-premise-and-revised-introduction) requires the opening cinematic to establish the conflict, escalation, player responsibility and crew stakes. The six captions in `fs2rts_config.lua` now express those ideas; `CreateIntroScene()` provides a temporary native combat tableau. Viewer comprehension and the final presentation remain acceptance work.

Build the mod around **attachment, responsibility, and the limits of victory**. Give players recognizable fleets, practical opportunities to preserve them, and a clear distinction between defeating a command structure and destroying everyone who served it.

**Every life matters:** crewed ships and stations represent living people, not merely replacement costs. Player and AI decisions must give survival practical stakes without making avoidance the best strategy or overriding explicit orders. The [crew-survival acceptance conditions](AI_ACCEPTANCE_AND_INVARIANTS.md#crew-survival-lives-are-stakes) require avoidable-loss and necessary-risk controls, useful recovery, continuous ship histories, loss-aware reporting and survivor agency on both sides. These are long-match acceptance requirements; exact crew-casualty simulation and campaign population are not implemented claims.

Larger crewed ships generally put more lives at risk and deserve greater preservation weight, independently of their CP price or firepower. Verified crew information is preferred; labeled class/role estimates are acceptable as design inputs. Several smaller crews, escape feasibility, risk to covering ships and the mission can outweigh one larger hull. `GetCrewExposureEstimate()` uses four labeled role bands. `GetFleetServiceCrewPriority()` applies them to missing hull per service slot only for simultaneous admissions, preserving earlier arrivals and explicit orders. Wider crew-aware recovery protection, escort and sacrifice decisions are not implemented by that weighting.

**Courage also matters:** justified risk and sacrifice can protect other crews or secure a decisive objective. The user requested [ship/wing commendations](AI_ACCEPTANCE_AND_INVARIANTS.md#courage-justified-sacrifice-and-commendations) for verified gallantry, protection, preservation, distinguished service and necessary sacrifice. Survival can earn recognition; death alone cannot. `AwardFleetCitation()` implements two match-local ship citations: recovery followed by a confirmed hostile mobile kill, and removal of a pursuing threat followed by the beneficiary's confirmed escape. Lifetime records, history/report reasons and a Blue notification are present, without economic bonuses or invented crew casualties. Broader award categories and wing awards remain unimplemented.

## Divergences from the philosophy — 13 October source audit

Acceptance scenarios and completion rules for each gap are in [Player acceptance and definition of done](PLAYER_ACCEPTANCE.md#philosophy-criteria). Recovery/protection refers to station service and covering withdrawals; no separate rescue mechanic is implied.

This is a code-to-design comparison, not proof of balance or player attachment. The newer M4/M5/M6 boundaries in `AI_ACCEPTANCE_AND_INVARIANTS.md` take precedence over the older overview's completion language.

| Requirement | Current code | Remaining divergence or acceptance gap |
| --- | --- | --- |
| Recognizable identities and continuous histories | `RecordShipCreated`, `RecordWingHistory`, `RecordServiceFinish`, `RecordUnitFate`; Ships/Wings report pages | Ship history is implemented. Recognition during ordinary play and emotional attachment need player evidence; counters cannot establish them. |
| Survival decisions that account for people and necessary risk | Role estimates and simultaneous service priority; explicit ownership and committed-strike thresholds remain | Crew weight is absent from strategic target/escort selection and defeated-fleet cover selection. Feasible recovery/withdrawal versus necessary sacrifice, several small crews versus one large crew, and reserved variants still need controlled physical outcomes. |
| Recovery has real costs and useful rejoin | Four service slots, travel, CP, hull/ammunition/subsystem work, recovery histories | The station tooltip's incorrect two-slot claim is corrected to read configured capacity. Reposition/evasion code is not evidence that every attacked visitor finds a safe route or rejoins usefully. |
| Defeat differs from destruction; survivors retain agency | Immutable `StrategicResult`, player station loss and mobile fates; defeated-AI extraction/rearguard; explicit Blue withdrawal | The control rules exist. Long-match extraction completion, route safety and faction fairness remain unverified across the supported roster/layout set. |
| Restraint can be obeyed without invulnerability | `CanAutoEngage`, passage corridor and explicit interception; native departure required for escape | Not unconditional mercy or safe passage: explicit attacks and in-flight damage remain possible by design. Broader weapon/faction passage controls are still acceptance work. |
| Factual courage and sacrifice recognition | `RECOVERY_REJOIN`, `WITHDRAWAL_COVER`; duplicate/lifetime guards; report reasons | No general gallantry, distinguished-service or wing citations. A cover citation can survive the contributor's loss, but death alone never earns one. Final player readability is unverified. |
| Opening communicates responsibility and crew stakes | Six rewritten captions plus temporary native fighting/retreating hulls | Implemented presentation, not the missing rewrite previously reported here. Comprehension, final pixels and optional asset configurations still need review. |
| Honest reports without a moral score | Original station result, current survivor fates, post-result losses, recovery/pilot histories and citation reasons | Implemented data presentation. No verified crew head counts or casualty totals; no persistent campaign population. These are deliberate exclusions, not bugs to fill with invented values. |

Full philosophical acceptance is therefore **not established**. The next design work is controlled crew-preservation/necessary-sacrifice cases and review of recognition, extraction and intro presentation. Do not change combat balance solely to make the narrative look successful, or add crew-death totals, medal bonuses or diplomacy to close these gaps.

The central question is: **What do you keep fighting for once the battle can no longer be won?** Its counterpart for the winner is: **What does winning entitle you to do?**

The seven recommendations below describe one connected play loop. The current game implements that loop within a single RTS skirmish rather than a persistent campaign.

| Priority | Recommendation | What the player actually does |
| --- | --- | --- |
| 1 | Give ships and wings recognizable identities and factual histories | Recognizes a returning wing, takes its controls, and remembers its losses |
| 2 | Make preservation an accessible tactical decision | Sends a damaged ship for service, covers its retreat, or keeps it committed |
| 3 | Separate personal defeat, strategic victory, and fleet survival | Accepts losing a station while choosing what happens to the remaining fleet |
| 4 | Make player withdrawal a physical operation | Reaches an extraction area and chooses when to leave |
| 5 | Make restraint an enforceable order | Allows a withdrawing enemy to leave or explicitly continues the pursuit |
| 6 | Let defeated AI forces withdraw under cover | Encounters a rearguard that retaliates while the rest of the mobile fleet extracts |
| 7 | Report consequences without assigning a morality score | Sees who remained, who escaped, and which familiar ships were lost |

This preserves the appeal of building, commanding, and piloting FreeSpace fleets. Emotional weight comes from repeated interaction with particular ships and from choices with visible consequences. It should not depend on players reading philosophical speeches.

The design is an interpretation for this mod, not a claim that these mechanics or faction motivations are established FreeSpace canon.

## What the current game actually does

The current mode is a configurable single-player skirmish with up to twelve hostile teams, political faction profiles, shared escalation, CP production, physical service, direct piloting and match-local ship histories. It starts with stations and builds the combat fleets during play. Ship and wing histories reset with the mission; there is no persistent campaign population or crew model.

Several existing rules already carry philosophical implications:

- `EvaluateFactionVictory()` records an immutable strategic victor/draw when at most one command station remains. A player's station loss before that point records personal defeat but does not stop other factions' production if the player resumes.
- Strategic resolution starts global aftermath. Construction queues, pending sentries/strikes, income, upgrades, abilities and service stop; the stored strategic result cannot be rewritten by later station losses.
- AI fleets begin automatic extraction only after their station is destroyed. A healthy armed cover wing or ship stays to retaliate against the credited killer while other mobile units reach the marked sector and attempt native `warpOut()`; a living station never triggers automatic extraction. Blue remains a player choice unless Auto Mode owns the faction.
- Automatic targeting grants passage by default after a withdrawing ship reaches its corridor. Explicit attacks remain possible, weapons already in flight can hit, and withdrawal gives no damage immunity.
- Ship/wing histories record hull minima, damaged service recoveries, pilot time and confirmed loss/escape fates for the current match. The battle report shows strategic result and later mobile-fleet outcome separately.
- Service still requires travel, capacity, CP and time. Explicit player orders retain ownership until the player cancels or changes them.

The implemented rules develop these relationships. They do not add a moral score, crew-death estimate, or permanent campaign progression. Historical faction motivations remain fictional skirmish adaptations where the game does not establish them.

## Mechanics now in place and limits

### 1. Recognizable ships and wings, with histories the game can prove

Each eligible mobile ship receives a match-local record with its faction, class, native name, commissioning time, lowest observed hull, service recoveries, pilot time and eventual fate. Logical wings retain original membership for the final wing summary. These records are used for recovery notices, focus/service actions and the report. Names remain bounded by the native 31-byte ship-name payload limit.

Records contain plain data and a signature used only while the ship remains live. A terminal record is retained through removal/departure cleanup; a newly created ship with a reused native object slot receives a fresh record. Histories clear on mission restart/shutdown.

The report distinguishes ships still present, lost and confirmed escaped, and shows original/escaped/present/lost wing counts. A focused recovery notice appears when a manually ordered or piloted Blue ship reaches its configured critical-hull threshold. The user can focus the ship or send it to service.

Do not call a quiet interval an "engagement survived" without defining and detecting an engagement. Initial history can use the reliable events above. Do not invent captain biographies, crew counts, or thoughts from hull damage.

**Implementation:** `fs2rts_fleet_life.lua` owns `RecordShipCreated`, `RecordWingHistory`, `RecordServiceFinish`, `RecordPilotTime` and `RecordUnitFate`; lifecycle/service/pilot/departure hooks update them.

**Reason:** the player can replace an Orion, but the replacement is not the Orion they personally brought home twice. No veterancy damage bonus is required to make that distinction visible.

### 2. Make existing recovery decisions visible and easy to execute

The four-slot physical service economy remains. A critical-hull notice is rate-limited per ship and offers focus and the existing service action. Service reports unavailable when no station survives.

Sending a ship home withdraws its firepower from the current engagement, spends CP, and occupies existing service capacity. Continuing an attack preserves pressure and accepts the risk of losing it. Those are already meaningful costs; no extra injury currency is needed.

Preserve command ownership. A notice must never replace a manual attack, move, or possession order. Reuse the existing service cancellation and order-restoration paths. A wing-level command must continue to respect individual eligibility and slot capacity; it cannot teleport a wing into simultaneous repairs.

Record a "damaged recovery" only when a ship genuinely enters service damaged and returns to the existing readiness criterion. Rearming an undamaged craft is a service visit, not a near-death recovery. Track recoveries without paying a bonus, avoiding a repair-farming incentive.

**Implementation:** `FleetRecoveryNotice`, `FocusHistoryShip` and the existing `BeginFleetService`/`FinishFleetService` path own the action and record a recovery only when a ship entered service damaged and returned ready. No reward is paid for repair visits.

**Reason:** attachment matters when the player has a timely, usable way to act on it. Otherwise the history system only produces sad messages after unavoidable losses.

### 3. Separate three outcomes that the current lifecycle conflates

Track **the player's station loss**, **the strategic result**, and **the later mobile-fleet fates** separately. These are separate state transitions, not one result value.

| Event | Recommended behavior |
| --- | --- |
| Player station falls while multiple enemy stations remain | Pause and show player defeat. Resume leaves the global contest and surviving enemy economies active; the player can command, pilot or withdraw survivors. |
| At most one command station remains after same-frame station losses are collected | Snapshot that faction as strategic victor and enter global aftermath. |
| No command station remains when the strategic result is first determined | Snapshot a draw. |
| The last hostile station falls during continued combat | Show a draw; keep the first station result as report history. |
| No mobile ships remain, or the player's mobile fleet survives with no hostile assets left | Show final fleet fate with no Continue. Sole-survivor victory includes surviving enemy stations and sentries when checking for hostiles. |
| The player ends observation before resolution | Record `UNRESOLVED`; do not fabricate a winner or escape. |

Opening the report pauses mission time. Resuming a player-defeat report does not enter aftermath; only strategic station resolution does. The final fleet-fate report omits Continue and Withdraw actions, matching the completed mobile-fleet phase.

On global aftermath, pending builds, sentries, strikes and refits are cancelled without refunds; new income, upgrades, abilities and service are disabled. Launched projectiles and existing ships remain. Player-defeat-only reports do not cancel another faction's economy or pending actions.

**Implementation:** `EvaluateFactionVictory()` writes `StrategicResult` once. `PlayerDefeatShown`, `PostBattleActive` and `AftermathActive` separately represent Blue station loss, report visibility and global aftermath. `extraction-integrated-03` verified player defeat/resume preserves enemy production and that a later station loss cannot rewrite the stored strategic result.

**Reason:** losing a government or command structure, losing a battle, and losing every surviving ship are different events. The game's rules should acknowledge that difference.

### 4. Withdrawal must happen in space

After station loss, offer the player's surviving mobile ships **Withdraw** or continued combat. Withdrawal assigns a marked extraction area. Ships must reach it and complete a real departure. Ships already in flight are neither instantly saved nor silently removed.

Each faction gets a fixed extraction sector 14 km outward from its original station position, with an 8 km slot radius. Clearance search avoids the destroyed home station, other living stations, other extraction slots and the world boundary. Repeated withdrawal orders cannot move the sector. The HUD marks the sector and separates **WITHDRAWING // EXPOSED** from **IN DEPARTURE CORRIDOR**.

Withdrawal is irreversible for each ship after commitment. A committed ship's orders are cleared and turrets locked; it travels to its assigned sector and attempts native `warpOut()` only at the departure point. Players choose this for Blue; after an AI station falls, the same route carries the withdrawing survivors while a cover element retaliates. A living base does not trigger AI extraction. Player-issued orders retain precedence unless the player commits that ship to withdraw. Allow Withdrawal is on by default: automatic fire stops only once the ship enters the corridor. An explicit attack can still intercept it.

This creates a practical decision: send the damaged destroyer ahead, keep escorts fighting to cover it, then decide when those escorts should break off. An attacker can still destroy a withdrawing ship. Withdrawal status confers no damage immunity.

Only a confirmed departure hook marks a ship **escaped**. Death marks it **lost**. A missing route, absent propulsion or rejected departure leaves it **stranded/present** with a reason. End Observation records `UNRESOLVED` when no strategic result exists; it does not convert ships into escapees. Stations and sentries are reported as installations, separate from mobile survivors.

The player can pilot the approach. When the possessed ship reaches its departure point, control returns to the observer before the real hull attempts to leave. The observer and unrelated ships are excluded from withdrawal cleanup.

**Implementation:** `fs2rts_fleet_life.lua` owns player withdrawal, extraction areas, slot assignment, corridor state and history. Departure uses upstream `ship:warpOut()` and the departure hook; cleanup releases targets, groups, waypoints, service ownership and possession without running death/bounty logic. `extraction-integrated-03` verified a route reaching its corridor, accepted warpOut, one escape record, and a surviving observer.

**Reason:** preserving the player's fleet becomes a playable operation, including after defeat. Choosing withdrawal on a results screen alone would not provide this experience.

### 5. Make restraint a rule the player's ships can obey

**Allow Withdrawal** defaults on. It excludes committed ships from automatic targeting only after corridor entry; exposed withdrawing ships remain valid targets. The player can toggle passage to interception from the fleet-life controls.

Explicit attacks and pilot fire remain possible against corridor ships. Automatic passage grants no damage immunity, and in-flight weapons may still hit. There is no mercy score or withdrawal bounty.

`CanAutoEngage()` centralizes hostility and passage permission for mod targeting. Corridor entry clears disallowed stale attacker/turret targets and applies passage turret overrides; explicit target orders are retained. The native extraction probe verified autonomous guns honor passage and that explicit fighter/capital interception still causes real damage. It did not test every matchup or all weapons under long-match churn.

Keep faction hostility separate from this permission. `AreEnemies()` participates in threat, attribution, and other contracts; turning an entire faction friendly would hide real threats and affect other teams. An automatic-target eligibility rule belongs alongside hostility, with explicit-order handling kept distinct.

Ordinary eligible hostile kills retain their normal CP reward while the battle economy is active. Global aftermath suppresses payouts. Departure grants no bounty, salvage, refund or victory points.

The meaningful cost of passage is the opponent's survival and the player's choice not to intercept, not a hidden morality currency.

**Implementation:** native boundary evidence is in `extraction-integrated-03`. It verifies the tested corridor/autonomous-gun paths, explicit interception and no damage immunity; broader faction/weapons matchup coverage is still needed.

**Reason:** the player should decide what to do with a defeated force, and automation should carry out that decision. A moral choice is hollow if the turrets ignore it.

### 6. Defeated AI survivors extract under a rearguard

When an AI station is destroyed, automatic extraction begins for its mobile fleet: most units route to the faction's bounded extraction sector, while a healthy armed cover wing or ship stays to attack the credited killer. The rearguard switches to other in-arena hostiles if no killer assets remain; without a target it extracts too. This never starts while the faction's station is alive. The defeated faction gets no production or station service, and only a confirmed native departure counts as escaped.

The player controls the equivalent choice for Blue: continue fighting, or commit selected survivors to physical withdrawal after station loss or strategic resolution. Manual orders and possession remain authoritative. The extraction corridor and passage policy apply only after a ship is explicitly committed or the AI's station is destroyed.

Use existing weapon-role restrictions: base-capable units attack the responsible faction's station when it survives; fighters prioritize that faction's mobile ships and defenses. Keep automatic target reach, passage permission and hostile IFF checks in force. Do not grant invulnerability or invent replacement hulls.

**Implementation:** `UpdateDefeatedFleetExtraction()` runs on the existing survivor-combat cadence and is gated by faction elimination. It assigns a cover element, begins withdrawal for other eligible survivors, and uses `FactionDefeatedBy` to prioritize retaliation. Focused tests verify active-base no-op, post-loss extraction, rearguard orders and warp-out initiation. The rendered upstream review probe verifies station loss and actual retaliation damage; long-match faction balance remains to be measured.

**Reason:** defeating a command structure should not make its living defenders disappear from the fight. The player still gets the choice to preserve their own fleet by withdrawing it.

### 7. Give the report memory, with no moral grade

The paused report has Summary, Ships, Wings and Factions pages. It shows the stored strategic result, current mobile fleet fates, installations, after-result losses, stranded hulls, damaged-service recoveries and piloted time. Ship and wing details remain match-local.

Mobile ships and installations are counted separately. Confirmed departure records persist after native removal; ship fates and original wing membership do not rely on live object handles. CP spent is labeled “net refunds” because it reflects production spending/refunds rather than every expenditure category.

Use labels the data supports: **lost**, **escaped**, **still present**, **returned from service**, **piloted by you**. Do not report crews saved without a crew model, imply every destroyed ship lost all hands, or infer mercy merely because an enemy escaped beyond weapon range.

Example presentation, with illustrative values only:

> Player result: Defeat — command station lost.
>
> Global battle: Unresolved when observation ended.
>
> Fleet outcome: Four ships escaped; two were lost during withdrawal.
>
> First wing: Two of its original five ships escaped.
>
> Your destroyer returned from damaged service twice before its final loss.

Use restrained event text during battle: a recognizable identity and an observable event. Avoid accusing the player of murder, declaring them heroic, or inventing emotional speeches. Escalation notices should state the newly available capability and shared threat; the arms race needs no added “accelerate everybody” button.

**Implementation:** `BuildBattleSummary()` and `DrawPostBattleOverlay()` use the retained records. History is runtime gameplay state, not dependent on trace telemetry. No between-match persistence is added.

**Reason:** a report can let players interpret what they did. A virtue score would reduce the whole design to optimizing another meter.

## How a match should unfold

The player builds a wing, gives it an identity through the existing wing label, and can pilot a ship or recover a critically damaged ship through service. Match history records hull lows, service recoveries and pilot time for the report.

During a base assault, the player chooses between recalling the wing for service and keeping it in the fight. Service still uses normal travel, capacity, CP and repair time.

The player's station can fall while other stations remain; resuming keeps their economies active. Defeated AI survivors extract after station loss under a rearguard that attacks the credited killer. Blue ships can be manually withdrawn after defeat. Passage applies at the marked corridor only for ships committed to withdraw; explicit interception and in-flight damage remain possible.

When at most one command station remains, or none remain, the first station result is recorded and global aftermath begins. The player can resume while mobile fleets finish their fates. The original report stays in history, but continued combat can earn a draw by destroying the last hostile station and final victory by eliminating every hostile asset while the player fleet survives. The final report has no Continue action.

This sequence supports attachment, duty, restraint, and survival through ordinary actions. It needs no external campaign to make this particular battle matter.

## Current code ownership

These are the active ownership seams for the implemented behavior.

| Data/state | Owning module | Current contract |
| --- | --- | --- |
| Histories, recoveries, pilot time, withdrawal/passage | `fs2rts_fleet_life.lua` | Match-local records survive live-object cleanup; no between-match persistence |
| Player defeat, strategic result, global aftermath | `fs2rts_lifecycle.lua`, `fs2rts_ui_text.lua` | Strategic result is immutable; report visibility is separate |
| AI build request | `fs2rts_ai_production.lua`, `fs2rts_hud.lua` | One active player-side Auto Mode request saves CP; emergency defense and fleet-cap rules still apply |
| Scene and music | `fs2rts_environment.lua`, `fs2rts_config.lua` | Retail files resolve through VFS; no volumetric-nebula mode is enabled |
| Asset provenance | `core/data/maps/README-insignias.txt`, `core/data/FSPORT-ASSET-CREDITS.txt` | Six attributed legacy badges and five standalone FS1 hull models/maps |

Histories are match-local. No live engine handles are stored in records. Restart and shutdown clear histories, extraction state, scene handles and music streams. Telemetry remains separate; records retain only player-facing counters and milestones.

Departure and result semantics are deliberate changes described in the play README. Extraction uses native `warpOut()` and keeps departure cleanup distinct from death/bounty processing.

## Native verification and limits

| Probe | Observed result |
| --- | --- |
| `extraction-integrated-03` (rendered upstream FSO 26.1.0) | Passage honored by autonomous guns; explicit fighter/capital interception caused real damage; accepted warpOut recorded one escape while the observer survived; route reached its corridor; pilot pause/speed/Escape worked; player defeat/resume preserved enemy production; later station loss did not rewrite the strategic result. |
| `expanded-rosters-env-06` (rendered upstream FSO 26.1.0) | Twelve-team setup, all nine profiles, and actual creation of Apollo, Valkyrie, Athena, Anubis and Shaitan; all 36 retail backdrop names/art resolved and add/remove reused at most one instance slot; first/last retail music WAVs resolved. |
| Temporary staged MediaVP music check | The matching first/last OGG files resolved through VFS when `MV_Music.vp` was hardlinked into the probe workspace. The temporary link was removed; no audible-output claim. |
| Focused tests at this documentation update | Faction profiles 16, environment 4, table references 12, Lua parser 0 failures. The full repository suite has not yet been rerun on the final shared working tree. |

The probes do not establish faction win-rate balance, late-game performance at twelve factions, sound audibility, or passage fairness across every weapon/faction combination. A static 24/30/32-pixel insignia preview was inspected with the PCX green key applied; it is not a final in-engine screenshot/contrast audit. Earlier failed probe attempts remain in the artifacts archive with their original verdicts.

Playtesting must answer questions the code cannot prove: Can players recognize a ship without opening its history? Do they use service because of attachment as well as efficiency? Is withdrawal understandable while piloting? Can they distinguish winning the battle from surviving it? Does extraction finish naturally without becoming a cleanup chore?

Do not claim emotional success from counters alone. If players ignore identities and histories, revise presentation and repetition before adding more rules. If withdrawal is tedious, adjust route and departure pacing rather than pretending a button press saved everyone.

## What to leave out

| Earlier idea | Final decision and reason |
| --- | --- |
| Finite crew/reinforcement reserves | Exclude. This would rebalance production, abilities, attrition, and stalemates before the core attachment loop is established. |
| Escape pods and rescue craft | Exclude. They introduce a second recovery game, new objects, pickup rules, crew assumptions, and farming risks. Physical ship withdrawal provides a coherent first survival mechanic. |
| Player-triggered global escalation | Exclude. Paying to strengthen every opponent is difficult to make legible or attractive; the existing shared schedule already expresses an arms race. |
| Diplomacy, alliances, surrender ownership, prisoners | Exclude. These require broader contracts than the narrow withdrawal and engagement permission proposed here. |
| Permanent campaign progression | Exclude. This mode is a skirmish. A remembered ship can matter within one battle; persistent rewards would add balance and save-format obligations. |
| Veterancy combat buffs | Exclude. First establish attachment without making preservation merely the best statistical purchase. |
| Random mutiny or refusal of explicit orders | Exclude. It undermines the command ownership the current implementation deliberately protects. |
| Species or faction morality stereotypes | Exclude. Existing hulls, capabilities, and observable behavior are enough to distinguish forces initially. |
| Crew-death estimates derived from hulls | Exclude. The current system does not justify those numbers. |
| “Good commander” ratings or a mercy currency | Exclude. Show consequences and let players judge their choices. |
| Mandatory total destruction or forced aftermath | Exclude. Both turn a resolved objective into compulsory cleanup. |

These exclusions are intentional scope boundaries for the current release, not claims that all follow-up balance or presentation work is complete.

## Evidence and limits

This document describes the current working tree and the limits of its evidence. Native probes establish the listed upstream engine interactions; they do not prove faction balance, long-match performance, sound audibility or the emotional effect on players.

Inspected sources:

- [Play and controls](../core/README.md): current mode, service, possession, station objectives, and survivor flow.
- [Configuration](../core/data/scripts/fs2rts_config.lua): faction profiles, shared escalation, and recovery settings.
- [Lifecycle](../core/data/scripts/fs2rts_lifecycle.lua): `BuildBattleSummary`, `EvaluateFactionVictory`, global aftermath and immutable strategic result.
- [Fleet life](../core/data/scripts/fs2rts_fleet_life.lua): match history, service recovery, pilot time, extraction, passage and final fleet fates.
- [Report transitions](../core/data/scripts/fs2rts_ui_text.lua): paused result reports, resume, withdrawal, restart and end observation.
- [Strategy](../core/data/scripts/fs2rts_strategy.lua): tactical AI and stationless survivor ownership.
- [Factions and wings](../core/data/scripts/fs2rts_factions.lua): `AreEnemies`, `RegisterLogicalWing`, and live wing lookup.
- [Production](../core/data/scripts/fs2rts_production.lua): `SpawnFactionUnit`, creation, player income, and aftermath guards.
- [AI production](../core/data/scripts/fs2rts_ai_production.lua): global aftermath and report guards.
- [Service](../core/data/scripts/fs2rts_service.lua): return travel, service ownership, completion, and cancellation.
- [Orders](../core/data/scripts/fs2rts_orders.lua): existing order, movement, and command ownership entry points.
- [Pilot and wing control](../core/data/scripts/fs2rts_player_wing.lua): broadcast Depart protection and observer/recipient safeguards; extraction uses a narrow lifecycle path.
- [Pilot](../core/data/scripts/fs2rts_pilot.lua): possession entry, exit, and tactical directives.
- [HUD](../core/data/scripts/fs2rts_hud.lua): identity, scene/music picker, request-build buttons, fleet recovery controls and `DrawPostBattleOverlay`.
- [Environment](../core/data/scripts/fs2rts_environment.lua): retail soundtrack VFS selection, optional MediaVP OGG lookup, and 2D backdrop add/remove.
- [Station systems](../core/data/scripts/fs2rts_station.lua): aftermath gating for station actions and pending strikes.
- [AI planning](../core/data/scripts/fs2rts_ai_planning.lua): hit observation records, which must not be mistaken for verified casualty or engagement histories.
- [Development record](DEVELOPMENT.md): native probe tags, run evidence and unresolved balance/presentation questions.
- [Asset credits](../core/data/FSPORT-ASSET-CREDITS.txt) and [insignia provenance](../core/data/maps/README-insignias.txt): source and noncommercial reuse terms.

The implementation uses upstream FSO and adds no engine patches. The current rendered probe validated 12-team setup, native creation of the five bundled FS1 hulls, music/backdrop VFS calls and selected extraction/pass-through cases. Full-suite verification and broad matchup/endgame balance testing remain separate work; no claim of equal faction strength is made.
