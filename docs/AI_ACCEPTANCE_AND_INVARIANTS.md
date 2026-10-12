# Verification contract and next-work target

**8 October 2026 · RTS Fleet Command 1.4.5 · current development tree**

Latest checkpoint: [double-check repairs](DEVELOPMENT.md#double-check-repairs--8-october-2026) fix four reproduced gaps: missing economy fields, boolean numeric-counter coverage, malformed faction/provenance containers, and arena bounds checked too late during spawn search. The full suite and targeted assertion kills completed. Broader empirical balance/UI/MediaVP claims remain separate.

This is the starting document for future AI, balance and verification work. It supersedes historical claims that an analyzer PASS, a test total, or an unlocked capital not being purchased establishes AI quality. Performance optimization remains parked. The initial verification cleanup changed tooling/tests; the later gameplay and verification fixes are recorded below and in Development.

**Follow-up implementation, 8 October:** the earlier cleanup is historical. Run provenance/completion, selected-metric coverage, record-order cutoffs, stable production IDs and global/personal result handling are now implemented. Congested spawns now return explicit failure instead of knowingly creating an obstructed hull; both producers preserve once-only retirement/refunds. Experiment tools add equal initial CP/base-income and explicit two-faction slot swaps. No gameplay engine extension was added. See [Development](DEVELOPMENT.md#evidence-and-spawn-follow-up--8-october-2026) for completed checks and remaining empirical limits.

## What we are building

An upstream-compatible space RTS in which rival commands seek victory while protecting living crews. Preserve elimination-only matches, distinct faction strengths, explicit player ownership, optional piloting and separate strategic/survivor outcomes. Long matches, uneven counter-matchups and necessary sacrifices are legitimate. Performance optimization remains parked.

## Current situation — 8 October 2026

**9 October: NOT DONE. M1 and the frozen M3 cohort are assessed.** M3 finished 15 attempts: three natural results and twelve unresolved caps, with no engine failures. The profile-only M2 cohort was inconclusive and retained one modified-engine access violation. New bomber banking and 10% fighter station damage have focused/native evidence; fresh matched banking validation and player-facing checks remain. See the active follow-up in CONTINUATION_HANDOFF.md. Earlier dated bullets describe their historical candidates.

- Work in `RTS-fleet-command-1.4.5`, not the old `1.4.1` directory. The working tree contains substantial uncommitted changes. Upstream FSO is authoritative; the modified engine is an experiment tool, never a gameplay dependency.
- Latest recorded repair evidence: 1088 full-suite checks, 77 later shared checks, 13 tool mutations and three spawn/admission mutations passed. These overlap and test named contracts, not win rates or enjoyable play. Evidence and limits: [Development](DEVELOPMENT.md#double-check-repairs--8-october-2026).
- The latest recorded pristine-upstream lifecycle probe passed on revision `242eb19ef5516f704febf4fdb5867b4ed5ed3ef7`. This is a dated tested revision; recheck upstream identity for future retained changes. The specific edge-placement regression uses engine doubles.
- Two recent 90-second experimental runs verified staging, completion and ordinary production. Their self-comparison was inconclusive. Final-tier long-match behavior was not exercised; the current final unlock is 1380 mission seconds / 23 minutes.
- Earlier frozen trees produced unresolved 40–50-minute contests and variable capital investment. A saving latch passed tests but worsened its paired match and was reverted. These are leads for current-tree reproduction, not current balance verdicts.
- Normal player/opponent economies differ. Equal-economy and slot-swap experiment controls exist; normal-play difficulty/economy effects still need separate checks.
- Historical failed/stalled runs and a native missile-evasion crash remain recorded. Their current applicability/root cause is unresolved. Do not classify them as balance outcomes or declare them fixed because later runs completed.
- Crew-aware priorities, commendations and the conflict-intro rewrite are requested follow-up features. Existing ship histories, service and survivor mechanics provide foundations. An exact crew-casualty model and persistent campaign population are not implemented claims.
- Comparison PASS currently describes selected metrics using a median/MAD heuristic. It does not establish statistical faction fairness. Broader matchup uncertainty, MediaVP combat parity and player experience remain unverified.

## Long-match balance contract

### Decision rules: demonstrate a problem before changing a knob

The active deliverable is a **bounded balance iteration**, not proof of optimal balance for every ship/configuration. Complete M1, work only on problems it establishes, and validate the retained result in M3. If no repeatable problem is established, finish the investigation with a no-change result and its limits. Do not invent a tuning target to justify work.

The former blanket targets are withdrawn: 25% defensive improvement, 35–65% faction wins, 40–60% mirror-slot wins, a service bill below 50% of replacement price, defense within two updates, and mandatory adaptation after two failed assaults. None had a measured basis. Also withdraw requirements that every ship be equally competitive, every upgrade have a different optimal opening, or every threat have an equal-cost counter. A fortress, tech lead or specialist counter is allowed to confer an advantage.

Use numbers in three distinct ways:

1. **Hard rules:** exact obligations already chosen for the game, such as reduced fighter station damage (10% of normal weapon damage; replacing the ineffective 1% candidate on 9 October), correct payment/refunds, explicit order ownership and no automatic defeated-fleet extraction while the base lives. Keep the 53 required contracts below; passing checks remains scoped to exercised cases.
2. **Observation budgets:** fixed workload/windows that bound investigation. They are not gameplay deadlines, balance thresholds or proof of statistical power.
3. **Acceptance measures:** chosen per demonstrated problem from its baseline/control and practical consequence. Freeze them before evaluating candidates. No universal better/worse direction for spending, casualties, repair volume, engagement or capital purchases.

### M1. Baseline assessment — current task

Start on retail assets, Normal difficulty, the standard economy preset, circle layout, default spacing and AI control for both sides. Use equal initial CP/base income to isolate faction/policy behavior. Freeze the actual configuration and admitted rosters; confirm the installed scenario names rather than inventing parameters.

**Discovery workload:** GTA/Shivans, PVN/Shivans and NTF/GTVA; two recorded seeds per pairing, each with positions swapped: **12 runs**. This samples cross-species and same-species matchups, not the full faction pool. Use a **45-simulated-minute observation budget per run**, or stop at global strategic resolution. This leaves a final-tier observation period and is an experiment cap only; the game remains elimination-only. Preserve early completion, unresolved caps, failures and missing evidence distinctly. If the engine cannot complete the workload, report M1 BLOCKED with the captured cause; do not substitute only successful attempts.

For each run record: starting conditions; global result or unresolved reason; station hull/repair-ceiling trajectory; commissioned/lost/escaped ships and replacement CP by class; paid production and queue outcomes; saving episodes; service admission, actual work, ready/rejoin; attack/defense orders and native execution. Record observation coverage and unknowns. Attribute damage only where supported; assigned offensive value is not damage. Review timelines around major losses, failed attacks, near-funded purchase changes and stalled recovery.

**M1 DONE:** the 12 scheduled runs are accounted for; usable runs have verified inputs/completion/telemetry; each apparent problem has a cited trace and a legitimate control or is labeled unconfirmed; a short ranked issue list explains the gameplay consequence. Each run and excluded observation has a reason. This completes discovery, not a fairness certificate. Do not extend the run list repeatedly just to obtain a preferred story.

### M2. One problem, one causal experiment

**Latest siege evidence, 9 October:** the completed assay now covers six bomber
and four capital classes at both ranges. Smart selection fixes loaded Trebuchets;
it does not give the Shaitan an anti-capital missile. Its installed bank contains
ten Rockeyes. At 3 km the final native assay launched all ten and removed 183.5
station hull in 120 simulated seconds, with an invulnerable attacker and no
station healing. This confirms firing, but not useful siege investment under
defense. M1 bought 27 Shaitan jobs and only one Nahema job across eight Shivan
appearances. Keep role/loadout and affordability as an explicit next hypothesis
if the matched profile campaign lacks eligible bomber exposure; do not silently
equate the bomber class label with effective station siege or buff all weapons.

**Shivan effective-siege work item, 9 October:** M1's eight Shivan appearances contain accepted station-target PRIMARY groups and native acquisition, yet only four have attributed hostile-station hull removal (maximum 1,117, versus the sampled 51,000-hull station). This rules out a blanket missing-order explanation; it does not prove a loadout or balance cause. Retail/default Shivan bomber banks differ sharply from Medusa's Cyclops loadout. The upstream `siege_probe.lua` freezes Medusa, Sekhmet, Shaitan and Nahema at 3,000/8,000 initial range, native ATTACK orders, identical undefended Terran command-station armor, 120 simulated seconds and stock banks/ammunition. Sources are invulnerable solely to remove survival/attrition confounding; station repair and automatic directors are disabled. Primary observation is per-source pre/post collision hull removal, accompanied by real weapon creation/hit counts and final distance. Later shockwave damage is not assigned by that hook. Near Medusa must remove hull for a valid positive control. If a Shivan class cannot engage/remove hull in this control, isolate role/loadout/native execution before changing prices; if it can, examine battle arrival/attrition/defense instead. Different range, ammo, interceptability and hull budgets forbid treating equal ship counts as a fairness test. No damage/price adjustment is accepted from the M1 win count or this isolated assay alone; a selected mechanism needs a legal force-budget control and reserved validation. Current M3 remains the already-frozen service/priority candidate; these diagnostics use M1 rather than validation outcomes for tuning.

**Reproduced recovery defect, 8 October (lead implementer):** `UpdateFleetServices` retains a remembered attacker solely while its handle is alive. A ready visitor consequently stays UNDER_FIRE even when the fresh local-threat query returns no contact. The new `test_automatic_service_releases_when_remembered_attacker_is_no_longer_local` fails on this exact ready/rejoin assertion; the same sequence first confirms that a genuinely local threat blocks automatic release. The candidate samples current local threat each active service tick while retaining the existing latched pad. Primary criterion: the ready visitor rejoins after quiet/minimum recovery obligations when the attacker leaves; control: it stays protected while the attacker remains locally dangerous. Preserve payment, travel, slots, explicit commands, the actual pad and retry rules. Native crew/recovery probe and existing service/ownership cases are the reserved mechanism checks. This is a correctness fix, not a demonstrated faction win-rate improvement; M3 campaign outcomes remain required.

Open a work item only for a reproducible failure, repeatable adverse pattern, or an explicit new design request. A low CP bank, absence of a flagship or long match alone is insufficient. Investigate the highest-impact demonstrated failure first: inability to execute a viable siege, failed defense, wasted investment or avoidable loss/recovery loops.

Every work item must contain this record before editing:

| Field | Required content |
| --- | --- |
| Problem and evidence | Exact run/time/entities, expected behavior and observed failure; independent reproduction. |
| Hypothesis | The responsible decision/state transition or numerical relationship, plus a probe that can disprove it. |
| Frozen comparison | Source/assets/engine, force budgets/classes, upgrades, positions, policy, seed list and observation window. |
| One primary measure | A meaningful outcome: assault objective completed, recoverable ship returned, funded job deployed before its actual opportunity expired, or a documented investment trade. State direction and units. |
| Pass threshold and reason | A concrete condition grounded in the control/opportunity/contract. For numeric tuning, state the smallest practically useful effect and allowed variation before seeing the candidate. Do not pick a percentage merely because it is easy to calculate. |
| Guardrails | Explicit limits for own losses/CP, station protection, useful activity, unavailable-unit handling and touched hard contracts. Explain which tradeoffs are acceptable. |
| Validation and stop rule | Exact frozen discovery cases plus a reserved seed and a relevant roster/layout/pressure variant. Decide sample size, variation handling and stopping before testing; one extra win cannot become a fairness claim. |

Example: if the AI assault fails but the same available fleet completes that objective under a legal direct-order control, investigate coordination/targeting before raising damage. If both fail, check actual firing, armor, force investment and defenses before declaring the AI wrong. For service, compare a recoverable ship with its continued-attack and replacement alternatives; measure rejoin and cost/time, not healed HP alone.

**M2 DONE for a bug:** the original sequence fails, the fix succeeds, the nearest legitimate control remains valid, affected regressions pass, and the reserved cases meet the frozen condition. Verify engine-sensitive behavior on upstream. **M2 DONE for tuning:** the predeclared primary effect and guardrails hold on discovery and reserved validation under the chosen uncertainty rule. Mixed/insufficient results mean INCONCLUSIVE; revert or leave the candidate unpromoted. Rejected candidates remain documented. No repeated sampling until green.

### M3. Validate this balance iteration

Freeze the retained candidate before validation. Repeat the three M1 pairings and slot swaps using two reserved, previously unexamined seeds per pairing: **12 validation runs**, under the same observation budgets. Seeds used to tune cannot serve as validation. Run matched baseline controls when a comparative improvement is claimed. A completed representative run from M1 that needs no change can remain the baseline; do not fabricate a candidate improvement.

Add three declared interaction cases: three-faction circle, four-faction star and six-faction multi-circle. Freeze their factions, economies and seeds before candidate results; include a mirror faction and rotate the player slot where the work item concerns ownership/targeting. These are interaction checks, not representative free-for-all win-rate estimates. Use an existing largest-supported-count setup/spawn probe for capacity; add a long maximum-count case only if the change or evidence implicates that boundary.

**M3 DONE:** each scheduled attempt is accounted for; each retained M2 item still meets its frozen criteria; no unresolved reproducible blocker in the tested command/economy/attack/recovery/result paths; affected contract checks pass; upstream-sensitive mechanisms have native evidence. Complete one documented real player session containing a supported assault, a recovery decision and the relevant RTS/pilot transition. Log what the player could execute and any friction; an automated render is not that session. If player validation is unavailable, status is READY FOR PLAYTEST, not DONE.

Deliver a concise report with tested configurations, accepted/rejected changes, primary outcomes, unresolved runs and remaining issues. Report win/loss counts and their denominator; add statistical uncertainty only using a declared validated method, preserving draw/unresolved handling. Do not assert faction equality from this small campaign. A long contest is not a failure unless the work item demonstrates the harmful loop. Failed or censored runs cannot disappear from the report or from comparative accounting.

**Current balance iteration DONE = M1 assessed + selected blockers resolved/retained under M2 + M3 accepted.** Awards, intro work and exhaustive roster/asset coverage do not block that milestone. A newly discovered blocker opens a named issue; an optional improvement goes to the next iteration. Do not endlessly reopen the pass for speculative knobs.

### Coverage map — inventory, not an exhaustive completion demand

| Area | What to watch / when to expand testing |
| --- | --- |
| Ships and weapons | Fighters, bombers, escorts, capitals, flagships; actual banks/arcs/range/ammo/energy/armor, collateral damage, equal CP plus build-time/cap tradeoffs. Examine individual classes implicated by traces or touched tables; retain admitted-roster validity checks. No demand that every legacy hull be optimal. |
| Stations and defenses | Assault arrival, lasting damage after healing, sentry acquisition and placement, artillery counterplay, friendly spawn/collision damage. Compare supported attack and defended controls before changing hull/DPS. |
| Economy and progression | Income/upgrades/rewards, saving interruptions, paid requests, queue/cap recovery, tier transitions and replacement cycles. Expand to difficulty/economy presets when their factors are changed or implicated. |
| Recovery and abilities | Travel, capacity, CP, real work, interruption, rejoin, repeated activations and expiry. Zero-CP and station-loss controls are required when these paths change. |
| AI and player control | Reachable support, threat priority, formation/cohesion, useful offense/defense, explicit orders, possession and cooldown ownership. Survival must not be rewarded through perpetual avoidance. |
| Factions and maps | M1 pairings are a sample; other profiles, layouts, spacings and population counts remain in the inventory. Expand one relevant dimension for an observed problem rather than taking the full cross-product. |
| Defeat and survivors | Personal loss versus global resolution, remaining economies, retaliation, physical extraction, departure rewards and resumed fleet fate. Preserve the existing rules rather than retuning them without a demonstrated issue. |
| Assets and experience | Retail is this pass's baseline. Combat-changing MediaVP configurations need separately labeled campaigns before parity claims. UI/performance work stays separate except concrete defects blocking the tested decisions/completion. |

### Crew survival: lives are stakes

**M4 — separate behavior milestone after the combat baseline.** Crewed ships/stations carry lives. Larger crews generally increase preservation stakes, independently of CP/firepower, while risk to rescuers, several smaller crews and a decisive objective can justify sacrifice. Preserve explicit player commands. Use existing recovery/escort/history mechanisms first; add a crew weight only when controlled cases show that those decisions need it. Use verified data or labeled class/role estimates; do not fabricate crew-death totals or introduce a population simulation by default.

Freeze three decision cases: (a) endangered ship with a feasible recovery route and no useful reason to continue attacking; (b) holding a necessary objective/rearguard despite danger; (c) competing rescue priorities where crew exposure matters. Each has a legitimate counter-control, including saving several smaller crews instead of one larger hull. Record ship fates, recovered-and-rejoined units, CP/time and objective outcomes separately.

**Initial M4 implementation boundary:** preserve the existing recovery admission, strike commitment, explicit ownership and FIFO chronology. Within simultaneous admissions only, prioritize missing hull multiplied by an explicitly estimated crew exposure band per occupied service slot. Bands are SMALL (fighters/bombers), MEDIUM (escorts), LARGE (capitals) and VERY LARGE (heavy/juggernauts), using ordinal priorities 1–4; these are not head counts, canonical crew facts or casualties. A healthy large hull gains no hull-recovery priority, and more seriously damaged smaller crews can outrank a moderately damaged larger hull. Freeze controls with two service slots: equally injured capital vs fighter; moderately injured capital vs two critically injured fighters; and an older fighter admission vs a later capital. Primary outcomes are actual paid hull work and recovery/rejoin, with no size-triggered retreat, discarded command, free repair or starvation of older admissions. Wider commander crew weighting remains conditional on evidence; this bounded feature does not claim to maximize lives saved.

**M4 DONE:** the three cases and their counter-controls produce their declared decisions and physical outcomes; reserved variants preserve useful combat participation and player ownership; a player can recognize danger and execute recovery/withdrawal in the existing interface. Repeat loss/recovery cycles without free resets or lost identity. No healthy-capital hiding policy or unconditional size-first retreat passes. Validate the affected M2/M3 guardrails; do not rerun unrelated feature campaigns by default.

### Courage, justified sacrifice and commendations

**Lead implementation record, 8 October:** M1 is being frozen separately before feature edits. The initial recovery citation requires a commissioned lifetime to lose enough hull to a directly observed hostile projectile to reach the existing service return threshold, receive paid hull repair, finish service and subsequently destroy a hostile mobile combatant. Friendly projectile damage invalidates that recovery episode. Contact-only beam evidence does not qualify: upstream beam collision precedes damage. The covering citation requires a confirmed hostile kill of a mobile combatant targeting a same-faction committed withdrawing ship, followed by that beneficiary's confirmed native escape. Proximity, an assigned cover order, station kills, repair alone and death alone never qualify. Each citation is once per recipient lifetime, archived even after loss/escape, without resource/stat rewards. Native probes and negative controls must establish these boundaries before acceptance.

**M5 — separate recognition feature.** Honor useful courage, protection and preservation, including a lost ship's justified contribution. Death/damage alone never qualifies. Keep the initial feature match-local, attached to actual ship/wing lifetimes, with no CP/stat bonuses, campaign unlocks or AI medal-chasing objective.

Start with two observable citations: meaningful recovery followed by useful rejoin, and covering a confirmed withdrawal. A qualifying covering action can honor either a surviving or lost contributor; do not infer rescue from proximity alone. Freeze evidence requirements before coding. If upstream cannot observe the needed contribution, mark that citation BLOCKED rather than awarding it from invented attribution. Broader gallantry/distinguished-service categories remain requested follow-up work, not an obstacle to delivering the initial usable feature.

**M5 initial release DONE:** both citations have a qualifying and near-identical nonqualifying test; one upstream scenario demonstrates each; duplicate callbacks, recycled signatures, possession changes, friendly-fire repair, command-ID churn and death spam cannot farm awards. Recognition survives the recipient's observed loss/escape within the match, resets on restart, and names recipient/reason in history/report plus a readable notification. A player can understand the reason without private enemy orders or invented casualty counts. Report remaining award categories explicitly.

### Scenario premise and revised introduction

**M6 — separate presentation feature.** X rival commands are caught in an escalating survival conflict, each seeking victory while protecting its people. Political disputes, competing claims, diplomatic breakdown or interspecies hostility can supply context. Mirror factions can represent rival commands/splinter forces. Select wording that fits the chosen factions; do not imply every faction negotiated or that this is one canonical historical war. Destroying command structures need not erase surviving crews. Courage, necessary sacrifice and responsibility remain central.

The current intro is an in-engine camera/caption sequence with mechanical briefing text. Reuse its machinery. Present the conflict, escalating deployments, player role and crew stakes; leave weapon-scaling/menu instructions to appropriate help. Use neutral wording before setup resolves, or resolved names/colors/count afterward. No fixed three-faction or permanent red/blue/gold story. Do not add a diplomacy system.

**M6 DONE:** rewritten sequence viewed on pristine upstream with retail assets; captions legible in the supported test window; normal playthrough, skip, restart and transition to setup/command succeed; no gameplay CP/time/ownership/asset changes are caused by the intro. A real viewer can identify the conflict, their command role and crew stakes. Record tested window/asset configurations. Optional audiovisual overrides are checked separately; no new video pipeline or engine fork is required by this request.

### Milestone status and the next action

| Milestone | Current status | Next concrete action |
| --- | --- | --- |
| M1 baseline assessment | 12 ATTEMPTS ASSESSED | Four natural global results, eight cap-unresolved, zero failed attempts. Plan/setup hashes, runner sidecars and telemetry sequences checked; repeated full VP-manifest rehash remains unclaimed. Ranked findings are in sibling artifacts/work/lead-balance-20261008/PRELIMINARY-M1-OBSERVATIONS.md. |
| M2 causal fixes/tuning | MECHANISMS VERIFIED; BANKING COMPARISON PENDING | Recovery, smart secondary selection and fighter chip have upstream native controls. Profile-only comparison: two natural control results, five caps, one candidate AV; no qualifying bomber exposure, so inconclusive. Newest-tier bomber banking needs the separately predeclared eight-attempt comparison. |
| M3 iteration validation | 15 OF 15 EARLIER ATTEMPTS ASSESSED | Three natural global results, twelve unresolved caps, zero failed engine attempts. Includes the three layout interactions. This snapshot predates secondary-selection/banking/chip changes; player acceptance remains required. |
| M4 crew-aware behavior | BOUNDED SERVICE PRIORITY IMPLEMENTED | Labeled estimates, simultaneous-admission priorities and FIFO controls have native paid-work evidence. Wider preservation/necessary-sacrifice cases and player recognition remain acceptance work. |
| M5 initial commendations | IMPLEMENTED, NATIVE POSITIVE CASES VERIFIED | Recovery/rejoin and confirmed withdrawal cover are match-local lifetime records with no bonuses. Negative/duplicate/reset controls are tested; final history/report and player readability remain review work. |
| M6 conflict intro | NATIVE LIFECYCLE VERIFIED, FINAL PIXELS PENDING | Six temporary retail hulls fight and retreat outside the playable arena. Upstream full sequence, fire, cleanup, skip and restart pass. User requested slower pacing, no pre-match F10 notice and a smoother ending: shots are 50% longer, final drift/caption flash is removed, and camera reset occurs through black. Latest native -08 and 229 affected regressions pass; final transition pixels were not inspected after Computer Use interruption. |

**Next step: the separately frozen banking comparison described in sibling artifacts/work/lead-balance-20261008/BANKING-VALIDATION-PLAN.md.** Both arms retain smart selection and 10% chip; only bomber banking differs. It uses the modified-engine fixed-step runner because those CLI flags do not exist upstream, with separate native corroboration. Preserve prior failed/inconclusive cohorts; do not reinterpret old caps as draws or old snapshots as validation of later code. No new reproducible order, runtime or accounting defect is acceptable. Native mechanism evidence and natural campaign impact remain separate.

## Findings and disposition

| ID | Finding | Disposition / next action |
| --- | --- | --- |
| F01 | The overall test count mixes Lua boundary doubles, static inspection, analyzer tests and harness self-tests. | Separate `--suite lua`, `static`, `tools`, and `all`. Report the evidence type, not a single gameplay-confidence number. |
| F02 | Four of seven “invariants” encode historical tuning assumptions. | Mark them `diagnostic`, render alarms as ALERT, retain numerical results, and exclude them from the accounting gate. |
| F03 | Comparison output reported PASS without selected acceptance criteria. | Report NOT_EVALUATED. A successful descriptive command is not an accepted change. |
| F04 | Empty/corrupt telemetry and single-run comparisons could receive a pass. | Report INSUFFICIENT_EVIDENCE. Explicit gate exits 2; malformed records remain visible. |
| F05 | Inconclusive gated metrics silently passed. | Report INCONCLUSIVE and exit 2. Missing evidence is not evidence of safety. |
| F06 | Raw spending, fleet size, losses, repairs and order activity had universal better/worse directions. | All default directions are neutral. Choose the metric and direction explicitly for each experiment, with a reason and regression limits. |
| F07 | The convenience gate picked a September baseline and eight proxy goals automatically. | Remove the historical default and fixed goals. Require explicit baseline/environment selection, metric and direction. |
| F08 | Median/MAD separation is a heuristic, not statistical confidence. | Keep descriptive calculations; disclose their scope. Next: paired effects and uncertainty for outcome evaluation. Two samples only make variation observable; they do not establish adequate power. |
| F09 | Matched seed numbers do not keep every subsequent random draw or combat event identical after a policy change. | Freeze inputs; treat each trial as a policy comparison, not proof that one branch uniquely caused every changed casualty. |
| F10 | Totals from unequal observation windows are not comparable. | Compare common windows, or use actual time-to-event outcomes. Rate normalization alone does not remove survivor/phase bias. The current comparison warnings are not a complete comparability validator. |
| F11 | The player slot and opponent slots use different economic factors. | Balance trials need common effective economies or slot swaps; normal difficulty alone is not a symmetry guarantee. |
| F12 | Experimental headless runs are not upstream runtime evidence. Four recent runs stalled. | Record failure/stall explicitly. Retain partial traces for diagnosis; exclude them from completion/win statistics. Require pristine upstream checks for shipped contracts. |
| F13 | `FACTION.offense` is assigned fleet value, not damage or successful attacks. | Call it assigned offensive value. Measure arrival, actual useful damage and objective progress separately. |
| F14 | More engagement or fewer losses can reward pointless combat or indefinite avoidance. | Use role/objective-aware outcomes and exploit scenarios, not aggregate activity as the optimization target. |
| F15 | Capital absence does not by itself prove a broken producer. | Check unlock, funding, queue/build time, losses, emergency spending and observation cutoff. The rejected capital latch passed tests but worsened its paired match. |
| F16 | Repair volume increases when more damage needs repairing. | Measure admission, travel, actual work, recovery completion, cost and rejoin; do not maximize repaired HP blindly. |
| F17 | Some tests freeze incidental defaults and module counts. Two global-name tests were weaker duplicates of the scope checker. | Remove the duplicate tests; replace module-count/list freezes with entrypoint/import closure. Remove unrelated and numeric tuning pins from doctrine default tests; keep safety/default-off and actual on/off behavior checks. |
| F18 | Engine doubles can hide native API, geometry, firing and time-clock failures. | Keep doubles for state contracts. Native tests remain required at those engine boundaries. Historical probe clock bugs demonstrate why. |
| F19 | The mutation harness has excessive blank-line expansion; its registry also contains historical anchors. | Formatting/oracle cleanup completed. Full 64-guard audit found seven weak checks; their fixtures/mutations were repaired and re-killed. The unfalsifiable assignment-pcall mutation was replaced by actual waypoint-handle cleanup. Three new spawn/job guards were killed separately. |
| F20 | A mutation killed on setup/import/API failure does not necessarily cover the intended behavior. | Require green original, red intended assertion, exact restoration and identified mutant. Preserve ERROR/VACUOUS/UNCOVERED outcomes. |
| F21 | Resource ledger and flow counters partly share a writer. | Check against actual bank movement and independently observed queue/completion/payment paths; do not call two views of the same counter fully independent proof. |
| F22 | The headless acceptance driver ended on a visible player report. | Fixed: personal loss emits PLAYER_DEFEAT and resumes; only StrategicResult ends the run. BATTLE_END carries globalResolved and the authoritative victor. Legacy personal reports cannot become global winners. |
| F23 | Winning against one build/seed can encourage benchmark-specific behavior. | Use an untouched validation cohort with faction, slot, spacing, layout, difficulty and opponent-policy variation. |
| F24 | UI geometry tests do not prove legibility, contrast, physical input, or pixel quality. | Keep layout/hitbox checks; final pilot/RTS captures and human input remain separate evidence. |
| F25 | MediaVP weapon/loadout overrides can change combat and armor interactions. | Keep retail compatibility as the baseline; test effective MediaVP classes separately before claiming parity. |
| F26 | File presence/silence was used to identify completion. | Fixed: shared run evidence validates frozen inputs, plan, engine/runner hashes, prelaunch pilot hashes, runtime overlay, seed and matching successful runner/native results. Missing, duplicate, failed and timeout attempts cannot pass. Caps remain unresolved. |
| F27 | Missing values and zero-denominator rates became zero. | Fixed: metric rows use null without complete observed coverage; zero-denominator rates and absent event streams are unknown. Per-match legacy vectors are retained with explicit coverage flags for older consumers. Missing numeric counters no longer cause arithmetic exceptions. |
| F28 | The mutation runner treated generic failures/timeouts as kills and could infer a green original from missing failure output. Source drift did not fail its exit gate. | Require JUnit evidence of actual passing originals and Python/Lua assertion failures. Setup/runtime errors, skips, incomplete parameter groups and timeouts are ERROR. Source drift fails the gate. Lua `assert` traceback is distinguished from a missing native API. |
| F29 | The harness's deliberately “vacuous” fixture already failed before mutation; two timeout tests merely searched source strings and one endorsed timeout as a kill. | Make the fixture truly pass both versions, replace string checks with actual runner/decision controls, and prove the revised checks detect deliberately restored false-pass mechanisms. |

## Current executable analyzer inventory

Names remain stable for historical consumers. JSON rows add `kind`; their legacy numeric rule and PASS/FAIL/WARN `status` are preserved. A diagnostic `status=FAIL` means an alarm, **not an invariant failure**. Human output says ALERT/CLEAR. The accounting gate uses only `kind=invariant`.

| Check | Classification | What remains valid | Suggested change / limitation |
| --- | --- | --- | --- |
| `production_spend_reconciles` | Accounting invariant | Bank delta must equal recorded income + bounty + refund − spending over the same observed interval. Ledger prefix must match the cumulative publish; build payment cannot exceed the accounted payment path. | Keep numerical round-trip tolerances explicit. More granular future rows should separate bank conservation, ledger consistency and build payment. Missing fields/snapshots must remain unknown, not zero. Shared writer consistency is only one witness. |
| `losses_reconcile` | Accounting invariant | Cumulative loss snapshots must agree with actual LOSS records at the same cutoff. | Keep cutoff alignment. The existing one-unit tolerance needs a precise event-ordering justification; investigate tightening or ordering by sequence, not widening for convenience. |
| `no_orphan_builds` | Lifecycle/accounting invariant | A paid build must complete, cancel, or remain legitimately queued at the observation cutoff; sentry jobs need a terminal state or genuine in-flight evidence. | Retain conservation. Future matching should use stable job IDs where available, not solely class/timestamp. A simulation cap is not an orphan. |
| `cp_drift_not_persistently_negative` | Diagnostic | A low bank while claiming savings is worth investigating. | The 400 CP floor / 14% historical threshold is not a universal rule. Replace quality judgment with progress toward the actual goal, spending attribution, deadlines and emergency context. |
| `roster_escalation` | Diagnostic | No observed capital-class completion after unlock can expose starvation. | Consider real affordability, build time, queued hulls and pressure. Allow legitimate specialization. Do not require a capital merely because a tier unlocked. |
| `fleet_composition_not_degenerate` | Diagnostic | A fleet concentrated on one class or tier may be exploitable. | The 85% class threshold and T1-only alarm are historical heuristics. Judge counter coverage and outcomes across opponents; specialization itself is allowed. |
| `bank_target_reachable` | Diagnostic | A declared target above every observed bank value is an observation-window gap. | It cannot prove permanent unreachability. Track a saving episode, income, competing spending, completed purchase and expiry. Keep pending/capped episodes unresolved. |

## Mod invariant catalogue

These are the contracts future work must preserve or explicitly revise. “Invariant” describes the required behavior; inclusion does not assert universal proof. Evidence references identify the current owners and test seams. Lua checks use engine doubles; native probes cover selected scenarios, not every configuration.

### Compatibility, package and observations

| ID | Contract | Owner / evidence | Recommendation |
| --- | --- | --- | --- |
| C01 | Shipped gameplay requires upstream FSO APIs; experiment-only engine hooks are optional. | scripts, generated API allowlist; native review/faction/command probes | Hard gate. Recheck remote HEAD and the tested binary identity when compatibility changes. |
| C02 | Required modules resolve from the real entrypoint and loaded scripts parse. | `fs2rts.lua`; structural/parse/scope checks | Hard gate based on imports, not a fixed file count. |
| C03 | Reads/calls resolve in the correct Lua scope; native methods need engine evidence. | scope checker, Lua boot, native probes | Keep early/late-declaration negative controls. Static names alone do not prove ADE object behavior. |
| C04 | Retail assets/classes/weapons resolve; optional packs are not a required fallback. | table references, retail tables, faction probe | Fail real missing dependencies; report absent optional evidence distinctly. |
| C05 | Native ship names fit the 31-byte payload and remain distinguishable. | `GetSafeShipName`, spawn/faction probe | Hard gate; test the reported overflow and multiple large serials. |
| C06 | Unknown, invalid or non-finite handles/vectors never become successful commands/spawns. | orders, factions, service, pilot; focused doubles/native checks | Reject input visibly. Do not silently invent a valid target. |
| C07 | Each run records its source/config/assets/engine/seed/setup and completion state. | stager freeze/plan, runner results | Mandatory experiment prerequisite. Unknown provenance prevents acceptance. |
| C08 | Counters, gauges, interval totals and cumulative totals retain their declared meanings. | telemetry contracts/analyzers | Hard schema gate. Assigned intent is not execution or damage. |
| C09 | Damage attribution distinguishes attacker/target, hull/shield, friendly/hostile and observed/unobserved damage. | damage telemetry, native armor controls | No zero damage or kills inferred from missing hooks. Check coverage before evaluating effects. |
| C10 | Compare the same phase/window; departure, death, unresolved cap, stall and natural result stay distinct. | lifecycle/runner/analyzers | Outcome prerequisite; cohort comparability validation remains incomplete. |

### Identity, layout, selection and privacy

| ID | Contract | Owner / evidence | Recommendation |
| --- | --- | --- | --- |
| I01 | Political identity/species does not collapse separate hostile slots; mirror factions remain separate. | factions, faction profiles/native probe | Hard gate including duplicate species. |
| I02 | Active faction colors are unique; choosing an occupied color swaps ownership consistently. | factions, setup/native probe | Hard gate across setup and spawned visuals. |
| I03 | Every active faction gets a valid station and an admitted roster; disabled slots do not silently produce units. | lifecycle, factions, production | Hard gate. Do not require identical rosters. |
| I04 | Layout positions are finite, centered, distinct, spaced by the selected minimum and inside enlarged map bounds. | ui_text, faction geometry/native probes | Keep exhaustive count/layout/distance checks. Odd stars/clusters need not have equal tactical positions. |
| I05 | Layout changes reposition stations only during setup; scenario geometry is immutable during combat. | ui_text/lifecycle; layout regression | Hard gate, including cached layout/bounds state. |
| I06 | Selection/grouping cannot give ownership of hostile ships or group the base with mobile units. | selection/player_wing/orders | Hard ownership gate, including wing double-click and notification selection. |
| I07 | Hostile hover/stats reveal permitted basic information, not internal goals, destinations or targets. | hud/ui_text/input; feedback regressions | Privacy gate through all UI paths; final pixels remain separately unverified. |

### Player commands, possession and input

| ID | Contract | Owner / evidence | Recommendation |
| --- | --- | --- | --- |
| P01 | Explicit player orders own eligible units until replacement/cancel/completion; planners and automatic service do not steal them. | orders/strategy/service; command probe | Highest-priority behavioral gate, including repeated MOVE under fire. |
| P02 | New orders cancel conflicting prior movement, combat, service and possession state consistently. | orders/service/pilot | Test event sequences, not just one recorded giveOrder call. |
| P03 | Rejected native goal installation is not cached as successful; valid goals can recover from native preemption. | IssueStrategicOrder/validation | Hard gate. A native target refinement can be legitimate; not every mismatch is a bug. |
| P04 | Formation slots reflect requested facing and geometry; movement/attack preserves useful cohesion without forcing impossible strict combat formation. | orders/AI formation/native movement | Geometry is a contract; effectiveness/spacing values are tuning targets. |
| P05 | Pilot possession and release restore the observer, camera, controls, locks and ownership without destroying the hull. | pilot/lifecycle; lifecycle/cannon probes | Hard lifecycle gate including death, pause and restart. |
| P06 | Manual capital triggers use valid banks, legal targets, aim and cooldown/ammo; nearby flak can use appropriate fighter targets. | pilot; cannon/battery probe | Native firing is required proof. ALL selection does not make every turret able to fire through every arc. |
| P07 | Comm orders affect the permitted wing/group, never hostile/unrelated/base assets; Depart stays disabled. | player_wing; commands probe | Hard gate including grouped and ungrouped recipients. |
| P08 | Pilot kills/shields/objectives/cooldowns reflect actual native state and current orders. | pilot/player feedback | Separate authoritative values from estimated ETA/hints. |
| P09 | Space pauses only RTS; speed shortcuts work in both modes; Escape restores the intended pause/pilot/menu state. | input/lifecycle/camera | Hard mode-transition gate including already-paused sequences. |
| P10 | Hints start hidden; their toggle and notice remain reachable; UI clicks do not issue unintended world commands. | input/hud/layout checks | Hit testing and visual readability are separate checks. |

### Production, economy, installations and recovery

| ID | Contract | Owner / evidence | Recommendation |
| --- | --- | --- | --- |
| E01 | CP balance changes only through admitted income, rewards, spending and refunds. | economy-flow/accounting | Keep actual-bank conservation; no free builds or hidden second writer. |
| E02 | A queued item pays once, respects unlock/cap/capacity, completes once, and gets the appropriate cancel/refund behavior. | production/ai_production/station | Hard state-machine gate; retry and station-loss controls required. |
| E03 | Queue deadlines use the intended clock; caps and pauses do not fabricate completion. | lifecycle/production/time | Test before/after deadlines and repeated callbacks. |
| E04 | Spawn placement clears the owning hull and relevant blockers/enemy bases; no legal slot means explicit failure/defer. | GetSpawnFrame/SpawnFactionUnit; geometry/admission/refund controls | Fixed: final finite/map/own-hull/blocker/enemy separation validation; no best-available fallback. Legal geometry control succeeds; both producers reject nil frames. Native probes remain scoped rather than universal geometry proof. |
| E05 | Auto Mode off stops automatic player production/investment; opponent state does not spend player CP. | ai_production/station | Hard ownership gate; retained states must not leak behavior after toggling. |
| E06 | “Build this for me” uses the real bank, preserves Auto Mode, respects capacity and cleans up on cancel/base loss. | RequestAutoBuild; commands probe | Keep real save→queue→spawn→select path and emergency controls. |
| E07 | Sentry placement validates legality before charging, completes once at the requested point, and refunds an invalidated job. | station; placement/cannon probe | Hard job/geometry contract. Sentry cost and range are tuning values. |
| E08 | Weapons and armor honor configured impact/blast factors and range. Fighter weapons apply 10% station damage; bomber/capital siege remains distinct. | weapons/armor tables, source guards; native chip/control probes | Configuration may change deliberately; role classification and supported weapon coverage may not drift silently. |
| E09 | Selling/removing a sentry clears targeting, selection, cost and lock/upgrade records without deleting unrelated units. | station/death cleanup | Hard ownership/lifecycle gate. |
| E10 | Service requires valid ownership, a living station, travel, slots, CP and actual elapsed work; recovery/rejoin are observable. | service; command/service tests | Hard admission/accounting/state gates. Slot count, rates and thresholds are configurable. |
| E11 | Service never invents repair/rearm, overfills hull/ammo/subsystems, double-charges a tick or permanently strands a visitor. | service/telemetry | Native coverage still scoped; test interruption, missing station, capacity, zero CP and repeated updates. |
| E12 | Station healing respects quiet delay, repair ceiling/scars, elapsed time and upgrades. | station; repair tests/native controls | Keep mechanics; do not maximize healing as an AI-quality score. |
| E13 | Ability costs/cooldowns are real, nonnegative and applied once; failed activation is not charged as successful. | station/environment/faction ability probes | Hard resource/state gate, not a requirement to use every ability often. |

### Automatic AI execution and results

| ID | Contract | Owner / evidence | Recommendation |
| --- | --- | --- | --- |
| A01 | Automatic actions exclude player-owned/possessed/service/withdrawal units as appropriate. | IsAutomaticAIUnit, planner/service | Hard precedence gate through all directors. |
| A02 | Automatic targets are live, hostile, inside permitted arena and subject to corridor passage policy. | CanAutoEngage/context/target validation | Hard eligibility gate. Recheck live team/permission changes despite cached observations. |
| A03 | Fighters do not receive an immune station as an effective siege goal; screens protect useful strike assets when no suitable hostile remains. | strategy/operations/rebalance tests | Role contract; specific fleet percentages are not invariants. |
| A04 | Nearby support estimates exclude unavailable ships and preserve actual long-range threats. | AI context/local strength/service | State correctness is a contract; strength formula and arrival horizon remain hypotheses requiring outcomes. |
| A05 | Commander/operation intent survives legitimate phase transitions without overriding immediate danger or player ownership. | operations/CommitAIGroup | Sequence tests required. A fixed switch/retention rate is not the goal. |
| A06 | A healthy living base never triggers defeated-fleet extraction; automatic units remain within permitted battle bounds while active. | fleet_life/orders/lifecycle | Hard state/arena contract, including timers and recycled signatures. |
| A07 | Defeated survivors keep appropriate hostility/rearguard retaliation and physically reach extraction before native departure. | fleet_life; extraction probe | Hard lifecycle contract. Quiet/missing telemetry is not proof of escape. |
| R01 | Station loss, personal defeat, global strategic result, report visibility and mobile-fleet fate are separate states. | EvaluateFactionVictory/ui_text/fleet_life | Preserve elimination-only behavior and the immutable strategic snapshot. |
| R02 | Personal defeat/resume leaves surviving opponents' economies active until global resolution. | lifecycle/extraction probe | Hard gate; no premature global aftermath. |
| R03 | Global aftermath disables new income/builds/jobs/upgrades/abilities/service without deleting existing ships or weapons. | lifecycle/station/service/production | Hard gate; existing combat can continue. |
| R04 | Final sole-survivor/fleet-fate reporting considers hostile stations/sentries as well as mobile ships and omits Resume when final. | lifecycle/fleet_life | Test observation/end states, not just label text. |
| R05 | Death/departure cleanup is once-only and releases signatures, groups, targets, queues, cameras and engine handles. | lifecycle/factions/fleet_life | Keep death, escape and sale distinct; departure has no kill bounty. |
| R06 | Restart/shutdown resets mission clocks/caches and cannot transfer ownership or records onto recycled object signatures. | ResetState/ResetCoordinatedAI/history | Hard lifecycle gate; a green first mission does not cover restart. |

## Measurements for tuning, not invariants

| Goal | Primary measurement | Guardrail / interpretation |
| --- | --- | --- |
| Dependable commands | Native response time, completion, wrong-goal duration, unintended override count | Immediate controls must remain usable under pause/fire/repeat input. |
| Coordinated siege | Strike arrival spread, escort coverage, useful hostile damage and net objective progress | Account for weapon arcs, approach distance, healing, losses and resource cost. Assigned offensive value is context only. |
| Effective defense | Response to base-capable threats and station damage prevented over matched windows | Do not maximize home garrison or recall the entire fleet for harmless contacts. |
| Useful recovery | Actual ready/rejoin events, recovery time/cost, interruption and lost-returning ships | Compare to replacement cost and lost contribution. More repair is not inherently better. |
| Viable economy | Queue/payment/completion outcomes and saving episode progress | Consider affordability/deadlines/pressure; idle CP can be sensible saving. |
| Faction balance | Strategic elimination outcomes, time-to-event, confidence/uncertainty, slot-swapped matchup results | Capped games are unresolved observations, not wins or artificial draws. Do not compare pooled damage from both opponents as one AI-quality score. |
| Meaningful strategies | Exploit trials: fighter rush, bomber rush, static artillery, capital push, kiting, defense bait and recovery abuse | Evaluate counterplay and opportunity cost, not victory against one canned opponent. |
| Enjoyment/readability | Human pilot/RTS playtests and explicit friction observations | No automatic metric substitutes for clear controls, useful choices and acceptable frustration. |

## How to operate the verification system

Work from the current mod directory, never the empty old 1.4.1 shell. Use installed Python/lupa/pytest; no additional dependency is introduced.

```powershell
$env:PYTEST_DISABLE_PLUGIN_AUTOLOAD = '1'
python -m pytest --suite lua -q        # Lua-backed contract modules, with engine doubles
python -m pytest --suite static -q     # scope, parsing, source/assets
python -m pytest --suite tools -q      # analyzers, parsers, exports, harness itself
python -m pytest --suite all -q        # shared-path/release verification
```

Module classification is operational, not a promise that every test in a mixed Lua module executes engine behavior. A newly added test file must be classified in root `conftest.py`; a selected suite collecting zero tests is an error. Run the owning suite after a small change; run all after shared fixture/telemetry/verification changes. Test totals are inventory, not acceptance criteria.

For batches, use the documented sibling `RTS-fleet-command-artifacts/headless/headless.py` launcher. Keep fresh tags, frozen snapshots, valid pilot/VP inputs and distinct ports. Native probes with `--rendered` use pristine upstream; fixed-dt headless runs use the modified experiment engine.

```powershell
python core/tools/ai_invariants.py '<completed-batch>' --require-clean
python core/tools/compare_batches.py '<baseline>' '<candidate>' --json '<report.json>'
# Only after recording why this metric/direction answers the experiment question:
python core/tools/regression_gate.py '<candidate>' --baseline '<baseline>' --until 1800 --metric '<metric>' --polarity '<metric>=lower'
python core/tools/killcheck.py --guard '<specific-guard>' --json '<mutation-report.json>'
```

The invariant CLI gates accounting only: 0 = no reported accounting failures/unknowns, 1 = violation, 2 = incomplete/error. Malformed records prevent acceptance. JSON retains `kind` and legacy diagnostic statuses. Comparison schema **3** requires explicit directions and a common `--until` mission-time cutoff for metric gates. Every declared seed must be present once, with valid frozen provenance/completion, record sequence and selected-metric coverage. Engine/assets/setup must agree; script-policy changes are allowed. Legacy logs remain descriptive, but cannot satisfy the new gate. NOT_EVALUATED means no selected goals, INSUFFICIENT_EVIDENCE means prerequisites are absent, INCONCLUSIVE means selected results do not separate. Descriptive exit 0 is not gameplay acceptance; selected-metric PASS remains a median/MAD heuristic. Two seeds do not establish adequate statistical power.

Do not rerun every mutation after unrelated edits. Re-run mutations for changed guards/test seams. A missing anchor, timeout, setup/import failure or uncovered behavior is not a killed behavioral regression. Do not replace an assertion merely to get green.

The mutation CLI now obtains per-test completion/assertion evidence from pytest JUnit output. A baseline with failures or missing cases cannot establish coverage. Skipped parameters invalidate the corresponding test; a subprocess timeout is retained as HUNG with guard ERROR, rather than KILLED. Recorded sandbox writes and before/after source fingerprints are separate checks; a write-call count is not a byte count. Historical mutation verdicts remain historical and were not retroactively certified.

## Next work, in order

Follow [M1–M6 and the milestone ledger](#long-match-balance-contract). Freeze the M1 discovery manifest first. Expand tooling only to resolve a named missing observation or completion blocker. M2 requires a concrete failure, a causal hypothesis, one primary measure and declared guardrails; M3 uses untouched validation. M4–M6 have independent release criteria. Existing scripts, upstream probes and raw evidence remain the starting point.

Reaching an observation cap is unresolved, not a gameplay draw. A no-change conclusion is legitimate when the investigation establishes no repeatable problem; it is not a claim of universal balance. Inconclusive tuning is not promoted. Performance work stays parked.
