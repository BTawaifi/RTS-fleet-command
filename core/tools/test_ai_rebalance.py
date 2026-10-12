"""Behavior checks for adaptive composition, support and operation progress."""
import unittest
from pathlib import Path

from test_feature_request import boot
from test_operations import FIXTURE
from test_station import SCRIPTS
from lupa.lua51 import LuaRuntime


class RebalanceTests(unittest.TestCase):
    def setUp(self):
        self.lua = boot()

    def test_escalation_uses_native_smart_secondary_selection(self):
        data = Path(SCRIPTS).parent
        mission = (data / 'missions/FS2_RTS_Escalation.fs2').read_text()
        profile = (data / 'tables/fs2rts-ai-profiles-aip.tbm').read_text()
        self.assertIn('$AI Profile: RTS Fleet Command', mission)
        self.assertIn('$Profile Name: RTS Fleet Command', profile)
        self.assertIn('$smart secondary weapon selection: YES', profile)
        self.assertNotIn('$Profile Name: FS2 RETAIL', profile,
            'RTS must not change unrelated retail missions')

    def test_static_artillery_does_not_inherit_capital_siege_armor(self):
        tables = Path(SCRIPTS).parent / 'tables'
        cannon = (tables / 'fs2rts-cannon-wep.tbm').read_text()
        self.assertEqual(cannon.count('RTS Static Artillery'), 3,
            'impact or either blast path still inherits capital beam damage')
        armor = (tables / 'fs2rts-base-beam-amr.tbm').read_text()
        command = armor.split('$Name: RTS Command Hull', 1)[1]
        self.assertIn('$Damage Type: RTS Static Artillery\n', command)
        artillery = command.split('$Damage Type: RTS Static Artillery', 1)[1].split('$Damage Type:', 1)[0]
        self.assertIn('+Value: 0.025', artillery)
        capital = command.split('$Damage Type: RTS Capital Beam', 1)[1].split('$Damage Type:', 1)[0]
        self.assertIn('+Value: 0.25', capital, 'mobile capital siege was nerfed with sentries')

    def test_composition_uses_only_buildable_roles_and_preserves_siege(self):
        self.lua.execute('''
          r.AIProductionNeeds.RED={fighter=.5,bomber=0,escort=0,capital=0}
          local targets=r:GetAICompositionTargets('RED',3,{fighter=true,bomber=true,capital=true})
          assert(targets.escort==0 and math.abs(targets.fighter+targets.bomber+targets.capital-1)<1e-9)
          assert(targets.fighter>.28 and targets.bomber>0 and targets.capital>0,
            'counter production erased offensive roles')
          r.AIProductionNeeds.RED={fighter=0,bomber=0,escort=0,capital=0}
          targets=r:GetAICompositionTargets('RED',3,{fighter=true})
          assert(targets.fighter==1,'sparse roster saved toward an impossible composition')
        ''')

    def test_opponent_demand_is_fleet_wide_bounded_and_decays(self):
        self.lua.execute('''
          local home=mkFighter('Home')
          local foe=ship('Remote bomber',class('GTB Artemis'),ba.createVector(14000,0,0),mn.Teams.hostile)
          foe.__role='bomber'
          r.StrategicThreatSnapshot={{ship=foe,profile={value=100}}}
          r:UpdateAIProductionDemand('BLUE',home,{},0)
          local initial=r.AIProductionNeeds.BLUE.fighter
          assert(initial>0,'remote bomber fleet was ignored')
          r.StrategicThreatSnapshot={}
          r:UpdateAIProductionDemand('BLUE',home,{},1)
          assert(r.AIProductionNeeds.BLUE.fighter>initial*.9,'one quiet tick discarded opponent history')
          r:UpdateAIProductionDemand('BLUE',home,{},121)
          assert(r.AIProductionNeeds.BLUE.fighter<initial*.1,'obsolete opponent demand never decayed')
          r:ResetCoordinatedAI()
          assert(next(r.AIOpponentDemand)==nil,'opponent history survived mission restart')
        ''')

    def test_real_production_picker_consumes_adaptive_targets(self):
        self.lua.execute('''
          r.GetCurrentEscalationTier=function() return 3 end
          local roster={{class='GTF Ulysses',tier=1,role='fighter',weight=1},
            {class='GTB Artemis',tier=2,role='bomber',weight=1}}
          for _,entry in ipairs(roster) do class(entry.class) end
          r.GetAIRoster=function() return roster end
          r.GetFleetCap=function() return 64 end; r.CountCommittedCombatants=function() return 0 end
          r.CountAIRoleUnits=function() return {fighter=0,bomber=0,capital=0,total=0},
            {fighter=0,bomber=0,escort=0,capital=0,total=0} end
          r.AIProductionNeeds.RED={fighter=.5}
          local candidate,decision=r:ChooseAIBuild('RED',{cp=100000},0)
          assert(candidate and decision.desiredRole=='fighter')
          assert(decision.compositionTargets.capital==0 and decision.compositionTargets.escort==0)
          assert(decision.compositionTargets.fighter>.7,'production ignored its adapted roster targets')
        ''')

    def test_full_planner_evaluates_new_opponent_model(self):
        self.lua.execute('''
          local foe=mkFighter('Remote player bomber',ba.createVector(13000,0,0)); foe.__role='bomber'
          r:ResetCoordinatedAI(); r:InvalidateShipList()
          r:UpdateFactionStrategicPlan('RED',50,true)
          assert(r.AIOpponentDemand.RED and r.AIProductionNeeds.RED.fighter>0,
            'strategic planner never evaluated the opponent model')
        ''')

    def test_ready_home_defenders_preserve_savings_but_uncovered_or_critical_base_does_not(self):
        self.lua.execute('''
          r:ResetCoordinatedAI()
          r.CombatTelemetryEnabled=true
          local bomber=mkFighter('Base attacker',stations.RED.Position+ba.createVector(500,0,0))
          bomber.__role='bomber'; bomber.Target=stations.RED; bomber[1].Target=stations.RED
          local guards={}
          for i=1,4 do
            local unit=ship('Defender '..i,class('SF Mara'),stations.RED.Position,mn.Teams.hostile)
            unit.__role='fighter'; guards[#guards+1]=unit
          end
          r:InvalidateShipList(); r:UpdateFactionStrategicPlan('RED',50,true)
          assert(r.AIPlanTelemetry.RED.emergency,'fixture did not create real strategic station pressure')
          assert(not r.AIProductionEmergency.RED.emergency,'covered pressure continually cancelled capital savings')
          for _,guard in ipairs(guards) do guard.valid=false end
          r:InvalidateShipList(); r:UpdateFactionStrategicPlan('RED',60,true)
          assert(r.AIProductionEmergency.RED.emergency,'uncovered bomber did not release savings for counters')
          for _,guard in ipairs(guards) do guard.valid=true end
          stations.RED.HitpointsLeft=stations.RED.HitpointsMax*.2
          r:InvalidateShipList(); r:UpdateFactionStrategicPlan('RED',70,true)
          assert(r.AIProductionEmergency.RED.emergency,'critical base protected savings instead of surviving')
        ''')

    def test_full_planner_releases_a_spare_screen_to_bombers(self):
        self.lua.execute('''
          r:ResetCoordinatedAI()
          local bomber=ship('Strike',class('SB Shaitan'),stations.RED.Position,mn.Teams.hostile)
          bomber.__role='bomber'
          local fighters={}
          for i=1,4 do
            local s=ship('Guard '..i,class('SF Mara'),stations.RED.Position+ba.createVector(i*50,0,0),mn.Teams.hostile)
            s.__role='fighter'; fighters[#fighters+1]=s
            r.AIOrderState[s:getSignature()]={mission='SCREEN',targetSignature=stations.RED:getSignature(),assignedAt=0}
          end
          r:InvalidateShipList(); r:UpdateFactionStrategicPlan('RED',50,true)
          local escorts=0; local details={}
          for _,s in ipairs(fighters) do
            local order=r.AIOrderState[s:getSignature()]
            details[#details+1]=order.mission..'/'..tostring(order.targetSignature)..'/'..tostring(order.reason)
            if order.mission=='ESCORT' and order.targetSignature==bomber:getSignature() then escorts=escorts+1 end
          end
          assert(escorts==1,'planner failed to release exactly one spare home screen: '..table.concat(details,','))
        ''')

    def test_immediate_home_bomber_pressure_bypasses_memory_delay(self):
        self.lua.execute('''
          local home=mkFighter('Home')
          r.StrategicThreatSnapshot={}; r:UpdateAIProductionDemand('BLUE',home,{},0)
          local bomber=ship('Incoming',class('GTB Artemis'),ba.createVector(500,0,0),mn.Teams.hostile)
          bomber.__role='bomber'
          r:UpdateAIProductionDemand('BLUE',home,{{ship=bomber,value=100}},.1)
          assert(r.AIProductionNeeds.BLUE.fighter>=.5,'smoothing delayed emergency bomber defense')
        ''')

    def test_idle_home_screen_can_escort_without_consuming_home_reserve(self):
        self.lua.execute('''
          local bomber=mkFighter('Strike'); bomber.__role='bomber'
          local front=mkStation(); local anchor={id='b',units={bomber},primary=front,value=100,role='bomber'}
          local a=mkFighter('Guard A'); local b=mkFighter('Guard B')
          local ga={id='a',role='fighter',units={a},value=100,screen=true,primary=front}
          local gb={id='c',role='fighter',units={b},value=100,screen=true,primary=front}
          assert(r:ChooseAIBomberEscort({ga,gb},anchor,100,0)~=nil,
            'home screen status permanently prevented an escort')
          assert(r:ChooseAIBomberEscort({ga},anchor,100,0)==nil,'escort consumed the last home defender')
          ga.defending=true; ga.target=front
          assert(r:ChooseAIBomberEscort({ga,gb},anchor,100,0)==nil,'active defender was taken from home')
          ga.defending=false; ga.target=nil; ga.committed=true
          assert(r:ChooseAIBomberEscort({ga},anchor,0,0)==nil,'committed assault screen was stolen')
        ''')

    def test_local_strength_discounts_late_arrivals_and_service(self):
        self.lua.execute('''
          local own=mkFighter('Own',ba.createVector(0,0,0))
          local foe=ship('Slow remote foe',class('SF Mara'),ba.createVector(4000,0,0),mn.Teams.hostile)
          local ally=mkFighter('Servicing ally',ba.createVector(100,0,0))
          local rows={{ship=own,profile={value=100,armed=true,range=1000,speed=100}},
            {ship=foe,profile={value=10000,armed=true,range=1000,speed=20}},
            {ship=ally,profile={value=10000,armed=true,range=1000,speed=100}}}
          r.GetAISpatialCandidates=function() return rows end; r.StrategicThreatSnapshot=rows
          r.FleetServices[ally:getSignature()]={}; r.AILocalCache={}
          local friend,enemy=r:AILocalStrength(own,own.Position,4500,false)
          assert(friend==100 and enemy==0,'inactive or distant strength distorted combat')
          rows[2].profile.range=6000; r.AILocalCache={}
          friend,enemy=r:AILocalStrength(own,own.Position,4500,false)
          assert(enemy==10000,'long range attacker was discounted')
        ''')

    def test_operation_deadline_requires_no_objective_progress(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        lua.execute(FIXTURE)
        lua.execute('''
          local home=makeHome(); local target=makeTarget(21,'RED',1000,0)
          local g=makeGroup(1,target,'bomber',1000,0,100)
          R:BuildAIOperations('BLUE',{g},home,0,0)
          local op=R.AIOperations.BLUE[21]
          op.phase='ENGAGE'; op.phaseAt=0; op.engagedAt=0; op.initialValue=100; op.initialStrikes=1
          R.Config.AI.Operations.AttackSeconds=10
          target.HitpointsLeft=90
          R:BuildAIOperations('BLUE',{g},home,11,0)
          assert(op.phase~='WITHDRAW','productive siege was recalled by elapsed time')
          R:BuildAIOperations('BLUE',{g},home,22,0)
          assert(op.phase=='WITHDRAW','stalled operation never recovered')
        ''')

    def test_armed_escorts_keep_operation_alive_after_bomber_loss(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        lua.execute(FIXTURE)
        lua.execute('''
          local home=makeHome(); local target=makeTarget(21,'RED',1000,0)
          local bomber=makeGroup(1,target,'bomber',1000,0,100)
          local escort=makeGroup(2,target,'escort',1000,0,400)
          local defender=makeShip(10,'RED',1000,0,'fighter')
          R.StrategicThreatSnapshot={{ship=defender,profile={value=100}}}
          R:BuildAIOperations('BLUE',{bomber,escort},home,0,0)
          R:BuildAIOperations('BLUE',{bomber,escort},home,10,0)
          R:BuildAIOperations('BLUE',{bomber,escort},home,11,0)
          local op=R.AIOperations.BLUE[21]
          R:BuildAIOperations('BLUE',{escort},home,12,0)
          assert(op.phase~='WITHDRAW' and op.strikes==1,'capable escorts fled after losing the bomber')
          escort.role='fighter'
          R:BuildAIOperations('BLUE',{escort},home,13,0)
          assert(op.phase=='WITHDRAW','fighter-only force stayed on an immune base')
        ''')

    def test_fighter_screen_stays_with_strike_when_no_suitable_hostile_remains(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        lua.execute(FIXTURE)
        lua.execute('''
          local home=makeHome(); local target=makeTarget(21,'RED',1000,0); target.station=true
          local bomber=makeGroup(1,target,'bomber',900,0,100)
          local fighter=makeGroup(2,target,'fighter',900,100,100)
          local op={phase='ENGAGE',target=target,serial=1,defenders={},groups={bomber,fighter},anchor=bomber}
          fighter.operation=op
          local t,m=R:ApplyAIOperationOrder(fighter,target,'PRIMARY',{},home,1,{})
          assert(t==bomber.units[1] and m=='ESCORT','screen was sent to an immune base instead of covering the bomber')
          op.phase='EXPLOIT'
          t,m=R:ApplyAIOperationOrder(fighter,target,'PRIMARY',{},home,2,{})
          assert(t==bomber.units[1] and m=='ESCORT','breakthrough abandoned bomber protection')
          local hostile=makeShip(30,'RED',950,0,'bomber'); op.defenders={hostile}
          t,m=R:ApplyAIOperationOrder(fighter,target,'PRIMARY',{},home,3,{})
          assert(t==hostile and m=='PRIMARY','screen failed to intercept fresh reinforcements during exploitation')
        ''')

    def test_healed_chip_damage_is_not_endless_operation_progress(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        lua.execute(FIXTURE)
        lua.execute('''
          local home=makeHome(); local target=makeTarget(21,'RED',1000,0)
          local g=makeGroup(1,target,'bomber',1000,0,100)
          R:BuildAIOperations('BLUE',{g},home,0,0)
          local op=R.AIOperations.BLUE[21]
          op.phase='ENGAGE'; op.phaseAt=0; op.engagedAt=0; op.initialValue=100; op.initialStrikes=1
          R.Config.AI.Operations.AttackSeconds=10
          target.HitpointsLeft=90; R:BuildAIOperations('BLUE',{g},home,1,0)
          target.HitpointsLeft=100; R:BuildAIOperations('BLUE',{g},home,3,0)
          target.HitpointsLeft=91; R:BuildAIOperations('BLUE',{g},home,5,0)
          target.HitpointsLeft=100; R:BuildAIOperations('BLUE',{g},home,7,0)
          target.HitpointsLeft=91; R:BuildAIOperations('BLUE',{g},home,12,0)
          assert(op.phase=='WITHDRAW','healed chip damage permanently renewed the siege')
        ''')

    # Characterizes the feint branch of UpdateFactionStrategicPlan (fs2rts_strategy.lua
    # ~1442-1449), which had no executing test. Feint state is seeded on each wing's
    # previous order; the planner then decides whether the wing taunts a decoy.
    FEINT_SEED = '''
      r:ResetCoordinatedAI()
      decoy=mkFighter('Blue Decoy',ba.createVector(0,0,0))
      feintWings={}
      for i=1,4 do
        local s=ship('Feint Wing '..i,class('SF Mara'),stations.RED.Position+ba.createVector(i*50,0,0),mn.Teams.hostile)
        s.__role='fighter'; feintWings[#feintWings+1]=s
        r.AIOrderState[s:getSignature()]={mission='PRIMARY',assignedAt=0,feintUntil=FEINT_UNTIL,
          feintTargetSignature=decoy:getSignature()}
      end
      r:InvalidateShipList()
    '''

    def test_seeded_feint_window_sends_probing_wings_to_the_decoy_with_taunt_reason(self):
        self.lua.execute(self.FEINT_SEED.replace('FEINT_UNTIL', '80') + '''
          r:UpdateFactionStrategicPlan('RED',50,true)
          for _,s in ipairs(feintWings) do
            local o=r.AIOrderState[s:getSignature()]
            assert(o.mission=='FEINT', 'an open feint window must put the probing wing on FEINT: '..tostring(o.mission))
            assert(o.targetSignature==decoy:getSignature(), 'FEINT must aim at the decoy, got '..tostring(o.targetSignature))
            assert(o.reason=='TAUNT_DECOY', 'a decoy other than the primary is reported as TAUNT_DECOY: '..tostring(o.reason))
            assert(o.feintUntil==80, 'the feint window must be carried forward')
          end
        ''')

    def test_expired_feint_window_does_not_fire_the_decoy(self):
        self.lua.execute(self.FEINT_SEED.replace('FEINT_UNTIL', '40') + '''
          r:UpdateFactionStrategicPlan('RED',50,true)
          for _,s in ipairs(feintWings) do
            local o=r.AIOrderState[s:getSignature()]
            assert(o.mission~='FEINT' and o.targetSignature~=decoy:getSignature(),
              'a feint window that ended before now must not keep baiting: '..tostring(o.mission))
          end
        ''')

    def test_dead_decoy_falls_back_to_the_primary_objective(self):
        # Pins the fallback that IS observed: a dead decoy is replaced by the primary
        # objective (GOLD, signature 3) as the feint target. A later rule then downgrades a
        # wing whose primary is a base to a home SCREEN with UNIT_CANNOT_DAMAGE_BASE. That
        # downgrade is characterized here, not endorsed: whether a fighter feint on a base
        # should screen instead is an open question for the audit report.
        self.lua.execute(self.FEINT_SEED.replace('FEINT_UNTIL', '80') + '''
          decoy.valid=false; r:InvalidateShipList()
          r:UpdateFactionStrategicPlan('RED',50,true)
          for _,s in ipairs(feintWings) do
            local o=r.AIOrderState[s:getSignature()]
            assert(o.targetSignature~=decoy:getSignature(), 'a dead decoy must not stay a target')
            assert(o.feintTargetSignature==stations.GOLD:getSignature(),
              'the feint must fall back to the primary objective: '..tostring(o.feintTargetSignature))
            assert(o.mission=='SCREEN' and o.reason=='UNIT_CANNOT_DAMAGE_BASE',
              'characterized base downgrade changed: '..tostring(o.mission)..'/'..tostring(o.reason))
          end
        ''')


if __name__ == '__main__':
    unittest.main()
