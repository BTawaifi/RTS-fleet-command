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


if __name__ == "__main__":
    unittest.main()
