# Continuation handoff — updated 2026-10-09

## Current continuation — ten-percent harassment and optional weapon parity

Latest user instruction replaces the ineffective 1% candidate with **10%**
fighter station damage. Native retail blast/gun controls pass: Trebuchet 31.5
versus matched bomber 315; Subach direct ratio .09925; tested ordinary hull
damage remains 180. The first isolated run failed its obsolete primary-ratio
assertion; corrected final run is chip10-isolated-final-20261009. Do not count
the retained failure as an engine defect or discard it.

Paid rush probes chip10-rush15-20261009 and chip10-rush30-20261009 completed
120.42/120.66 actual attack seconds, both stations alive. Enemy final hulls
50032.3/50234.8 of 51000; attackers remaining 14/26, eight defenders targeting
each rush. No own-base contacts recorded. Separate variable-frame runs are
bounded survival/pressure controls, not a scaling/fairness comparison.

Generator now reads consecutive per-bank Allowed lists as upstream does.
MediaVP 4.7.3 audit scanned 42 tables: 118 covered-source patch entries,
including weapon ranges/effects bypassed by the retail aliases. Optional
mediavps/data/tables/z-rtsf-*-wep.tbm replays those patches on aliases, retaining
chip damage types and mapping spawn children. Audit/generator tool and VP
boundary/newline tests are in core/tools; final focused run: 98 passed.

Native chip10-mv-parity-final passes all 44 loaded Range/Damage/ArmorFactor
comparisons and blast/gun/non-strike/ordinary-hull/cluster controls with MediaVP
assets. Its earlier generator had doubled CRLF in descriptions; normalized
final output passes separate native recheck chip10-mv-clean-final, port7903,
including all44 source comparisons and the same chip/ordinary/cluster controls.
Root native/test sessions are closed. MediaVP itself emits particle-rate warnings;
FSO displays a warning popup even with -noninteractive. The two initial optional
probes timed out at that popup, retained. Computer Use acknowledgement let the
parity probe run. -nomovies avoids unrelated intro media during probes.
Unknown third-party weapons remain outside coverage; optional music/nebula and
visual parity need separate checks. Source parity is not a universal gameplay
damage certificate for arbitrary third-party armor.

The experiment assistant runs the eight-attempt newest-bomber-banking campaign,
predeclared BANKING-VALIDATION-PLAN.md and BANKING-CAMPAIGN-MANIFEST.json in sibling
work/lead-balance-20261008. Both arms share finalized 10% chip and smart selection;
only fs2rts_ai_production.lua differs. Seeds2026101101/1102, both slot orientations.
Modified-engine fixed-step experiments, not pristine upstream CLI support.
At last update: control-original runner session50391 and candidate-original
runner session95311 are active (one worker each). Root native probe completed;
the two experimental workers remain. A temporary three-engine overlap was
recorded transparently when root and helper checked capacity concurrently.
Read the manifest/agent status before resuming. Prior M2 access violation remains
unresolved and must never be replaced by a retry record.

Remaining: complete/evaluate this frozen campaign, finish RTS/pilot/intro/history
pixel review and M4 decision controls, then the deferred player acceptance.
Performance remains parked. The sections below are historical checkpoints.

## Active follow-up — campaign review, 9 October

**Historical one-percent checkpoint (superseded above):** fighters then caused
1% normal station weapon damage. The generator covers 44 primary/secondary
retail/FSPort weapons; native Trebuchet and Subach chip controls pass, while
bomber damage and the tested ordinary-ship damage are preserved. Player fighter
station orders are allowed; CanDamageBase remains the AI siege-role classifier.
Quiet repair/scars still react proportionally to real chip damage. The prior
zero-damage native probes and prior full-suite counts are historical.

Completed validation: chip full battle `lead-native-battle-chip-13` completed
2700 seconds without native failure, commissioned four Taurvis plus four
Shaitans; global result remained unresolved. The missing-variant failure is fixed:
known bundled variants missing or unable to page in request deferred native
weapon deletion; unknown countermeasure/third-party weapons remain distinct.
Final full suite **1114 passed**, one installed dateutil deprecation warning;
durable JUnit is sibling work/lead-balance-20261008/fighter-chip-final-tests.xml.
Paid fifteen-fighter rush `lead-fighter-chip-rush-14` completed with all fifteen
orders accepted and 120.608 simulated attack seconds. Enemy hull was 50955.1 of
51000; eight defenders targeted the rush, nine were present at the last sample.
Both stations survived and no own-base ship collisions were recorded in this
case. This is a bounded native pressure control, not faction fairness.
No current probe/test process remains running; do not resume closed exec IDs.

This checkpoint supersedes the running-job status below. M3 finished all 15
attempts: three natural global results, twelve unresolved caps, no failed engine
records. Its driver failed only during manifest finalization; missing note
properties now use Add-Member -Force, with parser and absent/repeated-property
controls passing. Original failure evidence remains recorded.

Latest continuation: fighter blast protection is implemented in 23 generated
retail/FSPort variants plus recursive cluster children. On upstream 0c0320bb8,
fighter Trebuchet caused zero station hull/subsystem loss, original bomber
Trebuchet caused 315 hull loss and fighter splash still removed 180 hull from
an ordinary hostile. Native Piranha produced fifteen safe children; a missing
launcher suppresses spawning in upstream itself. Root added fail-closed handling
for missing/page-in-failed bundled variants: vanish requests deferred native
deletion instead of restoring forbidden splash. Third-party weapon banks remain
outside the declared coverage.

The first 2700-second upstream battle smoke completed without a crash, but built
only old Shaitan bombers. Affordable-choice preference alone was insufficient:
normal purchases could still drain the newer bomber's savings goal. The revised
candidate banks for the newest unlocked bomber when bomber demand is selected
and income can fund it. Emergency fallback and zero-income/early controls remain.
119 shared selection tests pass after this correction. 213 blast/progression
checks passed before that last banking change. All numbers are scoped evidence.

Historical pre-chip checkpoint: native banking battle smoke
`lead-native-battle-banking-12` completed with eight Taurvis and no native failure;
full suite/JUnit `blast-banking-full-tests.xml` completed 1114 checks before the
user requested chip damage. Prior native smoke `-full-11` is
an earlier candidate and cannot validate the new banking change. Both rendered
smokes use variable-frame 16x and a Lua planner seed, not fixed-dt matched trials.
Their observation caps remain unresolved, not draws or wins.

M2 finished eight attempts: two natural control results, five unresolved caps,
one candidate access violation. No candidate commissioned the predeclared siege
bombers, so the natural-battle criterion is INCONCLUSIVE. Existing combat damage
telemetry DOES identify attacker class: the same-faction station Trebuchet damage
comes from SF Mara, not an eligible bomber. Direct collision protection does not
cover weapon_do_area_effect's global damage path. The experiment assistant is
implementing fighter-only splash variants/command-hull armor protection using
existing upstream APIs; root must review fields, scope and native controls.

Root's new production candidate retains the newest affordable bomber tier when
bomber demand is selected, including emergencies, even when the global tier has
advanced beyond the roster's last bomber tier. Early/unaffordable bomber fallback
and urgent fighter defense are preserved. The new regression fails the exact
frozen original selection; 119 station/rebalance/escalation checks passed. This
candidate has not yet had matched long-battle validation; old cohorts stay frozen.

Upstream HEAD advanced to 0c0320bb87d380047053cdbf6c4e47bec24a3f3e:
four null initializations in multiplayer SEXP readers. Clean checkout was
fast-forwarded and its Release build completed. Earlier native probes remain
evidence for 82e7a0793, not a test of the new binary.

The modified-engine AV independently reproduces at the same t=2006.9434 under
CDB in sibling work/lead-balance-20261008/m2-crash-diagnostic-cdb-02. Dump copied
to m2-crash-02.dmp; m2-crash-stack.log currently has offsets only because the
installed engine PDB is mismatched. Expected PDB GUID
92265a48-03af-400e-87bb-1094e1414b93, age 10; do not force mismatched symbols or
invent a source cause. Diagnostic replicas do not replace failed cohort records.

Next: review/validate blast protection; collect debug-symbol lookup; run focused
native controls on current upstream and a bounded candidate battle comparison.
Performance remains parked. Player usability/final intro pixels remain deferred.

## Stop point — usage handoff, 9 October

**Read this section first; older checkpoints below are historical.**
Active checkout: D:\Games\FreespaceOpen\FS2\RTS-fleet-command-1.4.5.
Preserve the broad dirty tree. Performance is parked. Finish coding/balance
and automated validation before asking for a normal player session; the user
explicitly deferred it. Batch related reads/checks and use compact summaries.

### Latest fix and completed evidence

The Escalation mission's FS2 RETAIL profile disables smart secondary selection.
Upstream code/ai/aicode.cpp therefore excludes Bomber+ missiles when choosing
anti-capital weapons. Trebuchets carry both Huge and Bomber+; loaded Shivan
missiles remained unfired, while Cyclops remained eligible.

Retained minimal fix: core/data/tables/fs2rts-ai-profiles-aip.tbm defines a
separate RTS Fleet Command profile, inheriting upstream base defaults and
enabling $smart secondary weapon selection: YES. The Escalation mission selects
that profile. No retail profile, weapon damage, price or engine source changed.
A temporary Lua/SEXP workaround was fully removed; do not reinstate it.

core/tools/siege_probe.lua tests six bomber and four capital classes at 3 km
and 8 km, each against a separate identical undefended station for 120 simulated
seconds. Attacker invulnerability removes attrition. Arena audit is disabled
only in this outside-arena probe. It records prices, actual weapon/beam creation,
contacts and per-target hull removal. This is not faction-fairness evidence.

Pristine upstream control lead-siege-isolated-05 and final candidate
lead-siege-smart-08 both completed. All six loaded Trebuchet class/range cases
fired in the candidate: 40 launches total versus zero in all six controls.
The final probe asserts actual firing. Reproducible comparison:
D:\Games\FreespaceOpen\FS2\RTS-fleet-command-artifacts\work\lead-balance-20261008\assess_siege.py
and native-siege-selection.json. Script verdict: PASS_NATIVE_SELECTION_MECHANISM.
Earlier probes -02 and -04 failed due to probe arena interference and a wrong
heavy-role expectation; retained as failed probe evidence, not gameplay defects.

Remote upstream HEAD was rechecked this turn:
82e7a0793f39134a48f6ebc873c1d9dd78e8a2b9. Pristine tested binary:
D:\Games\FreespaceOpen\src\fs2open-upstream-review\build-review\bin\Release\fs2_open_26_1_0_x64_AVX2.exe.
Both native control/candidate logs retain the existing invalid intro.mve startup
movie message and shader-uniform warnings. Do not claim wholly error-free logs.
QtFRED checking was not performed: source/runtime verified, not editor-linted.
Mission/new profile line endings are normalized to CRLF without content changes.

### Running jobs and acceptance boundaries

- M1 assessed: 12 completed attempts, four natural global results, eight
  unresolved 2700-second caps, zero failed attempts. Keep snapshots untouched.
- M1 purchase accounting: eight Shivan appearances queued 27 Shaitan jobs
  (108 requested ships, 104 spawned), one Nahema job (four ships), five Molochs,
  and no Nephilim/Seraphim/Ravana purchases. Eight Shaitan selections were
  expired saving-window fallbacks with newer bombers unaffordable; four were
  emergency purchases. Raw distinctions: m1-purchase-accounting.json. This is
  an unresolved composition/affordability lead; missile repair alone is not
  proof it is fixed. Do not buff all guns from the weak Shaitan assay.
- M3 is on the earlier immutable candidate, predating smart selection. Latest
  helper status: 13/15 complete, three natural results/ten caps/zero failures.
  All paired cases and three-circle are complete; four-star seed 2026100912 is
  active, followed by six-multicircle. PIDs are transient: inspect
  current processes rather than relying on an earlier checkpoint.
  Current evidence: sibling work/lead-balance-20261008/M3-RUN-PROGRESS.md and
  M3-CAMPAIGN-MANIFEST.json. The existing driver continues; do not launch a
  duplicate. If stopped, first verify no matching FSO/runner process, then:
  powershell -NoProfile -ExecutionPolicy Bypass -File
  D:\Games\FreespaceOpen\FS2\RTS-fleet-command-artifacts\work\lead-balance-20261008\run-m3-campaign.ps1 -Phase Run
  Driver uses --resume. Caps remain unresolved, never artificial draws.
- Existing GPT-6 Luna Medium helper /root/experiment_assistant continues M3 and
  has frozen the separate eight-attempt profile-only M2 comparison. Root review
  completed launch review and set launch_approved=true. M2 wave 1 is RUNNING:
  original control/candidate concurrently alongside M3, then the two swapped
  cohorts; distinct port ranges avoid overlap. Driver: sibling
  work/lead-balance-20261008/run-m2-siege.ps1. Parent driver and Python duplicate
  guards, engine/runner and frozen-plan hashes, preserved records and per-child
  launch-failure collection were reviewed before launch. At startup Python
  headless PIDs were 34976/19376 and batch PIDs 41636/33220; do not relaunch a
  live driver. Manifest and per-cohort m2-logs are the current status owners.
  This scheduling change preserves each frozen fixed-dt workload and reduces
  wall time. No performance comparison is claimed.
- Completed before final profile: 1103 full-suite checks and 187 analyzer/tool
  checks. Later 229 affected checks passed on the temporary SEXP implementation;
  those do not establish final-profile validation.
- Final-tree full suite completed in exec session 16189: **1107 passed**, zero
  failures/errors/skips, one installed dateutil deprecation warning, with
  PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 and python -m pytest --suite all -q.
  Durable JUnit: sibling work/lead-balance-20261008/smart-secondary-tests.xml.
  Completion was fetched; do not rerun unchanged checks.
  Lua parse check completed: 26 runtime files, zero failures. CRLF-aware
  git diff --check was clean before this doc-only update.
- Native assays are finished. Final intro pixels, wider M4 preservation/risk
  cases, MediaVP parity and normal player usability remain separate gates.
- Extended pristine-upstream `lead-crew-risk-09` completed after resumption:
  paid service/FIFO controls, healthy heavy-hull hostile focus, critically injured
  explicit player guard ownership and stable crew identity all pass. Raw evidence:
  sibling headless/runs/lead-crew-risk-09/base/probe/data/crew-intro-probe.log.
  This is bounded behavior evidence, not optimal AI sacrifice or player usability.

### Exact next steps

1. Full suite and extended native crew probe are finished. Collect current M3
   and M2 summaries; account for every attempt. M3 cannot validate the new
   profile retroactively. Both drivers are already running; preserve them.
2. Freeze separate profile-only M2 paired control/candidate configurations.
   Control: work/lead-balance-20261008/m3-candidate-source. Candidate: identical
   facade with ONLY the new AI-profile table and mission profile selection.
   Planned unused seeds 2026101001/1002, GTA/Shivans original and slot-swap,
   equal economy, 2700 seconds, both variants = eight attempts. Nothing was
   launched in two waves. The helper froze M2-CAMPAIGN-MANIFEST.json with exactly
   two source content changes; root reviewed and approved the driver before any
   outcomes. Do not restage or rewrite immutable input snapshots.
3. Existing campaign telemetry sees resolved impacts/hull damage, not launches
   or misses. Declare attributed Shivan station damage by weapon/class over the
   frozen window as the weaker primary observation. No eligible bomber purchase
   or approach means no campaign evidence of missile improvement. Native firing
   is proven separately. Guard fleet losses/combat, orders, accounting, service
   and results; smart selection also changes anti-bomber weapon choice.
4. Investigate old-bomber affordability fallback only if matched evidence still
   implicates it. Preserve emergency response, faction strengths and crew stakes;
   do not invent arbitrary prices/saving windows or sample repeatedly until green.
5. Finish remaining M4 cases and final intro transition visual inspection.
   Ask for player validation only when the automatic/coding iteration is ready.

Nothing pushed/deployed. Full balance is not DONE.

## Lead implementation checkpoint — 9 October

Active checkout is 1.4.5. M1 uses untouched frozen snapshots under sibling `RTS-fleet-command-artifacts/work/lead-balance-20261008/`: all twelve attempts finished, with four natural global results, eight unresolved caps and no failed attempts. The assistant assessed sidecars, setup/plan hashes and record sequences; repeated full VP-tree rehash is unclaimed. Do not substitute current scripts into those baseline workspaces. M3 candidate freeze is authorized, with its exact reserved seeds. The six-team interaction reservation was amended before outcomes to GTA/PVN/NTF/GTVA/GTI_ROGUE/GTA; old composition is retained in the manifest.

Current candidate fixes automatic service retaining an alive but distant attacker forever. Current local danger now governs release; the latched physical pad is retained. Simultaneous service admissions use labeled role-based crew estimates per occupied slot; older admissions still come first. Two match-local citations require paid recovery followed by confirmed hostile combat, or removal of a threat targeting a committed withdrawal followed by confirmed native escape. No CP/stat bonus, invented head count or beam-contact damage attribution is added. Temporary fighting/retreating hulls now replace the former two-base intro framing and are removed with their projectiles/waypoints before setup.

Pristine upstream `82e7a0793f39134a48f6ebc873c1d9dd78e8a2b9` built successfully. `headless/runs/lead-crew-intro-06/base/probe/data/crew-intro-probe.log` completes the native intro/fire/cleanup/restart/skip, automatic paid recovery/rejoin, both citations including a lost covering contributor, and actual crew-priority hull-work controls. Earlier `lead-crew-intro-05` failed because its probe expected the heavy Hecate to have capital-band exposure; the probe expectation was corrected, not runtime classification. Earlier `-01` checked deferred vanish too early; failed attempts remain preserved.

Full suite completed 1100 checks before the last intro changes; subsequent affected camera/fleet/service/HUD checks completed 173, and latest camera/feedback/HUD/static checks completed 229. Intro-order refusal cleanup has failing-original/green-fixed evidence. Native `lead-crew-intro-08` passes after the user's steering: shots 50% longer, F10 notice only after match start, no final lateral drift/caption flash, fade through black into setup. The closer intro shot was viewed at 1280x720 before that last transition change; final pixels remain unverified after Computer Use stopped on physical Escape. CRLF-aware diff check passes.

Next: run the frozen M3 campaign and inspect its declared outcomes/guardrails; complete the real player session and M4 commitment/preservation cases. Final intro transition viewing remains independent work. Do not claim balanced factions or M1–M6 complete from native mechanism checks. Performance remains parked.

## Resume here — current stop point and shortest route to completion

The active task is a **bounded long-match balance iteration**, governed by [M1–M6 and their status ledger](AI_ACCEPTANCE_AND_INVARIANTS.md#long-match-balance-contract). Next: M1, a frozen 12-run baseline assessment. M2 addresses demonstrated causes; M3 validates retained changes with unused seeds and player/upstream evidence. Crew behavior (M4), initial awards (M5) and the intro (M6) are separate deliverables, not a combined balance-completion gate. The former arbitrary percentage bands and mandatory two-assault adaptation rule are withdrawn. The 53 hard contracts remain. Performance stays parked.

The user established the [scenario premise and intro rewrite](AI_ACCEPTANCE_AND_INVARIANTS.md#scenario-premise-and-revised-introduction): X rival factions become locked into escalating conflict through diplomatic/political/interspecies tensions; each seeks victory and crew survival. The new in-engine combat tableau and captions establish those stakes without inventing a canonical war. Native transitions pass; final closer framing still needs visual inspection. No diplomacy system is implemented.

The user added a required [crew-survival gate](AI_ACCEPTANCE_AND_INVARIANTS.md#crew-survival-lives-are-stakes): every life matters, and ships are living crews rather than expendable CP tokens. Test avoidable-loss prevention, necessary-risk controls, useful recovery, player agency and surviving opposing fleets. Track observed ship fates separately from resource losses; do not fabricate crew-death counts or achieve survival by perpetual hiding. This is documented intent, not a newly implemented personnel model.

The user also requested [courage/sacrifice commendations](AI_ACCEPTANCE_AND_INVARIANTS.md#courage-justified-sacrifice-and-commendations). M5 starts with observable recovery/rejoin and withdrawal-cover citations; other categories remain follow-up. Preserve actual identity and anti-farming controls, with no CP/stat bonuses or campaign persistence. Detection/display/upstream attribution are not implemented yet; this feature has its own DONE gate.

Preservation must also weigh **crew exposure**: larger crewed ships generally carry more people and merit higher protection priority independently of cost/firepower. Use verified information or explicitly labeled estimates. Preserve controls where several smaller crews or the mission justify risking a larger vessel; avoid unconditional capital retreat and fabricated casualty counts. Crew-weighted AI behavior is not implemented/verified yet.

Latest: the four defects found by the user's double-check are fixed and regression-tested. Read [Double-check repairs](DEVELOPMENT.md#double-check-repairs--8-october-2026): 1088 full-suite checks, final shared checks, typed-evidence and spawn assertion kills, and a fresh upstream lifecycle probe. Older checkpoints below are historical. Next remains controlled empirical balance/interaction/MediaVP validation; performance is parked.

### Evidence/spawn follow-up — supersedes the cleanup checkpoint below

Read [Development: evidence and spawn follow-up](DEVELOPMENT.md#evidence-and-spawn-follow-up--8-october-2026). Code now validates frozen run provenance/completion, common metric windows, observed coverage, clocks/sequence/container types, stable build IDs and once-only terminal accounting. The driver resumes personal defeat until global strategic resolution. Congested spawns are rejected before native creation with existing once-only refund/retirement behavior. Experimental equal-budget and named slot-swap controls are available.

Evidence includes a 1060-check full suite plus later parser/shared checks, the full historical mutation audit with seven repairs/re-kills, three new spawn/job kills, isolated tool-seam mutations, two completed experimental matches with verified provenance and correctly inconclusive self-comparison, and a completed pristine-upstream lifecycle probe. Exact files, limitations and CLI/schema changes are in Development. Do not add overlapping test totals. Original failed audit/run outputs remain preserved.

Next: predeclare the causal question/measurements and run controlled, swapped and untouched balance cohorts. No statistical balance, human UI/input or full MediaVP parity claim is supported yet. Performance remains parked. No subagents were used and nothing was deployed.

### Current verification contract — 8 October 2026

Start with **[AI_ACCEPTANCE_AND_INVARIANTS.md](AI_ACCEPTANCE_AND_INVARIANTS.md)**. It is the user's requested findings/target/invariant document and supersedes older “invariant PASS” and comparison-gate interpretations. It identifies 29 findings, seven executable checks (three invariants / four diagnostics), 53 required mod contracts, evidence limits and the next acceptance work.

Verification is now selected with `python -m pytest --suite lua|static|tools|all -q` from 1.4.5. Lua checks are engine doubles; static and tool checks have separate roles. New test files must be classified; an empty selected suite is not a pass. Two weak duplicate static tests and brittle count/numeric pins were pruned; real behavioral and native boundaries were retained.

`ai_invariants.py --require-clean` gates accounting only, returns 2 on unknown evidence, and honors gating with JSON output. Four tuning alarms remain visible as diagnostics. Comparison schema 2 reports NOT_EVALUATED without criteria, INSUFFICIENT_EVIDENCE for empty/corrupt/one-run gated data, and INCONCLUSIVE when selected results do not separate. Default metric directions are neutral. The convenience gate requires an explicit baseline, metric and direction; it no longer selects a September batch or proxy goals automatically. A selected-metric PASS remains a scoped median/MAD heuristic, not gameplay acceptance.

The mutation harness was mechanically compacted, then deliberately hardened to require JUnit passing-original and Python/Lua assertion evidence. Setup/API/runtime errors, skips, missing parameters and timeouts are ERROR, not KILLED; source drift fails its gate. A broken vacuity fixture and two source-string checks were corrected openly. The preserved formatted checkpoint's oracle checks AST, selected helpers and numerical extractors with negative controls; intentional runner changes have separate regression/mutation checks. Evidence/frozen baseline: sibling `work/verification-slim-20261008/`. Gameplay Lua/tables/engine behavior are unchanged in this cleanup; no engine test is claimed merely from tool tests. Final verification is recorded in Development.

Next: validate provenance/completion and per-metric coverage, distinguish personal reports from global outcomes, then run predeclared slot/economy-controlled and untouched validation cohorts. Existing CP-floor/roster alarms are leads, not mandatory spending strategies. Performance stays parked. Do not silently treat fixed seed count, match caps or more tests as evidence of balanced/enjoyable gameplay.

Stop point: this verification cleanup is complete. Final full suite: 1035 passed (562 Lua / 45 static / 428 tools), one pre-existing third-party warning. Twelve deliberate false-pass mutations were killed; two actual Lua guards were falsified with no source drift. Mechanical oracle/recorded-input CLI checks completed, gameplay Lua is unchanged, and configured diff whitespace check is clean. No new engine match or full registry replay is claimed; completion/provenance/null semantics/statistical balance remain next work. No pending process, subagent, deployment or performance work. Exact evidence and scope: [Development](DEVELOPMENT.md#verification-cleanup--8-october-2026).

### AI rebalancing supersedes performance work — 8 October 2026

The user explicitly parked performance fixing and requested full AI rebalancing informed by recent machine-learning research. No subagents are running. Work in `RTS-fleet-command-1.4.5`; do not resume the older performance work queue unless requested.

Current changes: normalized roster-feasible counter composition, a decaying fleet-wide opponent model plus immediate home-threat demand, reach/arrival-weighted local strength with service/withdrawal exclusions, release of surplus home screens for bomber escort (including the previously hidden incumbent-order retention veto), progress-based operation withdrawal, and a separate 2.5% command-station damage factor for static artillery while retaining the 25% capital-beam and 10% fleet armor factors. These are research-informed Lua rules, not a trained neural/Q-learning agent. No new engine API or dependency.

Research, replay commands, comparison limits and tests belong in [Development](DEVELOPMENT.md#ai-rebalancing-and-research--8-october-2026). New experiments and mutation evidence: sibling `RTS-fleet-command-artifacts/work/ai-rebalance-20261008/`; frozen engine runs: `headless/runs/ai-rebalance-*` and `ai-assault-*`. Earlier experiment snapshots below remain historical, including the rejected sentry-placement change.

The AI/layout coding pass is verified: final retained-tree **1024 full-suite tests in 192.48 seconds**, fourteen killed isolated mutations rerun after rejecting the investment latch, 40 conservation/loss checks over seven completed batches, upstream combined command/service/request probe and expanded artillery/capital/battery probe. Three optional assault policies were compared; no compelling gain, so optional static/mobile assault locks stay off. Budget-gate GTI and PvN paired controls/candidates completed; PvN keeps its Typhon/Moloch builds and reduced Shivan station damage, but profile-specific CP-floor/affordability diagnostics remain. Four stalled experimental runs were explicitly stopped and recorded failed. Final runtime matches the completed upstream `ai-layout-complete` snapshot byte-for-byte. No active game process or unfinished test was cited as a pass.

The user also requested selectable starting configurations: setup now has Circle, Star and Multiple Circles; Circle stays default. All support 2–12 teams and preserve minimum station spacing. Non-circle maps orient stations/spawns toward local opponents and AI fronts prioritize nearby stations before expanding. Headless/native CLI supports `--layout circle|star|multi-circle` with frozen resume semantics. Geometry checks span 132 combinations; upstream six-team Star and twelve-team clustered setup probes pass, plus >1,800-s six-team Star/nine-team clustered matches. One Star station was destroyed with mobile survivors; no overall victor was resolved. Native checks establish engine behavior, not final pixels or equal slot/faction win rates.

The final GTI follow-up disproved a universal capital-bank failure on the latest operation/escort behavior: unrestricted control queues/spawns Orion at 1692/1888 s. An extra bounded capital-role latch passed tests but worsened the paired match (no Orion, less offensive pressure, lower home hull), so root rejected/reverted it and its proposed test. Original saving-window test is restored; candidate source/test/mutation evidence is preserved in `work/ai-rebalance-20261008/rejected-investment/` and the frozen `ai-assault-investment-*` runs. Do not reinstate that latch merely because its isolated regression is green.

Next AI work should use longer fresh seeds/slot swaps across the nine profiles and all three layouts, retaining the profile-dependent CP-floor/affordability alarms rather than forcing every faction to buy a capital under any pressure. Keep production conservation, player ownership, actual service and station-loss-only extraction as gates. Do not resume performance work without user instruction; final screenshot/pixel QA and broader MediaVP gameplay remain independent older concerns. No ML network/Q-table was trained: applied research ideas are explicit Lua policies and structured comparative evaluation. No engine dependency, publication or deployment.

### Version/path update — 8 October 2026

Current mod: **1.4.5**, working checkout `D:\Games\FreespaceOpen\FS2\RTS-fleet-command-1.4.5`. The complete directory contents, including `.git` and all existing dirty/untracked work, moved here. Metadata, current documentation, headless settings, the two repeatable isolated diagnostic settings and `interactive/live-rts` junction now use this path; the headless file check passes. Historical frozen experiment paths remain unchanged as provenance.

The old `RTS-fleet-command-1.4.1` directory is empty but locked by the open PowerShell/Codex session (including its child REPLs). Remove only that empty directory after the session is closed or reopened on 1.4.5; there is no second mod copy. All subsequent commands must explicitly set the new working directory. No gameplay code changed for this bump and no package was published.

### Latest completed follow-up — 8 October 2026

Both cross-model workers finished, then root reviewed the final delta against `artifacts/work/next-steps-20261007/baseline`. Only `core/tools/faction_setup_probe.lua` changed; no new gameplay retune is retained. The MediaVP Apollo failure was a probe clock bug: mission time includes compressed loading stalls while physics dt is capped. The probe now settles a post-spawn baseline and accumulates `ba.getMissionFrametime()` for 12 physics seconds, preserving movement/turn/fire thresholds. Retail and MediaVP isolated controls pass; root's standard six-faction `root-factions-physicsdt-final` also passes all five FS1 flight controls with COMPLETE/exit 0. A root in-memory mission-clock mutation goes RED with green control; evidence is `next-steps-20261007/easy/root-gate-mutation.json`.

The safer-static sentry placement candidate was rejected and reverted: it improved GTI/Shivan savings but lost the Shivan base much earlier against PvN. Restored runtime suite **1003 passed**; candidate patches, tests and failed comparisons remain outside the mod in the hard evidence folder. GTA/Shivan and GTI/Shivan controls both built Molochs, disproving universal Shivan capital starvation. Profile-specific replacement-budget/defensive-coverage tradeoffs remain; do not resurrect the rejected selector based only on lower churn.

Next: final-code UI screenshots and physical-input checks after capture access explicitly resumes; bounded faction-balance work preserving useful defensive coverage; measured large-fleet/traced tail optimization. Apollo asset/movement concern is closed to the tested retail/MediaVP controls; full MediaVP multi-faction gameplay and audible/pixel quality are separate. Upstream HEAD rechecked 8 October remains `242eb19ef5516f704febf4fdb5867b4ed5ed3ef7`. No new engine change, dependency or deployment. Details and exact replay commands are in [Development](DEVELOPMENT.md#apollo-clock-diagnosis-and-rejected-placement-experiment--8-october-2026); worker evidence is under `RTS-fleet-command-artifacts/work/next-steps-20261007/{easy,hard}`.

Earlier checkpoints below retain history and are superseded where this follow-up completes their open items.

This section supersedes the older next-step lists below. The plan was recorded without another test batch or gameplay edits; work has now resumed with the user's explicitly requested cross-model delegation below.

### Completed delegation and review — 7 October 2026

Both authorized workers have finished. Root reviewed their changes only after both completed, fixed the newly exposed stationless waypoint bug, and completed native `root-command-reviewed-01` (exit 0, COMPLETE). Final root suite: **1003 passed**, one third-party dateutil warning, 161.35 seconds. Parse/global/scope checks pass. New evidence is in [Development](DEVELOPMENT.md#cross-model-implementation-and-root-review--7-october-2026).

Current stop point: code and combined upstream command/request verification are complete for this delegation. Remaining work is actual final-code UI screenshots/physical input after capture access resumes, Shivan funding/held-out faction balance, large-fleet/traced tail performance with mixed normal-speed evidence, and the MediaVP-only Apollo movement failure. Retail audio/backdrops passed; MediaVP environment checks passed but its whole faction run failed. No claim of full balance or final pixel verification. Earlier queued steps below are historical where this checkpoint completes them.

- `/root/hard_implementation`: GPT-6.1-sol, low reasoning. AI/economy/service/strategy performance and demonstrated capital funding/composition defects; owns the AI/service modules and related tests plus the performance probe.
- `/root/easy_implementation`: GPT-6-Luna, xhigh reasoning. UI spacing/content/runtime checks; owns HUD/input/ui_text/environment, related layout/feedback tests and requested-capital native scenario verification.
- Root monitors and nudges based on progress, but reviews the implementation only after both workers finish. Shared-file changes require coordination. Hard worker initially owns rendered game launches for benchmarks, then releases the slot to easy worker; launches remain sequential.
- Frozen pre-delegation source/test/docs baseline: `D:\Games\FreespaceOpen\FS2\RTS-fleet-command-artifacts\work\delegated-finish-20261007-142815\baseline`; the adjacent manifest records 111 file hashes. Worker evidence goes in sibling `hard/` and `easy/` folders. Earlier solo-only instructions below are superseded by this explicit authorization; no additional forks are requested.

### What we are trying to finish

Finish the upstream-compatible RTS mod review and the original eleven-item expansion, then close the latest pilot/RTS UI audit. The original acceptance inventory is in [DEVELOPMENT.md](DEVELOPMENT.md#solo-review-test-inventory--7-october-2026); implemented changes are in [CHANGE_SUMMARY.md](CHANGE_SUMMARY.md). Preserve elimination-only matches, player command ownership, continued combat after station loss, actual defeated-faction warp-out, and existing working behavior. Full balance and large-fleet performance remain open, rather than being implied by test counts.

### Exact stop point

- The screenshot-driven UI coding pass is implemented: shared padding/section gaps, centered button labels, two-line production rows, an eight-pixel base gap between AI buttons and role badges, notification placement, comm-menu clearance, hover ownership, readable weapon groups, native capital hull portraits, and clustered selected fighter/bomber brackets. Final small edits synchronized selection-header spacing and tooltip padding in `fs2rts_hud.lua` and the layout assertion in `test_hud_layout.py`.
- Recorded evidence is 999 passing tests, nine killed UI mutations, and completed upstream `ui-fixes-final`, `ui-spacing-final`, and `ui-comm-final` probes. Treat these as recorded checkpoints: confirm the final spacing edits are covered before claiming final-tree verification. Native runtime and geometry checks establish behavior, not pixel quality.
- Final-code screenshots are still pending. The computer-use helper reported a physical-Escape stop; UI automation stopped. The original 17 captures and intermediate capital portrait capture precede the final fixes and are not after images. Resume computer use only after the user explicitly restarts it.
- This is a large dirty working tree, with prior modified/deleted/untracked files. Keep it intact. The two agents above are now explicitly authorized; older subagents remain closed. No commit, push, deployment, engine patch, or new dependency is part of this stop.

### Next steps, in execution order

| Step | Work and proof required | Stop condition |
| --- | --- | --- |
| 1. Close final UI code verification | Run the existing full suite and parse/global/scope checks once on the final tree. Recheck the nine UI mutations if their implementation/test anchors changed. Repeat native feedback and comm probes only for code newer than the recorded snapshots. Save logs under the sibling artifacts folder. | Every cited command has finished; failures are fixed and relevant checks rerun. |
| 2. Inspect actual UI | After computer use resumes, capture pilot fighter/capital, native comm, hints on/off, production rows/tooltips, selection/quick groups, map/3D placement, pause/Exit, victory/defeat and resumed final victory. Check 720p, the fitted larger window, and an available ultrawide configuration; use actual window dimensions. Inspect long names, AI/badge separation, borders, margins, wrap, glyph centering, contrast and native portrait size. | Current-code images show legible controls inside one monitor; mouse/keyboard paths work. If capture access remains unavailable, report this as unverified rather than repeat failed automation. |
| 3. Finish the remaining runtime scenario | Prove a requested capital is saved for, queued, built and selectable while Auto Mode continues. Include emergency interruption, capacity wait/cancel and station-loss controls. Check current MediaVP music/backdrop overrides and listen to playback when installed; retain retail fallback evidence. | Queue-to-completion and cleanup work on upstream; asset/listening results are recorded separately. |
| 4. Reduce measured stalls | Use the existing performance probe and frozen controls to isolate faction scoring, service admission and world overlays. Optimize the largest measured contributor first. Compare the same crowded/pilot/paused/normal-speed/churn workloads; preserve immediate manual orders, privacy, service and HUD detail. | Record before/after median and tail timings; no behavioral regression. Explicitly retain any unresolved large-fleet cost. |
| 5. Resolve AI economy and balance concerns | Inspect the 42 FAIL / 30 WARN verdicts from `solo-ai-nine-01`; reproduce each relevant mechanism before changing thresholds or logic. Run longer held-out matchups beyond each roster's actual capital unlock/affordability window. Batch faction mirrors/cross-species, bomber siege/base defense, outmatched service/rejoin, manual command override and defeated withdrawal. Repeat final-code long combat after tuning. | Economy/queue conservation stays clean; specific funding/composition failures are explained or fixed; fleet engagement and natural-elimination results are reported without calling capped runs wins. |
| 6. Close the review | Read the final diff and added files; search changed contracts/callers. Run only checks made stale by the last changes, then `git diff --check`. Update this handoff, Development and Change Summary with exact artifacts and remaining concerns. | Provide the user's requested issues/fixes/files/tests/concerns/upstream-status report. No running check is called a pass and no unresolved concern is silently dropped. |

### Start commands and evidence locations

Run from `D:\Games\FreespaceOpen\FS2\RTS-fleet-command-1.4.5`. Execute commands separately and check each exit code. The existing runner's `--help` and `settings.json` define the current configured engines and staging paths.

```powershell
$env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = '1'
python -m pytest core/tools -q --tb=short
python core/tools/parse_check.py
python core/tools/undefined_global_check.py
python core/tools/lua_scope_order_check.py
git diff --check
```

Current-code upstream probes, if step 1 finds the recorded snapshots precede final edits:

```powershell
python 'D:\Games\FreespaceOpen\FS2\RTS-fleet-command-artifacts\headless\headless.py' probe ui-spacing-checked --kind feedback --rendered --resolution 1920x1080 --ui-seconds 3 --port 58630
python 'D:\Games\FreespaceOpen\FS2\RTS-fleet-command-artifacts\headless\headless.py' probe ui-comms-checked --kind commands --rendered --resolution 1280x720 --port 58631
```

Use fresh tags/available ports if those runs already exist; launches are sequential to avoid competing game windows. The runner fits requested resolution to the monitor work area (the earlier 1920x1080 request became 1706x960); record actual dimensions. Rendered probes use pristine upstream, while modified-engine batches are experimental corroboration only.

- Native logs: `D:\Games\FreespaceOpen\FS2\RTS-fleet-command-artifacts\headless\runs\<tag>\base\probe\data\`.
- UI mutation report: `D:\Games\FreespaceOpen\FS2\RTS-fleet-command-artifacts\work\ui-visual-fixes-20261007\ui-mutations.json` (contains the nine guard names and individual verdicts).
- Original screenshot archive: `D:\Games\FreespaceOpen\FS2\RTS-fleet-command-artifacts\work\ui-visual-audit-20261007\UI-captures-20261007.zip`.
- Performance and balance evidence/limitations: [Development batched verification](DEVELOPMENT.md#batched-verification--7-october-2026). Recorded upstream build: `242eb19ef5516f704febf4fdb5867b4ed5ed3ef7`; recheck current upstream HEAD on resumption.

For the fastest finish: reuse the existing modules, probes and frozen controls; batch independent checks, fix only demonstrated failures, and repeat only checks affected by subsequent changes. Screenshot access does not block source/runtime performance or balance work. Retain the upstream missile-evasion crash evidence as an external concern; introduce no modified-engine dependency or combat disablement to hide it. When reported remaining usage is below 10%, stop safely and refresh this file; no tool currently exposes a percentage, so do not invent one.

## Solo review and verification checkpoint — 7 October 2026

Latest steering: fix all eight screenshot findings together and give panels/controls proper padding, including a clear gap between build-row AI buttons and type badges. That coding pass is complete; details are in CHANGE_SUMMARY.md's UI audit section. Full suite now **999 passed**, nine UI removal guards killed, native portrait/feedback/comm probes pass. The capture tool reported a physical-Escape stop; no further computer-use actions were issued. Final-code screenshots remain the immediate next visual check. The intermediate capital screenshot predates the corrected singular native gauge names and is labelled accordingly. Balance/performance follow-ups below remain separate.

The user requested a solo review of all changes and automatic fixes, then explicitly asked to inventory verification and finish coding before running more tests. All three newly spawned review agents were interrupted; do not restart or spawn agents. The original eleven-item request is preserved in DEVELOPMENT.md's solo review test inventory. Later corrections include an actual RTS Exit menu, living-base AI remaining in the battle, defeated withdrawals eventually warping out, and continued combat allowing a draw/final survivor victory. The user requests a handoff and safe stop when reported usage falls below 5%; no quota percentage tool is exposed in this session.

The source coding pass corrected:

- New FS1 standalone classes had zero-default rotation/acceleration/reactor/weapon capacity. Their physics, energy, afterburner, countermeasure and exact subsystem profiles were restored from installed FSPort `fsport3_7.vp`/`ships.tbl`; retail weapons remain and no FSPort runtime dependency was added.
- `GS_EVENT_PAUSE_GAME` is a plain pause screen, not the quit/restart popup. RTS Esc and topbar EXIT now share a real Resume/Restart/Quit overlay (`OpenExitMenu`, `DrawExitMenu`, mouse routing, OnFrame gate); pilot Escape still resumes and exits possession. Old native-state marker code was removed. Restart/quit use upstream mission events. The native review probe now requires the rendered three actions and a Resume mouse click, not a pause-state transition.
- `GetBattleMapHalfExtent` separates combat bounds from the extraction-expanded display. Automatic target eligibility, world recovery and normal commands use battle bounds; withdrawal route waypoints can still use the expanded area.
- `AILocalStrength` no longer counts a hostile excluded by targeting rules as friendly support. Production records created hull ownership before fallible paint initialization. Service admission refuses dead stations; station-threat selection really examines the nearest attacker. Station point defense prefers bombers over fighters within valid reach/arcs.
- Pilot proxy passive recharge is disabled during possession and restored on exit; shield and weapon transfer deltas reach the real hull once, preserving real damage/fire expenditure. Initial ETS settings are copied from the real ship. Native testing proved a keybinding override still duplicates countermeasures. The final `On Countermeasure Fire` hook transfers the single native decoy to the real hull and charges it once; `solo-pilot-energy-cm-02` passed.
- Music only pauses its owned stream. Mission event music is None to avoid a second score. Full-cap requested Auto Mode builds can wait; player Auto Mode uses its actual income in the existing savings calculation.
- Original station-result history remains recorded, but continued combat can earn a draw after last-station loss or final victory when the player's mobile force has no hostile assets left. Final reports reject Resume at the action layer. Hostile installations count against sole-survivor victory.

The test phase additionally corrected analyzer endpoint/roster assumptions and reduced repeated AI geometry/IFF calls inside the synchronous context. Live team changes and extraction permissions retain fresh checks. Healthy focused hulls defer recovery threat work until hull recovery can act; ammunition/subsystem admission and active-service safety still scan. The service regression now explicitly expects immediate HULL_LOW on crossing the threshold, rather than an OUTMATCHED label accumulated while healthy.

Finished evidence: **989 full-suite tests pass**, all 26 runtime modules parse, global/scope checks pass, twelve earlier plus nine final removal guards all go RED. Current clean upstream Release build finished successfully; GitHub HEAD recheck matches `242eb19ef5516f704febf4fdb5867b4ed5ed3ef7`, executable SHA256 `C7E4C96556F44D61C54FF1CE7975293A026495D3106BC90AB0D25C55A66D286A`. Native lifecycle/commands/extraction/cannon/feedback/faction/audio/rush/performance batches finished. Tags, failures, exact coverage and limits are in [DEVELOPMENT.md](DEVELOPMENT.md#batched-verification--7-october-2026). No engine dependency, commit, push, deployment or new library was added. All subagents are closed; no test or game process remains running at this checkpoint.

Earlier follow-up inventory (execution order is now defined by **Resume here** above):

1. Profile and reduce remaining large-fleet stalls: 193-unit crowded update median improved 330.74→259.56 ms, but p95 remains 342.33 ms; normal-speed p95 170.72 ms and paused HUD median 38.59 ms. Faction scoring, service admission and world overlays remain the measured hot paths. Reuse frozen script controls from the prior performance tags; compare isolated identical workloads and keep failed runs.
2. Investigate capital savings in longer held-out matchups. `solo-ai-nine-01` seeds 2026100701–703 all reached 900.01 simulated seconds, 65,574 records, no engine-log errors, real repair/rearm/READY states, all economy/queue accounting checks clean, but no natural elimination. Invariants still show 117 PASS / 42 FAIL / 30 WARN for funding/roster/composition. Respect roster-specific unlocks and attainable bank windows; do not turn caps into gameplay time limits. These experiments precede the final performance changes; final-code long combat must be repeated.
3. Native requested-capital Auto Mode queue-to-completion and final MediaVP audio/art checks remain desirable. Current requested-build fault/cap/emergency coverage is regression-level. Retail sound-enabled probes prove unrelated voice continues through music mute/unmute/cleanup.
4. Physical input, monitor bounds and pixel/readability audit remain unverified. Exit proof calls the central click handler at the rendered rectangle because hidden-window mouse warping did not move the cursor. Native font/layout checks are not pixel-quality proof. Cannon/feedback remote contacts use explicitly enlarged diagnostic arenas; normal arena restrictions have separate coverage.

Earlier upstream missile-evasion crashes still limit long authoritative matches; see DEVELOPMENT.md for the source/dump evidence. Do not introduce an engine workaround or disable combat behavior just to make a test pass. Keep the user's dirty tree intact. The latest AGENTS instructions require a safe handoff if reported remaining usage drops below 10%; no percentage is exposed by the tools, so do not invent a quota stop.

The resumed status below is historical and superseded by this checkpoint.

## Resumed status — 2026-10-07

The checkpoint below is historical: its remaining-work checklist has been addressed except broad gameplay balance/performance validation. Current changes and evidence are in CHANGE_SUMMARY.md and DEVELOPMENT.md.

- Latest completed full suite: 968 passed in 163.45 seconds; log in sibling artifacts/work/expanded-request-20261006/pytest-final.txt. Later query, bomber and ring changes require their focused checks and final shared checks.
- Native commands-final-07 passed. Native passage-rearguard-20261006-05 passed real automatic fighter attack, explicit/capital interception, physical extraction and result/pilot checks. Beam-base-damage-14 and -15 passed paired .25/.10/2.5x beam ratios and corrected full-shockwave-core Cyclops controls.
- Scene crash reproduced in coarse performance05 and fixed in draw/click paths; coarse06 and isolated07 passed. UI overlap/click/ghost regions, final-report actions and critical-pilot notices are fixed. Documentation and insignia provenance are updated.
- Root added empty-withdrawal fast paths to faction/IFF/target queries: 60 focused tests passed and all three independent query mutations were killed. Earlier UI, scene, service-scan and lifetime/result mutations were killed too.
- Active AI worker: bomber operation-target selection incorrectly diverted strike groups toward mobile escorts. New regression went red/green; 19 operations tests pass. Same-seed original-factions 900-second replay expanded-ai-03 is running against expanded-ai-02 (seed 2026100701, same engine/runner/setup). Full-match evidence is corroboration, not isolation of one source change.
- Active HUD worker: bounded projected-range-ring cache, preserving all lines and invalidating on camera/position/range/screen changes. Await focused checks and native performance verification. Do not edit HUD/test_player_feedback concurrently.
- Content worker's independent read-only lifecycle/fleet/report review found no concrete defect. Runtime APIs remain upstream-compatible; HEAD rechecked today, unchanged at 45b9d31d769c830a8eacb56c23717f939e573d96.

Next: collect AI/HUD worker outcomes, fix any remaining demonstrated engagement issue, run current shared/static/mutation checks, update final evidence and inspect diff. No deployment/commit occurred. Old quota stop is no longer active.

## Archived checkpoint

## Goal and constraints

Finish the user's expanded request: pilot Escape/RTS Space/time controls; outmatched service; 3D sentry placement; canonical FS1/FS2 rosters; stronger capital/beam base damage; requested auto builds; triangular-dot Shivan badge; music/nebula selection; full PHILOSOPHY_AND_GAMEPLAY_RECOMMENDATIONS.md implementation. User authorized GPT-6 Luna high workers and root review. Preserve the large pre-existing dirty tree. No reset/clean, engine changes, publishing, or commits. Existing HANDOFF.md is untrusted.

Upstream source of truth: D:\Games\FreespaceOpen\src\fs2open-upstream-review, HEAD 45b9d31d769c830a8eacb56c23717f939e573d96. Rebuilt executable build-review\bin\Release\fs2_open_26_1_0_x64_AVX2.exe. Modified engine is experiments only. Artifacts are in sibling RTS-fleet-command-artifacts.

## Implemented, with scope of evidence

- Pilot input worker implemented Escape exit/resume, RTS-only Space, pilot time controls, 3D sentry preview and withdrawal route clearance. Focused worker tests passed; actual engine extraction-integrated-03 probe also exercised scripted key-entry APIs, not physical keyboard injection.
- AI worker tuned retreat/service, requested-auto-build savings and queue lifecycle, automated withdrawal target permissions, and Command Hull capital-beam scalar .10 to .25. Fighter base immunity remains. Station/sentry/strike automatic selectors now use CanAutoEngage. Worker reported 264/265 tests passed; remaining test stubs GetCarrier as an empty table and must supply a valid handle, without weakening production validation.
- Content worker restored five bundled FS1 hulls (Apollo, Valkyrie, Athena, Anubis, Shaitan), canon profile rosters, authorized FSPort asset credits, 21 music tracks and 36 nebula backdrop choices. Native expanded-rosters-env-06 passed all 12 teams, new model spawns, WAV VFS and backdrop handle reuse. Temporary MVPS music mount confirmed OGG endpoints and was removed. No audio listening/pixel review claim. Apollo optional glow ANI absent from installed source pack; model and base textures work.
- Root added fleet history/extraction module, native RTS Passage IFF, immutable strategic result vs later fleet fate, personal defeat that leaves other factions' economies alive, aftermath queue cutoff, report tabs and environment/auto-build UI.
- extraction-integrated-03 native probe passed actual movement around station clearance, corridor entry, explicit fighter/capital fire, confirmed departure/archive, unresolved personal defeat/resume and immutable resolved victor. Log: artifacts\headless\runs\extraction-integrated-03\base\probe\data\extraction-probe.log. Latest rearguard bounded-position changes happened after this run and need retesting.
- Latest root change: IsPointOnRTSUI recognizes FleetLifeButtonRects and environment modal, preventing world gestures from swallowing buttons. Finished command: python -m pytest core/tools/test_fleet_life.py core/tools/test_hud_layout.py core/tools/test_alt_focus_input.py -q — 33 passed. git diff --check finished exit 0 (line-ending warnings only).

## Remaining work — do not claim complete

1. Fix DrawFleetLifeOverlay layout: controls currently start x=12 just below top bar and overlap selected stats. Recovery card at bottom left may overlap panels. Reuse existing UI geometry, then test actual button routing and bounds. Pilot critical recovery notice also needs practical visibility.
2. Review UpdatePassageInterception: AllowWithdrawal=false must actually acquire nearby Passage targets even when ship.Target is nil; currently it mainly respects existing/explicit targets. Keep explicit attacks permitted and corridor vulnerable, no immunity. Review departing/dead cleanup for Rearguards, MoveTurretLocks, pursuit/target caches and warnings.
3. Add focused rearguard tests: bounded pursuit, actual confirmed extraction before release, stranded withdrawal, no armed cover, duplicate callbacks/signature reuse. Existing seven fleet-history tests do not cover the whole cover behavior.
4. Run full current pytest suite, parsing/global/scope/table checks and meaningful mutation kill checks. Previous full integration run had 941 pass/14 failures; most were subsequently fixed (top-bar layout, module count, stale behavior expectations, cached IFF permissions) but full green has NOT been rerun. Do not treat old 924-pass baseline as current evidence.
5. Native cannon probe failed Cyclops armor control: capped=14000 vs control=16000, expected equal. Investigate fixture contamination/blast sequencing, don't relax assertion. A dedicated native capital-beam Command Hull versus Base Hull pair is still needed to prove the scalar increase. AI worker hit usage limit before doing it.
6. Repeat final extraction probe after rearguard changes; review complete final diff/new files. Do not infer visual quality from geometry tests.
7. Update core/data/maps/README-insignias.txt: it still describes the discarded claw logo. Current generated Shivan PNG is three red circular dots in an equilateral triangle, transparent. Source C:\Users\User\.codex\generated_images\01a0fff6-70e8-7f80-a432-89195f5a79b4\exec-36b2c17b-cc77-4f1d-81b8-d756d8e977d1.png. Preserve image, correct prompt/provenance and preview at HUD sizes.
8. Finish documentation in existing README/DEVELOPMENT/PHILOSOPHY docs: controls, outcomes, extraction invariants, scene/music behavior, build requests, tests and honest limitations. New environment and fleet-life modules are required by fs2rts.lua.
9. Balance remains unproven across profiles. expanded-ai-02 reached 900.013 simulated seconds without errors, 81 spawns but no heavy/capital purchase or station damage. This is evidence of a remaining economy/engagement concern, not a successful balance verdict. Retain failed expanded-ai-01 and cannon artifacts. Earlier upstream missile-evade crash remains an engine concern; don't introduce an engine dependency or disable all AI to hide it.

## Files and workers

Main added modules: fs2rts_environment.lua, fs2rts_fleet_life.lua; new passage IFF table. Main integrations: lifecycle, HUD, input, orders, production, station, strategy, ai_planning/ai_production, config, factions. Fleet tests: core/tools/test_fleet_life.py. Native probe: core/tools/extraction_probe.lua. Snapshots/logs in artifacts/work/expanded-request-20261006 and faction-followup-20261006.

Available worker names: /root/pilot_input and /root/content_environment finished; /root/ai_behavior errored with usage-limit notice. Reauthorize its turn only if quota permits. All workers share files; read their changes before further edits. No tests running from the latest root continuation (session 89310 fetched completion, exit 0). Root stopped at a safe point after the quota notice; no completion or deployment claim.
