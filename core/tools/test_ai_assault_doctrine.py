"""Guards for the heavy assault objective lock (a capital clears a way, it does
not go hunting sentries).

Both locks ship OFF, so every guard below has a default-off half that asserts the
shipped path is untouched and an on-half that asserts the gate does what it
claims. A guard that cannot go red is decoration; each one is registered in
killcheck.py so that is checked mechanically rather than asserted here.

WHAT THE GUARDS ARE GUARDING, because the obvious reading of the defect is
wrong. The measured symptom (capgate-20261001, 2906 heavy PRIMARY decisions:
44.8% sentry, 16.4% station) is real, but the cause is not that the planner
prefers a nearby sentry on score. ChooseAIOperationTarget
(fs2rts_operations.lua:192) scores candidates as `rank*100000 - distance`, with a
static defence at rank 3 for a strike group and the operation objective - the
enemy command station - at rank 1. The 200,000 gap is unpayable by distance, so
every sentry in the defender ring outranks the station unconditionally, and
ApplyAIOperationOrder returns that value with context.locked=true from
fs2rts_strategy.lua:1422, after all local-threat logic. Hence
localThreatSignature == target occurred 0 times and hardLocalThreat was false in
100% of those records: the local threat was never consulted, not outvoted. These
guards therefore exercise a VETO on what operations returns, not a re-weighting
of the score.

Run with the repository's existing Python executable:
    cd core/tools && python -m pytest test_ai_assault_doctrine.py -q
"""
import os
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

# RTS_SCRIPTS_OVERRIDE lets the kill-check harness point this module at a mutated
# COPY of the scripts directory, exactly as test_ai_concentration.py does.
SCRIPTS = Path(os.environ.get('RTS_SCRIPTS_OVERRIDE')
               or (Path(__file__).resolve().parents[1] / 'data/scripts'))
STRATEGY = SCRIPTS / 'fs2rts_strategy.lua'

FIXTURE = r'''
local Vec = {}; Vec.__index = Vec
function Vec.__add(a,b) return ba.createVector(a.x+b.x,a.y+b.y,a.z+b.z) end
function Vec.__sub(a,b) return ba.createVector(a.x-b.x,a.y-b.y,a.z-b.z) end
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

-- The four doubles ApplyAssaultObjectiveLock actually calls. Everything else the
-- gate touches is plain data on the group/ship tables, so an unexpected engine
-- call fails loudly here instead of silently returning nil and passing.
R.AreEnemies=function(self,a,b) return a.team~=b.team end
R.IsCommandStation=function(self,s) return s.station==true end
R.IsStaticDefense=function(self,s) return s.static==true end
function assertEq(a,b,msg)
  assert(a==b,(msg or 'mismatch')..' expected '..tostring(b)..' got '..tostring(a))
end

function ship(id,x,z,team)
  local s={signature=id,team=team or 'RED',Position=ba.createVector(x or 0,0,z or 0),
    HitpointsLeft=100,valid=true,Radius=250,static=false,station=false,Name='Enemy Hull'}
  function s:getSignature() return self.signature end
  function s:isValid() return self.valid ~= false end
  function s:isDying() return false end
  return s
end
function station(id,x,z,team)
  local s=ship(id,x,z,team); s.station=true; s.Name='Enemy Station'; return s
end
function sentry(id,x,z,team)
  local s=ship(id,x,z,team); s.static=true; s.Name='Sentry'; return s
end
-- One group, one enemy command station it is supposed to be attacking, and a
-- centroid-to-station axis along +x so corridor geometry is legible.
function scenario(stationDistance)
  local st=station(900,stationDistance or 11857,0,'RED')
  local g={id='W1:capital',role='capital',units={ship(100,0,0,'BLUE')},value=100,
    assaultReserved=true,screen=false,spread=0,armed=true}
  g.operation={kind='RED',front=st:getSignature(),serial=3,phase='ENGAGE',target=st,value=100,
    strikes=1,screens=1,groups={g},defenders={}}
  return g,st
end
'''

# The measured p50 sentry diversion, from DECISION centroid/target geometry on
# capgate-20261001: the group sits 11,857 m from the station and the sentry it
# was ordered onto is 7,406 m out with a 689 m perpendicular offset.
MEASURED_STATION_DISTANCE = 11857
MEASURED_SENTRY_DISTANCE = 7406
MEASURED_SENTRY_OFFSET = 689


class AssaultDoctrineGuardTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(FIXTURE)

    def check(self, code):
        self.lua.execute(code)

    # -- shipped defaults ----------------------------------------------------

    def test_both_locks_ship_off_and_the_gate_is_a_no_op(self):
        """Kill-check: red if either default flips, and red if the gate stops
        returning its inputs untouched while both flags are off. The second half
        is the one that matters: an ungated behaviour change here would alter
        every heavy group in the game with no flag to turn it off."""
        self.check("""
          local d=Config.AI.Doctrine
          assert(d.AssaultStaticDefenceLock==false,
            'AssaultStaticDefenceLock must ship false; got '..tostring(d.AssaultStaticDefenceLock))
          assert(d.AssaultMobileThreatLock==false,
            'AssaultMobileThreatLock must ship false; got '..tostring(d.AssaultMobileThreatLock))
          assert(d.AssaultStaticDefenceThreatDistance==3600,
            'AssaultStaticDefenceThreatDistance default moved: '..tostring(d.AssaultStaticDefenceThreatDistance))
          assert(d.AssaultStaticDefenceCorridorWidth==0,
            'AssaultStaticDefenceCorridorWidth must default to 0; got '..tostring(d.AssaultStaticDefenceCorridorWidth))
          assert(d.AssaultMobileThreatCorridorWidth==0,
            'AssaultMobileThreatCorridorWidth must default to 0; got '..tostring(d.AssaultMobileThreatCorridorWidth))
          -- the four flags other work pinned must not be disturbed
          assert(Config.Station.AI.CapitalAwareInvestment==false,'CapitalAwareInvestment must still ship false')
          assert(Config.AI.BoundBankTarget==false,'BoundBankTarget must still ship false')
          assert(Config.AI.PreserveSavingClockWhileFielding==false,
            'PreserveSavingClockWhileFielding must still ship false')
          assert(Config.AI.FieldCheapHullWhileSaving==false,
            'FieldCheapHullWhileSaving must still ship false')

          -- and the gate must be inert for both buckets at the shipped default
          local g,st=scenario()
          local tur=sentry(901,7406,689)
          g.localThreat=nil
          local t,m=R:ApplyAssaultObjectiveLock(g,tur,'PRIMARY',{})
          assert(t==tur,'with both flags off a sentry diversion must pass through untouched')
          assert(m=='PRIMARY','mission was rewritten with both flags off')
          assert(g.assaultLock==nil,'the gate recorded a hold with both flags off')
          local escort=ship(902,3000,0)
          local t2=R:ApplyAssaultObjectiveLock(g,escort,'PRIMARY',{})
          assert(t2==escort,'with both flags off a mobile diversion must pass through untouched')
        """)

    # -- the sentry bucket ----------------------------------------------------

    def test_a_sentry_that_is_the_local_threat_is_still_engaged(self):
        """Kill-check: red if the gate vetoes a reactive sentry. This is the
        behaviour the doctrine must preserve - a sentry that is pressing this
        group is exactly the sentry worth clearing."""
        self.check("""
          R.Config.AI.Doctrine.AssaultStaticDefenceLock=true
          local g,st=scenario()
          local tur=sentry(901,3000,0)
          g.localThreat=tur
          local context={}
          local t,m=R:ApplyAssaultObjectiveLock(g,tur,'PRIMARY',context)
          assert(t==tur,'a sentry that IS the local threat was vetoed; the way is not being cleared')
          assert(m=='PRIMARY','mission changed on a reactive engagement')
          assert(g.assaultLock==nil,'a reactive engagement was recorded as a held objective')
          assert(context.reason==nil,'a reactive engagement was given a hold reason: '..tostring(context.reason))
        """)

    def test_a_sentry_that_is_not_a_threat_is_vetoed_and_the_station_stays(self):
        """Kill-check: THE core guard. Red if the gate stops vetoing, and red if
        it gives the group anything other than the station. Geometry is the
        measured p50 sentry diversion: 11,857 m to the station, the sentry 7,406 m
        out and 689 m off the axis, with no local threat anywhere."""
        self.check("""
          R.Config.AI.Doctrine.AssaultStaticDefenceLock=true
          local g,st=scenario(11857)
          local tur=sentry(901,7406,689)
          g.localThreat=nil
          local context={}
          local t,m=R:ApplyAssaultObjectiveLock(g,tur,'PRIMARY',context)
          assert(t==st,'the station was not restored as the objective; got signature '..tostring(t and t:getSignature()))
          assert(m=='PRIMARY','the hold changed the mission instead of only the target')
          assertEq(context.reason,'ASSAULT_OBJECTIVE_HELD','the hold is not attributed in the record')
          assert(g.assaultLock~=nil,'a hold was not recorded, so a batch cannot measure the gate')
          assertEq(g.assaultLock.rejected,tur:getSignature(),'assaultLock.rejected is the wrong hull')
          assertEq(g.assaultLock.held,st:getSignature(),'assaultLock.held is the wrong hull')
          assert(g.assaultLock.staticDefence==true,'assaultLock did not classify the rejected hull as static')
        """)

    def test_hard_local_threat_alone_does_not_admit_an_unrelated_sentry(self):
        """Kill-check: red if the gate treats g.hardLocalThreat as sufficient
        evidence on its own. hardLocalThreat is a statement about SOME local
        threat, so honouring it for an arbitrary target re-admits exactly the
        behaviour being gated - the flag would then be a no-op."""
        self.check("""
          R.Config.AI.Doctrine.AssaultStaticDefenceLock=true
          local g,st=scenario()
          local tur=sentry(901,7406,689)
          local other=sentry(902,1500,0)
          g.localThreat=other
          g.hardLocalThreat=true
          local t=R:ApplyAssaultObjectiveLock(g,tur,'PRIMARY',{})
          assert(t==st,'a sentry was admitted on the strength of a hardLocalThreat that named a different hull')
          -- and the named hull itself is still admitted, so the flag is not simply inert
          g2,st2=scenario()
          g2.localThreat=other; g2.hardLocalThreat=true
          local t2=R:ApplyAssaultObjectiveLock(g2,other,'PRIMARY',{})
          assert(t2==other,'the sentry that IS the local threat was vetoed')
        """)

    def test_the_reactive_bound_is_enforced_and_configurable(self):
        """Kill-check: red if the threat-distance bound stops biting. localThreat
        is re-derived every tick from LocalEngageRadius, but the INTERCEPT
        retention swap at fs2rts_strategy.lua:1040-1044 can re-bind it to a
        previous target well outside that radius, so an unbounded reactive test
        would let exactly that stale target re-appear as an objective."""
        self.check("""
          R.Config.AI.Doctrine.AssaultStaticDefenceLock=true
          local d=R.Config.AI.Doctrine
          -- inside the bound: engaged
          local g,st=scenario()
          local close=sentry(901,3000,0); g.localThreat=close
          assert(R:ApplyAssaultObjectiveLock(g,close,'PRIMARY',{})==close,
            'a sentry inside the reactive bound was vetoed')
          -- outside the bound, even though it IS localThreat: vetoed
          local g2,st2=scenario()
          local far=sentry(902,7406,689); g2.localThreat=far
          assert(R:ApplyAssaultObjectiveLock(g2,far,'PRIMARY',{})==st2,
            'a local threat beyond AssaultStaticDefenceThreatDistance was still admitted')
          -- and the bound is genuinely configurable, not a constant
          d.AssaultStaticDefenceThreatDistance=9000
          local g3,st3=scenario()
          local far2=sentry(903,7406,689); g3.localThreat=far2
          assert(R:ApplyAssaultObjectiveLock(g3,far2,'PRIMARY',{})==far2,
            'raising AssaultStaticDefenceThreatDistance did not admit the hull')
          -- bound of 0 disables the reactive clause entirely. The sentry is put
          -- 500 m out rather than 0 m: 0 <= 0 is true in Lua, so a coincident
          -- hull would satisfy a zero bound and the case would prove nothing.
          d.AssaultStaticDefenceThreatDistance=0
          local g4,st4=scenario()
          local near=sentry(904,500,0); g4.localThreat=near
          assert(R:ApplyAssaultObjectiveLock(g4,near,'PRIMARY',{})==st4,
            'a zero bound still admitted a local threat')
          d.AssaultStaticDefenceThreatDistance=3600
        """)

    def test_a_sentry_in_the_corridor_is_engaged_but_one_beside_the_lane_is_not(self):
        """Kill-check: red if the corridor clause stops admitting an on-axis
        sentry, and red if it starts admitting one that is off the lane. The
        positive half documents the clause the brief asked for; the negative half
        is the reason the width ships at 0 - measured p90 offset is 2,008 m, so
        any width that still admits a real blocker also admits most of the rest."""
        self.check("""
          local d=R.Config.AI.Doctrine
          d.AssaultStaticDefenceLock=true
          d.AssaultStaticDefenceCorridorWidth=1000
          -- group centroid at the origin, station 11,857 m along +x
          local g,st=scenario(11857)
          local onAxis=sentry(901,5000,500)
          assert(R:ApplyAssaultObjectiveLock(g,onAxis,'PRIMARY',{})==onAxis,
            'a sentry inside the corridor was not engaged')
          local g2,st2=scenario(11857)
          local beside=sentry(902,5000,3000)
          local t=R:ApplyAssaultObjectiveLock(g2,beside,'PRIMARY',{})
          assert(t==st2,'a sentry 3,000 m off the lane was admitted by a 1,000 m corridor')
          -- behind the group, not ahead of it: also outside the corridor
          local g3,st3=scenario(11857)
          local behind=sentry(903,-4000,100)
          assert(R:ApplyAssaultObjectiveLock(g3,behind,'PRIMARY',{})==st3,
            'a sentry behind the group was admitted by the corridor clause')
          -- and the shipped width of 0 disables the clause, so the on-axis case
          -- is vetoed unless it is reactive
          d.AssaultStaticDefenceCorridorWidth=0
          local g4,st4=scenario(11857)
          local onAxis2=sentry(904,5000,500)
          assert(R:ApplyAssaultObjectiveLock(g4,onAxis2,'PRIMARY',{})==st4,
            'a corridor width of 0 still admitted an on-axis sentry')
        """)

    # -- the mobile bucket ---------------------------------------------------

    def test_the_mobile_lock_is_a_separate_flag_and_ships_off(self):
        """Kill-check: red if the sentry lock starts touching mobile targets, or
        if the mobile lock fails to bite when it is turned on. Both halves
        matter: the 30.3% escort bucket is a different problem from the sentry
        bucket and must not be shipped on the sentry flag's evidence."""
        self.check("""
          local d=R.Config.AI.Doctrine
          d.AssaultStaticDefenceLock=true
          -- sentry lock alone leaves the escort bucket exactly as it shipped
          local g,st=scenario()
          local escort=ship(901,3000,0)
          assert(R:ApplyAssaultObjectiveLock(g,escort,'PRIMARY',{})==escort,
            'the static-defence lock leaked onto a mobile target')
          -- mobile lock on: a non-reactive escort is vetoed
          d.AssaultMobileThreatLock=true
          local g2,st2=scenario()
          local escort2=ship(902,3000,0)
          assert(R:ApplyAssaultObjectiveLock(g2,escort2,'PRIMARY',{})==st2,
            'the mobile lock did not veto a non-reactive escort')
          -- ... and a reactive one is still engaged
          local g3,st3=scenario()
          local escort3=ship(903,3000,0); g3.localThreat=escort3
          assert(R:ApplyAssaultObjectiveLock(g3,escort3,'PRIMARY',{})==escort3,
            'the mobile lock vetoed a reactive escort')
          -- a dead hull is not an obstacle worth anything
          local g4,st4=scenario()
          local wreck=ship(904,3000,0); wreck.HitpointsLeft=0; wreck.valid=false
          assert(R:ApplyAssaultObjectiveLock(g4,wreck,'PRIMARY',{})==wreck,
            'the gate hijacked a dead hull')
          d.AssaultMobileThreatLock=false
        """)

    # -- scope ----------------------------------------------------------------

    def test_non_heavy_groups_are_unaffected(self):
        """Kill-check: red if the gate touches any role other than
        capital/heavy/juggernaut. Bombers exist to suppress turrets, escorts are
        the strike anchor's screen, and the station screen is the base's job; a
        capital-only rule that leaked into any of them would strip the game of
        its turret-suppression and base-defence behaviour."""
        self.check("""
          local d=R.Config.AI.Doctrine
          d.AssaultStaticDefenceLock=true
          d.AssaultMobileThreatLock=true
          for _,role in ipairs({'fighter','escort','bomber','support'}) do
            local g,st=scenario()
            g.role=role
            local tur=sentry(901,7406,689)
            assert(R:ApplyAssaultObjectiveLock(g,tur,'PRIMARY',{})==tur,
              'the gate vetoed a '..role..' group, which is out of scope')
            local escort=ship(902,3000,0)
            assert(R:ApplyAssaultObjectiveLock(g,escort,'PRIMARY',{})==escort,
              'the gate vetoed a mobile target for a '..role..' group')
          end
          -- every in-scope heavy role IS gated
          for _,role in ipairs({'capital','heavy','juggernaut'}) do
            local g,st=scenario()
            g.role=role
            local tur=sentry(901,7406,689)
            assert(R:ApplyAssaultObjectiveLock(g,tur,'PRIMARY',{})==st,
              'the gate did not apply to role '..role)
          end
        """)

    def test_the_gate_only_fires_on_a_primary_assault_against_a_command_station(self):
        """Kill-check: red if the gate widens past the case it was measured on.
        Every early exit here is a case where vetoing would be wrong: a
        non-PRIMARY mission is a phase or lifecycle order, and an objective that
        is not a command station means the operation is not a base assault."""
        self.check("""
          local d=R.Config.AI.Doctrine
          d.AssaultStaticDefenceLock=true
          d.AssaultMobileThreatLock=true
          local missions={'INTERCEPT','SCREEN','REGROUP','ESCORT','RETREAT','TRAP','LURE','FEINT'}
          for _,m in ipairs(missions) do
            local g,st=scenario()
            local tur=sentry(901,7406,689)
            assert(R:ApplyAssaultObjectiveLock(g,tur,m,{})==tur,
              'the gate applied to mission '..m)
          end
          -- objective is a mobile enemy capital, not a command station
          local g2,st2=scenario()
          g2.operation.target=ship(903,12000,0)
          local tur2=sentry(901,7406,689)
          assert(R:ApplyAssaultObjectiveLock(g2,tur2,'PRIMARY',{})==tur2,
            'the gate applied when the operation objective was not a command station')
          -- no operation on the group at all
          local g3,st3=scenario()
          g3.operation=nil
          local tur3=sentry(901,7406,689)
          assert(R:ApplyAssaultObjectiveLock(g3,tur3,'PRIMARY',{})==tur3,
            'the gate applied to a group with no operation')
          -- already attacking the station
          local g4,st4=scenario()
          assert(R:ApplyAssaultObjectiveLock(g4,st4,'PRIMARY',{})==st4,
            'the gate applied when the group was already on the station')
          -- a dead operation objective must never be substituted in
          local g5,st5=scenario()
          st5.HitpointsLeft=0; st5.valid=false
          local tur5=sentry(901,7406,689)
          assert(R:ApplyAssaultObjectiveLock(g5,tur5,'PRIMARY',{})==tur5,
            'the gate substituted a destroyed station as the objective')
        """)

    # -- wiring ---------------------------------------------------------------

    def test_the_gate_runs_between_operations_and_commit(self):
        """Kill-check: red if the call site is removed or moved. The gate is
        only a veto if it runs after ApplyAIOperationOrder has produced the
        diverted target and before CommitAIGroup records it; anywhere else it
        would either be overwritten or would never see the sentry at all."""
        text = STRATEGY.read_text(encoding='utf-8')
        op = text.find('target,mission=self:ApplyAIOperationOrder(')
        lock = text.find('target,mission=self:ApplyAssaultObjectiveLock(')
        commit = text.find('mission=self:CommitAIGroup(')
        self.assertNotEqual(op, -1, 'ApplyAIOperationOrder call site not found')
        self.assertNotEqual(lock, -1,
                            'ApplyAssaultObjectiveLock is never called from '
                            'UpdateFactionStrategicPlan')
        self.assertNotEqual(commit, -1, 'CommitAIGroup call site not found')
        self.assertLess(op, lock,
                        'the gate must run AFTER operations chooses the target')
        self.assertLess(lock, commit,
                        'the gate must run BEFORE CommitAIGroup records the target')


if __name__ == "__main__":
    unittest.main()
