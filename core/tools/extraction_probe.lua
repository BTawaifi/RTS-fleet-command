-- Native proof of passage, explicit interception and confirmed departure.
local R=require 'fs2rts'
local out=cf.openFile('extraction-probe.log','w','data')
assert(out and out:isValid())
local function log(s) out:write(s..'\n'); out:flush() end
local function check(v,s) assert(v,s); log('PASS '..s) end
local finished=false; local phase=0; local started=0
local target,fighter,capital,escapee,survivor,routeProbe; local initialHealth; local departed=0; local capitalHits=0
local escapeRecord,survivorRecord; local unresolvedIncome; local automaticStart
local original=R.OnFrame
local production=R.UpdateAIProduction
R.Config.Cinematic.Enabled=false
for _,name in ipairs({'UpdateAIProduction','UpdateEnemyWaves','UpdateStations','UpdateAIStrategicObjectives','UpdateDefaultPolicy'}) do R[name]=function() end end
R.UpdateFleetServices=function() end -- isolate target eligibility from automatic recovery
engine.addHook('On Ship Depart',function() if escapee and hv.Ship and hv.Ship:getSignature()==escapee:getSignature() then departed=departed+1 end end)
engine.addHook('On Beam Collision',function()
    if capital and hv.Ship and target and hv.Ship:getSignature()==target:getSignature()
        and hv.Beam.ParentShip:isValid() and hv.Beam.ParentShip:getSignature()==capital:getSignature() then capitalHits=capitalHits+1 end
end)
engine.addHook('On Weapon Collision',function()
    if capital and hv.Ship and target and hv.Ship:getSignature()==target:getSignature()
        and hv.Weapon.Parent:isValid() and hv.Weapon.Parent:getSignature()==capital:getSignature() then capitalHits=capitalHits+1 end
end)
local function quit() finished=true; R:SetTimeScale(1); ba.postGameEvent(ba.GameEvents.GS_EVENT_QUIT_GAME) end
engine.addHook('On Frame',function() if finished then ba.postGameEvent(ba.GameEvents.GS_EVENT_QUIT_GAME) end end)
local function spawn(name,class,pos,team)
    local s=mn.createShip(name,tb.ShipClasses[class],nil,ba.createVector(pos[1],pos[2],pos[3]),team,true)
    check(s and s:isValid(),'created '..name); R:InvalidateShipList(); s:clearOrders(); return s
end
local function run()
    local now=mn.getMissionTime()
    if phase==0 then
        if not R.SetupActive or not R.RosterModelWarmup or not R.RosterModelWarmup.done then return end
        R.SetupFactionCountChoice=3; R.SetupAutoMode=false; R.SetupSentries=false; R:StartScenario()
        check(not R.SetupActive,'scenario started')
        local team=mn.Teams['RTS Passage']; check(team and team:isValid(),'native passage IFF exists')
        check(not mn.Teams.friendly:attacks(team) and not mn.Teams.hostile:attacks(team),'all-teams-war exempts passage')
        target=spawn('Passage Target','GTC Fenris',{0,0,0},team)
        target.HitpointsMax=200000; target.HitpointsLeft=200000
        target:giveOrder(ORDER_PLAY_DEAD,nil,nil,.99)
        fighter=spawn('Passage Fighter','GTF Ulysses',{0,0,-1000},mn.Teams.friendly)
        fighter:giveOrder(ORDER_GUARD,R:GetCarrier(),nil,.95)
        capital=spawn('Passage Capital','GTD Hecate',{2500,0,0},mn.Teams.friendly)
        capital.Orientation=ba.createOrientationFromVectors(ba.createVector(-1,0,0))
        R:EnableFullArsenal(capital)
        capital:giveOrder(ORDER_STAY_STILL,nil,nil,.95)
        R:SetShipTurretLock(capital,false)
        initialHealth=target.HitpointsLeft+target.Shields.CombinedLeft
        phase=1; started=now; R:SetTimeScale(4)
    elseif phase==1 and now-started>=10 then
        check(target:isValid() and target.HitpointsLeft+target.Shields.CombinedLeft==initialHealth,'autonomous guns honor passage without damage immunity')
        R.Withdrawals[target:getSignature()]={faction='RED',inCorridor=true,phase='IN DEPARTURE CORRIDOR'}
        R.AllowWithdrawal.BLUE=false
        R.UserOrders[fighter:getSignature()]=nil; R.AIOrderState[fighter:getSignature()]=nil
        R.UserOrders[capital:getSignature()]={kind='hold'} -- isolate automatic acquisition to the fighter
        fighter.Position=target.Position+ba.createVector(0,0,-500)
        fighter:clearOrders(); fighter.Target=nil; fighter:giveOrder(ORDER_STAY_STILL,nil,nil,.99)
        R:UpdatePassageInterception()
        log('AUTO targetAssigned='..tostring(fighter.Target==target)..' targetValid='..tostring(fighter.Target and fighter.Target:isValid())
            ..' userOrder='..tostring(R.UserOrders[fighter:getSignature()])..' range='..tostring(R:GetShipWeaponRange(fighter))
            ..' distance='..tostring(fighter.Position:getDistance(target.Position)))
        check(fighter.Target==target and R.UserOrders[fighter:getSignature()]==nil,
            'Allow Withdrawal=false acquired an in-range Passage target without an explicit attack order')
        automaticStart=target.HitpointsLeft+target.Shields.CombinedLeft
        phase=2; started=now
    elseif phase==2 and now-started>=10 then
        check(target.HitpointsLeft+target.Shields.CombinedLeft<automaticStart,
            'native fighter did not fire at an automatically acquired Passage target')
        R.AllowWithdrawal.BLUE=nil
        R.UserOrders[capital:getSignature()]=nil
        R.UserOrders[fighter:getSignature()]={kind='attack',targetSignature=target:getSignature()}
        fighter:clearOrders(); check(fighter:giveOrder(ORDER_ATTACK,target,nil,.99)==true,'explicit interception order accepted')
        R:UpdatePassageInterception()
        check(fighter.Target==target,'explicit player interception remains assigned under Allow Withdrawal')
        initialHealth=target.HitpointsLeft+target.Shields.CombinedLeft
        phase=3; started=now
    elseif phase==3 and now-started>=20 then
        check(target.HitpointsLeft+target.Shields.CombinedLeft<initialHealth,'explicit fighter interception damages passage target')
        initialHealth=target.HitpointsLeft+target.Shields.CombinedLeft
        R.UserOrders[fighter:getSignature()]=nil
        fighter:clearOrders(); fighter.Target=nil; fighter:giveOrder(ORDER_PLAY_DEAD,nil,nil,.99)
        for i=1,#capital do local turret=capital[i]; if turret:isTurret() then turret.Target=target end end
        phase=4; started=now
    elseif phase==4 and now-started>=20 then
        log('CAPITAL hits='..capitalHits..' hull='..capital.HitpointsLeft..' targetHealth='..(target.HitpointsLeft+target.Shields.CombinedLeft)..' before='..initialHealth)
        check(capitalHits>0 and target.HitpointsLeft+target.Shields.CombinedLeft<initialHealth,'explicit capital turret interception damages passage target')
        escapee=spawn('Passage Escape','GTF Ulysses',{-20000,0,0},mn.Teams.friendly)
        escapeRecord=R:RecordShipCreated(escapee)
        check(escapee:warpOut()==true,'upstream warpOut accepted')
        phase=5; started=now
    elseif phase==5 and now-started>=15 then
        check(departed==1 and not escapee:isValid(),'one confirmed departure without death')
        check(R:GetObserver() and R:GetObserver():isValid(),'observer survives departure')
        check(escapeRecord.fate=='ESCAPED','native departure archived an actual escape')
        local home=R:GetCarrier().Position
        survivor=spawn('Extraction Pilot','GTF Ulysses',{home.x,home.y+3000,home.z},mn.Teams.friendly)
        survivorRecord=R:RecordShipCreated(survivor)
        check(R:StartPilotMode(survivor),'native possession entered')
        R:OnKeyPressed('Pause','Pause'); check(R.Paused and R.TimeScale==0,'native pilot pause stops engine clock')
        R:OnKeyPressed('Alt-3','3'); check(not R.Paused and R.TimeScale==4,'pilot speed hotkey resumes clock at chosen speed')
        R:OnKeyReleased('Alt-3','3')
        R:OnKeyPressed('Pause','Pause'); R:OnKeyReleased('Pause','Pause')
        R:OnKeyPressed('Esc','Esc')
        check(not R.Paused and R.PossessedSignature==nil and R.TimeScale>0,'Escape exits paused pilot and restores command simulation')
        R:OnKeyReleased('Esc','Esc')
        R:OnKeyPressed('Space','Space'); check(R.Paused,'RTS Space pauses'); R:OnKeyReleased('Space','Space')
        R:OnKeyPressed('Space','Space'); check(not R.Paused,'RTS Space resumes'); R:OnKeyReleased('Space','Space')
        R:EliminateFaction('BLUE'); R:EvaluateFactionVictory()
        check(R.PostBattleActive and not R.AftermathActive and not R.StrategicResult,'personal defeat keeps global contest unresolved')
        check(R:ResumePostBattle() and not R.AftermathActive,'resuming personal defeat retains normal phase')
        unresolvedIncome=R.AIStates.RED.cp
        production(R,now+10)
        check(R.AIStates.RED.cp>unresolvedIncome or R.AIStates.RED.queue~=nil,'healthy enemy economy/production continues after player defeat')
        check(R:BeginShipWithdrawal(survivor),'irreversible extraction committed')
        check(not R:IsMovableFriendly(survivor),'withdrawal rejects fresh attack/move orders')
        local home=R:GetScenarioBasePosition('BLUE')
        local station=R:GetFactionCommandShip('BLUE')
        station.HitpointsLeft=0 -- prove routing around the dead base's retained collision volume
        local length=math.sqrt(home.x*home.x+home.z*home.z)
        local dx,dz=length>1 and home.x/length or 1,length>1 and home.z/length or 0
        local shipRadius=tb.ShipClasses['GTF Ulysses'].Model.Radius
        local area=R.ExtractionAreas.BLUE
        routeProbe=spawn('Extraction Route Probe','GTF Ulysses',{
            home.x-dx*(area.homeRadius+shipRadius*1.05+5000),home.y,
            home.z-dz*(area.homeRadius+shipRadius*1.05+5000)},mn.Teams.friendly)
        check(R:BeginShipWithdrawal(routeProbe),'front-side route probe committed to extraction')
        local destination=R.Withdrawals[routeProbe:getSignature()].destination
        local first=R:ConfigureMoveWaypoints(routeProbe,destination)
        local entry=R.MoveWaypoints[routeProbe:getSignature()]
        check(first and entry and entry.route,'front-side route avoids the destroyed home station')
        local clearance=area.homeRadius+R:GetShipFormationRadius(routeProbe)*1.05+300
        local function segmentDistance(a,b,center)
            local x,y,z=b.x-a.x,b.y-a.y,b.z-a.z
            local length=x*x+y*y+z*z
            local ox,oy,oz=center.x-a.x,center.y-a.y,center.z-a.z
            local t=math.max(0,math.min(1,(ox*x+oy*y+oz*z)/math.max(1,length)))
            return (a+ba.createVector(x*t,y*t,z*t)):getDistance(center)
        end
        local previous=routeProbe.Position
        for _,waypoint in ipairs(entry.route) do
            check(segmentDistance(previous,waypoint.Position,area.home)>=clearance-.5,
                'native withdrawal waypoint clears home radius plus ship radius')
            previous=waypoint.Position
        end
        check(routeProbe:giveOrder(ORDER_WAYPOINTS_ONCE,first,nil,.99)==true,
            'FSO accepts the front-side withdrawal waypoint route')
        phase=6; started=now; R:SetTimeScale(8)
    elseif phase==6 then
        if survivorRecord.fate=='ESCAPED' and not survivor:isValid() then
            check(not survivor:isValid() and survivorRecord.fate=='ESCAPED','physical route reached corridor and confirmed departure')
            check(R:GetObserver():isValid(),'observer survives owned extraction')
            R:EliminateFaction('GOLD'); R:EvaluateFactionVictory()
            check(R.StrategicResult and R.StrategicResult.victor=='RED' and R.AftermathActive,'one remaining station resolves immutable strategic winner')
            local result=R.StrategicResult; R:ResumePostBattle(); R:EliminateFaction('RED'); R:EvaluateFactionVictory()
            check(R.StrategicResult==result and R.BattleVictor=='RED','later winner station loss cannot rewrite strategic history')
            log('COMPLETE native passage, pilot pause, phase separation and physical extraction'); quit()
        elseif now-started>260 then
            local w=R.Withdrawals[survivor:getSignature()]
            log('ROUTE phase='..tostring(w and w.phase)..' distance='..tostring(w and survivor.Position:getDistance(w.destination)))
            check(false,'physical extraction did not finish before diagnostic deadline')
        end
    end
end
R.OnFrame=function(self)
    if finished then return end
    local ok,err=pcall(function() original(self); run() end)
    if not ok then log('FAIL '..tostring(err)); quit() end
end
