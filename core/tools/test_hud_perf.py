"""HUD projection cost, and the interaction defects around picking and input.

Run: python -m pytest test_hud_perf.py    (or: python -m pytest, from this dir)

These drive the real shipped Lua through the same engine doubles test_station.py
installs, plus a projection double that reproduces the engine's own pinhole
(so the frustum gate and the engine answer are computed the same way and can be
compared against each other rather than against a stub).

There are two things being pinned here, and the first is much more important
than the second.

THE PROJECTION COST. getScreenCoords is not a query. In
code/scripting/api/objs/vecmath.cpp:668 it does

    bool do_g3 = G3_count < 1;
    if (do_g3) g3_start_frame(1);
    g3_rotate_vertex(&vtx, &v3);
    g3_project_vertex(&vtx);
    if (do_g3) g3_end_frame();

Scripting never runs inside a g3 frame, so do_g3 is true on every call and each
one opens and closes a full 3D frame. The HUD used to make two of them for
every ship in the world on every frame -- the reticle pass projected the whole
world, then the hover pick projected it again -- which is 600 a frame on a 300
hull board. There is no Lua binding that opens a g3 frame, so these cannot be
batched; the fix is one call per ship and fewer ships reaching it.

THE FALSE CULL. A gate that skips a projection the engine would have made
on-screen turns into a dropped click, and a gate that skips one the engine
would have made off-screen only costs a wasted call. The asymmetry is why
test_the_gate_never_rejects_a_ship_the_engine_would_have_projected_on_screen
is the load-bearing test in this file, and why the gate is written to fail open
whenever the engine cannot describe the view: a missing gr.getEyeFOV, a missing
getUvec, no camera, all of them return nil and the caller projects everything.

The rest are the interaction defects: a world drag released over a panel, an
armed order released on the map, a map click that disagreed with a map drag
about what is hostile, a click that never became the primary selection, a
ten-pixel dead strip between the two opponent toggles, and a top bar that
threw away readouts because they did not fit rather than shortening them.
"""
import unittest

from lupa.lua51 import LuaRuntime
from test_station import SETUP, SCRIPTS

# Installed after the mod loads, the way test_feature_request.py does.
#
# The camera sits at camZ looking down +z with +x right and +y up, which is the
# mod's own convention (build-rotation about y, then pitch, so the camera looks
# down). TANH is the horizontal tan(FOV/2) the engine actually uses: FSO stores
# the camera fov as a "zoom" and multiplies it by PROJ_FOV_FACTOR before
# projecting (code/render/3dsetup.h:57, code/render/3dsetup.cpp:127 and :193).
EXTRA = r'''
io=io or {}
io.getMouseX=io.getMouseX or function() return 960 end
io.getMouseY=io.getMouseY or function() return 300 end
io.setCursorHidden=io.getCursorHidden or function() end
ba.postGameEvent=ba.postGameEvent or function() end
ba.setButtonControlMode=ba.setButtonControlMode or function() end
bit=bit or {checkBit=function() return false end}

SCREEN_W=1920; SCREEN_H=1080
FONT_W=6
function setScreen(w,h) SCREEN_W=w; SCREEN_H=h end
gr={setCamera=function() end,
  loadTexture=function() return {isValid=function() return true end,getWidth=function() return 128 end,getHeight=function() return 128 end} end,
  getScreenWidth=function() return SCREEN_W end,
  getScreenHeight=function() return SCREEN_H end,
  setColor=function() end,
  getStringWidth=function(text) return #tostring(text)*FONT_W end,
  drawRectangle=function() end,
  drawString=function() end,
  drawLine=function() end, drawCircle=function() end, drawRectangleCentered=function() end,
  drawImage=function() end,
  drawTargetingBrackets=function() return nil end,
  setTarget=function() end, clearScreen=function() end, createTexture=function() return false end,
  getEyeFOV=function() return 1.02 end}
CAMZ=-9000
function setCameraZ(z) CAMZ=z; r.Camera.Position=ba.createVector(0,0,z) end
r.Camera={Position=ba.createVector(0,0,CAMZ),Orientation={
  getFvec=function() return ba.createVector(0,0,1) end,
  getRvec=function() return ba.createVector(1,0,0) end,
  getUvec=function() return ba.createVector(0,1,0) end,
  copy=function() return {} end},FOV=1.02}
r.CameraFocus=ba.createVector(0,0,0)
r.Enabled=true; r.SetupActive=false; r.Paused=false; r.PostBattleActive=false
r.CinematicActive=false; r.BattleCamActive=false; r.FreeCamActive=false
r.PossessedSignature=nil; r.FollowSignature=nil
r.UIClock=0; r.UINow=function(self) return self.UIClock end
r.SetStatus=function() end
r.IsPointOnRTSUI=function() return false end
r.IsPointOnTacticalMap=function() return false end
r.ScreenToPlane=function(self,x,y) return ba.createVector(x,0,y) end
r.DrawShipModelThumb=function() return false end
r.GetBriefingIcon=function() return nil end
r.GetShipWeaponRange=function() return 0 end
r.BuildCatalog={}
for i=1,9 do
  r.BuildCatalog[i]={class='GTF Build '..i,role=(i<=3 and 'fighter' or (i<=6 and 'bomber' or 'escort')),
    tier=1,label='Build '..i,cost=100,time=60,count=1}
end
r.BuildRoleFilter='all'; r.BuildPage=1
r.CommandPoints=5000
r.PanelTab='production'
r.GetCarrier=function() return stations.BLUE end
r.IsBuildOptionUnlocked=function() return true end
r.GetProductionQueueStatus=function() return nil end
r.AutoPlayerMode=false
r.ArmedCommand=nil
r.GlobalPolicy='HOLD'
r.Selected={}function r:GetSelectedShips() return self.testSelection or {} end
function r:GetSelectedFriendlyShips() return {} end
function r:GetControlGroupCount() return 0 end
r.Formations={{id='wedge',label='Wedge',desc='Tight wedge'}}
r.SelectedFormation='wedge'
function r:GetFormationTypes() return self.Formations end
function r:GetSelectedFormation() return 'wedge' end
r.MusicMuted=false
r.MapView=nil

-- ---- the projection double ------------------------------------------------
-- The engine's map, verbatim (code/render/3dmath.cpp:247, with the rvec/uvec
-- scaling of code/render/3dsetup.cpp:187, window aspect assumed 1):
--     sx = W/2 * (1 + (d.r/d.f)/tanH)     sy = H/2 * (1 - (d.u/d.f)/tanH)
-- and PF_OVERFLOW when d.f <= 0, which getScreenCoords reports as false.
PROJ_CALLS=0
TANH=math.tan(1.02*1.39626348/2)
gr.getVectorFromCoords=function(x,y,depth)
  local dx=(x/(SCREEN_W*.5)-1)*TANH
  local dy=(1-y/(SCREEN_H*.5))*TANH
  local length=math.sqrt(dx*dx+dy*dy+1)
  return ba.createVector(dx*depth/length,dy*depth/length,CAMZ+depth/length)
end
function projected(x,y,z)
  PROJ_CALLS=PROJ_CALLS+1
  local dx,dy,dz=x,y-0,z-CAMZ
  local depth=dz
  if depth<=0 then return false end
  return SCREEN_W*0.5*(1+(dx/depth)/TANH), SCREEN_H*0.5*(1-(dy/depth)/TANH)
end
function mkpos(x,y,z)
  local p={x=x,y=y,z=z}
  p.getScreenCoords=function() return projected(x,y,z) end
  p.getDistance=function(self,other)
    local dx=x-other.x; local dy=y-other.y; local dz=z-other.z
    return math.sqrt(dx*dx+dy*dy+dz*dz)
  end
  return p
end
function resetCalls() PROJ_CALLS=0 end
function calls() return PROJ_CALLS end
function clearProjectionCache()
  r.ProjectionEpoch=nil; r.ProjectionX=nil; r.ProjectionY=nil
  r.ProjectionOwner=nil; r.ProjectionAt=nil; r.ProjectionPrunedAt=0
  r.DecorationGrid=nil
end

-- test_station's SETUP keeps its own `ships` array, which r.GetShipList and
-- r.EachShip are stubbed to read, and appends every ship() to it. It has to be
-- reset with mn.Ships or the board silently accumulates across calls.
function clearBoard() ships={}; mn.Ships={} end
function addShip(name,className,pos,teamName,role)
  local s=ship(name,class(className or 'GTF Aries'),pos or mkpos(0,0,0),
               teamName and mn.Teams[teamName] or mn.Teams.friendly)
  s.role=role or 'fighter'
  return s
end
function buildBoard(n,extent,camZ)
  clearBoard()
  if camZ~=nil then setCameraZ(camZ) end
  for i=1,(n or 300) do
    local side=(i%2==0) and 'friendly' or 'hostile'
    local x=((i*7919)%(2*extent))-extent
    local z=((i*104729)%(2*extent))-extent
    addShip('P '..i, (i%9==0) and 'SF Mara' or 'GTF Aries',
            mkpos(x, ((i*13)%400)-200, z), side)
  end
end
function boardFrame()
  -- ResetState leaves the mod in the pre-battle setup state, which swallows
  -- every mouse event, so the fixtures put it back into the playing state.
  local camera=r.Camera
  r:ResetState(); r.Camera=camera; r.SetupActive=false; r.testSelection={}
  r.UIMetrics=nil; r.MapView=nil; r.Enabled=true; r.PossessedSignature=nil
  r.CinematicActive=false; r.PostBattleActive=false
  r.UIClock=1; r.TopBarCounters=nil; r.TopBarFieldCache=nil
  clearProjectionCache()
end
-- test_station's SETUP replaces GetEscalationProfile with {buildTimeScale=1},
-- which has no name and no targetSeconds. The real one reads the configured
-- duration table, and both the top bar's escalation clock and the setup screen
-- are sized by those two numbers, so the fixtures put the real logic back
-- rather than measuring the bar against a one-word clock.
function realDurationProfile(self)
  return self.Config.Escalation
end
-- The setup screen reads its pickers through these indices, and ResetState
-- leaves them nil, which DrawSetupOverlay then concatenates.
function setupScreen(width, height)
  r:ResetState(); r.SetupActive=true
  r.SetupOpponents={RED=true,GOLD=false}
  r.SetupDifficultyIndex=1; r.SetupEconomyIndex=1
  r.SetupBaseDistanceIndex=1
  r.SetupFactionCount=2
  r.GetEscalationProfile=realDurationProfile
  setScreen(width,height); r.UIMetrics=nil
end
'''

# A 300 hull board over the scenario's +/-15km footprint. A 24x24 grid of
# lateral/depth/vertical combinations for the gate-safety sweep.
SWEEP = r'''
local checked, culled, onScreen = 0, 0, 0
local gate = r:BuildViewportGate(SCREEN_W, SCREEN_H)
for _,depth in ipairs({50,200,1000,5000,9000,20000,60000}) do
  for lateral=-40000,40000,733 do
    for _,vert in ipairs({-3000,0,3000}) do
      local pos = {x=lateral,y=vert,z=depth}
      local sx, sy = projected(lateral, vert, depth)
      local engineOnScreen = (sx ~= false and sx >= 0 and sy >= 0
                              and sx <= SCREEN_W and sy <= SCREEN_H)
      checked = checked + 1
      if engineOnScreen then onScreen = onScreen + 1 end
      if not r:PassesScreenGate(gate, pos) then
        culled = culled + 1
        assert(not engineOnScreen,
          'the gate rejected a point at lateral '..lateral..' depth '..depth
            ..' vert '..vert..' but the engine projects it on screen at '
            ..tostring(sx)..','..tostring(sy))
      end
    end
  end
end
-- and the converse has to hold too, or the gate is not earning its keep
local skippedOnScreen = 0
for _,depth in ipairs({1000,9000,20000}) do
  for lateral=-20000,20000,911 do
    for _,vert in ipairs({-2000,0,2000}) do
      local sx, sy = projected(lateral, vert, depth)
      if sx ~= false and sx >= 0 and sy >= 0 and sx <= SCREEN_W and sy <= SCREEN_H then
        assert(r:PassesScreenGate(gate, {x=lateral,y=vert,z=depth}),
          'the gate rejected an on-screen point at '..sx..','..sy)
        skippedOnScreen = skippedOnScreen + 1
      end
    end
  end
end
return checked, culled, onScreen, skippedOnScreen
'''


def boot():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
    lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
    lua.execute(SETUP)
    lua.execute(EXTRA)
    return lua


class ProjectionCostTests(unittest.TestCase):
    """How many getScreenCoords a frame actually costs, and how few."""

    def setUp(self):
        self.lua = boot()

    def check(self, code):
        return self.lua.execute(code)

    def test_a_full_board_frame_makes_fewer_than_one_projection_per_ship(self):
        """The defect: 600 projections a frame on a 300 hull board, because the
        reticle pass projected every ship in the world and then the hover pick
        projected every ship in the world again. Each one is a whole g3 frame
        (vecmath.cpp:681-689). The budget is one per ship per frame, and in
        practice a third of that, because the ambient pass refreshes on a round
        robin and the gate rejects the off-screen contacts outright."""
        before, after, ships = self.check(r"""
          setScreen(1920,1080)
          buildBoard(300,15000,-9000); boardFrame()
          -- Configuration A: the old code. No cache (every consumer projects for
          -- itself) and no gate (nothing rejects a ship before projecting).
          local realProject,realGate=r.ProjectShip,r.BuildScreenGate
          r.ProjectShip=function(self,s,maxAge)
            local a,b=s.Position:getScreenCoords()
            if a==false then return false,false end
            return a,b
          end
          r.BuildScreenGate=function() return nil end
          resetCalls()
          for i=1,20 do r.UIClock=i*0.016; r:DrawHUD() end
          local noCache=calls()
          r.ProjectShip=realProject; r.BuildScreenGate=realGate
          clearProjectionCache()
          resetCalls()
          for i=1,20 do r.UIClock=100+i*0.016; r:DrawHUD() end
          return noCache, calls(), #ships
        """)
        self.assertEqual(ships, 300)
        self.assertEqual(before / 20.0, 600.0,
                         "the unoptimised baseline is not the 2-per-ship the old "
                         "code did, so this measurement is not comparable")
        self.assertLess(after / 20.0, 300.0,
                        "a frame still makes a projection for every ship in the world")
        self.assertGreaterEqual(before / max(1, after), 3.0,
                                "the fix is not buying a 3x reduction in g3 frames")

    def test_one_projection_per_ship_however_many_consumers_ask_for_it(self):
        """The reticle pass, the hover pick and the readout all want the same
        hull's screen position in the same epoch. They used to each pay for
        their own."""
        calls = self.check(r"""
          clearBoard(); setCameraZ(-9000)
          local s=addShip('one','GTF Aries',mkpos(0,0,-1000),'friendly')
          boardFrame()
          r:BeginFrameProjection()
          resetCalls()
          for i=1,25 do r:ProjectShip(s,0) end
          local inOneEpoch=calls()
          r:BeginFrameProjection()
          for i=1,25 do r:ProjectShip(s,0) end
          return inOneEpoch, calls()
        """)
        self.assertEqual(calls[0], 1,
                         "25 consumers in one epoch made 25 g3 frames")
        self.assertEqual(calls[1], 2,
                         "a new epoch did not re-project, so a stale answer is "
                         "being served across frames")

    def test_ambient_projections_are_reused_but_strict_ones_are_not(self):
        """The reticle is a presence marker and a hull moves well under a pixel
        in two epochs at tactical range, so the ambient set is refreshed on a
        round robin. Selection and hover are the thing the player is pointing
        at, so they are never allowed to ride a stale answer."""
        result = self.check(r"""
          clearBoard(); setCameraZ(-9000)
          local s=addShip('one','GTF Aries',mkpos(0,0,-1000),'friendly')
          boardFrame()
          r:BeginFrameProjection()
          r:ProjectShip(s,0)                     -- makes the entry
          local before=calls()
          for i=1,5 do r:ProjectShip(s,0) end
          r:ProjectShipAmbient(s)               -- strict and ambient, same epoch
          local sameEpoch=calls()-before
          r:BeginFrameProjection()
          r:ProjectShipAmbient(s)               -- one epoch old: still fine
          local oneOld=calls()-before
          r:BeginFrameProjection()
          r:ProjectShipAmbient(s)               -- two epochs old: refreshed
          r:BeginFrameProjection()
          r:ProjectShipAmbient(s)               -- and not refreshed again
          local settled=calls()-before
          -- a strict read in an epoch that already has a fresh entry
          r:BeginFrameProjection()
          r:ProjectShip(s,0)
          before=calls()
          for i=1,5 do r:ProjectShip(s,0) end
          local strictSame=calls()-before
          -- and a strict read in a new epoch, where the cached entry is stale
          r:BeginFrameProjection()
          before=calls(); r:ProjectShip(s,0)
          local strictNew=calls()-before
          return sameEpoch, oneOld, settled, strictSame, strictNew
        """)
        self.assertEqual(result[0], 0,
                         "consumers in one epoch re-projected, so the reticle pass "
                         "and the hover pick are each paying for the same hull")
        self.assertEqual(result[1], 0, "a one-epoch-old ambient entry was thrown away")
        self.assertEqual(result[2], 1,
                         "the ambient set is not refreshing on its round robin: "
                         "an entry two epochs old should be taken once and the "
                         "one after it reused, so two epochs cost one projection")
        self.assertEqual(result[3], 0, "a strict read re-projected inside its own epoch")
        self.assertEqual(result[4], 1,
                         "a strict read served a stale entry from a previous epoch, "
                         "so a click can select a ship that has moved since")

    def test_a_recycled_signature_does_not_return_the_previous_hulls_position(self):
        """The engine reuses signatures freely. A cache keyed only on the
        signature would hand a dead capital's screen position back to whatever
        fighter now owns that number, and the fighter would be drawn - and
        clickable - at the wrong place. The double hands out fresh signatures,
        so this forces the reuse the engine would do on its own."""
        before, after = self.check(r"""
          clearBoard(); setCameraZ(-9000)
          local dead=addShip('dead','SF ULYSSES',mkpos(0,0,-1000),'hostile')
          local sig=dead:getSignature()
          boardFrame()
          r:BeginFrameProjection()
          local dx,dy=r:ProjectShip(dead,0)
          local first=tostring(dx)..','..tostring(dy)
          -- the capital is destroyed; the engine recycles its signature onto a
          -- fighter somewhere else entirely
          clearBoard()
          local fresh=addShip('fresh','GTF Aries',mkpos(3000,500,4000),'friendly')
          fresh.getSignature=function() return sig end
          local sx,sy=r:ProjectShip(fresh,0)
          return first, tostring(sx)..','..tostring(sy)
        """)
        self.assertNotEqual(before, after,
                            "the new hull was served the dead hull's cached "
                            "projection, so its reticle and its hit test are both "
                            "at the old capital's position")

    def test_the_cache_drops_ships_that_leave_the_world(self):
        """Every entry is a signature the mod will never use again if the hull
        is gone, and a long battle spawns and kills hundreds. Without a prune
        the cache is a leak that only the end of the mission clears."""
        before, after = self.check(r"""
          clearBoard(); setCameraZ(-9000)
          for i=1,50 do addShip('g '..i,'GTF Aries',mkpos(i*100,0,-5000),'hostile') end
          boardFrame()
          for i=1,40 do r:BeginFrameProjection(); r:ProjectShip(ships[i],0) end
          local filled=0
          for _ in pairs(r.ProjectionX) do filled=filled+1 end
          -- everyone dies, two new hulls appear
          for i=1,50 do ships[i].valid=false end
          clearBoard()
          addShip('a','GTF Aries',mkpos(0,0,-2000),'friendly')
          addShip('b','GTF Aries',mkpos(200,0,-2000),'friendly')
          r.ProjectionPrunedAt=-1000
          r:BeginFrameProjection()
          r:PruneProjectionCache()
          local kept=0
          for _ in pairs(r.ProjectionX) do kept=kept+1 end
          return filled, kept
        """)
        self.assertGreater(before, 30, "fixture: the cache never filled")
        self.assertEqual(after, 0,
                         "the cache kept projections for hulls that no longer exist")


class GateTests(unittest.TestCase):
    def test_facing_overlay_accepts_a_destination_behind_the_camera(self):
        lua=boot()
        lua.execute('''
          clearBoard(); setCameraZ(-9000)
          local s=addShip('hovered','GTF Aries',mkpos(0,0,0),'friendly')
          r.Selected={s:getSignature()}; r.HoveredSelectionSigs={}
          r.GetShipAtScreen=function() return s end
          local dest=ba.createVector(0,0,-10000)
          local facing=ba.createVector(0,0,10000)
          local vm=getmetatable(dest)
          vm.getScreenCoords=function(p) return projected(p.x,p.y,p.z) end
          r.UserOrders[s:getSignature()]={kind='move',destination=dest,facing=facing}
          r:BeginFrameProjection(); r:DrawWorldOverlays()
        ''')

    """The pre-projection frustum test, and in particular that it cannot cost a
    click."""

    def setUp(self):
        self.lua = boot()

    def check(self, code):
        return self.lua.execute(code)

    def test_the_gate_never_rejects_a_ship_the_engine_would_have_projected_on_screen(self):
        """The asymmetry that matters. Rejecting a ship the engine would have
        put on screen means a click that lands on a reticle selects nothing.
        Rejecting one it would have put off screen only wastes the call. The
        sweep covers three decades of depth, the full width of the board, and
        heights above and below the viewport, and requires both directions:
        every rejection is confirmed off-screen by the engine's own projection,
        and every on-screen point is admitted."""
        checked, culled, on_screen, admitted = self.check(SWEEP)
        self.assertGreater(checked, 400, "fixture: the sweep is vacuous")
        self.assertGreater(culled, 0, "fixture: the gate culled nothing")
        self.assertGreater(on_screen, 100, "fixture: the sweep found nothing on screen")
        self.assertGreater(admitted, 0, "fixture: the second sweep admitted nothing")

    def test_the_gate_rejects_a_hull_on_or_behind_the_camera_plane(self):
        """The live half of a defect that reads as already fixed. g3_project_vertex
        flags z < MIN_Z as PF_OVERFLOW and getScreenCoords reports that as
        false, so a hull behind the camera was already rejected -- but the
        z == 0 case takes a different branch: it ORs in `PF_OVERFLOW &
        PF_PROJECTED` (3dmath.cpp:233), which is 2 & 1 == 0, so the overflow
        flag comes back CLEARED and the point is reported as screen (0,0). A
        hull sitting exactly on the camera plane was pickable at the top-left
        pixel of the screen."""
        self.check(r"""
          setScreen(1920,1080); setCameraZ(-9000)
          local gate=r:BuildViewportGate(SCREEN_W,SCREEN_H)
          assert(not r:PassesScreenGate(gate,{x=0,y=0,z=-9000}),
            'a point on the camera plane passed the gate')
          assert(not r:PassesScreenGate(gate,{x=0,y=0,z=-9500}),
            'a point behind the camera plane passed the gate')
          assert(not r:PassesScreenGate(gate,{x=0,y=0,z=-20000}),
            'a point far behind the camera plane passed the gate')
          assert(r:PassesScreenGate(gate,{x=0,y=0,z=-8000}),
            'a point just in front of the camera was rejected, so an object the '
              ..'player is looking straight at cannot be picked')
        """)

    def test_the_gate_fails_open_when_the_engine_cannot_describe_the_view(self):
        """The gate is an optimisation. If any input it needs is missing it
        returns nil and every caller projects everything, which is exactly the
        old behaviour. A gate that quietly returned an empty region when it
        could not build itself would stop the player clicking their own fleet."""
        for removal in ("getUvec", "getFvec", "getRvec"):
            lua = boot()
            lua.execute("""
              if '%s'=='getUvec' then r.Camera.Orientation.getUvec=nil end
              if '%s'=='getFvec' then r.Camera.Orientation.getFvec=nil end
              if '%s'=='getRvec' then r.Camera.Orientation.getRvec=nil end
            """ % (removal, removal, removal))
            gate = lua.execute("return r:BuildViewportGate(1920,1080)")
            self.assertIsNone(gate,
                              "with the camera missing %s the gate still built a "
                              "region, from a basis it does not have" % removal)
        # and no camera at all
        lua = boot()
        lua.execute("r.Camera=nil")
        self.assertIsNone(lua.execute("return r:BuildViewportGate(1920,1080)"),
                          "the gate built a region with no camera")

    def test_the_gate_still_works_without_gr_getEyeFOV(self):
        """Native screen rays calibrate the gate independently of getEyeFOV."""
        lua = boot()
        lua.execute("gr.getEyeFOV=nil")
        gate = lua.execute("return r:BuildViewportGate(1920,1080)")
        self.assertIsNotNone(gate, "the gate gave up when only gr.getEyeFOV was missing")
        self.assertGreater(gate.tolA, 0)
        self.assertGreater(gate.tolB, 0)

    def test_off_center_pick_gate_agrees_with_native_projection_model(self):
        lua = boot()
        lua.execute('''
          for _,fraction in ipairs({.15,.3,.7,.85}) do
            local x,y=SCREEN_W*fraction,SCREEN_H*.25
            local point=gr.getVectorFromCoords(x,y,5000,false)
            local sx,sy=projected(point.x,point.y,point.z)
            assert(math.abs(sx-x)<.001 and math.abs(sy-y)<.001)
            local gate=r:BuildPickGate(x,y,SCREEN_W,SCREEN_H,24)
            assert(gate and r:PassesScreenGate(gate,point),'native cursor point rejected')
          end
        ''')

    def test_a_contact_the_gate_rejects_is_not_projected_but_still_gets_a_border_marker(self):
        """The gate is only allowed to be free for the off-screen contacts, and
        only because those contacts get a border marker, which is derived from
        the camera basis and needs no projection. If a culled contact stopped
        being drawn at all, the save would be a contact the player cannot see."""
        projections, on_screen, border = self.check(r"""
          setScreen(1920,1080)
          buildBoard(300,15000,-500); boardFrame()   -- zoomed in: most is off screen
          r.EdgeMarkerPoints=nil
          resetCalls()
          r:BeginFrameProjection()
          r:DrawWorldOverlays()
          local drew=calls()
          -- and how many of the board is genuinely on screen, per the engine.
          -- Read after `drew`, because this loop projects on its own account.
          local onScreen=0
          for i=1,#ships do
            local sx,sy=ships[i].Position:getScreenCoords()
            if sx~=false and sx>=0 and sy>=0 and sx<=SCREEN_W and sy<=SCREEN_H then onScreen=onScreen+1 end
          end
          return drew, onScreen, #(r.EdgeMarkerPoints or {})
        """)
        self.assertGreater(on_screen, 20, "fixture: the board is not mostly on screen")
        self.assertGreater(border, 0,
                           "no border marker was placed, so a culled contact is invisible")
        self.assertLess(projections, 300,
                        "every ship in the world was projected anyway, so the gate is not "
                        "rejecting anything")

    def test_a_rejected_contact_is_still_reachable_by_a_click(self):
        """The whole reason the gate is allowed to reject a contact at all: the
        contact is not on screen, so no click can be aiming at it, and the
        border marker takes its place. A contact on screen must stay pickable,
        which is the direction the sweep above covers; this is the direction
        that would actually be felt."""
        picked, marker = self.check(r"""
          setScreen(1920,1080); setCameraZ(-9000)
          clearBoard()
          local s=addShip('dead ahead','GTF Aries',mkpos(0,0,-8000),'hostile')
          boardFrame()
          -- where the engine puts it
          local sx,sy=s.Position:getScreenCoords()
          r:BeginFrameProjection()
          local hit=r:GetShipAtScreen(sx,sy,true,true,true)
          r.EdgeMarkerPoints={}
          r:BeginFrameProjection()
          r:DrawWorldOverlays()
          return hit and hit.Name or 'MISS', #(r.EdgeMarkerPoints or {})
        """)
        self.assertEqual(picked, "dead ahead",
                         "a contact in the middle of the screen cannot be clicked")
        self.assertEqual(marker, 0,
                         "a contact in the middle of the screen was pinned to the border")


class MapTests(unittest.TestCase):
    """The tactical map's own hot path and its two disagreeing pickers."""

    def setUp(self):
        self.lua = boot()

    def check(self, code):
        return self.lua.execute(code)

    def test_the_map_rect_is_built_once_per_frame_not_once_per_ship(self):
        """WorldToTacticalMap rebuilt the rect, the view centre and the
        configured half extent on every call, and it is called once per ship.
        With 300 contacts that is 300 identical rectangles a frame."""
        same_rect, same_frame, followed, popped_x1, docked_x1 = self.check(r"""
          setScreen(1920,1080); r.UIMetrics=nil; r.MapView=nil
          r:ResetState(); r.SetupActive=false
          local a=r:GetTacticalMapRect()
          local b=r:GetTacticalMapRect()
          local f1=r:GetTacticalMapFrame()
          local f2=r:GetTacticalMapFrame()
          -- and it must still follow the geometry when that changes
          r.MapView.popped=true
          r.MapView.x=400; r.MapView.y=300; r.MapView.w=700; r.MapView.h=400
          local popped=r:GetTacticalMapRect()
          return a==b, f1==f2, (popped~=b), popped.x1, a.x1
        """)
        self.assertTrue(same_rect, "the map rect is rebuilt on every call")
        self.assertTrue(same_frame, "the map window rect is rebuilt on every call")
        self.assertTrue(followed, "the cached map rect survived a window move")
        self.assertEqual(popped_x1, 400, "the popped map rect ignored the window x")
        self.assertNotEqual(docked_x1, 400)

    def test_the_map_rect_follows_a_resolution_change(self):
        """The cache key is built from the cached UI metrics, so a resize has to
        invalidate it -- otherwise the map keeps projecting into the old
        window's coordinates after the player drags the window edge."""
        widths = self.check(r"""
          setScreen(1920,1080); r.UIMetrics=nil; r.MapView=nil
          r:ResetState(); r.SetupActive=false
          local out={}
          for _,res in ipairs({{1920,1080},{1280,720},{3840,2160},{1600,900}}) do
            setScreen(res[1],res[2]); r.UIMetrics=nil
            local rect=r:GetTacticalMapRect()
            out[#out+1]=tostring(rect.x1)..'-'..tostring(rect.x2)
          end
          return table.concat(out,',')
        """)
        seen = widths.split(",")
        self.assertEqual(len(set(seen)), len(seen),
                         "the map rect did not change with the screen: " + widths)

    def test_map_click_and_map_drag_agree_about_what_is_hostile(self):
        """There were three predicates and they did not agree: SelectMapClick
        took friendly OR enemy, GetMapShipAt took the same set written out by
        hand, and SelectMapBox took friendly only. Clicking a Vasudan raider on
        the map put it in the selection and the same drag one pixel over
        selected nothing, and dragging a box over a contact the click would have
        taken silently selected nothing at all."""
        click, box, at = self.check(r"""
          setScreen(1920,1080); r.UIMetrics=nil; r.MapView=nil
          r:ResetState(); r.SetupActive=false
          clearBoard()
          local friendly=addShip('mine','GTF Aries',mkpos(-3000,0,0),'friendly')
          local hostile=addShip('raider','SF Mara',mkpos(3000,0,0),'hostile')
          local third=addShip('vayasu','GVCv Sobek',mkpos(0,0,3000),'neutral')
          r.ShipCache=nil
          local rect=r:GetTacticalMapRect()
          -- where the map puts each of them
          local fx,fy=r:WorldToTacticalMap(friendly.Position)
          local hx,hy=r:WorldToTacticalMap(hostile.Position)
          local tx,ty=r:WorldToTacticalMap(third.Position)

          r.ShiftDown=false; r.Selected={}; r.PrimarySelectionSignature=nil
          r:SelectMapClick(hx,hy)
          local clickHostile=(r.PrimarySelectionSignature==hostile:getSignature())
                        and 'raider' or 'other'
          local clickThird
          r:SelectMapClick(tx,ty)
          clickThird=(r.PrimarySelectionSignature==third:getSignature()) and 'vayasu' or 'other'
          local clickFriendly
          r:SelectMapClick(fx,fy)
          clickFriendly=(r.PrimarySelectionSignature==friendly:getSignature()) and 'mine' or 'other'

          local pickHostile=r:GetMapShipAt(hx,hy)
          local pickThird=r:GetMapShipAt(tx,ty)

          -- and the same three points as a drag over the whole map
          r.ShiftDown=false; r.Selected={}
          r:SelectMapBox(rect.x1-50,rect.y1-50,rect.x2+50,rect.y2+50)
          local boxed={}
          for _,sig in ipairs(r.Selected) do boxed[sig]=true end
          -- a map click on empty space, to check the primary is cleared too
          local rect=r:GetTacticalMapRect()
          r:SelectMapClick(rect.x1+2, rect.y1+2)
          return clickHostile..','..clickThird..','..clickFriendly,
                 tostring(boxed[friendly:getSignature()])..','..
                 tostring(boxed[hostile:getSignature()])..','..
                 tostring(boxed[third:getSignature()]),
                 (pickHostile and pickHostile.Name)..','..(pickThird and pickThird.Name)
        """)
        self.assertEqual(click, "raider,vayasu,mine",
                         "a map click no longer picks what it used to")
        self.assertEqual(box, "true,true,true",
                         "a map drag does not select what a map click over the same "
                         "point does: a hostile or third-faction contact inside the "
                         "drag was skipped, so clicking and dragging over the same "
                         "area disagree about what is hostile")
        self.assertEqual(at, "raider,vayasu")

    def test_a_map_click_publishes_the_primary_selection(self):
        """SelectMapBox always set PrimarySelectionSignature; a map click did
        not. So a ship picked off the map was never the primary, and every
        "the ship I last clicked" read - the detail card, the station panel,
        the order the last clicked ship was given - went to whatever was
        selected before. An empty map click also cleared Selected but left the
        signature pointing at a ship the player had just deselected."""
        result = self.check(r"""
          setScreen(1920,1080); r.UIMetrics=nil; r.MapView=nil
          r:ResetState(); r.SetupActive=false
          clearBoard()
          local first=addShip('first','GTF Aries',mkpos(-3000,0,0),'friendly')
          local second=addShip('second','GTF Aries',mkpos(3000,0,0),'hostile')
          r.ShipCache=nil
          r.ShiftDown=false; r.Selected={first:getSignature()}; r.PrimarySelectionSignature=nil
          local sx,sy=r:WorldToTacticalMap(second.Position)
          r:SelectMapClick(sx,sy)
          local afterClick=(r.PrimarySelectionSignature==second:getSignature())
          -- and an empty click has to clear it too
          local rect=r:GetTacticalMapRect()
          r:SelectMapClick(rect.x1+2, rect.y1+2)
          return (afterClick and 'yes' or 'no')..','..
                 (r.PrimarySelectionSignature and 'stale' or 'cleared')..','..#r.Selected
        """)
        self.assertEqual(result, "yes,cleared,0",
                         "a map click left the primary selection pointing at the "
                         "previously selected ship, or an empty map click left a "
                         "primary selection that is no longer in Selected, so the "
                         "HUD reports a ship the player just deselected")

    def test_double_clicking_a_map_contact_selects_its_wing(self):
        selected = self.check(r"""
          setScreen(1920,1080); r.UIMetrics=nil; r.MapView=nil
          r:ResetState(); r.SetupActive=false; clearBoard()
          local first=addShip('alpha 1','GTF Aries',mkpos(-3000,0,0),'friendly')
          local second=addShip('alpha 2','GTF Aries',mkpos(3000,0,0),'friendly')
          r.ShipCache=nil; r:RegisterLogicalWing({first,second},'Blue Alpha')
          local x,y=r:WorldToTacticalMap(first.Position)
          r.UIClock=10; r.ShiftDown=false; r.Selected={}; r.LastLeftClickKey=nil
          r.Enabled=true; r.PossessedSignature=nil; r.CinematicActive=false; r.PostBattleActive=false
          bit.checkBit=function(button,b) return b==0 end
          io.getMouseX=function() return x end; io.getMouseY=function() return y end
          r.MapDrag={x1=x,y1=y}; r:OnMouseReleased(1)
          local firstWasSingle=#r.Selected==1
          r.UIClock=10.2
          r.MapDrag={x1=x,y1=y}; r:OnMouseReleased(1)
          local secondWasDouble=#r.Selected==2
          return tostring(firstWasSingle)..','..tostring(secondWasDouble)..','..#r.Selected
        """)
        self.assertEqual(selected, "true,true,2",
                         "a map double-click selected only the clicked hull instead of its logical wing")

    def test_an_armed_order_released_on_the_tactical_map_is_executed(self):
        """Only sentry and strike were handled on the map. Arming MOVE, pressing
        it on the map and clicking the destination changed the selection instead
        of moving the fleet, and the command stayed armed so the next world
        click moved it to a place the player was not looking. The map is where
        an RTS player issues orders."""
        for kind, field in [("move", "moved"), ("attack", "attacked")]:
            lua = boot()
            outcome = lua.execute("""
              setScreen(1920,1080); r.UIMetrics=nil; r.MapView=nil
              r:ResetState(); r.SetupActive=false
              clearBoard()
              local target=addShip('raider','SF Mara',mkpos(4000,0,0),'hostile')
              r.ShipCache=nil
              r.Enabled=true; r.PossessedSignature=nil
              r.IsPointOnTacticalMap=function() return true end
              r.SetStatus=function() end
              r.TacticalMapToWorld=function(self,x,y) return ba.createVector(x,0,y) end
              r.SetOrderPing=function() end
              local moved,attacked=0,0
              r.IssueMove=function(self,dest) moved=moved+1 end
              r.IssueAttack=function(self,ship) attacked=attacked+1 end
              local x,y=r:WorldToTacticalMap(target.Position)
              r.ArmedCommand='%s'
              r.MapDrag={x1=x,y1=y,x2=x,y2=y}
              bit.checkBit=function(button,b) return b==0 end
              io.getMouseX=function() return x end
              io.getMouseY=function() return y end
              r:OnMouseReleased(1)
              -- strings, because a nil coming back through lupa is ambiguous
              return table.concat({moved, attacked,
                r.ArmedCommand or 'cleared', #(r.Selected or {})}, ',')
            """ % kind)
            moved, attacked, armed, selected = outcome.split(",")
            self.assertGreater(int(moved) + int(attacked), 0,
                               "an armed %s released on the tactical map issued no "
                               "order at all" % kind)
            self.assertEqual(armed, "cleared",
                             "an armed %s survived the map click, so the next click "
                             "anywhere issues it by accident" % kind)
            self.assertEqual(selected, "0",
                             "an armed %s released on the map also changed the "
                             "selection" % kind)


class InputTests(unittest.TestCase):
    """Left-drag bookkeeping and the setup screen's click regions."""

    def setUp(self):
        self.lua = boot()

    def check(self, code):
        return self.lua.execute(code)

    def test_new_unit_popup_button_selects_the_delivered_batch(self):
        selected = self.check(r"""
          setScreen(1920,1080); r.UIMetrics=nil; r.MapView=nil
          r:ResetState(); r.SetupActive=false; r.Enabled=true; r.CinematicActive=false; r.PostBattleActive=false
          clearBoard()
          local first=addShip('new alpha 1','GTF Aries',mkpos(-1000,0,0),'friendly')
          local second=addShip('new alpha 2','GTF Aries',mkpos(1000,0,0),'friendly')
          r.ShipCache=nil; r.UIClock=1; r:NotifyNewUnits({first}); r:NotifyNewUnits({second})
          assert(#r.NewUnitPopup.signatures==2,'separate deliveries did not coalesce into one selectable notice')
          r:DrawNewUnitPopup(1920,1080)
          local card,button=r.NewUnitPopupRect,r.NewUnitPopupSelectRect
          assert(card and button and card.x1>=0 and card.x2<=1920 and card.y1>=0 and card.y2<=1080,
            'new unit popup escapes the game viewport')
          r.IsPointOnRTSUI=function(self,x,y) return self:PointInside(self.NewUnitPopupRect,x,y) end
          local x=(button.x1+button.x2)/2; local y=(button.y1+button.y2)/2
          bit.checkBit=function(_,b) return b==0 end
          io.getMouseX=function() return x end; io.getMouseY=function() return y end
          r:OnMousePressed(1); r:OnMouseReleased(1)
          return #r.Selected..','..tostring(r.Selected[1]==first:getSignature())..','..
            tostring(r.Selected[2]==second:getSignature())..','..tostring(r.NewUnitPopup==nil)
        """)
        self.assertEqual(selected, "2,true,true,true",
                         "clicking SELECT did not select and consume the newly delivered ships")

    def test_drag_selection_never_takes_the_command_station(self):
        """A box over the base and a wing selected the base along with the ships.
        The base is selected by click only."""
        result = self.check(r"""
          setScreen(1920,1080); r.UIMetrics=nil; r.MapView=nil
          r:ResetState(); r.SetupActive=false; r.Enabled=true; r.CinematicActive=false; r.PostBattleActive=false
          clearBoard()
          local wing=addShip('box wing 1','GTF Aries',mkpos(0,0,0),'friendly')
          r.EachShip=function(self,fn) fn(stations.BLUE); fn(wing) end
          r.BuildScreenGate=function() return nil end
          r.ProjectShip=function() return 500,500 end
          r.Selected={}; r.ShiftDown=false
          r:SelectBox(0,0,1000,1000)
          local sawWing, sawStation = false, false
          for _,sig in ipairs(r.Selected) do
            if sig==wing:getSignature() then sawWing=true end
            if sig==stations.BLUE:getSignature() then sawStation=true end
          end
          return tostring(sawWing)..','..tostring(sawStation)
        """)
        self.assertEqual(result, "true,false", "box selection did not keep the wing and drop the station")

    def test_a_hull_in_production_shows_its_warp_in_point_only_once_started(self):
        result = self.check(r"""
          local camera=r.Camera
          r:ResetState(); r.Camera=camera; r.SetupActive=false; r.Enabled=true; r.PostBattleActive=false
          tb.ShipClasses['GTF Aries']=tb.ShipClasses['GTF Aries'] or {Name='GTF Aries',isValid=function() return true end}
          r.GetCarrier=function() return stations.BLUE end
          r.GetSpawnFrame=function() return ba.createVector(100,0,200),nil end
          r.BuildQueue={{started=false,option={class='GTF Aries',count=1},id=1}}
          local idle=#r:GetBuildSignatures(10)
          r.BuildQueue={{started=true,option={class='GTF Aries',count=1},id=2}}
          local active=r:GetBuildSignatures(10)
          return idle..','..#active..','..tostring(active[1] and active[1].pos.x)
        """)
        self.assertEqual(result, "0,1,100", "a queued hull showed a warp-in point, or a started one did not")
        # A spawn point three km out is often off screen, and a 350 m ring at that range is
        # a few pixels. Both cases must leave a visible marker: on screen where it projects,
        # pinned to the edge where it does not.
        drawn = self.check(r"""
          r.BuildQueue={{started=true,option={class='GTF Aries',count=1},id=3}}
          local onScreen=ba.createVector(100,0,200)
          onScreen.getScreenCoords=function() return 960,540 end
          local offScreen=ba.createVector(3000,0,3000)
          offScreen.getScreenCoords=function() return false end
          r.GetSpawnFrame=function() return onScreen,nil end
          local onCount=r:DrawBuildSignatures()
          r.GetSpawnFrame=function() return offScreen,nil end
          r.BuildQueue[1].signatureAt=nil
          local offCount=r:DrawBuildSignatures()
          return tostring(onCount)..','..tostring(offCount)
        """)
        on, off = (int(x) for x in drawn.split(','))
        self.assertGreater(on, 0, "an on-screen jump signature drew no marker")
        self.assertGreater(off, 0, "an off-screen jump signature drew no edge marker")

    def test_new_unit_card_is_centred_over_the_scene(self):
        """The card hung off the left of the notification band. It is centred over
        the 3D view, at the same height as before."""
        offset = self.check(r"""
          setScreen(1920,1080); r.UIMetrics=nil; r.MapView=nil
          r:ResetState(); r.SetupActive=false; r.Enabled=true; r.CinematicActive=false; r.PostBattleActive=false
          clearBoard()
          local first=addShip('centre alpha 1','GTF Aries',mkpos(-1000,0,0),'friendly')
          r.ShipCache=nil; r.UIClock=1
          r:NotifyNewUnits({first})
          r:DrawNewUnitPopup(1920,1080)
          local v=r:GetContactViewport(1920,1080,r:GetUIMetrics(1920,1080))
          local card=r.NewUnitPopupRect
          return ((card.x1+card.x2)/2)-((v.x1+v.x2)/2)
        """)
        self.assertLess(abs(float(offset)), 2, 'new unit card is %s px off the scene centre' % offset)

    def test_new_unit_popup_card_is_compact(self):
        """The card used the full width of the notification band. It is a single
        compact line: a label and a SELECT button."""
        width = self.check(r"""
          setScreen(1920,1080); r.UIMetrics=nil; r.MapView=nil
          r:ResetState(); r.SetupActive=false; r.Enabled=true; r.CinematicActive=false; r.PostBattleActive=false
          clearBoard()
          local first=addShip('compact alpha 1','GTF Aries',mkpos(-1000,0,0),'friendly')
          r.ShipCache=nil; r.UIClock=1
          r:NotifyNewUnits({first})
          r:DrawNewUnitPopup(1920,1080)
          return r.NewUnitPopupRect.x2-r.NewUnitPopupRect.x1
        """)
        self.assertLessEqual(float(width), 340, 'new unit card is %s px wide' % width)

    def test_new_unit_popup_lapses_within_a_few_seconds(self):
        """The ready card used to stay for 12 seconds, and a card re-armed after
        pilot mode (expiresAt cleared) got another 12 seconds on first draw."""
        window = self.check(r"""
          setScreen(1920,1080); r.UIMetrics=nil; r.MapView=nil
          r:ResetState(); r.SetupActive=false; r.Enabled=true; r.CinematicActive=false; r.PostBattleActive=false
          clearBoard()
          local first=addShip('lapse alpha 1','GTF Aries',mkpos(-1000,0,0),'friendly')
          r.ShipCache=nil; r.UIClock=1
          r:NotifyNewUnits({first})
          local delivered=r.NewUnitPopup.expiresAt-r:UINow()
          r.NewUnitPopup.expiresAt=nil
          r:DrawNewUnitPopup(1920,1080)
          local redrawn=r.NewUnitPopup.expiresAt-r:UINow()
          return delivered..','..redrawn
        """)
        delivered, redrawn = (float(x) for x in window.split(','))
        self.assertLessEqual(delivered, 6, 'a delivered ready card lasts too long')
        self.assertLessEqual(redrawn, 6, 'a re-armed ready card lasts too long')

    def test_a_world_drag_released_over_a_panel_does_not_press_it(self):
        """The press is the only place that knows where a gesture started, and
        the origin was thrown away, so HandleUILeftClick ran on every left
        release. Drag a box-select across the command panel and letting go over
        HOLD held your fleet; letting go over MUSIC muted the music."""
        held, selected = self.check(r"""
          setScreen(1920,1080); r.UIMetrics=nil; r.MapView=nil
          boardFrame()
          clearBoard()
          local held=0
          r.HoldSelected=function() held=held+1 end
          r.IsPointOnRTSUI=function(self,x,y) return x>=400 and x<=900 and y>=100 and y<=140 end
          r.IsPointOnTacticalMap=function() return false end
          r.SetStatus=function() end
          bit.checkBit=function(button,b) return b==0 end
          local x,y=500,120
          r.ActionButtonRects={hold={x1=x,y1=y,x2=x+120,y2=y+30}}
          -- press in the world...
          io.getMouseX=function() return 100 end
          io.getMouseY=function() return 900 end
          r:OnMousePressed(1)
          -- ...drag across the panel, and let go over the button
          io.getMouseX=function() return x end
          io.getMouseY=function() return y end
          r:OnMouseReleased(1)
          return held, #r.Selected
        """)
        self.assertEqual(held, 0,
                         "a left drag that began in the world fired the panel button "
                         "it happened to end over")

    def test_a_press_that_started_on_a_panel_still_presses_it(self):
        """The control for the test above: the guard must key on the ORIGIN of
        the gesture, not blanket-block releases over the HUD."""
        held = self.check(r"""
          setScreen(1920,1080); r.UIMetrics=nil; r.MapView=nil
          boardFrame()
          clearBoard()
          local held=0
          r.HoldSelected=function() held=held+1 end
          r.IsPointOnRTSUI=function(self,x,y) return x>=400 and x<=900 and y>=100 and y<=140 end
          r.IsPointOnTacticalMap=function() return false end
          r.SetStatus=function() end
          bit.checkBit=function(button,b) return b==0 end
          local x,y=500,120
          r.ActionButtonRects={hold={x1=x,y1=y,x2=x+120,y2=y+30}}
          io.getMouseX=function() return x end
          io.getMouseY=function() return y end
          r:OnMousePressed(1)
          r:OnMouseReleased(1)
          return held
        """)
        self.assertEqual(held, 1,
                         "a click on a panel button no longer presses it")

    def test_faction_species_picker_fits_small_screens_and_keeps_rows_clickable(self):
        for width,height in ((640,480),(800,600),(1024,768),(1280,720),(1920,1080)):
            page_size,blue_y,red_bottom,start_y,inside=self.check("""
              setupScreen(%d,%d)
              r.SetupFactionCountChoice=12; r:UpdateFactionCount()
              r:DrawSetupOverlay(%d,%d)
              local blue=r.SetupButtonRects.faction_BLUE
              local red=r.SetupButtonRects.faction_RED or blue
              local count=r.SetupButtonRects.factions
              local start=r.SetupButtonRects.start
              local inside=true
              for _,rect in pairs(r.SetupButtonRects) do
                if rect.x1<0 or rect.y1<0 or rect.x2>%d or rect.y2>%d then inside=false end
              end
              return r.SetupFactionPageSize,blue.y1,red.y2,start.y1,inside
            """ % (width,height,width,height,width,height))
            self.assertGreaterEqual(page_size,1)
            self.assertLess(blue_y,red_bottom)
            self.assertLess(red_bottom,start_y,"species rows overlap START at %dx%d" % (width,height))
            self.assertTrue(inside,"setup button leaves the visible screen at %dx%d" % (width,height))


class TopBarTests(unittest.TestCase):
    """The top bar's behaviour when the window is too narrow for it.

    The read comes from the bar's DRAW calls, not from its width measurements.
    It has to: the bar measures both the long and the short form of every field
    when it builds its cache, so a measurement log cannot tell a placed field
    from one the layout measured and then decided against, and that decision is
    the thing under test. test_hud_layout already covers the geometry from 1280
    up; this class covers the widths where the bar starts losing fields.
    """

    def setUp(self):
        self.lua = boot()

    def bar(self, width):
        """The texts the bar actually drew, in the top bar's band.

        Returned as one string because a Lua table comes back through lupa as a
        proxy whose ``in`` is not Python's ``in``; a joined string is unambiguous.
        """
        seen = self.lua.execute("""
          setScreen(%d,720); r.UIMetrics=nil
          r:ResetState(); r.SetupActive=false; r.Enabled=true
          r.PossessedSignature=nil; r.PostBattleActive=false
          r.CommandPoints=5000; r.GlobalPolicy='HOLD'
          r.UIClock=1; r.TopBarCounters=nil; r.TopBarFieldCache=nil
          r.GetEscalationProfile=realDurationProfile
          r.CountFriendlyCombatants=function() return 40 end
          r.CountHostiles=function() return 30 end
          local band=r:GetUIMetrics(%d,720).topBarHeight
          local seen={}
          local realDraw=gr.drawString
          gr.drawString=function(text,x1,y1,x2,y2)
            if (tonumber(y1) or 0)<band then seen[#seen+1]=tostring(text) end
          end
          r:DrawTopBar(%d)
          gr.drawString=realDraw
          return table.concat(seen,'\\1')
        """ % (width, width, width))
        return seen.split("\1")

    def test_every_readout_is_present_in_full_at_a_normal_width(self):
        for wanted in ("CP: 5000", "Fleet: 40/64", "Contacts: 30", "Policy: HOLD"):
            self.assertIn(wanted, self.bar(1920),
                          "at 1920px the top bar no longer places " + wanted)

    def test_a_narrow_window_shortens_the_readouts_before_it_drops_them(self):
        """The old layout dropped the LAST field that did not fit and said
        nothing, so a narrow window lost Policy, then Contacts, then Fleet. The
        contact count is the one number the HUD reports nowhere else, so it gets
        an abbreviated form that fits long before the full one is given up, and a
        field is removed only after everything below it is already short.

        The invariant asserted at every width is the one that matters: no readout
        is ever given up while a LESS important one is still on the bar. That is
        the shape of the old bug, and it is what the sacrifice order has to
        rule out.
        """
        importance = [("CP: 5000", "CP 5000"),
                      ("Fleet: 40/64", "FLT 40/64"),
                      ("Contacts: 30", "CON 30"),
                      ("Policy: HOLD", "POL HOLD")]
        for w in range(1920, 700, -10):
            seen = set(self.bar(w))
            present = [any(f in seen for f in forms) for forms in importance]
            for i, alive in enumerate(present):
                if alive:
                    continue
                for j in range(i + 1, len(present)):
                    self.assertFalse(present[j],
                                     "at %dpx the bar dropped %s but kept the less "
                                     "important %s: %s"
                                     % (w, importance[i][0], importance[j][0],
                                        sorted(seen)))
                break
        # and the shortening path itself is exercised somewhere
        self.assertTrue(any("CON 30" in self.bar(w) for w in range(1920, 700, -10)),
                        "the contact count is never abbreviated, so shorten-before-"
                        "drop is not being exercised")

    def test_the_sacrifice_order_is_policy_then_fleet_then_contacts_then_cp(self):
        """The order is fixed, so it can be asserted. Command points go last
        because every other decision is measured against them."""
        order = []
        for w in range(1920, 700, -10):
            seen = set(self.bar(w))
            # reported LEAST important survivor first, so scanning down the
            # widths names each field at the width where it was given up
            for name, short in (("Policy: HOLD", "POL HOLD"),
                                ("Contacts: 30", "CON 30"),
                                ("Fleet: 40/64", "FLT 40/64")):
                if name in seen or short in seen:
                    order.append(name)
                    break
        self.assertTrue(order, "fixture: the fields were never placed at all")
        first = [name for i, name in enumerate(order) if name not in order[:i]]
        self.assertEqual(first, ["Policy: HOLD", "Contacts: 30", "Fleet: 40/64"],
                         "the readouts are given up in the wrong order: " + str(first))
        for w in (1920, 1280, 1100):
            self.assertTrue(any(t.startswith("CP") for t in self.bar(w)),
                            "at %dpx command points are not placed at all: %s"
                            % (w, self.bar(w)))

    def test_the_title_is_dropped_before_the_fleet_count(self):
        """The title is decoration and the widest single item in the bar, so it
        is the first thing sacrificed once shortening is not enough. Keeping a
        twelve character heading in place of a fleet count is the wrong trade."""
        seen = self.bar(1920)
        self.assertIn("FLEET COMMAND", seen,
                      "fixture: the title is not drawn at 1920px")
        gone = None
        for w in range(1920, 700, -10):
            if "FLEET COMMAND" not in self.bar(w):
                gone = w
                break
        self.assertIsNotNone(gone,
                             "the title survives at every width down to 700px, so "
                             "its sacrifice order is not being exercised")
        self.assertTrue("FLT 40/64" in self.bar(gone),
                        "at %dpx, the width where the title goes, the fleet count "
                        "went with it: %s" % (gone, self.bar(gone)))

    def test_the_speed_note_is_abbreviated_before_it_is_dropped(self):
        """The note is the first thing the right-hand group gives up, because the
        seven speed buttons beside it already state the speed. When the group is
        short of room it is shortened rather than allowed to disappear at a width
        where an abbreviated form would have fitted."""
        forms = ("Tiers + income: mission time", "Tiers + income:",
                 "TIME x1", "TIME PAUSED")
        abbreviated = []
        for w in range(1920, 700, -10):
            seen = self.bar(w)
            present = [f for f in forms if f in seen]
            if any(f.startswith("TIME") for f in present):
                abbreviated.append(w)
            # the escalation clock is the one that must not be sacrificed first
            if not present:
                self.assertTrue(any(t.startswith("TIER ") or t.startswith("T4 ") for t in seen),
                                "at %dpx the speed note went and took the "
                                "escalation clock with it: %s" % (w, seen))
                return
        self.assertTrue(abbreviated,
                        "the speed note is never abbreviated at any width, so the "
                        "shorten path for the right-hand group is not exercised")

    def test_the_abbreviated_layout_does_not_overlap_or_escape_at_any_width(self):
        """test_hud_layout already checks non-overlap from 1280 up. This sweeps
        the widths where the bar actually starts losing fields, and sorts by x
        before comparing, because the draw order is right cluster then left
        cluster and is not x order."""
        problem = self.lua.execute("""
          for _,w in ipairs({1920,1600,1400,1280,1200,1100,1000,960,920,900,880,
                             860,840,820,800,780,760,740,720,700,680}) do
            setScreen(w,720); r.UIMetrics=nil
            r:ResetState(); r.SetupActive=false; r.Enabled=true
            r.PossessedSignature=nil; r.PostBattleActive=false
            r.CommandPoints=5000; r.GlobalPolicy='HOLD'
            r.UIClock=1; r.TopBarCounters=nil; r.TopBarFieldCache=nil
            r.CountFriendlyCombatants=function() return 300 end
            r.CountHostiles=function() return 300 end
            local m=r:GetUIMetrics(w,720)
            local placed={}
            local realWidth=r.TextWidth
            local realDraw=gr.drawString
            gr.drawString=function(text,x1,y1,x2,y2)
              placed[#placed+1]={t=tostring(text),x=x1,y=y1,w=realWidth(r,tostring(text))}
            end
            r:DrawTopBar(w)
            gr.drawString=realDraw
            table.sort(placed,function(a,b) return a.x<b.x end)
            for i=2,#placed do
              if placed[i].x<placed[i-1].x+placed[i-1].w then
                return '"'..placed[i-1].t..'" and "'..placed[i].t..'" overlap at '
                  ..w..'px'
              end
            end
            for _,p in ipairs(placed) do
              if p.x<0 or p.x+p.w>w or p.y<0 or p.y>=m.topBarHeight then
                return '"'..p.t..'" escapes the bar at '..w..'px'
              end
            end
            for _,rect in pairs(r.TimeButtonRects) do
              if rect.x1<0 or rect.x2>w or rect.y2>m.topBarHeight then
                return 'a speed button escapes the bar at '..w..'px'
              end
            end
          end
          return nil
        """)
        self.assertIsNone(problem, "the top bar is wrong at some width: " + str(problem))


class DecorationTests(unittest.TestCase):
    """The ambient decoration cull."""

    def setUp(self):
        self.lua = boot()

    def check(self, code):
        return self.lua.execute(code)

    def test_the_occupancy_grid_agrees_with_the_point_list_it_replaced(self):
        """The cull went from "compare against every point already placed" to
        "is this cell or a neighbour occupied". Two points are within minGap on
        both axes exactly when their cells differ by at most one on each axis,
        so the grid answers the same question -- but the equivalence is worth
        pinning, because a grid sized wrong drops contacts that are nowhere near
        each other."""
        mismatch = self.check(r"""
          r:ResetState()
          local sel=r.Config.Selection
          local minGap=math.max(18,(sel.ReticleMinPixels or 22)+math.max(10,sel.RoleMarkerSize or 11))
          -- `placed` is the set both rules have agreed on so far, so neither is
          -- ever shown its own candidate.
          local placed={}
          local function reference(sx,sy,forced)
            if not forced then
              for _,p in ipairs(placed) do
                if math.abs(p.x-sx)<minGap and math.abs(p.y-sy)<minGap then return false end
              end
            end
            return true
          end
          -- a deterministic scatter, including deliberately on-cell-boundary
          -- offsets and exact-minGap neighbours
          local seeds={}
          for i=1,240 do
            seeds[i]={x=math.floor(i*37.3), y=math.floor(i*53.7), f=(i%9==0)}
          end
          seeds[#seeds+1]={x=0,y=0,f=false}
          for i=1,#seeds do
            local sx,sy,forced=seeds[i].x,seeds[i].y,seeds[i].f
            local want=reference(sx,sy,forced)
            r:ResetDecorationGrid()
            for _,p in ipairs(placed) do r:ShouldDecorateReticle(p.x,p.y,0,false) end
            local got=r:ShouldDecorateReticle(sx,sy,0,forced)
            if want~=got then
              return ('at ('..sx..','..sy..') forced='..tostring(forced)
                ..' the list said '..tostring(want)
                ..' and the grid said '..tostring(got)
                ..', minGap='..tostring(minGap)..' over '..#placed..' placed points')
            end
            if want then placed[#placed+1]={x=sx,y=sy} end
          end
          -- and exactly minGap apart in each axis must both survive
          r:ResetDecorationGrid()
          r:ShouldDecorateReticle(500,500,0,false)
          local touchingX=r:ShouldDecorateReticle(500+minGap,500,0,false)
          r:ResetDecorationGrid()
          r:ShouldDecorateReticle(500,500,0,false)
          local touchingY=r:ShouldDecorateReticle(500,500+minGap,0,false)
          r:ResetDecorationGrid()
          r:ShouldDecorateReticle(500,500,0,false)
          local inside=r:ShouldDecorateReticle(500+minGap-1,500,0,false)
          return nil, touchingX, touchingY, inside
        """)
        self.assertIsNone(mismatch[0], "the grid and the list disagree: " + str(mismatch[0]))
        self.assertTrue(mismatch[1], "a contact exactly minGap away on x was culled")
        self.assertTrue(mismatch[2], "a contact exactly minGap away on y was culled")
        self.assertFalse(mismatch[3], "a contact inside minGap was not culled")

    def test_selection_and_hover_are_never_culled_by_the_overlap_rule(self):
        """The thing the player is pointing at is never the thing the
        declutterer drops."""
        self.check(r"""
          r:ResetState()
          r:ResetDecorationGrid()
          assert(r:ShouldDecorateReticle(500,500,0,false),'the first contact was not decorated')
          assert(not r:ShouldDecorateReticle(502,502,0,false),
            'a contact on top of a decorated one was decorated again')
          assert(r:ShouldDecorateReticle(500,500,0,true),
            'a selected contact was culled by the overlap rule')
          assert(r:ShouldDecorateReticle(900,500,0,false),
            'a contact well clear of the others was culled')
        """)


if __name__ == "__main__":
    unittest.main()
