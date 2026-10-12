"""Characterization of RTS:ObserveAIExecution (fs2rts_ai_planning.lua).

The observer runs every strategic cycle and its records feed the planner, so these
guards pin what each observation field means: progress, stall, engagement, hull
loss and native-target changes. Collaborators that belong to other modules are
stubbed by name below; the observer's own arithmetic is not.

Run: cd core/tools && python -m pytest test_ai_observation.py -q
"""
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

SCRIPTS = Path(__file__).resolve().parents[1] / "data/scripts"

FIXTURE = r'''
local Vec = {}; Vec.__index = Vec
function Vec:getDistance(b)
  return math.sqrt((self.x-b.x)^2+(self.y-b.y)^2+(self.z-b.z)^2)
end
ba = {createVector=function(x,y,z) return setmetatable({x=x,y=y,z=z},Vec) end}
package.preload.fs2rts_state = function() return R end
-- fs2rts_ai_planning reaches only shipAlive and AI_FACTION_ORDER. The other exports
-- are present (the harness contract) but fail loudly if a path ever calls them.
package.preload.fs2rts_util = function()
  local function unused(name) return function() error('fs2rts_util.'..name..' is not stubbed in test_ai_observation') end end
  return {shipAlive=function(s) return s~=nil and s:isValid() and (tonumber(s.HitpointsLeft) or 0)>0 end,
    AI_FACTION_ORDER={'BLUE','RED','GOLD'},
    sortedNumericKeys=unused('sortedNumericKeys'), clamp=unused('clamp'), lower=unused('lower'),
    vec=unused('vec'), copyVec=unused('copyVec'), distance2=unused('distance2'),
    objectValid=unused('objectValid'), shipValid=unused('shipValid'), teamName=unused('teamName'),
    tableContainsSignature=unused('tableContainsSignature')}
end

R = {Config={AI={Doctrine={NoProgressSeconds=40}}}}
require 'fs2rts_ai_planning'(R)
R.AIObservations={}; R.AIOrderState={}; R.AIPursuit={}; R.MoveWaypoints={}
R.AIStats={hits={},received={},nativeChanges=0}
R.events={}; R.ships={}; R.resets=0; R.canEngage=true
R.ResetCoordinatedAI=function(self) self.resets=self.resets+1; self.AIStats={hits={},received={},nativeChanges=0}; self.AIObservations={} end
R.AIProfile=function(self,ship) return {range=1000,confidence=.9,value=100} end
R.GetFactionKey=function(self,ship) return 'BLUE' end
R.FindShipBySignature=function(self,id) return self.ships[id] end
R.GetNativeObjectiveStatus=function(self,ship,state) return self.nativeStatus or 'NATIVE_ORDER_ACTIVE',true end
R.CanAutoEngage=function(self,a,b) return self.canEngage end
R.EmitAIEvent=function(self,kind,payload,now) self.events[#self.events+1]={kind=kind,payload=payload,now=now} end

function ship(id,x,z,hp)
  local s={signature=id,Position=ba.createVector(x,0,z),HitpointsLeft=hp or 100,HitpointsMax=100,Radius=10,
    Physics={VelocityMax={z=100}}}
  function s:getSignature() return self.signature end
  function s:isValid() return true end
  return s
end
'''


class ObserveAIExecutionTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(FIXTURE)

    def check(self, code):
        self.lua.execute(code)

    def test_first_observation_records_an_engaged_objective_and_one_event(self):
        self.check('''
          local me=ship(1,0,0); local target=ship(2,300,0); me.Target=target
          R.ships[2]=target
          R.AIOrderState[1]={targetSignature=2,assignedAt=10,mission='ATTACK'}
          R.StrategicThreatSnapshot={{ship=me}}
          R:ObserveAIExecution(20)
          local o=R.AIObservations[1]
          assert(o.time==20 and o.objective==2 and o.assignedAt==10)
          assert(o.distance==300 and o.closing==0, 'no previous sample means no closing rate')
          assert(o.inRange and o.engaged and o.mode=='ENGAGED', 'in range on the native target must read ENGAGED')
          assert(o.lastProgress==20 and o.unengaged==0 and o.sampledSeconds==0)
          assert(#R.events==1 and R.events[1].kind=='EXECUTION' and R.events[1].payload.mode=='ENGAGED')
          assert(R.AIStats.received.BLUE==0 and R.AIStats.nativeChanges==0)
        ''')

    def test_closing_rate_and_hull_loss_are_taken_from_the_previous_sample(self):
        self.check('''
          local me=ship(1,0,0); local target=ship(2,300,0); me.Target=target
          R.ships[2]=target
          R.AIOrderState[1]={targetSignature=2,assignedAt=10,mission='ATTACK'}
          R.StrategicThreatSnapshot={{ship=me}}
          R:ObserveAIExecution(20)
          me.Position=ba.createVector(100,0,0); me.HitpointsLeft=90
          R:ObserveAIExecution(22)
          local o=R.AIObservations[1]
          assert(o.closing==50, 'closing = (300-200)/2s, got '..o.closing)
          assert(o.hullLoss==10 and R.AIStats.received.BLUE==10, 'hull loss must accumulate per faction')
          assert(o.lastProgress==22, 'closing above 1 m/s is progress')
          assert(o.sampledSeconds==2 and o.unengaged==0, 'sampled time accrues only while the sample spans dt')
          assert(#R.events==1, 'an unchanged status and mode must not emit another event')
        ''')

    def test_native_target_changes_are_counted_and_stall_is_reported_without_progress(self):
        self.check('''
          local me=ship(1,0,0); local target=ship(2,300,0); me.Target=target
          R.ships[2]=target
          R.AIOrderState[1]={targetSignature=2,assignedAt=10,mission='ATTACK'}
          R.StrategicThreatSnapshot={{ship=me}}
          R:ObserveAIExecution(20)
          R:ObserveAIExecution(22)
          me.Target=nil
          R:ObserveAIExecution(63)
          local o=R.AIObservations[1]
          assert(R.AIStats.nativeChanges==1, 'a native target that changed must be counted once')
          assert(o.lastProgress==20, 'no closing and no anchor advance means lastProgress stays put')
          assert(o.stalled and o.mode=='STALLED', 'idle past NoProgressSeconds while enemies are engageable must stall')
          assert(#R.events==2 and R.events[2].payload.mode=='STALLED', 'a mode change must emit an event')
        ''')

    def test_stall_is_suppressed_when_the_objective_is_engaged(self):
        self.check('''
          local me=ship(1,0,0); local target=ship(2,300,0); me.Target=target
          R.ships[2]=target
          R.AIOrderState[1]={targetSignature=2,assignedAt=10,mission='ATTACK'}
          R.StrategicThreatSnapshot={{ship=me}}
          R:ObserveAIExecution(20)
          R:ObserveAIExecution(100)
          local o=R.AIObservations[1]
          assert(not o.stalled and o.objectiveEngaged, 'a native lock on the objective in range is not a stall')
          assert(o.mode=='ENGAGED')
        ''')

    def test_pursuit_anchor_advance_counts_as_progress(self):
        self.check('''
          local me=ship(1,0,0); local target=ship(2,300,0); local anchor=ship(3,50,0)
          R.ships[2]=target; me.Target=nil
          R.AIOrderState[1]={targetSignature=2,assignedAt=10,mission='ATTACK',pursuitAt=5}
          R.MoveWaypoints[1]={waypoint=anchor}
          R.StrategicThreatSnapshot={{ship=me}}
          R.AIObservations[1]={time=20,objective=2,assignedAt=10,native=-1,status='NATIVE_ORDER_ACTIVE',mode='APPROACHING',
            distance=300,hull=100,lastProgress=20,pursuitRange=50,sampledSeconds=0,unengaged=0}
          R.AIPursuit[1]={anchoredAt=30}
          R:ObserveAIExecution(25)
          local o=R.AIObservations[1]
          assert(o.anchorAdvanced and o.lastProgress==25, 'a re-anchored pursuit is forward motion')
          assert(o.pursuitRange==50 and o.pursuitClosing==0, 'the anchor did not close range, so progress must come from the advance: '..o.pursuitClosing)
          assert(not o.stalled and o.mode=='APPROACHING', 'a progressing pursuit must not be reported STALLED')
        ''')

    def test_missing_stats_are_reset_before_observing(self):
        self.check('''
          local me=ship(1,0,0)
          R.AIStats=nil; R.StrategicThreatSnapshot={{ship=me}}
          R:ObserveAIExecution(5)
          assert(R.resets==1, 'observing without AIStats must reset the coordinated AI first')
          assert(R.AIObservations[1]~=nil and R.AIObservations[1].mode=='IDLE', 'an unordered ship reads IDLE')
        ''')

    def test_empty_snapshot_observes_nothing(self):
        self.check('''
          R.StrategicThreatSnapshot=nil
          R:ObserveAIExecution(5)
          assert(next(R.AIObservations)==nil and #R.events==0)
        ''')


if __name__ == "__main__":
    unittest.main()
