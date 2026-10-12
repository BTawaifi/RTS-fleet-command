"""Contract tests for the four telemetry instrumentation defects.

These guard the SHAPE and the MEANING of what the emitters publish, because the
four analysis tools (ai_tactics.py, ai_matchmap.py, compare_batches.py,
ai_invariants.py) consume these records and were being lied to:

  A  DECISION.score was the incumbent's score on a RETAINED decision, because
     `chosen=current` runs before the record is built. Read naively that inverts
     the explanation of every retention.
  B  COHESION.nodes changed JSON type mid-stream. Root cause is the shared
     json() encoder emitting a length-0 table as `{}`, i.e. an empty faction's
     node list becomes an object. Not a first-record code path.
  C  FACTION.damageDealt was filled from totalByFaction[kind], which is keyed by
     TARGET faction, so the field carried damage RECEIVED.
  D  The candidate ranking behind every decision was never recorded, because
     DetailedDecisionTelemetry costs ~200 MB/match and ships off.

Run:
    cd core/tools && python -m pytest test_telemetry_contracts.py -q

Engine objects are boundary doubles. This does not replace an FSO run.
"""
import os
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

# Lets the kill-check harness point this module at a mutated COPY of the scripts
# directory, so a guard can be proven to go red without editing the tree.
SCRIPTS = Path(os.environ.get('RTS_SCRIPTS_OVERRIDE')
               or (Path(__file__).resolve().parents[1] / 'data/scripts'))

# The mod's own ship-id helper, semantics copied from fs2rts_util.sig: a live
# ship reports getSignature(), a dead one reports -1 so a destroyed hull can
# never be confused with the real signature 1.
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
ba = {createVector=function(x,y,z) return setmetatable({x=x,y=y,z=z},Vec) end, print=function() end}
local function valid(x)
  if x == nil then return false end
  return x.valid ~= false
end
local function sigOf(x)
  if not valid(x) then return -1 end
  return x.getSignature and x:getSignature() or x.signature
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
require 'fs2rts_ai_planning'(R)
require 'fs2rts_ai_telemetry'(R)

now = 0
mn = {getMissionTime=function() return now end, Ships={}, Teams={}}

-- ---- doubles -------------------------------------------------------------
-- Each ship declares the score inputs the two candidate targets need to differ:
-- `value` feeds the objective's value factor, so a 4000-value incumbent and a
-- 100-value challenger cannot produce the same score.
nextSig = 100
function mkShip(team,value,role,x,z)
  nextSig = nextSig + 1
  local s = {signature=nextSig, team=team, value=value or 100, role=role or 'bomber',
    HitpointsLeft=100, HitpointsMax=100, valid=true, Radius=250, carry=100, loaded=100,
    Name='Enemy Hull', Team={Name=team},
    Position=ba.createVector(x or 0,0,z or 0), Class={Name='GVCv Sobek'},
    Physics={VelocityMax={z=100}}, Shields={CombinedLeft=0}}
  function s:getSignature() return self.signature end
  function s:isValid() return self.valid ~= false end
  function s:isDying() return false end
  function s:kill() self.HitpointsLeft=0 end
  R.world = R.world or {}
  R.world[s.signature] = s
  return s
end
R.world = {}

function mkGroup(lead,role)
  return {id=(role or 'bomber')..':'..sigOf(lead), role=role or 'bomber', units={lead},
    value=100, candidates=nil, assaultReserved=false, screen=false, spread=0}
end

-- ---- the minimal CommitAIGroup surface ----------------------------------
R.AIObservations = {}
R.AIOrderState = {}
R.AISnapshot = {}
R.AISpatialGrid = {}
R.AIProfileIndex = {}
R.AILocalCache = {}
R.AITargetedBy = {}
R.CombatTelemetryEnabled = true
-- The emitter double below represents an active recording destination.
R.AIEventSink = function() end
R.Config.AI.DetailedDecisionTelemetry = false
R.Config.AI.SampledHeavyDecisionTelemetry = false
R.ScenarioStartTime = 0
R.CommandPoints = 5000

R.GetFactionKey = function(self,s) return s and s.team or nil end
R.AreEnemies = function(self,a,b) return a.team ~= b.team end
R.IsCommandStation = function(self,s) return s.station == true end
R.IsStaticDefense = function(self,s) return s.static == true end
R.IsCapitalTarget = function(self,s) return s.station == true end
R.IsAutomaticAIUnit = function(self,s) return true end
R.FindShipBySignature = function(self,s)
  for _,s2 in pairs(R.world or {}) do if s2:getSignature() == s then return s2 end end
  return nil
end
R.GetShipRole = function(self,s) return s.role or 'capital' end
R.GetShipOrdnance = function(self,s) return 100,100 end
R.GetShipFormationRadius = function(self,s) return 50 end
R.HealthOf = function(self,s) return (tonumber(s.HitpointsLeft) or 0) end
R.AILocalStrength = function(self,a,b,c,d) return 0,0 end
R.BuildSafeFormationDestinations = function(self,group,point) return {} end
R.ChooseAIFormation = function(self,role,mission) return 'WEDGE' end
R.BuildAIFormationSlots = function(self,g,mission,ctx) return {} end
R.IsFiniteVector = function(v) return v ~= nil end
R.FindAIGroupTargeter = function(self,g) return nil end
R.ObserveAIUnit = function(self,s) end
R.UpdateAIPursuitGoals = function(self,s) end
R.RecordAIOrderTelemetry = function() end
R.ChooseAILocalThreat = function(self,g,coverage) return nil end
R.GetCommandArenaHalfExtent = function(self) return 15000 end
R.FlushAITrace = function() end
R.GetFleetCap = function(self,kind) return 200 end
R.GetEscalationProfile = function(self) return {buildTimeScale=1,tierUnlocks={0,240,570,1050,1380}} end
R.GetEscalationProgress = function(self,now) return math.max(0,math.min(1,((now or mn.getMissionTime())-(self.ScenarioStartTime or 0))/1380)) end
R.GetCurrentEscalationTier = function(self,n) return 4 end
R.GetAIIncomeRamp = function(self,n) return 1 end
R.GetUpgradeLevel = function(self,kind,track) return 0 end
R.GetPurchaseEstimate = function(self,class,tier,count) return {cost=100,time=10} end
R.GetFactionThreats = function(self,kind,station,r) return {},0,false end
R.IsUserOrderActive = function() return false end
R.EachShip = function(self,fn) end
R.GetShipList = function(self) return {} end

-- Every emitted record is captured instead of written, so the assertions read
-- the same payload the analysis tools would read off disk.
emitted = {}
R.EmitAIEvent = function(self,event,data,t)
  emitted[#emitted+1] = {event=event, data=data or {}, time=t}
end
function lastRecord(event)
  for i = #emitted, 1, -1 do
    if emitted[i].event == event then return emitted[i].data end
  end
  return nil
end
-- SummarizeAI emits one FACTION record per faction in a single call, so the
-- record of interest has to be selected by name. Taking the last one silently
-- returns GOLD's summary no matter which faction the test asked about.
function factionRecord(kind)
  for i = 1, #emitted do
    local row = emitted[i]
    if row.event == 'FACTION' and row.data.faction == kind then return row.data end
  end
  return nil
end
function countRecords(event)
  local n = 0
  for _,row in ipairs(emitted) do if row.event == event then n = n + 1 end end
  return n
end
function clearRecords() emitted = {} end

-- AIProfile is the scoring input. Keep it explicit so a candidate's score is a
-- function of declared `value` and nothing else.
function R:AIProfile(s)
  return {value=s.value or 100, range=s.range or 5000, armed=true, speed=s.speed or 100,
    role=s.role}
end

R.AIStats = {decisions=0, retained=0, switches=0, reissued=0, nativeChanges=0, orderIssues=0,
  received={BLUE=0,RED=0,GOLD=0}, losses={BLUE={},RED={},GOLD={}}}
R.AIPlanTelemetry = {}
R.AIEconomyFlow = {}
R.AIEconomyFlowCumulative = {}
R.AIStates = {BLUE={cp=1000,queue=nil}, RED={cp=1000,queue=nil}, GOLD={cp=1000,queue=nil}}
R.BuildQueue = {}
R.AutoPlayerMode = false
R.ActiveIncomePerSecond = 10

-- Order issuing is not what these tests are about; record the acceptance so the
-- commit path completes without the engine.
function R:IssueStrategicOrder(ship,target,label,mission,now_,force,options)
  self.AIOrderState[sigOf(ship)] = {targetSignature=sigOf(target), mission=mission,
    assignedAt=now_, label=label, confidence=0.9}
  self.AIStats.decisions = (self.AIStats.decisions or 0) + 1
  return true
end

-- ---- SummarizeAI surface -------------------------------------------------
stations = {}
function mkStation(kind,x)
  local s = mkShip(kind=='BLUE' and 'BLUE' or kind, 10000, 'capital', x or 0, 0)
  s.station = true
  s.HitpointsMax = 20000
  s.HitpointsLeft = 19000
  stations[kind] = s
  return s
end
mkStation('BLUE', 0)
mkStation('RED', 20000)
mkStation('GOLD', -20000)
R.GetFactionCommandShip = function(self,kind) return stations[kind] end

-- A minimal CombatDamageTelemetry: totalByFaction is keyed by TARGET faction and
-- every matchup row carries attackerFaction. That is exactly the shape defect C
-- is about, and the shape ai_tactics.py joins on.
--
-- The matchup/weapon buckets are keyed by the composite BUCKET-KEY STRING, not
-- appended as an array, because that is how the mod builds them
-- (fs2rts_ai_util.lua:132) and because an array-shaped bucket silently hides an
-- ipairs walk of it: ipairs over a pure hash table yields nothing, which shipped
-- as damageDealt=0.0 for all three factions on instrfix-a1 while this fixture
-- passed. Keying the rows the way the mod keys them is what makes the guard real.
function mkCombatDamage(buckets)
  local byFaction = {}
  for targetFaction, rows in pairs(buckets) do
    local entry = {hullDamage=0, shieldDamage=0, hitCount=0, lethalHits=0, matchups={}}
    for index, row in ipairs(rows) do
      entry.hullDamage = entry.hullDamage + row.hullDamage
      entry.hitCount = entry.hitCount + 1
      -- string key, exactly like combatDamageBucketKey
      entry.matchups['k'..index] = row
    end
    byFaction[targetFaction] = entry
  end
  return {registered=true, hitCount=0, totalByFaction=byFaction, intervalByFaction={}}
end

function mkBaseDamage(buckets)
  local byFaction = {}
  for targetFaction, rows in pairs(buckets) do
    local entry = {hullDamage=0, shieldDamage=0, hitCount=0, lethalHits=0, weapons={}}
    for index, row in ipairs(rows) do
      entry.hullDamage = entry.hullDamage + row.hullDamage
      entry.weapons['w'..index] = row
    end
    byFaction[targetFaction] = entry
  end
  return {hookCount=1, hitCount=0, totalByFaction=byFaction, intervalByFaction={}}
end

function runFactionSummary(kind)
  now = 100
  R.AISummaryAt = -1000
  R.AICombatDamageSummaryAt = 0
  R.AIBaseHullSamples = {}
  R.StrategicThreatSnapshot = {}
  clearRecords()
  R:SummarizeAI(now)
  return factionRecord(kind)
end
'''


class TelemetryContractTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(FIXTURE)

    def check(self, code):
        self.lua.execute(code)

    # ------------------------------------------------------------------ A
    def test_retained_decision_reports_a_challenger_score_distinct_from_the_incumbent(self):
        """The defect itself: on a RETAINED decision `score` was the incumbent's.

        The guard asserts three separate things, because a fix that only renames
        the field would leave the inversion in place:
          * score is the incumbent's (the objective the group kept)
          * challengerScore is a DIFFERENT number (the option it rejected)
          * scoreIsChallenger is false, so a consumer is told which is which

        The lead group is an ESCORT deliberately. A bomber scores match=0.12
        against a non-capital, and ScoreAIObjective collapses any match under
        0.2 to score=-100 (fs2rts_ai_planning/candidates.lua:133), which would make every
        candidate tie at -100 and the two scores indistinguishable.
        """
        self.check("""
          local lead=mkShip('BLUE',100,'escort')
          local incumbent=mkShip('RED',4000)   -- scores high
          local challenger=mkShip('RED',100)   -- scores low, so it loses
          local station=mkStation('RED',0)

          -- The group is already committed to `incumbent`, one second ago, so the
          -- age gate retains it regardless of score.
          R.AIOrderState[lead:getSignature()]={mission='PRIMARY',
            targetSignature=incumbent:getSignature(),assignedAt=99}
          local g=mkGroup(lead,'escort')
          local ctx={posture='OFFENSIVE'}
          R:CommitAIGroup(g,challenger,'PRIMARY',station,ctx,100,nil)
          local rec=lastRecord('DECISION')
          assert(rec,'no DECISION record was emitted')
          assert(rec.reason=='OBJECTIVE_RETAINED',
            'fixture did not produce a retention: reason='..tostring(rec.reason))
          assert(rec.scoreIsChallenger==false,
            'a retained decision must not label the committed score as the challenger')
          assert(rec.challengerScore~=nil,'challengerScore was not emitted')
          assert(math.abs(rec.score-rec.challengerScore)>0.001,
            'retained decision reported an IDENTICAL challenger and incumbent score ('
              ..tostring(rec.score)..'); the record cannot distinguish the two, which is'
              ..' exactly the inversion this defect caused')
          -- score must remain the committed objective's score, or the four tools
          -- silently change meaning. It equals the incumbent's own score.
          assert(rec.target==incumbent:getSignature(),
            'record does not point at the committed target')
        """)

    def test_non_retained_decision_labels_the_committed_score_as_the_challenger(self):
        """The complement of the guard above.

        When the challenger WINS, the committed objective IS the challenger, so
        scoreIsChallenger must be true and the two scores must agree. A fix that
        hardcoded scoreIsChallenger=false would break this case.
        """
        self.check("""
          local lead=mkShip('BLUE',100,'escort')
          local incumbent=mkShip('RED',100)    -- scores low
          local challenger=mkShip('RED',4000)  -- scores high, so it wins
          local station=mkStation('RED',0)

          -- Age past MinimumCommitmentSeconds so the age gate cannot retain, and
          -- the incumbent is genuinely beaten by more than switchingCost.
          R.AIOrderState[lead:getSignature()]={mission='PRIMARY',
            targetSignature=incumbent:getSignature(),assignedAt=1}
          local g=mkGroup(lead,'escort')
          local ctx={posture='OFFENSIVE'}
          R:CommitAIGroup(g,challenger,'PRIMARY',station,ctx,100,nil)
          local rec=lastRecord('DECISION')
          assert(rec.scoreIsChallenger==true,
            'a switched decision must label the committed score as the challenger')
          assert(math.abs(rec.score-rec.challengerScore)<0.0001,
            'on a switch the committed score and the challenger score must be the same number')
          assert(rec.target==challenger:getSignature(),'record does not point at the new target')
        """)

    def test_decision_record_always_carries_both_scores(self):
        """Both fields on every DECISION, not only on retentions.

        A field that appears only sometimes is the same class of trap as a field
        that changes type: consumers must branch, and they cannot tell a missing
        value from an absent code path.
        """
        self.check("""
          local lead=mkShip('BLUE',100,'bomber')
          local target=mkShip('RED',200)
          local station=mkStation('RED',0)
          local g=mkGroup(lead,'bomber')
          R:CommitAIGroup(g,target,'PRIMARY',station,{posture='OFFENSIVE'},100,nil)
          local rec=lastRecord('DECISION')
          assert(rec.score~=nil,'score missing')
          assert(rec.challengerScore~=nil,'challengerScore missing on a non-retained decision')
          assert(rec.scoreIsChallenger~=nil,'scoreIsChallenger missing')
        """)

    # ------------------------------------------------------------------ B
    def test_cohesion_publishes_an_explicit_node_count_and_emptiness_flag(self):
        """Consumers must never have to infer emptiness from the JSON type.

        The reporter's hypothesis was a first-record-versus-steady-state code
        path. It is not: json() (fs2rts_ai_util.lua:68) emits a length-0 table as
        an object, so ANY record for a faction holding no groups serialises
        nodes as {}. These two tests pin both arms of that.
        """
        self.check("""
          R:EmitAICohesion('RED',{},stations.RED,nil,100)
          local empty=lastRecord('COHESION')
          assert(empty,'no COHESION record emitted for a faction with no groups')
          assert(empty.nodesEmpty==true,
            'a faction with no groups must set nodesEmpty=true')
          assert(empty.nodeCount==0,'nodeCount must be 0 for an empty node list')
          assert(empty.groupCount==0,'groupCount disagrees with nodeCount')
        """)

    def test_cohesion_node_count_matches_the_nodes_actually_emitted(self):
        """nodeCount is authoritative and must agree with the payload.

        If nodeCount ever disagreed with what shipped, a consumer trusting the
        count would analyse groups that are not in the record.
        """
        self.check("""
          local station=stations.RED
          local groups={
            {id='g1',units={mkShip('BLUE',100,'heavy')},target=nil},
            {id='g2',units={mkShip('BLUE',100,'heavy')},target=nil},
          }
          groups[1].mission='PRIMARY'
          R:EmitAICohesion('RED',groups,stations.RED,nil,100)
          local rec=lastRecord('COHESION')
          assert(rec.nodeCount==2,'expected 2 nodes, got '..tostring(rec.nodeCount))
          assert(rec.groupCount==rec.nodeCount,'groupCount and nodeCount disagree')
          assert(rec.nodesEmpty==false,'a populated record must set nodesEmpty=false')
          -- The array and the count have to describe the same thing.
          local n=0
          if type(rec.nodes)=='table' then for _ in pairs(rec.nodes) do n=n+1 end end
          assert(n==rec.nodeCount,
            'the emitted node container holds '..n..' entries but nodeCount says '..tostring(rec.nodeCount))
        """)

    # ------------------------------------------------------------------ C
    def test_damage_dealt_is_dealt_and_damage_received_is_received(self):
        """The join that ai_tactics.py was doing in Python, published directly.

        BLUE fires 8000 into RED and 4000 into GOLD. RED fires 6000 into BLUE.
        So BLUE dealt 12000 and received 6000. The old emitter published
        damageDealt=6000 (BLUE's received) under the name "dealt", which is the
        inversion the tools were silently computing against.
        """
        self.check("""
          R.CombatDamageTelemetry=mkCombatDamage{
            RED={{attackerFaction='BLUE',hullDamage=8000}},
            GOLD={{attackerFaction='BLUE',hullDamage=4000}},
            BLUE={{attackerFaction='RED',hullDamage=6000}},
          }
          R.BaseDamageTelemetry=mkBaseDamage{}
          local rec=runFactionSummary('BLUE')
          assert(rec,'no FACTION record emitted')
          assert(math.abs(rec.damageDealt-12000)<0.01,
            'damageDealt must be the 12000 BLUE inflicted, got '..tostring(rec.damageDealt))
          assert(math.abs(rec.damageReceived-6000)<0.01,
            'damageReceived must be the 6000 BLUE took, got '..tostring(rec.damageReceived))
          assert(math.abs(rec.damageDealt-rec.damageReceived)>0.01,
            'dealt and received are identical here, so the test cannot tell the two'
              ..' fields apart and would pass against the old inverted emitter')
        """)

    def test_damage_dealt_is_not_a_mirror_of_the_other_factions_totals_by_accident(self):
        """A second faction, to prove the field tracks the attacker.

        Only the ATTACKER's own figure should move. Under the old emitter,
        damageDealt was keyed by target, so RED's number was BLUE's received
        total and this assertion fails.
        """
        self.check("""
          R.CombatDamageTelemetry=mkCombatDamage{
            RED={{attackerFaction='BLUE',hullDamage=8000}},
            BLUE={{attackerFaction='RED',hullDamage=6000}},
          }
          R.BaseDamageTelemetry=mkBaseDamage{}
          local blue=runFactionSummary('BLUE')
          local red=runFactionSummary('RED')
          assert(math.abs(blue.damageDealt-8000)<0.01,
            'BLUE dealt 8000, got '..tostring(blue.damageDealt))
          assert(math.abs(red.damageDealt-6000)<0.01,
            'RED dealt 6000, got '..tostring(red.damageDealt))
          assert(math.abs(red.damageReceived-8000)<0.01,
            'RED received 8000, got '..tostring(red.damageReceived))
        """)

    def test_station_damage_dealt_is_also_attributed_to_the_attacker(self):
        """stationDamageDealt had the identical target-keyed mislabelling.

        The comment above the old code claimed BaseDamageTelemetry held damage
        this faction dealt to the enemy station; the table it read is keyed by
        the station's own faction, so it held damage the station took.
        """
        self.check("""
          R.CombatDamageTelemetry=mkCombatDamage{}
          R.BaseDamageTelemetry=mkBaseDamage{
            RED={{attackerFaction='BLUE',hullDamage=2500}},
            BLUE={{attackerFaction='RED',hullDamage=400}},
          }
          local blue=runFactionSummary('BLUE')
          assert(math.abs(blue.stationDamageDealt-2500)<0.01,
            'BLUE dealt 2500 hull damage to a station, got '..tostring(blue.stationDamageDealt))
          assert(math.abs(blue.stationDamageReceived-400)<0.01,
            'BLUE took 400 station hull damage, got '..tostring(blue.stationDamageReceived))
        """)

    def test_damage_dealt_ignores_rows_with_no_known_attacker(self):
        """Damage the hook could not attribute to a faction is not that faction's.

        Without this, UNKNOWN-attributed hits silently inflate some faction's
        dealt total and the arms-race comparison is meaningless. The hit is
        aimed at RED, so BLUE's received total must stay at zero: BLUE cannot
        be credited with a shot the hook never attributed to it.
        """
        self.check("""
          R.CombatDamageTelemetry=mkCombatDamage{
            RED={{attackerFaction='UNKNOWN',hullDamage=99999},
                 {attackerFaction='BLUE',hullDamage=1000}},
          }
          R.BaseDamageTelemetry=mkBaseDamage{}
          local rec=runFactionSummary('BLUE')
          assert(math.abs(rec.damageDealt-1000)<0.01,
            'unattributable damage leaked into damageDealt: '..tostring(rec.damageDealt))
          assert(math.abs(rec.damageReceived-0)<0.01,
            'BLUE took no hits at all, but damageReceived says '..tostring(rec.damageReceived))
        """)

    def test_retained_candidate_set_does_not_record_the_incumbent_twice(self):
        """A retained decision used to append `current` and then `chosen`.

        Because `chosen` IS `current` after the retain rebind, the recorded
        candidate set held the incumbent twice and held NO row at all for the
        challenger - the option actually being rejected. Any frequency analysis
        over the list would double-count the incumbent, and the most interesting
        row was missing. Surfaced by the new sampling mode, which is the first
        thing that makes this list reachable.
        """
        self.check("""
          Config.AI.SampledHeavyDecisionTelemetry=true
          Config.AI.SampledHeavyDecisionSampleEvery=1
          local incumbent=mkShip('RED',4000)
          local challenger=mkShip('RED',100)
          local lead=mkShip('BLUE',100,'capital')
          R.AIOrderState[lead:getSignature()]={mission='PRIMARY',
            targetSignature=incumbent:getSignature(),assignedAt=99}
          local g=mkGroup(lead,'capital')
          R:PrepareAIGroups({g},stations.BLUE,challenger,100)
          R:CommitAIGroup(g,challenger,'PRIMARY',stations.RED,{posture='OFFENSIVE'},100,nil)
          local rec=lastRecord('DECISION')
          assert(rec.reason=='OBJECTIVE_RETAINED','fixture must produce a retention')
          local seenIncumbent,seenChallenger=0,0
          for _,c in ipairs(rec.candidates) do
            if c.target==incumbent:getSignature() then seenIncumbent=seenIncumbent+1 end
            if c.target==challenger:getSignature() then seenChallenger=seenChallenger+1 end
          end
          assert(seenIncumbent==1,
            'the incumbent appears '..seenIncumbent..' times in the candidate set, expected once')
          assert(seenChallenger==1,
            'the challenger appears '..seenChallenger..' times in the candidate set, expected once')
        """)

    def test_detailed_decision_telemetry_still_works_without_prepare(self):
        """A group that never went through PrepareAIGroups must keep the flag.

        PrepareAIGroups and CommitAIGroup are ordered only by convention: every
        production caller prepares first, but CommitAIGroup used to honour
        DetailedDecisionTelemetry on its own. Reading the prepared flag without a
        fallback would silently switch that flag off for any caller that does not
        prepare, and it is a telemetry flag people enable by hand.
        """
        self.check("""
          Config.AI.DetailedDecisionTelemetry=true
          local target=mkShip('RED',4000)
          local lead=mkShip('BLUE',100,'fighter')
          local g=mkGroup(lead,'fighter')
          -- No PrepareAIGroups call at all.
          R:CommitAIGroup(g,target,'PRIMARY',stations.RED,{posture='OFFENSIVE'},100,nil)
          local rec=lastRecord('DECISION')
          assert(rec.candidates~=nil,
            'DetailedDecisionTelemetry stopped working for a group that skipped PrepareAIGroups')
        """)

    def test_the_fallback_does_not_disturb_the_sampling_rate(self):
        """Taking the fallback must not advance the 1-in-N counter.

        Otherwise a caller that mixes prepared and unprepared groups would see
        the sampling rate drift away from its configured value, and two runs of
        the same battle would not be comparable.
        """
        self.check("""
          Config.AI.SampledHeavyDecisionTelemetry=true
          Config.AI.SampledHeavyDecisionSampleEvery=4
          local target=mkShip('RED',4000)
          -- Unprepared heavy groups only: the counter must stay at zero, so no
          -- candidate list is ever produced by the fallback path.
          for _=1,8 do
            local lead=mkShip('BLUE',100,'capital')
            R.AIOrderState={}
            local g=mkGroup(lead,'capital')
            R:CommitAIGroup(g,target,'PRIMARY',stations.RED,{posture='OFFENSIVE'},100,nil)
            assert(lastRecord('DECISION').candidates==nil,
              'the unprepared fallback must not sample heavy groups; the sampler has no rate to divide')
          end
          assert(R.AIHeavyDecisionSamples==nil or R.AIHeavyDecisionSamples==0,
            'the fallback advanced the sampling counter (now '
              ..tostring(R.AIHeavyDecisionSamples)..')')
        """)

    # ------------------------------------------------------------------ D
    def test_sampled_candidate_telemetry_ships_off_and_adds_no_candidate_rows(self):
        """The default path must cost nothing and record nothing.

        Both flags ship off, so no DECISION carries a candidate list and none of
        the sampling labels are published. Publishing them unconditionally cost
        1.51 MB/match (3.4% of volume) to say "absent" on every record; with the
        flag off, candidates is absent from EVERY decision, so the batch already
        states that no candidate data was collected. This is the guard that keeps
        the 200 MB/match regression from returning by accident.
        """
        self.check("""
          assert(Config.AI.SampledHeavyDecisionTelemetry==false,
            'SampledHeavyDecisionTelemetry must default OFF')
          assert(Config.AI.DetailedDecisionTelemetry==false,
            'DetailedDecisionTelemetry must keep its existing OFF default')
          local lead=mkShip('BLUE',100,'capital')
          local target=mkShip('RED',4000)
          local g=mkGroup(lead,'capital')
          -- The SAME group object goes through both calls, as the planner does.
          R:PrepareAIGroups({g},stations.BLUE,target,100)
          R:CommitAIGroup(g,target,'PRIMARY',stations.RED,{posture='OFFENSIVE'},100,nil)
          local rec=lastRecord('DECISION')
          assert(rec.candidates==nil,
            'a heavy decision recorded a candidate list with both flags off')
          assert(rec.candidateCountTotal==nil,
            'candidateCountTotal must not be published when nothing was recorded')
          assert(rec.candidateSampleEvery==nil,
            'candidateSampleEvery must not be published when nothing was recorded')
          -- Defect A is unconditional and must survive this default path.
          assert(rec.challengerScore~=nil,'challengerScore must always be published')
          assert(rec.scoreIsChallenger~=nil,'scoreIsChallenger must always be published')
        """)

    def test_sampled_heavy_telemetry_records_the_ranking_on_a_1_in_n_sample(self):
        """Heavy groups only, 1-in-N, and the list is labelled as partial."""
        self.check("""
          Config.AI.SampledHeavyDecisionTelemetry=true
          Config.AI.SampledHeavyDecisionSampleEvery=4
          local target=mkShip('RED',4000)

          -- Four heavy decisions: with N=4 only the fourth is sampled.
          local recorded=0
          for i=1,4 do
            local lead=mkShip('BLUE',100,'capital')
            R.AIOrderState={}
            local g=mkGroup(lead,'capital')
            R:PrepareAIGroups({g},stations.BLUE,target,100)
            R:CommitAIGroup(g,target,'PRIMARY',stations.RED,{posture='OFFENSIVE'},100,nil)
            local rec=lastRecord('DECISION')
            if rec.candidates~=nil then recorded=recorded+1 end
          end
          assert(recorded==1,
            '1-in-4 over four heavy decisions must record exactly one, recorded '..recorded)
        """)

    def test_sampled_heavy_telemetry_never_samples_a_light_group(self):
        """A fighter wing's decisions must stay unrecorded.

        This is the property that makes the mode affordable: fighter and escort
        groups are the overwhelming majority of DECISION records (79% fighter,
        19% escort in capgate-20261001), so sampling them would cost as much as
        DetailedDecisionTelemetry did.
        """
        self.check("""
          Config.AI.SampledHeavyDecisionTelemetry=true
          Config.AI.SampledHeavyDecisionSampleEvery=1   -- sample EVERYTHING
          local target=mkShip('RED',4000)
          for _,role in ipairs({'fighter','escort','bomber'}) do
            local lead=mkShip('BLUE',100,role)
            R.AIOrderState={}
            local g=mkGroup(lead,role)
            R:PrepareAIGroups({g},stations.BLUE,target,100)
            R:CommitAIGroup(g,target,'PRIMARY',stations.RED,{posture='OFFENSIVE'},100,nil)
            local rec=lastRecord('DECISION')
            assert(rec.candidates==nil,
              'a '..role..' group recorded candidates; only heavy groups may be sampled')
          end
        """)

    def test_sampled_heavy_telemetry_does_not_change_detailed_decision_telemetry(self):
        """DetailedDecisionTelemetry is unchanged in meaning: still all groups.

        The new mode is strictly additive. If the old flag is on, every group is
        recorded exactly as before, because a consumer that enables it expects
        the pre-existing behaviour.
        """
        self.check("""
          Config.AI.DetailedDecisionTelemetry=true
          Config.AI.SampledHeavyDecisionTelemetry=true
          local target=mkShip('RED',4000)
          local lead=mkShip('BLUE',100,'fighter')
          local g=mkGroup(lead,'fighter')
          R:PrepareAIGroups({g},stations.BLUE,target,100)
          R:CommitAIGroup(g,target,'PRIMARY',stations.RED,{posture='OFFENSIVE'},100,nil)
          local rec=lastRecord('DECISION')
          assert(rec.candidates~=nil,
            'DetailedDecisionTelemetry must still record every group')
          assert(rec.candidateSampleEvery==0,
            'a non-sampled (flag-driven) record must report candidateSampleEvery=0')
        """)

    def test_sampled_record_labels_itself_as_partial_and_names_the_untruncated_size(self):
        """A short candidate list must not read as "nothing else was on the table".

        candidateCountTotal is the size of the set this decision actually scored;
        candidateSampleEvery names the rate, so a consumer can say how much of
        the match is missing rather than assuming it saw everything.
        """
        self.check("""
          Config.AI.SampledHeavyDecisionTelemetry=true
          Config.AI.SampledHeavyDecisionSampleEvery=1
          local incumbent=mkShip('RED',4000)
          local challenger=mkShip('RED',100)
          local lead=mkShip('BLUE',100,'capital')
          R.AIOrderState[lead:getSignature()]={mission='PRIMARY',
            targetSignature=incumbent:getSignature(),assignedAt=1}
          local g=mkGroup(lead,'capital')
          R:PrepareAIGroups({g},stations.BLUE,challenger,100)
          R:CommitAIGroup(g,challenger,'PRIMARY',stations.RED,{posture='OFFENSIVE'},100,nil)
          local rec=lastRecord('DECISION')
          assert(rec.candidates~=nil,'expected a sampled candidate list')
          assert(rec.candidateSampleEvery==1,
            'candidateSampleEvery must name the sampling rate, got '..tostring(rec.candidateSampleEvery))
          assert(rec.candidateCountTotal==#rec.candidates,
            'candidateCountTotal ('..tostring(rec.candidateCountTotal)..') disagrees with the'
              ..' emitted list length ('..tostring(#rec.candidates)..')')
          -- Exactly one candidate is marked selected, and it is the committed one.
          local selected=0
          for _,c in ipairs(rec.candidates) do
            if c.selected then selected=selected+1 end
          end
          assert(selected==1,'exactly one candidate must be marked selected, got '..selected)
        """)

    def test_sampled_candidate_rows_carry_class_and_role_from_the_real_hulls(self):
        """The ranking is only useful if a candidate can be identified.

        The row is scored by signature; class and role are what make the list
        readable without a second lookup.
        """
        self.check("""
          Config.AI.SampledHeavyDecisionTelemetry=true
          Config.AI.SampledHeavyDecisionSampleEvery=1
          local target=mkShip('RED',4000)
          target.Class={Name='GVCv Sobek'}
          local lead=mkShip('BLUE',100,'capital')
          local g=mkGroup(lead,'capital')
          R:PrepareAIGroups({g},stations.BLUE,target,100)
          R:CommitAIGroup(g,target,'PRIMARY',stations.RED,{posture='OFFENSIVE'},100,nil)
          local rec=lastRecord('DECISION')
          local found=false
          for _,c in ipairs(rec.candidates) do
            if c.target==target:getSignature() then
              found=true
              assert(c.class=='GVCv Sobek','candidate class missing, got '..tostring(c.class))
              assert(c.role~=nil,'candidate role missing')
            end
          end
          assert(found,'the committed target was not present in its own candidate list')
        """)

    def test_sampling_counter_is_reset_per_mission(self):
        """A counter that survives a restart makes match 2's rate arbitrary.

        The cohesion and contest sample clocks are mission-scoped for the same
        reason: a leftover count changes which decisions get sampled, so two runs
        of the same battle produce different telemetry and a comparison between
        them is not reproducible.
        """
        self.check("""
          Config.AI.SampledHeavyDecisionTelemetry=true
          Config.AI.SampledHeavyDecisionSampleEvery=4
          local target=mkShip('RED',4000)
          local function recordedIn(n)
            local total=0
            for _=1,n do
              local lead=mkShip('BLUE',100,'capital')
              R.AIOrderState={}
              local g=mkGroup(lead,'capital')
              R:PrepareAIGroups({g},stations.BLUE,target,100)
              R:CommitAIGroup(g,target,'PRIMARY',stations.RED,{posture='OFFENSIVE'},100,nil)
              local rec=lastRecord('DECISION')
              if rec.candidates~=nil then total=total+1 end
            end
            return total
          end
          local first=recordedIn(8)
          -- Restart: the counter must come back to zero, so the next 8 decisions
          -- sample identically rather than continuing mid-cycle.
          R.AIHeavyDecisionSamples=0
          local second=recordedIn(8)
          assert(first==second,
            'the 1-in-4 pattern is not reproducible after a restart: '
              ..tostring(first)..' then '..tostring(second))
          assert(first==2,'8 heavy decisions at 1-in-4 must record 2, got '..tostring(first))
        """)
