"""The stager must copy runtime data only and refuse existing snapshots."""
import tempfile
import unittest
from pathlib import Path

import prepare_headless_batch as stage


class StagingTests(unittest.TestCase):
    def test_exact_faction_array_roundtrips_and_driver_preserves_slot_identity(self):
        from lupa.lua51 import LuaRuntime
        choices=['NTF','GTVA','GTA','SHIVAN']
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'batch_setup.lua'
            fields=stage.write_batch_setup(path,'default','star',True,False,choices)
            lua=LuaRuntime()
            actual=lua.execute(path.read_text())
            self.assertEqual(fields['factionChoices'],choices)
            self.assertEqual(list(actual['factionChoices'].values()),choices)
            self.assertEqual(actual['factions'],4)
            for bad in ([],['GTA'],['GTA']*13,['GTA','NOT_REAL']):
                with self.assertRaises(ValueError): stage.write_batch_setup(path,'default',faction_choices=bad)
            with self.assertRaises(ValueError): stage.write_batch_setup(path,'gta-shivans',faction_choices=choices)
        lua.globals().setup=actual
        lua.execute('''
          cf={openFile=function() return {isValid=function() return true end,write=function() end,flush=function() end} end}
          mn={getMissionTime=function() return 0 end}
          local keys={'BLUE','RED','GOLD','TEAM04'}
          R={SetupActive=true,choices={},Config={AI={},Cinematic={},Setup={DefaultBaseDistance=2,BaseLayouts={{id='STAR'}}}},
            ApplyConfiguredBaseSpacing=function() end,InitializeAIStates=function(self) self.AIStates={} end,
            OnFrame=function() end,UpdateFactionCount=function(self) self.SetupFactionCount=self.SetupFactionCountChoice end,
            GetFactionKeys=function() return keys end,SetFactionChoice=function(self,k,v) self.choices[k]=v end,
            GetFactionChoice=function(self,k) return self.choices[k] end,
            GetFactionCommandShip=function() return nil end,
            GetEscalationProfile=function() return {tierUnlocks={}} end,EmitAIEvent=function() end}
          R.StartScenario=function(self) self.SetupActive=false; self.ScenarioStartTime=0 end
          package.preload.fs2rts=function() return R end
          package.preload.batch_setup=function() return setup end
        ''')
        lua.execute(Path(__file__).with_name('acceptance_driver.lua').read_text(encoding='utf-8'))
        lua.execute("R:StartScenario(); assert(R.SetupFactionCount==4 and R.choices.BLUE=='NTF' and R.choices.RED=='GTVA' and R.choices.GOLD=='GTA' and R.choices.TEAM04=='SHIVAN')")

    def test_slot_swaps_and_equal_economy_are_explicit_and_preserve_normal_setup(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'batch_setup.lua'
            fields=stage.write_batch_setup(path,'gta-shivans',equal_economy=True,swap_slots=True)
            self.assertEqual((fields['blueFaction'],fields['redFaction']),('SHIVAN','GTA'))
            self.assertTrue(fields['equalEconomy'])
            self.assertEqual(stage.SCENARIOS['gta-shivans']['blueFaction'],'GTA')
            with self.assertRaises(ValueError): stage.write_batch_setup(path,'default',swap_slots=True)
        from lupa.lua51 import LuaRuntime
        lua=LuaRuntime()
        lua.execute('''
          cf={openFile=function() return {isValid=function() return true end,write=function() end,flush=function() end} end}
          R={Config={AI={},Cinematic={}},ApplyConfiguredBaseSpacing=function() end,StartScenario=function() end,OnFrame=function() end,
            CommandPoints=3000,ActiveIncomePerSecond=10,
            InitializeAIStates=function(self) self.AIStates={BLUE={cp=3000,playerEconomy=true},RED={cp=1000,income=7},GOLD={cp=1000,income=7}} end}
          package.preload.fs2rts=function() return R end; package.preload.batch_setup=function() return {equalEconomy=true} end
        ''')
        lua.execute(Path(__file__).with_name('acceptance_driver.lua').read_text(encoding='utf-8'))
        lua.execute('''R:InitializeAIStates(0)
          assert(R.AIStates.RED.cp==3000 and R.AIStates.GOLD.income==10 and R.AIStates.BLUE.playerEconomy)
        ''')

    def test_personal_report_resumes_but_global_result_ends_once(self):
        from lupa.lua51 import LuaRuntime
        lua=LuaRuntime()
        lua.execute('''
          events,resumes,quits,closes={},0,0,0
          local file={isValid=function() return true end,write=function() end,flush=function() end,close=function() end}
          cf={openFile=function() return file end}; mn={getMissionTime=function() return 20 end}
          ba={GameEvents={GS_EVENT_QUIT_GAME=1},postGameEvent=function() quits=quits+1 end}
          R={Config={AI={},Cinematic={Enabled=true}},PostBattleActive=true,
            ApplyConfiguredBaseSpacing=function() end,StartScenario=function() end,OnFrame=function() end,
            EmitAIEvent=function(self,event,data) events[#events+1]={event=event,data=data} end,
            ResumePostBattle=function(self) resumes=resumes+1; self.PostBattleActive=false end,
            CloseAITrace=function() closes=closes+1 end}
          package.preload.fs2rts=function() return R end; package.preload.batch_setup=function() return {} end
        ''')
        lua.execute(Path(__file__).with_name('acceptance_driver.lua').read_text(encoding='utf-8'))
        lua.execute('''
          R:OnFrame(); assert(resumes==1 and quits==0 and closes==0)
          assert(events[1].event=='PLAYER_DEFEAT' and not events[1].data.globalResolved)
          R.StrategicResult={victor='RED'}; R:OnFrame(); R:OnFrame()
          assert(quits==1 and closes==1 and #events==2)
          assert(events[2].data.globalResolved and events[2].data.victorFaction=='RED')
        ''')

    def test_rotation_moves_every_active_faction(self):
        from lupa.lua51 import LuaRuntime
        from test_feature_request import boot
        lua=boot()
        lua.execute('''
          package.loaded.batch_setup=nil
          package.preload.batch_setup=function() return {rotation=120} end
          local file={isValid=function() return true end,write=function() end,flush=function() end}
          cf={openFile=function() return file end}; package.loaded.fs2rts=r
          r.SetupActive=true; r.SetupFactionCountChoice=3; r:UpdateFactionCount()
          r.UpdateCameraTransform=function() end
          baseSpacing=r.ApplyConfiguredBaseSpacing
          baseSpacing(r)
          before={}
          for _,kind in ipairs(r:GetFactionKeys()) do before[kind]=r:GetFactionCommandShip(kind).Position end
        ''')
        lua.execute(Path(__file__).with_name('acceptance_driver.lua').read_text(encoding='utf-8'))
        lua.execute('''
          r:ApplyConfiguredBaseSpacing()
          for _,kind in ipairs(r:GetFactionKeys()) do
            local physical=r:GetFactionCommandShip(kind).Position
            assert(physical:getDistance(r.ScenarioBasePositions[kind])<.01,'physical station did not follow rotated layout: '..kind)
            assert(physical:getDistance(before[kind])>100,'rotation had no effect: '..kind)
          end
        ''')

    def test_layout_is_explicit_frozen_data_and_does_not_mutate_scenarios(self):
        from lupa.lua51 import LuaRuntime
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'batch_setup.lua'
            for layout in ('circle','star','multi-circle'):
                fields=stage.write_batch_setup(path,'rotated',layout)
                self.assertEqual(dict(LuaRuntime().execute(path.read_text())),fields)
                self.assertEqual(fields['layout'],layout)
                self.assertEqual(fields['rotation'],120)
            self.assertNotIn('layout',stage.SCENARIOS['rotated'])
            with self.assertRaises(ValueError): stage.write_batch_setup(path,'default','not-a-layout')

    def test_acceptance_start_retries_rejection_and_does_not_restart_a_running_match(self):
        from lupa.lua51 import LuaRuntime
        lua=LuaRuntime()
        lua.execute('''
          attempts,flushes,closed=0,0,false
          local file={isValid=function() return true end,write=function() assert(not closed) end,
            flush=function() end,close=function() closed=true end}
          cf={openFile=function() return file end}
          mn={getMissionTime=function() return 0 end}
          R={SetupActive=true,Config={AI={},Cinematic={Enabled=true},Setup={DefaultBaseDistance=2}},
            ScenarioBasePositions={},OnFrame=function() end,ApplyConfiguredBaseSpacing=function() end,
            UpdateFactionCount=function(self) self.SetupFactionCount=3 end,
            GetFactionKeys=function() return {'BLUE','RED','GOLD'} end,
            GetFactionCommandShip=function() return nil end,
            GetEscalationProfile=function() return {tierUnlocks={0,300}} end,
            EmitAIEvent=function() end,FlushAITrace=function() flushes=flushes+1 end}
          R.StartScenario=function(self)
            attempts=attempts+1
            if attempts>1 then self.SetupActive=false; self.ScenarioStartTime=0 end
          end
          package.preload.fs2rts=function() return R end
          package.preload.batch_setup=function() return {} end
        ''')
        lua.execute((Path(__file__).with_name('acceptance_driver.lua')).read_text(encoding='utf-8'))
        lua.execute('''
          assert(R.Config.Cinematic.Enabled==false,'headless run retains presentation clock')
          R:OnFrame(); assert(attempts==1 and not closed)
          R:OnFrame(); assert(attempts==2 and closed and flushes==1,'rejected start was never retried')
          R:OnFrame(); assert(attempts==2 and flushes==1,'running match restarted')
        ''')

    def test_scenario_is_frozen_as_lua_data_and_unknown_names_are_rejected(self):
        from lupa.lua51 import LuaRuntime
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'batch_setup.lua'
            for name,expected in stage.SCENARIOS.items():
                stage.write_batch_setup(path,name)
                actual=LuaRuntime().execute(path.read_text())
                self.assertEqual(dict(actual),expected)
            with self.assertRaises(KeyError): stage.write_batch_setup(path,'not-a-scenario')
    def test_runtime_snapshot_excludes_tools_and_caches_and_keeps_assets(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); core=root/'core'; dest=root/'snapshot'
            for name in ('data/scripts/fs2rts.lua','data/models/test.pof','data/maps/test.png',
                         'tools/test_old.py','data/__pycache__/junk.pyc','mod.ini'):
                p=core/name; p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(b'fixture')
            stage.copy_core(core,dest)
            self.assertEqual((dest/'data/models/test.pof').read_bytes(),b'fixture')
            self.assertTrue((dest/'data/scripts/fs2rts.lua').is_file())
            self.assertTrue((dest/'data/maps/test.png').is_file())
            self.assertTrue((dest/'mod.ini').is_file())
            self.assertFalse((dest/'tools').exists())
            self.assertFalse((dest/'data/__pycache__').exists())
            with self.assertRaises(FileExistsError):
                stage.stage_base(dest,core,root/'missing-template')


if __name__=='__main__':
    unittest.main()
