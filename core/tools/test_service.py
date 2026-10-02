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
unit.SecondaryBanks={{AmmoMax=100,AmmoLeft=0}}; unit.HitpointsLeft=400
unit.Orders={}; unit.given=0
function unit:clearOrders() self.Orders={} end
function unit:giveOrder(order,target)
  self.given=self.given+1
  self.Orders={{Target=target,isValid=function() return true end,getType=function() return order end}}
  return true
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
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path=SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(SETUP+EXTRA)

    def check(self,code): self.lua.execute(code)

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
          local resumes=0; r.ReissueUserOrder=function(self,s,o) assert(o.kind=='guard'); resumes=resumes+1 end
          r.UserOrders[unit.signature]={kind='guard'}; r:BeginFleetService(unit,'SELF_PRESERVATION',0)
          work(0); work(19.99); assert(r.FleetServices[unit.signature]); work(20)
          assert(not r.FleetServices[unit.signature] and resumes==1 and r.FleetServiceCooldown[unit.signature]==50)''')

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

    def test_survival_requires_persistent_disadvantage_but_critical_damage_immediate(self):
        self.check('''unit.HitpointsLeft=1000; unit.SecondaryBanks[1].AmmoLeft=100
          r.StrategicThreatSnapshot={}; r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          local threat=ship('Local enemy',class('Enemy fighter'),unit.Position,mn.Teams.hostile)
          r.GetFleetLocalThreat=function(self,s) return s==unit and threat or nil end
          r.AILocalStrength=function() return 100,250 end
          r.AITargetedBy={[unit.signature]={RED={[threat.signature]=threat}}}
          r:UpdateFleetServices(0); r:UpdateFleetServices(2); r:UpdateFleetServices(4)
          assert(not r.FleetServices[unit.signature]); r:UpdateFleetServices(6)
          assert(r.FleetServices[unit.signature].reason=='OUTMATCHED')
          r.FleetServices={}; r.NextFleetServiceThink=0; r.UserOrders[unit.signature]={kind='guard'}
          unit.HitpointsLeft=210; r:UpdateFleetServices(8)
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

    def test_drag_move_keeps_manual_control_after_arrival_but_tap_move_does_not(self):
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
          r.IsFiniteVector=function() return true end; r.IsMovableFriendly=function() return true end
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
          r.IsFiniteVector=function() return true end
          r:IssueMove(ba.createVector(0,0,-1400))
          assert(not r.UserOrders[unit.signature].manual,
            'a plain tap-to-move was wrongly tagged as a manual command')
          handed=spy(true); r:OnWaypointsDone(unit)
          assert(handed(), 'a tap-to-move no longer returns to the default control')''')

    def test_overwhelming_bad_fight_is_avoided_without_waiting_for_damage(self):
        self.check('''unit.HitpointsLeft=1000; unit.SecondaryBanks[1].AmmoLeft=100
          r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          local threat=ship('Severe enemy',class('Severe'),unit.Position,mn.Teams.hostile)
          r.GetFleetLocalThreat=function(self,s) return s==unit and threat or nil end
          r.AILocalStrength=function() return 100,500 end
          r.AITargetedBy={[unit.signature]={RED={[threat.signature]=threat}}}
          r:UpdateFleetServices(0)
          assert(r.FleetServices[unit.signature].reason=='AVOID_OVERWHELMING_FIGHT')''')

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
          assert(r.FleetServices[unit.signature].reason=='AVOID_OVERWHELMING_FIGHT',
            'actual hostile focus must still trigger immediate avoidance')
          r.FleetServices={}; r.NextFleetServiceThink=0; r.AITargetedBy={}
          unit.HitpointsLeft=200; r:UpdateFleetServices(16)
          assert(r.FleetServices[unit.signature].reason=='SELF_PRESERVATION',
            'critical damage remains an immediate retreat trigger')''')

    def test_service_retry_cooldown_blocks_danger_loop_but_not_critical_hull(self):
        self.check('''unit.HitpointsLeft=1000; unit.SecondaryBanks[1].AmmoLeft=100
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
          assert(r.FleetServices[unit.signature].reason=='AVOID_OVERWHELMING_FIGHT',
            'persistent danger did not trigger after cooldown')
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

    def test_station_attack_keeps_outmatched_defenders_in_the_fight(self):
        self.check('''unit.HitpointsLeft=1000; unit.SecondaryBanks[1].AmmoLeft=100
          r.StrategicThreatSnapshot={}; r.BuildStrategicThreatSnapshot=function() return {} end; r.BuildAIContext=function() end
          local threat=ship('Enemy pounding station',class('Enemy capital'),unit.Position,mn.Teams.hostile)
          r.GetFleetLocalThreat=function(self,s) return s==unit and threat or nil end
          r.AILocalStrength=function() return 100,1000 end
          r.AITargetedBy={[unit.signature]={RED={[threat.signature]=threat}}}
          r.GetFactionThreats=function() return {{attacking=true,capital=true}} end
          for t=0,12,2 do r:UpdateFleetServices(t) end
          assert(not r.FleetServices[unit.signature], 'base defense yielded to ordinary outmatched recovery')
          r.GetFactionThreats=function() return {} end; r.NextFleetServiceThink=0
          r:UpdateFleetServices(14)
          assert(r.FleetServices[unit.signature].reason=='AVOID_OVERWHELMING_FIGHT',
            'normal self-preservation resumed after the base threat ended')''')

    def test_base_under_fire_aborts_docked_refit(self):
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
          assert(not r.FleetServices[unit.signature],
            'a docked refit kept running while its own station was under fire')
          assert(r.FleetServiceCooldown[unit.signature]>114,
            'interrupted service did not take a retry cooldown')''')

    def test_manual_service_survives_base_attack_but_a_stale_one_does_not(self):
        self.check('''unit.HitpointsLeft=400; unit.SecondaryBanks[1].AmmoLeft=0
          assert(r:BeginFleetService(unit,'HULL_LOW',0)); work(100); work(112)
          r.StrategicThreatSnapshot={}; r.BuildStrategicThreatSnapshot=function() return {} end
          r.BuildAIContext=function() end
          local threat=ship('Enemy pounding station',class('Enemy capital'),unit.Position,mn.Teams.hostile)
          r.GetFleetLocalThreat=function() return nil end
          r.GetFactionThreats=function() return {{attacking=true,ship=threat}} end
          r.NextFleetServiceThink=0; r:UpdateFleetServices(114)
          assert(not r.FleetServices[unit.signature],'precondition: automatic service was aborted')
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
