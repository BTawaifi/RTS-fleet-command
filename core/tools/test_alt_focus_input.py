"""Mouse gesture checks for Alt camera focus controls."""
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

SCRIPTS = Path(__file__).resolve().parents[1] / "data/scripts"


class AltFocusTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('''
          package.path=scripts_path.."/?.lua;"..package.path
          package.preload.fs2rts_config=function() return {Selection={DragThresholdPixels=6}} end
          -- Full fs2rts_util surface. fs2rts_input binds all twelve helpers as
          -- module-locals; the ones that used to be missing from this stub were
          -- NIL, so a reached call site failed on "attempt to call a nil value"
          -- rather than on a real assertion. Mirrors
          -- data/scripts/fs2rts_util.lua.
          local Vec={}; Vec.__index=Vec
          function Vec.__add(a,b) return ba.createVector(a.x+b.x,a.y+b.y,a.z+b.z) end
          function Vec.__sub(a,b) return ba.createVector(a.x-b.x,a.y-b.y,a.z-b.z) end
          function Vec.__mul(a,b) return ba.createVector(a.x*b,a.y*b,a.z*b) end
          function Vec.__div(a,b) return ba.createVector(a.x/b,a.y/b,a.z/b) end
          function Vec.__unm(a) return ba.createVector(-a.x,-a.y,-a.z) end
          ba={createVector=function(x,y,z) return setmetatable({x=x,y=y,z=z},Vec) end}
          local function objValid(o) return o~=nil and o:isValid() end
          package.preload.fs2rts_util=function() return {AI_FACTION_ORDER={'BLUE','RED','GOLD'},
            sortedNumericKeys=function(t) local r={}; for k in pairs(t) do r[#r+1]=k end; table.sort(r); return r end,
            clamp=function(v,a,b) return math.max(a,math.min(b,v)) end,
            lower=function(v) if v==nil then return '' end return string.lower(tostring(v)) end,
            vec=ba.createVector, copyVec=function(v) return ba.createVector(v.x,v.y,v.z) end,
            distance2=function(x1,y1,x2,y2) local dx=x1-x2; local dy=y1-y2; return dx*dx+dy*dy end,
            objectValid=objValid,
            shipValid=function(s) return objValid(s) and s:getBreedName()=='Ship' end,
            shipAlive=function(s) return objValid(s) and not s:isDying() and (tonumber(s.HitpointsLeft) or 0)>0 end,
            teamName=function(s) if not objValid(s) then return '' end return string.lower(tostring(s.Team.Name)) end,
            tableContainsSignature=function(list,sig)
              for _,v in ipairs(list or {}) do if v==sig then return true end end
              return false end} end
          R={}; package.preload.fs2rts_state=function() return R end
          require "fs2rts_input"
          bit={checkBit=function(v,i) return math.floor(v/2^i)%2==1 end}
          io.getMouseX=function() return R.mouseX end; io.getMouseY=function() return R.mouseY end
          R.Enabled=true; R.Config={Selection={DragThresholdPixels=6}}
          R.CameraFocus={x=0,y=0,z=0}; R.LeftDrag=nil
          R.HandleUILeftClick=function() return false end; R.IsPointOnRTSUI=function() return false end
          R.UpdateCameraTransform=function(self) self.focusUpdates=(self.focusUpdates or 0)+1 end
          R.SetStatus=function(self,text) self.status=text end
          R.GetShipAtScreen=function(self) return self.target end
          R.ScreenToPlane=function() return {x=7,y=0,z=9} end
          R.SelectBox=function(self) self.boxSelected=true end
          R.FocusOnSelection=function(self) self.selectionFocused=true end
        ''')

    def test_alt_click_focuses_hovered_ship_without_changing_selection(self):
        self.lua.execute('''
          R.target={Name='Enemy Wing 1',Position={x=10,y=20,z=30}}
          R.mouseX=100; R.mouseY=100; R.LeftDrag={x1=100,y1=100,alt=true}
          R:OnMouseReleased(1)
          assert(R.CameraFocus.x==10 and R.CameraFocus.y==20 and R.CameraFocus.z==30)
          assert(R.focusUpdates==1 and R.status=='Focused: Enemy Wing 1')
        ''')

    def test_alt_drag_box_selects_and_focuses_group(self):
        self.lua.execute('''
          R.target=nil; R.mouseX=140; R.mouseY=140; R.LeftDrag={x1=100,y1=100,alt=true}
          R:OnMouseReleased(1)
          assert(R.boxSelected and R.selectionFocused)
          assert(R.focusUpdates==nil,'group focus should use the existing selection camera path')
        ''')

    def test_escape_resumes_and_exits_a_paused_pilot(self):
        self.lua.execute('''
          controls={Pause='Pause'}
          R.Config={HotkeyHintsKey='F10',HomeworldControls={},Pilot={ToggleKey='P'}}
          R.KeyDown={}; R.FastKeyDown={}
          R.Paused=true; R.PossessedSignature=17
          function R:SetPaused(paused) self.Paused=paused end
          function R:TogglePilotMode() self.PossessedSignature=nil end
          R:OnKeyPressed('Esc','Esc')
          assert(R.Paused==false and R.PossessedSignature==nil,
            'Escape must resume simulation and leave piloting from a paused pilot view')
          assert(R:ShouldOverrideKey('Esc','Esc'),
            'Escape should be consumed when it performs the pilot recovery action')
        ''')

    def test_space_pauses_only_the_rts_and_ctrl_space_still_focuses(self):
        self.lua.execute('''
          controls={Pause='Pause'}
          R.Config={HotkeyHintsKey='F10',HomeworldControls={},Pilot={ToggleKey='P'}}
          R.KeyDown={}; R.FastKeyDown={}
          function R:TogglePause() self.pauseToggles=(self.pauseToggles or 0)+1 end
          R.PossessedSignature=17
          R:OnKeyPressed('Space','Space')
          assert(R.pauseToggles==nil and not R:ShouldOverrideKey('Space','Space'),
            'Space must remain native piloting input')
          R.PossessedSignature=nil
          R:OnKeyPressed('Space','Space')
          assert(R.pauseToggles==1 and R:ShouldOverrideKey('Space','Space'),
            'Space must pause and be consumed in RTS mode')
          R:OnKeyPressed('Alt-Esc','Esc')
          assert(R.pauseToggles==1 and not R:ShouldOverrideKey('Alt-Esc','Esc'),
            'Alt+Escape must remain available to the native menu')
          R.CtrlDown=false
          R:OnKeyPressed('Ctrl-Space','Space')
          assert(R.selectionFocused and R.pauseToggles==1,
            'Ctrl+Space must keep its existing focus action')
          assert(R:ShouldOverrideKey('Ctrl-Space','Space'),
            'Ctrl+Space focus must remain consumed by the RTS')
        ''')

    def test_speed_keys_work_while_piloting_and_paused(self):
        self.lua.execute('''
          R.Config={HotkeyHintsKey='F10',HomeworldControls={},Pilot={ToggleKey='P'}}
          R.PossessedSignature=17; R.Paused=true; R.TimeScale=0; R.LastNonZeroTimeScale=2
          function R:StepTimeScale(delta) self.step=delta end
          function R:SetPaused(value) self.Paused=value end
          function R:SetTimeScale(value) self.TimeScale=value end
          R:OnKeyPressed('=','=')
          assert(R.step==1 and R:ShouldOverrideKey('=','='),
            'speed stepping must work and be consumed in a paused pilot view')
          R:OnKeyPressed('Alt-3','3')
          assert(R.Paused==false and R.TimeScale==4 and R:ShouldOverrideKey('Alt-3','3'),
            'direct speed selection must work and be consumed while piloting: '
              ..tostring(R.Paused)..'/'..tostring(R.TimeScale)..'/'..tostring(R:ShouldOverrideKey('Alt-3','3')))
        ''')

    def test_world_click_places_an_armed_sentry(self):
        self.lua.execute('''
          require 'fs2rts_orders'
          R.BeginFrameProjection=function() end
          R.GetCarrier=function() return {Position={y=12}} end
          R.ScreenToPlane=function(self,x,y,planeY)
            self.ray={x=x,y=y,planeY=planeY}
            return ba.createVector(700,planeY,900)
          end
          R.ExecuteStationArmedCommand=function(self,pos) self.placed=pos end
          R.ArmedCommand='sentry'; R.PossessedSignature=nil
          R.mouseX=320; R.mouseY=240
          R.LeftDrag={x1=320,y1=240,onUI=false}
          R:OnMouseReleased(1)
          assert(R.placed and R.placed.x==700 and R.placed.y==12 and R.placed.z==900,
            'an armed sentry world click must resolve to the 3D camera ray and place')
          assert(R.ray.x==320 and R.ray.y==240 and R.ray.planeY==12,
            'sentry placement must use the cursor ray intersected with station height')
        ''')

    # OnMouseMoved is an engine hook (core/data/tables/fs2rts-sct.tbm) that runs
    # every frame, so each drag mode gets its own guard here.
    MOVE_SETUP = '''
      R.BeginFrameProjection=function(self) self.projected=(self.projected or 0)+1 end
      R.Config.Camera={DragThresholdPixels=5,MouseOrbitYaw=.01,MouseOrbitPitch=.01,
        MinPitchDegrees=-80,MaxPitchDegrees=80,MousePanScale=1}
      R.CameraYaw=0; R.CameraPitch=0
      R.ClampMapCenter=function(self) self.clamped=true end
    '''

    def test_mouse_move_is_ignored_when_disabled_possessed_or_in_a_cinematic(self):
        self.lua.execute(self.MOVE_SETUP + '''
          R.LeftDrag={x1=100,y1=100,x2=100,y2=100}
          local blockers={Enabled=false,PossessedSignature=9,CinematicActive=true,PostBattleActive=true,ExitMenuActive=true}
          for blocker,value in pairs(blockers) do
            R.Enabled=true; R.PossessedSignature=nil; R.CinematicActive=nil; R.PostBattleActive=nil; R.ExitMenuActive=nil
            R[blocker]=value
            R.LeftDrag.x2=100; R.LeftDrag.y2=100
            R.mouseX=160; R.mouseY=160
            R:OnMouseMoved()
            assert(R.projected==nil, blocker..' must return before any projection work')
            assert(R.LeftDrag.x2==100 and R.LeftDrag.y2==100, blocker..' must not update the drag')
          end
        ''')

    def test_map_window_drag_takes_precedence_over_other_drags(self):
        self.lua.execute(self.MOVE_SETUP + '''
          R.MapWindowDrag={id='panel'}; R.LeftDrag={x1=100,y1=100,x2=100,y2=100}
          R.UpdateMapWindowDrag=function(self,x,y) self.windowMoved={x=x,y=y} end
          R.mouseX=130; R.mouseY=140
          R:OnMouseMoved()
          assert(R.windowMoved.x==130 and R.windowMoved.y==140, 'window drag must receive the cursor')
          assert(R.LeftDrag.x2==100, 'a window drag must return before the left drag updates')
        ''')

    def test_map_pan_drag_moves_the_map_center_by_the_cursor_delta_in_world_space(self):
        self.lua.execute(self.MOVE_SETUP + '''
          R.TacticalMapToWorld=function(self,x,y) return {x=x,z=y} end
          local view={cx=500,cz=500}; R.GetMapView=function() return view end
          R.MapPanDrag={x=100,y=100}
          R.mouseX=110; R.mouseY=105
          R:OnMouseMoved()
          assert(view.cx==490 and view.cz==495, 'map center must move opposite the drag: '..view.cx..'/'..view.cz)
          assert(R.clamped, 'map pan must clamp the center')
          assert(R.MapPanDrag.x==110 and R.MapPanDrag.y==105, 'map pan must advance its anchor to the cursor')
        ''')

    def test_left_drag_records_the_live_cursor_without_moving_the_camera(self):
        self.lua.execute(self.MOVE_SETUP + '''
          R.LeftDrag={x1=100,y1=100,x2=100,y2=100}
          R.mouseX=103; R.mouseY=97
          R:OnMouseMoved()
          assert(R.LeftDrag.x2==103 and R.LeftDrag.y2==97, 'left drag must track the cursor')
          assert(R.focusUpdates==nil and R.CameraYaw==0, 'a left drag alone must not orbit the camera')
        ''')

    def test_right_facing_drag_previews_destination_and_facing_past_threshold(self):
        self.lua.execute(self.MOVE_SETUP + '''
          R.ScreenToPlane=function(self,x,y,planeY) return {x=x,y=y} end
          R.CameraFocus={x=0,y=0,z=0}
          R.RightDrag={facingDrag=true,x1=100,y1=100,startX=100,startY=100,x=100,y=100}
          R.mouseX=102; R.mouseY=100
          R:OnMouseMoved()
          assert(R.RightDrag.moved==nil, 'a 2 px jitter is below the 5 px threshold')
          assert(R.MovePreview.facing.x==102, 'the preview tracks the cursor even before the drag is marked moved')
          R.mouseX=130; R.mouseY=100
          R:OnMouseMoved()
          assert(R.RightDrag.moved==true, 'the threshold is measured from the press point')
          assert(R.MovePreview.destination.x==100 and R.MovePreview.destination.y==100,
            'destination is the press point on the command plane')
          assert(R.MovePreview.facing.x==130, 'facing is the current cursor on the command plane')
          assert(R.CameraYaw==0, 'a facing drag must not orbit the camera')
        ''')

    def test_right_orbit_drag_rotates_yaw_and_clamps_pitch_after_threshold(self):
        self.lua.execute(self.MOVE_SETUP + '''
          R.RightDrag={x=100,y=100,startX=100,startY=100}
          R.mouseX=110; R.mouseY=100
          R:OnMouseMoved()
          assert(R.RightDrag.moved==true and R.focusUpdates==1, 'orbit must update the camera once it moves')
          assert(math.abs(R.CameraYaw-(-0.1))<1e-9, 'horizontal drag must change yaw by dx*MouseOrbitYaw: '..R.CameraYaw)
          R.mouseX=110; R.mouseY=100+10000
          R:OnMouseMoved()
          assert(R.CameraPitch==math.rad(80), 'pitch must clamp at MaxPitchDegrees: '..R.CameraPitch)
          assert(R.RightDrag.x==110 and R.RightDrag.y==10100, 'orbit must advance its anchor')
        ''')

    def test_follow_orbit_drag_changes_follow_offsets_without_the_free_camera(self):
        self.lua.execute(self.MOVE_SETUP + '''
          R.FollowOrbitDrag={x=100,y=100,startX=100,startY=100}
          R.FollowYawOffset=0; R.FollowPitchOffset=.22
          R.FindShipBySignature=function() return nil end
          R.FollowSignature=7
          R.mouseX=120; R.mouseY=100
          R:OnMouseMoved()
          assert(R.FollowOrbitDrag.moved==true and R.FollowOrbitDrag.x==120, 'follow orbit must track the cursor')
          assert(math.abs(R.FollowYawOffset-(-0.2))<1e-9, 'follow yaw must use the same orbit gain: '..R.FollowYawOffset)
          assert(R.CameraYaw==0 and R.focusUpdates==nil, 'follow orbit must not touch the free camera')
        ''')


if __name__ == "__main__":
    unittest.main()
