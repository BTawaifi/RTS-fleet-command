"""Guards for RTS:StartScenario (fs2rts_lifecycle.lua) run as real code.

Other suites replace StartScenario with stubs, so the real body was never executed.
This file runs it with the shipped module and stubs only the collaborators named in
STUBS, each of which has its own coverage elsewhere. Asserts pin the setup gates,
the economy and roster handoff, and the failure status for a station-spawn error.

Run: cd core/tools && python -m pytest test_scenario_start.py -q
"""
import unittest
from lupa.lua51 import LuaRuntime

from test_station import SETUP, SCRIPTS

# Collaborators replaced by recorders. Each call is counted by name in r.calls.
RECORDED = '''
FinishRosterModelWarmup ResolveRandomFactionSpecies BuildProductionCatalog
ApplyConfiguredBaseSpacing ResetFleetLife ScaleCommandStationsForEscalation
CaptureBaseHullBaseline CreateOptionalAsteroidField ResetStationState
InitializeAIStates InitializeUnitOrders SetTimeScale SetMusicMuted
RegisterBaseDamageProtection RegisterBaseDamageTelemetry RegisterCombatDamageTelemetry
RegisterStationBeamHitHook StartAITrace SetMissionFocusPolicy UpdateFactionCount
ClearSetupBackdrop CreateSetupBackdrop
'''

STUBS = '''
calls={}
for name in string.gmatch(RECORDED_NAMES, "%S+") do
  r[name]=function() calls[name]=(calls[name] or 0)+1 end
end
r.DisableFactionShips=function(self,kind) calls.DisableFactionShips=(calls.DisableFactionShips or 0)+1; disabled=kind end
r.SetFactionEliminated=function(self,kind,value) eliminated[kind]=value end
r.SetStatus=function(self,text,seconds) statuses[#statuses+1]={text=text,seconds=seconds} end
r.ShowAnnouncement=function(self,text) announcements[#announcements+1]=text end
r.UINow=function() return 100 end
r.GetEscalationProfile=function() return {playerIncomeScale=2} end
r.GetFactionDisplayName=function(self,kind) return 'NTF' end
r.GetFactionKeys=function() return {'BLUE','RED'} end
r.GetFactionDefinition=function(self,kind) return {team=kind=='BLUE' and 'friendly' or 'enemy'} end
r.IsFactionEnabled=function(self,kind) return kind=='BLUE' end
r.SpawnFactionStations=function(self) calls.SpawnFactionStations=(calls.SpawnFactionStations or 0)+1; return spawnOk end
mn.Teams.friendly={isValid=function() return true end}
mn.Teams.enemy={isValid=function() return true end}
'''


class StartScenarioTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(SETUP)
        self.lua.globals().RECORDED_NAMES = RECORDED
        self.lua.execute('''
          eliminated={}; statuses={}; announcements={}; disabled=nil; spawnOk=true
          r.Config.FactionOrder={'BLUE','RED'}
          r.Config.Setup.Economies={{startCP=5000,income=20}}
          r.SetupEconomyIndex=1; r.SetupFactionCount=2; r.SetupActive=true
          r.SetupAutoMode=false; r.SetupSentries=nil
        ''')
        self.lua.execute(STUBS)

    def check(self, code):
        self.lua.execute(code)

    def test_inactive_setup_is_a_no_op(self):
        self.check('''
          r.SetupActive=false
          r:StartScenario()
          assert(next(calls)==nil, 'a started scenario must not run any start step')
          assert(#statuses==0 and r.GameStatus=='SETUP')
        ''')

    def test_fewer_than_two_factions_stays_in_setup_with_a_status(self):
        self.check('''
          r.SetupFactionCount=1
          r:StartScenario()
          assert(r.SetupActive==true and r.GameStatus=='SETUP')
          assert(statuses[#statuses].text=='Select at least one enemy faction' and statuses[#statuses].seconds==3)
          assert(calls.SpawnFactionStations==nil, 'no station may spawn before the faction gate passes')
        ''')

    def test_unavailable_team_identity_blocks_start_and_names_the_team(self):
        self.check('''
          mn.Teams.enemy=nil
          r:StartScenario()
          assert(r.SetupActive==true and r.GameStatus=='SETUP')
          assert(statuses[#statuses].text=='Faction IFF unavailable: enemy' and statuses[#statuses].seconds==5)
          assert(calls.SpawnFactionStations==nil)
        ''')

    def test_successful_start_applies_economy_roster_and_auto_mode(self):
        self.check('''
          r.SetupAutoMode=true
          r:StartScenario()
          assert(r.SetupActive==false and r.GameStatus=='ACTIVE')
          assert(r.CommandPoints==5000, 'starting CP comes from the chosen economy')
          assert(r.ActiveIncomePerSecond==40, 'income scales by the escalation profile: '..tostring(r.ActiveIncomePerSecond))
          assert(r.AutoPlayerMode==true and r.StatusMessage=='ESCALATION STARTED // NTF AUTO MODE')
          assert(disabled=='RED', 'only disabled factions lose their ships, got '..tostring(disabled))
          assert(eliminated.RED==true and eliminated.BLUE==false, 'elimination follows enablement')
          assert(calls.SpawnFactionStations==1 and calls.InitializeAIStates==1 and calls.ResetFleetLife==1)
          assert(r.ScenarioStartTime==mn.getMissionTime() and r.StatusUntil==106, 'status timer runs 6 s from UINow')
          assert(r.CombatTelemetryEnabled==true, 'combat telemetry is armed on start')
          assert(announcements[#announcements]=='TIER 1 // ESCALATION BEGINS')
        ''')

    def test_manual_start_uses_the_plain_status_message(self):
        self.check('''
          r:StartScenario()
          assert(r.AutoPlayerMode==false and r.StatusMessage=='ESCALATION STARTED')
        ''')

    def test_start_vanishes_the_setup_backdrop_before_the_bases_spawn(self):
        self.check('''
          order={}
          r.ClearSetupBackdrop=function() order[#order+1]='clear' end
          r.SpawnFactionStations=function() order[#order+1]='spawn'; return true end
          r:StartScenario()
          assert(order[1]=='clear' and order[2]=='spawn', 'backdrop must clear before spawning: '..table.concat(order,','))
        ''')

    def test_station_spawn_failure_keeps_setup_open_and_reports_it(self):
        self.check('''
          spawnOk=false
          r:StartScenario()
          assert(r.SetupActive==true and r.GameStatus=='SETUP', 'a failed spawn must not start the battle')
          assert(statuses[#statuses].text=='Could not initialize every command station' and statuses[#statuses].seconds==5)
          assert(calls.CreateSetupBackdrop==1, 'a failed start must put the setup backdrop back')
          assert(calls.ResetFleetLife==nil and calls.InitializeAIStates==nil,
            'no post-spawn start step may run after a failed spawn')
          -- Characterized, not endorsed: the economy is assigned before the spawn step, so a
          -- failed attempt leaves starting CP applied. A retry overwrites it with the same value.
          assert(r.CommandPoints==5000)
        ''')


if __name__ == "__main__":
    unittest.main()
