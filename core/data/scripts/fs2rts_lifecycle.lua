-- Victory, faction spawn/elimination, warmup, scenario start, frame/death hooks.
local Config = require "fs2rts_config"
local U = require "fs2rts_util"
local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys
local RTS = require "fs2rts_state"
local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

function RTS:ScaleCommandStationsForDuration()
    local duration=self:GetDurationProfile(); if duration==nil then return end; local scale=duration.stationHullScale or 1
    if self.SetupFactionCount>=3 then scale=scale*(duration.threeFactionStationScale or 1) end
    for _,kind in ipairs({"BLUE","RED","GOLD"}) do
        if self:IsFactionEnabled(kind) then
            local station=self:GetFactionCommandShip(kind)
            if shipValid(station) then
                local configuredBase=self.Config.StationBaseHull
                local base=self.StationBaseHull[station.Name] or configuredBase or station.HitpointsMax
                self.StationBaseHull[station.Name]=base
                station.HitpointsMax=base*scale
                station.HitpointsLeft=station.HitpointsMax
            end
        end
    end
end

function RTS:GetLivingFactionKeys()
    local result = {}
    if shipValid(self:GetCarrier()) and not self.BlueEliminated then result[#result+1] = "BLUE" end
    if self:IsFactionEnabled("RED") and shipValid(self:GetEnemyCommand()) and not self.RedEliminated then result[#result+1] = "RED" end
    if self:IsFactionEnabled("GOLD") and shipValid(self:GetThirdCommand()) and not self.GoldEliminated then result[#result+1] = "GOLD" end
    return result
end

-- Snapshot the numbers the after-action report needs. Everything is read from
-- state the sim already tracks, so the report costs nothing to build.
function RTS:BuildBattleSummary()
    local summary={durationSeconds=self:GetScenarioElapsed(),tier=self:GetCurrentEscalationTier(),
        cpRemaining=self.CommandPoints,cpSpent=0,losses=0,kills=0,capitalLosses=0,fleetCap=self:GetFleetCap("BLUE"),factions={}}
    self:EachShip(function(ship)
        if ship.Name==self.Config.ObserverShip then return end
        local kind=self:GetFactionKey(ship)
        if kind~=nil then
            local entry=summary.factions[kind]
            if entry==nil then
                local faction=self.Config.Factions[kind]
                entry={key=kind,label=(faction and faction.name) or kind,eliminated=false,ships=0}
                summary.factions[kind]=entry
            end
            entry.ships=entry.ships+1
        end
    end)
    local ordered={}
    for _,entry in pairs(summary.factions) do
        if entry.key=="BLUE" then ordered[#ordered+1]=entry
        elseif entry.key=="RED" then ordered[#ordered+1]=entry
        elseif entry.key=="GOLD" then ordered[#ordered+1]=entry end
    end
    summary.factions=ordered
    -- Keyed lookup, not an `and`/`or` chain. A chain cannot express three
    -- independent booleans: for kind=="BLUE" with BlueEliminated==false the
    -- first two tests are false, so evaluation falls through to the
    -- unguarded tail and the report claims BLUE is eliminated because
    -- GoldEliminated happens to be true - the exact inverse of the
    -- PostBattleResult that opened the screen. ai_planning carries the same
    -- shape with the correct `or false` tail; this is the drifted copy.
    local eliminatedByKind={BLUE=self.BlueEliminated,RED=self.RedEliminated,GOLD=self.GoldEliminated}
    for _,entry in ipairs(ordered) do entry.eliminated=eliminatedByKind[entry.key]==true end
    local blueLosses=self.AIStats and self.AIStats.losses and self.AIStats.losses["BLUE"]
    if blueLosses~=nil then
        for className,count in pairs(blueLosses) do
            summary.losses=summary.losses+(count or 0)
            if className:find("Sathanas") or className:find("Colossus") or className:find("Lucifer")
                or className:find("Deimos") or className:find("Sobek") or className:find("Hecate")
                or className:find("Orion") or className:find("Hatshepsut") or className:find("Ravana")
                or className:find("Arcadia") then
                summary.capitalLosses=summary.capitalLosses+(count or 0)
            end
        end
    end
    local enemyLosses=self.AIStats and self.AIStats.losses or {}
    for _,kind in ipairs({"RED","GOLD"}) do
        local bucket=enemyLosses[kind]
        if bucket~=nil then for _,count in pairs(bucket) do summary.kills=summary.kills+(count or 0) end end
    end
    local flow=self.AIEconomyFlow and self.AIEconomyFlow["BLUE"]
    if flow~=nil then summary.cpSpent=(flow.productionSpend or 0)+(flow.refund and -flow.refund or 0) end
    return summary
end

-- Attrition score used when the time box expires with stations still standing.
-- Every input already exists: AIStats.losses counts hulls destroyed per faction
-- and per class, and Config.Bounties / ShipCostMap price them. The point is
-- that a match must be LOSABLE: with victory firing only on elimination, a
-- three-way free-for-all needs two station kills at a measured rate of roughly
-- one per 3,000 s, so it was mathematically unable to resolve inside its own
-- advertised length. That is why 8 of 8 batches ended time_limit, and why no
-- amount of beam-cap or hull tuning changed the outcome.
--
-- stationHullFraction is the deepest bite any single hostile took out of one
-- station, so a faction that nearly cracked a base is rewarded for it without
-- the match having to run long enough to finish the job.
function RTS:GetAttritionScore(kind)
    local losses=self.AIStats and self.AIStats.losses or {}
    local bounties=(self.Config and self.Config.Bounties) or {}
    local shipCost=self.ShipCostMap or {}
    local function valueOf(className)
        local price=shipCost[className]
        if price==nil then price=bounties[className] end
        if type(price)~="number" then price=0 end
        return price
    end
    local killed, lost=0,0
    for _,bucket in ipairs(losses) do
        for className,count in pairs(bucket or {}) do
            local value=valueOf(className)*(count or 0)
            if bucket==losses[kind] then killed=killed+value else lost=lost+value end
        end
    end
    -- Credit for station damage actually dealt, taken from the base-damage
    -- telemetry the mod already records per attacker faction. Normalised against
    -- the leading faction's total so the term is bounded to [0,1] without
    -- hardcoding a hull value that the beam cap keeps moving.
    local totals={}
    local byFaction=(self.BaseDamageTelemetry and self.BaseDamageTelemetry.totalByFaction) or {}
    for _,kind in ipairs({"BLUE","RED","GOLD"}) do
        local sum=0
        for _,row in ipairs(byFaction[kind] or {}) do sum=sum+(row.hullDamage or 0) end
        totals[kind]=sum
    end
    local peak=math.max(totals["BLUE"] or 0,totals["RED"] or 0,totals["GOLD"] or 0)
    local stationFraction=peak>0 and ((totals[kind] or 0)/peak) or 0
    local weight=(self.Config and self.Config.Victory and self.Config.Victory.StationCreditWeight) or 0.25
    return killed-lost+weight*stationFraction,killed,lost,stationFraction
end

function RTS:EvaluateFactionVictory()
    if self.SetupActive then return end
    if self.BlueEliminated then
        self.GameStatus="DEFEAT"
        if not self.PostBattleActive then self.BattleSummary=self:BuildBattleSummary(); self:OpenPostBattle("BLUE STATION DESTROYED // BLUE FLEET DEFEATED") end
        return
    end
    if self.BattleVictor~=nil then return end
    local living=self:GetLivingFactionKeys()
    if #living==1 and living[1]=="BLUE" then
        self.BattleVictor="BLUE"; self.GameStatus="VICTORY"; self.StatusMessage="GTVA // BLUE FLEET IS VICTORIOUS"; self.StatusUntil=math.huge
        self:ShowAnnouncement("BLUE FLEET VICTORIOUS",8,"BLUE"); self.BattleSummary=self:BuildBattleSummary(); self:OpenPostBattle("ALL OPPOSING STATIONS DESTROYED // BLUE FLEET VICTORIOUS")
    elseif #living==0 then
        self.BattleVictor="NONE"; self.GameStatus="DEFEAT"; self.StatusMessage="NO FACTION SURVIVED"; self.StatusUntil=math.huge
        self:ShowAnnouncement("NO FACTION SURVIVED",8,nil); self.BattleSummary=self:BuildBattleSummary(); self:OpenPostBattle("MUTUAL DESTRUCTION // NO FACTION SURVIVED")
        return
    end
    -- Time box LAST, so the defeat and last-standing branches above always win
    -- and a match that ends on a kill is never re-decided by the clock.
    local duration=self:GetDurationProfile()
    local box=(duration and duration.targetSeconds) or 1800
    if box<=0 or self:GetScenarioElapsed()<box then return end
    if (self.Config and self.Config.Victory and self.Config.Victory.TimeBoxEnabled)==false then return end
    self:ResolveTimeBoxVictory()
end

function RTS:ResolveTimeBoxVictory()
    local scored={}
    for _,kind in ipairs({"BLUE","RED","GOLD"}) do
        scored[kind]=self:GetAttritionScore(kind)
    end
    local best=scored["BLUE"]; local bestKind="BLUE"
    for _,kind in ipairs({"RED","GOLD"}) do
        if scored[kind][1]>best[1] then best, bestKind=scored[kind], kind end
    end
    self.AttritionScores=scored
    self.BattleSummary=self:BuildBattleSummary()
    if self.BattleSummary~=nil then self.BattleSummary.decidedBy="TIME BOX // ATTRITION"; self.BattleSummary.attrition=scored end
    -- A draw is a real outcome, not a failure to decide. Before this, a
    -- non-VICTORY status rendered as DEFEAT everywhere in the HUD, so a drawn
    -- match would have been reported to the player as a loss.
    if bestKind=="BLUE" then
        self.BattleVictor="BLUE"; self.GameStatus="VICTORY"; self.StatusMessage="TIME BOX // BLUE FLEET HOLDS THE FIELD"; self.StatusUntil=math.huge
        self:ShowAnnouncement("BLUE FLEET VICTORIOUS",8,"BLUE")
        self:OpenPostBattle("TIME BOX REACHED // BLUE FLEET WINS ON ATTRITION")
    else
        self.BattleVictor=bestKind; self.GameStatus="DRAW"; self.StatusMessage="TIME BOX // BLUE FLEET OUTMATCHED"; self.StatusUntil=math.huge
        self:ShowAnnouncement("STALEMATE",8,nil)
        self:OpenPostBattle("TIME BOX REACHED // "..bestKind.." OUTMATCHED THE BLUE FLEET")
    end
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

function RTS:SpawnGoldFaction()
    if not self:IsFactionEnabled("GOLD") then return end
    local stationClassName=(self.Config.StationClasses and self.Config.StationClasses.GOLD) or self.Config.StationClass
    local stationClass=tb.ShipClasses[stationClassName]; local team=mn.Teams[self.Config.ThirdTeam]
    if not stationClass or not stationClass:isValid() or not team or not team:isValid() then return end
    local p=self:GetScenarioBasePosition("GOLD"); local towardCenter=vec(-p.x,-p.y,-p.z); local orient=towardCenter:getOrientation()
    local station=mn.createShip(self.Config.ThirdCommandShip,stationClass,orient,vec(p.x,p.y,p.z),team,true)
    self:InvalidateShipList()
    if not shipValid(station) then return end
    -- Command installations are part of the battlefield from frame zero.  They are
    -- created directly at their configured position and must never perform a ship
    -- arrival/warp effect. Blue/Red get "immobile" from the mission file's own
    -- +Flags: (they're pre-placed there); Gold only exists via this runtime
    -- mn.createShip call, so it needs the same object flag set here instead.
    station:setFlag(true,"immobile")
    self:EnableFullArsenal(station)
end

function RTS:SpawnSentryDefenses()
    self.StaticDefenseSignatures={}

    local spawned=0
    for _,kind in ipairs({"BLUE","RED","GOLD"}) do
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


function RTS:EliminateFaction(kind)
    local teamKey = nil
    if kind == "BLUE" then
        if self.BlueEliminated then return end
        self.BlueEliminated = true
        teamKey = self.Config.FriendlyTeam
    elseif kind == "RED" then
        if self.RedEliminated then return end
        self.RedEliminated = true
        teamKey = self.Config.HostileTeam
    elseif kind == "GOLD" then
        if self.GoldEliminated then return end
        self.GoldEliminated = true
        teamKey = self.Config.ThirdTeam
    else return end

    local def = self:GetFactionDefinition(kind)
    local label = def and def.name or kind
    if self.CombatTelemetryEnabled then self:EmitOutcomeCause(kind, mn.getMissionTime()) end
    self:ShowAnnouncement(label .. " HAS BEEN DEFEATED", 7, kind)
    self:SetStatus(label .. " defeated - surviving units are withdrawing", 6)
    if self.AIStates[kind] then
        local queued=self.AIStates[kind].queue
        if queued then
            self:EmitAIEvent("PRODUCTION",{action="QUEUE_CANCELLED",producer="AI",faction=kind,
                class=queued.entry and queued.entry.class or "UNKNOWN",count=queued.count or 1,
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
                class=option.class or "UNKNOWN",count=option.count or 1,cost=cost,refundedCP=back,
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

    self:EachShip(function(unit)
        if shipValid(unit) and unit.Name ~= self.Config.ObserverShip and teamName(unit) == teamKey then
            local isStation = unit.Name == self.Config.CarrierShip or unit.Name == self.Config.EnemyCommandShip or unit.Name == self.Config.ThirdCommandShip
            if not isStation and not self:IsStaticDefense(unit) then unit:clearOrders(); unit:giveOrder(ORDER_DEPART, nil, nil, 1.5) end
        end
    end)
    self:EvaluateFactionVictory()
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
    self:FinishRosterModelWarmup()
    local economy=self.Config.Setup.Economies[self.SetupEconomyIndex]; local duration=self:GetDurationProfile(); self.CommandPoints=economy.startCP; self.ActiveIncomePerSecond=economy.income*(duration.playerIncomeScale or 1)
    self.AutoPlayerMode=self.SetupAutoMode==true
    self:ApplyConfiguredBaseSpacing()
    self.SetupActive=false; self.GameStatus="ACTIVE"; self.RedEliminated=not self:IsFactionEnabled("RED"); self.GoldEliminated=not self:IsFactionEnabled("GOLD"); self.BlueEliminated=false; self.BattleVictor=nil; self.PostBattleActive=false; self.PostBattleResult=nil
    self.ScenarioStartTime=mn.getMissionTime(); self.LastIncomeTime=self.ScenarioStartTime; self.StatusUntil=self:UINow()+6; self.StatusMessage=self.AutoPlayerMode and "ESCALATION STARTED // BLUE AUTO MODE" or "ESCALATION STARTED"
    self.CombatTelemetryEnabled=true; self:RegisterBaseDamageTelemetry(); self:RegisterCombatDamageTelemetry(); self:RegisterStationBeamHitHook(); self:StartAITrace(); self:SetMissionFocusPolicy(true)
    if not self:IsFactionEnabled("RED") then self:DisableFactionShips("RED") end
    self:SpawnGoldFaction(); self:ScaleCommandStationsForDuration(); self:CaptureBaseHullBaseline()
    self:CreateOptionalAsteroidField()
    self:ResetStationState()
    if self.SetupSentries then self:SpawnSentryDefenses() end
    self:InitializeAIStates(self.ScenarioStartTime); self:InitializeUnitOrders(); self:SetTimeScale(1)
    self.BattleSummary=nil; self.MusicMuted=false; self:SetMusicMuted(false,true)
    self:ShowAnnouncement("TIER 1 // ESCALATION BEGINS",4,"BLUE")
end

function RTS:CycleSetupValue(kind,delta)
    if kind=="difficulty" then local max=#self.Config.Setup.Difficulties; self.SetupDifficultyIndex=((self.SetupDifficultyIndex-1+delta)%max)+1
    elseif kind=="economy" then local max=#self.Config.Setup.Economies; self.SetupEconomyIndex=((self.SetupEconomyIndex-1+delta)%max)+1
    elseif kind=="duration" then local max=#self.Config.Setup.Durations; self.SetupDurationIndex=((self.SetupDurationIndex-1+delta)%max)+1
    elseif kind=="distance" then local max=#(self.Config.Setup.BaseDistances or {}); if max>0 then self.SetupBaseDistanceIndex=((self.SetupBaseDistanceIndex-1+delta)%max)+1 end end
end

function RTS:HandleSetupClick(x,y)
    for id,rect in pairs(self.SetupButtonRects or {}) do
        if self:PointInside(rect,x,y) then
            if id=="difficulty" then self:CycleSetupValue("difficulty",1)
            elseif id=="economy" then self:CycleSetupValue("economy",1)
            elseif id=="duration" then self:CycleSetupValue("duration",1)
            elseif id=="distance" then self:CycleSetupValue("distance",1)
            elseif id=="red" then self.SetupOpponents.RED=not self.SetupOpponents.RED; self:UpdateFactionCount()
            elseif id=="gold" then self.SetupOpponents.GOLD=not self.SetupOpponents.GOLD; self:UpdateFactionCount()
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
    self:DisarmObserverWeapons()
    self:StartIntroCinematic()
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
    if TRANSIENT_GAME_STATES[newName] then return end
    self:Shutdown()
end

function RTS:Shutdown()
    -- Clear the session flag first. Shutdown is reachable from a hook that can
    -- re-enter (state end fires again on the way out), and an error part-way
    -- through must never leave a half-torn-down session looking live.
    if self.Enabled ~= true then return end
    self.Enabled = false
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

-- Drop every object handle the mod is holding, at mission end.
--
-- FSO never tears the scripting state down between missions: code\scripting\lua.cpp
-- calls luaL_openlibs at startup and has NO lua_close anywhere, and the global
-- hook table (code\scripting\global_hooks.cpp) exposes no mission-cleanup hook
-- either. So the same lua_State - and therefore the same table registry - lives
-- across every mission in a session.
--
-- The mod keys many tables by ship signature and some hold the ship itself
-- (UserOrders, FleetServices, AIOrderState, PolicyApplied, SentryCosts,
-- StaticDefenseSignatures, SurgedShips, MoveWaypoints, and the pooled
-- FreeMoveWaypoints). FSO recycles object signatures, so on the next mission a
-- freed hull can be handed the same signature - and anything still reachable
-- from Lua is a handle into memory the engine no longer owns. Touching one is a
-- use-after-free, which is what a hard crash at teardown with no Lua error and no
-- console output looks like.
--
-- Every step is individually guarded: this runs at shutdown, where an exception
-- is caught and only logged, so a raise here would abort the remaining steps and
-- leave exactly the state we are trying to clear.
function RTS:ReleaseObjectHandles()
    local function wipe(name)
        if self[name]==nil then return end
        pcall(function() self[name]={} end)
    end
    -- Signature-keyed tables holding handles or per-hull state.
    for _,name in ipairs({
        "UserOrders","PolicyApplied","AIOrderState","FleetServices","FleetServiceCooldown",
        "SurvivalDangerSince","StaticDefenseSignatures","SentryCosts","SentryHullBoosted",
        "SentryNames","SentryHulls","DefenseRateBoosted","MjolnirRangeLocks","SurgedShips",
        "EngageTargets","Selected","ControlGroups","AIStats","AIEconomyFlow",
    -- Two HUD-side tables were missing here and hold live object handles, not
    -- just data. HoverReadout is read by fs2rts_ui_text.lua:389 and holds
    -- `ship`/`target`; OrderPing holds signatures plus a vector and was
    -- previously cleared only if the HUD happened to draw that branch
    -- (fs2rts_hud.lua:941). Neither was reachable from ResetState, so a mission
    -- restart inside the 2 s ping window left OrderPing alive against a
    -- UIClock reset to 0: `left = untilTime - 0` stayed positive, and
    -- `pulse = 4 + (2-left)*8` went strongly negative, reaching gr.drawCircle
    -- with a negative radius every frame. ProjectionAmbient was in this list
    -- and exists nowhere in the mod; the list had drifted from the code.
    "HoverReadout","OrderPing",
    }) do wipe(name) end
    -- Pooled waypoint handles: FSO exposes no Lua call to delete a waypoint list,
    -- so these must at least stop being reachable from the mod.
    if self.MoveWaypoints~=nil then pcall(function() self.MoveWaypoints={} end) end
    if self.FreeMoveWaypoints~=nil then pcall(function() self.FreeMoveWaypoints={} end) end
    -- Pending work records can hold ships too.
    for _,name in ipairs({"PendingSentries","PendingStrikes","AIOperations","LogicalWings","WingNameCounters"}) do wipe(name) end
    -- The ship list cache holds live handles.
    pcall(function() self.ShipCache=nil end)
    -- Cached projections are keyed by signature and are per-frame; drop them so a
    -- stale handle cannot survive into the next mission.
    for _,name in ipairs({"ProjectionX","ProjectionY","ProjectionOwner","ProjectionEpoch"}) do
        if self[name]~=nil then pcall(function() self[name]=nil end) end
    end
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

    if self.PostBattleActive then return end
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
    self:UpdateAIStrategicObjectives(now)
    self:AuditWorldPositions(now)
    if not self.SetupActive and self.ScenarioStartTime ~= nil then
        local tier = self:GetCurrentEscalationTier(now)
        if tier > (self.LastEscalationTier or 1) then
            self.LastEscalationTier = tier
            self:ShowAnnouncement("ESCALATION TIER "..tier.." UNLOCKED", 5, nil)
            self:SetStatus("Tier "..tier.." production unlocked for all surviving factions", 5)
        end
    end
    if not self.SetupActive and not self.BlueEliminated then self:UpdateDefaultPolicy(now) end

    if self.SetupActive or self.BattleVictor ~= nil then return end
    -- BLUE is checked LAST. EliminateFaction ends with EvaluateFactionVictory,
    -- which snapshots the after-action report, and that snapshot is final: once
    -- the first loss of the frame has opened the post-battle screen,
    -- BattleVictor is set and the remaining stations are never recorded. In a
    -- mutual kill that reported the opponent as SURVIVING on the screen while
    -- the result line above it said the battle was over.
    if self:IsFactionEnabled("RED") and not shipValid(self:GetEnemyCommand()) and not self.RedEliminated then self:EliminateFaction("RED") end
    if self:IsFactionEnabled("GOLD") and not shipValid(self:GetThirdCommand()) and not self.GoldEliminated then self:EliminateFaction("GOLD") end
    if not shipValid(self:GetCarrier()) and not self.BlueEliminated then self:EliminateFaction("BLUE") end
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
    if breed=='Weapon' then return shipValid(killer.Parent) and killer.Parent or nil end
    if breed=='Beam' then return shipValid(killer.ParentShip) and killer.ParentShip or nil end
    return nil
end

function RTS:OnShipDeath(ship,killer)
    if not self.Enabled or not shipValid(ship) then return end
    local deadSignature=ship:getSignature()
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
    local rewardFaction=shipValid(rewardShip) and self:GetFactionKey(rewardShip) or nil
    self.BountyProcessed=self.BountyProcessed or {}
    local firstDeath=not self.BountyProcessed[deadSignature]
    self.BountyProcessed[deadSignature]=true
    if firstDeath and rewardFaction and rewardShip:getSignature()~=deadSignature
        and self:AreEnemies(rewardShip,ship) and self:IsFactionEnabled(rewardFaction)
        and shipAlive(self:GetFactionCommandShip(rewardFaction))
        and (rewardFaction=='BLUE' or self.AIStates and self.AIStates[rewardFaction]) then
        bounty=math.max(self.Config.Bounties.Minimum or 25,math.floor(baseUnitCost*(self.Config.Bounties.DefaultFractionOfCost or .24)))
    end
    if self.AIStats then
        if kind then local losses=self.AIStats.losses[kind] or {}; self.AIStats.losses[kind]=losses; losses[ship.Class.Name]=(losses[ship.Class.Name] or 0)+1 end
        self:EmitAIEvent("LOSS",{ship=deadSignature,class=ship.Class.Name,faction=kind,
            baseUnitCost=baseUnitCost,replacementCost=replacement,bountyCP=bounty,rewardFaction=rewardFaction,
            objective=self.AIOrderState[deadSignature],lethalHit=lethalHit})
        self.AIObservations[deadSignature]=nil; self.AIStats.hits[deadSignature]=nil
    end
    if self.AILethalDamageByShip then self.AILethalDamageByShip[deadSignature]=nil end
    self.UserOrders[deadSignature]=nil; self.PolicyApplied[deadSignature]=nil; self.PolicyDefend[deadSignature]=nil; self.AIOrderState[deadSignature]=nil; self.WingBySignature[deadSignature]=nil; self:ReleaseMoveWaypoint(deadSignature); self.WorldBoundsWarnings[deadSignature]=nil
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
    if bounty>0 then
        local before=self:GetFactionCP(rewardFaction)
        if rewardFaction=='BLUE' then self.CommandPoints=before+bounty
        else self.AIStates[rewardFaction].cp=before+bounty end
        self:RecordAIEconomyFlow(rewardFaction,"bounty",bounty)
        self:EmitAIEvent("PRODUCTION",{action="BOUNTY",producer="KILL_REWARD",faction=rewardFaction,
            destroyedShip=deadSignature,destroyedClass=ship.Class.Name,baseUnitCost=baseUnitCost,
            killerShip=rewardShip:getSignature(),bountyCP=bounty,cpBefore=before,cpAfter=self:GetFactionCP(rewardFaction)},mn.getMissionTime())
        if rewardFaction=='BLUE' then self:SetStatus("+"..tostring(bounty).." CP - "..ship.Name.." destroyed",2.5) end
    end
    if ship.Name==self.Config.CarrierShip then self:EliminateFaction("BLUE")
    elseif ship.Name==self.Config.EnemyCommandShip then self:EliminateFaction("RED")
    elseif ship.Name==self.Config.ThirdCommandShip then self:EliminateFaction("GOLD") end
end

function RTS:OnWaypointsDone(ship)
    if shipValid(ship) and self.FleetServices and self.FleetServices[ship:getSignature()] then return end
    if not self.Enabled or not self:IsFriendly(ship) then return end
    local sig=ship:getSignature(); local order=self.UserOrders[sig]
    if order~=nil and order.kind=="move" then
        -- A right-drag move carries a facing point, which is a directional
        -- command: the player is asking the hull to travel there AND arrive
        -- pointing a specific way. OnWaypointsDone used to collapse both cases
        -- into one "move finished" branch, so a drag-move silently became a
        -- plain hold and then fell back to the default policy, handing the ship
        -- straight back to the AI the moment it stopped moving. Keep manual
        -- control for the facing case: hold position, keep the commanded
        -- heading, and stay out of the AI's pool until the player says
        -- otherwise. A tap-to-move has no facing and keeps the old behaviour,
        -- which is what makes tap correct today.
        if order.manual==true or (order.facing~=nil and self:IsFiniteVector(order.facing)) then
            -- copyVec(order.facing) unguarded crashed here: the branch is entered
            -- when order.manual==true OR the facing is finite, but a MANUAL
            -- tap-to-move carries no facing at all, so copyVec(nil) indexed a nil
            -- and took down the whole $On Waypoints Done hook - once per completed
            -- manual move, on the player's own input.
            local facing=nil
            if order.facing~=nil and self:IsFiniteVector(order.facing) then facing=copyVec(order.facing) end
            self:SetUserOrder(ship,{kind="hold",facing=facing,manual=true})
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
    local warningBound=self:GetCommandArenaHalfExtent()*(self.Config.Formation.WorldWarningMultiplier or 1.60)
    self:EachShip(function(ship)
        if ship.Name~=self.Config.ObserverShip and not self:IsCommandStation(ship) then
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
