# FreeSpace RTS: Fleet Command 1.4.1

FreeSpace RTS: Fleet Command is a single-player real-time strategy and fighter-pilot hybrid for FreeSpace Open. Command Blue's fleet against Red, with an optional third faction, from a tactical camera and minimap. Build strike craft and capital ships, manage command points and reinforcements, and switch into a fighter or bomber to fly it with FreeSpace Open's native HUD and controls.

## Launch

Select **FreeSpace RTS: Fleet Command** in Knossos and launch it. The mod's launch settings start the included **FS2 RTS - Escalation** campaign. It requires retail FreeSpace 2 assets and FreeSpace Open 26.0.1. MediaVPs are optional. Asteroid fields and free starting sentries are disabled by default; purchased sentries are available from the STATION tab.

The tactical map uses ship-class icons when available and role markers as a fallback.

## Controls

- Left-click selects a ship; left-drag box-selects. Shift modifies the selection.
- Alt-click focuses the camera on a ship or point; Alt-drag selects and focuses a friendly group.
- Right-click empty space issues a formation move; right-click a hostile to attack or a friendly to guard.
- **Right-press and drag from empty space** (with a selection) sets a move destination *and* the facing: the press point is the destination, the drag direction is the heading the ships turn to on arrival. The live preview shows the destination cross, the facing arrow and a **FACE** label while you drag.
- Attacking a member of a multi-ship wing keeps the order on that wing and retargets its surviving members.
- Middle-drag pans the camera; right-drag over a ship, or with nothing selected, orbits; the mouse wheel zooms.
- WASD or arrow keys pan the camera. Shift slows camera movement.
- The minimap supports selection and box-selection; right-click moves the camera focus.
- **F1..F4** recall wings 1-4; **Ctrl+F1..F4** assign the current selection to one. (Legacy **Ctrl+1..4** assign still works.)
- **1** / **2** / **3** / **4** drive the time ladder: slower, pause/resume, faster, and reset to 1x. **+** and **-** also step the speed.
- **B** enters chase mode on the ship under the cursor (or the primary selection) and releases it again; **Alt+double-click** still works.
- Press **P** with one friendly fighter, bomber, or capital ship selected to pilot it. Press **P** again to return to RTS command.
- Possessing a **capital** exposes its turret groups: **[** and **]** select a group, **\\** puts every group live at once, **O** toggles the locked-in target subsystem, and **<** / **>** step through the target's subsystems. Pulling the primary trigger fires the active turret group, because a capital's guns live in turret subsystems that the normal ship fire calls cannot reach. The pilot HUD names the group, the target subsystem and when manual fire is live.
- **L** selects all; **R** orders selected ships to hold position; **T** orders them to engage nearby hostiles; **G** releases them.
- **J** / **Z** / **X** / **V** set the default policy to **HOLD**, **RETREAT**, **STANDOFF**, **ENGAGE**. **HOLD** is the default and issues no standing order at all, so with Auto Mode off an uncommanded fleet only does what you told it to.
- **N** mutes the mission music without touching weapon or UI audio.
- The **FORMATION** button in the tactical options strip cycles the group shape used by the next move: LINE, COLUMN, TIGHT, WEDGE, ECHELON, SCREEN. The AI picks its own shape per role.
- **SERVICE** sends selected ships back for paid station repair and rearm. A green **+** on the tactical map marks recovery; ship labels show RETURNING, QUEUED, UNDER FIRE, WAIT CP or REPAIR REARM.

Hovering any ship draws its effective weapon range as a ring on the command plane, its current action and projected course, and — while it has a move order — the destination and the facing it will arrive on. Target reticles keep the same shape and colour language as the tactical-map icons at every zoom level, and contacts outside the view are pinned to the screen edge as hollow markers. The battle director favors recent hits, active target locks and ships under fire over idle capital shots. Selecting a ship shows its weapon loadout (primary, secondary and, for a capital, every turret bank), current AI mission, target, distance and reason. If the piloted craft is destroyed, the pilot view remains for five seconds before returning to RTS command.

Tier 5 unlocks juggernauts late in a match: 23 minutes in the 30-minute profile and 46 minutes in the 60-minute profile. They have no hard count cap. Colossus and Sathanas cost roughly 12,000–14,000 CP; the Lucifer now costs about 15,450 CP, a 25% premium over its prior price. Four juggernauts consume most of a faction's measured lifetime CP in a long match; players and AI can exceed four if they earn the points, at the expense of the rest of their fleet. The AI can save for one for up to ten minutes, then resumes affordable production if it cannot buy one.

Wingmate HUD visibility and normal-style commands while piloting are not included yet. Placeholder: this capability remains future work. The experimental native wing-membership extension is disabled and is not a mod dependency.

## Auto Mode, cinematic and the after-action report

**AUTO MODE** hands your faction to the AI: it spends your CP, builds ships and issues strategic orders. Switching it **off** refunds any queued build and drops the Blue production state entirely, so nothing can spend your CP on your behalf. The default policy becomes **HOLD**, which issues no standing order at all, so an uncommanded fleet sits where you left it. The other three policies (RETREAT, STANDOFF, ENGAGE) are opt-in stances. Red and Gold are never affected by the switch.

The intro cinematic runs six establishing shots with per-shot hold beats and FOV interpolation. **Left** / **Right** step between shots and **5** replays the current one, each with a shot counter and progress bar in the letterbox; any other key or click skips the whole intro. After the last shot the camera drifts for a beat rather than freezing on the cut.

When the battle ends, the report shows the outcome and why, then Blue's battle length, escalation tier, ships lost, capital losses, enemy kills, CP spent, CP remaining and fleet cap, plus a surviving-or-eliminated row per faction. Defeat distinguishes a destroyed Blue station from mutual destruction.

## Station upgrades and sentries

Open **STATION** in the right panel. It uses the sidebar space normally occupied by production, control groups and fleet policy; return to **PRODUCTION** for those controls. Hover an upgrade for costs and effects; hover the hull readout for the rotating station preview.

Each track has three cumulative levels, unlocked at escalation tiers 1, 2 and 3. Pay CP when starting; only one upgrade runs at once, while ship production continues. Upgrade duration follows the match duration setting.

| Track | Level 1 | Level 2 | Level 3 |
| --- | --- | --- | --- |
| Armor | +20% maximum hull | +40% maximum hull and slow repair after 30 seconds without damage | +60% maximum hull |
| Defenses | +2 sentry capacity | +50% hull on existing and future sentries | Station and sentry turrets fire 25% faster |
| Logistics | +15% CP income | Ship builds take 20% less time | +30% CP income and a second simultaneous ship-build lane |
| Command | +8 fleet capacity | +2 km sentry placement radius and +2 sentry capacity | Faction ability |

Armor preserves the current hull percentage rather than healing damage instantly. Defenses L3 improves existing station turrets and current/future platforms; it no longer awards unequal free ships. Blue's Logistics L3 opens a second concurrent build lane; autonomous factions keep one production job at a time.

Station repairs recover at most 60% of observed hull damage; the other 40% leaves permanent scars. **BASE LIMIT** shows the remaining repair ceiling. Armor upgrades preserve scars as a fraction of maximum hull. Winning a raid therefore leaves damage that the next attack can exploit.

Fleet service is available at each surviving faction's station. Ships gather beyond the station hull on the side away from nearby threats. Two ships can receive service at once; a capital, heavy or juggernaut uses both slots. Travel and queue time provide no recovery. Damage or a nearby armed threat pauses work for at least eight quiet seconds.

Service repairs 0.4% maximum hull per second to 90%, repairs subsystems at 1% per second to 90%, and restores 4% of each ammunition bank per second to full. Actual work consumes faction CP: repairing a full hull costs 35% of the ship's current purchase estimate, all subsystems 15%, and a full payload 12%. Partial work costs proportionally. No CP means waiting; losing the station prevents further service. Ready ships return to their previous manual orders or normal fleet control.

Autonomous ships return below 40% hull, below 15% in any finite ammunition bank, or with badly damaged systems. A ship under pressure at 22% hull or less breaks contact even while defending. More than four times the local opposing combat strength triggers immediate avoidance, and more than twice triggers withdrawal after six seconds, when an enemy is targeting the ship or it has taken a recent hostile hit. Mere proximity to a stronger force does not trigger service. A healthy siege unit does not retreat merely because its intended capital target has a large hull. Recovery has a minimum duration and a retry cooldown. New RTS orders can cancel service; critical self-preservation can trigger again. Player-piloted ships retain direct control.

Kill rewards belong to the faction that dealt the fatal attack. AI-versus-AI deaths do not subsidize Blue; friendly fire, self-kills, unknown killers and repeated death callbacks pay no bounty.

Choose a sentry, then left-click in the world or minimap. Construction takes 20 seconds; its footprint is reserved and shown on the map. If enemy ships reach the build site before completion, construction cancels and refunds its CP. Invalid placement stays armed; Shift keeps placing after a successful order; right-click cancels. Placement range starts 4 km beyond the station model radius, with collision-sized clearance around the station and 600 m minimum spacing. Sentries have their own cap of 6 (up to 10 with upgrades) and do not consume fleet slots. Select your sentries and press **SELL** for half the CP actually paid; free platforms refund nothing.

Sentries have fixed prices and hull profiles, independent of mobile-ship pricing. Their roles differ:

| Platform | Faction | Tier | CP | Hull before upgrades | Weapon / role |
| --- | --- | --- | --- | --- | --- |
| Watchdog | Blue | 1 | 375 | 600 | Basic Terran laser screen |
| Cerberus | Blue | 2 | 875 | 900 | Flak against strike craft |
| Alastor | Blue | 3 | 1500 | 1200 | Harpoon missiles |
| Mjolnir | Blue | 4 | 3000 | 3000 | Capital beam, aimed horizontally away from the base |
| Ankh | Gold | 1 | 375 | 600 | Basic Terran laser screen |
| Edjo | Gold | 2 | 875 | 1000 | Harpoon missiles |
| Cerberus | Gold | 3 | 1500 | 1200 | Flak against strike craft (Terran hull; see below) |
| Mjolnir | Gold | 4 | 3000 | 3000 | Capital beam (Terran hull; see below) |
| Trident | Red | 1 | 375 | 700 | Basic Shivan laser screen |
| Belial | Red | 2 | 825 | 1100 | Four-turret Shivan laser battery |
| Rahu | Red | 3 | 2000 | 4000 | Three-turret flak battery |

Prices are authoritative in `fs2rts_config.lua` (`AI` -> `Defenses` -> `Classes`). Gold reaches tier 4 like Blue; it previously stopped at tier 2, which left its base materially softer at identical CP spend because `UpdateStationAI` filters on `option.tier<=tier`.

Gold's tiers 3 and 4 reuse Blue's `GTSG Cerberus` and `GTSG Mjolnir` hulls. They were previously listed as `GVSG Sotar` and `GVSG Sekhem`, which name no class in retail `ships.tbl` or in any mod table — retail ships exactly two Vasudan sentries, `GVSG Ankh` and `GVSG Edjo` — so those slots could never build anything, and the entry meant to close the tier gap silently reopened it. An unknown class is an invalid handle rather than `nil`, which is why it never threw. `core/tools/test_table_references.py` now fails the build on any unresolvable `class`/`weapon` reference. Modelling real Vasudan emplacements means defining ship classes in a mod `*-shp.tbm`; that is outstanding work, not a tuning change.

Laser travel is 1,375 m for Terran turrets and 950 m for Shivan turrets; Harpoon travel is 1,250 m. Flak works at roughly 1 km and the Mjolnir beam reaches 4 km; its turret is locked against targets outside that distance and tracks in-range targets along its placement lane. These are weapon travel limits, not guaranteed hits against moving ships. Turret arcs matter: cover multiple approaches, and place Mjolnir on the lane it should defend. It is a capital specialist, not a bomber screen.

Command L3 unlocks a 150-second-cooldown ability: Blue targets a strike within 12 km of its station, Gold jumps in a Sobek if a fleet slot is free, and Red boosts nearby fighter/bomber maximum speed by 50% for 20 seconds, preserving engine-recharge speed changes. Blue's strike arrives after 5 seconds, deals 1,200 native blast damage inside 250 m and falls off to zero by 900 m in three dimensions. Shields and armor apply, and **friendly fire is enabled**. An out-of-range click keeps targeting armed and spends no cooldown.

AI factions can buy upgrades and sentries; Blue does so only with auto mode enabled. AI preserves the cost of a mobile production package, builds at least eight mobile combatants before discretionary defenses, and normally buys only two sentries without nearby threats. Threats influence platform choice and additional defensive investment. Sentries never count as mobile fighter composition.

**Known defect, live in the shipped default.** The save window is restarted by *every* purchase, including the cheap hull the producer deliberately fields alongside an unmet goal. The window therefore never ages out, the bank never accumulates toward its target, and `SAVING_FOR_DESIRED_ROLE` becomes a permanent no-op. Measured headless, 4/4 matches: **zero capital, heavy and juggernaut hulls built**, per-faction bank peaking near 2,300 CP against a target of 12,675-31,275 CP, fighter builds up 5x and losses up 228%. The target is economically unreachable, not merely unsaved for. See `docs/contracts/03-ai-production.md` and `docs/contracts/04-station-economy.md` for the recorded violations.

In a three-faction battle, the commander allocates new groups toward a 70% preferred-front / 30% secondary-front split by assigned combat value. This keeps a main assault concentrated while covering both enemies. Surviving groups keep their fronts; a destroyed, disabled or realigned target releases the assignment. There is no fleet-wide turn every 180 seconds and no hull-weakness pile-on. With one enemy faction remaining, groups converge on that survivor. Capital strike groups stay on the station objective until a fixed defense is within weapon reach, preventing a distant sentry from stalling the siege. Manual Blue orders and piloting retain priority over automatic control.

The commander assesses each front separately, counting that enemy's defenders rather than treating a third faction attacking it as friendly defensive strength. Close self-defense, interception, escorts and feints still operate below the campaign assignment. Group retention cannot restore an obsolete base objective after an explicit front reassignment. Ordinary base emergencies target at most 70% defensive allocation; critical hull may authorize a full recall. Allocation uses whole groups, so percentages are budgets rather than exact ship-count limits.

Combat strength uses remaining hull/shields and nominal output of available weapons. Locked/destroyed turrets and empty ammo banks contribute no output; purchase price remains an economic/replacement-cost measure. This proxy does not simulate accuracy, armor interactions or missile submunitions. Higher difficulty lowers the required overmatch for an assault (Easy 0.76, Normal 0.65, Hard 0.59, Brutal 0.53); self-preservation and retreat thresholds remain active. Native hostile missile targeting is recognized as point defense and never passed through ship-only field access.

Production combines composition deficits with counter-role demand reported by the commander for nearby home threats. During an active base emergency, the AI cancels long capital saving and buys the fastest affordable counter: bombers for capital threats, otherwise fighters, then escorts. Once the emergency clears, ordinary saving resumes. Station upgrades and sentries respect the factory's current CP reservation. The AI's savings window does not restart when its composition need changes: it saves for at most two minutes for ordinary purchases, ten minutes for tier-3 capitals, fifteen minutes for tier-4 heavy ships, and ten minutes for tier-5 juggernauts before buying another affordable role. Under critical station pressure, attack operations hold their offensive commitment instead of withdrawing on a routine timer, and focused attackers stay in the fight unless their hull reaches the critical retreat threshold. AI fighters keep a station strike until their ammunition is nearly empty; fighters rearm at 5%, other roles at 15%, and committed base-strike groups at 2%. Escalation is not a free-spawn schedule: Ravana is a tier 3 capital, while Sathanas, Lucifer and Colossus are tier 5 juggernauts funded through the normal economy. Faustus is an armed light escort with a science-hull model; it supplies no CP-income bonus or research ability. No CP storage cap has been added.

Out-of-combat armor repair resets its delay on every observed hull loss, including fractional damage below 0.5 HP. Repeated light hits must suppress repair just like large hits.

## Development checks

`tools/kill_reward_natural_fire_probe.lua` and its matching `tools/kill-reward-natural-fire-sct.tbm` run an isolated native reward check. Place the script and hook in a leading probe mod, using the same portable headless runner as the station checks. Require final `PASS` plus normal engine exit: an armed Hercules must kill a fighter with projectiles and a Hecate must kill a Fenris with beams. The probe checks the native killer handle, its owning ship, exact bounty, and zero payments to other factions. Low-hull stationary targets isolate attribution, not combat balance. Do not inspect ship-only properties on weapon/beam handles, even inside Lua `pcall`: unattended engine property errors can throw a native exception.

`python core/tools/test_station.py` runs the actual Lua scripts under Lua 5.1 using Python's `lupa` package. From inside `core`, use `python tools/test_station.py`. An optional scripts-directory argument allows comparison with a backup. These checks cover purchase rejection, completion boundaries, repair timing, reset, placement/refunds, capacity, abilities, income/build speed, AI spending and panel bounds; engine objects are test doubles.

`python core/tools/parse_check.py` compiles every module in `data/scripts` and reports the first file that fails to load. Run it after any edit: Lua only reports a syntax error when the mission actually loads, so a typo ships silently otherwise.

## Headless match verification

`python core/tools/prepare_headless_batch.py --tag <label> --matches 8` stages a headless workspace from the *current* mod tree — hardlinked retail VPs, this mod as `rts`, and `core/tools/acceptance_driver.lua` as a leading `probe` mod that starts the scenario, emits one `BATTLE_END` record and asks the engine to quit so a match ends naturally instead of being killed at the wall clock. It writes a plan for `src/fs2open/tools/rts_ai_experiments/run_batch.py`, one match per worker. Point `--core` at a pre-change snapshot for a paired control on identical seeds.

`python core/tools/analyze_batch.py <results>` turns a finished batch into per-feature verdicts: crash and error counts, natural versus timed-out terminals, capital spawn placement against both the own-base and enemy-base limits, measured beam-versus-projectile damage per hit on a station, order compliance, and the outcome cause.

Three further tools turn a batch into evidence rather than a number:

- `python core/tools/ai_timeline.py <results>` streams per-faction time series, derived phase transitions and ASCII sparklines, and explains anomalies in the terms that caused them (for example a production blackout, naming the build reason, the bank movement and the bank target that were in play).
- `python core/tools/compare_batches.py <baseline> <candidate>` normalises 64 metrics, applies each metric's declared polarity, and separates real change from noise using the spread of per-match values. It refuses to compare totals when the two batches ran different amounts of simulated time.
- `python core/tools/ai_invariants.py <results>` asserts algebraic invariants - CP spend reconciles to build costs, `FACTION.losses` reconciles to LOSS events, capital-class production actually happens, `bankTarget` is reachable against the observed bank peak. This is the check that finds *absences*, which a baseline diff cannot.
- `python core/tools/regression_gate.py <candidate>` grades a candidate against a baseline on a fixed metric set and exits non-zero on a regression. It refuses to gate a metric that has no declared polarity, rather than passing it silently.

Contracts for each subsystem, including recorded violations and unverified invariants, are in `docs/contracts/`.

Three records exist only to make a result explainable rather than merely reportable:

- `DECISION` carries the group's centroid, radius, target and station position, and the arena extent, so where each group was can be reconstructed.
- `COHESION` (every 2 s per faction) holds every group's geometry and the pairs that shared a target or whose discs overlapped, which is the only record of a faction coordinating with itself. It is rate limited because sampling on every planner tick roughly tripled a headless run's frame cost.
- `CONTEST` (every 10 s per faction) and `OUTCOME_CAUSE` (once, the instant a command station dies) answer "why did this side lose": how the groups were allocated between the enemy base and enemy groups, how long any assigned group went without closing on its objective, and which faction killed which base with which weapons from what state. The CONTEST stall metric is the live signature of a capital that accepted an attack order and then parked, which is what the engine does when `ai_chase` refuses a fighter target.

Two limits worth knowing. The command arena is a *movement* clamp, not the playfield: the Red and Gold stations sit outside it, so groups near their own base are expected to be outside it. And capital hulls carry a `$Collision Physics` block with zero rotation factors, so a collision cannot spin them; the visible rolling during rearm is a goal-reissue loop, not collision response.

`python core/tools/undefined_global_check.py` flags any bare global function call that is neither a module local nor a name this FSO build actually registers. It exists because an undefined scripting global does not raise a catchable Lua error in the engine: the process aborts with an uncatchable C++ exception, leaving no Lua stack, no log line and an empty stdout. That exact failure shipped once during this work (a `shipValid` call where the module's helper is the local `valid`) and cost several failed headless batches to find. Run it before every headless batch; it takes under a second.

`python core/tools/test_feature_request.py` covers the interaction layer specifically: that every bound key is also swallowed by `ShouldOverrideKey` (a key bound but not swallowed leaks to FSO and double-fires), that no two actions share a key, that number keys drive time rather than wing recall, that Auto Mode off leaves Blue unable to spend CP while Red and Gold keep producing, that each formation shape produces distinct slot geometry, that reticle pixel size stays inside its clamp across the whole zoom range, that cinematic shot switching wraps without error, and that the after-action report carries real numbers. It also guards two bugs that shipped during this work: an infinite recursion in the move-facing frame updater, and a shot switch that advanced the status line without advancing the shot. Its spatial and outcome telemetry suites pin the group-centroid, cohesion, contest and outcome fields the analysis tools depend on, including the stall metric and the per-faction sample cadence.

`core/tools/station_headless_probe.lua` is an opt-in native combat probe, never loaded in normal play. In an isolated portable copy with retail VPs, add a leading `probe` mod with this file under `data/scripts` and a conditional `$On Game Init` hook requiring `station_headless_probe`. Add a briefing `$On Frame` hook posting `GS_EVENT_ENTER_GAME`. Run `FS2_RTS_Escalation` with `-headless -fixed-dt 0.03333333333333333 -noninteractive -max-sim-time 160`, at normal time scale. The local experimental FSO build must support these flags and dispatch Lua frame callbacks in headless mode. The probe writes and flushes `probe/data/station-fixes.txt`; require its final `PASS`, not just a successful engine exit. It tests every upgrade level/faction, all nine platforms against a cruiser/fighter/bomber at 650 m across four directions, Mjolnir's actual placement orientation, repair delay, Surge persistence/expiry, Gold reinforcement and native strike controls. Ten-second gaps allow old projectiles to expire between combat trials. Targets are immobilized and hull-normalized; this is mechanism verification, not a moving-target balance test.

`core/tools/coordination_contract_probe.lua` uses the same isolated setup, requiring `coordination_contract_probe` instead and a 45-second cap. Require the final `PASS` in `probe/data/coordination-contracts.jsonl`. It disables the operation layer to isolate native missile targeting, persistent two-front assignments, disabled-weapon valuation, ordinary/critical recall budgets, counter-role demand, capital savings and fractional-damage repair. Its emergency contact is injected into the hit cache with real native ships; it does not prove a physical beam hit. The station probe above covers native weapons separately.

`core/tools/convoy_headless_probe.lua` uses the same setup with a 210-second cap. Require its final `PASS` in `probe/data/convoy-headless.jsonl`. It repeatedly evaluates operations and installs native goals for one bomber and three fighter groups, checking physical approach progress, escort separation, reserve release and operation continuity. The objective is immobilized and disarmed. This isolates movement mechanics; it does not measure combat effectiveness or prove coordinated attacks win more battles.

Full-match experiments need `AI.TraceFileEnabled=true` in the isolated test copy; enable `ExperimentalDamageTelemetry` only with the matching local hook build. Require a `BATTLE_END` event and natural engine `mission_exit` for terminal results. Compare multiple seeds; seed control does not produce identical tactical replays. Test MediaVPs separately from retail models; the headless checks use retail assets.

For full acceptance batches use the maintained runner rather than the ad-hoc probes above: `work/readable-rts-acceptance/prepare_suite.py` stages a run and `src/fs2open/tools/rts_ai_experiments/run_batch.py` executes it, with the verdict rules in that directory's `README.md`.

## Engine-facing traps

Both of these fail silently in a way that costs a full debug cycle, and neither is caught by reading the mod code.

- **Never put `#` comments inside `#Conditional Hooks`.** The SCT parser reads `optional_string("#Conditional Hooks")`, which skips whitespace only, so any prose before the marker makes it skip the entire block. Inside the block a `#` line is consumed as a *condition*, rejected, and the following hook is disabled: `Condition '#' is not valid for hook 'On Game Init'. The hook will not evaluate!` For `On Game Init` that means the mod never loads; for `On Ship Death`, that death bookkeeping silently stops. `data/tables/fs2rts-sct.tbm` must stay comment-free — put the rationale in the Lua beside the code it explains (see `fs2rts_lifecycle.lua`, `TRANSIENT_GAME_STATES`).
- **Check every engine flag name against the engine tables.** `ship:getFlag("weapons-locked")` is a real flag — `Parse_object_flags[]` in `code/mission/missionparse.cpp` and `Object_base_fixes[]` in `code/ship/ship.cpp` both carry it, alongside `primaries-locked`, `secondaries-locked`, `lock-all-turrets` and `afterburners-locked`. An earlier version of this file claimed the opposite and would have discouraged a perfectly valid flag; verify against the engine tree rather than against prose like this. A bad name still logs `Ship/object/ai flag '…' not found!` on every call and always returns false, which turns the guard into dead code rather than an error.

## Debugging a load or activation problem

Run a **debug** build and read `[FS2RTS]` lines in `fs2_open.log`; the mod logs activation, shutdown, and invalid runtime ship classes. Two log-reading caveats: the log is only written on a graceful exit, so do not force-kill a run you intend to inspect, and the debug build's asserts and modal dialogs discard the log entirely — prefer the release engine for unattended batch runs and the debug build only for interactive diagnosis.
