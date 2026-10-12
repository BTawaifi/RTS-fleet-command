"""Setup backdrop: the random skirmish shown behind the escalation setup panel.

Run: cd core/tools && python -m pytest test_setup_backdrop.py -q
"""
import unittest

from lupa.lua51 import LuaRuntime

from test_station import SETUP, SCRIPTS


class SetupBackdropTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(SETUP)
        # Record every spawned ship and the flags set on it; the shared double
        # ignores setFlag, and the backdrop's invulnerability is what matters here.
        self.lua.execute('''
          for _,n in ipairs({'GTC Fenris','GTF Hercules','GTB Medusa','SC Lilith','SF Mara','SB Nephilim'}) do
            tb.ShipClasses[n]={Name=n,HitpointsMax=100}
          end
          created={}; refuseOrders=nil
          local base=mn.createShip
          mn.createShip=function(...)
            local s=base(...); created[#created+1]=s; s.flagsSet={}
            function s:setFlag(v,...) for _,f in ipairs({...}) do self.flagsSet[f]=v end end
            if refuseOrders then s.giveOrder=function() return false end end
            return s
          end
          r.EnableFullArsenal=function() end
          r.GetTacticalMapHalfExtent=function() return 10000 end
        ''')

    def check(self, code):
        self.lua.execute(code)

    def test_spawns_three_opposing_pairs_one_friendly_and_one_hostile_each(self):
        self.check('''
          r:CreateSetupBackdrop()
          assert(#created==6, 'expected 6 backdrop ships, got '..#created)
          local friendly,hostile=0,0
          for _,s in ipairs(created) do
            if s.Team==mn.Teams.friendly then friendly=friendly+1 elseif s.Team==mn.Teams.hostile then hostile=hostile+1 end
          end
          assert(friendly==3 and hostile==3, 'sides '..friendly..'/'..hostile)
        ''')

    def test_each_ship_attacks_its_pair_and_is_invulnerable(self):
        self.check('''
          r:CreateSetupBackdrop()
          local ships=r.SetupBackdropShips
          for i=1,#ships,2 do
            local a,b=ships[i],ships[i+1]
            assert(a.Team~=b.Team, 'a pair must be one of each side')
            assert(a.Target==b and b.Target==a, 'pair does not attack each other')
            assert(a.flagsSet.invulnerable==true and b.flagsSet.invulnerable==true,
              'backdrop ships must be invulnerable so the battle never ends')
          end
        ''')

    def test_classes_come_from_the_side_pools(self):
        self.check('''
          r:CreateSetupBackdrop()
          local friendlyNames={['GTC Fenris']=true,['GTF Hercules']=true,['GTB Medusa']=true}
          local hostileNames={['SC Lilith']=true,['SF Mara']=true,['SB Nephilim']=true}
          for _,s in ipairs(r.SetupBackdropShips) do
            local name=s.Class.Name
            if s.Team==mn.Teams.friendly then assert(friendlyNames[name], 'friendly ship with class '..name)
            else assert(hostileNames[name], 'hostile ship with class '..name) end
          end
        ''')

    def test_each_start_gets_a_different_layout(self):
        self.check('''
          r:CreateSetupBackdrop()
          local first=r.SetupBackdropShips[1].Position
          r:CreateSetupBackdrop()
          local second=r.SetupBackdropShips[1].Position
          assert(first.x~=second.x or first.z~=second.z, 'two starts placed the first ship identically')
        ''')

    def test_the_backdrop_does_not_draw_from_the_global_random_stream(self):
        self.check('''
          math.randomseed(42); local a=math.random()
          math.randomseed(42); r:CreateSetupBackdrop(); local b=math.random()
          assert(a==b, 'the backdrop consumed draws the headless runs depend on')
        ''')

    def test_clear_vanishes_every_backdrop_ship_and_leaves_the_intro_alone(self):
        self.check('''
          r.IntroShips={'intro-sentinel'}
          r:CreateSetupBackdrop()
          local group=r.SetupBackdropShips
          r:ClearSetupBackdrop()
          for _,s in ipairs(group) do assert(not s:isValid(), 'backdrop ship survived clear') end
          assert(r.SetupBackdropShips==nil, 'clear must forget the group')
          assert(r.IntroShips[1]=='intro-sentinel', 'clearing the backdrop touched the intro tableau')
        ''')

    def test_a_refused_attack_order_aborts_and_leaves_no_ships(self):
        self.check('''
          refuseOrders=true
          local ok,err=pcall(function() r:CreateSetupBackdrop() end)
          assert(not ok and tostring(err):find('attack order refused',1,true), 'refusal must abort: '..tostring(err))
          for _,s in ipairs(created) do assert(not s:isValid(), 'a refused backdrop left a ship behind') end
        ''')


if __name__ == "__main__":
    unittest.main()
