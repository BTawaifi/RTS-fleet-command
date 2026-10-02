"""Lua 5.1 boundary checks for temporary logical-to-native player-wing membership."""
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

SCRIPTS = Path(__file__).resolve().parents[1] / 'data/scripts'
PLAYER_WING = SCRIPTS / 'fs2rts_player_wing.lua'

FIXTURE = r'''
local function ship(signature,name)
  local s={signature=signature,Name=name,valid=true,HitpointsLeft=100,team='BLUE',Team={Name='BLUE'}}
  function s:getSignature() return self.signature end
  function s:isValid() return self.valid end
  -- The real shipValid/shipAlive ask the engine for getBreedName() and
  -- isDying(); a hull that cannot answer them is not one the engine would
  -- have produced either.
  function s:getBreedName() return 'Ship' end
  function s:isDying() return false end
  function s:getWing() return self.nativeWing or {} end
  return s
end
package.preload.fs2rts_state=function() return {} end
-- Full export list of data/scripts/fs2rts_util.lua. This stub used to define
-- only shipValid and shipAlive, so every other helper the module bound was a
-- nil upvalue and a reached call site failed on "attempt to call a nil value"
-- rather than on a real assertion. tools/test_script_structure.py enforces
-- that this list stays complete.
package.preload.fs2rts_util=function()
  ba=ba or {}
  local Vec={}; Vec.__index=Vec
  function Vec.__add(a,b) return ba.createVector(a.x+b.x,a.y+b.y,a.z+b.z) end
  function Vec.__sub(a,b) return ba.createVector(a.x-b.x,a.y-b.y,a.z-b.z) end
  function Vec.__mul(a,b) return ba.createVector(a.x*b,a.y*b,a.z*b) end
  function Vec.__div(a,b) return ba.createVector(a.x/b,a.y/b,a.z/b) end
  function Vec.__unm(a) return ba.createVector(-a.x,-a.y,-a.z) end
  ba.createVector=ba.createVector or function(x,y,z) return setmetatable({x=x,y=y,z=z},Vec) end
  local function objValid(o) return o~=nil and o:isValid() end
  return {AI_FACTION_ORDER={'BLUE','RED','GOLD'},sortedNumericKeys=function(t)
      local r={}; for k in pairs(t) do r[#r+1]=k end; table.sort(r); return r end,
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
      return false end}
end
R=require 'fs2rts_player_wing'
pilot=ship(1,'Pilot fighter'); observer=ship(2,'RTS Observer')
mate1=ship(3,'Wingmate 1'); mate2=ship(4,'Wingmate 2')
wing={Name='Alpha',DisplayName='Existing label',[1]=observer}
observer.nativeWing=wing; wing.addCalls=0; wing.removeCalls=0
function wing:addPlayerWingMember(s)
  self.addCalls=self.addCalls+1
  if self.failAt==self.addCalls then return false end
  self[#self+1]=s; s.nativeWing=self; return true
end
function wing:removePlayerWingMember(s)
  self.removeCalls=self.removeCalls+1
  for i=2,#self do if self[i]==s then
    table.remove(self,i); s.nativeWing=nil; return true
  end end
  return false
end
function makeState(order1)
  R.UserOrders={[1]={kind='pilot'}}
  if order1 then R.UserOrders[3]=order1 end
  R.PolicyApplied={}; R.AIOrderState={}; R.returned={}; R.reissued={}
  R.logical={label='Blue Beta',signatures={1,3,4}}
  R.ships={[1]=pilot,[2]=observer,[3]=mate1,[4]=mate2}
  R.GetLogicalWing=function(self,s) return s==pilot and self.logical or nil end
  R.GetObserver=function() return observer end
  R.FindShipBySignature=function(self,sig) return self.ships[sig] end
  R.SetUserOrder=function(self,s,order) self.UserOrders[s.signature]=order; self.PolicyApplied[s.signature]=nil; self.AIOrderState[s.signature]=nil end
  R.ReissueUserOrder=function(self,s,order) self.reissued[#self.reissued+1]=s.signature end
  R.ReturnToDefaultControl=function(self,s) self.returned[#self.returned+1]=s.signature end
  R:LeavePilotNativeWing()
  wing[2]=nil; wing[3]=nil; wing.addCalls=0; wing.removeCalls=0; wing.failAt=nil; wing.DisplayName='Existing label'
  mate1.nativeWing=nil; mate2.nativeWing=nil
end
function attach() return R:JoinPilotNativeWing(pilot) end
function detach() R:LeavePilotNativeWing() end
'''


class PilotWingTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(FIXTURE)

    def check(self, code):
        self.lua.execute(code)

    def test_stock_configuration_never_calls_native_wing_extensions(self):
        self.check("""
          makeState({kind='attack',targetSignature=99})
          R.Config={Pilot={NativeWingExtensions=false}}
          wing.addPlayerWingMember=function() error('stock engine has no extension') end
          assert(attach()==nil)
          assert(#wing==1 and mate1.nativeWing==nil and mate2.nativeWing==nil)
          assert(R.UserOrders[3].kind=='attack' and R.UserOrders[4]==nil)
          assert(R.PilotNativeWing==nil)
        """)

    def test_join_adds_logical_wingmates_to_native_player_wing_and_restores(self):
        self.check("""
          makeState({kind='attack',targetSignature=99})
          assert(attach()=='Blue Beta')
          assert(#wing==3 and wing[1]==observer and wing[2]==mate1 and wing[3]==mate2)
          assert(pilot.nativeWing==nil and observer.nativeWing==wing)
          assert(mate1.nativeWing==wing and mate2.nativeWing==wing)
          assert(wing.DisplayName=='Blue Beta')
          assert(R.UserOrders[3].kind=='wing' and R.UserOrders[4].kind=='wing')
          detach()
          assert(#wing==1 and wing[1]==observer and observer.nativeWing==wing)
          assert(mate1.nativeWing==nil and mate2.nativeWing==nil)
          assert(wing.DisplayName=='Existing label')
          assert(R.UserOrders[3].kind=='attack' and R.UserOrders[4]==nil)
          assert(#R.reissued==1 and R.reissued[1]==3 and #R.returned==1 and R.returned[1]==4)
        """)

    def test_reentry_does_not_duplicate_members(self):
        self.check("""
          makeState(); assert(attach()=='Blue Beta'); detach()
          assert(#wing==1); assert(attach()=='Blue Beta')
          assert(#wing==3 and wing[2]==mate1 and wing[3]==mate2)
          detach(); assert(#wing==1 and wing[1]==observer)
        """)

    def test_native_add_failure_rolls_back_partial_membership(self):
        self.check("""
          makeState(); wing.failAt=2
          assert(attach()==nil)
          assert(#wing==1 and wing[1]==observer and mate1.nativeWing==nil and mate2.nativeWing==nil)
          assert(wing.DisplayName=='Existing label' and R.PilotNativeWing==nil)
          assert(R.UserOrders[3]==nil and R.UserOrders[4]==nil)
        """)

    def test_member_in_another_native_wing_prevents_partial_join(self):
        self.check("""
          makeState()
          local other={Name='Other wing',[1]=mate2}; mate2.nativeWing=other
          assert(attach()==nil)
          assert(#wing==1 and mate1.nativeWing==nil and mate2.nativeWing==other)
          assert(wing.DisplayName=='Existing label' and R.PilotNativeWing==nil)
        """)

    def test_preexisting_service_order_is_cancelled_not_restored(self):
        self.check("""
          makeState({kind='service',targetSignature=88})
          assert(attach()=='Blue Beta' and R.UserOrders[3].kind=='wing')
          detach()
          assert(R.UserOrders[3]==nil and #R.returned==2)
        """)

    def test_failed_native_removal_keeps_members_owned_and_reports_failure(self):
        self.check("""
          makeState(); assert(attach()=='Blue Beta')
          wing.removePlayerWingMember=function() return false end
          local restored,reason=R:LeavePilotNativeWing()
          assert(restored==false and reason and reason:find('cleanup incomplete'))
          assert(R.PilotNativeWing and #R.PilotNativeWing.members==2 and #wing==3)
          assert(R.UserOrders[3].kind=='wing' and R.UserOrders[4].kind=='wing',
            'AI ownership returned while native wing membership remained')
        """)


if __name__ == '__main__':
    unittest.main()
