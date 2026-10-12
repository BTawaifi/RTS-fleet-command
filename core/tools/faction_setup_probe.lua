-- Native upstream check for selectable race rosters, mirror IFFs and N-gon starts.
local R=require 'fs2rts'
local out=cf.openFile('faction-setup-probe.log','w','data')
assert(out and out:isValid())
local function log(text) out:write(text..'\n'); out:flush() end
local function check(ok,text) assert(ok,text); log('PASS '..text) end
local FLIGHT_GATE_SECONDS=12
local function addFlightSimulationTime(total,frameDt) return total+frameDt end
-- Mission time is test-only input: a stall may advance it without a matching physics step.
local function flightGateReady(physicsElapsed,_missionElapsed) return physicsElapsed>=FLIGHT_GATE_SECONDS end
local syntheticPhysicsElapsed=addFlightSimulationTime(0,.25)
check(not flightGateReady(syntheticPhysicsElapsed,57),'57s mission-clock jump with only 0.25s physics leaves flight gate closed')
for _=2,48 do syntheticPhysicsElapsed=addFlightSimulationTime(syntheticPhysicsElapsed,.25) end
check(flightGateReady(syntheticPhysicsElapsed,57),'48 accumulated 0.25s physics updates satisfy the 12s flight gate')
local finished=false; local simulatedAt=nil; local flightChecks=nil; local flightStarted=nil; local flightBaselineAt=nil; local flightFrames=0; local flightSimulationElapsed=0
local original=R.OnFrame
local updateStations=R.UpdateStations
R.Config.Cinematic.Enabled=false
if not (R.ReviewFactionSimSeconds and R.ReviewFactionSimSeconds>0) then
    for _,name in ipairs({'UpdateAIProduction','UpdateEnemyWaves','UpdateStations','UpdateAIStrategicObjectives','UpdateDefaultPolicy'}) do
        R[name]=function() end
    end
end
local function quit()
    finished=true; R:SetTimeScale(1)
    ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
end
local function probeEnvironmentAssets()
    local tracks=R.Config.Music.Tracks
    check(#tracks==21,'environment exposes the 21 selectable retail combat cues')
    for _,index in ipairs({1,#tracks}) do
        local track=tracks[index]
        check(cf.fileExists(track.file,'',true),'VFS has music cue '..track.file)
        if track.mediavps then
            log('VFS_MEDIAVPS music='..track.mediavps..' available='
                ..tostring(cf.fileExists(track.mediavps,'',true)))
        end
    end

    if R.ReviewProbeAudioEnabled then
        local voice=ad.openAudioStream(tracks[1].file,AUDIOSTREAM_VOICE)
        check(voice and voice:isValid() and voice:play(1,true),'native independent voice stream starts')
        check(voice:isPlaying(),'native independent voice stream is playing')
        check(R:SetEnvironmentMusic(1,true),'native selected music opens its owned stream')
        check(R:SetEnvironmentMusicMuted(true),'native selected music can be muted')
        check(voice:isPlaying(),'muting RTS music leaves unrelated voice playing')
        check(R:SetEnvironmentMusicMuted(false),'native selected music can be unmuted')
        check(voice:isPlaying(),'unmuting RTS music leaves unrelated voice playing')
        R:StopEnvironment()
        check(voice:isPlaying(),'RTS scene cleanup leaves unrelated voice playing')
        check(voice:close(false),'native voice control stream closes')
    end

    local backdrops=R.Config.Environment.NebulaBackdrops
    check(#backdrops==36,'environment exposes all 36 stock nebula backdrops')
    local baseline=#mn.BackgroundBitmaps
    local allocatedCount
    for index,name in ipairs(backdrops) do
        local texture=name..'.pcx'
        check(cf.fileExists(texture,'',true),'VFS has nebula art '..texture)
        local element=mn.addBackgroundBitmapNew(name,ba.createOrientation(),1,1,1,1)
        check(element and element:isValid(),'native background API accepts '..name)
        check(#mn.BackgroundBitmaps<=baseline+1,'temporary background layers do not accumulate '..name)
        check(mn.removeBackgroundElement(element),'native background API removes '..name)
        allocatedCount=allocatedCount or #mn.BackgroundBitmaps
        check(#mn.BackgroundBitmaps==allocatedCount,
            'removed background slot is reused on the next selection '..name)
        if index==1 or index==#backdrops then log('NATIVE_BACKDROP_EDGE '..name) end
    end
    check(#mn.BackgroundBitmaps<=baseline+1,'all 36 temporary backdrops use at most one extra slot')
end
local function flightVector(value)
    return string.format('%.1f,%.1f,%.1f',value.x,value.y,value.z)
end
local function logFlightState(entry,phase)
    local ship=entry.ship; local class=ship.Class; local physics=ship.Physics
    local order=ship.Orders[1]; local orderCount=#ship.Orders
    local orderKind=order and order:isValid() and order:getType()==ORDER_WAYPOINTS_ONCE and 'WAYPOINTS_ONCE'
        or order and order:isValid() and 'OTHER' or 'NONE'
    local orientation=ship.Orientation
    local now=mn.getMissionTime()
    log(string.format('FLIGHT_STATE phase=%s mission=%.3f missionElapsed=%.3f physicsElapsed=%.3f frameDt=%.3f frames=%d scale=%s ship=%s class=%s model=%s type=%s classVmax=%s physicsVmax=%s velocity=%s desired=%s position=%s spawn=%s baseline=%s baselineForward=%s forward=%s up=%s right=%s classRole=%s runtimeFlags={no-dynamic:%s} orders=%d order=%s priority=%s shot=%s',
        phase,now,flightBaselineAt and now-flightBaselineAt or 0,flightSimulationElapsed,ba.getMissionFrametime(),flightFrames,tostring(R.TimeScale),ship.Name,class.Name,class.Model.Filename,
        class.TypeString,flightVector(class.VelocityMax),flightVector(physics.VelocityMax),flightVector(physics.Velocity),
        flightVector(physics.VelocityDesired),flightVector(ship.Position),flightVector(entry.spawnPosition),
        entry.position and flightVector(entry.position) or 'pending',
        entry.baselineForward and flightVector(entry.baselineForward) or 'pending',flightVector(orientation:getFvec()),
        flightVector(orientation:getUvec()),flightVector(orientation:getRvec()),R:GetShipRole(ship),
        tostring(ship:getFlag('no-dynamic')),orderCount,orderKind,tostring(order and order.Priority),tostring(entry.shot)))
end
local function startFlightChecks(self,stations,classes)
    flightChecks={}; flightStarted=mn.getMissionTime(); flightBaselineAt=nil; flightFrames=0; flightSimulationElapsed=0
    self:InvalidateShipList()
    log(string.format('NATIVE_FLIGHT_FIXTURE factions=%d shipsBefore=%d missionLaunch=%.3f classes=%s gatePhysicsSeconds=12',
        #stations,#self:GetShipList(),flightStarted,table.concat(classes,',')))
    for index,name in ipairs(classes) do
        local class=tb.ShipClasses[name]
        check(class.PowerOutput>0 and class.RotationTime.x>0 and class.RotationTime.y>0 and class.RotationTime.z>0,
            'native FS1 class has nonzero reactor and turn rates '..name)
        local position=ba.createVector((index-3)*1800,6000,0)
        local ship=mn.createShip('FS1 flight '..index,class,ba.createOrientation(),position,stations[1].Team,true)
        check(ship and ship:isValid() and ship.WeaponEnergyMax>0 and ship.WeaponEnergyLeft>0,'native FS1 hull has usable gun energy '..name)
        self:InvalidateShipList(); self:SetUserOrder(ship,{kind='move',destination=position+ba.createVector(2200,0,1600)})
        check(self:MoveShipTo(ship,position+ba.createVector(2200,0,1600),.99),'native FS1 waypoint accepted '..name)
        local entry={ship=ship,spawnPosition=ba.createVector(position.x,position.y,position.z),nextSampleTime=3}
        flightChecks[#flightChecks+1]=entry
        logFlightState(entry,'spawn')
    end
    self:InvalidateShipList()
    log(string.format('NATIVE_FLIGHT_FIXTURE shipsAfter=%d timescale=4',#self:GetShipList()))
    self:SetTimeScale(4)
end
engine.addHook('On Frame',function() if finished then ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME']) end end)
local choices={}
for _,choice in ipairs(R.Config.FactionChoices) do if choice~='RANDOM' then choices[#choices+1]=choice end end
local function run(self)
    if finished then return end
    local simSeconds=self.ReviewFactionSimSeconds or 0
    if flightChecks then
        -- Use the capped physics dt, not mission-clock time, which includes compressed time spent in stalled frames.
        local baselineReady=flightBaselineAt~=nil
        flightFrames=flightFrames+1
        for _,entry in ipairs(flightChecks) do
            local ship=entry.ship
            assert(ship:isValid(),'FS1 flight hull lost '..ship.Class.Name)
            if not entry.shot then
                ship.PrimaryTriggerDown=true
                entry.shot=ship:firePrimary()>0
                ship.PrimaryTriggerDown=false
            end
            if not entry.position then
                local position=ship.Position; local forward=ship.Orientation:getFvec()
                entry.position=ba.createVector(position.x,position.y,position.z)
                entry.baselineForward=ba.createVector(forward.x,forward.y,forward.z)
                flightBaselineAt=flightBaselineAt or mn.getMissionTime()
                logFlightState(entry,'baseline')
            end
        end
        if baselineReady then flightSimulationElapsed=addFlightSimulationTime(flightSimulationElapsed,ba.getMissionFrametime()) end
        for _,entry in ipairs(flightChecks) do
            if flightSimulationElapsed>=entry.nextSampleTime then
                logFlightState(entry,'sample')
                entry.nextSampleTime=entry.nextSampleTime+3
            end
        end
        local missionElapsed=flightBaselineAt and mn.getMissionTime()-flightBaselineAt or 0
        if not flightGateReady(flightSimulationElapsed,missionElapsed) then return end
        for _,entry in ipairs(flightChecks) do
            local ship=entry.ship
            logFlightState(entry,'final')
            check(ship.Position:getDistance(entry.position)>100,'native FS1 hull moves '..ship.Class.Name)
            local forward=ship.Orientation:getFvec()
            check(math.abs(forward.x)>.05,'native FS1 hull turns toward its waypoint '..ship.Class.Name)
            check(entry.shot,'native FS1 hull fires a real primary bank '..ship.Class.Name)
        end
        log(self.ReviewFlightOnly and 'COMPLETE isolated native FS1 movement/rotation/firing control'
            or 'COMPLETE faction setup plus all five native FS1 movement/rotation/firing controls')
        quit(); return
    end
    if simulatedAt then
        if self.BattleVictor~=nil or mn.getMissionTime()-simulatedAt>=simSeconds then
            local rows={}
            for _,kind in ipairs(self:GetFactionKeys()) do
                local station=self:GetFactionCommandShip(kind); local ships=0
                for _,ship in ipairs(self:GetShipList()) do
                    if ship:isValid() and not ship:isDying() and ship.Name~=self.Config.ObserverShip
                        and self:GetFactionKey(ship)==kind and not self:IsCommandStation(ship) then ships=ships+1 end
                end
                rows[#rows+1]=string.format('%s:station=%.0f,ships=%d',kind,station and station:isValid() and station.HitpointsLeft or 0,ships)
            end
            log('NATIVE_MATCH_RESULT simulated='..string.format('%.1f',mn.getMissionTime()-simulatedAt)
                ..' victor='..tostring(self.BattleVictor)..' '..table.concat(rows,' '))
            log('COMPLETE native faction match')
            quit()
        end
        return
    end
    if not self.SetupActive then return end
    self.SetupFactionCountChoice=self.ReviewFactionCount or 6
    assert(self.SetupFactionCountChoice>=2 and self.SetupFactionCountChoice<=#self.Config.FactionOrder,
        'requested faction count is outside the declared upstream IFF capacity')
    self:UpdateFactionCount()
    for _,kind in ipairs(self:GetFactionKeys()) do
        local def=self:GetFactionDefinition(kind); local team=def and mn.Teams[def.team]
        local okName,name=pcall(function() return team.Name end)
        local okValid,valid=pcall(function() return team:isValid() end)
        log('TEAM_LOOKUP key='..kind..' name='..tostring(okName and name)..' valid='..tostring(okValid and valid)..' teams='..tostring(#mn.Teams))
        check(team and team:isValid(),'upstream table exposes IFF '..tostring(def and def.team))
    end
    for i,kind in ipairs(self:GetFactionKeys()) do
        self:SetFactionChoice(kind,i==self.ReviewFactionCount and i>#choices and 'RANDOM' or choices[(i-1)%#choices+1])
    end
    self.SetupBaseLayoutIndex=self.ReviewFactionLayoutIndex or self.Config.Setup.DefaultBaseLayout or 1
    self.SetupAutoMode=simSeconds>0; self.SetupSentries=false; self.SetupAsteroids=false
    self:StartScenario()
    check(not self.SetupActive,'scenario accepted the selected faction count: '..tostring(self.StatusMessage))
    local keys=self:GetFactionKeys(); check(#keys==self.ReviewFactionCount or #keys==6,'all requested factions became active')
    check(self.GameStatus=='ACTIVE' and self.BattleVictor==nil,'elimination state remains active with multiple stations')
    local d=self:GetBaseDistanceProfile().distance
    local seenColors={}
    local stations={}
    for i,kind in ipairs(keys) do
        local def=self:GetFactionDefinition(kind); local station=self:GetFactionCommandShip(kind)
        check(self:GetFactionSpecies(kind)~='RANDOM' and self.Config.Species[self:GetFactionSpecies(kind)]~=nil,
            'random species resolves once before station creation for '..kind)
        check(station and station:isValid(),'station spawned for '..kind)
        check(string.lower(station.Team.Name)==string.lower(def.team),'station uses its dedicated IFF team for '..kind)
        check(station.TeamColor and station.TeamColor:isValid(),'station uses its distinct ship-render color for '..kind)
        check(station.Class.Name==self.Config.Species[self:GetFactionSpecies(kind)].stationClass,
            'station hull matches '..self:GetFactionSpecies(kind)..' roster for '..kind)
        check(station.TeamColor==tb.TeamColors[self:GetFactionTeamColorName(kind)],'station paint uses its selected color for '..kind)
        local facing=self:GetFactionBattleFacingPoint(kind)-station.Position
        local length=facing:getDistance(ba.createVector(0,0,0)); local forward=station.Orientation:getFvec()
        check(length>0 and (forward.x*facing.x+forward.y*facing.y+forward.z*facing.z)/length>.999,
            'native station faces its battle approach for '..kind)
        local r,g,b=self:GetFactionColor(kind); local color=table.concat({r,g,b},'/')
        check(not seenColors[color],'team color is unique for '..kind); seenColors[color]=true
        stations[i]=station
    end
    local closest=math.huge
    for i=1,#stations do
        local nextIndex=i%#stations+1
        if self:GetBaseLayoutProfile().id=='CIRCLE' then
            check(math.abs(stations[i].Position:getDistance(stations[nextIndex].Position)-d)<1,
                'adjacent station spacing matches the selected distance')
        end
        for j=i+1,#stations do closest=math.min(closest,stations[i].Position:getDistance(stations[j].Position)) end
        check(stations[i].Position:getDistance(ba.createVector(0,0,0))+10000<=self.ScenarioMapHalfExtent+1,
            'native station plus clearance fits layout bounds')
        check(self:AreEnemies(stations[i],stations[nextIndex]),'active faction IFFs are hostile')
    end
    check(math.abs(closest-d)<1,'minimum native station separation matches selected distance: '..self:GetBaseLayoutProfile().name)
    if self.ReviewFlightOnly then
        startFlightChecks(self,stations,{'GTF Apollo'})
        return
    end
    check(self:GetFactionSpecies('BLUE')==self:GetFactionSpecies('RED') and self:AreEnemies(stations[1],stations[2]),
        'same-species mirror factions remain distinct enemies')
    check(self:GetTacticalMapHalfExtent()>stations[1].Position:getDistance(ba.createVector(0,0,0)),
        'tactical map bounds enclose the configured starting ring')
    if simSeconds==0 then
        probeEnvironmentAssets()
        local oldBlue,oldRed=self:GetFactionColorIndex('BLUE'),self:GetFactionColorIndex('RED')
        check(self:SetFactionColor('BLUE',oldRed),'native color change accepted')
        check(self:GetFactionColorIndex('RED')==oldBlue,'occupied colors swap without duplicates')
        check(stations[1].TeamColor==tb.TeamColors[self:GetFactionTeamColorName('BLUE')],'native paint refresh after a color swap')
        self.EnemySerial=128
        local long=self:SpawnFactionUnit('GTF Ulysses',stations[1],stations[1].Team,'RTS TEAM 04 Production',2,13,129,1,1)
        check(long and long:isValid() and #long.Name<=31,'exact reported name overflow survives native creation')
        local profiles={}
        for index,kind in ipairs(keys) do
            local profile=self:GetFactionProfile(kind); local choice=self:GetFactionChoice(kind)
            local texture=self:LoadBriefingIcon(profile.insignia)
            check(texture and texture:isValid(),'native insignia loads for '..choice)
            check(self:DrawFactionInsignia(kind,20,20,52,52),'native insignia sizing and draw APIs for '..choice)
            local roster=self:GetAIRoster(kind); check(#roster==#profile.classes,'complete curated roster for '..choice)
            local anchor=stations[index]; local created={}
            for slot,entry in ipairs(roster) do
                local estimate=self:GetPurchaseEstimate(entry.class,entry.tier,1)
                local ship=self:SpawnFactionUnit(entry.class,anchor,anchor.Team,'FP'..index,slot,slot,#roster,1,1,nil,nil,created)
                check(ship and ship:isValid(),'native model and creation '..choice..' / '..entry.class)
                ship:clearOrders(); ship:giveOrder(ORDER_PLAY_DEAD,nil,nil,.99); self:SetShipTurretLock(ship,true)
                log(string.format('HULL faction=%s class=%s tier=%d role=%s cp=%d hull=%.0f radius=%.0f',choice,entry.class,entry.tier,entry.role,estimate.cost,ship.HitpointsMax,ship.Radius))
            end
            self.StationState[kind].levels.command=3; self.StationState[kind].nextAIThink=math.huge
            if kind=='BLUE' then self.CommandPoints=1000000 else self.AIStates[kind].cp=1000000 end
            local ability=self:GetFactionAbilityProfile(kind); local before=self:GetFactionCP(kind)
            if ability.kind=='strike' then
                local enemyTeam=stations[index%#keys+1].Team
                local target=mn.createShip('StrikeTest'..index,tb.ShipClasses['GTF Ulysses'],nil,anchor.Position+ba.createVector(0,0,2500),enemyTeam,true)
                check(target and target:isValid(),'strike control target exists')
                self:InvalidateShipList(); target:clearOrders(); target:giveOrder(ORDER_PLAY_DEAD,nil,nil,.99)
                check(self:QueueOrbitalStrike(kind,target.Position),'targeted ability activates '..choice)
                check(self:GetFactionCP(kind)==before-ability.cost,'native strike charges once '..choice)
            else
                check(self:UseFactionAbility(kind),'native command ability activates '..choice)
                check(self:GetFactionCP(kind)==before-ability.cost,'native command ability charges once '..choice)
                check(not self:UseFactionAbility(kind),'cooldown prevents duplicate ability '..choice)
                if ability.kind=='surge' then
                    local boosted=0
                    for _,ship in ipairs(created) do
                        local surge=self.SurgedShips[ship:getSignature()]
                        if surge then
                            check(ability.roles[self:GetShipRole(ship)],'surge affects an admitted role '..choice)
                            check(math.abs(ship.Physics.VelocityMax.z-surge.velocity.z*ability.speedMultiplier)<.01,'native speed multiplier '..choice)
                            boosted=boosted+1; surge.untilTime=mn.getMissionTime()
                        end
                    end
                    check(boosted>0,'surge changes real ships '..choice)
                    updateStations(self,mn.getMissionTime())
                    for _,ship in ipairs(created) do check(not self.SurgedShips[ship:getSignature()],'native surge expiry '..choice) end
                else
                    local estimate=self:GetPurchaseEstimate(ability.class,ability.tier,ability.count)
                    check(ability.cost>=estimate.cost,'reinforcement does not undercut production '..choice)
                end
            end
            profiles[choice]=true
        end
        if #keys>=#choices then for _,choice in ipairs(choices) do check(profiles[choice],'native faction coverage '..choice) end end
        if #keys>=3 then
            local kind=keys[3]; local state=self:GetStationState(kind)
            self:SetFactionChoice(kind,'PVN')
            state.levels={armor=3,defenses=3,logistics=3,command=3}
            state.abilityReadyAt=0; state.nextAIThink=0; state.capitalGateSince=nil
            local production=self.AIStates[kind]
            production.cp=10000; production.queue=nil
            production.savingRole='capital:4'; production.productionReserve=20000
            local now=mn.getMissionTime(); local before=self:GetFactionCP(kind)
            local options=self.GetSentryOptions
            self.GetSentryOptions=function() return {} end
            local limit=self.Config.Station.AI.CapitalAwareInvestmentMaxSeconds
            self.Config.Station.AI.CapitalAwareInvestmentMaxSeconds=90
            self:UpdateStationAI(kind,state,stations[3],now)
            check(state.capitalGateSince==now,'native fleet savings gate is active')
            check(self:GetFactionCP(kind)==before and state.abilityReadyAt==0,'native AI ability preserves fleet savings')
            state.nextAIThink=0
            self:UpdateStationAI(kind,state,stations[3],now+90)
            check(self:GetFactionCP(kind)==before-self:GetFactionAbilityProfile(kind).cost and state.abilityReadyAt>now,
                'native AI ability resumes when bounded savings gate expires')
            self.GetSentryOptions=options
            self.Config.Station.AI.CapitalAwareInvestmentMaxSeconds=limit
        end
        local tier=self.GetCurrentEscalationTier
        local targets=self.Config.AI.CompositionTargets[5]
        local demand=self.AIProductionNeeds
        local random=math.random
        self.GetCurrentEscalationTier=function() return 5 end
        self.Config.AI.CompositionTargets[5]={fighter=0,bomber=0,escort=0,capital=1}
        self.AIProductionNeeds={}; math.random=function() return .999999 end
        local choice=self:ChooseAIBuild('BLUE',{cp=1000000,savingRole='capital:5',savingSince=mn.getMissionTime()},mn.getMissionTime())
        check(choice and choice.entry.class=='GTD Orion','native classic savings commit the desired hull without a current-tier option')
        self.GetCurrentEscalationTier=tier; self.Config.AI.CompositionTargets[5]=targets
        self.AIProductionNeeds=demand; math.random=random
    end
    if simSeconds>0 then
        self:SetTimeScale(16)
        simulatedAt=mn.getMissionTime()
        log('NATIVE_MATCH_START factions='..#keys..' timescale=16')
    else
        startFlightChecks(self,stations,{'GTF Apollo','GTF Valkyrie','GTB Athena','PVF Anubis','SB Shaitan'})
    end
end
R.OnFrame=function(self)
    if finished then return end
    local ok,err=pcall(function()
        if self.ReviewFlightOnly then
            -- StartScenario still finishes the real roster setup; skip only its redundant one-model-per-frame prewarm.
            local process=self.ProcessRosterModelWarmup
            self.ProcessRosterModelWarmup=function() end
            local warmOk,warmErr=pcall(original,self)
            self.ProcessRosterModelWarmup=process
            assert(warmOk,warmErr)
        else
            original(self)
        end
        run(self)
    end)
    if not ok then log('FAIL '..tostring(err)); quit() end
end
