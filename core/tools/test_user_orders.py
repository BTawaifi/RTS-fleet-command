"""Focused Lua checks for persistent player attack-wing orders."""
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

SCRIPTS = Path(__file__).resolve().parents[1] / "data/scripts"

FIXTURE = r'''
package.preload.fs2rts_config = function() return {Policy={RefreshInterval=1}} end
package.preload.fs2rts_util = function()
  return {
    AI_FACTION_ORDER={}, sortedNumericKeys=function(t)
      local keys={}; for k in pairs(t) do keys[#keys+1]=k end; table.sort(keys); return keys
    end,
    shipValid=function(s) return s~=nil and s.valid~=false end,
    shipAlive=function(s) return s~=nil and s.valid~=false and (s.HitpointsLeft or 0)>0 end,
    lower=string.lower, clamp=function(v,a,b) return math.max(a,math.min(b,v)) end,
    copyVec=function(v) return v end, vec=function(...) return {...} end,
    distance2=function() return 0 end, objectValid=function(s) return s~=nil end,
    teamName=function(s) return s.faction end, tableContainsSignature=function(t,s)
      for _,v in ipairs(t) do if v==s then return true end end; return false
    end
  }
end
R={UserOrders={},PolicyApplied={},AIOrderState={},FleetServices={},RTSWings={},ships={},SelectedShips={}}
package.preload.fs2rts_state = function() return R end
ORDER_ATTACK=1; ORDER_GUARD=2; ORDER_STAY_STILL=3
local function makeShip(signature,faction)
  local s={signature=signature,faction=faction,Name="Ship"..signature,HitpointsLeft=100,orders={}}
  function s:getSignature() return self.signature end
  function s:clearOrders() self.orders={} end
  function s:giveOrder(kind,target) self.orders[#self.orders+1]={kind=kind,target=target}; return true end
  return s
end
R.makeShip=makeShip
function R:GetSelectedFriendlyShips() return self.SelectedShips end
function R:IsPlayerEnemy(s) return s~=nil and s.faction~="BLUE" end
function R:IsFriendly(s) return s~=nil and s.faction=="BLUE" end
function R:FindShipBySignature(sig) return self.ships[sig] end
function R:GetLogicalWing(s) return self.wingBySignature[s.signature] end
function R:SetStatus(s) self.status=s end
function R:AreEnemies(a,b) return a.faction~=b.faction end
function R:Reset()
  self.UserOrders={}; self.PolicyApplied={}; self.AIOrderState={}; self.FleetServices={}; self.RTSWings={}; self.ships={}; self.wingBySignature={}; self.SelectedShips={}; self.returned=0
end
'''


class UserOrderTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(FIXTURE)
        self.lua.execute('''
          R.Config={CarrierShip='Carrier',EnemyCommandShip='Red Base',ThirdCommandShip='Gold Base',ObserverShip='Observer'}
          require "fs2rts_orders"
          R.IsStaticDefense=function() return false end
          R.ReturnToDefaultControl=function(self) self.returned=(self.returned or 0)+1 end
        ''')

    def test_attack_order_follows_live_members_of_target_wing(self):
        self.lua.execute("""
          R:Reset()
          local attacker=R.makeShip(1,'BLUE'); local target1=R.makeShip(10,'RED')
          local target2=R.makeShip(11,'RED'); local target3=R.makeShip(12,'RED')
          R.ships={[1]=attacker,[10]=target1,[11]=target2,[12]=target3}
          R.SelectedShips={attacker}
          local wing={id='W4',label='Red Beta',signatures={10,11,12}}
          R.RTSWings.W4=wing; R.wingBySignature={[10]=wing,[11]=wing,[12]=wing}
          R:IssueAttack(target1)
          local order=R.UserOrders[1]
          assert(order.kind=='attack_wing' and order.targetWing=='W4' and order.targetSignature==10)
          target1.HitpointsLeft=0
          R:HandleAttackWingTargetDeath(10)
          assert(order.targetSignature==11 and attacker.orders[#attacker.orders].target==target2,
            'attack wing did not continue after its first target died')
          target2.HitpointsLeft=0
          R:HandleAttackWingTargetDeath(11)
          assert(order.targetSignature==12 and attacker.orders[#attacker.orders].target==target3,
            'attack wing did not continue to its final live member')
        """)

    def test_attack_wing_releases_when_all_members_are_gone(self):
        self.lua.execute("""
          R:Reset()
          local attacker=R.makeShip(1,'BLUE'); local target=R.makeShip(10,'RED')
          R.ships={[1]=attacker,[10]=target}; R.SelectedShips={attacker}
          local wing={id='W1',label='Red Alpha',signatures={10}}
          R.RTSWings.W1=wing; R.wingBySignature={[10]=wing}
          R:IssueAttack(target)
          assert(R.UserOrders[1].kind=='attack','single-ship attack changed contract')
          R.UserOrders[1]={kind='attack_wing',targetSignature=10,targetWing='W1'}
          target.HitpointsLeft=0
          R:HandleAttackWingTargetDeath(10)
          assert(R.UserOrders[1]==nil and R.returned==1,
            'empty target wing kept the manual order alive')
        """)


if __name__ == "__main__":
    unittest.main()
