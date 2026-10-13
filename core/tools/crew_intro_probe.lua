-- Upstream-only intro lifetime and citation attribution controls.
local R=require 'fs2rts'
local out=cf.openFile('crew-intro-probe.log','w','data')
assert(out and out:isValid())
local function log(s) out:write(s..'\n'); out:flush() end
local function check(value,label) assert(value,label); log('PASS '..label) end
local stage,elapsed,shots=0,0,{}
local cast,baseHull,actor,enemy,record,beneficiary,beneficiaryRecord,serviceAt
local shotsFired=0
local introCleanupAt
local priorityCapital,smallCrew,otherSmallCrew,priorityAt,priorityIdentity
local restartStarts=0
local gameplayStart=R.OnGameplayStart
R.OnGameplayStart=function(self)
    restartStarts=restartStarts+1
    return gameplayStart(self)
end
local frame=R.OnFrame
local updateService=R.UpdateFleetServices
R.Config.Cinematic.Enabled=true
for _,name in ipairs({'UpdateAIProduction','UpdateEnemyWaves','UpdateAIStrategicObjectives','UpdateDefaultPolicy','UpdateStations','EvaluateFactionVictory','UpdateDefeatedFleetExtraction'}) do R[name]=function() end end
engine.addHook('On Weapon Created',function()
    if R.CinematicActive and hv.Weapon and hv.Weapon:isValid() then shotsFired=shotsFired+1 end
end)
local function spawn(name,class,point,team)
    local ship=mn.createShip(name,tb.ShipClasses[class],nil,point,team,true)
    check(ship and ship:isValid(),'spawn '..name)
    R:InvalidateShipList(); R:RecordShipCreated(ship,true); ship:setFlag(true,'no-shields')
    ship:clearOrders(); return ship
end
local function run()
    local now=mn.getMissionTime()
    if stage==0 then
        if not R.CinematicActive then return end
        cast=R.IntroShips; check(cast and #cast==6,'intro contains two mobile forces')
        baseHull={}
        for _,kind in ipairs({'BLUE','RED'}) do
            local station=R:GetFactionCommandShip(kind)
            baseHull[kind]=station and station:isValid() and station.HitpointsLeft or false
        end
        stage=1
    elseif stage==1 then
        if R.CinematicActive then
            local index=R.CinematicShotIndex
            if index and not shots[index] then
                shots[index]=true; log('SHOT '..index..' '..tostring(R.CinematicCaption)..' camera='..tostring(R.Camera.Position))
            end
            return
        end
        if not introCleanupAt then introCleanupAt=now; return end
        if now-introCleanupAt<.1 then return end
        for _,ship in ipairs(cast) do check(not ship:isValid(),'intro hull removed') end
        check(shotsFired>0,'intro depicts native weapons fire')
        for _,kind in ipairs({'BLUE','RED'}) do
            local station=R:GetFactionCommandShip(kind)
            local hull=station and station:isValid() and station.HitpointsLeft or false
            check(hull==baseHull[kind],'intro preserves '..kind..' station presence and hull')
        end
        check(next(R.UnitHistory)==nil,'intro does not commission real fleet')
        R:StartIntroCinematic(); check(#R.IntroShips==6,'intro can restart')
        R:EndIntroCinematic(true); check(not R.CinematicActive and R.IntroShips==nil,'skip removes restarted scene')
        R:OpenExitMenu()
        check(R:HandleExitMenuAction('restart'),'setup RTS menu requests native level restart')
        stage=90
    elseif stage==90 then
        if restartStarts<2 or not R.CinematicActive then return end
        if not introCleanupAt or now<introCleanupAt then introCleanupAt=now end
        if now-introCleanupAt<3 then return end
        check(R.IntroShips and #R.IntroShips==6,'level restart creates a fresh intro cast')
        for _,ship in ipairs(R.IntroShips) do check(ship:isValid(),'restarted intro hull remains valid') end
        R:EndIntroCinematic(true)
        check(R.SetupActive and not R.CinematicActive,'restarted intro skips into setup')
        stage=2
    elseif stage==2 then
        if not R.RosterModelWarmup or not R.RosterModelWarmup.done then return end
        R.SetupFactionCountChoice=2; R.SetupAutoMode=false; R.SetupSentries=false; R:StartScenario()
        check(not R.SetupActive,'intro transitions through setup to command')
        for _,ship in ipairs(R:GetShipList()) do R:SetShipTurretLock(ship,true); ship:setFlag(true,'primaries-locked','secondaries-locked') end
        local station=R:GetCarrier()
        actor=spawn('Citation Crew','GTF Hercules',station.Position+ba.createVector(0,0,-6500),mn.Teams.friendly)
        enemy=spawn('Citation Attacker','GTF Ulysses',actor.Position+ba.createVector(0,0,-450),mn.Teams.hostile)
        actor.HitpointsMax=1000; actor.HitpointsLeft=1000
        actor:setFlag(true,'primaries-locked','secondaries-locked')
        actor:giveOrder(ORDER_STAY_STILL,nil,nil,.99)
        enemy.Target=actor; enemy:giveOrder(ORDER_ATTACK,actor,nil,.99)
        record=R:GetUnitHistory(actor)
        R.UpdateFleetServices=function() end
        elapsed=now; R:SetTimeScale(4); stage=3
    elseif stage==3 then
        assert(actor:isValid() and not actor:isDying(),'injured citation subject died before recovery')
        if actor.HitpointsLeft/actor.HitpointsMax>R.Config.Station.FleetService.ReturnHull then
            assert(now-elapsed<180,'hostile projectile injury not observed'); return
        end
        enemy:setFlag(true,'primaries-locked','secondaries-locked'); enemy:clearOrders(); enemy:giveOrder(ORDER_STAY_STILL,nil,nil,.99)
        check((record.hostileProjectileHull or 0)>=1-R.Config.Station.FleetService.ReturnHull,'upstream pre/post hook measures hostile hull removal')
        check(R:BeginFleetService(actor,'PROBE_RECOVERY',now,false),'admitted real paid recovery')
        R.FleetServices[actor:getSignature()].threatSignature=enemy:getSignature()
        enemy.Position=ba.createVector(60000,45000,60000)
        serviceAt=now; stage=4
    elseif stage==4 then
        local service=R.FleetServices[actor:getSignature()]
        if service then
            updateService(R,now)
            assert(now-serviceAt<360,'paid service did not physically finish'); return
        end
        check(record.recoveryRejoinPending and not record.citations,'paid service alone does not award combat rejoin')
        enemy:kill(actor)
        stage=5
    elseif stage==5 then
        if not (record.citations or {}).RECOVERY_REJOIN then return end
        check(true,'native hostile kill confirms recovery and useful rejoin')
        beneficiary=spawn('Covered Crew','GTB Medusa',actor.Position+ba.createVector(1000,0,0),mn.Teams.friendly)
        beneficiaryRecord=R:GetUnitHistory(beneficiary)
        R:SetFactionEliminated('BLUE',true)
        check(R:BeginShipWithdrawal(beneficiary),'cover beneficiary commits withdrawal')
        local threat=spawn('Cover Threat','SF Mara',beneficiary.Position+ba.createVector(0,0,-500),mn.Teams.hostile)
        threat.Target=beneficiary; threat:kill(actor)
        stage=6
    elseif stage==6 then
        if not next(beneficiaryRecord.coverContributors or {}) then return end
        check(not record.citations.WITHDRAWAL_COVER,'cover waits for escape')
        actor:kill()
        local withdrawal=R.Withdrawals[beneficiary:getSignature()]
        beneficiary.Position=withdrawal.destination
        stage=7
    elseif stage==7 then
        R:UpdateFleetLife(now)
        if beneficiaryRecord.fate~='ESCAPED' then return end
        check(record.citations.WITHDRAWAL_COVER and record.fate=='LOST','native escape retains lost covering contributor')
        R:SetFactionEliminated('BLUE',false); R.Config.Station.FleetService.Slots=2
        local home=R:GetCarrier().Position
        priorityCapital=spawn('Crew Priority Capital','GTD Hecate',home+ba.createVector(0,0,-6000),mn.Teams.friendly)
        smallCrew=spawn('Small Crew One','GTF Hercules',home+ba.createVector(1000,0,-6000),mn.Teams.friendly)
        otherSmallCrew=spawn('Small Crew Two','GTF Hercules',home+ba.createVector(-1000,0,-6000),mn.Teams.friendly)
        for _,ship in ipairs({smallCrew,otherSmallCrew,priorityCapital}) do
            ship.HitpointsMax=1000; ship.HitpointsLeft=250
            R:SetShipTurretLock(ship,true); ship:setFlag(true,'primaries-locked','secondaries-locked')
            check(R:BeginFleetService(ship,'PROBE_CREW_PRIORITY',now,true),'crew-priority visitor admitted')
            ship.Position=R:GetFleetServicePoint(ship,R:GetCarrier(),nil)
            ship.Physics.Velocity=ba.createVector(0,0,0)
        end
        check(R:GetCrewExposureEstimate(priorityCapital)==4,'native heavy hull uses labeled very-large crew estimate')
        priorityAt=now; stage=8
    elseif stage==8 then
        updateService(R,now)
        if now-priorityAt<3 then return end
        check(priorityCapital.HitpointsLeft>250 and smallCrew.HitpointsLeft==250 and otherSmallCrew.HitpointsLeft==250,
            'same-time priority performs paid work for greater estimated crew exposure')
        priorityCapital.HitpointsLeft=650; priorityAt=now; stage=9
    elseif stage==9 then
        updateService(R,now)
        if now-priorityAt<3 then return end
        check(smallCrew.HitpointsLeft>250 and otherSmallCrew.HitpointsLeft>250 and priorityCapital.HitpointsLeft==650,
            'several critically damaged small crews outrank moderate capital injury')
        R:CancelFleetServiceForShip(priorityCapital)
        priorityCapital.HitpointsLeft=250
        check(R:BeginFleetService(priorityCapital,'PROBE_LATER_ARRIVAL',now,true),'later capital visit admitted')
        priorityCapital.Position=R:GetFleetServicePoint(priorityCapital,R:GetCarrier(),nil)
        priorityCapital.Physics.Velocity=ba.createVector(0,0,0)
        priorityAt=now; stage=10
    elseif stage==10 then
        updateService(R,now)
        if now-priorityAt<3 then return end
        check(priorityCapital.HitpointsLeft==250,'later larger crew does not starve older admissions')
        priorityIdentity=R:GetUnitHistory(priorityCapital).id
        for _,ship in ipairs({smallCrew,otherSmallCrew,priorityCapital}) do R:CancelFleetServiceForShip(ship) end
        priorityCapital.HitpointsLeft=1000
        local threat=spawn('Crew Risk Enemy','SD Ravana',priorityCapital.Position+ba.createVector(0,0,-3000),mn.Teams.hostile)
        R:SetShipTurretLock(threat,true); threat:setFlag(true,'primaries-locked','secondaries-locked')
        threat.Target=priorityCapital
        check(threat:giveOrder(ORDER_ATTACK,priorityCapital,nil,.99)==true,'native hostile focus accepted')
        priorityCapital:clearOrders(); priorityCapital:giveOrder(ORDER_STAY_STILL,nil,nil,.99)
        priorityAt=now; stage=11
    elseif stage==11 then
        updateService(R,now)
        assert(not R.FleetServices[priorityCapital:getSignature()],'healthy large crew hid solely under hostile focus')
        if now-priorityAt<10 then return end
        log('PASS healthy large crew does not hide solely under hostile focus')
        priorityCapital.HitpointsLeft=200
        R:SetUserOrder(priorityCapital,{kind='guard',targetSignature=R:GetCarrier():getSignature()})
        check(priorityCapital:giveOrder(ORDER_GUARD,R:GetCarrier(),nil,.99)==true,'native player guard accepted')
        priorityAt=now; stage=12
    elseif stage==12 then
        updateService(R,now)
        assert(not R.FleetServices[priorityCapital:getSignature()],'critical crew danger overrode explicit player commitment')
        if now-priorityAt<10 then return end
        log('PASS critical crew danger preserves explicit player commitment')
        check(R.UserOrders[priorityCapital:getSignature()].kind=='guard','player commitment remains owned')
        check(R:GetUnitHistory(priorityCapital).id==priorityIdentity,'recovery and risk retain crew identity')
        log('COMPLETE crew intro, upstream citations, recovery priorities and player risk ownership')
        R:SetTimeScale(1); ba.postGameEvent(ba.GameEvents.GS_EVENT_QUIT_GAME); stage=13
    end
end
R.OnFrame=function(self)
    frame(self)
    if stage==13 then ba.postGameEvent(ba.GameEvents.GS_EVENT_QUIT_GAME); return end
    local ok,errorMessage=pcall(run)
    if not ok then log('FAIL '..tostring(errorMessage)); stage=13; self:SetTimeScale(1); ba.postGameEvent(ba.GameEvents.GS_EVENT_QUIT_GAME) end
end
