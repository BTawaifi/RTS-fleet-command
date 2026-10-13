"""Match history and phase contracts; native extraction_probe checks engine APIs."""
import unittest
from lupa.lua51 import LuaRuntime
from test_station import SETUP, SCRIPTS


class FleetLifeTests(unittest.TestCase):
    def test_presentation_ships_are_not_commissioned_before_start(self):
        self.lua.execute('''
          local unit=ship('RTS Setup 1-1',class('GTF Ulysses'),stations.BLUE.Position,mn.Teams.friendly)
          r.GetShipList=function() return {unit} end
          for _,phase in ipairs({'setup','intro'}) do
            r:ResetFleetLife(); r.NextFleetLife=0
            r.SetupActive=phase=='setup'; r.CinematicActive=phase=='intro'
            assert(r:RecordShipCreated(unit)==nil,'presentation hull commissioned')
            r:UpdateFleetLife(1)
            assert(next(r.UnitHistory)==nil,'presentation hull enters real history')
          end
          r.SetupActive=false; r.CinematicActive=false
          assert(r:RecordShipCreated(unit),'active gameplay cannot commission real hulls')
        ''')

    def test_citations_require_paid_recovery_useful_rejoin_and_confirmed_cover_escape(self):
        self.lua.execute('''
          local unit=ship('Recovering crew',class('GTF Ulysses'),stations.BLUE.Position,mn.Teams.friendly)
          local enemy=ship('Pursuer',class('SF Mara'),stations.BLUE.Position,mn.Teams.hostile)
          local record=r:RecordShipCreated(unit)
          record.hostileProjectileHull=.8; unit.HitpointsLeft=unit.HitpointsMax*.2
          r:RecordServiceStart(unit,1); unit.HitpointsLeft=unit.HitpointsMax
          r:RecordServiceFinish(unit,30,{hullRepaired=unit.HitpointsMax*.8})
          assert(record.recoveryRejoinPending and not record.citations,'repair alone awarded effective combat')
          r:RecordFleetCombatKill(unit,enemy)
          assert(record.citations.RECOVERY_REJOIN)
          r:RecordFleetCombatKill(unit,enemy)
          local count=0; for _ in pairs(record.citations) do count=count+1 end
          assert(count==1,'duplicate kill farmed citations')
          local evacuee=ship('Escaping crew',class('GTB Medusa'),stations.BLUE.Position,mn.Teams.friendly)
          local evac=r:RecordShipCreated(evacuee)
          r.Withdrawals[evac.signature]={history=evac.id,faction='BLUE'}
          enemy.Target=evacuee
          r:RecordFleetCombatKill(unit,enemy)
          assert(not record.citations.WITHDRAWAL_COVER,'threat removal without escape invented a rescue')
          r:RecordUnitFate(unit,'LOST','DESTROYED')
          r:RecordUnitFate(evacuee,'ESCAPED','SHIP_DEPARTED_WARP')
          assert(record.citations.WITHDRAWAL_COVER and record.fate=='LOST','lost covering ship was forgotten')
          assert(r:GetFleetHistorySummary().citations==2)
          local fresh=r:RecordShipCreated(unit,true)
          assert(fresh.id~=record.id and not fresh.citations)
          r:ResetFleetLife(); assert(next(r.UnitHistory)==nil)
        ''')

    def test_projectile_evidence_measures_actual_hull_loss_and_friendly_damage_invalidates_it(self):
        self.lua.execute('''
          local callback,override
          engine={addHook=function(name,fn,condition,pre) callback=fn; override=pre; return true end}
          r:RegisterCrewProjectileEvidence()
          local unit=ship('Damaged crew',class('GTF Ulysses'),stations.BLUE.Position,mn.Teams.friendly)
          local enemy=ship('Enemy',class('SF Mara'),stations.BLUE.Position,mn.Teams.hostile)
          local record=r:RecordShipCreated(unit)
          local weapon={Parent=enemy,isValid=function() return true end}
          hv={Ship=unit,Weapon=weapon}
          assert(override()==false); callback()
          assert(not record.hostileProjectileHull,'zero-damage contact credited injury')
          assert(override()==false); unit.HitpointsLeft=unit.HitpointsMax*.2; callback(); callback()
          assert(math.abs(record.hostileProjectileHull-.8)<.001,'actual damage missing or duplicate callback credited twice')
          r:RecordServiceStart(unit,2); assert(record.serviceCitationEligible)
          weapon.Parent=unit; override(); r:RecordAIHit(unit,unit,'PROJECTILE'); callback()
          assert(record.serviceCitationEligible and not record.friendlyDamageEpisode,
            'zero-hull-damage friendly projectile contact revoked legitimate recovery')
          weapon.Parent=unit; override(); unit.HitpointsLeft=unit.HitpointsLeft-1; callback()
          assert(record.friendlyDamageEpisode and not record.serviceCitationEligible)
          unit.HitpointsLeft=unit.HitpointsMax
          r:RecordServiceFinish(unit,30,{hullRepaired=unit.HitpointsMax*.8})
          r:RecordFleetCombatKill(unit,enemy)
          assert(not record.citations,'friendly-fire repair farmed recognition')
          hv={}; assert(override()==false); callback()
          hv={Ship=unit,Weapon=weapon}; weapon.Parent=enemy; override()
          r:RecordUnitFate(unit,'LOST','DESTROYED')
          local fresh=r:RecordShipCreated(unit,true)
          unit.HitpointsLeft=unit.HitpointsLeft-100; callback()
          assert(not fresh.hostileProjectileHull,'recycled lifetime inherited the previous collision evidence')
        ''')

    def test_citation_near_controls_do_not_infer_cover_or_useful_rejoin(self):
        self.lua.execute('''
          local unit=ship('Healthy crew',class('GTF Ulysses'),stations.BLUE.Position,mn.Teams.friendly)
          local enemy=ship('Enemy',class('SF Mara'),stations.BLUE.Position,mn.Teams.hostile)
          local evacuee=ship('Nearby crew',class('GTB Medusa'),stations.BLUE.Position,mn.Teams.friendly)
          local record=r:RecordShipCreated(unit); local evac=r:RecordShipCreated(evacuee)
          r:RecordServiceStart(unit,1); r:RecordServiceFinish(unit,20,{hullRepaired=0})
          enemy.Target=evacuee; r:RecordFleetCombatKill(unit,enemy)
          assert(not evac.coverContributors,'uncommitted nearby ship was treated as withdrawing')
          r.Withdrawals[evac.signature]={history=evac.id,faction='BLUE'}
          enemy.Target=nil; r:RecordFleetCombatKill(unit,enemy)
          r:RecordUnitFate(evacuee,'ESCAPED','SHIP_DEPARTED_WARP')
          assert(not record.citations,'proximity or healthy service invented a citation')
          record.hostileProjectileHull=.8; unit.HitpointsLeft=unit.HitpointsMax*.2
          r:RecordServiceStart(unit,30); unit.HitpointsLeft=unit.HitpointsMax
          r:RecordServiceFinish(unit,50,{hullRepaired=0})
          r:RecordFleetCombatKill(unit,enemy)
          assert(not record.citations,'unpaid hull edit invented a recovery')
          local doomed=ship('Lost evacuee',class('GTB Medusa'),stations.BLUE.Position,mn.Teams.friendly)
          local lost=r:RecordShipCreated(doomed)
          r.Withdrawals[lost.signature]={history=lost.id,faction='BLUE'}
          enemy.Target=doomed; r:RecordFleetCombatKill(unit,enemy)
          assert(lost.coverContributors and lost.coverContributors[record.id])
          r:RecordUnitFate(doomed,'LOST','DESTROYED')
          assert(not record.citations,'a failed withdrawal invented an escaped crew')
        ''')

    def test_extraction_expands_display_without_expanding_active_combat_bounds(self):
        self.lua.execute('''
          local half=r:GetTacticalMapHalfExtent(); local commandHalf=r:GetCommandArenaHalfExtent()
          local attacker=ship('Active defender',class('GTF Ulysses'),ba.createVector(0,0,0),mn.Teams.friendly)
          local target=ship('Outside enemy',class('SF Mara'),ba.createVector(half+1000,0,0),mn.Teams.hostile)
          assert(not r:CanAutoEngage(attacker,target))
          r:GetExtractionArea('RED')
          assert(r:GetTacticalMapHalfExtent()>half,'extraction sector is not visible on the map')
          assert(not r:CanAutoEngage(attacker,target),'an extraction sector expanded the active AI chase boundary')
          assert(r:GetCommandArenaHalfExtent()==commandHalf,'ordinary move bounds expanded with extraction')
        ''')

    def test_resumed_defeat_can_become_draw_then_final_survivor_victory(self):
        self.lua.execute('''
          local blue=ship('Blue survivor',class('GTB Medusa'),ba.createVector(0,0,0),mn.Teams.friendly)
          local red=ship('Red survivor',class('SF Mara'),ba.createVector(1000,0,0),mn.Teams.hostile)
          r.GetShipList=function() return {stations.RED,blue,red} end
          r:SetFactionEliminated('BLUE',true); r:SetFactionEliminated('GOLD',true)
          stations.BLUE.HitpointsLeft=0; stations.GOLD.HitpointsLeft=0
          r:EvaluateFactionVictory(); local original=r.StrategicResult
          assert(r.GameStatus=='DEFEAT' and r:ResumePostBattle())
          r:SetFactionEliminated('RED',true); stations.RED.HitpointsLeft=0
          r:EvaluateFactionVictory()
          assert(r.PostBattleActive and r.GameStatus=='DRAW' and not r.FleetFateFinal,
            'destroying the last enemy station during Resume cannot earn a draw')
          assert(r.StrategicResult==original and original.victor=='RED','earlier report history was erased')
          assert(r:ResumePostBattle())
          red.HitpointsLeft=0; r:EvaluateFactionVictory()
          assert(r.PostBattleActive and r.FleetFateFinal and r.GameStatus=='VICTORY',
            'the sole surviving player force did not receive final victory')
          assert(not r:ResumePostBattle(),'final survivor result still has a resumable action')
        ''')

    def test_fully_extracted_player_fleet_is_final_despite_eliminated_leftovers(self):
        """Survivor counts used to be global: a hostile ship left behind by the
        eliminated faction kept mobile above zero, so an escaped player fleet was
        never recognised as settled and the result stayed open."""
        self.lua.execute('''
          local blue=ship('Extracting ship',class('GTB Medusa'),ba.createVector(0,0,0),mn.Teams.friendly)
          local leftover=ship('Eliminated leftover',class('SF Mara'),ba.createVector(3000,0,0),mn.Teams.hostile)
          r.GetShipList=function() return {stations.BLUE,blue,leftover} end
          r:SetFactionEliminated('RED',true); r:SetFactionEliminated('GOLD',true)
          stations.RED.HitpointsLeft=0; stations.GOLD.HitpointsLeft=0
          r:EvaluateFactionVictory()
          assert(r.StrategicResult and r.GameStatus=='VICTORY' and not r.FleetFateFinal,
            'strategic victory did not open the fleet-fate stage')
          assert(r:ResumePostBattle(),'the strategic report did not hand back the battle')
          local record=r:RecordShipCreated(blue)
          r:RecordUnitFate(blue,'ESCAPED','SHIP_DEPARTED_WARP')
          r.GetShipList=function() return {stations.BLUE,leftover} end
          r:EvaluateFactionVictory()
          assert(r.FleetFateFinal,'a fully extracted fleet was not recognised while a hostile leftover remained')
          assert(r.AftermathResultText:find('FLEET EXTRACTED',1,true),'the final report does not say the fleet extracted')
        ''')

    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('package.path=scripts_path.."/?.lua;"..package.path')
        self.lua.execute(SETUP)
        self.lua.execute('''
          r:ResetFleetLife(); r.Enabled=true; r.SetupActive=false; r.ScenarioStartTime=0
          r.SetupFactionCountChoice=3; r:UpdateFactionCount()
          for _,kind in ipairs(r:GetFactionKeys()) do r:SetFactionEliminated(kind,false) end
          r.OpenPostBattle=function(self,text) self.PostBattleActive=true; self.PostBattleResult=text end
          r.AIStates={BLUE={cp=5000},RED={cp=5000},GOLD={cp=5000}}
        ''')

    def test_normal_faction_queries_skip_withdrawal_signature_reads(self):
        self.lua.execute('''
          local friend=ship('Normal friend',class('GTF Ulysses'),stations.BLUE.Position,mn.Teams.friendly)
          local enemy=ship('Normal enemy',class('SF Mara'),stations.RED.Position,mn.Teams.hostile)
          local reads=0
          for _,unit in ipairs({friend,enemy}) do
            local getter=unit.getSignature
            unit.getSignature=function(self) reads=reads+1; return getter(self) end
          end
          assert(r:GetFactionKey(friend)=='BLUE' and r:CanAutoEngage(friend,enemy))
          assert(reads==0,'ordinary IFF queries pay native signature reads for absent withdrawals')
          r.Withdrawals[enemy.signature]={faction='RED',inCorridor=true}
          assert(not r:CanAutoEngage(friend,enemy) and reads>0)
          r.AllowWithdrawal.BLUE=false; assert(r:CanAutoEngage(friend,enemy))
        ''')

    def test_player_defeat_resume_does_not_end_other_economies_or_cancel_strikes(self):
        self.lua.execute('''
          r.BlueEliminated=true; stations.BLUE.HitpointsLeft=0
          r.PendingStrikes={{kind='RED',at=200,cost=750}}
          r:EvaluateFactionVictory()
          assert(r.PostBattleActive and r.GameStatus=='DEFEAT' and not r.StrategicResult)
          assert(not r.AftermathActive and r.BattleVictor==nil,'personal defeat finalized the global battle')
          assert(r:ResumePostBattle() and r.GameStatus=='ACTIVE' and not r.AftermathActive)
          assert(#r.PendingStrikes==1,'opening personal defeat cancelled another faction strike')
          r:EvaluateFactionVictory(); assert(not r.PostBattleActive,'personal defeat reopened every frame')
        ''')

    def test_strategic_snapshot_is_immutable_after_station_loss_and_fleet_survival(self):
        self.lua.execute('''
          r.BlueEliminated=true; r.GoldEliminated=true
          stations.BLUE.HitpointsLeft=0; stations.GOLD.HitpointsLeft=0
          r.PendingStrikes={{kind='RED',at=200}}
          r:EvaluateFactionVictory()
          local result=r.StrategicResult
          assert(result and result.victor=='RED' and r.AftermathActive and #r.PendingStrikes==0)
          r:ResumePostBattle()
          r.RedEliminated=true; stations.RED.HitpointsLeft=0
          r:EvaluateFactionVictory()
          assert(r.StrategicResult==result and r.BattleVictor=='RED','later station loss rewrote the strategic winner')
          assert(result.summary.factions[2].eliminated==false,'immutable result snapshot changed with live flags')
        ''')

    def test_same_frame_mutual_station_loss_records_one_draw(self):
        self.lua.execute('''
          for _,kind in ipairs({'BLUE','RED','GOLD'}) do r:SetFactionEliminated(kind,true); stations[kind].HitpointsLeft=0 end
          r:EvaluateFactionVictory()
          assert(r.StrategicResult.victor=='NONE' and r.GameStatus=='DRAW' and r.AftermathActive)
          local result=r.StrategicResult; r:ResumePostBattle(); r:EvaluateFactionVictory()
          assert(r.StrategicResult==result,'draw was replaced after resume')
        ''')

    def test_archive_keeps_original_wing_and_reused_signature_has_a_fresh_lifetime(self):
        self.lua.execute('''
          local unit=ship('First Orion',class('GTD Orion'),stations.BLUE.Position,mn.Teams.friendly)
          local record=r:RecordShipCreated(unit); local wing=r:RegisterLogicalWing({unit},'Alpha')
          assert(record.originalWing==wing.id and #r.WingHistory[wing.id].members==1)
          r.BountyProcessed={[unit:getSignature()]=true}
          assert(r:RecordUnitFate(unit,'LOST','DESTROYED') and not r:RecordUnitFate(unit,'ESCAPED','WARP'))
          assert(r:RecordShipCreated(unit)==record,'terminal native callback window invented another commission')
          local fresh=r:RecordShipCreated(unit,true)
          assert(fresh.id~=record.id and fresh.fate=='PRESENT' and not r.BountyProcessed[unit:getSignature()])
          assert(r.UnitHistory[record.id].fate=='LOST' and r.WingHistory[wing.id].members[1]==record.id)
          r:ResetFleetLife(); assert(next(r.UnitHistory)==nil and next(r.Withdrawals)==nil and r.ExtractionExtent==nil)
        ''')

    def test_damage_recovery_and_pilot_time_require_real_transitions(self):
        self.lua.execute('''
          local unit=ship('Recovery',class('GTF Ulysses'),stations.BLUE.Position,mn.Teams.friendly)
          local record=r:RecordShipCreated(unit)
          r:RecordServiceStart(unit,0); r:RecordServiceFinish(unit,5)
          assert(record.serviceVisits==1 and record.recoveries==0,'healthy rearm invented a damaged recovery')
          unit.HitpointsLeft=unit.HitpointsMax*.3; r:RecordServiceStart(unit,6)
          unit.HitpointsLeft=unit.HitpointsMax; r:RecordServiceFinish(unit,20)
          assert(record.recoveries==1)
          r:RecordPilotTime(unit,30,true); r:RecordPilotTime(unit,45,false); r:RecordPilotTime(unit,46,false)
          assert(record.pilotSeconds==15,'pilot duration double-counted an exit callback')
        ''')

    def test_last_original_wing_member_notice_waits_for_terminal_fate(self):
        self.lua.execute('''
          local first=ship('Alpha 1',class('GTF Ulysses'),stations.BLUE.Position,mn.Teams.friendly)
          local last=ship('Alpha 2',class('GTF Ulysses'),stations.BLUE.Position,mn.Teams.friendly)
          local wing=r:RegisterLogicalWing({first,last},'Alpha')
          local history=r.WingHistory[wing.id]
          assert(#history.members==2)
          r:RecordUnitFate(first,'LOST','DESTROYED')
          assert(history.lastOriginalFateNotice==nil,'notice fired before the other original member left')
          r:RecordUnitFate(last,'ESCAPED','SHIP_DEPARTED_WARP')
          assert(history.lastOriginalFateNotice=='ESCAPED'
            and r.StatusMessage:find('LAST ORIGINAL MEMBER OF Alpha ESCAPED',1,true),
            'last original wing fate was not reported accurately')
        ''')

    def test_music_click_uses_music_index_not_large_backdrop_index(self):
        self.lua.execute('''
          r.EnvironmentPicker=true
          r.Config.Music={Tracks={'one','two','three'}}
          r.Config.Environment={NebulaBackdrops={}}
          for i=1,40 do r.Config.Environment.NebulaBackdrops[i]='scene '..i end
          r.EnvironmentMusicIndex=nil; r.EnvironmentBackdropIndex=36
          r.EnvironmentButtonRects={music_next={x1=1,y1=1,x2=10,y2=10}}
          r.PointInside=function(self,rect,x,y) return x>=rect.x1 and x<=rect.x2 and y>=rect.y1 and y<=rect.y2 end
          ad={playMusic=true}
          r.SetEnvironmentMusic=function(self,choice) self.appliedMusic=choice end
          r:HandleFleetLifeClick(5,5)
          assert(r.SetupMusicChoice==2 and r.appliedMusic==2 and r.EnvironmentBackdropIndex==36,
            'music next used the unset music index fallback from backdrop 36')
        ''')

    def test_withdrawal_is_irreversible_and_only_confirmed_departure_marks_escape(self):
        self.lua.execute('''
          local unit=ship('Extract',class('GTF Ulysses'),stations.BLUE.Position,mn.Teams.friendly)
          unit.flags={}
          function unit:getFlag(flag) return self.flags[flag]==true end
          function unit:setFlag(value,flag) self.flags[flag]=value end
          local record=r:RecordShipCreated(unit)
          assert(not r:BeginShipWithdrawal(unit),'healthy faction withdrew before defeat/result')
          r:SetShipCommandDiscipline(unit,true)
          assert(unit:getFlag('no-dynamic'),'fixture: a prior move owns the native movement lock')
          r.BlueEliminated=true
          assert(r:BeginShipWithdrawal(unit) and r.Withdrawals[unit:getSignature()].destination)
          assert(not unit:getFlag('no-dynamic'),'withdrawal still suppresses native missile evasion')
          r.NextFleetLife=0; r:UpdateFleetLife(.5)
          assert(not unit:getFlag('no-dynamic'),'the withdrawal tick re-enabled no-dynamic')
          local route=r.Withdrawals[unit:getSignature()].destination
          assert(r:BeginShipWithdrawal(unit) and r.Withdrawals[unit:getSignature()].destination==route)
          assert(not r:IsMovableFriendly(unit) and not r:BeginFleetService(unit,'MANUAL',0,true))
          assert(record.fate=='PRESENT','commitment fabricated escape')
          r:OnShipDeparture(unit,'SHIP_DEPARTED_WARP')
          assert(record.fate=='ESCAPED' and not r.Withdrawals[unit:getSignature()])
          r:OnShipDeparture(unit,'SHIP_DEPARTED_WARP')
          assert(r:GetFleetHistorySummary().escaped==1,'repeated departure duplicated escape credit')
        ''')

    def test_corridor_permission_keeps_logical_faction_and_hostile_attribution(self):
        self.lua.execute('''
          local unit=ship('Withdrawing hostile',class('SF Mara'),stations.RED.Position,mn.Teams.hostile)
          local friend=ship('Combatant',class('GTF Ulysses'),stations.BLUE.Position,mn.Teams.friendly)
          r.RedEliminated=true; r:BeginShipWithdrawal(unit)
          local w=r.Withdrawals[unit:getSignature()]
          assert(r:CanAutoEngage(friend,unit),'exposed withdrawal gained immediate ceasefire')
          mn.Teams['RTS Passage']={Name='RTS Passage',isValid=function() return true end,attacks=function() return false end}
          r:EnterPassageCorridor(unit,w)
          assert(r:GetFactionKey(unit)=='RED' and r:AreEnemies(friend,unit),'passage erased faction identity/hostility')
          assert(not r:CanAutoEngage(friend,unit),'automatic acquisition ignored corridor permission')
          r.AllowWithdrawal.BLUE=false
          assert(r:CanAutoEngage(friend,unit),'explicit intercept policy did not allow engagement')
        ''')

    def test_automatic_targets_outside_map_are_rejected_but_manual_passage_intercepts_remain(self):
        self.lua.execute('''
          local attacker=ship('Arena attacker',class('GTF Ulysses'),ba.createVector(0,0,0),mn.Teams.friendly)
          local target=ship('Outside target',class('SF Mara'),ba.createVector(26000,0,0),mn.Teams.hostile)
          assert(r:AreEnemies(attacker,target) and not r:CanAutoEngage(attacker,target),
            'automatic targeting followed a hostile beyond the tactical map')
          assert(not r:AIContextEnemies(attacker,{ship=target,position=target.Position},'BLUE',attacker.Team),
            'spatial AI threat strength still counted an out-of-map target')
          r.Withdrawals[target:getSignature()]={faction='RED',inCorridor=true}
          r.AllowWithdrawal.BLUE=false
          assert(r:CanAutoEngage(attacker,target),
            'explicit corridor interception was blocked by the ordinary world boundary')
          local localTarget=ship('Inside target',class('SF Mara'),ba.createVector(500,0,0),mn.Teams.hostile)
          assert(r:CanAutoEngage(attacker,localTarget))
        ''')

    def test_intercept_policy_acquires_only_in_reach_and_respects_manual_orders(self):
        self.lua.execute('''
          local passage={Name='RTS Passage',isValid=function() return true end,
            attacks=function() return false end}
          mn.Teams['RTS Passage']=passage
          local automatic=ship('Auto interceptor',class('GTF Ulysses'),ba.createVector(0,0,0),mn.Teams.friendly)
          local inRange=ship('Near withdrawal',class('SF Mara'),ba.createVector(600,0,0),passage)
          local outOfRange=ship('Far withdrawal',class('GVF Serapis'),ba.createVector(2500,0,0),passage)
          local held=ship('Manual hold',class('GTF Ulysses'),ba.createVector(0,0,0),mn.Teams.friendly)
          local explicit=ship('Manual intercept',class('GTF Ulysses'),ba.createVector(0,0,0),mn.Teams.friendly)
          for _,unit in ipairs({automatic,inRange,outOfRange,held,explicit}) do
            for i=1,#unit do unit[i].targetingOverride=function() end end
          end
          r.GetShipList=function() return {automatic,inRange,outOfRange,held,explicit} end
          r.Withdrawals={[inRange:getSignature()]={faction='RED',inCorridor=true},
            [outOfRange:getSignature()]={faction='GOLD',inCorridor=true}}
          r.AllowWithdrawal={BLUE=false}; r.UserOrders={}
          inRange.Radius=100; outOfRange.Radius=100
          automatic.Target=nil; held.Target=nil; explicit.Target=nil
          r.UserOrders[held:getSignature()]={kind='hold'}
          r.UserOrders[explicit:getSignature()]={kind='attack',targetSignature=inRange:getSignature()}
          r:UpdatePassageInterception()
          assert(automatic.Target==inRange and automatic[1].Target==inRange,
            'intercept policy did not acquire the nearest passage target within weapon reach')
          assert(automatic.Target~=outOfRange and held.Target==nil and held[1].Target==nil,
            'automatic acquisition exceeded effective reach or overrode a manual hold')
          assert(explicit.Target==inRange and explicit[1].Target==inRange,
            'explicit attack on a passage target was not honored')
          r.UserOrders[explicit:getSignature()]={kind='attack',targetSignature=outOfRange:getSignature()}
          explicit.Target=nil; r:UpdatePassageInterception()
          assert(explicit.Target==nil and explicit[1].Target==nil,
            'explicit attack was redirected to another in-range passage ship')
          r.UserOrders[explicit:getSignature()]={kind='attack',targetSignature=inRange:getSignature()}
          local autoSig=automatic:getSignature()
          assert(r.PassageTurretOverrides[autoSig].targetSignature==inRange:getSignature())
          r.AllowWithdrawal.BLUE=nil; automatic.Target=nil; r:UpdatePassageInterception()
          assert(automatic.Target==nil and automatic[1].Target==nil,
            'restoring passage policy left the automatic interception target assigned')
          explicit.Target=nil; r:UpdatePassageInterception()
          assert(explicit.Target==inRange and explicit[1].Target==inRange,
            'Allow Withdrawal overrode an explicit player intercept order')
        ''')

    def test_departure_clears_rearguard_and_passage_target_ownership(self):
        self.lua.execute('''
          local passage={Name='RTS Passage',isValid=function() return true end,
            attacks=function() return false end}
          mn.Teams['RTS Passage']=passage
          local attacker=ship('Interceptor',class('GTD Hecate'),ba.createVector(0,0,0),mn.Teams.friendly)
          local exiting=ship('Departing withdrawal',class('SF Mara'),ba.createVector(500,0,0),passage)
          for i=1,#attacker do attacker[i].targetingOverride=function() end end
          local signature=exiting:getSignature()
          r.GetShipList=function() return {attacker,exiting} end
          r.Withdrawals={[signature]={faction='RED',inCorridor=true}}
          local record=r:RecordShipCreated(exiting)
          r.ExtractionAreas={RED={slots={[signature]={point=exiting.Position}}}}
          r.PassageTurretOverrides={[attacker:getSignature()]={targetSignature=signature}}
          attacker.Target=exiting; attacker[1].Target=exiting
          r:OnShipDeparture(exiting,'SHIP_DEPARTED_WARP')
          assert(record.fate=='ESCAPED' and not r.Withdrawals[signature])
          assert(attacker.Target==nil and attacker[1].Target==nil
            and r.PassageTurretOverrides[attacker:getSignature()]==nil,
            'departure left native passage target/override references active')
          assert(r.ExtractionAreas.RED.slots[signature]==nil,'departure kept its extraction slot')
        ''')

    def test_death_clears_passage_turrets_rearguard_and_pursuit(self):
        self.lua.execute('''
          local passage={Name='RTS Passage',isValid=function() return true end,
            attacks=function() return false end}
          mn.Teams['RTS Passage']=passage
          local attacker=ship('Rearguard',class('GTD Hecate'),ba.createVector(0,0,0),mn.Teams.friendly)
          local dead=ship('Lost withdrawal',class('SF Mara'),ba.createVector(500,0,0),passage)
          for i=1,#attacker do attacker[i].targetingOverride=function() end end
          local signature=dead:getSignature(); local attackerSignature=attacker:getSignature()
          r.GetShipList=function() return {attacker,dead} end
          r.Withdrawals={[signature]={faction='RED',inCorridor=true}}
          r.PassageTurretOverrides={[attackerSignature]={targetSignature=signature}}
          r.ExtractionAreas={RED={slots={[signature]={point=dead.Position}}}}
          r.AIPursuit={[attackerSignature]={targetSignature=signature}}
          attacker.Target=dead; attacker[1].Target=dead
          r.BountyProcessed={}; r.AIStats=nil
          r.GetStrategicUnitValue=function() return 100 end
          r:OnShipDeath(dead,nil)
          assert(not r.Withdrawals[signature] and not r.ExtractionAreas.RED.slots[signature],
            'death kept extraction ownership')
          assert(attacker.Target==nil and attacker[1].Target==nil
            and r.PassageTurretOverrides[attackerSignature]==nil,
            'death left a passage turret/target reference active')
          assert(r.AIPursuit[attackerSignature]==nil,'death kept a stale pursuit assignment')
        ''')

    def test_defeated_ai_withdraws_while_a_rearguard_attacks_the_killer(self):
        self.lua.execute('''
          local area={home=ba.createVector(-5000,0,0),homeRadius=1000,direction=ba.createVector(1,0,0),
            center=ba.createVector(-30000,0,0),radius=8000,slots={}}
          r.ExtractionExtent=50000; r.ExtractionAreas={RED=area}; r.GetExtractionArea=function() return area end
          local killer=ship('Killer wing',class('GTF Myrmidon'),ba.createVector(-3000,0,-900),mn.Teams.friendly)
          local guard=ship('Defeated escort',class('GTC Aeolus'),ba.createVector(-5000,0,-900),mn.Teams.hostile)
          local withdrawer=ship('Defeated fighter',class('GTF Ulysses'),ba.createVector(-7000,0,0),mn.Teams.hostile)
          killer.role='fighter'; guard.role='escort'; withdrawer.role='fighter'
          r.AIProfile=function(self,unit) return {armed=unit==guard} end
          r.GetShipRole=function(self,unit) return unit.role end
          for _,unit in ipairs({guard,withdrawer}) do
            unit.Orders={}
            unit.clearOrders=function(self) self.Orders={} end
            unit.giveOrder=function(self,kind,target) self.Orders[#self.Orders+1]={kind=kind,target=target}; return true end
          end
          r.GetShipList=function() return {stations.BLUE,stations.RED,stations.GOLD,killer,guard,withdrawer} end
          r.SetShipCommandDiscipline=function() end; r.SetShipTurretLock=function() end
          r.RecordAITransition=function() end; r.RecordAIOrderTelemetry=function() end
          r.AIOrderState={}; r.AIPursuit={}; r.UserOrders={}; r.Withdrawals={}
          r.FactionDefeatedBy={RED='BLUE'}
          r:UpdateDefeatedFleetExtraction(29)
          assert(not r:IsShipWithdrawing(guard) and not r:IsShipWithdrawing(withdrawer)
            and r.ExtractionOperations.RED==nil,
            'living station did not keep its AI fleet in the battle')
          r:SetFactionEliminated('RED',true)
          stations.RED.HitpointsLeft=0
          r:UpdateDefeatedFleetExtraction(30)
          local op=r.ExtractionOperations.RED
          assert(op.rearguardSignature==guard:getSignature() and not r:IsShipWithdrawing(guard)
            and r:IsShipWithdrawing(withdrawer),'one cover group and the withdrawing fleet were not separated')
          assert(r.AIOrderState[guard:getSignature()].reason=='RETALIATE_BASE_KILLER'
            and r.AIOrderState[guard:getSignature()].targetSignature==killer:getSignature()
            and guard.Orders[#guard.Orders].kind==ORDER_ATTACK,
            'rear element did not retaliate against the credited base killer')
          local extent=r:GetTacticalMapHalfExtent()
          assert(math.abs(r.Withdrawals[withdrawer:getSignature()].destination.x)<=extent
            and math.abs(r.Withdrawals[withdrawer:getSignature()].destination.z)<=extent,
            'defeated fleet extraction destination is beyond the expanded tactical map')
          local withdrawal=r.Withdrawals[withdrawer:getSignature()]
          local warpCalls=0
          withdrawer.Position=withdrawal.destination
          withdrawer.warpOut=function() warpCalls=warpCalls+1; return true end
          r.EnterPassageCorridor=function(self,unit,route) route.inCorridor=true; return true end
          r.UpdatePassageInterception=function() end
          r.NextFleetLife=0; r:UpdateFleetLife(31)
          assert(warpCalls==1 and withdrawal.departureStarted,
            'automatically withdrawing defeated AI never attempted native warpOut at its departure point')
        ''')


if __name__ == '__main__':
    unittest.main()
