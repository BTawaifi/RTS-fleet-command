"""Fleet service/survival boundaries; native movement is tested separately."""
import unittest
from lupa.lua51 import LuaRuntime
from test_station import SETUP, SCRIPTS

EXTRA = r'''
r.Enabled=true
ORDER_STAY_STILL='STAY'; ORDER_WAYPOINTS_ONCE='MOVE'; ORDER_ATTACK='ATTACK'; ORDER_GUARD='GUARD'
local V=getmetatable(ba.createVector(0,0,0))
function V.__sub(a,b) return ba.createVector(a.x-b.x,a.y-b.y,a.z-b.z) end
stations.BLUE.Orientation={getFvec=function() return ba.createVector(0,0,1) end}
local c=class('Service fighter'); r.ShipCostMap[c.Name]={cost=1000,time=10}
unit=ship('Fleet test',c,ba.createVector(0,0,-1400),mn.Teams.friendly)
unit.role='fighter'
unit.SecondaryBanks={{AmmoMax=100,AmmoLeft=0,isValid=function() return true end,
  WeaponClass={Range=5000,Speed=500,LifeMax=10,isValid=function() return true end,isBeam=function() return false end}}}; unit.HitpointsLeft=400
unit.Orders={}; unit.given=0
function unit:clearOrders() self.Orders={} end
function unit:giveOrder(order,target)
  self.given=self.given+1
  self.Orders={{Target=target,isValid=function() return true end,getType=function() return order end}}
  return true
end
function serviceHull(name,role)
  local s=ship(name,class(name),unit.Position,mn.Teams.friendly)
  s.role=role; s.Orders={}; s.given=0
  s.clearOrders=unit.clearOrders; s.giveOrder=unit.giveOrder
  r.ShipCostMap[s.Class.Name]={cost=1000,time=10}
  return s
end
-- GetOrCreateMoveWaypoint is deliberately NOT faked here. It owns the
-- self.MoveWaypoints cache and the FreeMoveWaypoints pool, and it decides
-- whether a ship keeps its waypoint or gets a fresh one. Faking it hid the
-- "duplicate waypoint every 20 s" class of bug completely: the real body never
-- ran, so the engine doubles for mn.createWaypoint/mn.createWaypointList went
-- unused. The real one is exercised through the SETUP doubles, and
-- test_move_waypoint_cache_is_reused_not_recreated pins the contract.
r.AssignAIStrategicOrder=function() end; r.ReturnToDefaultControl=function() end
r.Config.Station.FleetService.MinimumRecoverySeconds=20
function work(t,slots,threat)
  now=t; return r:ServiceFleetShip(unit,r.FleetServices[unit.signature],stations.BLUE,t,slots or 2,threat)
end
'''

class ServiceTests(unittest.TestCase):
    def test_repair_pad_side_stays_inside_the_arena(self):
        """The pad sits behind the station, opposite the ship. A station near the map
        edge with the ship on its inward side put the pad outside the arena, and the
        clamp then parked every hull on the boundary. The approach must flip to the
        side whose pad is inside the arena."""
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        lua.execute(SETUP)
        lua.execute(EXTRA)
        result = lua.execute(r"""
          r.GetCommandArenaHalfExtent=function() return 10000 end
          stations.BLUE.Position=ba.createVector(9000,0,0)
          local hull=ship('edge pad hull',class('Service fighter'),ba.createVector(9800,0,0),mn.Teams.friendly)
          local ax,az=r:GetServiceApproach(hull,stations.BLUE,nil)
          local p=ba.createVector(9000-ax*2000,0,9000*0-az*2000)
          local bounded=r:ClampCommandPoint(p,0)
          return tostring(bounded~=nil and bounded:getDistance(p)<=.01)
        """)
        self.assertEqual(result, "true", "the repair pad lands outside the arena")

    def test_simultaneous_recovery_weighs_estimated_crew_exposure_without_size_first_retreat(self):
        self.check('''
          r.Config.Station.FleetService.Slots=2
          r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          r.GetFleetLocalThreat=function() return nil end
          local capital=serviceHull('Crewed capital','capital')
          local second=serviceHull('Another small crew','fighter'); second.HitpointsLeft=250
          unit.HitpointsLeft=250; unit.SecondaryBanks[1].AmmoLeft=100; capital.HitpointsLeft=250
          assert(r:BeginFleetService(unit,'STATION_SERVICE',0,true))
          assert(r:BeginFleetService(capital,'STATION_SERVICE',0,true))
          assert(r:BeginFleetService(second,'STATION_SERVICE',0,true))
          unit.Position=r:GetFleetServicePoint(unit,stations.BLUE,nil,0,1)
          capital.Position=r:GetFleetServicePoint(capital,stations.BLUE,nil,0,1)
          second.Position=r:GetFleetServicePoint(second,stations.BLUE,nil,0,1)
          r:UpdateFleetServices(0); r:UpdateFleetServices(10)
          assert(capital.HitpointsLeft>250 and unit.HitpointsLeft==250,'same-time recovery ignored the larger estimated crew exposure')
          capital.HitpointsLeft=650
          r.NextFleetServiceThink=0; r:UpdateFleetServices(12); r:UpdateFleetServices(14)
          assert(unit.HitpointsLeft>250 and second.HitpointsLeft>250 and capital.HitpointsLeft==650,
            'size-first priority denied two more seriously injured small crews')
          assert(r:GetCrewExposureEstimate(capital)==3 and r:GetCrewExposureEstimate(unit)==1,'crew priorities masquerade as head counts')
        ''')

    def test_older_service_admission_keeps_priority_over_later_larger_crew(self):
        self.check('''
          r.Config.Station.FleetService.Slots=2
          r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          r.GetFleetLocalThreat=function() return nil end
          local capital=serviceHull('Later capital','capital'); capital.HitpointsLeft=250
          unit.HitpointsLeft=250; unit.SecondaryBanks[1].AmmoLeft=100
          r:BeginFleetService(unit,'STATION_SERVICE',0,true); r:BeginFleetService(capital,'STATION_SERVICE',1,true)
          unit.Position=r:GetFleetServicePoint(unit,stations.BLUE,nil,0,1)
          capital.Position=r:GetFleetServicePoint(capital,stations.BLUE,nil,0,1)
          r:UpdateFleetServices(1); r:UpdateFleetServices(10)
          assert(unit.HitpointsLeft>250 and capital.HitpointsLeft==250,'larger later arrivals starved an older small crew')
        ''')

    def test_automatic_service_releases_when_remembered_attacker_is_no_longer_local(self):
        self.check('''
          local threat=ship('Departing attacker',class('SF Mara'),unit.Position,mn.Teams.hostile)
          local nearby=true
          r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          r.GetFleetLocalThreat=function(self,s) return s==unit and nearby and threat or nil end
          r.AILocalStrength=function() return 100,1000 end
          r.AITargetedBy={[unit.signature]={RED={[threat.signature]=threat}}}
          unit.HitpointsLeft=200
          r:UpdateFleetServices(0)
          local visit=r.FleetServices[unit.signature]
          assert(visit and visit.threatSignature==threat.signature)
          unit.Position=r:GetFleetServicePoint(unit,stations.BLUE,nil,visit.padApproachX,visit.padApproachZ)
          unit.HitpointsLeft=1000; unit.SecondaryBanks[1].AmmoLeft=100
          r:UpdateFleetServices(25)
          assert(r.FleetServices[unit.signature],'ready hull ignored a genuinely nearby armed threat')
          nearby=false; threat.Position=ba.createVector(60000,0,60000)
          r:UpdateFleetServices(35)
          assert(not r.FleetServices[unit.signature],'living but distant cached attacker permanently blocked ready/rejoin')
        ''')

    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path=SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(SETUP+EXTRA)

    def check(self,code): self.lua.execute(code)

    def test_healthy_idle_units_skip_threat_scans_but_service_admission_samples_danger(self):
        self.check('''
          unit.HitpointsLeft=1000; unit.SecondaryBanks[1].AmmoLeft=100
          r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          local scans=0
          r.GetFleetLocalThreat=function(self,s) if s==unit then scans=scans+1 end return nil end
          r:UpdateFleetServices(0)
          assert(scans==0 and not r.FleetServices[unit.signature])
          unit.HitpointsLeft=390; r.NextFleetServiceThink=0; r:UpdateFleetServices(2)
          assert(scans>0 and r.FleetServices[unit.signature])
          local previous=scans; r.NextFleetServiceThink=0; r:UpdateFleetServices(4)
          assert(scans>previous,'active service must retain danger checks')
        ''')

    def test_service_builds_its_context_only_when_danger_is_consumed(self):
        self.check('''
          unit.HitpointsLeft=1000; unit.SecondaryBanks[1].AmmoLeft=100
          local builds,contexts,stationQueries=0,0,0
          r.BuildStrategicThreatSnapshot=function() builds=builds+1; return {} end
          r.BuildAIContext=function() contexts=contexts+1 end
          r.GetFactionThreats=function() stationQueries=stationQueries+1; return {} end
          r.GetFleetLocalThreat=function(self,s)
            assert(self.StrategicThreatSnapshot,'danger read without context')
            return nil
          end
          r:UpdateFleetServices(0)
          assert(builds==0 and contexts==0 and stationQueries==0,'healthy fleet eagerly builds weapons context')
          unit.HitpointsLeft=390; r.NextFleetServiceThink=0; r:UpdateFleetServices(2)
          assert(builds==1 and contexts==1 and r.FleetServices[unit.signature])
          assert(not r.StrategicThreatSnapshot and not r.AIProfileIndex,'owned service context leaked')
          r.NextFleetServiceThink=0; r:UpdateFleetServices(4)
          assert(builds==2 and contexts==2 and stationQueries==0,
            'active service should refresh local threat context without a base-wide attacker scan')
          local borrowed={}; r.StrategicThreatSnapshot=borrowed
          r.NextFleetServiceThink=0; r:UpdateFleetServices(6)
          assert(builds==2 and r.StrategicThreatSnapshot==borrowed,'service rebuilt or cleared borrowed context')
        ''')

    def test_healthy_focused_units_defer_strength_scan_until_recovery_is_possible(self):
        self.check('''
          unit.HitpointsLeft=1000; unit.SecondaryBanks[1].AmmoLeft=100
          r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          r.IsFleetFocusedByHostiles=function() return true end
          local threat=ship('Focused attacker',class('SF Mara'),unit.Position,mn.Teams.hostile)
          local scans=0
          r.GetFleetLocalThreat=function(self,s) if s==unit then scans=scans+1 end return threat end
          r.AILocalStrength=function() return 100,1000 end
          r:UpdateFleetServices(0)
          assert(scans==0 and not r.FleetServices[unit.signature],'healthy focus triggers unusable local-strength work')
          unit.HitpointsLeft=390; r.NextFleetServiceThink=0; r:UpdateFleetServices(2)
          assert(scans>0 and r.FleetServices[unit.signature],'damaged focused hull missed automatic recovery')
        ''')

    def test_service_immediately_withdraws_and_repairs_a_lost_inbound_goal(self):
        self.check('''
          unit.Position=ba.createVector(0,0,-6000)
          unit.flags={}
          function unit:setFlag(value,name) self.flags[name]=value end
          unit:giveOrder(ORDER_ATTACK,stations.RED)
          r.Selected={unit.signature}; r.SelectedShips={unit}
          r.GetSelectedFriendlyShips=function() return {unit} end
          r:ServiceSelected()
          assert(unit.Orders[1]:getType()==ORDER_WAYPOINTS_ONCE,'service click leaves the attack goal running')
          assert(not unit:getFlag('no-dynamic'),'service suppresses native incoming-missile evasion')
          local before=unit.given
          unit:giveOrder(ORDER_ATTACK,stations.RED)
          work(2)
          assert(unit.Orders[1]:getType()==ORDER_WAYPOINTS_ONCE and unit.given>before,'cached destination hides stolen service goal')
          r:CancelFleetServiceForShip(unit)
          assert(not unit:getFlag('no-dynamic'),'service leaves permanent native AI suppression')
        ''')

    def test_focused_service_moves_to_the_other_side_of_its_station(self):
        self.check('''
          unit.flags={}
          function unit:setFlag(value,name) self.flags[name]=value end
          r.GetFleetLocalThreat=function() return nil end
          r:BeginFleetService(unit,'STATION_SERVICE',0,true)
          local visit=r.FleetServices[unit.signature]
          local oldPoint=visit.padPoint
          local oldX,oldZ=visit.padApproachX,visit.padApproachZ
          unit.Position=oldPoint
          local attacker=ship('New pad attacker',class('SF Mara'),
            stations.BLUE.Position+ba.createVector(0,0,-6000),mn.Teams.hostile)
          r.IsFleetFocusedByHostiles=function() return true end
          r:ServiceFleetShip(unit,visit,stations.BLUE,1,4,attacker)
          assert(visit.padApproachX*oldX+visit.padApproachZ*oldZ<-.9,
            'a service visitor under attack kept its exposed approach side')
          assert(visit.destination and visit.destination:getDistance(oldPoint)>1000,
            'service did not route the visitor to the safer side of the station')
          assert(not unit:getFlag('no-dynamic'),'repositioning disabled native evasive AI')
        ''')

    def test_focused_service_uses_the_attacker_bearing_when_it_changes_sideways(self):
        self.check('''
          r.GetFleetLocalThreat=function() return nil end
          assert(r:BeginFleetService(unit,'STATION_SERVICE',0,true))
          local visit=r.FleetServices[unit.signature]; local oldPoint=visit.padPoint
          unit.Position=oldPoint
          local attacker=ship('Lateral pad attacker',class('SF Mara'),
            stations.BLUE.Position+ba.createVector(6000,0,0),mn.Teams.hostile)
          r.IsFleetFocusedByHostiles=function() return true end
          r:ServiceFleetShip(unit,visit,stations.BLUE,1,4,attacker)
          assert(visit.padApproachX>.99 and math.abs(visit.padApproachZ)<.01,
            'service kept the old ship bearing rather than moving opposite the attacker')
          assert(visit.destination and visit.destination.x<stations.BLUE.Position.x,
            'service did not book a pad on the far side of the lateral attacker')
        ''')

    def test_under_fire_service_does_not_brake_native_evasive_velocity(self):
        self.check('''
          r.GetFleetLocalThreat=function() return nil end
          assert(r:BeginFleetService(unit,'STATION_SERVICE',0,true))
          local visit=r.FleetServices[unit.signature]
          unit.Position=visit.padPoint; visit.arrived=true; visit.phase='UNDER_FIRE'
          unit.Physics.Velocity=ba.createVector(100,0,0)
          unit:clearOrders(); unit:giveOrder(ORDER_STAY_STILL)
          local attacker=ship('Persistent pad attacker',class('SF Mara'),
            stations.BLUE.Position+ba.createVector(0,0,6000),mn.Teams.hostile)
          r.IsFleetFocusedByHostiles=function() return true end
          r:ServiceFleetShip(unit,visit,stations.BLUE,1,4,attacker)
          assert(unit.Physics.Velocity.x==100,'pad settling cancelled native evasive motion under fire')
        ''')

    def test_remote_recent_damage_preserves_evasion_without_a_nearby_threat(self):
        self.check('''
          r.GetFleetLocalThreat=function() return nil end
          assert(r:BeginFleetService(unit,'STATION_SERVICE',0,true))
          local visit=r.FleetServices[unit.signature]
          unit.Position=visit.padPoint; visit.arrived=true; visit.phase='UNDER_FIRE'
          unit.Physics.Velocity=ba.createVector(100,0,0)
          unit:clearOrders(); unit:giveOrder(ORDER_STAY_STILL)
          r.AITargetedBy={}; r.AIStats={hits={[unit.signature]={hostileTime=1}}}
          r:ServiceFleetShip(unit,visit,stations.BLUE,2,4,nil)
          assert(unit.Physics.Velocity.x==100,'a remote hit was ignored because the nearby threat scan was empty')
          assert(visit.phase=='UNDER_FIRE','recent remote fire allowed servicing to continue')
        ''')

    def test_critical_damage_does_not_override_a_live_player_command(self):
        self.check('''
          local threat=ship('Attacker',class('Enemy'),unit.Position,mn.Teams.hostile)
          unit.HitpointsLeft=100; r.UserOrders[unit.signature]={kind='move',manual=true}
          r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          r.GetFleetLocalThreat=function() return threat end
          r.AILocalStrength=function() return 100,1000 end
          r:UpdateFleetServices(0)
          assert(not r.FleetServices[unit.signature],'automatic self preservation takes away the repeated player move')
        ''')

    def test_irreversible_withdrawal_cannot_be_recalled_for_service(self):
        self.check('''r.IsShipWithdrawing=function(self,s) return s==unit end
          assert(not r:BeginFleetService(unit,'HULL_LOW',0,false),
            'a committed withdrawal was diverted into local service')
          assert(not r.FleetServices[unit.signature])''')

    def test_manual_service_repairs_fully_despite_a_nearby_contact_and_can_run_four_visitors(self):
        self.check('''
          local threat=ship('Nearby contact',class('Enemy'),unit.Position,mn.Teams.hostile)
          unit.HitpointsLeft=900; unit.SecondaryBanks[1].AmmoLeft=100
          r:BeginFleetService(unit,'STATION_SERVICE',0,true); work(0)
          for t=10,40,2 do if r.FleetServices[unit.signature] then work(t,4,threat) end end
          assert(unit.HitpointsLeft==1000 and not r.FleetServices[unit.signature],'manual refit sticks at 90 percent or a nearby contact blocks it')
          assert(r.Config.Station.FleetService.Slots==4,'depot only has single or double ship capacity')
        ''')

    def test_manual_refit_starts_on_the_next_tick_at_the_pad_without_travel_backlog(self):
        self.check('''
          r:BeginFleetService(unit,'STATION_SERVICE',0,true); work(0)
          work(1)
          assert(unit.HitpointsLeft==404,'manual service at the depot does not start directly')
          assert(unit.SecondaryBanks[1].AmmoLeft==4,'manual rearm at the depot waits for an artificial arrival timer')
        ''')

    def test_parallel_capitals_reserve_distinct_pads_with_hull_clearance(self):
        self.check('''
          unit.role='capital'; unit.Class.Model.Radius=700; unit.Position=ba.createVector(0,0,-6000)
          local c=class('Service capital'); c.Model.Radius=700
          local other=ship('Second capital',c,unit.Position,mn.Teams.friendly); other.role='capital'
          other.signature=unit.signature+5
          other.Orders={}; function other:clearOrders() self.Orders={} end
          function other:giveOrder(kind,target) self.Orders={{Target=target,isValid=function() return true end,getType=function() return kind end}}; return true end
          r:BeginFleetService(unit,'STATION_SERVICE',0,true); r:BeginFleetService(other,'STATION_SERVICE',0,true)
          local a=r:GetFleetServicePoint(unit,stations.BLUE,nil,0,1)
          local b=r:GetFleetServicePoint(other,stations.BLUE,nil,0,1)
          assert(a:getDistance(b)>1400,'parallel capital refit pads overlap or signatures alias the same pad')
          unit.Position=a; other.Position=b
          local first=r:ServiceFleetShip(unit,r.FleetServices[unit.signature],stations.BLUE,0,4,nil)
          local second=r:ServiceFleetShip(other,r.FleetServices[other.signature],stations.BLUE,0,4-first,nil)
          assert(first==2 and second==2,'one capital occupies the entire multi-ship depot')
        ''')

    def test_large_refit_pads_do_not_overlap_when_clamped_at_the_arena_edge(self):
        self.check('''
          r.GetCommandArenaHalfExtent=function() return 13500 end
          stations.BLUE.Position=ba.createVector(6500,0,-6500)
          unit.role='capital'; unit.Class.Model.Radius=3200; unit.Position=stations.BLUE.Position+ba.createVector(0,0,-8000)
          local c=class('Second large hull'); c.Model.Radius=3200
          local other=ship('Second large hull',c,unit.Position,mn.Teams.friendly); other.role='capital'
          other.Orders={}; function other:clearOrders() self.Orders={} end
          function other:giveOrder(kind,target) self.Orders={{Target=target,isValid=function() return true end,getType=function() return kind end}}; return true end
          r:BeginFleetService(unit,'STATION_SERVICE',0,true); r:BeginFleetService(other,'STATION_SERVICE',0,true)
          local a=r:GetFleetServicePoint(unit,stations.BLUE,nil,0,1)
          local b=r:GetFleetServicePoint(other,stations.BLUE,nil,0,1)
          assert(a and b and a:getDistance(b)>6400,'arena clamping compresses two large hulls onto overlapping service pads')
          assert(a:getDistance(r:GetFleetServicePoint(unit,stations.BLUE,nil,0,1))<1,'pad drifts while another visitor is booked')
        ''')

    def test_ammo_only_recall_books_capacity_without_parking_an_armed_fleet(self):
        self.check('''
          local function gun()
            return {AmmoMax=0,isValid=function() return true end,WeaponClass={Range=2000,Speed=500,LifeMax=4,
              isValid=function() return true end,isBeam=function() return false end}}
          end
          unit.PrimaryBanks={gun()}; unit.HitpointsLeft=1000
          assert(r:CanStartAmmoService(unit,'fighter'),'empty depot refuses an ammo-only visit')
          for i=1,r.Config.Station.FleetService.Slots do
            local visitor=ship('visitor '..i,class('GTF Myrmidon'),stations.BLUE.Position,mn.Teams.friendly)
            visitor.role='fighter'; r.FleetServices[visitor.signature]={phase='RETURNING'}
          end
          assert(not r:CanStartAmmoService(unit,'fighter'),'an armed fighter joins an unlimited rear-area queue')
          assert(r:CanStartAmmoService(unit,'bomber'),'ordnance-dependent bomber is denied recovery')
          unit.PrimaryBanks={}; unit[1]=nil; unit.SecondaryBanks[1].AmmoLeft=0
          assert(r:CanStartAmmoService(unit,'fighter'),'unarmed craft is kept in combat')
        ''')

    def test_paid_work_only_after_physical_arrival_and_quiet_deadline(self):
        self.check('''unit.Position=ba.createVector(0,0,-6000)
          assert(r:BeginFleetService(unit,'HULL_LOW',0)); work(100)
          assert(unit.HitpointsLeft==400 and unit.SecondaryBanks[1].AmmoLeft==0 and r.CommandPoints==10000)
          unit.Position=ba.createVector(0,0,-1400); work(102); work(109.99)
          assert(unit.HitpointsLeft==400); work(110); assert(unit.HitpointsLeft==400)
          work(112); assert(unit.HitpointsLeft==408 and unit.SecondaryBanks[1].AmmoLeft==8)
          assert(math.abs(r.CommandPoints-(10000-2.8-9.6))<.00001)''')

    def test_damage_and_nearby_threat_pause_without_backlog_heal(self):
        self.check('''r:BeginFleetService(unit,'HULL_LOW',0); work(0); work(10)
          local hp=unit.HitpointsLeft; unit.HitpointsLeft=hp-20; work(12)
          assert(unit.HitpointsLeft==hp-20); work(19.99); assert(unit.HitpointsLeft==hp-20)
          work(20); assert(unit.HitpointsLeft==hp-20)
          local threat=ship('Service threat',class('Enemy'),unit.Position,mn.Teams.hostile)
          work(22,2,threat); assert(unit.HitpointsLeft==hp-20)
          work(100); assert(unit.HitpointsLeft<=hp-4,'paused time became instant healing')''')

    def test_capacity_and_zero_cp_never_manufacture_resources(self):
        self.check('''r:BeginFleetService(unit,'AMMO_LOW',0); work(0); work(10,0)
          assert(unit.HitpointsLeft==400 and unit.SecondaryBanks[1].AmmoLeft==0)
          r.CommandPoints=0; work(12); assert(unit.HitpointsLeft==400 and unit.SecondaryBanks[1].AmmoLeft==0)
          assert(r.FleetServices[unit.signature].phase=='WAIT_CP')''')

    def test_complete_service_releases_once_and_retains_manual_intent(self):
        self.check('''unit.HitpointsLeft=900; unit.SecondaryBanks[1].AmmoLeft=100
          local starts,finishes=0,0
          r.RecordServiceStart=function(self,s,t)
            assert(self.FleetServices[s.signature] and t==0); starts=starts+1
          end
          r.RecordServiceFinish=function(self,s,t)
            assert(self.FleetServices[s.signature] and t==20); finishes=finishes+1
          end
          local resumes=0; r.ReissueUserOrder=function(self,s,o) assert(o.kind=='guard'); resumes=resumes+1 end
          r.UserOrders[unit.signature]={kind='guard'}; r:BeginFleetService(unit,'SELF_PRESERVATION',0)
          assert(starts==1,'service history missed the entry transition')
          work(0); work(19.99); assert(r.FleetServices[unit.signature]); work(20)
          assert(not r.FleetServices[unit.signature] and resumes==1 and r.FleetServiceCooldown[unit.signature]==50)
          assert(finishes==1,'service history missed completion or ran after record deletion')''')

    def test_station_death_rejects_healing_and_player_pilot_is_never_overridden(self):
        self.check('''r.PossessedSignature=unit.signature; assert(not r:BeginFleetService(unit,'HULL_LOW',0))
          r.PossessedSignature=nil; r:BeginFleetService(unit,'HULL_LOW',0); stations.BLUE.dying=true
          work(100); assert(unit.HitpointsLeft==400 and r.FleetServices[unit.signature].phase=='STATION_LOST')''')

    def test_commander_and_policy_cannot_overwrite_active_service(self):
        self.check('''r:BeginFleetService(unit,'HULL_LOW',0)
          r.AutoPlayerMode=true; assert(not r:IsAutomaticAIUnit(unit))
          local before=unit.given; r:ApplyPolicyToShip(unit,true); r:EngageShip(unit)
          assert(not r:IssueStrategicOrder(unit,stations.RED,'attack','PRIMARY',1,true))
          assert(unit.given==before); r:SetUserOrder(unit,{kind='hold'}); assert(not r.FleetServices[unit.signature])''')

    def test_native_order_preemption_does_not_override_service_hold(self):
        self.check('''r:BeginFleetService(unit,'HULL_LOW',0); work(0)
          unit:giveOrder(ORDER_ATTACK,stations.RED); work(2)
          assert(unit.Orders[1]:getType()==ORDER_STAY_STILL)
          assert(r.FleetServices[unit.signature])''')

    def test_healthy_outmatched_ships_keep_fighting_and_damaged_ships_service(self):
        self.check('''unit.HitpointsLeft=1000; unit.SecondaryBanks[1].AmmoLeft=100
          r.StrategicThreatSnapshot={}; r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          local threat=ship('Local enemy',class('Enemy fighter'),unit.Position,mn.Teams.hostile)
          r.GetFleetLocalThreat=function(self,s) return s==unit and threat or nil end
          r.AILocalStrength=function() return 100,250 end
          r.AITargetedBy={[unit.signature]={RED={[threat.signature]=threat}}}
          r:UpdateFleetServices(0); r:UpdateFleetServices(2); r:UpdateFleetServices(4); r:UpdateFleetServices(6)
          assert(not r.FleetServices[unit.signature],'healthy ships withdrew only because the local force ratio was bad')
          unit.HitpointsLeft=390; r.NextFleetServiceThink=0; r:UpdateFleetServices(8)
          -- Healthy pressure is no longer sampled for unusable recovery work;
          -- crossing the hull threshold starts recovery immediately as HULL_LOW.
          assert(r.FleetServices[unit.signature] and r.FleetServices[unit.signature].reason=='HULL_LOW',
            'damaged outmatched ship did not self-service: '..tostring(r.FleetServices[unit.signature] and r.FleetServices[unit.signature].reason))
          r.FleetServices={}; r.NextFleetServiceThink=0; r.UserOrders[unit.signature]={kind='guard'}
          unit.HitpointsLeft=210; r:UpdateFleetServices(8)
          assert(not r.FleetServices[unit.signature],'critical damage overrides the player guard')
          r.UserOrders[unit.signature]=nil; r:UpdateFleetServices(9)
          assert(r.FleetServices[unit.signature].reason=='SELF_PRESERVATION')''')

    def test_completed_service_waypoint_does_not_convert_saved_move_to_hold(self):
        self.check('''r.UserOrders[unit.signature]={kind='move',destination=unit.Position}
          r:BeginFleetService(unit,'SELF_PRESERVATION',0); r:OnWaypointsDone(unit)
          assert(r.UserOrders[unit.signature].kind=='move' and r.FleetServices[unit.signature])''')

    def test_manual_tap_to_move_with_no_facing_point_does_not_crash_arrival(self):
        # Live crash, reported from a real game window:
        #   fs2rts_util.lua:28 attempt to index local 'v' (a nil value)
        #   in copyVec, called from fs2rts_lifecycle.lua:830 in OnWaypointsDone
        # The arrival branch is entered when order.manual==true OR the facing is
        # finite, but it then called copyVec(order.facing) unconditionally. A
        # TAP-to-move is manual and carries NO facing at all, so every completed
        # tap crashed the whole $On Waypoints Done hook on the player's own
        # input. Regression: the hold order must be issued with facing=nil.
        self.check('''local sig=unit.signature
          r.IsFiniteVector=function() return true end
          r.IsMovableFriendly=function() return true end
          r.HoldShip=function() end; r.SetStatus=function() end
          r.ReturnToDefaultControl=function() end
          r.AssignAIStrategicOrder=function() end
          -- manual move, no facing key at all: this is a tap-to-move.
          r.UserOrders[sig]={kind='move',destination=unit.Position,manual=true}
          r:OnWaypointsDone(unit)
          local held=r.UserOrders[sig]
          assert(held~=nil,'the arrival branch dropped the manual order entirely')
          assert(held.kind=='hold','a completed tap should settle into hold: '..tostring(held.kind))
          assert(held.manual==true,'manual control must survive the arrival')
          assert(held.facing==nil,'a tap has no facing; one here means copyVec(nil) again')
          -- And the facing-carrying case must still carry its facing.
          r.UserOrders[sig]={kind='move',destination=unit.Position,manual=true,
                             facing=ba.createVector(0,0,600)}
          r:OnWaypointsDone(unit)
          local dragged=r.UserOrders[sig]
          assert(dragged.facing~=nil,'a drag-move must keep its commanded heading')''')

    def test_order_ping_ignores_a_degenerate_pick_instead_of_crashing(self):
        # Same class, same player-input path: SetOrderPing did copyVec(position)
        # unguarded, and callers pass ship.Position, a ScreenToPlane result or a
        # raw focus vector. A missing acknowledgement marker is cosmetic; a crash
        # there kills the input handler on the player's own click.
        self.check('''r.GetSelectedFriendlyShips=function() return {unit} end
          r.IsFiniteVector=function(v) return v~=nil end
          r:SetOrderPing(nil,'move')
          assert(r.OrderPing==nil,'a nil position must be ignored, not stored')
          r:SetOrderPing(ba.createVector(0,0,-900),'move')
          assert(r.OrderPing~=nil and r.OrderPing.pos~=nil,'a valid pick must still ping')''')

    def test_drag_and_tap_moves_both_keep_manual_control_after_arrival(self):
        self.check('''local function spy(auto)
            -- Only installs the hand-off spies. Clearing UserOrders here would
            -- destroy the order under test and make OnWaypointsDone take its
            -- no-order branch instead of the arrival branch.
            r.AutoPlayerMode=auto
            local handed=false
            r.AssignAIStrategicOrder=function() handed=true end
            r.ReturnToDefaultControl=function() handed=true end
            return function() return handed end
          end
          local face=ba.createVector(0,0,600)
          r.IsMovableFriendly=function() return true end
          r.GetSelectedFriendlyShips=function() return {unit} end
          r.GetSelectedFormation=function() return 'LINE_ABREAST' end
          r.ClampCommandPoint=function(self,p) return p,false end
          r.BuildSafeFormationDestinations=function(self,ships,target)
              return {{ship=ships[1],destination=ba.createVector(0,0,-1400)}} end
          r.MoveShipTo=function() return true end; r.SetStatus=function() end
          r.HoldShip=function() end; r.CommandMarkerUntil=0
          r:IssueMove(ba.createVector(0,0,-1400),face)
          local order=r.UserOrders[unit.signature]
          assert(order.manual==true and order.facing~=nil,
            'a directional drag-move was not recorded as a manual command')
          local handed=spy(true); r:OnWaypointsDone(unit)
          order=r.UserOrders[unit.signature]
          assert(order.manual==true and order.facing~=nil,
            'a drag-move lost manual control and its heading on arrival')
          assert(not handed(), 'a drag-move handed the ship back to the AI on arrival')
          r:IssueMove(ba.createVector(0,0,-1400))
          assert(r.UserOrders[unit.signature].manual,
            'a plain tap-to-move loses ownership')
          handed=spy(true); r:OnWaypointsDone(unit)
          assert(not handed() and r.UserOrders[unit.signature].kind=='hold', 'a tap-to-move returns to automatic combat')''')

    def test_healthy_ship_does_not_withdraw_from_an_overwhelming_local_fight(self):
        self.check('''unit.HitpointsLeft=1000; unit.SecondaryBanks[1].AmmoLeft=100
          r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          local threat=ship('Severe enemy',class('Severe'),unit.Position,mn.Teams.hostile)
          r.GetFleetLocalThreat=function(self,s) return s==unit and threat or nil end
          r.AILocalStrength=function() return 100,500 end
          r.AITargetedBy={[unit.signature]={RED={[threat.signature]=threat}}}
          r:UpdateFleetServices(0)
          assert(not r.FleetServices[unit.signature],
            'healthy ship withdrew solely because a nearby group had higher combat value')''')

    def test_force_disadvantage_without_focus_or_damage_does_not_withdraw(self):
        self.check('''unit.HitpointsLeft=1000; unit.SecondaryBanks[1].AmmoLeft=100
          r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          local enemy=ship('Near but not attacking',class('Enemy'),unit.Position,mn.Teams.hostile)
          r.GetFleetLocalThreat=function(self,s) return s==unit and enemy or nil end
          r.AILocalStrength=function() return 100,500 end
          r.AITargetedBy={}; r.AIStats={hits={}}
          for t=0,12,2 do r:UpdateFleetServices(t) end
          assert(not r.FleetServices[unit.signature],
            'mere local force ratio caused recovery with no targeting or recent damage')
          r.AITargetedBy={[unit.signature]={RED={[enemy.signature]=enemy}}}
          r.NextFleetServiceThink=0; r:UpdateFleetServices(14)
          assert(not r.FleetServices[unit.signature],
            'hostile focus alone should not make a healthy ship hide behind its station')
          r.FleetServices={}; r.NextFleetServiceThink=0; r.AITargetedBy={}
          unit.HitpointsLeft=200; r:UpdateFleetServices(16)
          assert(r.FleetServices[unit.signature].reason=='SELF_PRESERVATION',
            'critical damage remains an immediate retreat trigger')''')

    def test_service_retry_cooldown_blocks_danger_loop_but_not_critical_hull(self):
        self.check('''unit.HitpointsLeft=350; unit.SecondaryBanks[1].AmmoLeft=100
          r.StrategicThreatSnapshot={}; r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          local threat=ship('Persistent overwhelming enemy',class('Persistent threat'),unit.Position,mn.Teams.hostile)
          r.GetFleetLocalThreat=function(self,s) return s==unit and threat or nil end
          r.AILocalStrength=function() return 100,500 end
          r.AITargetedBy={[unit.signature]={RED={[threat.signature]=threat}}}
          r.FleetServiceCooldown[unit.signature]=40
          r:UpdateFleetServices(12)
          assert(not r.FleetServices[unit.signature],'ordinary danger bypassed service cooldown')
          r:UpdateFleetServices(38)
          assert(not r.FleetServices[unit.signature],'ordinary danger bypassed service cooldown before deadline')
          r:UpdateFleetServices(40)
          assert(r.FleetServices[unit.signature],
            'damaged ship did not enter service when its retry deadline elapsed')
          r.FleetServices={}; r.NextFleetServiceThink=0; unit.HitpointsLeft=200
          r.FleetServiceCooldown[unit.signature]=100
          r:UpdateFleetServices(42)
          assert(r.FleetServices[unit.signature].reason=='SELF_PRESERVATION',
            'critical hull damage must bypass the ordinary retry cooldown')''')

    def test_siege_unit_keeps_appropriate_matchup_but_not_critical_damage(self):
        self.check('''unit.HitpointsLeft=1000; unit.SecondaryBanks[1].AmmoLeft=100
          r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          r.GetShipRole=function() return 'bomber' end
          r.GetFleetLocalThreat=function(self,s) return s==unit and stations.RED or nil end
          r.AILocalStrength=function() return 100,1000 end
          for t=0,10,2 do r:UpdateFleetServices(t) end
          assert(not r.FleetServices[unit.signature],'base hull comparison cancelled healthy siege')
          unit.HitpointsLeft=200; r:UpdateFleetServices(12)
          assert(r.FleetServices[unit.signature].reason=='SELF_PRESERVATION')''')

    def test_station_attack_does_not_block_damaged_outmatched_service(self):
        self.check('''unit.HitpointsLeft=1000; unit.SecondaryBanks[1].AmmoLeft=100
          r.StrategicThreatSnapshot={}; r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          local threat=ship('Enemy pounding station',class('Enemy capital'),unit.Position,mn.Teams.hostile)
          r.GetFleetLocalThreat=function() return nil end
          r.AILocalStrength=function() return 100,1000 end
          r.AITargetedBy={}
          r.GetFactionThreats=function() return {{attacking=true,capital=true,ship=threat}} end
          for t=0,12,2 do r:UpdateFleetServices(t) end
          assert(not r.FleetServices[unit.signature], 'base defense yielded to ordinary outmatched recovery')
          unit.HitpointsLeft=390; r.GetFleetLocalThreat=function() return nil end
          r.NextFleetServiceThink=0; r:UpdateFleetServices(14)
          assert(r.FleetServices[unit.signature] and r.FleetServices[unit.signature].reason=='HULL_LOW',
            'base defense overrode repair for a damaged ship: '..tostring(r.FleetServices[unit.signature] and r.FleetServices[unit.signature].reason))''')

    def test_station_attack_alone_does_not_interrupt_a_safe_docked_refit(self):
        self.check('''unit.HitpointsLeft=400; unit.SecondaryBanks[1].AmmoLeft=0
          assert(r:BeginFleetService(unit,'HULL_LOW',0)); work(100); work(112)
          assert(r.FleetServices[unit.signature].phase=='REPAIR_REARM',
            'precondition: unit is docked and being refitted')
          r.StrategicThreatSnapshot={}; r.BuildStrategicThreatSnapshot=function() return {} end
          r.BuildAIContext=function() end
          local threat=ship('Enemy pounding station',class('Enemy capital'),unit.Position,mn.Teams.hostile)
          r.GetFleetLocalThreat=function() return nil end
          r.GetFactionThreats=function() return {{attacking=true,ship=threat}} end
          r.NextFleetServiceThink=0; r:UpdateFleetServices(114)
          assert(r.FleetServices[unit.signature] and r.FleetServices[unit.signature].phase=='REPAIR_REARM',
            'station attack alone cancelled safe, focused-free service')
          r.AITargetedBy={[unit.signature]={RED={[threat.signature]=threat}}}
          local oldPoint=r.FleetServices[unit.signature].padPoint
          r.GetFleetLocalThreat=function(self,s) return s==unit and threat or nil end
          r.NextFleetServiceThink=0; r:UpdateFleetServices(116)
          local service=r.FleetServices[unit.signature]
          assert(service and service.destination and service.destination:getDistance(oldPoint)>1000
            and service.phase=='RETURNING',
            'a focused docked visitor was cancelled instead of moving to the safer pad')''')

    def test_auto_and_manual_service_continue_when_base_attack_does_not_focus_visitor(self):
        self.check('''unit.HitpointsLeft=400; unit.SecondaryBanks[1].AmmoLeft=0
          assert(r:BeginFleetService(unit,'HULL_LOW',0)); work(100); work(112)
          r.StrategicThreatSnapshot={}; r.BuildStrategicThreatSnapshot=function() return {} end
          r.BuildAIContext=function() end
          local threat=ship('Enemy pounding station',class('Enemy capital'),unit.Position,mn.Teams.hostile)
          r.GetFleetLocalThreat=function() return nil end
          r.GetFactionThreats=function() return {{attacking=true,ship=threat}} end
          r.NextFleetServiceThink=0; r:UpdateFleetServices(114)
          assert(r.FleetServices[unit.signature],'base attack cancelled safe automatic service')
          r.GetFactionThreats=function() return {} end
          assert(r:BeginFleetService(unit,'STATION_SERVICE',120,true))
          r.UserOrders[unit.signature]={kind='service'}; work(122); work(134)
          assert(r.FleetServices[unit.signature].phase=='REPAIR_REARM','precondition: manual service is docked')
          r.NextFleetServiceThink=0
          r.GetFactionThreats=function() return {{attacking=true,ship=threat}} end
          r:UpdateFleetServices(136)
          assert(r.FleetServices[unit.signature],
            'an explicit player SERVICE order was cancelled by the base-alarm path')''')

    def test_committed_station_strike_rearms_only_at_near_empty(self):
        self.check('''unit.HitpointsLeft=1000; unit.SecondaryBanks[1].AmmoLeft=10
          r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          r.AIOrderState[unit.signature]={mission='PRIMARY',targetSignature=stations.RED.signature}
          r:UpdateFleetServices(0); assert(not r.FleetServices[unit.signature],
            'fighter left its station strike with 10% ammunition remaining')
          unit.SecondaryBanks[1].AmmoLeft=1; r.NextFleetServiceThink=0; r:UpdateFleetServices(2)
          assert(r.FleetServices[unit.signature].reason=='AMMO_LOW',
            'fighter failed to rearm after spending nearly all ammunition')''')

    def test_subsystem_repair_cost_and_fractional_ammo_budget_block(self):
        self.check('''unit.HitpointsLeft=900; unit.SecondaryBanks[1].AmmoLeft=100; unit[1].HitpointsLeft=50
          r:BeginFleetService(unit,'SYSTEMS_DAMAGED',0); work(0); work(10)
          assert(unit[1].HitpointsLeft==52 and math.abs(r.CommandPoints-9997)<.001)
          unit[1].HitpointsLeft=100; unit.SecondaryBanks[1].AmmoLeft=0; r.CommandPoints=.1; work(12)
          assert(unit.SecondaryBanks[1].AmmoLeft==0 and r.FleetServices[unit.signature].phase=='WAIT_CP')''')

    def test_refit_under_persistent_threat_is_released_not_parked_forever(self):
        # A hull that reaches the pad while a hostile is still inside DangerRadius
        # never satisfies the `not alive(threat)` finish test, so it sat in
        # UNDER_FIRE for the rest of the mission: never repaired, never released,
        # and reporting mode=IDLE in EXECUTION telemetry the whole time (it holds
        # no AIOrderState while FleetServices[id] is set). The station-under-attack
        # abort only covers REPAIR_REARM/WAIT_CP/QUEUED, so it never fired either.
        # Measured across the sentryfix batch: 216-254 service entries per match
        # were still open at run end and 12-28% of all service ship-time was
        # UNDER_FIRE, against only 0.8-1.4% actually spent repairing.
        self.check('''r:BeginFleetService(unit,'HULL_LOW',0); work(100); work(112)
          assert(r.FleetServices[unit.signature].phase=='REPAIR_REARM','precondition: docked refit')
          -- A hostile parked on the pad keeps `alive(threat)` true forever.
          local threat=ship('Pad camping',class('Camping'),unit.Position,mn.Teams.hostile)
          work(2000,2,threat)
          assert(r.FleetServices[unit.signature],
            'a refit under persistent threat was released instead of being parked forever')
          local s=r.FleetServices[unit.signature]
          assert(s.phase=='UNDER_FIRE','precondition: the refit is parked, not repairing')
          local cap=r.Config.Station.FleetService.MaxUnderFireSeconds
          work(2000+cap+2,2,threat)
          assert(not r.FleetServices[unit.signature],
            'a refit stayed parked under threat past its bound; it never repairs and never rejoins')
          assert(r.FleetServiceCooldown[unit.signature]>0,
            'the released refit did not take a retry cooldown, so it will re-park on the next tick')''')

    def test_quiet_refit_completes_and_never_reports_under_fire(self):
        # Counterpart to the release above: the bound must only ever touch a hull
        # that is actually stuck under threat. A refit that is quietly repairing
        # still finishes through the ordinary path and is never parked.
        self.check('''unit.HitpointsLeft=900; unit.SecondaryBanks[1].AmmoLeft=100
          r:BeginFleetService(unit,'SELF_PRESERVATION',0)
          work(0); work(18)
          assert(r.FleetServices[unit.signature],'precondition: refit still in progress')
          assert(r.FleetServices[unit.signature].phase~='UNDER_FIRE',
            'a quiet refit was wrongly parked under fire')
          work(20)
          assert(not r.FleetServices[unit.signature],
            'a refit that was never threatened failed to complete normally')''')

    def test_bounty_goes_to_actual_enemy_killer_once(self):
        self.check('''local killer=ship('Gold killer',class('Gold'),unit.Position,mn.Teams.neutral)
          local dead=ship('Red victim',class('Red'),unit.Position,mn.Teams.hostile)
          r.ShipCostMap[dead.Class.Name]={cost=1000,time=10}; local before=r.CommandPoints
          r:OnShipDeath(dead,killer)
          assert(r.CommandPoints==before and r.AIStates.GOLD.cp==10240 and r.AIStates.RED.cp==10000)
          r:OnShipDeath(dead,killer); assert(r.AIStates.GOLD.cp==10240)''')

    def test_friendly_self_unknown_and_dead_faction_do_not_get_bounty(self):
        self.check('''local killer=ship('Red killer',class('Red'),unit.Position,mn.Teams.hostile)
          local friend=ship('Red friend',class('Red friend'),unit.Position,mn.Teams.hostile)
          r:OnShipDeath(friend,killer); r:OnShipDeath(killer,killer)
          local unknown=ship('Unknown victim',class('Unknown'),unit.Position,mn.Teams.hostile)
          r:OnShipDeath(unknown); r:OnShipDeath(unknown,unit)
          stations.BLUE.dying=true
          local enemy=ship('Enemy victim',class('Enemy'),unit.Position,mn.Teams.hostile)
          r:OnShipDeath(enemy,unit)
          assert(r.CommandPoints==10000 and r.AIStates.RED.cp==10000 and r.AIStates.GOLD.cp==10000)''')

    def test_weapon_and_beam_owner_attribution_does_not_require_telemetry(self):
        self.check('''r.CombatTelemetryEnabled=false
          local function object(breed,parent)
            return {isValid=function() return true end,getBreedName=function() return breed end,Parent=parent,ParentShip=parent}
          end
          for _,breed in ipairs({'Weapon','Beam'}) do
            local enemy=ship('Victim '..breed,class('Victim '..breed),unit.Position,mn.Teams.hostile)
            r.ShipCostMap[enemy.Class.Name]={cost=1000,time=10}; r:OnShipDeath(enemy,object(breed,unit))
          end
          assert(r.CommandPoints==10480)
          assert(r:ResolveKillRewardShip(object('Weapon',nil))==nil)
          assert(r:ResolveKillRewardShip(object('Debris',unit))==nil)''')

    def test_final_balance_distinguishes_deathroll_from_object_validity(self):
        self.check('''r.CombatTelemetryEnabled=true; stations.BLUE.dying=true
          local captured
          r.EmitAIEvent=function(self,event,data) if event=='BALANCE_FINAL' then captured=data end end
          r:EmitAIFinalBalance('BLUE DEFEAT',10)
          assert(captured.factions.BLUE.alive==false and captured.factions.BLUE.objectValid==true)
          assert(captured.factions.RED.alive==true)''')

    def test_move_waypoint_cache_is_reused_not_recreated(self):
        # The real GetOrCreateMoveWaypoint owns self.MoveWaypoints. Recreating the
        # waypoint on every 8 s re-anchor is the "duplicate waypoint every 20 s"
        # bug: FSO has no way to delete a waypoint list, so each one leaks for
        # the rest of the mission. Count the engine calls to tell reuse from
        # recreation.
        self.check('''local before=#waypoints
          local first=r:GetOrCreateMoveWaypoint(unit)
          assert(#waypoints==before+1,'first call did not create a waypoint')
          for i=1,20 do
            local again=r:GetOrCreateMoveWaypoint(unit)
            assert(again==first,'call '..i..' handed back a different waypoint object')
          end
          assert(#waypoints==before+1,'20 repeat calls created '..(#waypoints-before-1)..' extra waypoints')
          assert(r.MoveWaypoints[unit.signature] and r.MoveWaypoints[unit.signature].waypoint==first,
            'the per-ship cache does not hold the waypoint it returned')''')

    def test_a_dead_waypoint_is_rebuilt_and_a_released_one_is_pooled(self):
        # A ship that dies must not keep a handle, and its waypoint list has to
        # be recycled through FreeMoveWaypoints rather than dropped on the floor.
        self.check('''local listsBefore=#waypointLists; local pointsBefore=#waypoints
          local first=r:GetOrCreateMoveWaypoint(unit)
          assert(#waypointLists==listsBefore+1 and #waypoints==pointsBefore+1)
          r:ReleaseMoveWaypoint(unit.signature)
          assert(r.MoveWaypoints[unit.signature]==nil,'release left the signature in the cache')
          assert(#r.FreeMoveWaypoints==1)
          -- Pool reuse: a different ship takes the released waypoint and the
          -- engine is NOT asked for another list.
          local other=ship('Pool consumer',class('Pooled'),unit.Position,mn.Teams.friendly)
          local reused=r:GetOrCreateMoveWaypoint(other)
          assert(reused==first,'the released waypoint was not reused for the next ship')
          assert(#waypointLists==listsBefore+1 and #waypoints==pointsBefore+1,
            'a pooled waypoint still cost a new waypoint list')
          assert(#r.FreeMoveWaypoints==0)
          -- Dead handle: a cached-but-invalid waypoint must be rebuilt rather
          -- than returned, otherwise orders are aimed at a dead object.
          r.MoveWaypoints[other.signature].waypoint.valid=false
          local rebuilt=r:GetOrCreateMoveWaypoint(other)
          assert(rebuilt~=reused and rebuilt:isValid(),'a dead cached waypoint was handed back')
          assert(#waypoints==pointsBefore+2)''')

if __name__=='__main__': unittest.main()
