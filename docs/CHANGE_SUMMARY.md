# RTS Fleet Command — Review and Change Summary

This document records the review and follow-up changes through 8 October 2026. Dated sections are historical snapshots; the latest section supersedes earlier behavior. It is not a claim of statistically optimal balance.

## Evidence and spawn follow-up — 8 October 2026

Fixed congested spawn admission, added production job identity and terminal accounting, and made AI-only trials continue past personal defeat to the global strategic result. Frozen provenance/completion, common windows and observed metric coverage now gate comparisons. Equal initial budgets/base income and named slot swaps support controlled trials. The historical mutation registry was audited and its seven weak checks repaired. Completed tests/native evidence and remaining balance/UI/MediaVP limits are in [Development](DEVELOPMENT.md#evidence-and-spawn-follow-up--8-october-2026).

## AI rebalance — 8 October 2026

The later [verification cleanup](AI_ACCEPTANCE_AND_INVARIANTS.md) changes the meaning of analyzer/gate outcomes: three accounting invariants are separated from four diagnostics; comparison goals/directions/baseline are explicit; incomplete or inconclusive evidence cannot pass. Evidence-group test suites and the findings/invariant catalogue now guide further work. Gameplay behavior is unchanged by that cleanup.

- Parked performance optimization at the user's request; researched recent RTS/multi-agent learning work and applied spatial influence, coordinated roles, state feedback and held-out evaluation within Lua.
- Adapt production to a decaying enemy fleet composition estimate plus immediate base-defense pressure, normalized over available roster roles.
- Discount distant short-range strength; exclude servicing/withdrawing hulls from available support.
- Release surplus home screens to escort bombers, keep the escort on its bomber's front, and bypass the target-retention veto that silently restored guard duty.
- Replace unconditional operation timers with sustained lack of objective progress; healing chip damage cannot perpetually renew a stalled siege.
- Armed beam escorts count as surviving siege assets after bomber loss. Fighter screens cover the remaining strike anchor when no suitable hostile remains, including during exploitation, rather than receiving an immune base target and being sent home.
- Separate strategic defense from emergency spending: covered station pressure keeps capital savings; insufficient assigned defender strength/arrival or critical station hull releases the bank for counters.
- Tested and rejected an additional capital-investment latch: the paired control built an Orion while the candidate did not and had worse base/fleet outcomes. Restored adaptive investment and the original saving-window regression; failed candidate/evidence remain outside the mod.
- Separate static artillery's station damage from capital beams: 2.5% command factor, retaining 10% fleet armor and 25% capital-beam station damage. Preserve sentry range and ordinary ship damage.
- Added regressions through the real planner and production picker, isolated mutation checks, matched and held-out combat batches, and upstream checks. Final balance validation is in progress; no trained ML model or engine dependency is added.

Evidence, limits and research references: [Development](DEVELOPMENT.md#ai-rebalancing-and-research--8-october-2026).

## Selectable faction starts — 8 October 2026

- Added Circle (default), Star and Multiple Circles to setup. All layouts support 2–12 teams, preserve selected minimum station separation, center the formation and expand map bounds with spawn clearance.
- Multiple Circles uses two clusters, or three from nine teams. Small counts degrade into smaller clusters/pairs. Star/cluster positions are tactically asymmetric; no equal-win-rate claim.
- Stations and newly produced units face local opponents on non-circle maps; AI prioritizes nearby fronts and advances outward once local stations fall. Circle targeting keeps its existing ring behavior.
- Layout changes are restricted to pre-battle setup; new rows retain space for faction controls at 720p/1080p. Reset restores Circle. Fixed the older Gold-only two-team placement and experiment rotation failing to move third/later factions.
- Headless runs and native faction probes accept `--layout circle|star|multi-circle`, freeze it in setup/plan data and reject changing it on resume.
- Exhaustive geometry checks cover three layouts × eleven faction counts × four distances; native Star and Multiple Circles setups/matches pass on upstream. Details in [Development](DEVELOPMENT.md#selectable-start-layouts--8-october-2026).

## Version 1.4.5 — 8 October 2026

Updated the local version and moved the full working checkout to `RTS-fleet-command-1.4.5`, preserving Git history and uncommitted work. Updated active launcher/diagnostic paths and the interactive junction. Historical frozen experiments retain their original paths. The prior directory is an empty shell held open by the current terminal/Codex session; remove it after reopening the new checkout. This is a local development update, not a published package.

## Apollo probe and balance follow-up — 8 October 2026

- Fixed the Apollo movement probe's deadline: accumulate capped physics dt instead of mission time advanced by loading stalls. Retail and MediaVP Apollo controls pass; root's standard six-faction probe passes all five FS1 flight controls. No ship/model/engine fix was needed.
- Rejected and reverted a sentry-placement experiment that improved one matchup but caused earlier base destruction in another. Lower replacement churn alone was a misleading success measure.
- GTA/Shivan and GTI/Shivan both build capitals; universal starvation is disproved. Profile-specific defensive spending and full balance remain open. Restored runtime suite: **1003 passed**. Current upstream HEAD is unchanged; no new gameplay retune/dependency/deployment retained.

Exact evidence, failed experiments and repeat commands are in [Development](DEVELOPMENT.md#apollo-clock-diagnosis-and-rejected-placement-experiment--8-october-2026).

## Cross-model follow-up and root review — 7 October 2026

- Deferred unused service context/weapon scoring and friendly-pair target-policy reads while retaining active repairs and hostile checks.
- Fixed emergency edge memory lost when strategic evidence snapshots were replaced; producer state now owns it.
- Fixed stationless movement/pursuit crashing when an absent station became `false` instead of a vector/nil center. Root reproduced it before fixing the shared waypoint path.
- Extended the native command probe through requested-capital capacity wait, real income saving, exact queue payment, one completed hull and popup selection. Final upstream `root-command-reviewed-01` passes the full combined scenario.
- Refreshed UI/runtime and retail/MediaVP environment evidence. Current geometry passes; final pixels remain unverified. MediaVP environment checks passed, but its broader Apollo movement check failed and remains open.

Final suite: **1003 tests pass**, plus parse/global/scope checks and clean diff whitespace. Performance improves in the paired crowded/pilot probes, with mixed normal-speed evidence. Extended PvN/Shivan experiments build a PvN capital but retain Shivan funding alarms and no natural winner; full balance remains unproven. Exact evidence and limitations are in [Development](DEVELOPMENT.md#cross-model-implementation-and-root-review--7-october-2026). No pricing, engine patch, dependency or deployment change.

## UI audit fixes and spacing — 7 October 2026

Fixed the eight issues found in the 17-window-capture audit, plus the AI-button/type-badge spacing example:

- Native pilot comms temporarily hide the custom information panel and restore it when the menu closes. World hover inspection stops over RTS UI panels.
- Announcements, status messages and new-unit selection notices use the free center column; notices stack and avoid map chrome and the control legend.
- Shieldless capital hulls use the cached real-ship portrait at native shield-gauge coordinates, with real hull health. Shielded craft retain the native quadrant gauges. Overrides restore on possession exit/reset. Upstream's lookup names are singular (`Player shield`, `Target shield`), unlike the table-parser labels; a native regression now verifies that contract.
- Custom UI uses the existing sharp eleven-pixel retail font03, scoped/restored around drawing. The existing large outcome font stays unchanged. Repeated faction/wing labels are removed from ship identity text; formation descriptions wrap.
- Capital cycles display every weapon type with readable names. Selected-target and local-gunner information are separate, and compact optional hints reserve space above lower native gauges. Empty secondary batteries do not advertise an unusable secondary binding.
- Close selected same-class fighters/bombers use a counted bracket and the most damaged member's hull bar. Different classes and distant contacts remain separate; picking, selection, commands and tactical-map markers retain their real positions.
- Shared panel padding is 12 pixels, button padding and section gaps are 8 pixels at normal scale. Button labels center using measured glyph height. Build names and cost/time use separate lines; the AI button has an 8-pixel gap to the ship-type badge and 8-pixel vertical padding. Compact viewports may show fewer build rows; normal paging preserves access.
- Help now states Space pauses and Esc opens the RTS exit menu. Quick-group labels/counts and pilot sections have measured separation.

Verification: **999 tests pass**, nine selected UI mutations all go RED, runtime parse/global/scope checks pass, and `git diff --check` is clean. Current upstream native feedback/portrait probes pass (`ui-fixes-final`, `ui-spacing-final` at 1280×720 and 1706×960), as does native wing/group comm and command ownership (`ui-comm-final`). No engine patch, new font asset or dependency was added.

The capture helper reported a physical-Escape stop during follow-up inspection. Computer-use actions stopped; final-code pixel/spacing screenshots have not been recaptured. Geometry and native runtime passes do not replace that remaining visual check.

## Solo batched verification and follow-up — 7 October 2026

The latest suite passes **989 tests**; 21 selected removal guards were falsified. Current upstream HEAD `242eb19ef5516f704febf4fdb5867b4ed5ed3ef7` builds and runs the native lifecycle, command/service, extraction, capital/sentry/armor, faction/content/audio and stress probes. Exact tags and limitations are in [Development](DEVELOPMENT.md#batched-verification--7-october-2026).

- Fixed duplicated pilot countermeasures using the upstream post-launch hook: one native decoy, real-hull ownership and one ammo deduction. Native shield/energy transfer and proxy recharge checks also pass.
- Fixed battle/display boundary contamination, excluded-hostile support accounting, immediate requested-build CP reservation, and continued draw/final survivor victory. RTS Exit renders a Resume/Restart/Quit dialog; this is a mod-owned dialog because upstream's scripting API exposes no direct native Escape-popup call.
- Reused spatial coordinates and cached IFF inside the synchronous AI context while retaining live permission/team checks. Deferred healthy recovery pressure scans until useful. The 193-unit crowded update median improved 330.74→259.56 ms and pilot 432.77→312.56 ms; large spikes and expensive world HUD rendering remain.
- Corrected combat analyzer false failures from purchases after the last economy snapshot and roster-specific capital unlocks. Three nine-faction experimental runs complete 900 seconds without engine-log errors, with actual service work, but leave capital-funding/composition concerns and no natural winner. Full balance is unproven.

Physical input/pixel-quality/monitor-bound verification and current MediaVP listening/art inspection remain open. No deployment, engine patch or added dependency occurred.

## Fleet preservation, content and integration — 7 October 2026

- Fixed pilot pause/exit ownership; Escape resumes a paused pilot and returns to command view. Space pauses only RTS, and speed controls work in either view. Sentries can be placed in 3D with station bounds and placement previews.
- Added requested Auto Mode builds using the existing budget and queue: save for one selected hull, preserve emergency defenses, wait for capacity, cancel with the normal refund path.
- Added Apollo, Valkyrie, Athena, Anubis and Shaitan with attributed FSPort assets and retail weapon references. Added the custom Shivan three-red-dot badge, 21 selectable/random music cues and 36 nebula backdrops. No FSPort or modified-engine runtime dependency.
- Implemented the connected [gameplay philosophy](PHILOSOPHY_AND_GAMEPLAY_RECOMMENDATIONS.md): factual ship/wing histories, service and pilot records, recovery notices, distinct player/global/fleet outcomes, physical withdrawal, vulnerable passage and paginated reports. After station loss, most defeated AI mobile units extract while a healthy armed cover wing or ship retaliates; living-base factions do not auto-extract. Escape is credited only by confirmed departure. Later losses retain the original strategic result; final fleet reports omit Continue.
- Automatic passage interception now installs a real attack goal; assigning the native target alone did not fire. Interception respects effective reach and explicit command ownership. Terminal cleanup releases target, turret, pursuit, extraction and rearguard references.
- Added post-station-loss AI extraction with a rearguard: the rest of the defeated mobile fleet routes to extraction and attempts upstream `warpOut()` at its departure point. Active factions are excluded; player withdrawal remains an explicit choice.
- Fixed recovery/control overlap, missing click regions, stale interactive regions after HUD early returns, and the scene-picker crash when unselected music inherited a larger nebula index. Healthy idle ships avoid unused threat scans; focused ships retain the prior danger window and active service retains safety checks.
- Capital beams deal 25% damage to Command Hull versus 10% to fleet Base Hull, confirmed twice with paired native targets. The Cyclops control discrepancy was probe geometry: impacts outside its full-damage shockwave core. Equal small targets inside that core pass the unchanged assertion.

The solo follow-up found additional defects: five new FS1 hulls had zero-default handling/power/weapon energy; Exit used a plain pause event; extraction widened active combat bounds; protected hostile contacts counted as friendly support; proxy weapon transfers were discarded; music paused unrelated voice streams; full-cap requested builds were rejected; and Resume could not earn its promised later draw/victory. Corrections are coded, with a visible shared exit dialog, full FS1 handling/reactors, separate arena bounds, preserved hostile classification, real energy ownership, owned-stream mute, cap waiting and separate continued outcomes.

Verification is pending for this coding pass. The completed pre-review baseline was **973 passed / 4 failed**. Earlier native evidence remains valid only for its named snapshot. The old exit-menu probe checked `GS_STATE_GAME_PAUSED` and therefore proved the wrong screen. Current upstream HEAD fetched for the new pass is `242eb19ef5516f704febf4fdb5867b4ed5ed3ef7`. The full pending inventory is in [Development](DEVELOPMENT.md).

Remaining: the nine-faction 900-second run completed but exposed stalled engagement with no base commitment; investigation continues. Crowded 193-unit performance remains costly, and audio listening plus interactive pixel QA are not established by these probes.

Important new files: `fs2rts_fleet_life.lua`, `fs2rts_environment.lua`, `fs2rts-passage-iff.tbm`, the FS1 hull/assets/credits and the extraction probe. Integrations are in lifecycle, HUD/input, orders, service, production, strategy/planning and station modules.

## Political factions and startup repairs — 6 October 2026

- Nine selectable identities: GTA, GTVA, PVN, Vasudan Empire, NTF, loyal/rogue GTI, Hammer of Light and Shivans. Mirror factions, individual randomization and 2–12 total teams remain supported.
- Curated cross-era rosters and nine paid abilities reuse retail hulls and the shared purchase/fleet-cap rules. Added Fenris, Hades, Boadicea and Iceni; Hades has a 40,000 CP floor. Reinforcement waves charge normal purchase value or more, require all slots, refund only missing hulls and create selectable arrival notifications. Role-limited surges cannot stack or activate without CP/eligible ships.
- Classic Orion/Typhon prices are 9,200/7,800 CP across all factions. Fixed completed savings buying cheap fighters instead of the intended capital when a roster has no newest-tier hull. Paid AI abilities now respect the existing bounded fleet-saving gate; manual abilities and sentry defense remain available.
- Random and selectable colors remain unique: occupied swatches swap between teams. Visible faction names replace color labels; internal slot IDs remain compatible with old scripts/logs.
- Bundled faction badges from FreeSpace Port, including the approved Silent Threat: Reborn GTI mark. Shivans use a stock briefing icon. Attribution is included; no new engine or mod dependency.
- Fixed the native 32-byte ship-name buffer overflow in the shared creation path. Bounded unique names cover player builds, AI production, reinforcements and sentries.
- Fixed mission-load failure caused by the old station name in a redundant native goal. Removed that fixed goal; the RTS lifecycle owns elimination/Resume results, and native tactical directive events remain.
- Clean upstream HEAD `45b9d31d769c830a8eacb56c23717f939e573d96` was rebuilt. Twelve-team faction/model/ability/color/insignia/savings, lifecycle/restart and command/service/pilot probes passed. Nine targeted mutations were killed; long-game matchup balance remains unproven.
- Final checks: 923 tests and all three Lua static checks passed. Both final 2,400-second PVN–Shivan replays completed without crashes/Lua errors and with CP accounting reconciled. PVN capital production improved from neither run to both; one Shivan capital-saving failure remains. The runs reached their caps, not natural battle results.

Important files: `fs2rts_config.lua`, `fs2rts_factions.lua`, `fs2rts_ai_production.lua`, `fs2rts_production.lua`, `fs2rts_station.lua`, `fs2rts_hud.lua`, `fs2rts_input.lua`, `fs2rts_lifecycle.lua`, `fs2rts_ui_text.lua`, `FS2_RTS_Escalation.fs2`, insignia maps, retail table parser, native faction probe and experiment scenario setup. Exact evidence and remaining concerns are in [Development](DEVELOPMENT.md#current-implementation-and-verification-2026-10-06).

## Command and pilot follow-up — 5 October 2026

- Player Move/Hold keep ownership through damage and arrival; automatic critical-hull recovery no longer overrides explicit orders. Combat/release restore normal native reactions.
- Isolated automatic fighters regroup with support before solo attacks against fortified targets; guard/escort pursuit is bounded.
- All three stations use dedicated 6 km beam acquisition and active-ray profiles. Fleet capital beams retain their ranges.
- Service withdraws immediately, repairs lost travel goals, supports four small ships or two capitals, and reserves separated pads even at arena edges. Manual refit repairs fully and begins promptly at a quiet pad; nearby contacts alone do not block it.
- Pilot projectiles use target/lead vectors; deferred swarm launches are corrected without changing native salvo timing/homing. Battery, estimated weapon cycles and targeting have separate visual sections.
- 1–4 recall groups, Shift+1–4 assign, and Alt+1/2/3/4/0 controls speed. F1–F4 RTS bindings are removed.
- Pilot comm applies to the logical wing or containing control group. Depart is blocked for everyone; bases/proxy cannot be grouped.

Primary runtime files: `fs2rts_orders.lua`, `fs2rts_service.lua`, `fs2rts_pilot.lua`, `fs2rts_player_wing.lua`, `fs2rts_ai_planning.lua`, `fs2rts_strategy.lua`, `fs2rts_hud.lua`, `fs2rts_input.lua`, `fs2rts_selection.lua`, `fs2rts_lifecycle.lua`, `fs2rts_factions.lua`, `fs2rts_config.lua`, the station/beam tables and SCT comm hook. Added `command_service_probe.lua` and the sibling launcher's `--kind commands` path.

## Player faction and free-for-all setup — 5 October 2026

- Setup selects 2–12 total teams including the player; each team independently chooses Terran, Shivan, Vasudan or Random. Duplicate species remain hostile on separate IFF teams.
- Station classes, AI rosters, sentry hulls, command abilities, HUD labels and ship/map colors follow the selected species/team. Stations use a regular N-gon layout with the chosen neighbor distance; camera/map bounds scale to fit.
- The species picker is paged and responsive on short screens; the total-faction count has increment/decrement controls.
- Added nine colored hostile IFFs and matching team-color entries. `+All Teams Attack` extends native hostility to every active team. The 12-team cap was chosen after modified-engine performance probes: 12 factions simulated faster than real time; 27 fell to 0.69x.
- The headless acceptance driver and analyzers now preserve per-faction selection and discover dynamic faction IDs. One 900-second six-way mirror run completed at the cap with all bases alive and CP flow reconciled. Longer experimental six-way runs hit engine crashes; an upstream native 16x match isolated the crash to FSO's missile-evade code. No engine changes were made.
- Final continuity check: 909 tests and the parser, undefined-global and Lua-scope checks passed. The order-wing fixture failure was caused by a missing `IsCommandStation` test stub; both regressions pass with the fixture contract restored.

891 tests/static checks, twelve isolated killed mutations and native command/comm/capital/lifecycle/rendered probes passed. A short headless match completed, but its economy/roster invariant report has unresolved verdicts; it is not a clean long-game balance result. Cooldowns are estimates and all-hull refit pathfinding/pixel readability remain unproven. The mod uses current upstream APIs, with no engine patch dependency. [Development notes](DEVELOPMENT.md#command-refit-and-pilot-follow-up-2026-10-05) retain exact evidence, failed experiments and limitations.

## Match flow and results

- Removed the 30/60-minute presets, countdown targets and timed attrition outcomes.
- Added one shared escalation schedule; normal matches end through station destruction.
- Fixed same-frame station losses so results are decided after all deaths are processed.
- Added **Resume // Survivors** after victory, defeat or draw.
- Resumed battles allow observation, commands and possession, but disable construction, queued completions, upgrades, income, abilities and refitting.
- Eliminated factions retain their ships and hostility.
- Destroying all remaining command stations produces a draw.
- Added **Battle Report** to reopen the paused report. Restart clears the survivor phase and restores normal play.
- Prevented resumed results from immediately reopening every frame.

## Movement, formations and targeting

- Dragged movement now uses the requested facing to orient formations: lines run perpendicular to the ships' heading.
- Ships receive parallel final headings instead of converging on one facing point.
- Tightened spacing while preserving clearance between different hull sizes.
- Arena-edge handling translates the formation rather than compressing ships together.
- Attack approaches loosely preserve the selected formation, then release close-combat steering.
- Manual capital attacks now use refreshed pursuit waypoints against all hull types where native attack orders otherwise leave them parked. Approach points preserve both hull radii plus a 600 m buffer.
- Retasking removes old pursuit state; pursuit refresh preserves the command's priority.
- Fixed lookup of ships created during the current engine frame, with validation of signature inputs.

## Direct ship control

- Possession now suppresses native AI steering through `PLAY_DEAD`.
- Capital turrets rotate and fire through explicit upstream APIs; automatic turret firing remains locked during possession. Short-range/out-of-arc batteries acquire local hostiles while retaining the pilot's selected hull target. Firing still requires the pilot's trigger.
- Fixed primary/secondary trigger handling for capitals without conventional ship weapon banks.
- Added native weapon-cycle support for turret-group selection.
- Fixed flak firing distance.
- Improved subsystem targeting, whole-hull targeting and cleanup of forced turret targets. Native commands and per-bank counters use unique `CanonicalName` identifiers rather than shared HUD turret labels.
- Preserved native turret locks when releasing control.
- Mirrored directional shield segments and ETS settings.
- Added generated capital silhouettes to the native shield gauge.
- Hid the misleading native empty weapons display during turret control and added loaded-bank counts.
- Restored the native weapons gauge on release/reset without retaining gauge handles across missions.
- Tuned the pilot panel to show actual remapped firing bindings, named subsystem aim, group/aim controls and per-category loaded-bank counts/ranges. Empty batteries are marked EMPTY; held input is explicitly distinguished from shot confirmation. Text wraps to the panel and preserves the exit key on short screens.

## HUD, map and inspection

- Unified map and reticle icons around basic geometric shapes, including a distinct juggernaut shape.
- Positioned type icons inside the reticle's upper-left corner with consistent scaling.
- Kept icons visible at distant zoom and under contact-density culling; density culling now applies to hull bars only.
- Corrected production-letter centering.
- Fixed selection rows overlapping the control legend.
- Added ship class/type to hover information.
- Removed enemy order details, tactical rationale, target links, service information, weapon ranges and predicted courses from inspection.
- Separated friendly controller information from tactical rationale.
- Replaced scaled result-title textures with direct rendering in the existing large retail font, improving contrast and centering. No new font asset was introduced.
- Removed the intro's per-shot loading bar and counter.
- Added a survivors-only panel in place of purchase controls during resumed combat.
- Added **F10** to toggle control hints in RTS and pilot views. Hints default off and the preference survives transitions/restarts; operational status remains visible.
- Added pilot tactical task, target/rally, phase/posture and rationale to FreeSpace's native directives panel through mission-event `DirectiveText`. Live wing assignments, the last AI assignment and prior manual orders are labeled separately. No generic base-destruction reminder or custom objectives box is used.
- Kept a visible hints-toggle notice while hints are off. Pilot objectives now include target identity, movement coordinates, distance and steering angles, plus a yellow objective marker. Unassigned pilots receive a labeled hostile-contact suggestion without changing their weapon target.
- Restricted native pilot comm commands to logical wingmates. Broadcasts cannot depart the station, possessed hull, observer proxy or unrelated ships; blocked commands show pilot feedback. Native wing commands containing protected members are rejected, so use individual wingmates under Ships.
- Changed the hint toggle to **F10**. Bounded each native directive event to two measured lines so its continuation cannot spill past the retail frame. C now opens the filtered wing command list directly, and the pilot panel shows the wingmate count.
- Routed capital bank-cycle bindings through upstream scripting overrides to suppress native empty-bank messages. Added beam-specific target/range feedback. Initial category-level experiments observed beam and projectile fire; later per-bank checks exposed barrel alignment and model-point aiming failures. These now guard beam cooldowns and permit local gunner targets when a large hull straddles the cone.
- Fixed armed sentry placement being diverted to box selection when the mouse moved. Added a sentry-only 6 km interceptor laser, retaining the anti-capital cannon's target restrictions and the original fighter weapons.
- Fixed the crash after faction station loss: survivor attack orders now carry assignment/installation timestamps, retained while the objective is unchanged.

## Weapon ranges and AI calculations

- Replaced guessed beam ranges with native weapon-data calculations.
- Shared range calculations between HUD and AI.
- Distinguished primary, secondary and beam ranges, with separate colors and numeric readouts.
- Excluded empty magazines, unavailable banks, locked guns and destroyed turrets.
- Removed the screen-space range-ring cap; rings now project their actual world geometry.
- Corrected beam firepower estimates for upstream's 170 ms damage interval, including cooldown/duty-cycle considerations.
- Fixed operation timing that counted recovery gaps twice.
- Fixed the threat-drop baseline used to trigger counterattacks.
- Added a survivor combat director for stationless factions and resumed battles, respecting player orders and possession.

Range displays describe maximum loaded firing envelopes. Native arcs, target restrictions and beam patterns still affect actual shots and subsystem damage.

## Balance and production

- Disabled Faustus construction for the player and Blue AI.
- Set purchase floors to **60,000 CP for Sathanas**, **40,000 CP for Colossus** and **35,000 CP for Lucifer**, with corresponding construction-time increases.
- A Sathanas has **1,500 base simulation seconds** of construction before build, logistics and difficulty modifiers.
- Flattened tier price multipliers to **1 / 1.5 / 1.75 / 2 / 2**.
- Removed Ravana and Hatshepsut's special 70% discounts.
- Made Gold's Sobek reinforcement cost **6,000 CP**, with a **300-second cooldown**.
- Reduced station base hull to **60,000 before modifiers**.
- Changed default station spacing to **12 km**, retaining wider options.
- Enabled protection of capital savings from station investment.
- Included Blue's actual income in savings decisions and made affordable savings goals complete their intended purchase.
- Limited ammunition-only service recalls so otherwise armed fleets do not accumulate in an unlimited rear-area queue. Bombers, unarmed craft, hull emergencies and manual service retain recovery priority.

## Sentries

- Kept sentries and revised their loadout and behavior.
- Added close-defense lasers alongside long-range cannons.
- Made platforms slew toward nearby hostiles.
- Scaled turret durability with purchased hull durability instead of retaining the retail 4 HP.
- Reduced tier prices and revised base hull values:

| Tier | CP | Hull before upgrades |
| --- | ---: | ---: |
| 1 | 250 | 600 |
| 2 | 375 | 900 |
| 3 | 500 | 1,200 |
| 4 | 1,250 | 3,000 |

- Corrected cannon range to **11 km**. That range does not apply to the close-defense laser.
- Applied the station's **0.10 armor multiplier** separately to cannon impact and blast damage.

## Lifecycle, spawning and input reliability

- Retired completed construction jobs before spawning, preventing exceptions from repeatedly creating ships.
- Retained already-created hulls after initialization errors and refunded only missing hulls.
- Hardened player, AI and reinforcement creation paths.
- Stopped production from using destroyed stations whose engine handles were still valid.
- De-duplicated death accounting and corrected hostile kill-credit attribution.
- Corrected reports to use cumulative spending and actual Blue kill credit, while retaining destroyed-faction rows.
- Cleared mission handles, cameras, gestures, caches and clocks during restart/shutdown.
- Preserved gameplay across native menu round trips.
- Fixed pause/Escape handling, paused speed changes, modifier releases and cinematic-skip click leakage.
- Enabled selection/base focus and chase while paused.
- Stopped repeatedly writing mouse-control mode, which flushed held native input.
- Corrected picking/projection calculations to use the engine's actual screen mapping rather than a guessed FOV model.
- Avoided the native fatal `error()` path when optional audio support is absent.
- Cleared armed placement/command gestures when resuming a result.

## Headless tooling, cleanup and compatibility

- Added a documented launcher for checking, staging, running, resuming, analyzing and probing experiments.
- Added frozen scenario presets, independent worker ports, input hashes and preserved attempt evidence.
- Separated completed processes, simulation caps, natural outcomes and failures. Experiment caps do not decide gameplay results.
- Limited rendered test windows to the primary monitor's work area; oversized requests are reduced and the actual resolution is recorded.
- Corrected accounting analysis for CP peaks between snapshots and unfinished sentry jobs at experiment caps.
- Added sentry job IDs and explicit finish times to telemetry.
- Archived obsolete handoffs, contracts, probes, personal HUD preferences and generated caches rather than discarding historical evidence.
- Updated play, development and headless instructions.
- Made experimental damage-hook support explicitly opt-in rather than inferred from engine version.
- Applied focus-pause handling during intro/setup, preserving intentional native menus and restoring user options on exit.
- Added safe 1280×720 windowed launch defaults and the correct native-video flag spelling. The optional direct shortcut loads live mod files without Knossos, UI automation or test probes.
- Kept ordinary gameplay compatible with upstream FSO without a modified-engine dependency.

Earlier checks used `1db8c586c5e444d8bdf011826185411dd1e7f17e`. Upstream advanced during the follow-up; the clean review engine was rebuilt at `2838d25ab716e9ecedd94d9c40c64fda35cc0632`. Native combat and lifecycle probes passed on that HEAD, including custom station models under the new POF validation. The modified local engine remains an experiment tool. No local engine source patches were added.

## Verification and remaining limits

- The latest full runtime suite completed with **862 passing checks**. An additional canonical-range regression passed separately.
- Ten new in-memory Lua kill checks and one native frozen-snapshot debris-cap mutation failed on their intended assertions. These supplement the earlier mutation coverage below.
- **10 isolated mutation checks** failed on their intended assertions when the corresponding implementations were removed or broken. These cover manual pursuit, persistent role markers, range calculation, service booking, same-frame object lookup, elapsed-time independence, gauge restoration, resumed spending, draw conversion and survivor combat.
- Parse, global, scope and diff-whitespace checks passed.
- Pristine-upstream native probes covered direct control, capital pursuit, formation movement/facing, sentry combat, weapon range, result rendering, restart and survivor-mode lifecycle.
- Native combat proved that a stationless enemy fighter retained hostility and damaged a Blue survivor.
- Native replay proved a resumed defeat can become a draw after the remaining stations are destroyed, without repeatedly reopening the result screen.
- Controlled headless batches retained raw evidence for baseline and balance variants, including natural outcomes, failed attempts and simulation caps.

Equal faction win rates are not statistically established. Some long autonomous matches still reach experiment caps; capped matches are not wins or losses. MediaVPs, full audio and sustained manual flight remain unverified. The capital shield silhouette, expanded pilot panel, fighter reticle/map icons and final defeat-title pixels were inspected. Broad icon coverage across every role/resolution remains incomplete.

The final upstream 4x rush checks left Red at 39,758/51,000 hull (13 of 15 attackers destroyed) and Gold at 48,878/51,000 (all 15 destroyed) at the 900-second experiment cap. Friendly-base dogfight contacts remain possible. Three additional 4000-second experimental-engine runs completed without engine errors, with 63 invariant passes, but none ended naturally. The accounting analyzer's false 0.65% discrepancy was fixed by comparing matching snapshot spans; real mismatches still fail and missing observations get no verdict. Detailed evidence and failed attempts are recorded in [Development](DEVELOPMENT.md).

## Important files and supporting instructions

The later capital/aftermath/rush pass added separate pilot status/control panels, local trigger-controlled flak defense with moving-target lead and actual-muzzle burst correction, and a targetless-beam guard that preserves its cooldown. After Resume, Blue-only surviving assets produce final Victory with no Resume action. Faction report rows distinguish station loss from remaining ships.

Move and refit destinations now clear the owner's station hull. Direct paths crossing it use pooled detour waypoints, preserving formations and native collision physics. Stations use separate armor for hulls and subsystems: 5% routine fighter weapon damage and a 250-damage debris impact cap. Fleet armor and normal ship damage are preserved. Two 6 km interceptor mounts per station prioritize incoming small craft. Overwhelmed active base assaults may recall the full defensive fleet. The paid rush probe records real CP/build timing, defense targets, hulls and friendly-base contacts; it is not a win-rate estimate.

Defeated fleets prioritize surviving assets of the faction credited with the fatal base hit, then other hostiles when those assets are gone. Unknown/environmental killers fall back to normal hostile targeting. Recovery strength counts armed units whose weapons or arrival speed can affect the current fight, retaining damage emergencies and real long-range threats.

| Area | Main files |
| --- | --- |
| Match flow and survivor mode | `core/data/scripts/fs2rts_lifecycle.lua`, `fs2rts_factions.lua`, `fs2rts_ui_text.lua` |
| Movement, pursuit and combat AI | `core/data/scripts/fs2rts_orders.lua`, `fs2rts_strategy.lua`, `fs2rts_operations.lua`, `fs2rts_ai_planning.lua` |
| Possession | `core/data/scripts/fs2rts_pilot.lua` |
| HUD, camera, picking and input | `core/data/scripts/fs2rts_hud.lua`, `fs2rts_input.lua`, `fs2rts_selection.lua`, `fs2rts_camera.lua` |
| Balance, production and service | `core/data/scripts/fs2rts_config.lua`, `fs2rts_production.lua`, `fs2rts_ai_production.lua`, `fs2rts_station.lua`, `fs2rts_service.lua` |
| Telemetry | `core/data/scripts/fs2rts_ai_telemetry.lua`, `fs2rts_ai_util.lua` |
| Ship and weapon patches | `core/data/tables/fs2rts-cannon-wep.tbm`, `fs2rts-sentries-shp.tbm`, `fs2rts-pilot-icons-shp.tbm` |
| Verification and staging | Native probes, regression tests, `prepare_headless_batch.py` and `ai_invariants.py` under `core/tools` |
| Headless entry point | Sibling artifacts folder: `headless/headless.py` and `headless/settings.json` |

- [Play and controls](../core/README.md)
- [Development, invariants and evidence](DEVELOPMENT.md)
- [Headless launch and analysis](../../RTS-fleet-command-artifacts/README.md)
- [Historical cleanup archive](../../RTS-fleet-command-artifacts/archive/cleanup-20261003/README.md)

## Performance review, 5 October

Repeated native ship/signature/team lookups were the main script bottleneck. The frame's positive ship index keeps same-frame creation fallbacks; synchronous AI contexts now reuse positions and faction IFF answers with live team-change fallback. Threat searches reject farther/out-of-range candidates first. Capital gunners reuse turret origins, and map/reticle colors share faction classification. Gameplay cadence, targeting rules and icons are preserved.

Dead logical wings now retire instead of accumulating. Contest history retains current groups, and disabled diagnostic tracing avoids discarded geometry/pair construction. Added operation-count, mutable-IFF, asymmetric-IFF, retargeting and lifetime-churn regressions; corrected inconsistent test fixtures openly.

The latest instrumented upstream crowded comparison reduced script-update median from about 1312 to 605 ms (54%). Capital turret-update mean fell from about 298 to 45 ms. These are stress-fixture script timings, not ordinary-play FPS. HUD improvements were inconsistent; another repeat had severe late-frame spikes. One churn experiment crashed in native missile-evasion indexing and remains unresolved. Full evidence, failed attempts and qualifications are in [Development](DEVELOPMENT.md#performance-pass-2026-10-05).

Primary files for this pass: `fs2rts_factions.lua`, `fs2rts_ai_planning.lua`, `fs2rts_service.lua`, `fs2rts_pilot.lua`, `fs2rts_hud.lua`, `fs2rts_lifecycle.lua`, `test_review_regressions.py` and the opt-in `performance_probe.lua`. The sibling launcher supports reproducible frozen controls with `--kind performance --control-scripts`; profiling is not loaded during normal play. No engine changes, new dependencies or deployments were made.

Verification: 878 full-suite checks, parser/global/scope checks, native lifecycle/restart and actual capital/sentry/armor/debris probes passed. A replacement headless combat run completed the 4000-second experiment cap with 330 produced units and 21 passing invariant verdicts. The initial long attempt was ended by a failed debugger inspection and is retained as invalid. Headless startup now skips the presentation cinematic and records accepted state explicitly.
