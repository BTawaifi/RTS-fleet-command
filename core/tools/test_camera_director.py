"""The battle camera prefers ships involved in current combat.

Covers the three branches of PickBattleCamTarget that the first version of this
file never reached: the zero-hull guard at fs2rts_camera.lua:342 (every fixture
ship had HitpointsLeft==HitpointsMax, so the hull ratio was never below 1), and
the Config.BattleCam reads at :361/:366/:371, which the shipped
fs2rts_config.lua does not provide at all -- see the note in
test_battle_cam_config_table_is_absent_from_the_shipped_config.
"""
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

SCRIPTS = Path(__file__).resolve().parents[1] / "data/scripts"

CONFIG = '''
          package.path=scripts_path.."/?.lua;"..package.path
          package.preload.fs2rts_config=function() return {ObserverShip='Observer'} end
          package.preload.fs2rts_util=function()
            -- Full export list of data/scripts/fs2rts_util.lua. fs2rts_camera
            -- binds all twelve as module-locals; a stub missing one leaves a
            -- nil upvalue that fails on "attempt to call a nil value" instead
            -- of on a real assertion. tools/test_script_structure.py enforces
            -- that this list stays complete.
            return {AI_FACTION_ORDER={},sortedNumericKeys=function() return {} end,
              clamp=function(v,a,b) return math.max(a,math.min(b,v)) end,
              lower=function(v) if v==nil then return '' end return string.lower(tostring(v)) end,
              vec=function(x,y,z) return {x=x,y=y,z=z} end,copyVec=function(v) return v end,
              distance2=function() return 0 end,objectValid=function(v) return v~=nil and v.valid~=false end,
              shipValid=function(v) return v~=nil and v.valid~=false end,
              shipAlive=function(v) return v~=nil and v.valid~=false and (v.HitpointsLeft or 1)>0 end,
              teamName=function(v) return v end,tableContainsSignature=function() return false end}
          end
          R={Config={ObserverShip='Observer'},BattleCamSignature=nil,AIStats={hits={}},AIObservations={},AITargetedBy={}}
          package.preload.fs2rts_state=function() return R end
          require 'fs2rts_camera'; mn={getMissionTime=function() return 100 end}
          gr={setCamera=function() end}
          local function position(x,z) return {x=x,y=0,z=z,getDistance=function(self,other)
            local dx,dy,dz=self.x-other.x,self.y-other.y,self.z-other.z
            return math.sqrt(dx*dx+dy*dy+dz*dz)
          end} end
          local function ship(id,name,capital,team)
            return {Name=name,signature=id,capital=capital,Team=team,Position=position(id*100,0),HitpointsMax=1000,HitpointsLeft=1000,
              Class={Name=name},isValid=function(self) return self.valid~=false end,
              getSignature=function(self) return self.signature end}
          end
          function mkShip(id,name,capital,team) return ship(id,name,capital,team) end
          idle=ship(1,'Idle juggernaut',true,'BLUE')
          fighter=ship(2,'Fighter under fire',false,'BLUE')
          hostile=ship(3,'Attacker',false,'RED')
          R.GetShipList=function() return {idle,fighter,hostile} end
          R.IsStaticDefense=function() return false end
          R.IsCommandStation=function(self,s) return s.station==true end
          R.GetShipWeaponRange=function() return 1000 end
          R.IsCapitalTarget=function(self,s) return s.capital==true end
          R.GetFactionKey=function(self,s) return s.Team end
          R.AreEnemies=function(self,a,b) return a.Team~=b.Team end
          R.AITargetedBy[2]={RED={[3]=hostile}}
'''

FIXTURES = '''
          -- Every other update the director needs, so UpdateBattleCam runs for
          -- real instead of being stubbed out.
          R.UINowValue=1000
          R.UINow=function(self) return self.UINowValue end
          R.FindShipBySignature=function(self,sig)
            for _,s in ipairs(R:GetShipList()) do if s.signature==sig then return s end end
          end
          R.Camera=nil
          R.Followed={}
          R.UpdateFollowCamera=function(self,s,target) self.Followed[#self.Followed+1]={ship=s,target=target} end
          R.SetStatus=function() end
          R.PostBattleActive=false
'''


class CameraDirectorTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute(CONFIG)

    def test_recent_combat_contact_beats_idle_capital(self):
        self.lua.execute('''
          local subject,target=R:PickBattleCamTarget()
          assert(subject==fighter and target==hostile,
            'battle director picked idle capital over a live hostile contact')
        ''')


    def test_distant_assignments_and_stations_do_not_displace_live_combat(self):
        self.lua.execute('''
          local marching=mkShip(4,'Marching capital',true,'BLUE')
          local base=mkShip(5,'Remote base',true,'RED'); base.station=true
          base.Position.x=50000; marching.Target=base; base.Target=marching
          R.AITargetedBy[4]={RED={[5]=base}}
          R.BattleCamSignature=fighter.signature
          R.GetShipList=function() return {marching,base,fighter,hostile} end
          local subject,target=R:PickBattleCamTarget()
          assert(subject==fighter and target==hostile,
            'a remote attack assignment or station displaced the current firefight')
        ''')


class BattleCamUpdateTests(unittest.TestCase):
    """fs2rts_camera.lua:359-372. Nothing in the first version of this file
    reached UpdateBattleCam, so the Config.BattleCam table, the shot window and
    the orbit rate were all untested."""

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute(CONFIG)
        self.lua.execute(FIXTURES)

    def check(self, code):
        self.lua.execute(code)

    def test_battle_cam_config_table_drives_the_shot_window_and_orbit_rate(self):
        # fs2rts_config.lua ships no BattleCam table, so `self.Config.BattleCam
        # or {}` always took the empty branch and the literals 9 and 0.12 were
        # the only reachable values. Injecting the table proves the reads are
        # real config reads, not dead code.
        self.check("""R.Config.BattleCam={ShotSeconds=3,OrbitRadiansPerSecond=0.5}
          R:ToggleBattleCam()
          assert(R.BattleCamActive and R.BattleCamSignature==nil)
          R.UINowValue=1000
          R:UpdateBattleCam()
          assert(R.BattleCamSignature==2,'the director did not lock a live contact: '..tostring(R.BattleCamSignature))
          assert(R.BattleCamTargetSignature==3,'the shot did not retain the hostile firing on its subject')
          assert(R.BattleCamShotStart==1000)
          assert(math.abs(R.BattleCamShotUntil-1003)<0.001,
            'Config.BattleCam.ShotSeconds was ignored: shot ran to '..tostring(R.BattleCamShotUntil))
          R.UINowValue=1000.5
          R:UpdateBattleCam()
          assert(#R.Followed==2 and R.Followed[2].ship==fighter and R.Followed[2].target==hostile,
            'the shot was re-picked before its configured window expired')
          assert(math.abs(R.FollowYawOffset-(R.BattleCamYawStart+0.5*0.5))<0.001,
            'Config.BattleCam.OrbitRadiansPerSecond was ignored: '..tostring(R.FollowYawOffset))
          -- Past the window the director is allowed to re-pick.
          R.UINowValue=1004
          R:UpdateBattleCam()
          assert(R.BattleCamShotStart==1004,'an expired shot was not restarted')""")

    def test_battle_cam_falls_back_to_literals_when_the_config_table_is_absent(self):
        # The state the shipped config actually produces. This is the branch
        # that runs in game today; the 9 s window and the 0.12 rad/s orbit are
        # literals at :366 and :371.
        self.check("""assert(R.Config.BattleCam==nil,'fixture: the shipped config has no BattleCam table')
          R:ToggleBattleCam()
          R.UINowValue=1000
          R:UpdateBattleCam()
          assert(R.BattleCamSignature~=nil,'the director found nothing with no config table')
          assert(math.abs(R.BattleCamShotUntil-1009)<0.001,
            'the no-config fallback window is not the 9 s literal: '..tostring(R.BattleCamShotUntil))
          R.UINowValue=1001
          R:UpdateBattleCam()
          assert(math.abs(R.FollowYawOffset-(R.BattleCamYawStart+1*0.12))<0.001,
            'the no-config fallback orbit rate is not the 0.12 literal: '..tostring(R.FollowYawOffset))
          -- Post-battle stops the director instead of re-picking a target.
          R.PostBattleActive=true
          R:UpdateBattleCam()
          assert(R.BattleCamSignature==nil and R.BattleCamActive==false,
            'the post-battle screen left the battle camera running')""")

    def test_stops_when_there_is_nothing_left_to_film(self):
        self.check("""R.GetShipList=function() return {} end
          R:ToggleBattleCam()
          R:UpdateBattleCam()
          assert(R.BattleCamActive==false and R.BattleCamSignature==nil,
            'an empty world left the battle camera active with no subject')""")

    def test_a_wounded_contact_out_ranks_a_healthy_one_in_the_same_fight(self):
        # The hull ratio at :342 feeds the `hull<.75` bonus at :351, so two
        # contacts that are both under fire are separated by how hurt they are.
        # If the ratio were computed wrong (or replaced by a constant) the two
        # would tie and the pick would fall to iteration order instead.
        self.check("""local healthy=mkShip(6,'Healthy contact',false,'BLUE')
          local wounded=mkShip(7,'Wounded contact',false,'BLUE')
          wounded.HitpointsMax=1000; wounded.HitpointsLeft=300
          R.AITargetedBy[6]={RED={[3]=hostile}}
          R.AITargetedBy[7]={RED={[3]=hostile}}
          -- Healthy first, so iteration order alone would pick it.
          local list={healthy,wounded}
          R.GetShipList=function() return list end
          assert(R:PickBattleCamTarget()==wounded,
            'a ship at 30% hull lost to a full-hull contact in the same firefight')
          -- At 80% the +5 wounded bonus lapses, the two scores tie, and the
          -- first ship in the list wins because the comparison is strict.
          wounded.HitpointsLeft=800
          list={healthy,wounded}
          assert(R:PickBattleCamTarget()==healthy,
            'the wounded-ship bonus never lapsed above 75% hull')""")

    def test_dead_hulls_are_never_selected_as_cinematic_subjects(self):
        self.check("""local derelict=mkShip(4,'Derelict',false,'RED')
          derelict.HitpointsMax=0; derelict.HitpointsLeft=0
          local live=mkShip(5,'Live contact',false,'BLUE')
          R.AITargetedBy[5]={RED={[3]=hostile}}
          local list={derelict,live}
          R.GetShipList=function() return list end
          local picked=R:PickBattleCamTarget()
          assert(picked==live,'a live contact lost to a zero-hull derelict: '..tostring(picked and picked.Name))
          -- Even a dead hull with a live attacker must not be selected.
          R.AITargetedBy[4]={BLUE={[3]=hostile}}
          list={derelict}
          assert(R:PickBattleCamTarget()==nil,
            'a dead hull was selected as a cinematic subject')
          local ghost=mkShip(8,'Zero hull capital',true,'RED')
          ghost.HitpointsMax=0; ghost.HitpointsLeft=0
          R.AITargetedBy[8]={BLUE={[5]=live}}
          list={ghost}
          assert(R:PickBattleCamTarget()==nil,
            'a dead capital was selected as a cinematic subject')""")


class BattleCamConfigShapeTests(unittest.TestCase):
    """Documentation, not behaviour: fs2rts_camera.lua reads
    self.Config.BattleCam.ShotSeconds and .OrbitRadiansPerSecond, and
    fs2rts_config.lua defines no BattleCam table, so both reads always fall
    back to the literals 9 and 0.12. Shipped as a failing-shaped test on
    purpose: when the table is added, this goes red and the literals can be
    deleted rather than left as a silent second source of truth."""

    def test_battle_cam_config_table_is_absent_from_the_shipped_config(self):
        source = (SCRIPTS / "fs2rts_config.lua").read_text(encoding="utf-8", errors="replace")
        self.assertNotIn("BattleCam =", source,
                         "fs2rts_config.lua now defines a BattleCam table; the fallback literals "
                         "at fs2rts_camera.lua:366 and :371 can be deleted and the defaults moved "
                         "into config so they are tunable")


if __name__ == "__main__":
    unittest.main()
