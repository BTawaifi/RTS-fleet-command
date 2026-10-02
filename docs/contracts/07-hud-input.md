# 07 — HUD and input

**Subsystems:** `core/data/scripts/fs2rts_hud.lua` (1837 lines),
`fs2rts_input.lua` (1484 lines)
**Prefix:** `HD-`

## PROMISES

**HD-1.** Every interactive rect table is rebuilt from scratch each frame.
`DrawHUD` clears all nine rect tables and all four transient fields before any draw
(`fs2rts_hud.lua:1789-1796`). Rationale: several draw paths return early
(cinematic, battle cam, free cam, post-battle, pilot mode), so a frame that skipped the
owning panel could otherwise leave clickable ghosts for `HandleUILeftClick` to act on
(`:1785-1788`).

**HD-2.** A new projection epoch begins every frame. `BeginFrameProjection`
(`fs2rts_input.lua:73`) increments `ProjectionEpoch` (`:74`) and initialises the
caches on the first call (`:75-79`). Rationale at `:61-72`: nothing can move a ship or
the camera between the epoch change and the end of the draw, so every projection taken
during a draw is as current as every other.

**HD-3.** A cached projection is only reused if it still belongs to the same hull.
`ProjectShip` checks `O[sig] == ship` (`fs2rts_input.lua:106`) *and*
`epoch - A[sig] <= maxAge` (`:106`). Rationale: the engine recycles signatures freely,
so a stale entry for a dead hull must not be handed back for whatever now owns that
number (`:103-105`).

**HD-4.** Click paths always project at the current epoch. `ProjectShip(ship, 0)`
is the click path; only the ambient reticle pass and the hover readout pass
`AMBIENT_PROJECT_EPOCHS` (`fs2rts_input.lua:38`, `:86-87`, `:120-122`).
Rationale: a reticle is a presence marker, not an animation, and at tactical range a
capital moves well under a pixel between two epochs.

**HD-5.** Projection overflow is handled as `false`, not `nil`.
`fs2rts_input.lua:110` normalises `px == false` to `(false, false)`. Every downstream
test compares against `false` explicitly (`:27-30`): `coords ~= nil` is true for the
engine's own off-screen answer and would treat a contact behind the camera as a
screen position.

**HD-6.** Expensive top-bar counters are sampled on a timer, not per frame.
`SampleTopBarCounters` (`fs2rts_hud.lua:61`) refreshes only every
`TOPBAR_SAMPLE_SECONDS` = 0.35 s (`:59`, `:64`). Rationale: two full `EachShip` passes
(thousands of ADE property reads) every frame purely to print numbers the player
cannot read changing at 60 Hz (`:55-58`).

**HD-7.** Top-bar layout is measured, left to right, and degrades in a fixed order.
`fs2rts_hud.lua:76-82`. Rationale: literal x positions made the note's right edge
(`sw-704`) fall behind its left edge (`770`) below ~1474 px, which is a
`gr.drawString` argument error the engine warns about once, and the tier readout
overwrote the policy field.

**HD-8.** Status text never overlaps the control legend. The status bar y is moved up
when the legend rect intersects it (`fs2rts_hud.lua:1827-1830`).

**HD-9.** The tactical map is drawn before panels and transient text.
`fs2rts_hud.lua:1812`. Rationale at `:1808-1811`: the map used to be redrawn after
`DrawAnnouncement` when popped out, so a 75%-opaque map covered the status message and
the escalation announcement sitting on top of it.

**HD-10.** Marker points are pooled, not reallocated. `RecycleMarkerPoints`
(`fs2rts_hud.lua:1331`) returns the list to `MARKER_POINT_POOL` (`:1330`), and
`DrawHUD` calls it every frame (`fs2rts_hud.lua:1797`).

**HD-11.** `ShouldOverrideKey` swallows every key the mod binds.
`fs2rts_input.lua:1437` builds one `handled` set from every `Config.HomeworldControls`
value, the pilot keys and the fixed ladder keys. Rationale at `fs2rts_config.lua:96-100`:
a key that is only bound in the input handler leaks to FSO and double-fires.

**HD-12.** Modifier prefixes are stripped before matching.
`fs2rts_input.lua:1420` strips `Shift-`, `Ctrl-`, `Alt-` from `rawKey`.

**HD-13.** Camera input and click handling are mutually exclusive with the modal
camera modes. `fs2rts_input.lua:1127` refuses to start a facing drag while a command is
armed, the game is paused, or battle cam / free cam are active.

## REFUSES

**HD-14.** `ProjectShip` refuses a nil ship or a nil `Position`
(`fs2rts_input.lua:88`), returning `(false, false)`.

**HD-15.** `PruneProjectionCache` refuses to carry forward an entry whose owner
mismatch (`:140`). Entries are rebuilt only from the live ship list (`:136-146`).

**HD-16.** `ShouldOverrideKey` refuses everything when the mod is disabled
(`fs2rts_input.lua:1419`), returns `true` wholesale during the cinematic (`:1425`),
returns `false` during post-battle (`:1426`), and returns `false` during setup
(`:1434`).

**HD-17.** `Esc` is swallowed except while paused (`fs2rts_input.lua:1424`), so the
native pause menu cannot flash mid-session.

**HD-18.** `DrawHUD` returns immediately when disabled (`fs2rts_hud.lua:1778`) and
short-circuits per modal mode (`:1799`, `:1800`, `:1801`, `:1805`, `:1806`).

## MUST NEVER

**HD-19.** **Never call `getScreenCoords` more than once per ship per frame on the
click path.** `fs2rts_input.lua:11-12`. Rationale: `code/scripting/api/objs/vecmath.cpp:668`
shows scripting is never inside a g3 frame, so `do_g3` is true on every call and the mod
opens and closes a full 3D frame per projection; there is no Lua binding that batches
them, so the only available wins are one call per ship and fewer ships.

**HD-20.** **Never read a name that is not in lexical scope at the line of use.** This
is the `RETICLE_COLOR_SELECTED` defect class: the constant was declared `local` 147
lines below its first use, so every use resolved to nil and crashed the live game
through 370 passing tests and a clean undefined-global check. Currently declared at
`fs2rts_hud.lua:878`, first used at `:881` — 3 lines later. Enforced by
`core/tools/lua_scope_order_check.py`; see CI-4.

**HD-21.** **Never leave a stale clickable rect.** HD-1's mechanism. A ghost rect
means a click acts on a button that was not drawn.

**HD-22.** **Never trust `sx ~= nil` as "on screen".** HD-5's mechanism; the engine
returns `false` for `PF_OVERFLOW`.

**HD-23.** **Never build a table that never changes inside a per-frame draw.**
`TOPBAR_SPEED_LABELS`, `TOPBAR_COLOR_*` (`fs2rts_hud.lua:86-91`), `ROLE_BADGES` (`:461`),
`ROLE_BADGE_COLORS` (`:466`), `CONTROLLER_COLORS` (`:252`) and
`ACTION_BUTTON_ROWS`/`LABELS` (`:261-263`) are module-level for this reason (`:84-85`).

**HD-24.** **Never key a cache on signature alone.** HD-3's mechanism; CI-3.

**HD-25.** **Never let a layout overflow become a draw call error.** HD-7's mechanism:
below ~1474 px the previous layout produced a `gr.drawString` argument error.

## INVARIANTS

**HD-I1 — Rect tables are empty or freshly built.**
*Algebraically:* at the top of every `DrawHUD`, for every rect table `R`,
`R == {}`. Enforced at `fs2rts_hud.lua:1789-1795`. Hence:
*no click can ever target a rect from a previous frame.*

**HD-I2 — Projection freshness.**
*Algebraically:* for any cached entry `s`,
`ProjectShip(ship, 0)` returns the cached value ⟹
`O[s] == ship AND epoch - A[s] <= 0`, i.e. the entry was written in the current epoch
(`fs2rts_input.lua:106`).

**HD-I3 — Ambient staleness bound.** Any projection returned by
`ProjectShipAmbient` was taken at most `AMBIENT_PROJECT_EPOCHS` = 2 epochs ago
(`fs2rts_input.lua:38`, `:121`).

**HD-I4 — Prune is amortised.** `ProjectionCacheNeedsPrune` fires at most once per
`PROJECTION_PRUNE_EPOCHS` = 30 epochs (`fs2rts_input.lua:44`, `:128`). Rationale:
every ambient epoch touches every live ship, so a rebuild cannot orphan a live entry
(`:40-43`).

**HD-I5 — Screen-gate correctness.** `BuildScreenGate` (`fs2rts_input.lua:165`) works
in tangent space because the set of world directions landing inside a screen rectangle
is a rectangle in tangent space (`fs2rts_input.lua:154-158`). The horizontal axis
carries an allowance for the `gr_screen.aspect` term scripting cannot read
(`fs2rts_input.lua:56-59`, constants at `:58-59`); the vertical axis is exact.

**HD-I6 — Key binding totality.** *Algebraically:* for every key `k` in
`Config.HomeworldControls` **and** every `Config.Pilot` binding key,
`ShouldOverrideKey(k, k) == true` whenever the session owns the screen and no modal
mode is active. Enforced by the single `handled` set at `fs2rts_input.lua:1437`, with
`fs2rts_config.lua:96-100` stating the requirement and `core/README.md:127` claiming a
test pins it.

**HD-I7 — Per-frame walk budget (algebraic).** Full-fleet `EachShip` walks per frame
must be bounded by a sampling interval, not per frame. The HUD-side instance:
`SampleTopBarCounters` at 0.35 s (`fs2rts_hud.lua:59`). The AI-side instances are
documented in [03-ai-production.md](03-ai-production.md) PR-7 and
[08-strategy-planning.md](08-strategy-planning.md).

**HD-I8 — Draw order is fixed.**
`DrawHUD`'s fixed sequence (after the modal early-returns at `:1799-1806`):
world overlays (`:1812`), strike warnings (`:1813`), top bar (`:1814`), tactical map
(`:1815`), then panels (`:1817-1819`), then transient status (`:1821-1834`),
announcement (`:1835`), hover readout (`:1836`). *Any early return after `:1805` must
preserve the invariant that the map is drawn before the panels.*

## Currently UNVERIFIED

- **HD-I6 (key totality).** `_Claimed, not run by me._` `core/README.md:127` states
  `test_feature_request.py` checks "that every bound key is also swallowed by
  `ShouldOverrideKey`". I did not run it this session.
- **HD-I2 (freshness).** `_Unverified._` **Would verify it:** prime a projection,
  advance the epoch, assert `ProjectShip(ship, 0)` re-queries while
  `ProjectShip(ship, 2)` does not.
- **HD-I4 (prune amortisation).** `_Unverified._` **Would verify it:** run 100 epochs
  with one hull dying and assert `PruneProjectionCache` ran at most 4 times.
- **HD-I7 (walk budget).** `_Unverified as a count._` `test_hud_perf.py` exists
  (referenced by name only). **Would verify it:** a ship double that counts `EachShip`
  callbacks across 1 s of frames and asserts a bounded number.
- **HD-I5 (gate correctness).** `_Unverified._` The tangent-space derivation is a
  comment citing `code/render/3dmath.cpp:247` and `code/render/3dsetup.cpp:187`, which
  I did not open. **Would verify it:** for a grid of world positions, assert
  `PassesScreenGate(BuildScreenGate(...), p)` implies `getScreenCoords` lands inside the
  rectangle, across a range of resolutions.
- **HD-20 (scope).** `_Verified._` `lua_scope_order_check.py` reports 0 findings on the
  current tree, with the engine allowlist generated from the FSO source rather than
  hand-typed. Per the agent that built it — I did not re-run it this session.
- **Ghost-rect behaviour (HD-21).** `_Partially verified._` `core/README.md:127` claims
  a key-swallowing test; the rect-clearing order itself is asserted by reading only.

## VIOLATIONS

### V-1 — HD-7's config surface does not exist: `Config.BattleCam`

`fs2rts_camera.lua:366`:

```lua
local cfg=self.Config.BattleCam or {}
```

`cfg.ShotSeconds` (`:371`) and `cfg.OrbitRadiansPerSecond` (`:375`) are read from this
table. **`fs2rts_config.lua` defines no `BattleCam` table.** Verified by reading all
994 lines of the config and by a pattern scan for `^\s*BattleCam\s*=` across the whole
`scripts/` directory — zero matches. The camera config block is `Config.Camera`
(`fs2rts_config.lua:64`), a different table with no `ShotSeconds` and no
`OrbitRadiansPerSecond`.

*Consequence:* the `or {}` fallback means battle-cam shot length and orbit rate are the
hardcoded literals 9 s and 0.12 rad/s and are **not tunable from config**. This does
not crash and does not misbehave; it is a documented-as-configurable control surface
that does not exist.

**This is not a defect in `fs2rts_hud.lua` or `fs2rts_input.lua`**, which is why it
appears here rather than in a camera contract — no camera contract exists (see below).
It belongs to `fs2rts_camera.lua` (430 lines, 21 `RTS:` methods, none of them
covered by this contract set).

**Violates the implied promise of a config-driven control surface; no sentence in this
contract is broken, which is itself the finding — the contract set has a gap.**

Note that `core/tools/test_camera_director.py` is *aware* of this and asserts the
absence deliberately: `:128` asserts `R.Config.BattleCam==nil` ("fixture: the shipped
config has no BattleCam table"), `:214` asserts `"BattleCam ="` is not in the config
source, and `:100` documents that "the `Config.BattleCam` table ... the shipped
configuration does not provide". So the fallback literals are pinned as intended
behaviour by the test suite, and the *naming* is the actual defect: a value read from
`Config.BattleCam` implies a `Config.BattleCam` that a maintainer would expect to find
and edit, and editing `Config.Camera` would silently do nothing.

### V-2 — Contract-set gap: no camera contract

`fs2rts_camera.lua` exists (430 lines, verified by Glob) and contains the tactical
camera, chase mode, follow mode, free cam and the battle director. **This contract set
does not document it**, because the brief's subsystem list did not name it and
`fs2rts_spawn.lua` / `fs2rts_wing.lua` (also named) do not exist.

Recorded rather than filled: writing a camera contract requires reading
`fs2rts_camera.lua` in full, which was not in scope for this pass. The gap is stated
so the next reader does not assume the camera is covered.

**Violates nothing; the absence is the violation of the method.** A contract set with
a hole in it will be read as complete.