"""Lifecycle, accounting and failure-path regressions, using the Lua 5.1 harness."""
import unittest

from lupa.lua51 import LuaRuntime
from test_station import SETUP, SCRIPTS


class ReviewRegressions(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(SETUP)
        self.lua.execute('''
          r.Enabled=true; r.GameStatus='ACTIVE'; r.GoldEliminated=false
          gr={setCamera=function() end}; io.setCursorHidden=function() end
          ba.setButtonControlMode=function() end
          io.getMouseX=function() return 100 end; io.getMouseY=function() return 100 end
        ''')

    def check(self, code):
        self.lua.execute(code)

    def test_elapsed_time_never_ends_a_battle_with_opposing_stations_alive(self):
        self.check("""r.GetScenarioElapsed=function() return 100000 end
          r.GetLivingFactionKeys=function() return {"BLUE","RED","GOLD"} end
          r:EvaluateFactionVictory()
          assert(r.BattleVictor==nil and not r.PostBattleActive,"elapsed time ended an elimination battle")
          r.GetLivingFactionKeys=function() return {"BLUE"} end
          r:EvaluateFactionVictory()
          assert(r.GameStatus=="VICTORY" and r.BattleVictor=="BLUE")""")

    def test_signature_lookup_finds_same_frame_created_hulls_without_accepting_invalid_ids(self):
        self.check('''
          local fresh=ship('fresh hull',class('GTF Myrmidon'),ba.createVector(0,0,0),mn.Teams.friendly)
          mn.Ships={fresh}; r.FindShipBySignature=realFindShipBySignature
          local calls=0
          mn.getObjectFromSignature=function() calls=calls+1; return {isValid=function() return false end} end
          assert(r:FindShipBySignature(fresh:getSignature())==fresh,'created-list hull is invisible to commands until frame merge')
          local before=calls
          for _,bad in ipairs({0,-1,1.5,math.huge,0/0,2147483648,'3'}) do assert(r:FindShipBySignature(bad)==nil) end
          assert(calls==before,'invalid signature reached native integer/assert boundary')
          fresh.valid=false
          assert(r:FindShipBySignature(fresh:getSignature())==nil,'fallback revived an invalid handle')
        ''')

    def test_repeated_signature_queries_reuse_live_index_and_keep_creation_fallback(self):
        self.check('''
          local first=ship('indexed',class('GTF Myrmidon'),ba.createVector(0,0,0),mn.Teams.friendly)
          mn.Ships={first}; r.FindShipBySignature=realFindShipBySignature
          r.GetShipList=function() return mn.Ships end
          local nativeCalls=0
          mn.getObjectFromSignature=function() nativeCalls=nativeCalls+1; return {isValid=function() return false end} end
          r:InvalidateShipList()
          for i=1,100 do assert(r:FindShipBySignature(first:getSignature())==first) end
          assert(nativeCalls<=1,'live signature lookup repeats native object-list scan')
          local second=ship('same-frame external',class('GTF Myrmidon'),ba.createVector(0,0,0),mn.Teams.friendly)
          mn.Ships[#mn.Ships+1]=second
          assert(r:FindShipBySignature(second:getSignature())==second,'positive index hides same-frame external creation')
          first.valid=false; assert(r:FindShipBySignature(first:getSignature())==nil,'index revives invalid ship handle')
          r:ResetState(); assert(r.ShipSignatureIndex==nil,'restart retains indexed engine handles')
        ''')

    def test_faction_lookup_reads_team_once_and_tracks_same_frame_iff_changes(self):
        self.check('''
          local s=ship('changing IFF',class('SF Mara'),ba.createVector(0,0,0),mn.Teams.hostile)
          local current=mn.Teams.hostile; local reads=0
          s.Team=nil; setmetatable(s,{__index=function(self,key) if key=='Team' then reads=reads+1; return current end end})
          assert(r:GetFactionKey(s)=='RED')
          assert(reads==1,'faction lookup repeatedly reads native team property')
          current=mn.Teams.friendly; assert(r:GetFactionKey(s)=='BLUE','faction lookup cached stale IFF')
          s.Name=r.Config.ObserverShip; assert(r:GetFactionKey(s)==nil,'observer proxy became a combat faction')
          current=mn.Teams.neutral; assert(r:GetFactionKey(s)=='GOLD')
          s.valid=false; assert(r:GetFactionKey(s)==nil)
        ''')

    def test_reticle_identity_reads_current_team_once(self):
        self.check('''
          local s=ship('reticle',class('fighter'),ba.createVector(0,0,0),mn.Teams.neutral)
          local team=s.Team; s.Team=nil; local reads=0
          setmetatable(s,{__index=function(_,key) if key=='Team' then reads=reads+1; return team end end})
          assert(r:GetReticleFactionKey(s)=='third')
          assert(reads==1,'reticle repeatedly crosses native Team getter')
          team=mn.Teams.friendly; assert(r:GetReticleFactionKey(s)=='friendly')
          team=mn.Teams.hostile; assert(r:GetReticleFactionKey(s)=='hostile')
        ''')

    def test_local_threat_filters_distance_before_expensive_iff_queries(self):
        self.check('''
          local own=ship('own',class('GTF Myrmidon'),ba.createVector(0,0,0),mn.Teams.friendly)
          local friend=ship('friend',class('GTF Myrmidon'),ba.createVector(100,0,0),mn.Teams.friendly)
          local dry=ship('unarmed',class('SF Mara'),ba.createVector(200,0,0),mn.Teams.hostile)
          local nearest=ship('nearest',class('SF Mara'),ba.createVector(500,0,0),mn.Teams.hostile)
          local tied=ship('tied',class('SF Mara'),ba.createVector(500,0,0),mn.Teams.hostile)
          local far=ship('far',class('SF Mara'),ba.createVector(1500,0,0),mn.Teams.hostile)
          local rows={}
          for _,s in ipairs({friend,dry,nearest,tied,far}) do rows[#rows+1]={ship=s,profile={armed=s~=dry,range=2000}} end
          r.GetAISpatialCandidates=function() return rows end
          local native=r.AreEnemies; local calls=0
          r.AreEnemies=function(self,a,b) calls=calls+1; return native(self,a,b) end
          assert(r:GetFleetLocalThreat(own)==nearest,'nearest hostile/tie order changed')
          assert(calls<=2,'farther/unarmed candidates repeat IFF queries')
          nearest.HitpointsLeft=0; assert(r:GetFleetLocalThreat(own)==tied,'dead nearest contact retained')
          dry.HitpointsLeft=1000; rows[2].profile.armed=true
          assert(r:GetFleetLocalThreat(own)==dry,'closer newly armed hostile ignored')
        ''')

    def test_report_uses_cumulative_spend_and_shows_destroyed_factions(self):
        self.check('''
          r.AIEconomyFlow={BLUE={productionSpend=5,refund=0}}
          r.AIEconomyFlowCumulative={BLUE={productionSpend=2000,refund=100}}
          r.RedEliminated=true; stations.RED.valid=false; r:InvalidateShipList()
          r.AIStats.kills={BLUE={A=2},RED={A=7}}
          local report=r:BuildBattleSummary(); local red
          for _,row in ipairs(report.factions) do if row.key=='RED' then red=row end end
          assert(report.cpSpent==1900 and report.kills==2)
          assert(red and red.eliminated and red.ships==0)
        ''')

    def test_death_is_accounted_once_including_loss_and_kill_credit(self):
        self.check('''
          local victim=ship('victim',class('victim'),ba.createVector(0,0,0),mn.Teams.hostile)
          r.ShipCostMap.victim={cost=100,time=1}
          r:OnShipDeath(victim,stations.BLUE)
          local cp=r.CommandPoints
          r:OnShipDeath(victim,stations.BLUE)
          assert(r.AIStats.losses.RED.victim==1 and r.AIStats.kills.BLUE.victim==1)
          assert(r.CommandPoints==cp)
        ''')

    def test_two_death_callbacks_do_not_finalize_a_partial_outcome(self):
        self.check('''
          r.SetupOpponents={RED=true,GOLD=false}; r.GoldEliminated=true
          r:EliminateFaction('RED')
          assert(not r.PostBattleActive,'first callback finalized an incomplete frame')
          r:EliminateFaction('BLUE'); r:EvaluateFactionVictory()
          assert(r.BattleVictor=='NONE' and r.PostBattleResult:find('MUTUAL'))
        ''')

    def test_restart_clears_camera_gestures_and_ui_sample_clocks(self):
        self.check('''
          r.BattleCamActive=true; r.FreeCamActive=true; r.BattleCamSignature=123
          r.MapWindowDrag={}; r.MapPanDrag={}; r.SwallowMouseRelease=true
          r.TopBarCounters={at=9999,fleet=50}; r.HoverReadout={ship=stations.BLUE}
          r.OrderPing={untilTime=9999}; r:ResetState()
          assert(not r.BattleCamActive and not r.FreeCamActive and r.BattleCamSignature==nil)
          assert(r.MapWindowDrag==nil and r.MapPanDrag==nil and not r.SwallowMouseRelease)
          assert(r.TopBarCounters==nil and r.HoverReadout==nil and r.OrderPing==nil)
        ''')

    def test_shutdown_releases_planning_and_pilot_handles(self):
        self.check('''
          local names={'StrategicThreatSnapshot','AISpatialGrid','AIShipIndex','AIProfileIndex',
            'AITargetedBy','PilotTurretGroups','PilotBatteryCandidates','PilotNativeWing','PilotPreviousUserOrder','RTSWings',
            'AIStrategicPlanQueue','ControlInfo','MoveTurretLocks'}
          for _,key in ipairs(names) do r[key]={ship=stations.BLUE} end
          r:ReleaseObjectHandles()
          for _,key in ipairs(names) do assert(r[key]==nil or next(r[key])==nil,key..' retained a handle') end
        ''')

    def test_modified_key_release_keeps_physically_held_modifiers(self):
        self.check('''
          r.KeyDown={A=true}; r.FastKeyDown={}; r.ShiftDown=true; r.CtrlDown=true; r.AltDown=true
          r:OnKeyReleased('Alt-Shift-Ctrl-A','A')
          assert(r.ShiftDown and r.CtrlDown and r.AltDown and not r.KeyDown.A)
          r:OnKeyReleased('Left Shift','Left Shift'); assert(not r.ShiftDown)
        ''')

    def test_absolute_speed_key_resumes_pause_and_is_overridden(self):
        self.check('''
          r:SetPaused(true); r:OnKeyPressed('Alt-0','0')
          assert(not r.Paused and r.TimeScale==16)
          assert(r:ShouldOverrideKey('Alt-0','0') and not r:ShouldOverrideKey('0','0'))
        ''')

    def test_shift_group_digits_are_swallowed_in_rts_mode(self):
        self.check('''
          for i=1,4 do
            local digit=tostring(i)
            assert(r:ShouldOverrideKey('Shift-'..digit,digit),'control group key leaked: '..digit)
          end
        ''')

    def test_paused_step_buttons_change_resume_speed_without_running_engine(self):
        self.check('''
          r:SetTimeScale(2); r:SetPaused(true); r:StepTimeScale(1)
          assert(r.Paused and r.TimeScale==0 and r.PausedTimeScale==4)
          r:SetPaused(false); assert(r.TimeScale==4)
        ''')

    def test_auto_production_stops_after_elimination_while_station_handle_is_valid(self):
        self.check('''
          r.AIStates.RED.eliminated=true; r.AIStates.RED.income=10; r.AIStates.RED.lastIncome=0
          r.AIStates.GOLD.eliminated=true
          r.AIStates.RED.queue={entry={class='bad'},estimate={cost=100},count=1,finishTime=1}
          local cp=r.AIStates.RED.cp; local spawns=0
          r.SpawnAIProduction=function() spawns=spawns+1 end
          r:UpdateAIProduction(2)
          assert(spawns==0 and r.AIStates.RED.cp==cp)
        ''')

    def test_postbattle_exits_hidden_ui_camera(self):
        self.check('''
          r.FreeCamActive=true; r.BattleCamActive=true
          r.UpdateCameraTransform=function() end
          r:OpenPostBattle('test')
          assert(not r.FreeCamActive and not r.BattleCamActive and r.PostBattleActive)
        ''')

    def test_escape_resumes_rts_and_exits_paused_pilot_without_hiding_alt_menu(self):
        self.check('''
          r.Paused=false; r:OnKeyPressed('Esc','Esc')
          assert(not r.Paused and r.ExitMenuActive and r:ShouldOverrideKey('Esc','Esc'),'RTS Escape did not open exit menu')
          r:HandleExitMenuAction('resume')
          r.Paused=true
          r:OnKeyPressed('Esc','Esc')
          assert(not r.Paused and r.ExitMenuActive and r:ShouldOverrideKey('Esc','Esc'),'Escape did not restore paused RTS before opening menu')
          r:HandleExitMenuAction('resume')
          r.PossessedSignature=123; r.Paused=true
          r.TogglePilotMode=function(self) self.PossessedSignature=nil end
          r:OnKeyPressed('Esc','Esc')
          assert(not r.Paused and r.PossessedSignature==nil and r:ShouldOverrideKey('Esc','Esc'),
            'Escape did not resume and exit a paused pilot view')
          r:OnKeyPressed('Alt-Esc','Esc')
          assert(not r:ShouldOverrideKey('Alt-Esc','Esc'),'Alt+Escape no longer reaches the native menu')
        ''')

    def test_cinematic_skip_click_cannot_start_setup_on_release(self):
        self.check('''
          bit={checkBit=function() return true end}
          r.CinematicActive=true; r.SetupActive=true
          r.EndIntroCinematic=function(self) self.CinematicActive=false end
          r.DisarmObserverWeapons=function() end
          r.HandleSetupClick=function() error('skip click reached setup') end
          r:OnMousePressed(1); r:OnMouseReleased(1)
        ''')

    def test_ai_partial_spawn_refunds_missing_hulls_once(self):
        self.check('''
          r.AIStates={RED={cp=800,income=0,lastIncome=0,nextThink=99,serial=0,
            queue={entry={class='test',tier=1},count=2,estimate={cost=200},finishTime=1}}}
          r.SpawnAIProduction=function(self,kind,queued,created)
            local s=ship('created',class('test'),ba.createVector(0,0,0),mn.Teams.hostile)
            created[#created+1]=s; error('injected failure after creation')
          end
          r:UpdateAIProduction(2); r:UpdateAIProduction(3)
          assert(r.AIStates.RED.cp==900 and r.AIStates.RED.queue==nil)
        ''')

    def test_missing_audio_does_not_use_fsos_fatal_error_forwarder(self):
        self.check('''
          ad=nil; r.MusicMuted=false
          error=function() assert(false,'FSO fatal error forwarder reached') end
          assert(r:SetMusicMuted(true)==false and not r.MusicMuted)
        ''')

    def test_upstream_version_does_not_claim_the_custom_damage_hook(self):
        self.check('''
          ba.isEngineVersionAtLeast=function() return true end
          engine={addHook=function(name) assert(name~='On Ship Damage','unknown upstream hook registered') end}
          r.Config.AI.ExperimentalDamageTelemetry=true
          r:ResetCoordinatedAI(); r.ResolvedDamageTelemetryAvailable=nil
          assert(not r:SupportsResolvedDamageTelemetry())
          r:RegisterBaseDamageTelemetry(); r:RegisterCombatDamageTelemetry()
          assert(r.BaseDamageTelemetry.hookCount==0 and not r.CombatDamageTelemetry.registered)
        ''')

    def test_station_beam_range_uses_weapon_data_without_role_lookup(self):
        self.check('''
          r.GetShipRole=function() assert(false,'role lookup must remain pure config') end
          for _,species in pairs(r.Config.Species) do
            local name=species.stationClass
            local s=ship('arbitrary mission name',class(name),ba.createVector(0,0,0),mn.Teams.friendly)
            s.PrimaryBanks={{AmmoMax=0,isValid=function() return true end,WeaponClass={Range=4000,Speed=1600,LifeMax=25,Damage=10,
              FireWait=1,isValid=function() return true end,isBeam=function() return true end}}}
            s.SecondaryBanks={}; s[1]=nil
            local _,_,beam,range=r:GetStrategicWeapons(s)
            assert(beam and range==4000,'station class used a role estimate instead of native beam reach: '..name)
          end
        ''')

    def test_cinematic_cursor_does_not_enable_mouse_flight_controls(self):
        self.check('''
          local hidden
          io.setCursorHidden=function(value) hidden=value end
          r.PossessedSignature=nil; r.CinematicActive=true; r:EnforceCursorState()
          assert(hidden and io.MouseControlStatus==false,'cinematic enabled mouse flight controls')
          r.CinematicActive=false; r:EnforceCursorState()
          assert(not hidden and io.MouseControlStatus==false)
          r.PossessedSignature=123; r:EnforceCursorState()
          assert(hidden and io.MouseControlStatus==true)
        ''')

    def test_cursor_enforcement_only_writes_mouse_flight_mode_on_change(self):
        self.check('''
          local mode,writes,held=false,0,true
          io=setmetatable({setCursorHidden=function() end},{
            __index=function(_,key) if key=='MouseControlStatus' then return mode end end,
            __newindex=function(_,key,value)
              assert(key=='MouseControlStatus'); mode=value; writes=writes+1; held=false
            end})
          r.PossessedSignature=nil; r.CinematicActive=false
          r:EnforceCursorState(); r:EnforceCursorState()
          assert(writes==0 and held,'unchanged mode flushed held mouse input')
          r.PossessedSignature=123; r:EnforceCursorState()
          assert(writes==1 and mode)
          held=true; r:EnforceCursorState()
          assert(writes==1 and held,'pilot frame flushed held mouse input')
          mode=false; r:EnforceCursorState()
          assert(writes==2 and mode,'native mode drift was not repaired')
        ''')

    def test_dead_wings_retire_without_losing_living_members_or_target_retargeting(self):
        self.check('''
          for cycle=1,200 do
            local a=ship('wing a',class('fighter'),ba.createVector(0,0,0),mn.Teams.hostile)
            local b=ship('wing b',class('fighter'),ba.createVector(100,0,0),mn.Teams.hostile)
            local wing=r:RegisterLogicalWing({a,b},'temporary')
            r:OnShipDeath(a,nil)
            assert(r.RTSWings[wing.id]==wing and #wing.signatures==1 and wing.signatures[1]==b:getSignature(),
              'death retains expired wing members or loses survivors')
            assert(r:GetLogicalWing(b)==wing)
            local order={targetWing=wing.id,targetSignature=a:getSignature()}
            assert(r:ResolveAttackWingTarget(order,a:getSignature())==b,'wing target did not advance to surviving member')
            r:OnShipDeath(b,nil); r:OnShipDeath(b,nil)
            assert(r.RTSWings[wing.id]==nil,'extinct wing survives indefinitely')
            assert(r:ResolveAttackWingTarget(order)==nil,'extinct wing kept an attack target')
          end
          assert(next(r.RTSWings)==nil,'wing registry grows with lifetime production')
        ''')

    def test_disabled_cohesion_trace_does_not_walk_ship_geometry(self):
        self.check('''
          r.CombatTelemetryEnabled=true; r.Config.AI.TraceFileEnabled=false; r.AITraceFile=nil; r.AIEventSink=nil
          local s=ship('trace contact',class('fighter'),ba.createVector(0,0,0),mn.Teams.friendly)
          local position=s.Position; s.Position=nil
          setmetatable(s,{__index=function(_,key) if key=='Position' then assert(false,'disabled trace walks geometry') end end})
          r:EmitAICohesion('BLUE',{{id='wing',units={s},value=10}},nil,nil,10)
          r:EmitContestRecord('BLUE',{{id='wing',units={s},target=stations.RED,value=10}},nil,nil,10)
          s.Position=position; local records={}; r.AIEventSink=function(record) records[#records+1]=record end
          r:EmitAICohesion('BLUE',{{id='wing',units={s},value=10}},nil,nil,10)
          assert(#records==1 and records[1].data.nodeCount==1,'enabling trace suppresses first real sample')
          r:EmitContestRecord('BLUE',{{id='wing',units={s},target=stations.RED,value=10}},nil,nil,10)
          assert(#records==2 and records[2].event=='CONTEST','enabling contest trace suppresses first sample')
        ''')

    def test_contest_progress_is_bounded_to_present_groups_per_faction(self):
        self.check('''
          r.CombatTelemetryEnabled=true; local records={}; r.AIEventSink=function(record) records[#records+1]=record end
          r.Config.AI.ContestSampleSeconds=1
          local s=ship('contest lead',class('fighter'),ba.createVector(0,0,0),mn.Teams.friendly)
          local target=stations.RED
          local group={id='alive',units={s},target=target,mission='PRIMARY',value=10}
          r:EmitContestRecord('GOLD',{group},nil,target,0)
          for cycle=1,200 do
            group.id='cycle'..cycle
            r:EmitContestRecord('BLUE',{group},nil,target,cycle)
          end
          local count=0; for _ in pairs(r.AIContestProgress) do count=count+1 end
          assert(count==2,'contest progress retains every extinct group')
          assert(r.AIContestProgress['GOLD/alive'],'cleanup removed another faction history')
          r:EmitContestRecord('BLUE',{group},nil,target,240)
          assert(records[#records].data.worstStallSeconds>=40,'live stall history was reset')
          r:EmitContestRecord('BLUE',{},nil,target,241)
          assert(r.AIContestProgress['BLUE/cycle200']==nil)
        ''')

    def test_local_queries_share_context_iff_but_recheck_changed_teams(self):
        self.check('''
          local a=ship('context owner',class('fighter'),ba.createVector(0,0,0),mn.Teams.friendly)
          local b=ship('context enemy',class('fighter'),ba.createVector(500,0,0),mn.Teams.hostile)
          r.StrategicThreatSnapshot={{ship=a,mounts={},maxRange=2000,armed=true,profileBeam=false,firepower=10},
            {ship=b,mounts={},maxRange=2000,armed=true,profileBeam=false,firepower=10}}
          r:BuildAIContext(r.StrategicThreatSnapshot)
          local native=r.AreEnemies; local checks=0
          r.AreEnemies=function(self,x,y) checks=checks+1; return native(self,x,y) end
          assert(r:GetFleetLocalThreat(a)==b)
          local _,enemy=r:AILocalStrength(a,a.Position,1000,false); assert(enemy>0)
          assert(checks==0,'context repeats IFF relation work for every local pair')
          b.Team=mn.Teams.friendly
          assert(r:GetFleetLocalThreat(a)==nil,'same-context IFF change kept a hostile target')
          r.AILocalCache={}; local _,none=r:AILocalStrength(a,a.Position,1000,false)
          assert(none==0 and checks>0,'changed native team did not fall back to live hostility')
          a.Team=mn.Teams.hostile; r.AILocalCache={}
          assert(r:GetFleetLocalThreat(a)==b,'changed owner team retained old relations')
        ''')

    def test_context_iff_keeps_asymmetric_and_unknown_team_relations(self):
        self.check('''
          local custom={Name='custom',isValid=function() return true end,attacks=function() return false end}
          mn.Teams.friendly.attacks=function(self,other) return other==custom end
          local a=ship('known owner',class('fighter'),ba.createVector(0,0,0),mn.Teams.friendly)
          local b=ship('unknown owner',class('fighter'),ba.createVector(500,0,0),custom)
          local rows={{ship=a,mounts={},maxRange=2000,armed=true,profileBeam=false,firepower=10},
            {ship=b,mounts={},maxRange=2000,armed=true,profileBeam=false,firepower=10}}
          r.StrategicThreatSnapshot=rows; r:BuildAIContext(rows)
          assert(r:AIContextEnemies(a,rows[2],'BLUE',a.Team),'known faction lost native asymmetric hostility')
          assert(not r:AIContextEnemies(b,rows[1],nil,b.Team),'unknown faction acquired invented symmetric hostility')
          assert(not r:AIContextEnemies(a,rows[1],'BLUE',a.Team),'explicit false relation fell through')
        ''')

    def test_strength_queries_reuse_context_geometry_and_refresh_next_pass(self):
        self.check('''
          local a=ship('owner',class('fighter'),ba.createVector(0,0,0),mn.Teams.friendly)
          local b=ship('enemy',class('fighter'),ba.createVector(500,0,0),mn.Teams.hostile)
          local position=b.Position; b.Position=nil; local reads=0
          setmetatable(b,{__index=function(_,key) if key=='Position' then reads=reads+1; return position end end})
          local function context()
            r.StrategicThreatSnapshot={{ship=a,mounts={},maxRange=2000,armed=true,profileBeam=false,firepower=10},
              {ship=b,mounts={},maxRange=2000,armed=true,profileBeam=false,firepower=10}}
            r:BuildAIContext(r.StrategicThreatSnapshot)
          end
          context(); reads=0
          local _,enemy=r:AILocalStrength(a,a.Position,1000,false)
          assert(enemy>0)
          assert(r:GetFleetLocalThreat(a)==b)
          assert(reads==0,'snapshot queries repeat native Position reads')
          position=ba.createVector(10000,0,0); context()
          local _,far=r:AILocalStrength(a,a.Position,1000,false)
          assert(far==0 and r:GetFleetLocalThreat(a)==nil,'geometry did not refresh at next context')
        ''')

    def test_hostility_reads_each_team_once_before_faction_validation(self):
        self.check('''
          local a=ship('a',class('fighter'),ba.createVector(0,0,0),mn.Teams.friendly)
          local b=ship('b',class('fighter'),ba.createVector(100,0,0),mn.Teams.hostile)
          local reads=0
          local team=b.Team; b.Team=nil
          setmetatable(b,{__index=function(_,key) if key=='Team' then reads=reads+1; return team end end})
          assert(r:AreEnemies(a,b))
          assert(reads<=2,'hostility repeats native Team reads')
          team=mn.Teams.friendly; assert(not r:AreEnemies(a,b))
          team=nil; assert(not r:AreEnemies(a,b))
          team={isValid=function() return false end}; assert(not r:AreEnemies(a,b))
        ''')

    def test_dedicated_pause_is_swallowed_with_native_pause_policy_disabled(self):
        self.check('''
          r.Config.AI.DisableMissionPause=false
          r.SetupActive=false; r.CinematicActive=false; r.PostBattleActive=false
          r:OnKeyPressed('Pause','Pause')
          assert(r.Paused and r:ShouldOverrideKey('Pause','Pause'),
            'dedicated pause also reached the native menu')
          assert(not r:ShouldOverrideKey('Alt-Pause','Pause'),'native menu shortcut was swallowed')
        ''')

    def test_native_menu_round_trip_keeps_the_rts_session_alive(self):
        self.check('''
          local shutdowns=0
          r.Shutdown=function(self) shutdowns=shutdowns+1; self.Enabled=false end
          for _,menu in ipairs({'GS_STATE_GAME_PAUSED','GS_STATE_OPTIONS_MENU',
            'GS_STATE_CONTROL_CONFIG','GS_STATE_HUD_CONFIG','GS_STATE_GAMEPLAY_HELP'}) do
            r.Enabled=true
            r:OnStateEnd({Name='GS_STATE_GAME_PLAY'},{Name=menu})
            r:OnStateEnd({Name=menu},{Name='GS_STATE_GAME_PLAY'})
            assert(r.Enabled and shutdowns==0,'return from '..menu..' shut the session down')
          end
          r:OnStateEnd({Name='GS_STATE_GAME_PLAY'},{Name='GS_STATE_DEBRIEF'})
          assert(shutdowns==1 and not r.Enabled,'terminal state failed to shut down')
        ''')

    def test_startup_focus_policy_keeps_intro_running_without_blocking_setup_menus(self):
        self.check('''
          r.SetupActive=true; r.CinematicActive=true; r.PostBattleActive=false
          local focus=true; local previous={Serialized='true'}; local disabled={Serialized='false'}
          local option={Key='Game.UnfocusedPause',Value=previous,getValidValues=function() return {previous,disabled} end}
          opt={Options={option}}
          r:OnStateStart({Name='GS_STATE_BRIEFING'},{Name='GS_STATE_GAME_PLAY'})
          assert(option.Value==disabled,'startup restores focus pause before START')
          assert(not r:IsMissionPauseDisabled(),'startup blocks intentional native menus')
          r:OnStateStart({Name='GS_STATE_GAME_PLAY'},{Name='GS_STATE_OPTIONS_MENU'})
          assert(option.Value==previous,'mission override leaked into options')
          r:OnStateStart({Name='GS_STATE_OPTIONS_MENU'},{Name='GS_STATE_GAME_PLAY'})
          assert(option.Value==disabled,'returning to setup loses the focus override')
          r:SetMissionFocusPolicy(false); assert(option.Value==previous)
        ''')

    def test_native_menu_cancels_gestures_whose_releases_it_consumes(self):
        self.check('''
          r.KeyDown={W=true}; r.FastKeyDown={W=true}; r.ShiftDown=true
          r.RightDrag={}; r.MovePreview={}; r.MapWindowDrag={}
          local intent={kind='hold'}; r.UserOrders[123]=intent
          r:OnStateEnd({Name='GS_STATE_GAME_PLAY'},{Name='GS_STATE_GAME_PAUSED'})
          assert(next(r.KeyDown)==nil and next(r.FastKeyDown)==nil and not r.ShiftDown,
            'native menu retained keys whose releases cannot reach gameplay hooks')
          assert(r.RightDrag==nil and r.MovePreview==nil and r.MapWindowDrag==nil)
          assert(r.UserOrders[123]==intent,'input cleanup discarded a committed order')
        ''')

    def test_move_turret_lock_restores_native_locks_instead_of_unlocking_everything(self):
        self.check('''
          local s=ship('moving capital',class('capital'),ba.createVector(0,0,0),mn.Teams.friendly)
          local a,b=s[1],{isValid=function() return true end,isTurret=function() return true end,TurretLocked=true}
          a.TurretLocked=false; s[2]=b
          r:SetShipTurretLock(s,true); r:SetShipTurretLock(s,true)
          assert(a.TurretLocked and b.TurretLocked)
          r:SetShipTurretLock(s,false)
          assert(not a.TurretLocked and b.TurretLocked,'move completion released a native turret lock')
          r:SetShipTurretLock(s,false)
          assert(b.TurretLocked,'repeated unlock discarded a native lock')
        ''')

    def test_player_spawn_exception_keeps_created_hulls_paid_and_is_not_retried(self):
        self.check('''
          r.GetSpawnFrame=function() return ba.createVector(0,0,0),{} end
          r.ApplyPolicyToShip=function() error('injected order failure') end
          local c=class('test production'); r.ShipCostMap[c.Name]={cost=100,time=1}
          local option={class=c.Name,label=c.Name,count=2,cost=200,time=1,tier=1}
          r.BuildQueue={{option=option,started=true,startTime=0,finishTime=1}}
          r.CommandPoints=800; local before=#ships
          r:UpdateBuildQueue(2); r:UpdateBuildQueue(3)
          assert(#ships==before+2 and #r.BuildQueue==0 and r.CommandPoints==800)
        ''')

    def test_rejected_spawn_never_calls_native_creation_and_refunds_once(self):
        self.check('''
          r.GetSpawnFrame=function() return nil,nil end
          local c=class('blocked production'); r.ShipCostMap[c.Name]={cost=100,time=1}
          local option={class=c.Name,label=c.Name,count=2,cost=200,time=1,tier=1}
          r.BuildQueue={{id=12,option=option,started=true,startTime=0,finishTime=1}}
          r.CommandPoints=800; local before=#ships
          r:UpdateBuildQueue(2); r:UpdateBuildQueue(3)
          assert(#ships==before and #r.BuildQueue==0 and r.CommandPoints==1000)
          assert(r:SpawnFactionUnit(c.Name,stations.RED,stations.RED.Team,'blocked',1,1)==nil)
          assert(#ships==before)
        ''')

    def test_congested_geometry_is_rejected_then_recovers_when_blocker_clears(self):
        self.check('''
          local c=class('spawn geometry control')
          local blocker=ship('huge blocker',c,stations.BLUE.Position,stations.BLUE.Team)
          blocker.Radius=100000
          r.GetLivingFactionKeys=function() return {'BLUE'} end
          local pos=r:NativeGetSpawnFrame(stations.BLUE,c,1,1,1)
          assert(pos==nil,'congested geometry returned a knowingly obstructed slot')
          blocker.valid=false; r:InvalidateShipList()
          pos=r:NativeGetSpawnFrame(stations.BLUE,c,1,1,1)
          assert(pos and pos:getDistance(stations.BLUE.Position)>=450,'clear control failed')
        ''')

    def test_capital_spawn_stays_within_reach_and_takes_the_nearest_legal_slot(self):
        """The clearance sweep searched angle-first, so a legal point at 3.2x the
        ring radius (about 9 km out, behind the station) beat a legal point a few
        hundred metres away on another bearing. A capital must stay inside the reach
        its own station allows, and the nearest legal slot wins."""
        self.check('''
          local c=class('reach capital'); c.Model.Radius=1500
          r.GetLivingFactionKeys=function() return {'BLUE','RED'} end
          -- Close enough that every slot inside the reach is inside the enemy separation.
          stations.RED.Position=ba.createVector(3000,0,0)
          local cap=r.Config.CapitalSpawn
          local anchorR=stations.BLUE.Class.Model and stations.BLUE.Class.Model.Radius or 500
          local bound=math.min(cap.MaxStationRadius or 9000,anchorR+c.Model.Radius
            +(r.Config.Formation.SpawnForwardClearance or 1100)+(cap.ForwardBias or 0.35)*c.Model.Radius*(cap.MaxStationRadiusFactor or 2.4))
          local placed=r:NativeGetSpawnFrame(stations.BLUE,c,1,1,1)
          assert(placed,'a capital with a legal in-reach slot was refused')
          local away=placed:getDistance(stations.BLUE.Position)
          assert(away<=bound+1,'capital spawned '..away..' m from its station, beyond its reach of '..bound)
          assert(placed:getDistance(stations.RED.Position)>=r:GetEnemyBaseSeparation()-1,'capital spawned inside the enemy separation')
        ''')

    def test_capital_search_skips_outside_arena_candidates_for_a_clear_alternate(self):
        self.check('''
          local c=class('edge capital'); c.Model.Radius=1500
          r.GetLivingFactionKeys=function() return {'BLUE'} end
          r.GetCommandArenaHalfExtent=function() return 10000 end
          assert(r:NativeGetSpawnFrame(stations.BLUE,c,1,1,1),'central placement control failed')
          stations.BLUE.Position=ba.createVector(9900,0,0)
          local legal=ba.createVector(9900,0,2700)
          assert(select(2,r:ClampCommandPoint(legal,0))==false)
          for _,other in ipairs(ships) do
            assert(legal:getDistance(other.Position)>1500+(other.Radius or 100)+250)
          end
          local placed=r:NativeGetSpawnFrame(stations.BLUE,c,1,1,1)
          assert(placed,'an outside-arena candidate discarded a legal alternate')
          assert(select(2,r:ClampCommandPoint(placed,0))==false)
          for _,other in ipairs(ships) do
            assert(placed:getDistance(other.Position)>=1500+(other.Radius or 100)+250)
          end
        ''')

    def test_withdrawal_blocks_orders_after_a_successful_native_order_control(self):
        self.check('''
          local s=ship('withdrawal control',class('GTB Medusa'),pos,mn.Teams.friendly)
          r.IsPursuitPair=function() return false end
          assert(r:IssueStrategicOrder(s,stations.RED,'control','PRIMARY',0,true))
          local previous=r.AIOrderState[s.signature]; local clears=0
          s.clearOrders=function() clears=clears+1 end
          r.IsShipWithdrawing=function(self,unit) return unit==s end
          assert(r:IssueStrategicOrder(s,stations.GOLD,'blocked','PRIMARY',1,true)==false)
          assert(clears==0 and r.AIOrderState[s.signature]==previous)
        ''')

    def test_same_frame_queue_admission_has_unique_persistent_job_ids(self):
        self.check('''
          local c=class('queued job control')
          local option={class=c.Name,label=c.Name,count=1,cost=100,time=1,tier=1}
          r.CountCommittedCombatants=function() return 0 end
          local events={}; r.EmitAIEvent=function(self,event,data) events[#events+1]=data end
          r:QueueBuildOption(option); r:QueueBuildOption(option)
          assert(#r.BuildQueue==2 and r.BuildQueue[1].id~=r.BuildQueue[2].id)
          assert(events[1].jobId==r.BuildQueue[1].id and events[2].jobId==r.BuildQueue[2].id)
        ''')

    def test_capital_subsystem_controls_accept_non_ship_targets_without_length_queries(self):
        self.check('''
          local weapon=newproxy(true); local meta=getmetatable(weapon)
          meta.__index={isValid=function() return true end,getBreedName=function() return 'Weapon' end}
          meta.__len=function() assert(false,'weapon queried as a subsystem list') end
          assert(r:ResolvePilotTargetSubsystemIndex(weapon)==0)
          stations.BLUE.Target=weapon; r.GetPossessedShip=function() return stations.BLUE end
          assert(not r:CyclePilotTargetSubsystem(1))
        ''')


if __name__ == '__main__':
    unittest.main()
