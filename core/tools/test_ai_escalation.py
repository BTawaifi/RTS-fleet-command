"""Tier-five unlock and one-juggernaut AI production checks."""
import unittest
from pathlib import Path

from lupa.lua51 import LuaRuntime

SCRIPTS = Path(__file__).resolve().parents[1] / "data/scripts"


class EscalationTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().scripts_path = SCRIPTS.resolve().as_posix()
        self.lua.execute('''
          package.path=scripts_path.."/?.lua;"..package.path
          -- The full fs2rts_util surface, not just clamp and sortedNumericKeys.
          -- fs2rts_factions/fs2rts_production/fs2rts_ai_production bind all twelve
          -- helpers as upvalues; the nine that used to be missing here were NIL,
          -- so any path reaching one failed on "attempt to call a nil value"
          -- instead of on a real assertion. Semantics mirror
          -- data/scripts/fs2rts_util.lua exactly.
          local Vec={}; Vec.__index=Vec
          function Vec.__add(a,b) return ba.createVector(a.x+b.x,a.y+b.y,a.z+b.z) end
          function Vec.__sub(a,b) return ba.createVector(a.x-b.x,a.y-b.y,a.z-b.z) end
          function Vec.__mul(a,b) return ba.createVector(a.x*b,a.y*b,a.z*b) end
          function Vec.__div(a,b) return ba.createVector(a.x/b,a.y/b,a.z/b) end
          function Vec.__unm(a) return ba.createVector(-a.x,-a.y,-a.z) end
          ba={createVector=function(x,y,z) return setmetatable({x=x,y=y,z=z},Vec) end}
          local function objValid(o) return o~=nil and o:isValid() end
          package.preload.fs2rts_util=function()
            return {clamp=function(v,a,b) return math.max(a,math.min(b,v)) end,
              lower=function(v) if v==nil then return '' end return string.lower(tostring(v)) end,
              vec=ba.createVector, copyVec=function(v) return ba.createVector(v.x,v.y,v.z) end,
              distance2=function(x1,y1,x2,y2) local dx=x1-x2; local dy=y1-y2; return dx*dx+dy*dy end,
              objectValid=objValid,
              shipValid=function(s) return objValid(s) and s:getBreedName()=='Ship' end,
              shipAlive=function(s) return objValid(s) and not s:isDying() and (tonumber(s.HitpointsLeft) or 0)>0 end,
              teamName=function(s) if not objValid(s) then return '' end return string.lower(tostring(s.Team.Name)) end,
              tableContainsSignature=function(list,sig)
                for _,v in ipairs(list or {}) do if v==sig then return true end end
                return false end,
              sortedNumericKeys=function(t) local r={}; for k in pairs(t) do r[#r+1]=k end; table.sort(r); return r end,
              AI_FACTION_ORDER={'BLUE','RED','GOLD'}}
          end
          R={}; package.preload.fs2rts_state=function() return R end
          C=require "fs2rts_config"; R.Config=C
          require "fs2rts_factions"; require "fs2rts_production"; require "fs2rts_ai_production"
          R.SetupActive=false; R.ScenarioStartTime=0; R.SetupDurationIndex=1
          R.GetFleetCap=function() return 64 end
          R.CountCommittedCombatants=function() return 0 end
          R.GetPurchaseEstimate=function(self,class,tier,count) return {cost=50,time=10} end
          R.CountAIRoleUnits=function(self) return self.testCounts,self.testValues end
          R.testCounts={fighter=0,bomber=0,escort=0,capital=0,juggernaut=0,total=0}
          R.testValues={fighter=0,bomber=0,escort=0,capital=0,total=0}
          tb={ShipClasses={}}
          for _,kind in ipairs({'BLUE','RED','GOLD'}) do
            for _,entry in ipairs(R:GetAIRoster(kind)) do
              tb.ShipClasses[entry.class]={isValid=function() return true end}
            end
          end
        ''')

    def test_every_cp_movement_emits_a_ledger_record(self):
        """RecordAIEconomyFlow is the single chokepoint every CP movement in the
        mod passes through: SpendFactionCP calls it after deducting, and the
        production paths call it directly. Two of the sinks that reach it - the
        station upgrade track (BuyUpgrade) and the faction ability
        (QueueOrbitalStrike, 750 CP) - publish no purchase event of their own,
        which left ~10% of productionSpend unattributable from a batch. The
        ledger exists so those deductions are individually visible without any
        caller having to change, and so a sink that stops recording shows up as
        ledger/flow drift instead of a silent gap."""
        self.lua.execute('''
          require "fs2rts_ai_telemetry"(R)
          R.CombatTelemetryEnabled=true
          R.bank={BLUE=5000,RED=5000,GOLD=5000}
          R.GetFactionCP=function(self,kind) return self.bank[kind] end
          R.ledger={}
          R.EmitAIEvent=function(self,name,data,now)
            self.ledger[#self.ledger+1]={name=name,data=data}
          end
          mn={getMissionTime=function() return 1234 end}

          R.bank.BLUE=5000
          R:RecordAIEconomyFlow("BLUE","productionSpend",625)
          R.bank.BLUE=2000
          R:RecordAIEconomyFlow("BLUE","productionSpend",750)
          assert(#R.ledger==2,'each spend must emit exactly one ledger record: '..#R.ledger)
          assert(R.ledger[1].name=='CP_SPEND' and R.ledger[2].name=='CP_SPEND')
          assert(R.ledger[1].data.amount==625 and R.ledger[1].data.faction=='BLUE')
          -- cpAfter is read after the deduction, so cpBefore recovers the
          -- pre-deduction balance and the two must bracket the charge.
          assert(R.ledger[1].data.cpAfter==5000 and R.ledger[1].data.cpBefore==5625,
            'ledger bracket is wrong: '..tostring(R.ledger[1].data.cpAfter)..'/'..tostring(R.ledger[1].data.cpBefore))
          assert(R.ledger[2].data.cpAfter==2000 and R.ledger[2].data.cpBefore==2750)
          -- the interval flow is untouched by the ledger and still accumulates
          assert(R.AIEconomyFlow.BLUE.productionSpend==1375)

          -- refunds are CP movements too, and carry the same bracket
          R.bank.BLUE=900
          R:RecordAIEconomyFlow("BLUE","refund",900)
          assert(R.ledger[3].data.flow=='refund' and R.ledger[3].data.cpBefore==1800)

          -- income and bounty are not deductions: they need no purchase event
          -- to reconcile against, so they must not add ledger volume on a path
          -- the service loop runs every tick.
          local before=#R.ledger
          R:RecordAIEconomyFlow("BLUE","income",333)
          R:RecordAIEconomyFlow("BLUE","bounty",64)
          assert(#R.ledger==before,'income/bounty must not emit ledger records')
          assert(R.AIEconomyFlow.BLUE.income==333 and R.AIEconomyFlow.BLUE.bounty==64)

          -- telemetry off means no ledger at all, so a shipped build pays nothing
          R.CombatTelemetryEnabled=false
          R:RecordAIEconomyFlow("BLUE","productionSpend",100)
          assert(#R.ledger==before,'ledger must stay silent when telemetry is off')
        ''')

    def test_duration_profiles_reach_late_tier_five(self):
        self.lua.execute('''
          R.ScenarioStartTime=0
          assert(R:GetCurrentEscalationTier(1379)==4)
          assert(R:GetCurrentEscalationTier(1380)==5)
          R.SetupDurationIndex=2
          assert(R:GetCurrentEscalationTier(2759)==4)
          assert(R:GetCurrentEscalationTier(2760)==5)
          assert(R.Config.ProductionClasses[#R.Config.ProductionClasses].tier==5)
        ''')

    def test_escalation_follows_the_game_clock_so_time_skip_works(self):
        """Regression: 1.4.1 drove the tiers off a wall-clock accumulator, which
        made the tier schedule the only thing in the match that ignored the speed
        control. Tiers must advance with mission time, and the removed clock must
        not come back."""
        self.lua.execute('''
          R.ScenarioStartTime=0; R.SetupDurationIndex=nil
          assert(R.GetRealScenarioElapsed==nil and R.AdvanceRealElapsed==nil,
            'the wall-clock scenario timer is back; escalation will ignore time skip again')
          -- Default 30 MIN profile unlocks tiers at {0,240,570,1050,1380}.
          assert(R:GetCurrentEscalationTier(0)==1)
          assert(R:GetCurrentEscalationTier(200)==1)
          assert(R:GetCurrentEscalationTier(300)==2)
          assert(R:GetCurrentEscalationTier(600)==3)
          assert(R:GetCurrentEscalationTier(1100)==4)
          assert(R:GetCurrentEscalationTier(1400)==5)
          -- The HUD countdown and the tier must agree, or the top bar lies about
          -- when the next unlock lands.
          local remaining=R:GetTierUnlockRemaining(2,200)
          assert(remaining==240-200,
            'tier countdown used a different clock than the tier itself: '..tostring(remaining))
        ''')

    def test_ai_can_repeat_juggernauts_when_budget_allows(self):
        self.lua.execute('''
          R.GetCurrentEscalationTier=function() return 5 end
          local state={cp=10000}
          local selected,decision=R:ChooseAIBuild('BLUE',state,1500)
          assert(selected and selected.entry.class=='GTVA Colossus',
            'Blue did not select its available tier-five Colossus')
          R.testCounts.juggernaut=4
          selected,decision=R:ChooseAIBuild('BLUE',state,1501)
          assert(selected and selected.entry.role=='juggernaut',
            'AI applied an unintended hard juggernaut cap')
          R.testCounts.juggernaut=5
          selected,decision=R:ChooseAIBuild('BLUE',state,1502)
          assert(selected and selected.entry.role=='juggernaut',
            'AI could not repeat a juggernaut purchase with enough CP and fleet capacity')
          local redSathanas
          for _,entry in ipairs(R.Config.AI.RedRoster) do
            if entry.class=='SJ Sathanas' then redSathanas=entry end
          end
          assert(redSathanas and redSathanas.tier==5)
          assert(R.Config.CostFormula.GlobalMultiplier==1.25)
          assert(R.Config.CostFormula.RoleMultipliers.juggernaut==0.14)
          assert(R.Config.CostFormula.ClassMultipliers['GVD Hatshepsut']==0.30)
          assert(R.Config.CostFormula.ClassMultipliers['SD Ravana']==0.30)
          assert(R.Config.CostFormula.ClassMultipliers['GTVA Colossus']==0.50)
          assert(R.Config.CostFormula.ClassMultipliers['SJ Sathanas']==0.65)
          assert(R.Config.CostFormula.ClassMultipliers['SD Lucifer']==1.25)
          assert(R.Config.AI.MaxJuggernautsPerFaction==nil)
          assert(R.Config.AI.CapitalSavingSeconds==600)
          assert(R.Config.AI.HeavyCapitalSavingSeconds==900)
          local hull={Name='test',HitpointsMax=1000000,ShieldHitpointsMax=100000,
            VelocityMax={z=100},Model={Radius=4000},isValid=function() return true end}
          R.ShipCostRoleMap={test='juggernaut'}
          local discounted=R:EstimateShipCost(hull)
          R.ShipCostRoleMap={}
          local standard=R:EstimateShipCost(hull)
          assert(discounted.cost<standard.cost*0.18,'juggernaut role multiplier did not affect hull cost')
          for className,maxRatio in pairs({['GTVA Colossus']=0.08,['SJ Sathanas']=0.10,['SD Lucifer']=0.18}) do
            hull.Name=className; R.ShipCostRoleMap={[className]='juggernaut'}
            discounted=R:EstimateShipCost(hull)
            hull.Name='unadjusted'; R.ShipCostRoleMap={}
            standard=R:EstimateShipCost(hull)
            assert(discounted.cost<standard.cost*maxRatio,className..' price was not normalized to lifetime CP')
          end
          hull.Name='SD Ravana'; R.ShipCostRoleMap={}
          discounted=R:EstimateShipCost(hull)
          hull.Name='unadjusted'; standard=R:EstimateShipCost(hull)
          assert(discounted.cost<standard.cost*0.31,'Ravana class price normalization was not applied')
          R.AIStates={}; R.testCounts.juggernaut=4
          R.BuildQueue={{option={role='juggernaut',count=1}},{option={role='juggernaut',count=1}},
            {option={role='juggernaut',count=1}},{option={role='juggernaut',count=1}}}
          R.CommandPoints=100000
          R.GameStatus='ACTIVE'; R.SetupActive=false; R.Enabled=true
          R.GetCarrier=function() return {} end; R.IsBuildOptionUnlocked=function() return true end
          R.CountCommittedCombatants=function() return 0 end; R.SetStatus=function(self,s) self.status=s end
          R.EmitAIEvent=function(self,n,d) self.lastEvent={name=n,data=d} end
          R.RecordAIEconomyFlow=function() end; R.FormatTime=function() return '' end
          mn={getMissionTime=function() return 0 end}
          local jug={class='GTVA Colossus',label='Colossus',role='juggernaut',tier=5,count=1,cost=100,time=10}
          R:QueueBuildOption(jug)
          assert(#R.BuildQueue==5,'player was incorrectly blocked after queuing four juggernauts')
        ''')

    def test_late_juggernaut_investment_has_a_bounded_save_window(self):
        self.lua.execute('''
          R.GetCurrentEscalationTier=function() return 5 end
          local state={cp=0}
          local choice,decision=R:ChooseAIBuild('BLUE',state,0)
          assert(not choice and decision.reason=='SAVING_FOR_DESIRED_ROLE')
          choice,decision=R:ChooseAIBuild('BLUE',state,599.99)
          assert(not choice and decision.reason=='SAVING_FOR_DESIRED_ROLE')
          choice,decision=R:ChooseAIBuild('BLUE',state,600)
          assert(not choice and decision.savingFallback and decision.reason=='INSUFFICIENT_CP',
            'late capital saving did not release the fleet after its configured window')
          assert(R.Config.AI.JuggernautSavingSeconds==600)
        ''')

    def test_role_changes_do_not_restart_the_saving_window(self):
        self.lua.execute('''
          R.GetCurrentEscalationTier=function() return 5 end
          local state={cp=0}
          local choice,decision=R:ChooseAIBuild('BLUE',state,0)
          assert(not choice and decision.reason=='SAVING_FOR_DESIRED_ROLE')
          R.Config.AI.CompositionTargets[5]={fighter=1,bomber=0,escort=0,capital=0}
          choice,decision=R:ChooseAIBuild('BLUE',state,100)
          assert(not choice and decision.reason=='SAVING_FOR_DESIRED_ROLE')
          choice,decision=R:ChooseAIBuild('BLUE',state,120)
          assert(not choice and decision.savingFallback,
            'changing the desired role restarted an already-running save window')
          assert(state.savingSince==0)
        ''')

    def test_capital_savings_scale_by_escalation_and_remain_bounded(self):
        self.lua.execute('''
          local windows={[3]=600,[4]=900,[5]=600}
          for tier,seconds in pairs(windows) do
            R.GetCurrentEscalationTier=function() return tier end
            local state={cp=0}
            local choice,decision=R:ChooseAIBuild('BLUE',state,0)
            assert(not choice and decision.reason=='SAVING_FOR_DESIRED_ROLE')
            choice,decision=R:ChooseAIBuild('BLUE',state,seconds-.01)
            assert(not choice and decision.reason=='SAVING_FOR_DESIRED_ROLE')
            choice,decision=R:ChooseAIBuild('BLUE',state,seconds)
            assert(not choice and decision.savingFallback,
              'tier '..tier..' never released its bounded capital savings')
          end
        ''')


if __name__ == "__main__":
    unittest.main()
