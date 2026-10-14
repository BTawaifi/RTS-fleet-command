"""Environment picker contracts use FSO Lua boundary doubles."""
import unittest
from lupa.lua51 import LuaRuntime
from test_station import SETUP, SCRIPTS


class EnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(SETUP)
        self.lua.execute('''
          require "fs2rts_environment"
          musicCalls={}; backgroundCalls={}; removedBackgrounds={}; failBackground=false
          ad={
            playMusic=function(file,volume,loop)
              musicCalls[#musicCalls+1]={kind='play',file=file,loop=loop}
              return #musicCalls+20
            end,
            stopMusic=function(handle,fade) musicCalls[#musicCalls+1]={kind='stop',handle=handle} end,
            pauseMusic=function(handle,paused) musicCalls[#musicCalls+1]={kind='pause',handle=handle,paused=paused} end,
          }
          ba.createOrientation=function(p,b,h) return {p=p,b=b,h=h} end
          mn.addBackgroundBitmapNew=function(name,orientation,sx,sy,dx,dy)
            if failBackground or #backgroundCalls+1==failBackgroundAt then failBackground=false; return {isValid=function() return false end} end
            local element={name=name,orientation=orientation,scaleX=sx,scaleY=sy,divX=dx,divY=dy,
              isValid=function() return true end}
            backgroundCalls[#backgroundCalls+1]=element
            return element
          end
          mn.removeBackgroundElement=function(element) removedBackgrounds[#removedBackgrounds+1]=element; return true end
        ''')

    def check(self, code):
        self.lua.execute(code)

    def test_reset_defaults_to_random_sky_and_start_respects_explicit_selection(self):
        self.check('''
          r:ResetState()
          assert(r.SetupBackdropChoice=='RANDOM' and r.SetupMusicChoice=='RANDOM')
          r.SpawnFactionStations=function() return true end -- stations already exist in this boundary fixture
          engine={addHook=function() return true end}
          local choices={}; local setSky=r.SetNebulaBackdrop
          r.SetNebulaBackdrop=function(self,choice,silent) choices[#choices+1]=choice; return setSky(self,choice,silent) end
          r:StartScenario()
          assert(not r.SetupActive and choices[1]=='RANDOM' and #r.EnvironmentBackdropElements==6)
          r:ResetState(); r.SetupBackdropChoice=19; r:StartScenario()
          assert(choices[2]==19 and r.EnvironmentBackdropIndex==19,'explicit sky selection was randomized away')
          r:ResetState(); assert(r.SetupBackdropChoice=='RANDOM' and #r.EnvironmentBackdropElements==0)
        ''')

    def test_music_selection_loops_vfs_asset_and_mute_stays_on_custom_track(self):
        self.check('''
          assert(r:SetEnvironmentMusic(4,true))
          assert(musicCalls[1].kind=='play' and musicCalls[1].file=='FS2_Btl_B01.wav' and musicCalls[1].loop)
          assert(musicCalls[2].kind=='pause' and musicCalls[2].handle==21 and not musicCalls[2].paused)
          assert(r:SetEnvironmentMusicMuted(true) and r.MusicMuted)
          assert(r:SetEnvironmentMusicMuted(false) and not r.MusicMuted)
          assert(musicCalls[#musicCalls].handle==21 and not musicCalls[#musicCalls].paused)
          for _,call in ipairs(musicCalls) do assert(call.handle~=-1,'music selection/mute touched unrelated voice streams') end
          local count=#musicCalls
          assert(not r:SetEnvironmentMusic(0,true) and #musicCalls==count)
        ''')

    def test_music_uses_installed_mediavps_ogg_and_retail_wav_fallback(self):
        self.check('''
          cf={fileExists=function(filename,path,checkVPs)
            assert(path=='' and checkVPs==true,'MediaVP probe must search the VFS')
            return filename=='FS2_Btl_A01.ogg'
          end}
          assert(r:SetEnvironmentMusic(1,true))
          assert(musicCalls[1].file=='FS2_Btl_A01.ogg','available MediaVP OGG should win')
          cf.fileExists=function() return false end
          assert(r:SetEnvironmentMusic(4,true))
          local played={}; for _,call in ipairs(musicCalls) do if call.kind=='play' then played[#played+1]=call.file end end
          assert(played[2]=='FS2_Btl_B01.wav','retail WAV remains the fallback')
        ''')

    def test_nebula_backdrop_replaces_owned_layer_and_rejects_invalid_choice(self):
        self.check('''
          assert(r:SetNebulaBackdrop(1,true) and backgroundCalls[1].name=='neb01')
          assert(#backgroundCalls==6 and backgroundCalls[1].scaleX==5 and backgroundCalls[1].scaleY==9.5
            and backgroundCalls[1].divY==4,'backdrop does not cover all six sky directions without horizontal wrapping')
          failBackground=true
          assert(not r:SetNebulaBackdrop(2,true),'failed API result must be rejected')
          assert(#removedBackgrounds==0 and r.EnvironmentBackdropElements[1]==backgroundCalls[1],
            'failed replacement must preserve the currently displayed backdrop')
          assert(r:SetNebulaBackdrop(19,true) and backgroundCalls[7].name=='dneb01')
          assert(#removedBackgrounds==6 and removedBackgrounds[1]==backgroundCalls[1])
          local count=#backgroundCalls
          assert(not r:SetNebulaBackdrop(0,true) and #backgroundCalls==count)
          assert(#r.Config.Environment.NebulaBackdrops==36)
          assert(#r.Config.Music.Tracks==21)
        ''')

    def test_partial_backdrop_failure_removes_new_faces_and_keeps_old_sky(self):
        self.check('''
          assert(r:SetNebulaBackdrop(1,true))
          local previous=r.EnvironmentBackdropElements
          failBackgroundAt=9
          assert(not r:SetNebulaBackdrop(2,true))
          assert(r.EnvironmentBackdropElements==previous and #previous==6 and r.EnvironmentBackdropIndex==1,
            'partial replacement discarded the existing sky')
          assert(#removedBackgrounds==2 and removedBackgrounds[1]==backgroundCalls[7]
            and removedBackgrounds[2]==backgroundCalls[8],'partial replacement leaked newly created faces')
        ''')

    def test_stop_releases_owned_music_and_backdrop_handles(self):
        self.check('''
          assert(r:SetEnvironmentMusic(1,true) and r:SetNebulaBackdrop(1,true))
          local track=r.EnvironmentMusicHandle; local backdrop=r.EnvironmentBackdropElements[1]
          r:StopEnvironment()
          assert(r.EnvironmentMusicHandle==nil and #r.EnvironmentBackdropElements==0)
          assert(removedBackgrounds[1]==backdrop)
          assert(musicCalls[#musicCalls].kind=='stop' and musicCalls[#musicCalls].handle==track)
          for _,call in ipairs(musicCalls) do assert(call.handle~=-1,'shutdown resumed unrelated voice streams') end
        ''')


if __name__ == "__main__":
    unittest.main()
