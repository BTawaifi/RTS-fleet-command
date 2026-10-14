-- Victory, faction spawn/elimination, warmup, scenario start, frame/death hooks.
local Config = require "fs2rts_config"
local U = require "fs2rts_util"
local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys
local RTS = require "fs2rts_state"
local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

function RTS:ScaleCommandStationsForEscalation()
    local profile=self:GetEscalationProfile(); if profile==nil then return end; local scale=profile.stationHullScale or 1
    self.FactionStationRadii=self.FactionStationRadii or {}
    if self.SetupFactionCount>=3 then scale=scale*(profile.threeFactionStationScale or 1) end
    for _,kind in ipairs(self:GetFactionKeys()) do
        if self:IsFactionEnabled(kind) then
            local station=self:GetFactionCommandShip(kind)
            if shipValid(station) then
                self.FactionStationRadii[kind]=station.Radius
                local configuredBase=self.Config.StationBaseHull
                local base=self.StationBaseHull[station.Name] or configuredBase or station.HitpointsMax
                self.StationBaseHull[station.Name]=base
                station.HitpointsMax=base*scale
                station.HitpointsLeft=station.HitpointsMax
                -- Hull armor alone leaves gun mounts vulnerable to full light
                -- weapon/debris damage. Protect the whole fixed installation.
                for i=1,#station do station[i].ArmorClass='RTS Command Hull' end
            end
        end
    end
end

function RTS:GetLivingFactionKeys()
    local result = {}
    for _,kind in ipairs(self:GetFactionKeys()) do
        if not self:IsFactionEliminated(kind) and shipAlive(self:GetFactionCommandShip(kind)) then result[#result+1]=kind end
    end
    return result
end

-- Snapshot the numbers the after-action report needs. Everything is read from
-- state the sim already tracks, so the report costs nothing to build.
function RTS:BuildBattleSummary()
    local summary={durationSeconds=self:GetScenarioElapsed(),tier=self:GetCurrentEscalationTier(),
        cpRemaining=self.CommandPoints,cpSpent=0,losses=0,kills=0,capitalLosses=0,fleetCap=self:GetFleetCap("BLUE"),factions={}}
    for _,kind in ipairs(self:GetFactionKeys()) do
        if self:IsFactionEnabled(kind) then
            local faction=self.Config.Factions[kind]
            summary.factions[kind]={key=kind,label=self:GetFactionDisplayName(kind),ships=0,mobileShips=0,installations=0}
        end
    end
    self:EachShip(function(ship)
        if ship.Name==self.Config.ObserverShip or not shipAlive(ship) then return end
        local kind=self:GetFactionKey(ship)
        if kind~=nil then
            local entry=summary.factions[kind]
            if entry==nil then
                local faction=self.Config.Factions[kind]
                entry={key=kind,label=self:GetFactionDisplayName(kind),eliminated=false,ships=0,mobileShips=0,installations=0}
                summary.factions[kind]=entry
            end
            entry.ships=entry.ships+1
            if self:IsCommandStation(ship) or self:IsStaticDefense(ship) then entry.installations=entry.installations+1 else entry.mobileShips=entry.mobileShips+1 end
        end
    end)
    local ordered={}
    for _,kind in ipairs(self:GetFactionKeys()) do
        local entry=summary.factions[kind]
        if entry then ordered[#ordered+1]=entry end
    end
    summary.factions=ordered
    for _,entry in ipairs(ordered) do entry.eliminated=self:IsFactionEliminated(entry.key) end
    local blueLosses=self.AIStats and self.AIStats.losses and self.AIStats.losses["BLUE"]
    if blueLosses~=nil then
        for className,count in pairs(blueLosses) do
            summary.losses=summary.losses+(count or 0)
            local role=self.ShipCostRoleMap and self.ShipCostRoleMap[className]
            if role=="capital" or role=="heavy" or role=="juggernaut"
                or className:find("Sathanas") or className:find("Colossus") or className:find("Lucifer")
                or className:find("Deimos") or className:find("Sobek") or className:find("Hecate")
                or className:find("Orion") or className:find("Hatshepsut") or className:find("Ravana")
                or className:find("Arcadia") then
                summary.capitalLosses=summary.capitalLosses+(count or 0)
            end
        end
    end
    local kills=self.AIStats and self.AIStats.kills and self.AIStats.kills.BLUE or {}
    for _,count in pairs(kills) do summary.kills=summary.kills+(count or 0) end
    local flow=(self.AIEconomyFlowCumulative or self.AIEconomyFlow or {}).BLUE
    if flow~=nil then summary.cpSpent=(flow.productionSpend or 0)+(flow.refund and -flow.refund or 0) end
    summary.fleetHistory=self.GetFleetHistorySummary and self:GetFleetHistorySummary() or nil
    summary.strategicVictor=self.StrategicResult and self.StrategicResult.victor or 'UNRESOLVED'
    summary.playerStationLost=self.BlueEliminated==true
    return summary
end

-- Report visibility, the player's station loss and global resolution are
-- separate state. A later fleet fate never rewrites the strategic snapshot.
function RTS:EvaluateFactionVictory()
    if self.SetupActive or self.PostBattleActive then return end
    local living=self:GetLivingFactionKeys()
    if not self.StrategicResult and #living<=1 then
        local victor=living[1] or 'NONE'
        self.BattleVictor=victor
        self.StrategicResult={victor=victor,time=mn.getMissionTime(),summary=self:BuildBattleSummary()}
        self:EnterGlobalAftermath()
        self.GameStatus=victor=='NONE' and 'DRAW' or victor=='BLUE' and 'VICTORY' or 'DEFEAT'
        self.AftermathResultStatus=self.GameStatus
        self.AftermathResultText=victor=='NONE' and 'MUTUAL DESTRUCTION // NO COMMAND STATION SURVIVED'
            or self:GetFactionDisplayName(victor)..' WON THE STRATEGIC BATTLE'
        if self.BlueEliminated and victor~='NONE' then self.AftermathResultText='YOUR STATION DESTROYED // '..self.AftermathResultText end
        self.BattleSummary=self:BuildBattleSummary(); self:OpenPostBattle(self.AftermathResultText)
    elseif not self.StrategicResult and self.BlueEliminated and not self.PlayerDefeatShown then
        self.PlayerDefeatShown=true; self.PlayerStationLostAt=mn.getMissionTime()
        self.GameStatus='DEFEAT'; self.BattleSummary=self:BuildBattleSummary()
        self:OpenPostBattle('YOUR STATION WAS LOST // THE GLOBAL BATTLE CONTINUES')
    elseif self.StrategicResult and not self.FleetFateFinal then
        local mobile,player,opponents=0,0,0
        for _,ship in ipairs(self:GetShipList()) do
            if shipAlive(ship) and ship.Name~=self.Config.ObserverShip then
                local own=self:GetFactionKey(ship)=='BLUE'
                if not own then opponents=opponents+1 end
                if not self:IsCommandStation(ship) and not self:IsStaticDefense(ship) then
                    mobile=mobile+1; if own then player=player+1 end
                end
            end
        end
        -- The player's fleet is settled once none of its own mobile hulls remain
        -- (escaped or lost). Hostile leftovers must not hold the result open, so
        -- this test is on the player's count, not the global one.
        if player==0 or opponents==0 then
            self.FleetFateFinal=true
            local escaped=0
            for _,record in pairs(self.UnitHistory or {}) do
                if record.faction=='BLUE' and record.fate=='ESCAPED' then escaped=escaped+1 end
            end
            self.AftermathResultStatus=player>0 and opponents==0 and 'VICTORY' or #living==0 and 'DRAW' or self.AftermathResultStatus
            self.AftermathResultText=player>0 and opponents==0 and 'YOUR FACTION IS THE SOLE REMAINING FORCE'
                or #living==0 and 'MUTUAL DESTRUCTION // NO COMMAND STATION SURVIVED' or self.AftermathResultText
            if escaped>0 then self.AftermathResultText='FLEET EXTRACTED // '..self.AftermathResultText end
            self.BattleSummary=self:BuildBattleSummary(); self.GameStatus=self.AftermathResultStatus
            self:OpenPostBattle(self.AftermathResultText..(mobile==0 and ' // NO MOBILE SHIPS REMAIN' or ''))
        elseif #living==0 and self.AftermathResultStatus~='DRAW' then
            -- Keep the first strategic report as history, while continued combat
            -- can still earn the draw offered by Resume.
            self.AftermathResultStatus='DRAW'; self.GameStatus='DRAW'
            self.AftermathResultText='MUTUAL DESTRUCTION // NO COMMAND STATION SURVIVED'
            self.BattleSummary=self:BuildBattleSummary(); self:OpenPostBattle(self.AftermathResultText)
        end
    end
end

function RTS:EnterGlobalAftermath()
    if self.AftermathActive then return end
    self.AftermathActive=true; self.AftermathStationCount=#self:GetLivingFactionKeys()
    for _,sig in ipairs(sortedNumericKeys(self.FleetServices or {})) do
        local ship=self:FindShipBySignature(sig); local service=self.FleetServices[sig]
        if shipValid(ship) then self:CancelFleetServiceForShip(ship,service.pendingOrder) end
    end
    self.FleetServices={}; self.PendingStrikes={}
    for _,job in ipairs(self.PendingSentries or {}) do
        self:EmitAIEvent('SENTRY_BUILD',{action='BUILD_CANCELLED',faction=job.kind,class=job.option.class,
            jobId=job.id,cost=job.cost,refundedCP=0,reason='GLOBAL_RESULT'},mn.getMissionTime())
    end
    self.PendingSentries={}
    for _,queued in ipairs(self.BuildQueue or {}) do
        self:EmitAIEvent('PRODUCTION',{action='QUEUE_CANCELLED',producer='PLAYER',faction='BLUE',
            jobId=queued.id,class=queued.option.class,count=queued.option.count or 1,cost=queued.option.cost,
            refundedCP=0,reason='GLOBAL_RESULT',queuedAt=queued.queuedAt},mn.getMissionTime())
    end
    self.BuildQueue={}
    for kind,state in pairs(self.AIStates or {}) do
        local queue=state.queue
        if queue then self:EmitAIEvent('PRODUCTION',{action='QUEUE_CANCELLED',producer='AI',faction=kind,
            jobId=queue.id,class=queue.entry.class,count=queue.count or 1,cost=queue.estimate.cost,refundedCP=0,
            reason='GLOBAL_RESULT',queuedAt=queue.queuedAt},mn.getMissionTime()) end
        state.queue=nil; state.AutoBuildRequest=nil
    end
    self:EmitAIFinalBalance(self.BattleVictor,mn.getMissionTime())
end

-- Only scripts change the button control mode, so it is set on transitions
-- instead of every frame. ButtonControlMode is cleared by ResetState and
-- Shutdown, which set the engine mode directly.
function RTS:SetButtonControlMode(mode)
    if self.ButtonControlMode ~= mode then
        ba.setButtonControlMode(mode)
        self.ButtonControlMode = mode
    end
end

function RTS:SetRTSInputMode()
    -- Keep native button actions (weapon cycling, target commands, etc.) from
    -- leaking through while the mouse is being used as an RTS cursor. Continuous
    -- fire bindings are additionally neutralized by DisarmObserverWeapons().
    self:SetButtonControlMode(LUA_OVERRIDE_BUTTON_CONTROL)
    -- Still every frame: this drops button presses accumulated since last frame.
    if self.ControlInfo ~= nil then self.ControlInfo.clearLuaButtonInfo() end
end

function RTS:SetPilotInputMode()
    self:SetButtonControlMode(NORMAL_BUTTON_CONTROLS)
end

function RTS:DisarmObserverWeapons()
    local observer = self:GetObserver()
    if not shipValid(observer) then return end
    observer.PrimaryTriggerDown = false
    observer:setFlag(true,"primaries-locked","secondaries-locked")
    self:DisarmObserverTurrets(observer)
    if observer.PrimaryBanks ~= nil then
        -- Armed=false selects bank -1; the native HUD still evaluates the
        -- observer and asserts. Lock firing without invalidating its selection.
        if #observer.PrimaryBanks>0 then observer.PrimaryBanks[1].Armed = true end
        observer.PrimaryBanks.Linked = false
    end
    if observer.SecondaryBanks ~= nil then
        if #observer.SecondaryBanks>0 then observer.SecondaryBanks[1].Armed = true end
        observer.SecondaryBanks.DualFire = false
    end
    if self.ControlInfo ~= nil then
        self.ControlInfo.PrimaryCount = 0
        self.ControlInfo.SecondaryCount = 0
        self.ControlInfo.CountermeasureCount = 0
        self.ControlInfo.clearLuaButtonInfo()
    end
end

function RTS:DisarmObserverTurrets(observer)
    -- Ship bank locks do not stop turret AI. A mirrored capital proxy must
    -- never add a second autonomous battery inside the controlled hull.
    if not shipValid(observer) then return end
    for i=1,#observer do
        local subsystem=observer[i]
        if subsystem:isValid() and subsystem:isTurret() then subsystem.TurretLocked=true end
    end
end

function RTS:SpawnFactionStations()
    for _,kind in ipairs(self:GetFactionKeys()) do
        local def=self:GetFactionDefinition(kind)
        local species=self.Config.Species[self:GetFactionSpecies(kind)]
        local class=species and tb.ShipClasses[species.stationClass]
        local team=def and mn.Teams[def.team]
        if not def or not class or not class:isValid() or not team or not team:isValid() then
            self:Log("FACTION STATION SETUP FAILED: "..tostring(kind))
            return false
        end
        local station=mn.Ships[def.station]
        if shipValid(station) then
            if station.Class.Name~=class.Name then station.Class=class end
            station.Team=team
        else
            local p=self:GetScenarioBasePosition(kind)
            local orient=vec(-p.x,-p.y,-p.z):getOrientation()
            station=mn.createShip(def.station,class,orient,vec(p.x,p.y,p.z),team,true)
            self:InvalidateShipList()
            if not shipValid(station) then self:Log("FACTION STATION SPAWN FAILED: "..def.station); return false end
            -- The mission-placed bases were no-shields; every base now carries it.
            station:setFlag(true,"no-shields")
        end
        local p=self:GetScenarioBasePosition(kind)
        station.Orientation=(self:GetFactionBattleFacingPoint(kind)-p):getOrientation()
        station:setFlag(true,"immobile")
        self:ApplyFactionVisual(station,kind)
        self:EnableFullArsenal(station)
        self:ApplyStationDefenseProgression(kind,0)
    end
    return true
end

function RTS:SpawnGoldFaction()
    return self:SpawnFactionStations()
end

function RTS:SpawnSentryDefenses()
    self.StaticDefenseSignatures={}

    local spawned=0
    for _,kind in ipairs(self:GetFactionKeys()) do
        if self:IsFactionEnabled(kind) then
            local entry=self:GetSentryOptions(kind)[1]
            local position=entry and self:FindSentrySpot(kind)
            if position and self:PlaceSentry(kind,entry,position,true) then spawned=spawned+1 end
        end
    end
    if spawned>0 then self:Log("Spawned "..spawned.." stationary sentry defenses") end
    return spawned
end

function RTS:CreateOptionalAsteroidField()
    if not self.SetupAsteroids then return end
    -- Build a sparse passive field above the normal fleet flight plane so it
    -- adds terrain without turning current straight-line AI orders into traps.
    -- mn.runSEXP returns false on a parse error without raising, so both
    -- results have to be checked: the log line used to claim success
    -- unconditionally while the field simply did not exist.
    local okToggle=mn.runSEXP("(toggle-asteroid-field true)")
    local okConfig=mn.runSEXP('(config-asteroid-field 24 0 0 -18000 18000 4000 9000 -18000 18000 false -500 500 -500 500 -500 500 "Brown")')
    if okToggle==true and okConfig==true then
        self:Log("Created optional 24-asteroid upper-plane field")
    else
        self:Log("Asteroid field FAILED to configure (toggle="..tostring(okToggle).." config="..tostring(okConfig)..") - the field is not present")
    end
end


function RTS:EliminateFaction(kind,killerFaction)
    if not self:IsFactionEnabled(kind) or self:IsFactionEliminated(kind) then return end
    self:SetFactionEliminated(kind,true)
    if kind=='BLUE' then self.PlayerStationLostAt=self.PlayerStationLostAt or mn.getMissionTime() end

    self.FactionDefeatedBy=self.FactionDefeatedBy or {}
    if killerFaction~=kind and self:GetFactionDefinition(killerFaction) then self.FactionDefeatedBy[kind]=killerFaction end
    local def = self:GetFactionDefinition(kind)
    local label = self:GetFactionDisplayName(kind)
    if self.CombatTelemetryEnabled then self:EmitOutcomeCause(kind, mn.getMissionTime()) end
    self:ShowAnnouncement(label .. " HAS BEEN DEFEATED", 7, kind)
    self:SetStatus(label .. " station lost - surviving units remain in combat", 6)
    if self.AIStates[kind] then
        local queued=self.AIStates[kind].queue
        if queued then
            self:EmitAIEvent("PRODUCTION",{action="QUEUE_CANCELLED",producer="AI",faction=kind,
                jobId=queued.id,class=queued.entry and queued.entry.class or "UNKNOWN",count=queued.count or 1,
                cost=queued.estimate and queued.estimate.cost or 0,refundedCP=0,
                reason="FACTION_ELIMINATED",queuedAt=queued.queuedAt},mn.getMissionTime())
        end
        self.AIStates[kind].eliminated = true; self.AIStates[kind].queue = nil
    end
    if kind=="BLUE" then
        -- Losing the base must not also destroy the player's queued investment.
        -- This used to emit QUEUE_ORPHANED with refundedCP=0 for every item and
        -- leave the queue intact, so up to several hundred seconds of paid build
        -- time vanished with no notice. Refund each item pro rata by the work
        -- actually started: a queue that never began its build time is refunded
        -- in full, a half-finished one is not.
        local abandoned,refunded=0,0
        for _,queued in ipairs(self.BuildQueue or {}) do
            local option=queued.option or {}
            local cost=option.cost or 0
            local progress=0
            if queued.started and queued.startTime and queued.finishTime then
                local span=queued.finishTime-queued.startTime
                if span>0 then progress=clamp((mn.getMissionTime()-queued.startTime)/span,0,1) end
            end
            local back=math.floor(cost*(1-progress)*0.95+0.5)
            if back>0 then self.CommandPoints=self.CommandPoints+back; refunded=refunded+back end
            abandoned=abandoned+1
            self:EmitAIEvent("PRODUCTION",{action="QUEUE_REFUNDED",producer="PLAYER",faction="BLUE",
                jobId=queued.id,class=option.class or "UNKNOWN",count=option.count or 1,cost=cost,refundedCP=back,
                progress=progress,reason="BASE_DESTROYED",queuedAt=queued.queuedAt},mn.getMissionTime())
        end
        self.BuildQueue={}
        if abandoned>0 then
            self:RecordAIEconomyFlow("BLUE","refund",refunded)
            self:SetStatus("Base lost - "..abandoned.." queued build"..(abandoned==1 and "" or "s").." refunded ("..refunded.." CP)",5)
            self:Log(string.format("Base destroyed: abandoned %d queued build(s), refunded %d CP",abandoned,refunded))
        end
    end
    self.FactionPrimaryTargets[kind]=nil

    -- Station elimination closes production, not the surviving fleet's IFF
    -- or combat orders. The survivor director handles targets without a base.
    -- Death hooks may deliver several station losses in one frame. OnFrame
    -- decides the outcome after collecting all of them.
end

function RTS:BeginRosterModelWarmup()
    self.RosterModelWarmup=nil
    if not (self.Config.AI and self.Config.AI.PrewarmRosterModels~=false) then
        self:BuildShipCostMap(); self:BuildProductionCatalog(); return
    end
    -- The warmup IS the cost-map build now. PrimeRosterCostMap collects the
    -- roster without paging anything; each tick pages exactly one model and
    -- prices it, so the 63 model_load() calls that used to land in one frame are
    -- spread one per frame and the progress bar measures real work.
    local pending=self:PrimeRosterCostMap() or {}
    local firstClass=tb.ShipClasses[pending[1]]
    if firstClass==nil or type(firstClass.isModelLoaded)~='function' then
        -- No isModelLoaded: fall back to the synchronous path rather than
        -- pretending the roster is priced.
        self:Log('Roster model prewarm unavailable; pricing synchronously')
        self:BuildShipCostMap(); self:BuildProductionCatalog()
        self.RosterModelWarmup={done=true,unsupported=true}
        return
    end
    self.RosterModelWarmup={classes=pending,nextIndex=1,loaded=0,alreadyLoaded=0,failed=0,done=#pending==0}
    if #pending>0 then
        self.StatusMessage='Preparing fleet models 0/'..tostring(#pending)
        self.StatusUntil=math.huge
    end
end

function RTS:ProcessRosterModelWarmup()
    local warmup=self.RosterModelWarmup
    if warmup==nil or warmup.done then return end
    -- One class per frame. LoadRosterModelStep pops from RosterPending, which
    -- PrimeRosterCostMap filled in the same order.
    local before=self:RosterPendingCount()
    local more=self:LoadRosterModelStep()
    warmup.nextIndex=warmup.nextIndex+1
    local completed=before-self:RosterPendingCount()
    if completed==0 then completed=1 end
    warmup.loaded=warmup.loaded+1
    if not more or self:RosterPendingCount()==0 then
        warmup.done=true
        -- Catalog can only be built once every class is priced.
        self:BuildProductionCatalog()
        self.StatusMessage='Configure escalation battle, then START.'
        self.StatusUntil=math.huge
        self:Log(string.format('Roster model prewarm complete: priced=%d of %d',warmup.loaded,#warmup.classes))
    else
        self.StatusMessage='Preparing fleet models '..tostring(warmup.nextIndex-1)..'/'..tostring(#warmup.classes)
        self.StatusUntil=math.huge
    end
end

function RTS:FinishRosterModelWarmup()
    while self.RosterModelWarmup and not self.RosterModelWarmup.done do
        self:ProcessRosterModelWarmup()
    end
end

function RTS:StartScenario()
    if not self.SetupActive then return end
    self:UpdateFactionCount(); if self.SetupFactionCount<2 then self:SetStatus("Select at least one enemy faction",3); return end
    for _,kind in ipairs(self:GetFactionKeys()) do
        local def=self:GetFactionDefinition(kind); local team=def and mn.Teams[def.team]
        if not team or not team:isValid() then self:SetStatus("Faction IFF unavailable: "..tostring(def and def.team or kind),5); return end
    end
    -- Mission paging invalidates native weapon resources even when the Lua
    -- module and registered hooks survive a restart.
    self.FighterBlastVariantsLoaded={}
    self:FinishRosterModelWarmup()
    self:ResolveRandomFactionSpecies()
    self:BuildProductionCatalog()
    local economy=self.Config.Setup.Economies[self.SetupEconomyIndex]; local duration=self:GetEscalationProfile(); self.CommandPoints=economy.startCP; self.ActiveIncomePerSecond=economy.income*(duration.playerIncomeScale or 1)
    self.AutoPlayerMode=self.SetupAutoMode==true
    for _,kind in ipairs(self.Config.FactionOrder or self:GetFactionKeys()) do
        if not self:IsFactionEnabled(kind) then self:DisableFactionShips(kind) end
    end
    -- The setup backdrop is vanished here so the real bases spawn into empty space.
    self:ClearSetupBackdrop()
    self:ApplyConfiguredBaseSpacing()
    if not self:SpawnFactionStations() then
        self:CreateSetupBackdrop()
        self:SetStatus("Could not initialize every command station",5); return
    end
    self.SetupActive=false; self.GameStatus="ACTIVE"; self.FactionEliminated={}; self.BlueEliminated=false; self.RedEliminated=false; self.GoldEliminated=false
    for _,kind in ipairs(self.Config.FactionOrder or AI_FACTION_ORDER) do self:SetFactionEliminated(kind,not self:IsFactionEnabled(kind)) end
    self.BattleVictor=nil; self.PostBattleActive=false; self.PostBattleResult=nil
    self:ResetFleetLife()
    self.ScenarioStartTime=mn.getMissionTime(); self.LastIncomeTime=self.ScenarioStartTime; self.StatusUntil=self:UINow()+6; self.StatusMessage=self.AutoPlayerMode and ("ESCALATION STARTED // "..self:GetFactionDisplayName("BLUE").." AUTO MODE") or "ESCALATION STARTED"
    self.CombatTelemetryEnabled=true; self:RegisterBaseDamageProtection(); self:RegisterBaseDamageTelemetry(); self:RegisterCombatDamageTelemetry(); self:RegisterStationBeamHitHook(); self:StartAITrace(); self:SetMissionFocusPolicy(true)
    self:ScaleCommandStationsForEscalation(); self:CaptureBaseHullBaseline()
    self:CreateOptionalAsteroidField()
    self:ResetStationState()
    if self.SetupSentries then self:SpawnSentryDefenses() end
    self:InitializeAIStates(self.ScenarioStartTime); self:InitializeUnitOrders(); self:SetTimeScale(1)
    self.BattleSummary=nil; self.MusicMuted=false; self:SetMusicMuted(false,true)
    if ad and ad.playMusic then self:SetEnvironmentMusic(self.SetupMusicChoice or 'RANDOM',true) end
    if mn.addBackgroundBitmapNew then self:SetNebulaBackdrop(self.SetupBackdropChoice or 'RANDOM',true) end
    self:ShowAnnouncement("TIER 1 // ESCALATION BEGINS",4,"BLUE")
end

function RTS:CycleSetupValue(kind,delta)
    if kind=="difficulty" then local max=#self.Config.Setup.Difficulties; self.SetupDifficultyIndex=((self.SetupDifficultyIndex-1+delta)%max)+1
    elseif kind=="economy" then local max=#self.Config.Setup.Economies; self.SetupEconomyIndex=((self.SetupEconomyIndex-1+delta)%max)+1
    elseif kind=="distance" then local max=#(self.Config.Setup.BaseDistances or {}); if max>0 then self.SetupBaseDistanceIndex=((self.SetupBaseDistanceIndex-1+delta)%max)+1 end
    elseif kind=="layout" then local max=#(self.Config.Setup.BaseLayouts or {}); if max>0 then self.SetupBaseLayoutIndex=(((self.SetupBaseLayoutIndex or 1)-1+delta)%max)+1 end
    elseif kind=="factions" then
        local max=self:GetMaxFactionCount()
        local current=self.SetupFactionCountChoice or self.SetupFactionCount or 2
        self.SetupFactionCountChoice=2+((current-2+delta)%(max-1))
        self:UpdateFactionCount()
        local pages=math.max(1,math.ceil(self.SetupFactionCount/(self.SetupFactionPageSize or 5)))
        self.SetupFactionPage=math.min(self.SetupFactionPage or 1,pages)
    end
end

function RTS:HandleSetupClick(x,y)
    if self.EnvironmentPicker then return self:HandleFleetLifeClick(x,y) end
    for index,rect in pairs(self.SetupColorRects or {}) do
        if self:PointInside(rect,x,y) then
            if index=="random" then self:RandomizeFactionColors(); self:ApplyFactionVisuals()
            else self:SetFactionColor(self.SetupColorPicker,tonumber(index)) end
            self.SetupColorPicker=nil; self.SetupColorRects={}; return true
        end
    end
    if self.SetupColorPicker then self.SetupColorPicker=nil; self.SetupColorRects={}; return true end
    for id,rect in pairs(self.SetupButtonRects or {}) do
        if self:PointInside(rect,x,y) then
            if id=="difficulty" then self:CycleSetupValue("difficulty",1)
            elseif id=="economy" then self:CycleSetupValue("economy",1)
            elseif id=="duration" then self:CycleSetupValue("duration",1)
            elseif id=="distance" then self:CycleSetupValue("distance",1)
            elseif id=="layout" then self:CycleSetupValue("layout",1)
            elseif id=="factions" or id=="factions_more" then self:CycleSetupValue("factions",1)
            elseif id=="factions_less" then self:CycleSetupValue("factions",-1)
            elseif id=="faction_prev" then self.SetupFactionPage=math.max(1,(self.SetupFactionPage or 1)-1)
            elseif id=="faction_next" then self.SetupFactionPage=math.min(math.ceil(self.SetupFactionCount/(self.SetupFactionPageSize or 5)),(self.SetupFactionPage or 1)+1)
            elseif id:sub(1,6)=="color_" then self.SetupColorPicker=id:sub(7)
            elseif id:sub(1,8)=="faction_" and id~="faction_prev" and id~="faction_next" then self:CycleFactionChoice(id:sub(9))
            elseif id:sub(1,8)=="species_" then self:CycleFactionSpecies(id:sub(9))
            elseif id=="red" then self.SetupOpponents.RED=not self.SetupOpponents.RED; self:UpdateFactionCount()
            elseif id=="gold" then self.SetupOpponents.GOLD=not self.SetupOpponents.GOLD; self:UpdateFactionCount()
            elseif id=="environment" then self.EnvironmentPicker=true
            elseif id=="start" then self:StartScenario() end
            return true
        end
    end
    return false
end

function RTS:OnGameplayStart()
    if not self:IsRTSMission() then self.Enabled = false; return end
    self.Enabled = true
    self:ResetState()
    self.PreviousMouseControl = io.MouseControlStatus
    io.MouseControlStatus = false
    io.setCursorHidden(false)
    mn.runSEXP("(player-use-ai)")
    self.ControlInfo = ba.getControlInfo()
    if self.ControlInfo ~= nil then
        self.PreviousAllButtonPolling = self.ControlInfo.AllButtonPolling
        self.ControlInfo.AllButtonPolling = true
    end
    self:SetRTSInputMode()
    local observer = self:GetObserver()
    if shipValid(observer) then
        self.ObserverHomePosition = copyVec(observer.Position)
        self.ObserverHomeOrientation = observer.Orientation:copy()
    end
    self:SetupCamera()
    -- BuildShipCostMap/BuildProductionCatalog are no longer called here: the
    -- warmup prices one roster class per frame and builds the catalog when it
    -- finishes. Calling them synchronously would page all 63 POFs in this frame.
    self:BeginRosterModelWarmup()
    self:InitializeSetupHold()
    self:RegisterCrewProjectileEvidence()
    self:DisarmObserverWeapons()
    self:StartIntroCinematic()
    self:CreateSetupBackdrop()
    self:SetMissionFocusPolicy(self:ShouldDisableUnfocusedPause())
    self.LastIncomeTime = mn.getMissionTime()
    self:Log("RTS setup mode enabled; cost map contains " .. tostring(#tb.ShipClasses) .. " loaded classes")
end

-- States that stack on top of gameplay without ending the mission. Mirrors
-- the end_mission==0 list in freespace2.cpp's game_leave_state(), plus
-- GS_STATE_HUD_CONFIG (a submenu the engine leaves out of that switch).
-- Anything not listed really is terminal, so OnStateEnd must tear down.
--
-- This table is also where the reasoning behind tables/fs2rts-sct.tbm lives,
-- because that file cannot carry comments: the SCT parser reads
-- optional_string("#Conditional Hooks") first, which skips whitespace only, and
-- inside the block a '#' line is consumed as a *condition* and then rejected,
-- silently disabling the hook it precedes. Keep this file comment-free and put
-- the notes here.
--
-- $On State End and $On State Start are deliberately not scoped by $State:.
-- gameseq_push_state() increments the stack before game_leave_state(), so a
-- $State: condition there would be compared against stale stack data on every
-- pushed transition, which is exactly the class of bug this table replaces.
local TRANSIENT_GAME_STATES = {
    -- A native menu pop resumes this mission; it is not a terminal transition.
    GS_STATE_GAME_PLAY = true,
    GS_STATE_GAME_PAUSED = true,
    GS_STATE_DEBUG_PAUSED = true,
    GS_STATE_MULTI_PAUSED = true,
    GS_STATE_TRAINING_PAUSED = true,
    GS_STATE_OPTIONS_MENU = true,
    GS_STATE_INGAME_OPTIONS = true,
    GS_STATE_CONTROL_CONFIG = true,
    GS_STATE_HUD_CONFIG = true,
    GS_STATE_GAMEPLAY_HELP = true,
    GS_STATE_HOTKEY_SCREEN = true,
    GS_STATE_MISSION_LOG_SCROLLBACK = true,
    GS_STATE_SHOW_GOALS = true,
    GS_STATE_EVENT_DEBUG = true,
    GS_STATE_DEATH_DIED = true,
    GS_STATE_LAB = true,
    GS_STATE_SCRIPTING_MISSION = true,
}

function RTS:OnStateEnd(oldState, newState)
    local newName = newState and newState.Name or nil
    if newName == nil then return end
    -- Input hooks are scoped to gameplay. A native menu consumes releases, so
    -- retaining held keys or mouse drags would resume a gesture that already ended.
    if oldState and oldState.Name=='GS_STATE_GAME_PLAY' and newName~='GS_STATE_GAME_PLAY' then self:ClearInputGestures() end
    if TRANSIENT_GAME_STATES[newName] then return end
    self:Shutdown()
end

function RTS:Shutdown()
    -- Clear the session flag first. Shutdown is reachable from a hook that can
    -- re-enter (state end fires again on the way out), and an error part-way
    -- through must never leave a half-torn-down session looking live.
    if self.Enabled ~= true then return end
    self.Enabled = false
    self.CombatTelemetryEnabled=false
    self.Paused = false
    self:CloseAITrace()
    self:SetMissionFocusPolicy(false)
    -- On State End can run after mission_close has deleted the player object.
    -- player-not-use-ai clears Player_ai goals and dereferences that object.
    if shipValid(self:GetObserver()) then
        if self.PossessedSignature~=nil then self:ExitPilotMode(nil,false) end
        mn.runSEXP("(player-not-use-ai)")
    end
    self.PossessedSignature=nil
    gr.setCamera(); mn.runSEXP("(reset-time-compression)")
    self.TimeScale=1; self.LastNonZeroTimeScale=1
    ba.setButtonControlMode(NORMAL_BUTTON_CONTROLS); self.ButtonControlMode=nil
    if self.ControlInfo~=nil and self.PreviousAllButtonPolling~=nil then self.ControlInfo.AllButtonPolling=self.PreviousAllButtonPolling end
    self.PreviousAllButtonPolling=nil
    if self.PreviousMouseControl~=nil then io.MouseControlStatus=self.PreviousMouseControl end
    self.PreviousMouseControl=nil
    io.setCursorHidden(false)
    self:ReleaseObjectHandles()
end

-- The shared Lua state outlives a mission. Drop handles and per-hull state at
-- shutdown/reset so caches, gestures and plans cannot reference the previous world.
function RTS:ReleaseObjectHandles()
    self.CrewProjectileBefore=nil
    if self.ClearIntroScene then self:ClearIntroScene() end
    if self.ClearSetupBackdrop then self:ClearSetupBackdrop() end
    if self.StopEnvironment then self:StopEnvironment() end
    for _,ship in ipairs(self:GetShipList()) do
        local withdrawal=self.Withdrawals and self.Withdrawals[ship:getSignature()]
        if withdrawal and shipValid(ship) then ship.Team=withdrawal.originalTeam end
        if (self.PassageTurretOverrides or {})[ship:getSignature()] then
            for i=1,#ship do if ship[i]:isTurret() then ship[i]:targetingOverride(false) end end
        end
    end
    for _,saved in pairs(self.CommandDiscipline or {}) do
        if shipValid(saved.ship) then self:SetShipCommandDiscipline(saved.ship,false) end
    end
    local function wipe(name)
        if self[name]==nil then return end
        pcall(function() self[name]={} end)
    end
    -- Signature-keyed tables holding handles or per-hull state.
    for _,name in ipairs({
        "UserOrders","PolicyApplied","AIOrderState","FleetServices","FleetServiceCooldown","MoveTurretLocks","CommandDiscipline",
        "SurvivalDangerSince","StaticDefenseSignatures","SentryCosts","SentryHullBoosted",
        "SentryNames","SentryHulls","DefenseRateBoosted","MjolnirRangeLocks","SurgedShips",
        "EngageTargets","Selected","ControlGroups","AIStats","AIEconomyFlow","SurvivorTargets",
    -- HUD samples also hold handles and deadlines relative to the mission UI clock.
    "HoverReadout","OrderPing","PilotWeaponCycleReadout",
    }) do wipe(name) end
    -- Pooled waypoint handles: FSO exposes no Lua call to delete a waypoint list,
    -- so these must at least stop being reachable from the mod.
    if self.MoveWaypoints~=nil then pcall(function() self.MoveWaypoints={} end) end
    if self.FreeMoveWaypoints~=nil then pcall(function() self.FreeMoveWaypoints={} end) end
    -- Pending work records can hold ships too.
    for _,name in ipairs({"PendingSentries","PendingStrikes","AIOperations","LogicalWings","WingNameCounters"}) do wipe(name) end
    -- The ship list cache holds live handles.
    pcall(function() self.ShipCache=nil; self.ShipSignatureIndex=nil end)
    -- Cached projections are keyed by signature and are per-frame; drop them so a
    -- stale handle cannot survive into the next mission.
    for _,name in ipairs({"ProjectionX","ProjectionY","ProjectionOwner","ProjectionEpoch"}) do
        if self[name]~=nil then pcall(function() self[name]=nil end) end
    end
    for _,name in ipairs({"StrategicThreatSnapshot","AISpatialGrid","AILocalCache","AISpatialCellSize",
        "AIShipIndex","AIProfileIndex","AITargetedBy","AIStrategicPlanQueue","RTSWings","WingBySignature",
        "PilotPrimaryWeapons","PilotTurretGroups","PilotBatteryCandidates","PilotFlakCandidates","PilotFlakPendingShots","PilotNativeWing","PilotPreviousUserOrder","PilotAIObjective","PilotSuggestedTarget","PilotSuggestedAt","PilotCommOrders","PilotCommWarningUntil","ControlInfo",
        "Camera","FollowCamera","PilotCamera"}) do self[name]=nil end
end

function RTS:OnFrame()
    if not self.Enabled then return end
    self:EnforceCursorState()
    local dt = ba.getRealFrametime()
    local now = mn.getMissionTime()
    self.UIClock = (self.UIClock or 0) + math.max(0, tonumber(dt) or 0)
    self:InvalidateShipList()
    if not self.SetupActive and not self.PostBattleActive then self:ObserveStationBeamHits(now) end
    self:StabilizeDyingStations()
    if self.CinematicActive then
        self:SetRTSInputMode()
        self:DisarmObserverWeapons()
        self:UpdateIntroCinematic(dt)
        return
    end

    if self.SetupActive then self:ProcessRosterModelWarmup() end

    if self.PossessedSignature ~= nil then
        self:UpdatePilotMode(dt)
    elseif self.BattleCamActive then
        self:SetRTSInputMode()
        self:DisarmObserverWeapons()
        self:UpdateBattleCam()
    elseif self.FollowSignature ~= nil then
        self:SetRTSInputMode()
        self:DisarmObserverWeapons()
        local followed = self:FindShipBySignature(self.FollowSignature)
        if not shipValid(followed) then self:ExitFollowMode("Follow target lost") else self:UpdateFollowCamera(followed) end
    else
        gr.setCamera(self.Camera)
        self:SetRTSInputMode()
        if not self.SetupActive then self:UpdateCameraInput(dt) end
        self:DisarmObserverWeapons()
    end

    if self.PostBattleActive or self.ExitMenuActive then return end
    -- The mod's own pause owns the whole simulation. The engine clock is
    -- already stopped by SetPaused, so gating here keeps mission-time driven
    -- systems (economy, queues, AI) from drifting on the frames that still run
    -- for input and HUD while the mission is idle. Escalation rides on mission
    -- time, and SetPaused stops the engine clock, so pausing holds the tier
    -- schedule too without needing a separate counter here.
    if self.Paused then return end
    self:UpdateEconomy(now)
    self:UpdateBuildQueue(now)
    self:UpdateEnemyWaves(now)
    self:UpdateAIProduction(now)
    if not self.SetupActive and self.ScenarioStartTime ~= nil then self:UpdateStations(now) end
    if not self.SetupActive and self.ScenarioStartTime ~= nil then self:UpdateFleetServices(now) end
    self:UpdateMoveFacings()
    self:ReconcileMoveOrders(now)
    self:UpdateAttackFormations(now)
    self:UpdateAIPursuitGoals(now)
    self:UpdateAIStrategicObjectives(now)
    self:UpdateSurvivorCombat(now)
    self:UpdateFleetLife(now)
    self:UpdateTraitorRaids(now)
    self:AuditWorldPositions(now)
    if not self.AftermathActive and not self.SetupActive and self.ScenarioStartTime ~= nil then
        local tier = self:GetCurrentEscalationTier(now)
        if tier > (self.LastEscalationTier or 1) then
            self.LastEscalationTier = tier
            self:ShowAnnouncement("ESCALATION TIER "..tier.." UNLOCKED", 5, nil)
            self:SetStatus("Tier "..tier.." production unlocked for all surviving factions", 5)
        end
    end
    if not self.AftermathActive and not self.SetupActive and not self.BlueEliminated then self:UpdateDefaultPolicy(now) end

    if self.SetupActive then return end
    -- Collect every loss before the single report snapshot. Death callbacks
    -- mark elimination but cannot decide a partially processed frame.
    for _,kind in ipairs(self:GetFactionKeys()) do
        if not shipValid(self:GetFactionCommandShip(kind)) and not self:IsFactionEliminated(kind) then self:EliminateFaction(kind) end
    end
    self:EvaluateFactionVictory()
end

-- Stations are fixed installations: the death roll and its own explosion
-- impulse sent the Shivan station spinning like a fidget spinner, so hold
-- dying stations still until they finish exploding.
--
-- The signature is only a hint. Signatures come from a per-mission free-object
-- pool, so a stale entry surviving a restart can resolve to some unrelated
-- ship, and this runs every frame regardless of setup/post-battle gates.
-- Re-check that the resolved object really is a command station still in its
-- death roll: a live hull held at zero velocity is a permanently dead-in-the-
-- water ship with no HUD indicator to explain it. Anything else is dropped.
function RTS:StabilizeDyingStations()
    if self.DyingStations==nil then return end
    for sig in pairs(self.DyingStations) do
        local ship=self:FindShipBySignature(sig)
        if shipValid(ship) and self:IsCommandStation(ship) and not shipAlive(ship) then
            ship.Physics.RotationalVelocity=vec(0,0,0); ship.Physics.Velocity=vec(0,0,0)
        else
            self.DyingStations[sig]=nil
        end
    end
end

function RTS:ResolveKillRewardShip(killer)
    if not objectValid(killer) then return nil end
    local breed=killer:getBreedName()
    if breed=='Ship' then return killer end
    if breed=='Weapon' then local source=self:GetWeaponCombatSource(killer); return shipValid(source) and source or nil end
    if breed=='Beam' then return shipValid(killer.ParentShip) and killer.ParentShip or nil end
    return nil
end

function RTS:OnShipDeath(ship,killer)
    if not self.Enabled or not shipValid(ship) then return end
    local deadSignature=ship:getSignature()
    self.BountyProcessed=self.BountyProcessed or {}
    if self.BountyProcessed[deadSignature] then return end
    self.BountyProcessed[deadSignature]=true
    if self.RecordUnitFate then self:RecordUnitFate(ship,'LOST','DESTROYED') end
    if self.ClearFleetLifeReferences then self:ClearFleetLifeReferences(ship) end
    if self.FleetServices then self.FleetServices[deadSignature]=nil end
    if self.FleetServiceCooldown then self.FleetServiceCooldown[deadSignature]=nil end
    if self.SurvivalDangerSince then self.SurvivalDangerSince[deadSignature]=nil end
    if self:IsCommandStation(ship) then self.DyingStations=self.DyingStations or {}; self.DyingStations[deadSignature]=true end
    if self.StaticDefenseSignatures then self.StaticDefenseSignatures[deadSignature]=nil end
    local lethalHit=self.AILethalDamageByShip and self.AILethalDamageByShip[deadSignature] or nil
    local kind=self:GetFactionKey(ship)
    -- This also lazily prices classes outside the configured production roster.
    local replacement=self:GetStrategicUnitValue(ship,kind)
    local mapped=self.ShipCostMap and self.ShipCostMap[ship.Class.Name]
    local baseUnitCost=mapped and mapped.cost or 100
    local bounty=0
    local rewardShip=self:ResolveKillRewardShip(killer)
    self:RecordFleetCombatKill(rewardShip,ship)
    local rewardFaction=shipValid(rewardShip) and self:GetFactionKey(rewardShip) or nil
    local hostileKill=rewardFaction and rewardShip:getSignature()~=deadSignature and self:AreEnemies(rewardShip,ship)
    if hostileKill
        and self:IsFactionEnabled(rewardFaction)
        and shipAlive(self:GetFactionCommandShip(rewardFaction))
        and (rewardFaction=='BLUE' or self.AIStates and self.AIStates[rewardFaction]) then
        bounty=math.max(self.Config.Bounties.Minimum or 25,math.floor(baseUnitCost*(self.Config.Bounties.DefaultFractionOfCost or .24)))
    end
    if self.AIStats then
        if kind then local losses=self.AIStats.losses[kind] or {}; self.AIStats.losses[kind]=losses; losses[ship.Class.Name]=(losses[ship.Class.Name] or 0)+1 end
        if hostileKill then
            self.AIStats.kills=self.AIStats.kills or {}
            local kills=self.AIStats.kills[rewardFaction] or {}; self.AIStats.kills[rewardFaction]=kills
            kills[ship.Class.Name]=(kills[ship.Class.Name] or 0)+1
        end
        self:EmitAIEvent("LOSS",{ship=deadSignature,class=ship.Class.Name,faction=kind,
            baseUnitCost=baseUnitCost,replacementCost=replacement,bountyCP=bounty,rewardFaction=rewardFaction,
            objective=self.AIOrderState[deadSignature],lethalHit=lethalHit})
        self.AIObservations[deadSignature]=nil; self.AIStats.hits[deadSignature]=nil
    end
    if hostileKill and self.PossessedSignature==rewardShip:getSignature() then
        local player=ba.getCurrentPlayer()
        if player:isValid() then
            local stats=player.Stats
            stats.MissionTotalKills=(stats.MissionTotalKills or 0)+1
            local classKills=stats:getMissionShipclassKills(ship.Class)
            if classKills>=0 then stats:setMissionShipclassKills(ship.Class,classKills+1) end
        end
    end
    if self.AILethalDamageByShip then self.AILethalDamageByShip[deadSignature]=nil end
    local wingId=self.WingBySignature[deadSignature]
    local wing=wingId and self.RTSWings[wingId]
    if wing then
        for i=#wing.signatures,1,-1 do
            if wing.signatures[i]==deadSignature then table.remove(wing.signatures,i) end
        end
        if #wing.signatures==0 then self.RTSWings[wingId]=nil end
    end
    self.UserOrders[deadSignature]=nil; self.PolicyApplied[deadSignature]=nil; self.PolicyDefend[deadSignature]=nil; self.AIOrderState[deadSignature]=nil; self.WingBySignature[deadSignature]=nil; self:ReleaseMoveWaypoint(deadSignature); self.WorldBoundsWarnings[deadSignature]=nil
    if self.CommandDiscipline then self.CommandDiscipline[deadSignature]=nil end
    -- Any living ship still holding a native ORDER_ATTACK on this signature
    -- keeps a raw object-index reference until its next strategic tick
    -- (up to StrategicOrderInterval seconds away). FSO can reuse a freed
    -- object slot for a different object type in that window; a capital
    -- ship's native ai_cruiser_chase submode dereferencing it as a ship then
    -- hits "En_objp->type == OBJ_SHIP" and crashes. Sever the goal now
    -- instead of waiting for the next tick to notice the target is gone.
    for _,sig in ipairs(sortedNumericKeys(self.AIOrderState)) do
        local state=self.AIOrderState[sig]
        if state and state.targetSignature==deadSignature then
            local attacker=self:FindShipBySignature(sig)
            if shipValid(attacker) then attacker:clearOrders() end
            self.AIOrderState[sig]=nil
        end
    end
    -- Player attack/guard orders on this ship hold the same raw reference, and
    -- otherwise leave the ship goal-less until the next policy refresh.
    self:HandleAttackWingTargetDeath(deadSignature)
    for _,sig in ipairs(sortedNumericKeys(self.UserOrders)) do
        local order=self.UserOrders[sig]
        if (order.kind=="attack" or order.kind=="guard") and order.targetSignature==deadSignature then
            local owner=self:FindShipBySignature(sig)
            self.UserOrders[sig]=nil; self.PolicyApplied[sig]=nil
            if shipValid(owner) then owner:clearOrders(); self:ReturnToDefaultControl(owner) end
        end
    end
    -- Bombers under Engage (player order or ENGAGE policy) attack one picked
    -- target; pick the next one now rather than idling.
    self.EngageTargets[deadSignature]=nil
    for _,sig in ipairs(sortedNumericKeys(self.EngageTargets)) do
        if self.EngageTargets[sig]==deadSignature then
            self.EngageTargets[sig]=nil
            local owner=self:FindShipBySignature(sig); local order=self.UserOrders[sig]
            if shipValid(owner) then
                if order~=nil and order.kind=="engage" then self:EngageShip(owner,0.95)
                elseif order==nil and self.PolicyApplied[sig]=="ENGAGE" then self:ApplyPolicyToShip(owner,true) end
            end
        end
    end
    for group,sigs in pairs(self.ControlGroups or {}) do local live={}; for _,sig in ipairs(sigs) do if sig~=deadSignature and self:FindShipBySignature(sig)~=nil then live[#live+1]=sig end end; self.ControlGroups[group]=live end
    if self.PossessedSignature~=nil and deadSignature==self.PossessedSignature then
        self:BeginPilotEject(ship)
    end
    if bounty>0 and not self.AftermathActive then
        local before=self:GetFactionCP(rewardFaction)
        if rewardFaction=='BLUE' then self.CommandPoints=before+bounty
        else self.AIStates[rewardFaction].cp=before+bounty end
        self:RecordAIEconomyFlow(rewardFaction,"bounty",bounty)
        self:EmitAIEvent("PRODUCTION",{action="BOUNTY",producer="KILL_REWARD",faction=rewardFaction,
            destroyedShip=deadSignature,destroyedClass=ship.Class.Name,baseUnitCost=baseUnitCost,
            killerShip=rewardShip:getSignature(),bountyCP=bounty,cpBefore=before,cpAfter=self:GetFactionCP(rewardFaction)},mn.getMissionTime())
        if rewardFaction=='BLUE' then self:SetStatus("+"..tostring(bounty).." CP - "..ship.Name.." destroyed",2.5) end
    end
    local responsible=hostileKill and rewardFaction or nil
    if self:IsCommandStation(ship) then self:EliminateFaction(self:GetFactionKey(ship),responsible) end
    if self.Withdrawals then self.Withdrawals[deadSignature]=nil end
    for _,area in pairs(self.ExtractionAreas or {}) do area.slots[deadSignature]=nil end
end

function RTS:OnWaypointsDone(ship)
    if self:IsShipWithdrawing(ship) then return end
    if shipValid(ship) and self.FleetServices and self.FleetServices[ship:getSignature()] then return end
    if not self.Enabled or not self:IsFriendly(ship) then return end
    local sig=ship:getSignature(); local order=self.UserOrders[sig]
    if order and order.approaching and (order.kind=="attack" or order.kind=="attack_wing") then
        order.approaching=nil
        self:ReissueUserOrder(ship,order)
        return
    end
    if order~=nil and order.kind=="move" then
        -- Explicit moves hold on arrival until released. Nonmanual waypoint
        -- users retain the existing automatic hand-back behavior below.
        if order.manual==true or (order.facing~=nil and self:IsFiniteVector(order.facing)) then
            -- copyVec(order.facing) unguarded crashed here: the branch is entered
            -- when order.manual==true OR the facing is finite, but a MANUAL
            -- tap-to-move carries no facing at all, so copyVec(nil) indexed a nil
            -- and took down the whole $On Waypoints Done hook - once per completed
            -- manual move, on the player's own input.
            local facing=nil
            if order.facing~=nil and self:IsFiniteVector(order.facing) then facing=copyVec(order.facing) end
            self:SetUserOrder(ship,{kind="hold",facing=facing,heading=order.heading and copyVec(order.heading) or nil,manual=true})
            self:HoldShip(ship,0.95)
            return
        end
        if self.AutoPlayerMode then
            self.UserOrders[sig]=nil; self.PolicyApplied[sig]=nil
            self:ReturnToDefaultControl(ship)
        else
            -- Stay where the player sent it; re-applying the default policy here
            -- (STANDOFF guards the station) flew it straight back to base.
            self:SetUserOrder(ship,{kind="hold"})
            self:HoldShip(ship,0.95)
        end
        return
    end
    if order==nil then
        if self.AutoPlayerMode then self:AssignAIStrategicOrder(ship,"BLUE",true)
        elseif self.GlobalPolicy=="RETREAT" then self:HoldShip(ship,self.Config.Policy.Priority or .65); self.PolicyApplied[sig]="RETREAT" end
    end
end

function RTS:AuditWorldPositions(now)
    if self.SetupActive or self.CinematicActive or self.PostBattleActive then return end
    if now-(self.LastWorldBoundsAudit or -100)<1.0 then return end
    self.LastWorldBoundsAudit=now
    local warningBound=self:GetBattleMapHalfExtent()
    self:EachShip(function(ship)
        if ship.Name~=self.Config.ObserverShip and not self:IsCommandStation(ship) and not self:IsShipWithdrawing(ship) then
            local p=ship.Position
            if self:IsFiniteVector(p) and (math.abs(p.x)>warningBound or math.abs(p.z)>warningBound) then
                local sig=ship:getSignature()
                if not self.WorldBoundsWarnings[sig] then
                    self.WorldBoundsWarnings[sig]=true
                    self:Log(string.format("WORLD-BOUNDS warning: %s at %.0f, %.0f, %.0f",ship.Name,p.x,p.y,p.z))
                end
                local order=self.UserOrders[sig]
                if self:IsFriendly(ship) and order~=nil and order.kind=="move" then
                    -- Recover only RTS-generated move orders; never teleport the ship.
                    local recovery=self:ClampCommandPoint(order.destination or p,self:GetShipFormationRadius(ship)*1.05)
                    if recovery~=nil then
                        order.destination=copyVec(recovery)
                        self:MoveShipTo(ship,recovery,0.98)
                    end
                elseif order==nil and self.PossessedSignature~=sig and not self:IsShipWithdrawing(ship)
                    and not (self.FleetServices and self.FleetServices[sig]) then
                    local kind=self:GetFactionKey(ship)
                    local automatic=kind~=nil and (kind~='BLUE' or self.AutoPlayerMode)
                        and not self:IsFactionEliminated(kind)
                    if automatic then
                        local state=self.AIOrderState and self.AIOrderState[sig]
                        local target=state and self:FindShipBySignature(state.targetSignature)
                        local outsideTarget=shipAlive(target) and (math.abs(target.Position.x)>warningBound or math.abs(target.Position.z)>warningBound)
                        local destination=state and state.destination
                        local outsideDestination=self:IsFiniteVector(destination)
                            and (math.abs(destination.x)>warningBound or math.abs(destination.z)>warningBound)
                        if state==nil or not shipAlive(target) or outsideTarget or outsideDestination then
                            self:AssignAIStrategicOrder(ship,kind,true)
                        end
                    end
                end
            end
        end
    end)
end

function RTS:ShouldOverrideHUD()
    -- RTS mode owns the HUD. Pilot mode deliberately releases the override so
    -- FSO's native fighter HUD/reticle/targeting display is rendered.
    return self.Enabled == true and self.PossessedSignature == nil
end
