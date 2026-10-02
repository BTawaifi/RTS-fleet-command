"""Guards for the two anti-fragmentation / anti-churn flags added to the planner.

Both flags ship OFF, so the first guard in each pair asserts that the default
path is byte-for-byte the pre-existing behaviour; the second asserts the fix
actually does what it claims. A guard that cannot go red is decoration.

Run with the repository's existing Python executable:
    cd core/tools && python -m pytest test_ai_concentration.py -q
"""
import os
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

# RTS_SCRIPTS_OVERRIDE lets the kill-check harness point this module at a mutated
# COPY of the scripts directory, so a guard can be proven to go red by breaking
# the source without ever editing the tree under test.
SCRIPTS = Path(os.environ.get('RTS_SCRIPTS_OVERRIDE')
               or (Path(__file__).resolve().parents[1] / 'data/scripts'))

FIXTURE = r'''
local Vec = {}; Vec.__index = Vec
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
  return x.valid ~= false
end
package.preload.fs2rts_state = function() return R end
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
R = {}
Config = require 'fs2rts_config'
R.Config = Config
require 'fs2rts_strategy'
-- fs2rts_ai_planning returns an installer function taking the RTS table, it does
-- not attach itself, so it has to be invoked the way the mod invokes it.
require 'fs2rts_ai_planning'(R)
R.AIObservations={}; R.AIOrderState={}
R.CombatTelemetryEnabled=false
R.Config.AI.DetailedDecisionTelemetry=false

-- ship/group doubles. Group doubles carry only the fields the pooling pass
-- reads; every other field is deliberately absent so an unexpected read fails
-- loudly instead of silently returning nil and passing an assertion.
function ship(id,x,z,value)
  local s={signature=id,Position=ba.createVector(x or 0,0,z or 0),HitpointsLeft=100,valid=true,
    carry=100,loaded=100,Physics={VelocityMax={z=100}}}
  function s:getSignature() return self.signature end
  function s:isValid() return self.valid ~= false end
  function s:isDying() return false end
  s.value=value or 100
  return s
end
gseq=0
function group(id,role,mission,centroidX,value,primary)
  gseq=gseq+1
  local base=gseq*100
  local units={ship(base+1,centroidX-200,0,100),ship(base+2,centroidX+200,0,100)}
  return {id=id,role=role,mission=mission,value=value or 100,units=units,
    primary=primary or ship(99999,0,0,100),screen=false,committed=false,assaultReserved=false,
    armed=true,ordnance=100,ordnanceLoaded=100,spread=0}
end
function groupCount(list) return #list end
function assertNo(c,msg) assert(not c,msg) end
function assertEq(a,b,msg) assert(a==b,(msg or 'mismatch')..' expected '..tostring(b)..' got '..tostring(a)) end
-- The real GetShipOrdnance walks a mount list these doubles do not carry. It is
-- covered by its own tests; here it only has to let the pooling pass re-derive
-- a merged group's minimum ordnance without reaching into the engine.
function R:GetShipOrdnance(s) return 100,100 end
'''


class ConcentrationGuardTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(FIXTURE)

    def check(self, code):
        self.lua.execute(code)

    # -- shipped defaults ----------------------------------------------------

    def test_both_flags_ship_off(self):
        """Kill-check: turns red if either default is flipped, which would
        silently change shipped behaviour instead of leaving it behind a flag."""
        self.check("""
          local d=Config.AI.Doctrine
          assert(d.PoolAssaultGroupsEnabled==false,
            'PoolAssaultGroupsEnabled must ship false; got '..tostring(d.PoolAssaultGroupsEnabled))
          assert(d.PoolAssaultGroupsRadius==3000,
            'PoolAssaultGroupsRadius default moved: '..tostring(d.PoolAssaultGroupsRadius))
          assert(d.OperationCommitmentEnabled==false,
            'OperationCommitmentEnabled must ship false; got '..tostring(d.OperationCommitmentEnabled))
          assert(d.OperationCommitmentSeconds==24,
            'OperationCommitmentSeconds default moved: '..tostring(d.OperationCommitmentSeconds))
          -- the fragile capital-investment block must be untouched by this work
          assert(Config.Station.AI.CapitalAwareInvestment==false,
            'CapitalAwareInvestment must still ship false')
          assert(Config.AI.BoundBankTarget==false,'BoundBankTarget must still ship false')
          assert(Config.AI.PreserveSavingClockWhileFielding==false,
            'PreserveSavingClockWhileFielding must still ship false')
          assert(Config.AI.FieldCheapHullWhileSaving==false,
            'FieldCheapHullWhileSaving must still ship false')
        """)

    # -- pooling -------------------------------------------------------------

    def test_pooling_is_a_no_op_while_the_flag_is_off(self):
        """Kill-check: red if PoolAIAssaultGroups merges anything at the shipped
        default, which would be an unflagged behaviour change."""
        self.check("""
          local g1=group('W1','fighter','PRIMARY',0,100)
          local g2=group('W2','fighter','PRIMARY',300,100)
          local input={g1,g2}
          local out=R:PoolAIAssaultGroups(input)
          assert(out==input,'pooling must return the input table untouched while disabled')
          assertEq(groupCount(out),2,'group count changed while pooling was disabled')
          assertEq(#g1.units,2,'a group was absorbed while pooling was disabled')
        """)

    def test_pooling_folds_co_located_same_intent_groups(self):
        """Kill-check: red if the merge logic stops merging, or if it merges on
        anything weaker than role+mission+front+proximity."""
        self.check("""
          R.Config.AI.Doctrine.PoolAssaultGroupsEnabled=true
          local primary=ship(99999,0,0,100)
          local g1=group('W1','fighter','PRIMARY',0,100,primary)
          local g2=group('W2','fighter','PRIMARY',400,150,primary)
          local g3=group('W3','fighter','PRIMARY',800,120,primary)
          local out=R:PoolAIAssaultGroups({g1,g2,g3})
          assertEq(groupCount(out),1,'three co-located same-intent wings did not fold into one group')
          assertEq(#out[1].units,6,'merged group did not absorb every hull')
          assertEq(out[1].value,370,'merged value is wrong: '..tostring(out[1].value))
          assert(out[1].spread>0,'merged spread was not re-derived, so FORMATION_RECOVERY would misfire')
        """)

    def test_pooling_refuses_every_unsafe_merge(self):
        """Kill-check: red if pooling ever merges across a mission, a front, a
        role, a distance, or an existing intent - each of those would redirect a
        wing that had already been given its own job."""
        self.check("""
          R.Config.AI.Doctrine.PoolAssaultGroupsEnabled=true
          local p1=ship(99999,0,0,100); local p2=ship(99998,50000,0,100)

          local base=group('W1','fighter','PRIMARY',0,100,p1)
          local otherMission=group('W2','fighter','SCREEN',300,100,p1)
          local otherFront=group('W3','fighter','PRIMARY',300,100,p2)
          local otherRole=group('W4','bomber','PRIMARY',300,100,p1)
          local farAway=group('W5','fighter','PRIMARY',9000,100,p1)
          local defending=group('W6','fighter','PRIMARY',300,100,p1); defending.defending=true
          local luring=group('W7','fighter','PRIMARY',300,100,p1); luring.luring=true
          local feinting=group('W8','fighter','PRIMARY',300,100,p1); feinting.feint=true
          local hasTarget=group('W9','fighter','PRIMARY',300,100,p1); hasTarget.target=ship(5,0,0,10)
          local reserved=group('WA','fighter','PRIMARY',300,100,p1); reserved.assaultReserved=true
          local suppressed=group('WB','fighter','PRIMARY',300,100,p1); suppressed.capitalSuppression=true
          local homeguard=group('WC','fighter','PRIMARY',300,100,p1); homeguard.homeguard=true
          local bomberEscort=group('WD','fighter','PRIMARY',300,100,p1); bomberEscort.escortBomber=true

          for _,pair in ipairs({{base,otherMission,'different mission'},{base,otherFront,'different front'},
            {base,otherRole,'different role'},{base,farAway,'out of radius'},{base,defending,'a defender'},
            {base,luring,'a lure'},{base,feinting,'a feint'},{base,hasTarget,'a group that already has a target'},
            {base,reserved,'an assault-reserved group'},{base,suppressed,'a suppression wing'},
            {base,homeguard,'a homeguard wing'},{base,bomberEscort,'a bomber escort'}}) do
            local host=pair[1]; local other=pair[2]; local why=pair[3]
            local out=R:PoolAIAssaultGroups({host,other})
            local n=groupCount(out)
            assert(n==2 and #host.units==2,
              'pooling merged across '..why..' (groups='..n..' hostUnits='..#host.units..')')
          end
        """)

    def test_pooling_never_creates_a_group_over_regroup_distance(self):
        """Kill-check: red if the merge ever accepts a pair whose hulls sit
        further apart than RegroupDistance. Such a group trips FORMATION_RECOVERY
        on its very next tick and churns forever, so pooling it would be worse
        than leaving the wings separate."""
        self.check("""
          R.Config.AI.Doctrine.PoolAssaultGroupsEnabled=true
          R.Config.AI.Doctrine.PoolAssaultGroupsRadius=3000
          R.Config.AI.Doctrine.RegroupDistance=2600
          local primary=ship(99999,0,0,100)
          -- Hulls 3300 apart (centroids 2900 apart, inside the radius). The
          -- centroid distance is deliberately NOT the admissibility test: the
          -- widest hull-to-hull distance is, because spread is a hull-to-hull
          -- measure and the outermost ships of the two wings are what matter.
          local a=group('W1','fighter','PRIMARY',0,100,primary)
          local b=group('W2','fighter','PRIMARY',2900,100,primary)
          local out=R:PoolAIAssaultGroups({a,b})
          assertEq(groupCount(out),2,
            'pooling merged two wings whose hulls are further apart than RegroupDistance')
          -- Pulled inside the limit, the same pair folds and the merged spread is
          -- reported truthfully rather than left at zero.
          local c=group('W3','fighter','PRIMARY',0,100,primary)
          local d=group('W4','fighter','PRIMARY',1000,100,primary)
          out=R:PoolAIAssaultGroups({c,d})
          assertEq(groupCount(out),1,'a safe pair should still fold')
          assertEq(out[1].spread,1400,'merged spread is wrong: '..tostring(out[1].spread))
          assert(out[1].spread<=R.Config.AI.Doctrine.RegroupDistance,
            'merged spread '..tostring(out[1].spread)..' exceeds RegroupDistance')
        """)

    # -- operation membership commitment -------------------------------------

    def _commit_fixture(self):
        """Builds the minimum CommitAIGroup needs to exercise the retention gate."""
        self.check("""
          R.AIOrderState={}
          R.AIObservations={}
          R.CombatTelemetryEnabled=false
          R.ScenarioStartTime=0
          R.GetFactionKey=function(self,s) return 'BLUE' end
          R.AreEnemies=function(self,a,b) return a.team~=b.team end
          R.IsCommandStation=function(self,s) return s.station==true end
          R.IsStaticDefense=function(self,s) return s.static==true end
          R.IsAutomaticAIUnit=function(self,s) return true end
          R.FindShipBySignature=function(self,s)
            for _,s2 in pairs(R.world or {}) do if s2:getSignature()==s then return s2 end end
            return nil
          end
          R.EmitAIEvent=function() end
          R.AIStats={retained=0,decisions=0,switches=0,reissued=0,nativeChanges=0}
          R.RecordAIOrderTelemetry=function() end
          R.IsFiniteVector=function(v) return v~=nil end
          function R:AIProfile(s)
            return {value=s.value or 100,range=s.range or 5000,armed=true,speed=s.speed or 100}
          end
          function R:GetShipFormationRadius() return 50 end
          function R:GetShipOrdnance(s) return 100,100 end
          R.AILocalStrength=function() return 0,0 end
          R.BuildSafeFormationDestinations=function() return {} end
          R.ChooseAIFormation=function() return 'WEDGE' end
          R.HealthOf=function(s) return (tonumber(s.HitpointsLeft) or 0) end
          R.GetShipRole=function(self,s) return s.role or 'capital' end
          R.FindAIGroupTargeter=function() return nil end
          R.ChooseAILocalThreat=function() return nil end
          R.ObserveAIUnit=function() end
          R.UpdateAIPursuitGoals=function() end
          R.CombatTelemetryEnabled=false
          mn={getMissionTime=function() return 0 end}
          R.FlushAITrace=function() end
          R.CombatDamageTelemetry={intervalByFaction={},totalByFaction={}}
          R.BaseDamageTelemetry={intervalByFaction={}}

          R.world={}
          function mk(id,team,station)
            local s={signature=id,team=team,HitpointsLeft=100,HitpointsMax=100,valid=true,Radius=250,
              Name=station and 'Enemy Station' or 'Enemy Hull',
              Position=ba.createVector(0,0,0),Class={Name='Fighter'},value=100,speed=100}
            function s:getSignature() return self.signature end
            function s:isValid() return self.valid ~= false end
            function s:isDying() return false end
            function s:clearOrders() self.Orders={} end
            function s:giveOrder(o,target) self.lastOrder=o; self.orderTarget=target; return true end
            function s:getDistance(other) return self.Position:getDistance(other.Position) end
            s.station=station==true
            R.world[id]=s
            return s
          end
          function mkGroup(lead,role)
            return {id=role..':'..lead:getSignature(),role=role,units={lead},value=100,
              candidates=nil,assaultReserved=false,screen=false,spread=0}
          end
        """)

    def test_operation_commitment_ships_off_and_then_holds_a_committed_target(self):
        """Kill-check: red in three separate ways. If the default flips, the
        default-off half goes red. If the exemption stops applying to an
        operation member, the hold half goes red. If it leaks past its own scope,
        the mission-change half goes red."""
        self._commit_fixture()
        self.check("""
          local defender=mk(200,'RED')
          local alternate=mk(201,'RED')
          local station=mk(300,'RED',true)
          local lead=mk(100,'BLUE')

          local g=mkGroup(lead,'bomber')
          -- The shape ApplyAIOperationOrder actually hands CommitAIGroup for an
          -- operation member that keeps its mission within a phase.
          local function opctx() return {assaultPrimarySignature=station:getSignature(),
            posture='OFFENSIVE',operation=7,operationPhase='ENGAGE',locked=true} end
          local context=opctx()
          local function install(mission,target,assignedAt)
            R.AIOrderState[lead:getSignature()]={mission=mission,targetSignature=target:getSignature(),
              assignedAt=assignedAt,assaultStartedAt=assignedAt}
          end

          -- 1. shipped default: context.locked wins, so the operation re-picks and
          --    MinimumCommitmentSeconds never runs. This is the behaviour the flag
          --    exists to change, so it is the regression baseline.
          assert(Config.AI.Doctrine.OperationCommitmentEnabled==false)
          install('PRIMARY',defender,1000)
          g=mkGroup(lead,'bomber')
          R:CommitAIGroup(g,alternate,'PRIMARY',station,opctx(),1100,nil)
          assertEq(g.target:getSignature(),alternate:getSignature(),
            'default path retained the target while operation-locked; that is not the shipped behaviour')

          -- 2. flag on, mission UNCHANGED, age well past MinimumCommitmentSeconds=8:
          --    the committed target must now be held instead of re-picked.
          R.Config.AI.Doctrine.OperationCommitmentEnabled=true
          install('PRIMARY',defender,1000)
          g=mkGroup(lead,'bomber')
          R:CommitAIGroup(g,alternate,'PRIMARY',station,opctx(),1010,nil)
          assertEq(g.target:getSignature(),defender:getSignature(),
            'operation commitment did not hold the target past the 8s minimum')
          assertEq(g.reason,'OPERATION_RETAINED','retention reason is not attributed: '..tostring(g.reason))

          -- 2b. inside the window the hold is immediate, not a 24s wait.
          install('PRIMARY',defender,1000)
          g=mkGroup(lead,'bomber')
          R:CommitAIGroup(g,alternate,'PRIMARY',station,opctx(),1002,nil)
          assertEq(g.target:getSignature(),defender:getSignature(),
            'operation commitment did not hold the target inside the window')

          -- 3. flag on but the MISSION changed: the phase machine must not be
          --    delayed, so a group moving ASSEMBLE->APPROACH is released at once.
          install('PRIMARY',defender,1000)
          g=mkGroup(lead,'bomber')
          R:CommitAIGroup(g,alternate,'ESCORT',station,opctx(),1010,nil)
          assertEq(g.target:getSignature(),alternate:getSignature(),
            'operation commitment delayed a mission change')

          -- 4. flag on, NON-operation group: context.locked still wins, so the
          --    exemption does not leak into the ordinary planner path.
          install('PRIMARY',defender,1000)
          g=mkGroup(lead,'bomber')
          R:CommitAIGroup(g,alternate,'PRIMARY',station,
            {assaultPrimarySignature=station:getSignature(),posture='OFFENSIVE',locked=true},1100,nil)
          assertEq(g.target:getSignature(),alternate:getSignature(),
            'the operation exemption leaked onto a non-operation locked group')

          -- 5. flag on, committed target is DEAD: released at once, never retained
          --    onto a destroyed hull.
          install('PRIMARY',defender,1000)
          defender.HitpointsLeft=0; defender.valid=false
          g=mkGroup(lead,'bomber')
          R:CommitAIGroup(g,alternate,'PRIMARY',station,opctx(),1010,nil)
          assertEq(g.target:getSignature(),alternate:getSignature(),
            'operation commitment retained a destroyed target')
        """)


if __name__ == "__main__":
    unittest.main()
