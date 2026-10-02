"""Measure what getScreenCoords costs a full HUD frame, and how much of it is left.

Run: python core/tools/probe_projection.py

This is a measurement, not a test -- the assertions live in test_hud_perf.py.
It exists because the fix has two independent parts and it matters which one is
doing the work: the per-frame cache, and the pre-projection frustum gate. It
also matters that the win survives a change of camera, because the gate's value
is entirely a function of how much of the board is on screen.

The three configurations are run against the same board:

  A  cache and gate both neutered. Every consumer calls getScreenCoords itself,
     for every ship, which is what the code did before: the reticle pass
     projected the whole world and then the hover pick projected it again.
  B  cache only. Isolates "one call per ship per epoch".
  C  the shipped code, cache plus gate.

Neutering is done by replacing RTS.ProjectShip with a direct call and
RTS.BuildScreenGate with a nil return, which reproduces the old call pattern
exactly -- the old code had no gate and no cache, so nothing else changes.

The projection double is a real pinhole matching the engine's
(code/render/3dmath.cpp:247 with the basis scaling of
code/render/3dsetup.cpp:187), so the gate and the engine answer are computed
the same way and can be compared:

  sx = W/2 * (1 + (d.r / d.f) / tanH)      tanH = tan(zoom * 1.39626348 / 2)
  sy = H/2 * (1 - (d.u / d.f) / tanH)
  PF_OVERFLOW when d.f <= 0
"""
from lupa.lua51 import LuaRuntime

from test_station import SETUP, SCRIPTS

EXTRA = r'''
io=io or {}
io.getMouseX=function() return 960 end
io.getMouseY=function() return 300 end
io.setCursorHidden=function() end
ba.postGameEvent=function() end
ba.setButtonControlMode=function() end
bit=bit or {checkBit=function() return false end}
SCREEN_W=1920; SCREEN_H=1080
FONT_W=6
gr={setCamera=function() end,
  getScreenWidth=function() return SCREEN_W end,
  getScreenHeight=function() return SCREEN_H end,
  setColor=function() end,
  getStringWidth=function(text) return #tostring(text)*FONT_W end,
  drawRectangle=function() end,
  drawString=function() end,
  drawLine=function() end, drawCircle=function() end, drawRectangleCentered=function() end, drawImage=function() end,
  drawTargetingBrackets=function() return nil end,
  setTarget=function() end, clearScreen=function() end, createTexture=function() return false end,
  -- FSO's own view fov. The real binding is gr.getEyeFOV; the gate falls back
  -- to Camera.FOV without it, and Camera.FOV is the same number, so both paths
  -- are exercised by test_hud_perf.py.
  getEyeFOV=function() return 1.02 end}
r.Camera={Position=ba.createVector(0,0,-9000),Orientation={
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

-- ---- the board ------------------------------------------------------------
PROJ_CALLS=0
CAM={ox=0,oy=0,oz=-9000,fx=0,fy=0,fz=1,rx=1,ry=0,rz=0,ux=0,uy=1,uz=0}
TANH=math.tan(1.02*1.39626348/2)
function projected(x,y,z)
  PROJ_CALLS=PROJ_CALLS+1
  local dx,dy,dz=x-CAM.ox,y-CAM.oy,z-CAM.oz
  local depth=dx*CAM.fx+dy*CAM.fy+dz*CAM.fz
  if depth<=0 then return false end
  local lateral=dx*CAM.rx+dy*CAM.ry+dz*CAM.rz
  local vertical=dx*CAM.ux+dy*CAM.uy+dz*CAM.uz
  return SCREEN_W*0.5*(1+(lateral/depth)/TANH), SCREEN_H*0.5*(1-(vertical/depth)/TANH)
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

-- test_station's SETUP keeps its own `ships` array that r.GetShipList and
-- r.EachShip are stubbed to read, and appends every ship() to it, so both it
-- and mn.Ships have to be reset or the board silently triples.
function buildBoard(n,extent)
  ships={}; mn.Ships={}
  for i=1,(n or 300) do
    local side=(i%2==0) and mn.Teams.friendly or mn.Teams.hostile
    local x=((i*7919)%(2*extent))-extent
    local z=((i*104729)%(2*extent))-extent
    ship('P '..i, class(i%9==0 and 'SF Mara' or 'GTF Aries'),
         mkpos(x, ((i*13)%400)-200, z), side)
  end
end
'''

MEASURE = r'''
function runBoard(frames, useCache, useGate)
  local realProject = r.ProjectShip
  local realScreenGate = r.BuildScreenGate
  if not useCache then
    r.ProjectShip = function(self, s, maxAge)
      local a, b = s.Position:getScreenCoords()
      if a == false then return false, false end
      return a, b
    end
  end
  if not useGate then r.BuildScreenGate = function() return nil end end
  r.ProjectionEpoch = nil; r.ProjectionX = nil; r.ProjectionY = nil
  r.ProjectionOwner = nil; r.ProjectionAt = nil; r.ProjectionPrunedAt = 0
  r.DecorationGrid = nil
  r.UIClock = 0
  resetCalls()
  for i = 1, frames do r.UIClock = i * 0.016; r:DrawHUD() end
  local drawn = calls()
  -- and the two picking passes one left click makes: the hover+capital pick
  -- and then the hostile pick that resolves an attack
  resetCalls()
  r:BeginFrameProjection()
  r:GetShipAtScreen(960, 300, true, true, true)
  r:GetShipAtScreen(960, 300, false, true)
  local picked = calls()
  r.ProjectShip = realProject
  r.BuildScreenGate = realScreenGate
  return drawn, picked
end

function countOnScreen()
  local n = 0
  for i = 1, #mn.Ships do
    local sx, sy = mn.Ships[i].Position:getScreenCoords()
    if sx ~= false and sx >= 0 and sy >= 0 and sx <= SCREEN_W and sy <= SCREEN_H then n = n + 1 end
  end
  return n
end

function scenario(name, camZ, extent)
  CAM.oz = camZ
  r.Camera.Position = ba.createVector(0, 0, camZ)
  buildBoard(300, extent)
  r:ResetState(); r.SetupActive = false; r.testSelection = {}; r.ShipCache = nil
  local FRAMES = 20
  local aD, aP = runBoard(FRAMES, false, false)
  local bD, bP = runBoard(FRAMES, true, false)
  local cD, cP = runBoard(FRAMES, true, true)
  local ships = #mn.Ships
  print('')
  print(name)
  print(string.format('  %d ships, %d on screen from this camera, %d frames',
    ships, countOnScreen(), FRAMES))
  print('  getScreenCoords per HUD frame')
  print(string.format('    A  no cache, no gate : %7.1f  (%.2f/ship)', aD/FRAMES, aD/FRAMES/ships))
  print(string.format('    B  cache only        : %7.1f  (%.2f/ship)', bD/FRAMES, bD/FRAMES/ships))
  print(string.format('    C  cache + gate      : %7.1f  (%.2f/ship)   -> %.1fx fewer than A',
    cD/FRAMES, cD/FRAMES/ships, aD/math.max(1, cD)))
  print(string.format('  one click, two picking passes:  A %d   B %d   C %d   -> %.1fx fewer than A',
    aP, bP, cP, aP/math.max(1, cP)))
end

-- default RTS camera: 9000m back, 58 degrees, over the full +/-15km board
-- zoomed in: Config.Camera.MinDistance is 55 and MinPitchDegrees 24, so this is
-- a real working camera, not an extreme. Zoomed out runs against MaxDistance.
scenario('default camera (9000m back, 30km board)', -9000, 15000)
scenario('zoomed in (500m back, 30km board)', -500, 15000)
scenario('zoomed out (30000m back, 30km board)', -30000, 15000)
'''


def main():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
    lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
    lua.execute(SETUP)
    lua.execute(EXTRA)
    lua.execute(MEASURE)


if __name__ == "__main__":
    main()
