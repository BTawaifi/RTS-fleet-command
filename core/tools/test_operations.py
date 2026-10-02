"""Focused Lua 5.1 checks for candidate multi-wing operation contracts.

Run with the repository's existing ai-venv Python executable.
"""
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

SCRIPTS = Path(__file__).resolve().parents[1] / 'data/scripts'

FIXTURE = r'''
local Vec = {}; Vec.__index = Vec
-- FSO's l_Vector is a full arithmetic userdata. Every operator is defined here
-- so that a vector operation inside a reached function fails on the assertion
-- the test makes, not on "attempt to perform arithmetic on a table" or "attempt
-- to call a nil value" from an incomplete double.
function Vec.__add(a,b) return ba.createVector(a.x+b.x,a.y+b.y,a.z+b.z) end
function Vec.__sub(a,b) return ba.createVector(a.x-b.x,a.y-b.y,a.z-b.z) end
function Vec.__mul(a,b) return ba.createVector(a.x*b,a.y*b,a.z*b) end
function Vec.__div(a,b) return ba.createVector(a.x/b,a.y/b,a.z/b) end
function Vec.__unm(a) return ba.createVector(-a.x,-a.y,-a.z) end
function Vec:getDistance(b)
  return math.sqrt((self.x-b.x)^2+(self.y-b.y)^2+(self.z-b.z)^2)
end
ba = {createVector=function(x,y,z) return setmetatable({x=x,y=y,z=z},Vec) end}
local function valid(x)
  if x == nil then return false end
  assert(type(x)=='table','shipAlive received non-object '..type(x))
  return x.valid ~= false
end
package.preload.fs2rts_state = function() return {} end
-- fs2rts_util exports twelve helpers. Stubbing three of them left the other
-- nine as NIL upvalues in fs2rts_operations and fs2rts_strategy, so every code
-- path that reached one died on "attempt to call a nil value (global 'clamp')"
-- -- a harness failure masquerading as coverage. The full surface is provided
-- here, with the same semantics as data/scripts/fs2rts_util.lua.
package.preload.fs2rts_util = function()
  return {shipValid=valid, shipAlive=function(x) return valid(x) and (tonumber(x.HitpointsLeft) or 0)>0 end,
    vec=ba.createVector,
    copyVec=function(v) return ba.createVector(v.x,v.y,v.z) end,
    clamp=function(v,lo,hi) if v<lo then return lo end if v>hi then return hi end return v end,
    lower=function(v) if v==nil then return '' end return string.lower(tostring(v)) end,
    objectValid=valid,
    distance2=function(x1,y1,x2,y2) local dx=x1-x2; local dy=y1-y2; return dx*dx+dy*dy end,
    teamName=function(s) if not valid(s) then return '' end return string.lower(tostring((s.Team or {}).Name or '')) end,
    tableContainsSignature=function(list,sig)
      for _,v in ipairs(list or {}) do if v==sig then return true end end
      return false end,
    sortedNumericKeys=function(source)
      local keys={}; for k in pairs(source or {}) do keys[#keys+1]=k end; table.sort(keys); return keys end,
    AI_FACTION_ORDER={'BLUE','RED','GOLD'}}
end
R = require 'fs2rts_operations'
R.Config={AI={Operations={RallyRadius=100,AssembleSeconds=10,AttackSeconds=360,RegroupSeconds=5},
  Doctrine={AssaultStrengthRatio=.65}},Setup={Difficulties={
    {aiAggression=.85},{aiAggression=1},{aiAggression=1.10},{aiAggression=1.22}}}}
R.AIOperations={}; R.AIHomeThreatHistory={}; R.StrategicThreatSnapshot={}
R.events={}
function R:EmitAIEvent(name,data,now) self.events[#self.events+1]={name=name,data=data,now=now} end
function R:GetFactionKey(s) return s.faction end
function R:AreEnemies(a,b) return a.team ~= b.team end
function R:GetShipRole(s) return s.role or 'capital' end
function R:IsStaticDefense(s) return s.static == true end
function R:IsCommandStation(s) return s.station==true end
function R:IsCapitalTarget(s) return s.capital == true end
function R:AIProfile(s) return {value=s.value or 100,range=s.range or 100} end
function R:IsFiniteVector(v) return v and v.x==v.x and v.y==v.y and v.z==v.z end
function R:ClampCommandPoint(v) return v end
function R:GetShipFormationRadius() return 100 end
function R:GetOrCreateMoveWaypoint(ship)
  local w={valid=true,signature=10000+ship.signature,Position=ba.createVector(0,0,0)}
  function w:isValid() return self.valid end
  function w:getSignature() return self.signature end
  self.MoveWaypoints=self.MoveWaypoints or {}; self.MoveWaypoints[ship.signature]={waypoint=w}
  return w
end
local function ship(id,team,x,z,role)
  local s={signature=id,team=team,faction=team,role=role,Position=ba.createVector(x or 0,0,z or 0),
    Radius=100,HitpointsLeft=100,Physics={VelocityMax={z=100}},value=100,Orders={}}
  function s:getSignature() return self.signature end
  function s:isValid() return self.valid ~= false end
  function s:clearOrders() self.cleared=(self.cleared or 0)+1; self.Orders={} end
  function s:giveOrder(order,target,subsystem,priority)
    self.given={order=order,target=target,subsystem=subsystem,priority=priority}; return true
  end
  return s
end
function makeShip(...) return ship(...) end
function makeTarget(id,team,x,z,role)
  local s=ship(id,team,x,z,role); s.capital=true; s.Class={Name='Capital'}
  function s:getDistance(other) return self.Position:getDistance(other.Position) end
  return s
end
function makeGroup(id,primary,role,x,z,value)
  local s=ship(id,'BLUE',x or 0,z or 0,role)
  return {id=id,primary=primary,armed=true,defending=false,screen=false,role=role,
    value=value or 100,units={s}}
end
function makeHome(x,z)
  local h=ship(900,'BLUE',x or 0,z or 0,'capital'); h.Radius=500
  return h
end
require 'fs2rts_strategy'
'''


class OperationTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(FIXTURE)

    def check(self, code):
        self.lua.execute(code)

    def test_difficulty_scales_assault_commitment(self):
        self.check("""
          local expected={.65/.85,.65,.65/1.10,.65/1.22}
          for index,value in ipairs(expected) do
            R.SetupDifficultyIndex=index
            assert(math.abs(R:GetAIAssaultStrengthRatio()-value)<.000001)
          end
        """)

    def test_assemble_waits_then_launches_at_deadline_and_releases_reserve(self):
        self.check("""
          local target=makeTarget(1,'RED',10000,0); local home=makeHome(0,0)
          local bomber=makeGroup(1,target,'bomber',0,0,100)
          local escort=makeGroup(2,target,'fighter',0,0,100)
          local reserve=makeGroup(3,target,'fighter',0,0,100)
          local reserve2=makeGroup(4,target,'fighter',0,0,100)
          local groups={bomber,escort,reserve,reserve2}
          local defender=makeShip(5,'RED',10000,100); defender.value=10
          R.StrategicThreatSnapshot={{ship=defender,profile={value=10}}}
          R:BuildAIOperations('BLUE',groups,home,0,0)
          local op=R.AIOperations.BLUE[1]; assert(op.phase=='ASSEMBLE' and op.serial==0)
          R:BuildAIOperations('BLUE',groups,home,9.99,0); assert(op.phase=='ASSEMBLE')
          R:BuildAIOperations('BLUE',groups,home,10,0)
          assert(op.phase=='APPROACH' and op.serial==1 and op.launchedAt==10 and op.reserveId,
            tostring(op.phase)..' serial '..tostring(op.serial)..' launched '..tostring(op.launchedAt)..' reserve '..tostring(op.reserveId))
          for _,g in ipairs(groups) do g.units[1].Position=target.Position end
          R:BuildAIOperations('BLUE',groups,home,11,0); assert(op.phase=='ENGAGE')
          R:BuildAIOperations('BLUE',groups,home,22.99,0)
          assert(op.phase=='ENGAGE' and not op.reserveReleased)
          R:BuildAIOperations('BLUE',groups,home,23,0)
          assert(op.reserveReleased)
        """)

    def test_operation_tracks_replacements_and_drops_dead_target(self):
        self.check("""
          local target=makeTarget(11,'RED',0,0); local home=makeHome()
          local g=makeGroup(1,target,'bomber',0,0,100)
          R:BuildAIOperations('BLUE',{g},home,0,0); local op=R.AIOperations.BLUE[11]
          R:BuildAIOperations('BLUE',{g},home,10,0); assert(op.serial==1)
          local replacement=makeGroup(2,target,'bomber',0,0,100)
          R:BuildAIOperations('BLUE',{replacement},home,11,0)
          assert(replacement.operation==op and op.serial==1,'replacement restarted operation')
          target.HitpointsLeft=0
          R:BuildAIOperations('BLUE',{replacement},home,12,0)
          assert(R.AIOperations.BLUE[11]==nil and replacement.operation==nil)
        """)

    def test_station_emergency_pauses_operation_withdrawal(self):
        self.check("""
          R.Config.AI.Operations.AttackSeconds=10
          local target=makeTarget(18,'RED',10000,0); local home=makeHome()
          local g=makeGroup(18,target,'bomber',5000,0,100); g.primary=target
          local defender=makeShip(19,'RED',10000,100); defender.value=20
          R.StrategicThreatSnapshot={{ship=defender,profile={value=20}}}
          local op={kind='BLUE',front=18,serial=1,phase='ENGAGE',phaseAt=0,engagedAt=0,lastUpdate=0,
            target=target,groups={g},anchor=g,value=100,initialValue=100,strikes=1,initialStrikes=1,
            initialDefense=20,defenders={defender}}
          R.AIOperations.BLUE=R.AIOperations.BLUE or {}; R.AIOperations.BLUE[18]=op
          R:BuildAIOperations('BLUE',{g},home,11,0,true)
          assert(op.phase=='ENGAGE' and op.engagedAt==11,
            'operation withdrew on its timer during an active home-base emergency')
          R:BuildAIOperations('BLUE',{g},home,22,0,true)
          assert(op.phase=='ENGAGE' and op.engagedAt==22,
            'home emergency did not keep extending the offensive commitment')
          R:BuildAIOperations('BLUE',{g},home,33,0,false)
          assert(op.phase=='WITHDRAW','normal operation withdrawal did not resume after the emergency')
        """)

    def test_temporary_force_gap_preserves_and_pauses_the_operation(self):
        self.check("""
          local target=makeTarget(12,'RED',10000,0); local home=makeHome()
          local g=makeGroup(1,target,'bomber',5000,0,100)
          R:BuildAIOperations('BLUE',{g},home,0,0)
          R:BuildAIOperations('BLUE',{g},home,10,0)
          local op=R.AIOperations.BLUE[12]
          assert(op.phase=='APPROACH' and op.serial==1)
          R:BuildAIOperations('BLUE',{},home,11,0)
          assert(R.AIOperations.BLUE[12]==op and op.phase=='APPROACH' and op.missingSince==11)
          R:BuildAIOperations('BLUE',{},home,20,0)
          assert(R.AIOperations.BLUE[12]==op,'operation ended before its force grace')
          local replacement=makeGroup(2,target,'bomber',0,0,100)
          R:BuildAIOperations('BLUE',{},home,500,0)
          assert(R.AIOperations.BLUE[12]==op,'operation expired while its surviving force was recovering')
          R:BuildAIOperations('BLUE',{replacement},home,501,0)
          assert(R.AIOperations.BLUE[12]==op and replacement.operation==op)
          assert(op.serial==1 and op.phaseAt==500 and op.missingSince==nil,
            'operation phase/deadline did not pause across recovery')
          replacement.primary=nil
          target.HitpointsLeft=0
          R:BuildAIOperations('BLUE',{},home,502,0)
          assert(R.AIOperations.BLUE[12]==nil,'operation survived its destroyed target')
        """)

    def test_withdraw_exploit_recovery_and_counterattack_window(self):
        self.check("""
          local target=makeTarget(21,'RED',7000,0); local defender=makeShip(22,'RED',7000,200)
          R.StrategicThreatSnapshot={{ship=defender,profile={value=500}}}
          local home=makeHome(); local bomber=makeGroup(1,target,'bomber',0,0,100)
          local fighter=makeGroup(2,target,'fighter',0,0,100)
          R:BuildAIOperations('BLUE',{bomber,fighter},home,0,10)
          local op=R.AIOperations.BLUE[21]
          R:BuildAIOperations('BLUE',{bomber,fighter},home,10,10); assert(op.phase=='APPROACH')
          bomber.units[1].Position=ba.createVector(7000,0,0); fighter.units[1].Position=ba.createVector(7000,0,0)
          R:BuildAIOperations('BLUE',{bomber,fighter},home,11,10); assert(op.phase=='ENGAGE')
          R.StrategicThreatSnapshot={}
          R:BuildAIOperations('BLUE',{bomber,fighter},home,12,0); assert(op.phase=='EXPLOIT')
          local ctx={}; local t,m=R:ApplyAIOperationOrder(bomber,target,'PRIMARY',ctx,home,12,{})
          assert(t==target and m=='PRIMARY' and ctx.reason=='BREAKTHROUGH_EXPLOIT')
          bomber.value=1; fighter.value=1
          R.StrategicThreatSnapshot={{ship=defender,profile={value=500}}}
          R:BuildAIOperations('BLUE',{bomber,fighter},home,13,0); assert(op.phase=='WITHDRAW')
          local rt,rm=R:ApplyAIOperationOrder(bomber,target,'PRIMARY',{},home,13,{})
          assert(rt==home and rm=='RETREAT')
          R.StrategicThreatSnapshot={}; R:BuildAIOperations('BLUE',{bomber,fighter},home,18,0)
          assert(op.phase=='ASSEMBLE')
          R.AIHomeThreatHistory.BLUE=100
          R:BuildAIOperations('BLUE',{bomber,fighter},home,19,0)
          assert(op.phase=='APPROACH' and op.serial==2)
          local found=false; for _,e in ipairs(R.events) do
            if e.name=='OPERATION' and e.data.reason=='COUNTERATTACK_WINDOW' then found=true end
          end
          assert(found,'defeated raid did not trigger counterattack launch')
        """)

    def test_flank_and_reserve_require_suitable_force_and_defense(self):
        self.check("""
          local target=makeTarget(31,'RED',10000,0); local home=makeHome()
          local d=makeShip(32,'RED',10000,200); d.value=500
          R.StrategicThreatSnapshot={{ship=d,profile={value=500}}}
          local b1=makeGroup(1,target,'bomber',0,0,100); local b2=makeGroup(2,target,'bomber',0,0,100)
          local f1=makeGroup(3,target,'fighter',0,0,100); local f2=makeGroup(4,target,'fighter',0,0,100)
          R:BuildAIOperations('BLUE',{b1,b2,f1,f2},home,0,0)
          local op=R.AIOperations.BLUE[31]
          R:BuildAIOperations('BLUE',{b1,b2,f1,f2},home,10,0)
          assert(op.flankId~=nil and op.reserveId~=nil)
          local flank=(b1.id==op.flankId and b1) or b2
          local ctx={}; local _,mission=R:ApplyAIOperationOrder(flank,target,'PRIMARY',ctx,home,11,{})
          assert(mission=='REGROUP' and ctx.reason=='PIN_AND_FLANK' and ctx.destination==op.flankPoint)
          flank.units[1].Position=op.flankPoint
          ctx={}; local _,rejoined=R:ApplyAIOperationOrder(flank,target,'PRIMARY',ctx,home,12,{})
          assert(op.flankDone and rejoined=='ESCORT' and ctx.reason=='COORDINATED_APPROACH',
            'completed flank did not release to the assault anchor')
          local controlTarget=makeTarget(33,'RED',-10000,0)
          local controlDefender=makeShip(34,'RED',-10000,200); controlDefender.value=500
          R.StrategicThreatSnapshot={{ship=controlDefender,profile={value=500}}}
          local controlBomber=makeGroup(5,controlTarget,'bomber',0,0,100)
          local controlScreen=makeGroup(6,controlTarget,'fighter',0,0,100)
          R:BuildAIOperations('GOLD',{controlBomber,controlScreen},makeHome(-10000,0),0,0)
          local small=R.AIOperations.GOLD[33]
          R:BuildAIOperations('GOLD',{controlBomber,controlScreen},makeHome(-10000,0),10,0)
          assert(small.phase=='APPROACH' and small.strikes==1 and small.screens==1
            and small.defense>0 and small.flankId==nil,'one-strike defended control incorrectly flanked')
          local controlContext={}; local controlTargetOrder,controlMission=R:ApplyAIOperationOrder(
            controlBomber,controlTarget,'PRIMARY',controlContext,makeHome(-10000,0),11,{})
          assert(controlTargetOrder==controlTarget and controlMission=='PRIMARY'
            and controlContext.reason=='OPERATION_ROLE_TARGET','control did not retain normal primary order')
          controlContext={}; local _,escortMission=R:ApplyAIOperationOrder(
            controlScreen,controlTarget,'PRIMARY',controlContext,makeHome(-10000,0),11,{})
          assert(escortMission=='ESCORT' and controlContext.reason=='COORDINATED_APPROACH',
            'control screen did not keep normal coordinated escort order')
        """)

    def test_screen_group_skips_non_bomber_without_passing_false_as_ship(self):
        self.check("""
          local primary=makeTarget(35,'RED',10000,0)
          local attacker=makeShip(36,'RED',5000,0,'bomber')
          local screen=makeGroup(1,primary,'fighter',0,0,100)
          local op={phase='ENGAGE',target=primary,defenders={primary},groups={
            {role='fighter'}, {role='bomber',targetedBy=attacker}}}
          assert(R:ChooseAIOperationTarget(op,screen,{})==attacker,
            'screen failed to intercept a nearby bomber targeting a bomber wing')
        """)

    def test_strike_group_does_not_detour_to_out_of_range_sentry(self):
        self.check("""
          local station=makeTarget(37,'RED',18000,0)
          local sentry=makeShip(38,'RED',15000,0,'fighter'); sentry.static=true; sentry.Radius=100
          local striker=makeGroup(39,station,'juggernaut',0,0,1000)
          local op={phase='ENGAGE',target=station,defenders={sentry},groups={striker}}
          assert(R:ChooseAIOperationTarget(op,striker,{})==station,
            'distant fixed defense diverted the capital strike from the station')
          sentry.Position=ba.createVector(100,0,0)
          assert(R:ChooseAIOperationTarget(op,striker,{})==sentry,
            'nearby fixed defense was not selected when the striker could engage it')
        """)

    def test_capital_siege_targets_station_turrets_instead_of_ramming_hull(self):
        self.check("""
          local station=makeTarget(53,'RED',1000,0); station.station=true
          local function turret(damage,hp)
            local weapon={Damage=damage,FireWait=1,isValid=function() return true end}
            return {HitpointsMax=100,HitpointsLeft=hp,Targetable=true,TurretLocked=false,PrimaryBanks={{WeaponClass=weapon,AmmoMax=0,isValid=function() return true end}},
              SecondaryBanks={},isTurret=function() return true end,isValid=function() return true end}
          end
          station[1]=turret(50,100); station[2]=turret(30,40)
          local group=makeGroup(54,station,'juggernaut',0,0,500)
          group.units[1].Position=station.Position
          local op={phase='ENGAGE',target=station,serial=1,defenders={},groups={group},strikes=1,screens=0}
          group.operation=op
          local ctx={}; local target,mission=R:ApplyAIOperationOrder(group,station,'PRIMARY',ctx,makeHome(),1,{})
          assert(target==station and mission=='PRIMARY' and ctx.subsystem==station[2] and ctx.subsystemIndex==2,
            'siege capital did not suppress the most dangerous vulnerable turret')
          local second=makeGroup(55,station,'heavy',0,0,500); second.operation=op; op.groups={group,second}
          second.units[1].Position=station.Position
          local ctx2={}; R:ApplyAIOperationOrder(second,station,'PRIMARY',ctx2,makeHome(),2,{})
          assert(ctx2.subsystemIndex==nil,'one operation assigned multiple groups to the same turret suppression task')
        """)

    def test_capital_siege_skips_turret_banks_without_weapon_classes(self):
        self.check("""
          local station=makeTarget(56,'RED',10000,0); station.station=true
          local invalidBank=setmetatable({}, {__index=function(_,key)
            if key=='isValid' then return function() return false end end
            error('read from invalid turret bank: '..tostring(key))
          end})
          station[1]={HitpointsMax=100,HitpointsLeft=100,Targetable=true,TurretLocked=false,
            PrimaryBanks={invalidBank},SecondaryBanks={},
            isTurret=function() return true end,isValid=function() return true end}
          station[2]={HitpointsMax=100,HitpointsLeft=100,Targetable=true,TurretLocked=false,
            PrimaryBanks={{WeaponClass={Damage=20,FireWait=1,isValid=function() return true end},AmmoMax=0,isValid=function() return true end}},
            SecondaryBanks={},isTurret=function() return true end,isValid=function() return true end}
          local group=makeGroup(57,station,'juggernaut',0,0,500)
          group.units[1].Position=station.Position
          local op={phase='ENGAGE',target=station,serial=1,defenders={},groups={group},strikes=1,screens=0}
          group.operation=op
          local ctx={}; R:ApplyAIOperationOrder(group,station,'PRIMARY',ctx,makeHome(),1,{})
          assert(ctx.subsystem==station[2] and ctx.subsystemIndex==2,
            'an invalid weapon bank crashed or hid the usable siege turret')
        """)

    def test_suppression_chooses_live_dangerous_turret_once(self):
        self.check("""
          local target=makeTarget(41,'RED',1000,0); target.capital=true
          local function turret(hp,damage,locked)
            local w={Damage=damage,FireWait=1,isValid=function() return true end}
            local bank={WeaponClass=w,AmmoMax=0,isValid=function() return true end}
            return {HitpointsMax=100,HitpointsLeft=hp,TurretLocked=locked,PrimaryBanks={bank},SecondaryBanks={},
              isValid=function(s) return s.valid~=false end,isTurret=function() return true end}
          end
          target[1]=turret(20,50,false); target[2]=turret(0,100,false)
          local attacker=makeShip(40,'BLUE',0,0,'bomber'); attacker.range=100
          local op={}
          assert(R:GetAISuppressionSubsystem(op,target,5,attacker)==target[1])
          assert(op.suppressionTarget==41 and op.suppressionUntil==75,
            'deadline must include estimated travel plus firing grace')
          assert(R:GetAISuppressionSubsystem(op,target,74.99,attacker)==target[1],
            'live turret lost its suppression order before the travel-aware deadline')
          assert(R:GetAISuppressionSubsystem(op,target,75,attacker)==nil,'expired suppression stayed active')
          assert(R:GetAISuppressionSubsystem(op,target,75,attacker)==nil,'spent suppression was retried')
          local destroyed={suppressionTarget=41,suppressionIndex=1,suppressionUntil=100}
          target[1].HitpointsLeft=0
          assert(R:GetAISuppressionSubsystem(destroyed,target,6,attacker)==nil,'destroyed turret was retained')
          local other=makeTarget(42,'RED',1000,0); other[1]=turret(20,50,false)
          local bound={suppressionTarget=41,suppressionIndex=1,suppressionUntil=100}
          assert(R:GetAISuppressionSubsystem(bound,other,6,attacker)==nil,'suppression crossed target identity')
        """)

    def test_suppression_window_caps_long_approaches(self):
        self.check("""
          local target=makeTarget(43,'RED',10000,0)
          target[1]={HitpointsMax=100,HitpointsLeft=100,WorldPosition=ba.createVector(10000,0,0),
            TurretLocked=false,Targetable=true,PrimaryBanks={{WeaponClass={Damage=10,FireWait=1,
              isValid=function() return true end},AmmoMax=0,isValid=function() return true end}},
            SecondaryBanks={},isValid=function() return true end,isTurret=function() return true end}
          local attacker=makeShip(44,'BLUE',0,0,'bomber'); attacker.range=0
          local op={}
          assert(R:GetAISuppressionSubsystem(op,target,10,attacker)==target[1])
          assert(op.suppressionUntil==100,'travel-aware deadline must honor the hard cap')
        """)

    def test_commander_rechecks_suppression_until_deadline_then_releases_it(self):
        self.check("""
          local target=makeTarget(45,'RED',1000,0); target[1]={HitpointsMax=100,HitpointsLeft=100,
            WorldPosition=ba.createVector(1000,0,0),TurretLocked=false,Targetable=true,
            PrimaryBanks={{WeaponClass={Damage=10,FireWait=1,isValid=function() return true end},
              AmmoMax=0,isValid=function() return true end}},SecondaryBanks={},
            isValid=function() return true end,isTurret=function() return true end}
          local attacker=makeGroup(46,target,'bomber',0,0,100); attacker.units[1].range=100
          local op={phase='ENGAGE',target=target,serial=1,strikes=2,defenders={},groups={attacker}}
          attacker.operation=op
          local home=makeHome()
          for _,now in ipairs({0,25,50,69.99}) do
            local context={}; local selected,mission=R:ApplyAIOperationOrder(attacker,target,'PRIMARY',context,home,now,{})
            assert(selected==target and mission=='PRIMARY' and context.subsystem==target[1],
              'commander re-evaluation dropped a live in-window suppression order at '..now)
          end
          local deadline=op.suppressionUntil
          assert(deadline==70)
          local context={}; local selected,mission=R:ApplyAIOperationOrder(attacker,target,'PRIMARY',context,home,deadline,{})
          assert(selected==target and mission=='PRIMARY' and context.subsystem==nil
            and context.reason=='OPERATION_ROLE_TARGET','commander did not release suppression at expiry')
          assert(op.suppressionSpent,'expired target was not marked spent')
        """)

    def test_suppression_unsuitable_and_expired_enabling_situation(self):
        self.check("""
          local target=makeTarget(47,'RED',1000,0)
          local invalid={HitpointsMax=100,HitpointsLeft=100,WorldPosition=target.Position,
            TurretLocked=true,Targetable=false,PrimaryBanks={},SecondaryBanks={},
            isValid=function() return true end,isTurret=function() return true end}
          target[1]=invalid
          local attacker=makeGroup(48,target,'bomber',0,0,100); attacker.units[1].range=100
          local op={phase='ENGAGE',target=target,serial=1,strikes=2,defenders={},groups={attacker}}
          attacker.operation=op
          local context={}; local selected,mission=R:ApplyAIOperationOrder(attacker,target,'PRIMARY',context,makeHome(),0,{})
          assert(selected==target and mission=='PRIMARY' and context.subsystem==nil
            and op.suppressionUntil==nil,'unsuitable turret gained suppression')
          local validTurret={HitpointsMax=100,HitpointsLeft=100,WorldPosition=target.Position,
            TurretLocked=false,Targetable=true,PrimaryBanks={{WeaponClass={Damage=10,FireWait=1,
              isValid=function() return true end},AmmoMax=0,isValid=function() return true end}},
            SecondaryBanks={},isValid=function() return true end,isTurret=function() return true end}
          target[1]=validTurret
          context={}; R:ApplyAIOperationOrder(attacker,target,'PRIMARY',context,makeHome(),1,{})
          assert(context.subsystem==validTurret)
          op.phase='EXPLOIT'
          context={}; R:ApplyAIOperationOrder(attacker,target,'PRIMARY',context,makeHome(),2,{})
          assert(context.subsystem==nil and context.reason=='BREAKTHROUGH_EXPLOIT',
            'suppression continued after the operation left ENGAGE')
        """)

    def test_defense_manual_and_immediate_orders_keep_priority(self):
        self.check("""
          local target=makeTarget(51,'RED',1000,0); local home=makeHome()
          local g=makeGroup(1,target,'bomber',0,0,100); g.operation={target=target,phase='WITHDRAW',serial=1}
          g.defending=true
          local ctx={}; local t,m=R:ApplyAIOperationOrder(g,target,'PRIMARY',ctx,home,1,{})
          assert(t==target and m=='PRIMARY' and ctx.reason==nil,'operation overrode defense priority')
          g.defending=false; g.hardLocalThreat=true
          t,m=R:ApplyAIOperationOrder(g,target,'INTERCEPT',{},home,1,{})
          assert(t==target and m=='INTERCEPT','operation overrode immediate survival order')
        """)


if __name__ == '__main__':
    unittest.main()
