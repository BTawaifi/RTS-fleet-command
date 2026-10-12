-- Load through review-engine-sct.tbm in an isolated leading probe mod.
-- Uses upstream APIs only. Rendered runs cover HUD and restart; a headless
-- harness must declare RTS.ReviewProbeHeadless=true before loading this module.
local R=require 'fs2rts'
local out=cf.openFile('review-engine-probe.log','w','data')
assert(out and out:isValid())
local finished,stage=false,0
local nativeStarts,reportDraws,setupDraws,exitMenuDraws=0,0,0,0
local fighterDraws,capitalDraws=0,0
local fighter,wingmate,capital,victim,startTime,cpBefore,failedPolicy,attackTarget
local survivorVictim,survivorAttacker,survivorHull
local pursueTarget,pursueOrigin,pursueAt
local commMate,commBlocked,commAllowed,commAt=nil,0,0,0
local exitRequested=false
local countermeasureReal,countermeasureProxy,countermeasureBefore=0,0,0
local countermeasures={}
local nativeComm=R.OnPilotCommOrder
R.OnPilotCommOrder=function(self,recipient,order,target,subsystem,name)
    if stage>=120 and stage<=122 then
        if self:ShouldOverridePilotCommOrder(recipient,order,name) then commBlocked=commBlocked+1
        else commAllowed=commAllowed+1 end
    end
    return nativeComm(self,recipient,order,target,subsystem,name)
end
local function log(message) out:write(message..'\n'); out:flush() end
engine.addHook('On Weapon Created',function()
    local weapon=hv.Weapon
    if weapon and weapon:isValid() and weapon.Class:isCountermeasure() and weapon.Parent:isValid() and fighter then
        countermeasures[#countermeasures+1]=weapon
        if weapon.Parent:getSignature()==fighter:getSignature() then countermeasureReal=countermeasureReal+1
        elseif R:GetObserver() and weapon.Parent:getSignature()==R:GetObserver():getSignature() then countermeasureProxy=countermeasureProxy+1 end
    end
end)
local function check(condition,message) assert(condition,message); log('PASS '..message) end
local function quit()
    finished=true; R:SetTimeScale(1); R:CloseAITrace()
    ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
end
engine.addHook('On Frame',function()
    if finished then ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME']) end
end)
R.Config.Cinematic.Enabled=false
R.Config.AI.ExperimentalDamageTelemetry=false
R.Config.Pilot.NativeWingExtensions=false
local originalFrame=R.OnFrame
local originalStart=R.OnGameplayStart
R.OnGameplayStart=function(self)
    log('GAMEPLAY START enabled='..tostring(self.Enabled))
    nativeStarts=nativeStarts+1
    return originalStart(self)
end
local originalStateEnd=R.OnStateEnd
R.OnStateEnd=function(self,oldState,newState)
    log('STATE END '..tostring(oldState and oldState.Name)..' -> '..tostring(newState and newState.Name))
    return originalStateEnd(self,oldState,newState)
end
local originalHUD=R.DrawHUD
R.DrawHUD=function(self)
    if finished then return end
    local ok,err=pcall(function()
        originalHUD(self)
        if self.Enabled and self.ExitMenuActive then exitMenuDraws=exitMenuDraws+1 end
        if self.Enabled and self.SetupActive then setupDraws=setupDraws+1 end
        if self.Enabled and self.PostBattleActive then reportDraws=reportDraws+1 end
        if self.PossessedSignature then
            local possessed=self:GetPossessedShip()
            if possessed and possessed:isValid() and possessed.Class.Name=='GTD Orion' then capitalDraws=capitalDraws+1
            else fighterDraws=fighterDraws+1 end
        end
    end)
    if not ok then log('FAIL HUD '..tostring(err)); quit() end
end
local applyPolicy=R.ApplyPolicyToShip
local spawnFriendly=R.SpawnFriendly
R.SpawnFriendly=function(self,option,spawned)
    log('SPAWN begin '..option.class)
    local ok,created=spawnFriendly(self,option,spawned)
    log('SPAWN end '..tostring(ok)..' '..tostring(created and #created))
    return ok,created
end
local getSpawnFrame=R.GetSpawnFrame
R.GetSpawnFrame=function(self,...)
    log('PLACEMENT begin')
    local p,o=getSpawnFrame(self,...)
    log('PLACEMENT end'); return p,o
end
R.ApplyPolicyToShip=function(self,ship,force)
    if ship.Class.Name=='GTF Myrmidon' and not failedPolicy then
        log('POLICY injected failure')
        failedPolicy=true; assert(false,'review injected post-create order error')
    end
    return applyPolicy(self,ship,force)
end

local function probe(self)
    if stage==0 and self.SetupActive then
        check(self:ShouldDisableUnfocusedPause() and not self:IsMissionPauseDisabled(),
            'startup suppresses focus pause while preserving deliberate native menus')
        if self.AIFocusOption then check(self.AIFocusOption.Value.Serialized=='false','native startup focus option is disabled') end
        check(self:GetObserver().Name==self.Config.ObserverShip and self.PossessedSignature==nil
            and gr.getCurrentCamera().Name==self.Camera.Name,'mission opens in tactical observer view')
        if not self.ReviewProbeHeadless then
            local sw,sh=gr.getScreenWidth(),gr.getScreenHeight()
            local cx,cy=sw*.8,sh*.5
            local point=gr.getVectorFromCoords(cx,cy,5000,false)
            local sx,sy=point:getScreenCoords()
            check(sx~=false and math.abs(sx-cx)<2 and math.abs(sy-cy)<2,'native projection round trip is the control')
            local gate=self:BuildPickGate(cx,cy,sw,sh,24)
            check(gate and self:PassesScreenGate(gate,point),'pick gate accepts the native off-center projection')
        end
        local cannon=tb.WeaponClasses['Vasudan Flux Cannon']
        log('CANNON range='..tostring(cannon.Range)..' lifetime='..tostring(cannon.LifeMax)..' speed='..tostring(cannon.Speed))
        check(cannon:isValid() and self:GetSentryWeaponRange(self.Config.Station.Sentries.Classes.BLUE[1])>=11000,
            'native cannon reaches the configured 11 km')
        self.SetupAutoMode=false; self.SetupOpponents={RED=true,GOLD=true}
        self:StartScenario(); self.ActiveIncomePerSecond=0
        cpBefore=self.CommandPoints
        self:QueueBuildOption({class='GTF Myrmidon',label='Review',cost=200,time=.1,count=2,tier=1})
        check(#self.BuildQueue==1,'native production queue accepts the request')
        startTime=mn.getMissionTime(); stage=1
        log('START upstream-only lifecycle/control probe')
    elseif stage==1 and #self.BuildQueue==0 then
        local created={}
        self:EachShip(function(ship) if self:IsFriendly(ship) and ship.Class.Name=='GTF Myrmidon' then created[#created+1]=ship end end)
        check(#created==2 and #self.BuildQueue==0,'post-create exception leaves two hulls and retires queue')
        check(self.CommandPoints==cpBefore-200,'post-create exception does not refund live hulls')
        fighter,wingmate=created[1],created[2]
        -- Upstream registers newly created signatures on the next object frame.
        stage=10
    elseif stage==10 then
        if not exitRequested then
            exitRequested=true
            self:DrawTopBar(gr.getScreenWidth())
            local rect=self.ExitMenuButtonRect
            check(rect and self:HandleUILeftClick((rect.x1+rect.x2)/2,(rect.y1+rect.y2)/2),'Exit button click is routed')
            check(self.ExitMenuActive and self.TimeScale==0,'Exit button opens its action menu and freezes the battle')
            return
        elseif exitMenuDraws==0 then
            if self.ReviewProbeHeadless then self:DrawExitMenu(gr.getScreenWidth(),gr.getScreenHeight()); exitMenuDraws=1 end
            return
        end
        local rect=self.ExitMenuButtonRects.resume
        check(rect and self.ExitMenuButtonRects.restart and self.ExitMenuButtonRects.quit,'rendered Exit menu offers Resume, Restart and Quit')
        check(self:HandleUILeftClick((rect.x1+rect.x2)/2,(rect.y1+rect.y2)/2),'scripted native Resume coordinates reach the central UI handler')
        check(not self.ExitMenuActive and self.TimeScale>0 and self.Enabled,'rendered Resume action returns to the same RTS mission')
        check(self.Enabled and gr.getCurrentCamera().Name==self.Camera.Name,'exit-menu return preserves tactical observer view')
        self.Selected={fighter:getSignature()}
        self:IssueMove(fighter.Position+ba.createVector(1200,0,0))
        check(self.UserOrders[fighter:getSignature()].kind=='move','manual move persists')
        self:HoldSelected(); check(self.UserOrders[fighter:getSignature()].kind=='hold','hold replaces move')
        self:IssueGuard(wingmate); check(self.UserOrders[fighter:getSignature()].kind=='guard','guard replaces hold')
        attackTarget=mn.createShip('Native fighter attack target',tb.ShipClasses['SF Mara'],fighter.Orientation,
            self:GetEnemyCommand().Position+ba.createVector(0,0,15000),mn.Teams[self.Config.HostileTeam],true)
        assert(attackTarget and attackTarget:isValid()); attackTarget:setFlag(true,'immobile','invulnerable')
        self:IssueAttack(attackTarget)
        check(self.UserOrders[fighter:getSignature()].kind=='attack','attack replaces guard')
        self:BeginFleetService(fighter,'REVIEW',mn.getMissionTime(),true)
        check(self:StartPilotMode(fighter),'fighter possession enters native proxy')
        check(self.FleetServices[fighter:getSignature()]==nil,'possession releases station service')
        self:UpdatePilotMode(ba.getRealFrametime())
        check(self:GetObserver().Class==fighter.Class,'proxy mirrors real fighter class')
        stage=12
    elseif stage==12 then
        local proxy=self:GetObserver()
        check(proxy.ShieldRegenRate==0 and proxy.WeaponRegenRate==0,'native pilot proxy cannot duplicate passive recharge')
        fighter.Shields.CombinedLeft=fighter.Shields.CombinedMax*.5
        fighter.WeaponEnergyLeft=fighter.WeaponEnergyMax*.8
        self:MirrorPilotTelemetryToObserver(fighter,proxy)
        local front,back=fighter.Shields[1],fighter.Shields[2]
        local energy=fighter.WeaponEnergyLeft
        proxy.Shields[1]=proxy.Shields[1]+2; proxy.Shields[2]=proxy.Shields[2]-2
        fighter.Shields[3]=fighter.Shields[3]-1
        proxy.WeaponEnergyLeft=proxy.WeaponEnergyLeft-2; fighter.WeaponEnergyLeft=fighter.WeaponEnergyLeft-1
        self:MirrorPilotTelemetryToObserver(fighter,proxy)
        check(math.abs(fighter.Shields[1]-front-2)<.01 and math.abs(fighter.Shields[2]-back+2)<.01,
            'native shield redistribution reaches the real hull')
        check(math.abs(fighter.WeaponEnergyLeft-(energy-3))<.01,'native weapon transfer preserves simultaneous real firing expenditure')
        local after=fighter.WeaponEnergyLeft; self:MirrorPilotTelemetryToObserver(fighter,proxy)
        check(math.abs(fighter.WeaponEnergyLeft-after)<.01,'native energy mirror applies a transfer once')
        countermeasureBefore=fighter.CountermeasuresLeft
        self:SetButtonControlMode(LUA_ADDITIVE_BUTTON_CONTROL)
        self.ControlInfo.useButtonControl(-1,'LAUNCH_COUNTERMEASURE')
        startTime=mn.getMissionTime(); stage=12.05
    elseif stage==12.05 then
        self.ControlInfo.clearLuaButtonInfo()
        if mn.getMissionTime()-startTime<.2 then return end
        log('COUNTERMEASURES real='..countermeasureReal..' proxy='..countermeasureProxy..' ammo='..countermeasureBefore..'->'..fighter.CountermeasuresLeft)
        check(countermeasureReal+countermeasureProxy==1 and #countermeasures==1 and countermeasures[1]:isValid()
            and countermeasures[1].Parent:getSignature()==fighter:getSignature() and fighter.CountermeasuresLeft==countermeasureBefore-1,
            'native countermeasure action creates one decoy owned by the real hull and consumes one charge')
        commMate=mn.createShip('Comm permitted wingmate',tb.ShipClasses['GTF Myrmidon'],fighter.Orientation,
            fighter.Position+ba.createVector(0,1000,0),mn.Teams[self.Config.FriendlyTeam],true)
        self:InvalidateShipList(); self:RegisterLogicalWing({fighter,commMate},'Comm review wing')
        self:SetButtonControlMode(LUA_ADDITIVE_BUTTON_CONTROL)
        self.ControlInfo.useButtonControl(-1,'SQUADMSG_MENU')
        commAt=mn.getMissionTime(); stage=120
    elseif stage==120 or stage==121 then
        self.ControlInfo.clearLuaButtonInfo()
        local desired='Depart'
        local selected=false
        for i=1,#mn.CommItems do
            local item=mn.CommItems[i]
            if item.Name==desired then check(item:selectItem(),'native comm menu selects '..desired); selected=true; break end
        end
        if selected then
            check(not self.PilotCommMenuPending,'native pilot C opens the wing command list without the empty Wings submenu')
            stage=122
        end
        if mn.getMissionTime()-commAt>10 then assert(false,'native comm menu did not expose '..desired) end
    elseif stage==122 then
        if commBlocked>0 and mn.getMissionTime()-commAt>1 then
            check(not commMate:isDepartingWarp(),'native wingmate Depart is disabled')
            check(not fighter:isDepartingWarp() and not self:GetObserver():isDepartingWarp()
                and not wingmate:isDepartingWarp() and not self:GetCarrier():isDepartingWarp(),
                'native All Fighters Depart protects pilot proxy station and unrelated wing')
            check(self.UserOrders[commMate:getSignature()]==nil,'blocked Depart leaves prior command ownership intact')
            self.ControlInfo.clearLuaButtonInfo(); self:SetPilotInputMode(); stage=123
        elseif mn.getMissionTime()-commAt>10 then assert(false,'native broadcast did not reach both permitted and blocked recipients') end
    elseif stage==123 then
        if not self.ReviewProbeHeadless then check(fighterDraws>0,'native fighter possession HUD rendered without a Lua error') end
        self:ExitPilotMode(nil,false)
        check(self.PossessedSignature==nil and self.UserOrders[fighter:getSignature()].kind=='attack','exit restores manual intent')
        local ok,createdCapital=self:SpawnFriendly({class='GTD Orion',label='Capital Review',count=1})
        capital=createdCapital and createdCapital[1]
        check(ok and capital and capital:isValid(),'capital spawn uses upstream creation')
        stage=11
    elseif stage==11 then
        local destination=capital.Position+ba.createVector(1200,0,0)
        check(self:MoveShipTo(capital,destination),'capital accepts a silent move before possession')
        self:SetUserOrder(capital,{kind='move',destination=destination,manual=true})
        check(self:StartPilotMode(capital),'capital possession enters')
        check(self.PilotTurretGroups and #self.PilotTurretGroups>0,'native capital turret banks form groups')
        local proxy=self:GetObserver()
        for i=1,#proxy do
            if proxy[i]:isTurret() then check(proxy[i].TurretLocked,'mirrored capital proxy turret is disarmed') end
        end
        local enabledTurrets=0
        for _,group in ipairs(self.PilotTurretGroups) do
            for _,entry in ipairs(group.turrets) do if not entry.wasLocked then enabledTurrets=enabledTurrets+1 end end
        end
        check(enabledTurrets>0,'possession does not inherit the move-order turret lock')
        self:CyclePilotTurretGroup(1); self:TogglePilotTurretGroup()
        self:UpdatePilotTurretFire(true,true)
        stage=13
    elseif stage==13 then
        if not self.ReviewProbeHeadless then check(capitalDraws>0,'native capital possession HUD rendered without a Lua error') end
        self.PilotDeathRestoreTimeScale=8; self.PilotDeathRestoreLastNonZeroTimeScale=8
        self:SetPaused(true); self:ExitPilotMode(nil,false)
        check(self.Paused and self.TimeScale==0 and self.PausedTimeScale==8,'ejection speed restoration preserves explicit pause')
        self:SetPaused(false); self:SetTimeScale(1)
        check(self:GetObserver().Class.Name=='GTF Ulysses','observer class restored')
        self:SetTimeScale(2); self:SetPaused(true); self:StepTimeScale(1)
        check(self.TimeScale==0 and self.PausedTimeScale==4,'paused speed step keeps native clock frozen')
        self:OnKeyPressed('Alt-0','0')
        check(not self.Paused and self.TimeScale==16 and self:ShouldOverrideKey('Alt-0','0'),'absolute speed key resumes without native action')
        self:SetTimeScale(1)
        self:OnKeyPressed('Esc','Esc'); check(self.ExitMenuActive and self:ShouldOverrideKey('Esc','Esc'),'RTS Escape opens the action menu')
        self:OnKeyPressed('Esc','Esc'); check(not self.ExitMenuActive and self.TimeScale>0 and self:ShouldOverrideKey('Esc','Esc'),'Escape resumes from the action menu without leaking a native pause')
        self:SetPaused(false)
        capital.Position=ba.createVector(-4000,0,-8000)
        pursueTarget=mn.createShip('Native capital pursuit target',tb.ShipClasses['GTD Hecate'],
            ba.createOrientationFromVectors(ba.createVector(0,0,1)),ba.createVector(4000,0,-8000),mn.Teams[self.Config.HostileTeam],true)
        assert(pursueTarget:isValid()); pursueTarget:setFlag(true,'immobile','invulnerable')
        self:InvalidateShipList(); self.Selected={capital:getSignature()}; self:IssueAttack(pursueTarget)
        check(self.AIPursuit[capital:getSignature()]~=nil,'native manual capital target installs pursuit against another capital')
        pursueOrigin=capital.Position:copy(); pursueAt=mn.getMissionTime(); stage=131
    elseif stage==131 and mn.getMissionTime()-pursueAt>=15 then
        check(capital.Position:getDistance(pursueOrigin)>100,'native manually targeted capital actually approaches enemy capital')
        self:SetUserOrder(capital,{kind='hold'}); self:HoldShip(capital,.95); self:RefreshAIPursuit(mn.getMissionTime()+2)
        check(not self.AIPursuit[capital:getSignature()],'native retasking ends capital pursuit')
        pursueTarget:vanish(); self:InvalidateShipList(); stage=14
    elseif stage==14 then
        victim=self:SpawnFactionUnit('SF Mara',self:GetEnemyCommand(),mn.Teams[self.Config.HostileTeam],
            'Review Victim',1,1,1,1,1)
        check(victim and victim:isValid(),'enemy unit created')
        local before=self.AIStats.losses.RED and self.AIStats.losses.RED['SF Mara'] or 0
        local playerStats=ba.getCurrentPlayer().Stats
        local pilotKillsBefore=playerStats.MissionTotalKills
        local classKillsBefore=playerStats:getMissionShipclassKills(victim.Class)
        check(self:StartPilotMode(fighter),'pilot possession starts for native kill gauge test')
        victim:kill(fighter)
        check(self.AIStats.losses.RED['SF Mara']==before+1,'native death hook accounts loss')
        local updatedPlayerStats=ba.getCurrentPlayer().Stats
        local classKillsAfter=updatedPlayerStats:getMissionShipclassKills(victim.Class)
        log('PILOT_KILL_STATS total='..tostring(pilotKillsBefore)..'->'..tostring(updatedPlayerStats.MissionTotalKills)
            ..' class='..tostring(classKillsBefore)..'->'..tostring(classKillsAfter)
            ..' factionKills='..tostring(self.AIStats.kills.BLUE and self.AIStats.kills.BLUE['SF Mara']))
        check(updatedPlayerStats.MissionTotalKills==pilotKillsBefore+1
            and classKillsAfter==classKillsBefore+1,
            'kill from possessed ship updates native kill gauge and ship-class stats')
        self:ExitPilotMode(nil,false)
        local reward=self.CommandPoints
        self:OnShipDeath(victim,fighter)
        check(self.AIStats.losses.RED['SF Mara']==before+1 and self.CommandPoints==reward,'repeated callback cannot duplicate loss or bounty')
        local reserve=mn.createShip('Resumed hostile reserve',tb.ShipClasses['SF Mara'],
            ba.createOrientationFromVectors(ba.createVector(0,0,1)),ba.createVector(60000,0,60000),mn.Teams[self.Config.HostileTeam],true)
        assert(reserve:isValid()); reserve:setFlag(true,'immobile','primaries-locked','secondaries-locked')
        self:InvalidateShipList()
        self.FreeCamActive=true
        self:OpenPostBattle('PROBE REPORT')
        check(self.PostBattleActive and not self.FreeCamActive,'post-battle report exits hidden UI without custom damage hook')
        self.PostBattleActive=false; self.BattleVictor=nil; self.GameStatus='ACTIVE'; self:SetTimeScale(1)
        self:GetEnemyCommand():kill(); self:GetThirdCommand():kill(); self:GetCarrier():kill()
        check(not self.PostBattleActive,'station death callbacks defer final report')
        stage=2
    elseif stage==1 and mn.getMissionTime()-startTime>30 then
        assert(false,'production queue did not complete in 30 mission seconds')
    elseif stage==2 then
        check(self.BlueEliminated and self.RedEliminated and self.GoldEliminated,'same-frame native station deaths all recorded')
        check(self.PostBattleActive and self.BattleVictor=='NONE' and self.PostBattleResult:find('MUTUAL'),
            'same-frame station deaths produce mutual destruction')
        check(#self.BattleSummary.factions==3,'report retains eliminated faction rows')
        check(fighter:isValid() and wingmate:isValid(),'station losses retain native surviving ships')
        check(self:ResumePostBattle() and self.AftermathActive and self.GameStatus=='ACTIVE' and self.TimeScale==1,
            'native result resumes surviving assets')
        local bank=self.CommandPoints
        self:QueueBuildOption({class='GTF Myrmidon',label='Forbidden',cost=1,time=.1,count=1,tier=1})
        check(#self.BuildQueue==0 and self.CommandPoints==bank and not self:SpendFactionCP('BLUE',1),
            'native resumed battle rejects construction and spending')
        self:EvaluateFactionVictory()
        check(not self.PostBattleActive,'resumed native result does not immediately reopen')
        self.Selected={fighter:getSignature()}
        check(self:StartPilotMode(fighter),'native survivor can be possessed after Blue station loss')
        self:ExitPilotMode(nil,false)
        self:OpenSurvivorReport()
        if self.ReviewProbeHeadless==true then log('COMPLETE native checks passed (HUD/restart skipped)'); quit()
        else startTime=self:UINow(); stage=3 end
    elseif stage==3 and self:UINow()-startTime>.25 then
        check(reportDraws>0,'native report HUD rendered without a Lua error')
        self.FreeCamActive=true; self.BattleCamActive=true
        self:RestartMission(); stage=4
    elseif stage==4 and nativeStarts>=2 and self.Enabled and self.SetupActive then
        check(not self.FreeCamActive and not self.BattleCamActive and self.PossessedSignature==nil,
            'native mission restart clears direct-control and camera modes')
        check(#self.BuildQueue==0 and not self.PostBattleActive and self.BattleVictor==nil
            and next(self.AIStats.losses)==nil,'native mission restart clears queues and battle accounting')
        check(gr.getCurrentCamera().Name==self.Camera.Name and self:GetObserver().Class.Name=='GTF Ulysses',
            'native mission restart restores tactical observer camera and hull')
        check(setupDraws>0,'native setup HUD rendered without a Lua error')
        check(not self.AftermathActive,'native restart clears survivors-only phase')
        self.SetupAutoMode=false; self.SetupOpponents={RED=true,GOLD=true}; self:StartScenario()
        self.Config.AI.Enabled=false
        survivorVictim=mn.createShip('Survivor Blue fixture',tb.ShipClasses['GTF Myrmidon'],
            ba.createOrientationFromVectors(ba.createVector(0,0,1)),ba.createVector(-15000,0,-5000),mn.Teams[self.Config.FriendlyTeam],true)
        survivorAttacker=mn.createShip('Survivor Red fixture',tb.ShipClasses['GTF Myrmidon'],
            ba.createOrientationFromVectors(ba.createVector(0,0,1)),ba.createVector(-15000,0,-5300),mn.Teams[self.Config.HostileTeam],true)
        assert(survivorVictim:isValid() and survivorAttacker:isValid())
        self:InvalidateShipList()
        survivorVictim:setFlag(true,'immobile','primaries-locked','secondaries-locked')
        survivorAttacker:setFlag(true,'immobile','secondaries-locked')
        survivorVictim.HitpointsMax=1000000; survivorVictim.HitpointsLeft=1000000; survivorVictim.Shields.CombinedLeft=0
        survivorHull=survivorVictim.HitpointsLeft
        self:SetUserOrder(survivorVictim,{kind='hold'}); self:HoldShip(survivorVictim,.95)
        self:GetEnemyCommand():kill(survivorVictim)
        startTime=mn.getMissionTime(); stage=5
    elseif stage==5 then
        if survivorVictim.HitpointsLeft<survivorHull then
            self:UpdateDefeatedFleetExtraction(mn.getMissionTime())
            check(survivorAttacker:isValid() and self.RedEliminated and self:AreEnemies(survivorAttacker,survivorVictim),
                'native stationless enemy retains hostility and damages surviving Blue assets')
            check(self.FactionDefeatedBy.RED=='BLUE' and self.AIOrderState[survivorAttacker:getSignature()].reason=='RETALIATE_BASE_KILLER',
                'native station death attributes killer faction and survivors retaliate')
            self.Config.AI.Enabled=true; self.LastAIStrategicUpdate=-100; self.AIStrategicPlanQueue=nil
            self:UpdateAIStrategicObjectives(mn.getMissionTime())
            check(self.AIOrderState[survivorAttacker:getSignature()].assignedAt~=nil
                and self.AIObservations[survivorAttacker:getSignature()].engagementDelay~=nil,
                'native strategic observation accepts stationless fleet assignments while other bases survive')
            self:GetCarrier():kill(); stage=6
        elseif mn.getMissionTime()-startTime>20 then assert(false,'stationless native fighter did not damage a close target') end
    elseif stage==6 then
        check(self.PostBattleActive and self.GameStatus=='DEFEAT','native Blue station loss opens defeat')
        check(self:ResumePostBattle() and self.AftermathStationCount==1,'native defeat resumes against last surviving station')
        self:GetThirdCommand():kill(); stage=7
    elseif stage==7 then
        check(self.PostBattleActive and self.GameStatus=='DRAW' and self.BattleVictor=='GOLD'
            and self.StrategicResult.victor=='GOLD',
            'native aftermath earns a draw after the remaining base is destroyed while preserving first-report history')
        check(self:ResumePostBattle(),'native draw resumes for observation')
        self:EvaluateFactionVictory()
        check(not self.PostBattleActive,'native draw does not reopen in a resume loop')
        self:EachShip(function(ship)
            if ship:isValid() and self:GetFactionKey(ship)~='BLUE' and ship.Name~=self.Config.ObserverShip then ship:kill() end
        end)
        stage=8
    elseif stage==8 then
        check(self.PostBattleActive and self.GameStatus=='VICTORY' and self.FleetFateFinal
            and self.StrategicResult.victor=='GOLD',
            'native sole-survivor force earns victory while preserving earlier report history')
        self:DrawPostBattleOverlay(gr.getScreenWidth(),gr.getScreenHeight())
        check(self.PostBattleButtonRects.resume==nil and not self:ResumePostBattle(),
            'native final survivor victory has no Resume button or resumable action')
        log('COMPLETE all native checks passed'); quit()
    end
end

R.OnFrame=function(self)
    if finished then return end
    local ok,err=pcall(function()
        originalFrame(self); probe(self)
    end)
    if not ok then log('FAIL '..tostring(err)); quit() end
end
return true
