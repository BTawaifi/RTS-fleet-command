"""Continuous-fire behavior for a possessed fighter's native input proxy, and
the manual capital-turret-fire path that lives behind the same call.

The turret path used to have zero coverage: nothing in this file ever set
PilotTurretGroups, so UpdatePilotTurretFire returned at fs2rts_pilot/turret_targeting.lua:96-99
before it ever read Config.Pilot.TurretFireLatches at :201. That left the whole
manual-fire feature -- the pcall(turretTrigger,...) wrapper, both TurretFire*
config keys, and the per-turret PrimaryTriggerDown write -- unexercised.

Run: python core/tools/test_pilot_fire.py
"""
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

SCRIPTS = Path(__file__).resolve().parents[1] / "data/scripts"


# Full fs2rts_util surface. fs2rts_pilot binds all twelve helpers as
# module-locals; a stub missing any of them makes a reached call site fail on
# "attempt to call a nil value" instead of on a real assertion. Mirrors
# data/scripts/fs2rts_util.lua.
UTIL_STUB = r'''
ba=ba or {}
mn=mn or {} -- mission library boundary; directive events are covered by the full-runtime suite
local Vec={}; Vec.__index=Vec
function Vec.__add(a,b) return ba.createVector(a.x+b.x,a.y+b.y,a.z+b.z) end
function Vec.__sub(a,b) return ba.createVector(a.x-b.x,a.y-b.y,a.z-b.z) end
function Vec.__mul(a,b) return ba.createVector(a.x*b,a.y*b,a.z*b) end
function Vec.__div(a,b) return ba.createVector(a.x/b,a.y/b,a.z/b) end
function Vec.__unm(a) return ba.createVector(-a.x,-a.y,-a.z) end
ba.createVector=ba.createVector or function(x,y,z) return setmetatable({x=x,y=y,z=z},Vec) end
function Vec:getDistance(other) return math.sqrt((self.x-other.x)^2+(self.y-other.y)^2+(self.z-other.z)^2) end
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
'''


# Per-turret PrimaryTriggerDown spy. Lua 5.1 only consults __newindex for keys
# that are ABSENT, so the raw key is deliberately never set: every write is
# intercepted and counted. A rawsets-based counter sees the first write and
# then silently passes every later one, which is exactly the "latched fire does
# not keep firing" bug this suite exists to catch.
TRIGGER_SPY = r'''
TRIG=setmetatable({}, {__mode='k'})
function fires(t) local e=TRIG[t]; return e and e.fires or 0 end
 function lastTrigger(t) local e=TRIG[t]; if e==nil then return false end; return e.last==true end
function writes(t) local e=TRIG[t]; return e and e.writes or 0 end
local function spyTurret(t)
  if getmetatable(t)~=nil and TRIG[t]~=nil then return end
  setmetatable(t,{__newindex=function(tbl,k,v)
    if k=='PrimaryTriggerDown' then
      local e=TRIG[tbl]; if e==nil then e={writes=0,fires=0}; TRIG[tbl]=e end
      e.writes=e.writes+1; e.last=v; if v==true then e.fires=e.fires+1 end
    else rawset(tbl,k,v) end
  end})
end
'''


class PilotFireTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(UTIL_STUB)
        self.lua.execute('''
          package.preload.fs2rts_config=function() return {} end
          R={}; package.preload.fs2rts_state=function() return R end
          require "fs2rts_pilot"
          gr={setCamera=function() end}
          local function banks() return {Linked=false,DualFire=false} end
          local ship={valid=true,HitpointsLeft=100,AfterburnerFuelLeft=0,PrimaryBanks=banks(),SecondaryBanks=banks(),
            Physics={VelocityMax={z=100},Velocity={z=0},AfterburnerActive=false}}
          function ship:isValid() return self.valid end
          function ship:getBreedName() return 'Ship' end
          function ship:isDying() return false end
          function ship:doManeuver() end
          function ship:firePrimary() self.fired=(self.fired or 0)+1 end
          function ship:fireSecondary() end; function ship:fireCountermeasure() end
          local observer={valid=true,Target=nil,PrimaryBanks=banks(),SecondaryBanks=banks(),
            Physics={AfterburnerActive=false}}
          function observer:isValid() return self.valid end
          function observer:getBreedName() return 'Ship' end
          function observer:isDying() return false end
          R.PossessedSignature=10; R.PendingPilotEject=false; R.PilotButtons={0,0,0,0}
          R.ControlInfo={Forward=0,ForwardCruise=0,Heading=0,Pitch=0,Bank=0,Vertical=0,Sideways=0,
            PrimaryCount=1,SecondaryCount=0,CountermeasureCount=0,
            pollAllButtons=function() return 0,0,0,0 end,getButtonControlNumber=function() return -1 end}
          R.GetPossessedShip=function() return ship end; R.GetObserver=function() return observer end
          R.MirrorPilotTelemetryToObserver=function() end
          R.ship=ship
        ''')

    def test_holding_primary_control_fires_each_frame_and_release_clears_trigger(self):
        self.lua.execute('''
          R:UpdatePilotMode(0.033)
          R:UpdatePilotMode(0.033)
          assert(R.ship.fired==2 and R.ship.PrimaryTriggerDown==true,
            'held primary input did not fire on each update')
          R.ControlInfo.PrimaryCount=0
          R:UpdatePilotMode(0.033)
          assert(R.ship.PrimaryTriggerDown==false,'primary trigger remained held after release')
        ''')

    def test_paused_pilot_does_not_issue_fire_or_maneuver_commands(self):
        self.lua.execute('''
          R.Paused=true; R.ship.PrimaryTriggerDown=true; R.ship.Physics.AfterburnerActive=true
          local calls=0
          R.ship.doManeuver=function() calls=calls+1 end
          R.ship.firePrimary=function() calls=calls+1 end
          R.ship.fireSecondary=function() calls=calls+1 end
          R.ship.fireCountermeasure=function() calls=calls+1 end
          R.ControlInfo.PrimaryCount=1; R.ControlInfo.SecondaryCount=1; R.ControlInfo.CountermeasureCount=1
          R:UpdatePilotMode(.033)
          assert(calls==0,'direct control issued simulation commands while paused')
          assert(not R.ship.PrimaryTriggerDown and not R.ship.Physics.AfterburnerActive)
          R.Paused=false; R:UpdatePilotMode(.033)
          assert(calls>=3,'resuming did not restore direct control')
        ''')

    def test_withdrawal_approach_pilot_cannot_fire(self):
        self.lua.execute('''
          R.IsShipWithdrawing=function() return true end
          R.ControlInfo.PrimaryCount=1; R.ControlInfo.SecondaryCount=1
          R.ControlInfo.CountermeasureCount=1
          local before=R.ship.fired or 0
          R:UpdatePilotMode(.033)
          assert((R.ship.fired or 0)==before and R.ship.PrimaryTriggerDown==false,
            'possessed extraction ship fired primaries while approaching withdrawal')
        ''')

    def test_targeting_possessed_hull_clears_previous_combat_target(self):
        self.lua.execute('''
          function R.ship:getSignature() return 10 end
          local observer=R:GetObserver()
          observer.Target=R.ship
          R.ship.Target={isValid=function() return true end,getSignature=function() return 20 end}
          R:UpdatePilotMode(.033)
          assert(R.ship.Target==nil,'self-targeting preserved a stale combat target')
        ''')


# A capital with two weapon families: one unlocked laser turret, one laser
# turret that was ALREADY TurretLocked before possession, and one harpoon
# turret. InitializePilotTurretGroups groups by weapon name and sorts by label,
# so this yields group 1 = Harpoon (ship[3]) and group 2 = Laser (ship[1],
# ship[2] with wasLocked=true).
CAPITAL_FIXTURE = r'''
gr=gr or {setCamera=function() end}
package.preload.fs2rts_config=function()
  return {CarrierShip='Blue Station',ObserverShip='Observer',Pilot={ToggleKey='P',
    ClassPrefixes={'GTF '},CapitalClassPrefixes={'GTD '},
    TurretGroupPreviousKey='[',TurretGroupNextKey=']',
    TurretFireLatches=true,TurretFireStatusLine='MANUAL TURRET FIRE ACTIVE'}}
end
R={}; package.preload.fs2rts_state=function() return R end
require 'fs2rts_pilot'
R.Config=require 'fs2rts_config'; R.Enabled=true; R.PossessedSignature=7
R.IsFriendly=function(self,s) return s~=nil and s.team=='BLUE' end
-- Possession gates on this; the real mod defines it in fs2rts_factions.lua.
R.IsStaticDefense=function(self,s) return s~=nil and s.isSentry==true end
-- The old subsystem trigger was a STATE write (PrimaryTriggerDown = true/false),
-- so the suite could observe a per-frame commanded state and assert a veto
-- turret was "held at false". fireWeapon is a one-shot EVENT with no release
-- call, so synthesise the release: clear the observed state at the start of
-- each pass. lastTrigger(t) then means "was this turret commanded to fire on the
-- most recent pass", which is what the veto/latch tests are actually about.
local realTurretFire=R.UpdatePilotTurretFire
R.UpdatePilotTurretFire=function(self,primaryDown,secondaryDown)
  for _,g in ipairs(self.PilotTurretGroups or {}) do
    for _,e in ipairs(g.turrets or {}) do
      local t=e.subsystem
      if TRIG[t] then TRIG[t].last=false end
    end
  end
  return realTurretFire(self,primaryDown,secondaryDown)
end
R.IsPlayerEnemy=function(self,s) return s~=nil and s.team=='RED' end
R.AreEnemies=function(self,a,b) return a.team~=b.team end
R.GetFactionKey=function(self,s) return s and s.team end
R.GetShipRole=function(self,s) return s and s.role end
R.GetWeaponFiringRange=function(self,w) return w.Range end
R.FindShipBySignature=function(self,id) return id==99 and self.target or nil end
R.GetShipList=function(self) return {self.ship,self.target} end
R.IsFiniteVector=function(self,p) return p~=nil and p.x==p.x and p.y==p.y and p.z==p.z end
R.GetBattleMapHalfExtent=function() return 20000 end
R.SetStatus=function(self,text,secs) self.statusText=text; self.statusAt=secs end
R.UINowValue=0
R.UINow=function(self) return self.UINowValue end
local target={valid=true,HitpointsLeft=100,team='RED',signature=99,Position=ba.createVector(0,0,3000)}
function target:getSignature() return self.signature end
function target:isValid() return self.valid end
function target:getBreedName() return 'Ship' end
function target:isDying() return false end
local function bank(name)
  local weapon={Name=name,Range=10000,isValid=function() return true end,isBeam=function() return false end}
  return {WeaponClass=weapon,isValid=function() return true end}
end
local function turret(name,locked)
  local s={valid=true,Name=name,TurretLocked=locked,PrimaryBanks={bank(name)},SecondaryBanks={bank(name..' sec')}}
  function s:isValid() return self.valid end
  function s:isTurret() return true end
  function s:targetingOverride(v) self.overridden=v; return true end
  s.WorldPosition=ba.createVector(0,0,0)
  function s:rotateTurret(aim) self.aim=aim; return true end
  function s:isTargetInFOV() return true end
  function s:isPositionInFOV() return true end
  function s:getNextFiringPosition() return self.WorldPosition,ba.createVector(0,0,1) end
  -- FSO's only subsystem-level trigger is fireWeapon(slot, flakRange, overrideVec):
  -- there is no firePrimary and no PrimaryTriggerDown on l_Subsystem (the latter
  -- is a SHIP property). slot is a flat index over the turret's own weapon list,
  -- primaries first, splitting at MAX_SHIP_PRIMARY_BANKS=3. Model it faithfully so
  -- the suite actually exercises the code path the engine runs.
  function s:fireWeapon(slot,flakRange,overrideVec)
    -- Count through TRIG directly with rawset: the spyTurret __newindex only
    -- intercepts NEW keys and treats a `true` write as a trigger press, so
    -- writing counters through it would double-count.
    local e=TRIG[self]; if e==nil then e={writes=0,fires=0}; TRIG[self]=e end
    e.fires=e.fires+1; e.last=true
    if slot<=3 then rawset(self,'primaryFires',(rawget(self,'primaryFires') or 0)+1)
    else rawset(self,'secondaryFires',(rawget(self,'secondaryFires') or 0)+1) end
    rawset(self,'lastSlot',slot); rawset(self,'lastFlak',flakRange)
    return true
  end
  function s:fireSecondaries() rawset(self,'secondaryFires',(rawget(self,'secondaryFires') or 0)+1) end
  return s
end
local function banks() return {Linked=false,DualFire=false} end
local observer={valid=true,Target=target,PrimaryBanks=banks(),SecondaryBanks=banks(),
  Physics={AfterburnerActive=false}}
function observer:isValid() return self.valid end
function observer:getBreedName() return 'Ship' end
function observer:isDying() return false end
local ship={valid=true,Name='Blue Capital',Class={Name='GTD Hecate'},team='BLUE',Target=target,
  HitpointsLeft=100,AfterburnerFuelLeft=0,PrimaryBanks=banks(),SecondaryBanks=banks(),
  Physics={VelocityMax={z=100},Velocity={z=0},AfterburnerActive=false}}
ship.Position=ba.createVector(0,0,0); ship.Orientation={getFvec=function() return ba.createVector(0,0,1) end}
function ship:isValid() return self.valid end
function ship:getSignature() return 7 end
function ship:getBreedName() return 'Ship' end
function ship:isDying() return false end
function ship:doManeuver() end
function ship:firePrimary() self.fired=(self.fired or 0)+1 end
function ship:fireSecondary() end; function ship:fireCountermeasure() end
ship[1]=turret('Laser',false); ship[2]=turret('Laser',true); ship[3]=turret('Harpoon',false)
R.ship=ship; R.target=target; R.observer=observer
R.GetPossessedShip=function() return ship end; R.GetObserver=function() return observer end
R.MirrorPilotTelemetryToObserver=function() end
require 'fs2rts_fleet_life'; R.Withdrawals={}; R.AllowWithdrawal={}
'''


class CapitalTurretFireTests(unittest.TestCase):
    def test_projectile_battery_uses_target_vector_instead_of_resting_barrel_and_reports_cycle(self):
        self.lua.execute('''
          mn.getMissionTime=function() return R.UINowValue end
          R:InitializePilotTurretGroups(R.ship)
          local turret=R.ship[1]
          local weapon=turret.PrimaryBanks[1].WeaponClass
          weapon.Speed=1000; weapon.LifeMax=10; weapon.FireWait=3
          local actual=turret.fireWeapon
          turret.fireWeapon=function(self,slot,range,direction) self.firedDirection=direction; return actual(self,slot,range,direction) end
          R.target.Position=ba.createVector(3000,0,3000)
          R:UpdatePilotTurretFire(true,false)
          assert(turret.primaryFires==1 and turret.firedDirection and turret.firedDirection.x>.7 and turret.firedDirection.z>.7,'projectile fires in default barrel direction while aiming elsewhere')
          turret.getNextFiringPosition=function() return turret.WorldPosition,ba.createVector(.70710678,0,.70710678) end
          R:UpdatePilotTurretFire(true,false)
          assert(turret.primaryFires==2,'aligned battery never fires')
          local entry
          for _,g in ipairs(R.PilotTurretGroups) do for _,e in ipairs(g.turrets) do if e.subsystem==turret then entry=e end end end
          assert(entry.cooldowns and entry.cooldowns[1]==3,'successful shot has no weapon cycle telemetry')
        ''')

    def test_battery_search_reads_turret_origin_once_and_rejects_out_of_range_before_iff(self):
        self.lua.execute('''
          R:InitializePilotTurretGroups(R.ship)
          local entry=R.PilotTurretGroups[1].turrets[1]
          local turret=entry.subsystem; local origin=turret.WorldPosition
          turret.WorldPosition=nil; local reads=0
          setmetatable(turret,{__index=function(_,key)
            if key=='WorldPosition' then reads=reads+1; return origin end
          end})
          turret.getNextFiringPosition=function() return origin,ba.createVector(0,0,1) end
          local enemies=R.AreEnemies; local checks=0
          R.AreEnemies=function(self,a,b) checks=checks+1; return enemies(self,a,b) end
          R.target.Position=ba.createVector(0,0,3000)
          R.PilotBatteryCandidates={at=0,ships={R.target,R.target,R.target}}
          assert(R:GetPilotBatteryTarget(R.ship,entry,nil)==R.target)
          assert(reads==1,'battery search repeats native turret origin reads')
          checks=0; R.UINowValue=1; R.target.Position=ba.createVector(0,0,30000)
          R.PilotBatteryCandidates={at=1,ships={R.target}}
          assert(R:GetPilotBatteryTarget(R.ship,entry,R.target)==nil)
          assert(checks==0,'out-of-range candidates repeat IFF queries')
        ''')

    def test_automatic_pilot_gunners_respect_passage_but_direct_target_still_fires(self):
        self.lua.execute('''
          R:InitializePilotTurretGroups(R.ship)
          R.Withdrawals={[99]={faction='RED',inCorridor=true}}
          local entry=R.PilotTurretGroups[1].turrets[1]
          assert(R:CanAutoEngage(R.ship,R.target)==false,'passage fixture is not protected')
          assert(R:GetPilotBatteryTarget(R.ship,entry,nil)==nil,
            'automatic capital battery reacquired a permitted passage target')
          assert(R:GetPilotBatteryTarget(R.ship,entry,R.target)==R.target,
            'explicitly selected passage target could not be intercepted')
          R.GetShipRole=function() return 'fighter' end
          entry.flakWeapon={Range=10000}
          assert(R:GetPilotFlakTarget(R.ship,entry,nil)==nil,
            'automatic flak fallback reacquired a permitted passage target')
          assert(R:GetPilotFlakTarget(R.ship,entry,R.target)==R.target,
            'explicitly selected passage fighter could not be intercepted by flak')
        ''')

    def test_native_fire_buttons_work_without_ship_bank_counts_and_flak_uses_target_distance(self):
        self.lua.execute('''
          R:InitializePilotTurretGroups(R.ship)
          R.ControlInfo={Forward=0,ForwardCruise=0,PrimaryCount=0,SecondaryCount=0,
            pollAllButtons=function() return 0,0,0,0 end,getButtonControlNumber=function() return -1 end}
          R.IsPilotControlDown=function(self,buttons,name) return name=='FIRE_PRIMARY' end
          R:UpdatePilotMode(.033)
          assert(R.ship[1].primaryFires==1 and R.ship[3].primaryFires==1,'native trigger depends on nonexistent capital ship banks')
          assert(R.ship[1].lastFlak==3000,'flak explodes at 100m rather than the target distance')
          assert(R.ship[1].TurretLocked and R.ship[3].TurretLocked,'native AI retains trigger ownership')
          local before=R.ship[1].primaryFires
          R.IsPilotControlDown=function() return false end
          R:UpdatePilotMode(.033)
          assert(R.ship[1].primaryFires==before,'release still fires')
        ''')

    def test_secondary_status_uses_the_same_throttle_as_primary_fire(self):
        self.lua.execute('''
          R:InitializePilotTurretGroups(R.ship)
          R.UINowValue=10; R:UpdatePilotTurretFire(false,true)
          R.UINowValue=10.2; R:UpdatePilotTurretFire(false,true)
          assert(R.PilotTurretFireStatusAt==10,'held secondary input refreshed status every frame')
          R.UINowValue=10.5; R:UpdatePilotTurretFire(false,true)
          assert(R.PilotTurretFireStatusAt==10.5)
          R:UpdatePilotTurretFire(false,false)
          R.UINowValue=10.6; R:UpdatePilotTurretFire(false,true)
          assert(R.PilotTurretFireStatusAt==10.6,'fresh secondary press failed to announce')
        ''')

    def test_secondary_trigger_fires_without_primary_trigger(self):
        self.lua.execute('''
          R:InitializePilotTurretGroups(R.ship)
          R.PilotTurretGroupIndex=1
          R:UpdatePilotTurretFire(false,true)
          assert(R.ship[3].secondaryFires==1 and (R.ship[3].primaryFires or 0)==0,
            'capital missiles require the primary trigger too')
          assert(R.PilotTurretFiring)
        ''')

    """fs2rts_pilot/turret_targeting.lua:94-123. Turret grouping, latched vs held fire, group
    exclusivity, the pre-locked-turret veto, and the pcall wrapper."""

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(UTIL_STUB)
        self.lua.execute(TRIGGER_SPY)
        self.lua.execute(CAPITAL_FIXTURE)
        self.lua.execute('''
          for i=0,#R.ship do
            local t=R.ship[i]
            if t~=nil then
              local raise=nil
              setmetatable(t,{__newindex=function(tbl,k,v)
                if k=='PrimaryTriggerDown' then
                  if raise~=nil then raise=raise-1; if raise>=0 then error('subsystem deleted mid-frame',0) end end
                  local e=TRIG[tbl]; if e==nil then e={writes=0,fires=0}; TRIG[tbl]=e end
                  e.writes=e.writes+1; e.last=v; if v==true then e.fires=e.fires+1 end
                else rawset(tbl,k,v) end
              end})
            end
          end
        ''')

    def check(self, code):
        self.lua.execute(code)

    def test_latched_fire_holds_the_active_group_down_for_every_frame(self):
        # TurretFireLatches defaults true, so a held trigger keeps the active
        # group's turrets pressed on each frame instead of firing once.
        self.check("""R:InitializePilotTurretGroups(R.ship)
          assert(#R.PilotTurretGroups==2,'turrets with equal weapons were not grouped')
          assert(R.PilotTurretGroupIndex==nil,'capital possession should start with all batteries enabled')
          R.PilotTurretGroupIndex=1
          local group=R.PilotTurretGroups[1]
          assert(group.label=='Harpoon + Harpoon sec','groups are not ordered by label: '..group.label)
          R:UpdatePilotTurretFire(true,false)
          assert(fires(R.ship[3])==1,'first held frame did not press the active turret: '..fires(R.ship[3]))
          assert(R.PilotTurretFiring==true and R.PilotTurretFireLatched==true)
          R:UpdatePilotTurretFire(true,false)
          R:UpdatePilotTurretFire(true,false)
          assert(fires(R.ship[3])==3,'a latched hold did not keep firing on every frame: '..fires(R.ship[3]))
          assert(R.PilotTurretFireLatched==true,'a latched hold released the trigger between frames')
          -- Releasing writes false so the turret actually stops shooting.
          R:UpdatePilotTurretFire(false,false)
          assert(lastTrigger(R.ship[3])==false,'release did not clear the turret trigger')
          assert(R.PilotTurretFiring==false and R.PilotTurretFireLatched==false)""")

    def test_unlatched_fire_is_edge_only_and_never_retriggers_while_held(self):
        # TurretFireLatches=false turns the same held input into one press.
        self.check("""R.Config.Pilot.TurretFireLatches=false
          R:InitializePilotTurretGroups(R.ship)
          R:UpdatePilotTurretFire(false,false)
          assert(fires(R.ship[3])==0,'an idle frame fired a turret')
          R:UpdatePilotTurretFire(true,false)
          assert(fires(R.ship[3])==1,'the press edge did not fire')
          R:UpdatePilotTurretFire(true,false)
          R:UpdatePilotTurretFire(true,false)
          assert(fires(R.ship[3])==1,
            'edge-only fire retriggered while the button was still held: '..fires(R.ship[3]))
          assert(R.PilotTurretFireLatched==true,'the held state was not remembered for the edge test')
          R:UpdatePilotTurretFire(false,false)
          R:UpdatePilotTurretFire(true,false)
          assert(fires(R.ship[3])==2,'a fresh press after a release did not fire again')
          -- Back to latching, the same hold must fire every frame again.
          R.Config.Pilot.TurretFireLatches=true
          R:UpdatePilotTurretFire(true,false)
          R:UpdatePilotTurretFire(true,false)
          assert(fires(R.ship[3])==4,'latching did not resume: '..fires(R.ship[3]))""")

    def test_only_the_active_group_fires_and_all_groups_live_fires_every_turret(self):
        self.check("""R:InitializePilotTurretGroups(R.ship)
          R.PilotTurretGroupIndex=1
          local laser=R.PilotTurretGroups[2]
          assert(laser.label=='Laser + Laser sec' and #laser.turrets==2,'laser group is wrong')
          R:UpdatePilotTurretFire(true,false)
          assert(fires(R.ship[3])==1,'the active group did not fire')
          assert(fires(R.ship[1])==0,'an inactive group fired: '..fires(R.ship[1]))
          assert(lastTrigger(R.ship[1])==false,'an inactive turret was not explicitly told to stop')
          R:CyclePilotTurretGroup(1)
          assert(R.PilotTurretGroupIndex==2)
          TRIG[R.ship[3]]=nil; TRIG[R.ship[1]]=nil
          R:UpdatePilotTurretFire(true,false)
          assert(fires(R.ship[1])==1,'the newly active group did not fire')
          assert(fires(R.ship[3])==0,'the previous group kept firing after the switch: '..fires(R.ship[3]))
          -- A nil group index means the whole battery: every group is live.
          R:TogglePilotTurretGroup()
          assert(R.PilotTurretGroupIndex==nil,'all-groups toggle did not clear the index')
          TRIG[R.ship[1]]=nil; TRIG[R.ship[3]]=nil
          R:UpdatePilotTurretFire(true,false)
          assert(fires(R.ship[1])==1 and fires(R.ship[3])==1,
            'all-groups mode did not fire every group: '..fires(R.ship[1])..'/'..fires(R.ship[3]))""")

    def test_a_turret_locked_before_possession_never_fires(self):
        # ship[2] was TurretLocked before possession. entry.wasLocked is the
        # veto at fs2rts_pilot/turret_targeting.lua:108, and it must hold in all-groups mode too,
        # which is the case where every group is live.
        self.check("""assert(R.ship[2].TurretLocked==true,'fixture precondition: the locked turret is not locked')
          R:InitializePilotTurretGroups(R.ship)
          R.PilotTurretGroupIndex=2
          R:UpdatePilotTurretFire(true,false)
          assert(fires(R.ship[1])==1,'the live laser turret did not fire')
          assert(fires(R.ship[2])==0,
            'a turret locked before possession fired: '..fires(R.ship[2]))
          assert(lastTrigger(R.ship[2])==false,'the vetoed turret was not held at false')
          R.PilotTurretGroupIndex=nil
          R:UpdatePilotTurretFire(true,false)
          assert(fires(R.ship[2])==0,
            'all-groups mode overrode the pre-locked veto: '..fires(R.ship[2]))
          -- Exit must put the native lock back exactly as it was found.
          R:RestorePilotTurretGroups()
          assert(R.ship[1].TurretLocked==false and R.ship[2].TurretLocked==true and R.ship[3].TurretLocked==false,
            'native turret lock state was not restored on pilot exit')""")

    def test_no_turret_groups_clears_the_latch_and_writes_nothing(self):
        # The early return at :195-198 is the path every non-capital took. It
        # must not leave a stale latch behind: with the latch stuck true, the
        # first frame of the next capital in edge-only mode reads as "not a
        # fresh press" and that turret battery never fires at all. Both
        # InitializePilotTurretGroups and RestorePilotTurretGroups also clear
        # the latch, so this pins the defensive branch itself rather than a
        # sequence the mod can currently reach.
        self.check("""R:InitializePilotTurretGroups(R.ship)
          R:UpdatePilotTurretFire(true,false)
          assert(R.PilotTurretFireLatched==true)
          local previousGroups=R.PilotTurretGroups
          R.PilotTurretGroups=nil
          local before=writes(R.ship[3])
          R:UpdatePilotTurretFire(true,false)
          assert(R.PilotTurretFireLatched==false,'the no-groups path left a stale latch')
          assert(writes(R.ship[3])==before,'the no-groups path still wrote a trigger')
          assert(R.PilotTurretFiring==nil or R.PilotTurretFiring==false)
          -- With a stale latch left in place, edge-only mode would swallow the
          -- first press of the next capital. Prove the reset is what prevents it.
          -- Restore the saved native lock ownership before reinitializing: the
          -- prior groups are deliberately hidden only to exercise the guard.
          R.PilotTurretGroups=previousGroups; R:RestorePilotTurretGroups()
          R:InitializePilotTurretGroups(R.ship)
          R.Config.Pilot.TurretFireLatches=false
          TRIG[R.ship[3]]=nil
          R:UpdatePilotTurretFire(true,false)
          assert(fires(R.ship[3])==1,
            'a stale latch swallowed the first press of the next capital: '..fires(R.ship[3]))""")

    def test_secondary_fire_uses_its_own_trigger_and_respects_group_and_native_locks(self):
        self.check("""R:InitializePilotTurretGroups(R.ship)
          R.PilotTurretGroupIndex=1
          R:UpdatePilotTurretFire(true,true)
          assert(R.ship[3].secondaryFires==1,'the secondary trigger did not reach the active turret')
          assert(R.ship[1].secondaryFires==nil,'an inactive group got secondaries: '..tostring(R.ship[1].secondaryFires))
          R:UpdatePilotTurretFire(true,false)
          assert(R.ship[3].secondaryFires==1,'secondaries fired with the secondary button up')
          local primaryFires=R.ship[3].primaryFires
          R:UpdatePilotTurretFire(false,true)
          assert(R.ship[3].secondaryFires==2,'secondary trigger incorrectly required primary fire')
          assert(R.ship[3].primaryFires==primaryFires,'secondary fire fired a primary bank')
          R.PilotTurretGroupIndex=nil
          R:UpdatePilotTurretFire(false,true)
          assert(R.ship[1].secondaryFires==1 and R.ship[3].secondaryFires==3,
            'all-groups mode did not fire both secondary banks')
          assert(R.ship[2].secondaryFires==nil,'a turret locked before possession fired secondaries')
          R:UpdatePilotTurretFire(false,false)
          assert(R.ship[1].secondaryFires==1 and R.ship[3].secondaryFires==3,
            'released secondary trigger kept firing')""")

    def test_a_turret_that_rejects_the_trigger_does_not_abort_the_frame(self):
        # Inject at the real engine call; PrimaryTriggerDown is not a turret API.
        self.check("""R:InitializePilotTurretGroups(R.ship)
          R.PilotTurretGroupIndex=nil
          local attempts=0; local realFire=R.ship[3].fireWeapon
          R.ship[3].fireWeapon=function() attempts=attempts+1; assert(false,'injected native fire error') end
          R:UpdatePilotTurretFire(true,false)
          assert(attempts==1,'failure injection was never reached')
          assert(R.PilotTurretFiring==true,'a raising turret aborted the whole fire pass')
          assert(R.ship[1].primaryFires==1,'a failed turret prevented another live turret firing')
          -- One bad frame must not poison the next one.
          R.ship[3].fireWeapon=realFire
          R:UpdatePilotTurretFire(true,false)
          assert(R.ship[1].primaryFires==2 and R.ship[3].primaryFires==1,
            'a previous failure suppressed later frames')
          assert(R.PilotTurretFiring==true)""")

    def test_status_line_is_announced_and_rate_limited_to_half_a_second(self):
        # The 0.5 s throttle at :215 keeps a held trigger from spamming the
        # status line every frame, but the first frame and every half second
        # must announce. The configured line is used, not a hardcoded string.
        self.check("""R:InitializePilotTurretGroups(R.ship)
          R.Config.Pilot.TurretFireStatusLine='BEAM BATTERY HOT'
          R.UINowValue=10
          R:UpdatePilotTurretFire(true,false)
          assert(R.statusText=='BEAM BATTERY HOT','the configured status line was not used: '..tostring(R.statusText))
          assert(R.statusAt==0.6)
          R.UINowValue=10.2; R:UpdatePilotTurretFire(true,false)
          R.UINowValue=10.49; R:UpdatePilotTurretFire(true,false)
          assert(R.PilotTurretFireStatusAt==10,'a sub-throttle tick moved the window: '..tostring(R.PilotTurretFireStatusAt))
          R.UINowValue=10.5; R:UpdatePilotTurretFire(true,false)
          assert(R.PilotTurretFireStatusAt==10.5,'the throttle window did not move at the half-second boundary: '..tostring(R.PilotTurretFireStatusAt))
          assert(R.statusText=='BEAM BATTERY HOT')
          -- Falling silent re-arms the announcement for the next press.
          R:UpdatePilotTurretFire(false,false)
          assert(R.PilotTurretFireStatusAt==nil,'release did not clear the throttle window')
          R.UINowValue=20; R:UpdatePilotTurretFire(true,false)
          assert(R.PilotTurretFireStatusAt==20,'a fresh press did not announce immediately')
          -- The fallback string is used when the config key is absent.
          R.Config.Pilot.TurretFireStatusLine=nil
          R:UpdatePilotTurretFire(false,false); R.UINowValue=30; R:UpdatePilotTurretFire(true,false)
          assert(R.statusText=='MANUAL TURRET FIRE ACTIVE','missing config key did not fall back: '..tostring(R.statusText))""")

    def test_update_pilot_mode_drives_the_turret_fire_path_end_to_end(self):
        # The wiring at fs2rts_pilot/possession_state.lua:34: holding primary in pilot mode must
        # reach the capital's turrets, not just the hull's own banks.
        self.check("""R:InitializePilotTurretGroups(R.ship)
          R.ControlInfo={Forward=0,ForwardCruise=0,Heading=0,Pitch=0,Bank=0,Vertical=0,Sideways=0,
            PrimaryCount=1,SecondaryCount=0,CountermeasureCount=0,
            pollAllButtons=function() return 0,0,0,0 end,getButtonControlNumber=function() return -1 end}
          R.IsPilotControlDown=function() return false end
          R.IsPilotControlPressed=function() return false end
          R:UpdatePilotMode(0.033)
          assert(fires(R.ship[3])==1,'holding primary in pilot mode did not fire the capital turrets: '..fires(R.ship[3]))
          assert(R.PilotTurretFiring==true)
          R:UpdatePilotMode(0.033)
          assert(fires(R.ship[3])==2,'the second pilot frame did not hold the turret trigger: '..fires(R.ship[3]))
          R.ControlInfo.PrimaryCount=0
          R:UpdatePilotMode(0.033)
          assert(lastTrigger(R.ship[3])==false,'releasing primary left the turrets firing')
          assert(R.PilotTurretFiring==false)""")


if __name__ == "__main__":
    unittest.main()
