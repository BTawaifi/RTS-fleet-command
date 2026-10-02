"""Capital possession selects and restores native turret weapon groups."""
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

SCRIPTS = Path(__file__).resolve().parents[1] / "data/scripts"

FIXTURE = r'''
package.preload.fs2rts_config=function()
  return {CarrierShip='Blue Station',ObserverShip='Observer',Pilot={ToggleKey='P',ClassPrefixes={'GTF '},
    CapitalClassPrefixes={'GTD '},TurretGroupPreviousKey='[',TurretGroupNextKey=']'}}
end
-- FSO always defines a controls table; OnKeyPressed reads controls.Pause at the
-- top of the hook, so a harness that drives key input must provide it.
controls=controls or {}
-- Full fs2rts_util surface. fs2rts_pilot binds all twelve helpers as
-- module-locals; the ones that used to be missing here were NIL, so a reached
-- call site failed on "attempt to call a nil value" instead of on a real
-- assertion. Mirrors data/scripts/fs2rts_util.lua.
local Vec={}; Vec.__index=Vec
function Vec.__add(a,b) return ba.createVector(a.x+b.x,a.y+b.y,a.z+b.z) end
function Vec.__sub(a,b) return ba.createVector(a.x-b.x,a.y-b.y,a.z-b.z) end
function Vec.__mul(a,b) return ba.createVector(a.x*b,a.y*b,a.z*b) end
function Vec.__div(a,b) return ba.createVector(a.x/b,a.y/b,a.z/b) end
function Vec.__unm(a) return ba.createVector(-a.x,-a.y,-a.z) end
ba={createVector=function(x,y,z) return setmetatable({x=x,y=y,z=z},Vec) end}
local function objValid(o) return o~=nil and o:isValid() end
package.preload.fs2rts_util=function()
  return {AI_FACTION_ORDER={'BLUE','RED','GOLD'},sortedNumericKeys=function(t)
      local r={}; for k in pairs(t) do r[#r+1]=k end; table.sort(r); return r end,
    clamp=function(v,a,b) return math.max(a,math.min(b,v)) end,
    lower=function(v) if v==nil then return '' end return string.lower(tostring(v)) end,
    vec=ba.createVector, copyVec=function(v) return ba.createVector(v.x,v.y,v.z) end,
    distance2=function(x1,y1,x2,y2) local dx=x1-x2; local dy=y1-y2; return dx*dx+dy*dy end,
    objectValid=objValid,
    shipValid=function(s) return objValid(s) and s:getBreedName()=='Ship' end,
    shipAlive=function(s) return objValid(s) and not s:isDying() and (tonumber(s.HitpointsLeft) or 0)>0 end,
    teamName=function(s) if not objValid(s) then return '' end return string.lower(tostring(s.Team.Name)) end,
    tableContainsSignature=function(list,sig)
      for _,v in ipairs(list or {}) do if v==sig then return true end end
      return false end}
end
R={}; package.preload.fs2rts_state=function() return R end
R.Config=require 'fs2rts_config'; R.Enabled=true; R.PossessedSignature=7
require 'fs2rts_pilot'; require 'fs2rts_input'
    R.IsFriendly=function(self,s) return s~=nil and s.team=='BLUE' end
    -- Possession gates on this. The real mod always defines IsStaticDefense in
    -- fs2rts_factions.lua, so the double must too now that IsPilotableShip
    -- consults it.
    R.IsStaticDefense=function(self,s) return s~=nil and s.isSentry==true end
R.IsPlayerEnemy=function(self,s) return s~=nil and s.team=='RED' end
R.IsMissionPauseDisabled=function() return false end
R.SetStatus=function(self,s) self.status=s end
local target={valid=true,team='RED',signature=99}
function target:getSignature() return self.signature end
function target:isValid() return self.valid end
-- The faithful shipValid/shipAlive above call the real engine methods
-- getBreedName() and isDying(), so the fixtures have to answer them. A hull
-- without getBreedName is not a Ship in the engine either.
function target:getBreedName() return 'Ship' end
function target:isDying() return false end
local function bank(name)
  local weapon={Name=name,isValid=function() return true end}
  return {WeaponClass=weapon,isValid=function() return true end}
end
local function turret(name,locked)
  local s={valid=true,Name=name,TurretLocked=locked,PrimaryBanks={bank(name)},SecondaryBanks={}}
  function s:isValid() return self.valid end
  function s:isTurret() return true end
  function s:targetingOverride(v) self.overridden=v; return true end
  return s
end
local ship={valid=true,Name='Blue Capital',Class={Name='GTD Hecate'},team='BLUE',Target=target}
function ship:isValid() return self.valid end
function ship:getSignature() return 7 end
function ship:getBreedName() return 'Ship' end
function ship:isDying() return false end
ship.Team={Name='BLUE'}; target.Team={Name='RED'}
ship[1]=turret('Laser',false); ship[2]=turret('Laser',true); ship[3]=turret('Harpoon',false)
R.ship=ship; R.target=target; R.GetPossessedShip=function() return ship end
'''


class PilotTargetSubsystemTests(unittest.TestCase):
    """Subsystem.Target is object-only, so selecting a target subsystem must
    never hand a subsystem to the setter. This is the crash that made capitals
    unpilotable: it threw inside StartPilotMode's turret init."""

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(FIXTURE)

    def check(self, code):
        self.lua.execute(code)

    def test_selecting_a_target_subsystem_never_passes_a_subsystem_to_target(self):
        self.check('''
          -- Give the enemy hull subscriptable subsystems and make the Target
          -- setter behave like the engine: ADE_VIRTVAR(Target, l_Subsystem,
          -- "object", ...) reads its argument with l_Object.GetPtr, so anything
          -- that is not an object is a hard type error.
          local subsysA={valid=true,Name='shield generator'}
          local subsysB={valid=true,Name='engine'}
          for _,s in ipairs({subsysA,subsysB}) do function s:isValid() return self.valid end end
          R.target[1]=subsysA; R.target[2]=subsysB
          local assigned={}
          for i=0,#R.ship do
            local t=R.ship[i]
            if t~=nil then
              t.valid=true
              -- The engine's own rule: only an object may be stored. The
              -- metatable goes on the turret, not on the value, and intercepts
              -- only Target so the rest of the hull still behaves normally.
              setmetatable(t,{__newindex=function(tbl,k,v)
                if k=='Target' then
                  if v~=nil and (v==subsysA or v==subsysB) then
                    error("Argument 2 is the wrong type of userdata; 'subsystem' given, but 'object' expected",0)
                  end
                  assigned[i]=v
                else rawset(tbl,k,v) end
              end})
            end
          end
          R:InitializePilotTurretGroups(R.ship)
          -- Only the active group's turrets are driven, so assert on those
          -- rather than on a fixed turret index.
          local active=R.PilotTurretGroups[R.PilotTurretGroupIndex]
          local function assertActiveHasTarget(why)
            for _,entry in ipairs(active.turrets) do
              local idx=entry.subsystem
              for i=0,#R.ship do if R.ship[i]==idx then idx=i end end
              assert(assigned[idx]==R.target,why)
            end
          end
          R.PilotTargetSubsystemIndex=1
          R:ApplyPilotTurretGroup(R.target)
          assertActiveHasTarget('the active turret group was not pointed at the target object')
          R.PilotTargetSubsystemIndex=2
          R:InvalidatePilotTurretTargets()
          R:ApplyPilotTurretGroup(R.target)
          assertActiveHasTarget('a subsystem selection changed what the turrets were given')
          -- Clearing the target must clear it to nil, not leave a stale handle.
          R:InvalidatePilotTurretTargets()
          R:ApplyPilotTurretGroup(nil)
          for _,entry in ipairs(active.turrets) do
            local idx=entry.subsystem
            for i=0,#R.ship do if R.ship[i]==idx then idx=i end end
            assert(assigned[idx]==nil,'turrets kept a stale target after it died')
          end''')


class CapitalPilotTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(FIXTURE)

    def test_capital_pilotable_group_fire_selection_and_restore(self):
        self.lua.execute('''
          assert(R:IsPilotableShip(R.ship),'GTD capital was not accepted for pilot mode')
          R:InitializePilotTurretGroups(R.ship)
          assert(#R.PilotTurretGroups==2,'turrets with equal weapons were not grouped')
          local first=R.PilotTurretGroups[R.PilotTurretGroupIndex]
          assert(first.label=='Harpoon' and #first.turrets==1)
          assert(R.ship[3].TurretLocked==false and R.ship[3].Target==R.target)
          assert(R.ship[1].TurretLocked==true and R.ship[2].TurretLocked==true)
          assert(R:CyclePilotTurretGroup(1))
          local active=R.PilotTurretGroups[R.PilotTurretGroupIndex]
          assert(active.label=='Laser' and #active.turrets==2)
          assert(R.ship[1].TurretLocked==false and R.ship[1].Target==R.target)
          assert(R.ship[2].TurretLocked==true,'a turret locked before possession was unexpectedly enabled')
          assert(R:ShouldOverrideKey(']'))
          R:OnKeyPressed('[')
          assert(R.PilotTurretGroupIndex==1,'turret-group key did not cycle the active weapon system')
          R:RestorePilotTurretGroups()
          assert(R.ship[1].overridden==false and R.ship[2].overridden==false and R.ship[3].overridden==false)
          assert(R.ship[1].TurretLocked==false and R.ship[2].TurretLocked==true and R.ship[3].TurretLocked==false,
            'native turret lock state was not restored on pilot exit')
          assert(R.PilotTurretGroups==nil)
        ''')


if __name__ == "__main__":
    unittest.main()
