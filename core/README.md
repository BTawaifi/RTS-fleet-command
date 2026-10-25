# FreeSpace RTS: Fleet Command

Single-player fleet command with optional direct ship control. Requires retail FreeSpace 2 assets and upstream FreeSpace Open 26.0.1 or a tested newer build. MediaVPs are optional.

## Launch

Select **FreeSpace RTS: Fleet Command** in Knossos. The included campaign/mission is **FS2 RTS - Escalation**. Setup lets you choose 2–12 total teams (including yours), each independently choosing GTA, GTVA, PVN, Vasudan Empire, NTF, loyal GTI, rogue GTI, Hammer of Light, Shivans or **RANDOM**, plus difficulty, economy, station spacing and layout. Mirror factions remain separate hostile teams. The default Circle layout puts six stations on a hexagon and other counts on a regular polygon. Twelve is the practical ceiling based on early-fleet experiments; sustained late-game performance at that count is not established. Click **START ESCALATION** when ready. Fully exit and relaunch after installing script or mission updates.

For a manual GitHub ZIP install, extract the player package into a new folder named `RTS-fleet-command-1.4.6` alongside FS2's retail assets. From the FS2 asset directory, launch your upstream FSO executable with `-mod RTS-fleet-command-1.4.6 -campaign FS2_RTS_Escalation -start_mission FS2_RTS_Escalation`. For optional MediaVPs, install the matching external pack first, then use `-mod RTS-fleet-command-1.4.6/mediavps,RTS-fleet-command-1.4.6,MediaVPs-directory`, replacing the last name with the actual pack folder. The optional patches must load before the core mod and MediaVPs. Configure resolution and window mode in your launcher.

**START LAYOUT** cycles Circle, Star and Multiple Circles. Circle keeps the existing ring; Star alternates outer and inner stations; Multiple Circles creates two clusters, or three with nine or more teams. Small faction counts produce small clusters or pairs. **BASE DISTANCE** is the minimum separation for every layout; the map expands to fit. Layouts apply when you start, never during combat. Star and clustered starts offer different tactical positions; equal faction win rates on these layouts are not established.

Team colors are randomized without duplicates. Click a team's color swatch to choose another; choosing an occupied color swaps the two teams' colors. **RANDOMIZE ALL COLORS** reshuffles them. Color identifies a team independently of its political faction.

Each faction has a curated roster and paid command ability: GTA orbital strike, GTVA joint mobilization, PVN mobile reserves, Vasudan Empire reinforcement jump, NTF raider screen, loyal GTI precision strike, rogue GTI prototype overdrive, Hammer of Light zealous advance and Shivan swarm surge. Identical hulls share prices and build rules across player/AI factions. Reinforcements require room for the whole wave and cannot undercut ordinary purchase prices. FSPort's FS1 models for the Apollo, Valkyrie, Athena, Anubis and Shaitan are bundled under its attributed non-commercial reuse permission with retail-only weapons; FSPort is not a runtime dependency. Matchup win-rate balance remains under evaluation.

Classic destroyers cost 9,200 CP for Orion and 7,800 CP for Typhon. Auto production commits completed savings to the needed role even when that faction has no latest-tier hull. Paid AI abilities respect the bounded fleet-saving window; emergency production can release it for defense.

Setup, station and pilot panels show faction insignias. Six PCX badges are attributed FSPort squad insignias; the custom Shivan badge is three red dots in a triangle, inspired by markings on some Shivan hulls. It is not a canon insignia. Asset attribution and provenance are in `data/maps/README-insignias.txt` and `data/FSPORT-ASSET-CREDITS.txt`.

The battle starts with command stations only. Production creates combat units after starting. Losing your station records player defeat while stations remain; other factions continue their normal economies if you resume. The strategic result is recorded when at most one command station remains (or none, for a draw). There are no match-duration presets or timed outcomes. One fixed escalation schedule unlocks later ships; income grows with escalation.

The result screen distinguishes **YOUR STATION WAS LOST // THE GLOBAL BATTLE CONTINUES** from the first station result. With surviving ships, the paused report offers **WITHDRAW FLEET**. After global station resolution, **CONTINUE** opens combat-only aftermath: construction, queued builds, upgrades, income, abilities, refits and pending strikes stop for all factions. The first station result remains in the report history, but destroying the last enemy station can earn a draw during continued combat. Eliminating every hostile asset while your mobile fleet survives earns final victory. The final report has no Continue action. **BATTLE REPORT** reopens a paused report; Restart restores normal play.

When an AI station falls, a healthy armed cover wing or ship stays to retaliate against the credited killer while the other mobile units route to extraction. Those withdrawals attempt FSO `warpOut()` on arrival; only the native departure callback records an escape. A living station never triggers this automatic extraction. AI survivors receive no production or station service. You may select your own surviving ships and choose **WITHDRAW SELECTED** after your station falls, or choose **WITHDRAW FLEET** from the result report. Explicit withdrawals use marked corridors and can still be intercepted. The result report records present, lost, escaped, stranded, service-recovery and pilot-time facts for this match only.

## Controls

| Input | Action |
| --- | --- |
| LMB / drag | Select a ship / box-select friendly ships |
| Shift + selection | Add/remove selection |
| Double LMB | Select the ship's wing |
| Ctrl + LMB | Select the same class |
| RMB on hostile / friendly / empty space | Attack / guard / formation move |
| MMB drag | Pan camera |
| RMB drag | Set move facing with selected ships; orbit with empty selection |
| WASD / arrows; Shift | Pan; slow pan |
| Wheel; Q / E | Zoom; far / near zoom |
| F / Ctrl+Space; H | Focus selection; focus your station |
| B; Alt + double LMB | Toggle chase; chase the clicked ship |
| 1..4; Shift+1..4 | Recall; assign control groups (also while paused) |
| Alt+1 / 2 / 3 / 4 / 0 | Set 1x / 2x / 4x / 8x / 16x and resume; RTS or pilot |
| + / - | Step speed; while paused, change the resume speed; RTS or pilot |
| Pause | Toggle pause in RTS or pilot mode |
| Space | Pause/resume in RTS mode only; retains native pilot firing behavior |
| Esc | Open Resume/Restart/Quit in RTS; while piloting, resume first if paused and exit to RTS |
| EXIT button (top bar) | Open the same Resume/Restart/Quit menu |
| L / R / T / G | Select all / hold / engage / release orders |
| J / Z / X / V | Default HOLD / RETREAT / STANDOFF / ENGAGE policy |
| M / K | Arm move / attack command |
| C; Shift+C | Battle director; hide/show UI |
| N | Toggle mission music |
| P | Pilot the primary selected friendly movable ship; return to RTS |
| F9 | Show/hide the labeled crew-cost estimates; hidden by default |
| F10 | Toggle control hints on both RTS and pilot screens; off by default |

The minimap supports ship selection, double-click wing selection and box selection. RMB on it focuses the camera. Production, station upgrades, fleet service, sentry placement and speed controls are clickable. Focus, base focus and chase remain available while paused. Arm a sentry from the station panel, then click its position in the 3D view or minimap; the station boundary ring and valid/invalid hover readout show placement limits and clearance.

The **SCENE** picker is available in setup and from the top bar. Choose retail FS2 combat music and a sky backdrop, or select **RANDOM**. Setup starts with a random complete six-face skybox. Backdrops do not add full-nebula fog, reduced visibility or sensor effects. Installed MediaVP OGG replacements take priority over retail WAV tracks.

Choose a formation in the options strip. A ground RMB drag places that formation perpendicular to the requested heading: a line runs across the ships' bows. Ships travel to their slots, then turn to parallel headings and hold them. Attack approaches loosely retain the selected formation, then release steering for close combat. Hull clearance is local to each pair; one capital does not spread the entire fighter screen. Oversized formations use packed ranks or ask for a smaller selection when they cannot fit safely.

Enemy inspection shows identity, ship class/role, hull, shields and speed. Orders, tactical rationale, target links, weapon-range overlays, service state and predicted courses are private to your team.

Map and reticle icons use the same basic geometric shapes. Type icons stay inside each reticle's upper-left corner at every tactical zoom. Friendly hover ranges distinguish primary (cyan), secondary (amber) and beam (violet) reach, with matching numbers. These are maximum loaded firing envelopes; native arcs and target restrictions still apply.

## Fleet control

Auto Mode spends your real CP and commands ships without manual orders. Switching it off refunds its queued build and removes your production director; opposing directors continue. HOLD is the default. Manual orders and possession take priority. A completed manual move holds at its destination; use **G** to release it.

With Auto Mode on, click the small **AI** button beside a production row to ask the player-side AI to save for that ship. It handles one request at a time, shows the request status below the build list and provides **CANCEL REQUEST**. It waits for fleet-cap space; urgent station defense can take a production turn before the request resumes.

Pilot mode uses native FSO flight/targeting/bank controls through an invulnerable, collisionless observer proxy; the real ship takes damage and fires its weapons. Craft destruction shows a short death view before returning to command. Pausing prevents direct simulation commands too. Speed hotkeys work while piloting and while paused.

Capitals start with all eligible turret groups selected: **[ / ]** selects a group and **\\** toggles all groups. Native weapon-cycle controls also select groups. Primary and secondary triggers drive loaded turret banks; the HUD reports their availability. Turrets fire under your control. **O / < / >** and native subsystem targeting direct subsystem aim; weapon patterns and firing arcs still apply. Capital hull silhouettes appear in the native shield gauge.

The pilot panel separates battery, weapon-cycle and targeting status. It shows bank counts and maximum reach for the selected groups. **WEAPON CYCLES (EST.)** shows ready mounts and remaining time based on successful manual shots and the turret fire-rate multiplier; native per-bank cooldowns, random delays and burst timing are not exposed upstream, so these are estimates. The longest cycles appear first; select a battery group to inspect other weapons. Projectile guns use an intercept vector rather than their resting barrel direction. Deferred swarm/corkscrew launches are corrected at launch without changing native homing or salvo timing. Batteries prefer your selected hostile; mounts outside its arc/reach acquire local hostiles. Beams require a hostile target and barrel alignment. Native weapon-bank cycle bindings select turret groups without the proxy's empty-bank messages. Empty batteries are marked EMPTY. The held-input indicator reports input, not hits.

Control hints have their own panel below ship status. Flak keeps a suitable selected fighter/bomber target; otherwise it tracks nearby hostile fighters in its own reach and arc. It leads their motion, using the actual shell launch point and predicted burst distance. Your primary/secondary triggers still control firing; local flak aiming does not replace your selected ship target.

Control hints are hidden initially; a visible **F10 SHOW/HIDE CONTROL HINTS** notice identifies the toggle. The preference carries between pilot/RTS views and mission restarts. During possession, FreeSpace's native directives panel shows the tactical task, target, movement point, distance, left/right and up/down steering angles, phase/posture and AI rationale. A yellow diamond marks the movement point or target when it is in view. Steering angles remain available when it is behind you. **AI WING ORDER** follows your wing's current assignment; **LAST AI ORDER** is the assignment captured when you took control. A prior manual command is labeled **YOUR ORDER**. Without an assignment, **SUGGESTED TASK** uses your selected hostile or an available hostile contact. These directives do not steer, fire or change your selected weapon target.

The native pilot **C** menu opens the command list directly, bypassing the empty native **Wings** category. Its **All Fighters** broadcast is filtered to your logical wing, or your control group when the possessed hull is grouped. A command to an eligible member applies to that whole wing/group, including grouped capitals. If the hull belongs to multiple groups, the lowest-numbered group is used. The pilot panel names the command scope. Your own hull, stations, proxy and unrelated ships are protected. **Depart is disabled for broadcast recipients**; direct withdrawal from the RTS extraction controls is supported. Bases and the proxy cannot join control/logical groups. RTS and AI control regain ownership when possession ends. This uses upstream hooks and does not require dynamic native-wing extensions or engine changes.

In Auto Mode, each build-row **AI** button asks the player-side director to save for and build that specific ship. One request can be active at a time; the request label/status appears below the build list, and **CANCEL REQUEST** cancels it. A full fleet cap delays the request, and urgent station defense may temporarily take production priority.

Faustus transports are excluded from production. Purchase floors are **60,000 CP** for Sathanas, **40,000 CP** for Colossus and Hades, and **35,000 CP** for Lucifer. A Sathanas has **1,500 base simulation seconds** of construction before build/logistics/difficulty modifiers. Tier premiums are shallower; Ravana and Hatshepsut no longer have special 70% discounts.

## Station and economy

CP buys units, upgrades, sentries, service and abilities. Fatal hostile attacks credit kill rewards to the actual faction; friendly fire, self-kills, unknown killers and duplicate callbacks do not pay.

Fighter weapons cause 5% normal damage against command-station hulls and armored turrets: harassment creates pressure, while bombers, escorts and capitals perform serious siege. Fighter rams and unsupported non-strike direct weapons remain blocked. The supported pool covers 44 retail/FSPort fighter weapon variants, including cluster children; third-party weapons require explicit coverage. The optional MediaVP package patches these variants to retain MediaVP weapon ranges and effects. Ordinary fleet targets retain their normal damage in the tested armor cases. Station chip damage interrupts the existing quiet-repair delay and contributes proportionally to the existing damage scars, so clearing attackers restores recovery. Typed wreckage impacts are capped at 250 damage per hit. Each station has two 6 km interceptor mounts. AI defense ranks siege-capable attackers ahead of fighter harassment; fighters remain screens rather than a committed AI siege force. Explicit player fighter attack orders are allowed. Recovery considers nearby weapons that can participate within its danger window. Movement and refit paths keep clearance around their own station and reuse detour waypoints; native contacts remain possible, particularly at high time compression.

| Upgrade track | Main effects |
| --- | --- |
| Armor | Up to +60% maximum hull; all stations recover 2.5% of max hull per 100 seconds after 30 damage-free seconds; level 2 doubles repair rate |
| Defenses | Extra sentry slots, +50% sentry hull, +25% turret fire rate |
| Logistics | Income/build improvements; the player gets a second build lane at level 3 |
| Command | Fleet cap, placement radius/sentry capacity, faction ability |

Passive station hull repair recovers at most 60% of observed damage, leaving permanent scars; station turret subsystems also self-repair at the fleet-service subsystem rate. Both pause for 30 seconds after any hull or turret damage, so bases recover while quiet rather than under active fire. Repairs are disabled after the match ends, including during survivor-only Resume.

Player move commands remain owned after arrival: ships hold there until retasked or released with **G**. Native hit reactions and automatic critical-hull recovery cannot take away an explicit command. Moving/refitting ships do not engage during transit. Automatic isolated fighters regroup with mobile support before attacking a station, heavy hull or multiple close enemies alone; emergency defense, intentional feints and supported attacks remain available. Guard/escort goals have bounded native pursuit ranges.

Fleet service withdraws immediately and repairs hull/subsystems and ammunition for CP at a surviving station. There are four service slots; a capital uses two. Visitors reserve distinct pads with hull clearance. Arrival is physical; travel and queues never bank repair time. Explicit Service aims for full hull/subsystems and ammo, starts on the next work tick at a quiet pad, and pauses after actual damage. A nearby contact alone does not indefinitely block manual work. Automatic recovery retains its conservative threat checks and 90% readiness threshold. Prior orders resume when ready; a fresh command cancels service and possession takes ownership. A critical-hull notice on a player-commanded or piloted ship offers focus or service. Stations use dedicated beam variants with **6 km acquisition range and active ray length**; fleet capital beam ranges are unchanged.

Sentry hulls are Watchdog (Terran), Ankh (Vasudan) and Trident (Shivan), following the faction's species. Each of their two turrets has a dedicated **RTS Sentry Interceptor** laser for small targets out to **6 km**, plus a Vasudan Flux Cannon for large targets out to **11 km**. The interceptor uses faster shots at a lower fire rate than the retail close-defense laser; regular fighters' Subach guns are unchanged. Fixed platforms slew toward nearby attackers. Their gun durability scales with the purchased hull instead of retaining the retail 4 HP. Tiers buy durability, not different weapons:

| Tier | CP | Hull before upgrades |
| --- | --- | --- |
| 1 | 250 | 600 |
| 2 | 375 | 900 |
| 3 | 500 | 1200 |
| 4 | 1250 | 3000 |

The cannon has 11 km native range with slow, unguided shells and retail capital-target flags; this range does not apply to the close-defense laser. Stations apply the existing 0.10 armor multiplier to cannon impact and blast damage. Sentries still need mobile screening against massed attackers. Place within the station's control radius; build sites reserve space and cancel/refund if contested. RMB cancels placement, Shift continues placing, and SELL refunds half the actual price paid. Free sentries refund nothing.

Command level 3 grants the chosen political faction's ability. The modern Vasudan Empire's Sobek jump costs at least **6,000 CP** with a **300-second cooldown**; failed creations refund their share of the purchase. Strikes can damage friendly ships. Surge abilities consume CP and affect only their stated roles; no eligible nearby hulls means no charge or cooldown.

## Crew records and raids

**CREWS** lists live, lost and personally flown hulls with match-local histories and citations. Use ALL, FLOWN, LOST and LIVE filters, then select a row for details; **FOCUS** is a separate action for a present ship. Crew complements and casualty totals are disclosed role-based estimates, not canonical head counts or exact simulated deaths. **F9** reveals their live strip. Named losses and factual honors remain visible without it; awards grant no resources or stat bonuses.

Rare announced splinter raids warp in hostile ships or wings associated with any active faction. They arrive as new combatants; existing ships keep their allegiance. Warnings identify their origin, and the arrivals display TRAITOR labels.

## Configuration

Gameplay settings are in `data/scripts/fs2rts_config.lua`; weapon and station definitions are in `data/tables`. The source repository includes maintainer checks and acceptance criteria. Large late-game fleets, twelve-team matches and high time compression can be expensive; sustained performance and every optional asset/loadout combination still need wider playtesting.

Third-party assets retain their owners' terms. Credits and provenance are in `data/ASSET-CREDITS.txt`, `data/FSPORT-ASSET-CREDITS.txt` and `data/maps/README-insignias.txt`.
