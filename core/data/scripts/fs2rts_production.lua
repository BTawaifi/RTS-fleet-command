-- Player production, economy, enemy waves, setup hold.
local Config = require "fs2rts_config"
local U = require "fs2rts_util"
local sortedNumericKeys = U.sortedNumericKeys
local RTS = require "fs2rts_state"
local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

function RTS:GetSafeShipName(name)
    -- Upstream ship_create copies into NAME_LENGTH=32, including the null byte.
    -- Keep safe names; a unique suffix prevents truncation merging late fleets.
    if #name<=31 and not shipValid(mn.Ships[name]) then return name end
    local candidate
    repeat
        self.GeneratedShipNameSerial=(self.GeneratedShipNameSerial or 0)+1
        local suffix="~"..string.format("%x",self.GeneratedShipNameSerial)
        candidate=name:sub(1,31-#suffix)..suffix
    until not shipValid(mn.Ships[candidate])
    return candidate
end

-- allowModelLoad is false for callers that must not page a POF. The death path
-- uses it: EstimateShipCost otherwise force-loads the model synchronously on
-- the frame a ship explodes, and an unloadable model used to raise an error
-- that silently aborted the rest of the $On Ship Death handler.
function RTS:EstimateShipCost(class, allowModelLoad)
    if class==nil or not class:isValid() then return nil end
    local f=self.Config.CostFormula; local hull=math.max(0,class.HitpointsMax or 0); local shields=math.max(0,class.ShieldHitpointsMax or 0)
    -- Costing an unloaded POF silently priced capital hulls at radius 1.
    -- Warmup covers the roster; this also handles other callers/classes.
    if allowModelLoad==false then return nil end
    if class.isModelLoaded and not class:isModelLoaded() then
        if not class:isModelLoaded(true) then
            -- A class that cannot page its POF is dropped from ShipCostMap, and
            -- from BuildCatalog with it, so the unit silently stops existing for
            -- both the player and the AI. Say which class and why.
            self:Log("COST ESTIMATE FAILED: model will not load for "..tostring(class.Name))
            return nil
        end
    end
    local radius=1; if class.Model~=nil then radius=math.max(1,class.Model.Radius or 1) end
    local speed=math.max(0,math.abs(class.VelocityMax.z or 0))
    local cost=f.Base+math.sqrt(math.max(1,hull+shields))*f.HullShieldSqrt+radius*f.Radius+speed*f.ForwardSpeed
    if radius>=f.HugeRadius then cost=cost*f.HugeMultiplier elseif radius>=f.LargeRadius then cost=cost*f.LargeMultiplier end
    local role=self.ShipCostRoleMap and self.ShipCostRoleMap[class.Name]
    local roleMultiplier=role and f.RoleMultipliers and f.RoleMultipliers[role] or 1.0
    local classMultiplier=f.ClassMultipliers and f.ClassMultipliers[class.Name] or 1.0
    cost=cost*roleMultiplier*classMultiplier*(f.GlobalMultiplier or 1)
    local round=f.CostRoundTo or 25; cost=math.max(f.MinimumCost or 50,math.floor((cost+round*0.5)/round)*round)
    local seconds=clamp(cost*(f.BuildSecondsPerCP or 0.025),f.MinBuildSeconds or 6,f.MaxBuildSeconds or 180)
    return {cost=cost,time=seconds,radius=radius,hull=hull,shields=shields,speed=speed}
end

function RTS:BuildShipCostMap()
    self.ShipCostMap = {}
    self.ShipCostRoleMap = {}
    local function registerRoles(entries)
        for _,entry in ipairs(entries or {}) do
            if type(entry.class)=="string" and type(entry.role)=="string" then
                self.ShipCostRoleMap[entry.class]=entry.role
            end
        end
    end
    registerRoles(self.Config.ProductionClasses)
    local ai=self.Config.AI or {}
    registerRoles(ai.BlueRoster); registerRoles(ai.RedRoster); registerRoles(ai.GoldRoster)
    local wanted={}
    for name in pairs(self.ShipCostRoleMap) do wanted[name]=true end
    for _,entries in pairs(self.Config.Station.Sentries.Classes) do for _,entry in ipairs(entries) do wanted[entry.class]=true end end
    for _,name in ipairs(sortedNumericKeys(wanted)) do
        local class = tb.ShipClasses[name]
        if class ~= nil and class:isValid() and class.Name ~= "" then
            local estimate = self:EstimateShipCost(class)
            if estimate ~= nil then self.ShipCostMap[class.Name] = estimate end
        end
    end
end

-- Prime the cost map's ROLE index and collect the roster classes that still need
-- paging, WITHOUT loading anything. BuildShipCostMap used to run the whole roster
-- through EstimateShipCost at mission start, and EstimateShipCost force-loads the
-- POF - 63 synchronous model_load() calls inside a single frame. That was the one
-- hard hitch in the startup path, and it made the "Preparing fleet models" bar
-- that ran afterwards meaningless: every class was already resident, so the
-- warmup loaded nothing and merely counted up to 63.
--
-- LoadRosterModelStep now does the loading AND the pricing, one class per frame,
-- so the progress bar measures real work and no single frame pays for 63 models.
function RTS:PrimeRosterCostMap()
    self.ShipCostMap = self.ShipCostMap or {}
    self.ShipCostRoleMap = {}
    local function registerRoles(entries)
        for _,entry in ipairs(entries or {}) do
            if type(entry.class)=="string" and type(entry.role)=="string" then
                self.ShipCostRoleMap[entry.class]=entry.role
            end
        end
    end
    registerRoles(self.Config.ProductionClasses)
    local ai=self.Config.AI or {}
    registerRoles(ai.BlueRoster); registerRoles(ai.RedRoster); registerRoles(ai.GoldRoster)
    local wanted={}
    for name in pairs(self.ShipCostRoleMap) do wanted[name]=true end
    for _,entries in pairs(self.Config.Station.Sentries.Classes or {}) do
        for _,entry in ipairs(entries or {}) do if type(entry.class)=="string" then wanted[entry.class]=true end end
    end
    self.RosterPending=sortedNumericKeys(wanted)
    return self.RosterPending
end

-- Page one roster model and price it. Returns false when the queue is exhausted.
-- A class whose POF cannot be paged is left out of ShipCostMap (so it is excluded
-- from BuildCatalog and the AI roster) and is logged by name, exactly as the
-- synchronous path did.
function RTS:LoadRosterModelStep()
    local pending=self.RosterPending
    if pending==nil or #pending==0 then return false end
    local name=table.remove(pending,1)
    local class=tb.ShipClasses[name]
    if class==nil or not class:isValid() or class.Name=="" then return true end
    -- isModelLoaded(true) is the actual page-in; EstimateShipCost then sees the
    -- model resident and never forces a second load.
    local ok,res=pcall(function() return class:isModelLoaded(true) end)
    if not ok or res~=true then
        self:Log("COST ESTIMATE FAILED: model will not load for "..tostring(name))
        return true
    end
    local estimate=self:EstimateShipCost(class)
    if estimate~=nil then self.ShipCostMap[name]=estimate end
    return true
end

function RTS:RosterPendingCount()
    return self.RosterPending and #self.RosterPending or 0
end

function RTS:BuildProductionCatalog()
    self.BuildCatalog={}
    for _,configured in ipairs(self:GetAIRoster("BLUE")) do
        local class=tb.ShipClasses[configured.class]; local base=self.ShipCostMap[configured.class]
        if class and class:isValid() and base then
            local count=configured.count or ((configured.role=="fighter" or configured.role=="bomber") and (self.Config.Economy.StrikeWingSize or 4) or 1)
            local estimate=self:GetPurchaseEstimate(configured.class,configured.tier or 1,count)
            self.BuildCatalog[#self.BuildCatalog+1]={key=configured.key,label=configured.label or configured.class,class=configured.class,cost=configured.cost or estimate.cost,time=configured.time or estimate.time,tier=configured.tier or 1,role=configured.role or "combat",count=count}
        end
    end
    table.sort(self.BuildCatalog,function(a,b) if a.tier~=b.tier then return a.tier<b.tier end; if a.cost~=b.cost then return a.cost<b.cost end; return a.label<b.label end)
    self.BuildPage=1
end

function RTS:QueueBuildOption(option)
    if not self.Enabled or self.SetupActive or self.AftermathActive or self.GameStatus~="ACTIVE" or option==nil then return end
    local now=mn.getMissionTime()
    local function reject(reason)
        self:EmitAIEvent("PRODUCTION",{action="QUEUE_REJECTED",producer="PLAYER",faction="BLUE",
            class=option.class or "UNKNOWN",role=option.role,tier=option.tier or 1,count=option.count or 1,
            cost=option.cost or 0,commandPoints=self.CommandPoints,reason=reason},now)
    end
    local carrier=self:GetCarrier(); if self.BlueEliminated or not shipAlive(carrier) then self:SetStatus("Cannot build: your station is destroyed",3); reject("BASE_DESTROYED"); return end
    if not self:IsBuildOptionUnlocked(option) then self:SetStatus("Tier "..option.tier.." locked for "..self:FormatTime(self:GetTierUnlockRemaining(option.tier)),2.5); reject("TIER_LOCKED"); return end
    local count=option.count or 1
    if self:CountCommittedCombatants("BLUE")+count>self:GetFleetCap("BLUE") then self:SetStatus("Fleet cap reached",2); reject("FLEET_CAP"); return end
    if self.CommandPoints<option.cost then self:SetStatus("Insufficient command points",2); reject("INSUFFICIENT_CP"); return end
    local before=self.CommandPoints
    self.CommandPoints=self.CommandPoints-option.cost
    self:RecordAIEconomyFlow("BLUE","productionSpend",option.cost)
    local jobId=self:NextProductionJobId()
    self.BuildQueue[#self.BuildQueue+1]={id=jobId,option=option,started=false,startTime=0,finishTime=0,queuedAt=now}
    self:EmitAIEvent("PRODUCTION",{action="QUEUE_ACCEPTED",producer="PLAYER",faction="BLUE",
        jobId=jobId,class=option.class,role=option.role,tier=option.tier,count=count,cost=option.cost,
        buildSeconds=option.time,cpBefore=before,cpAfter=self.CommandPoints,queuedAt=now},now)
    self:SetStatus("Queued "..(count>1 and (count.."-ship wing of ") or "")..option.label,2)
end

function RTS:NextProductionJobId()
    self.ProductionJobSerial=(self.ProductionJobSerial or 0)+1
    return self.ProductionJobSerial
end

function RTS:SpawnFriendly(option, spawned)
    local carrier=self:GetCarrier(); if not shipAlive(carrier) then return false,spawned end
    local class=tb.ShipClasses[option.class]; if class==nil or not class:isValid() then self:Log("Invalid build class: "..option.class); return false end
    local count=option.count or 1; spawned=spawned or {}; local failed=false; local wingLabel=count>1 and self:GetNextWingCallsign("BLUE") or nil
    self.BuildBatchSerial=(self.BuildBatchSerial or 0)+1; local batch=self.BuildBatchSerial
    for i=1,count do
        self.BuildSerial=self.BuildSerial+1; local pos,orient=self:GetSpawnFrame(carrier,class,i,count,batch); local name=self:GetSafeShipName(wingLabel and (wingLabel.." "..tostring(i)) or (option.label.." "..tostring(self.BuildSerial)))
        if pos==nil then failed=true; break end
        local ok,err=pcall(function()
        local ship=mn.createShip(name,class,orient,pos,carrier.Team,true); self:InvalidateShipList()
        if shipValid(ship) then
            -- Record ownership before initialization: a later error must not
            -- refund a hull that already exists or retry its construction.
            spawned[#spawned+1]=ship
            if self.RecordShipCreated then self:RecordShipCreated(ship,true) end
            self:ApplyFactionVisual(ship,"BLUE")
            ship:warpIn(); self:EnableFullArsenal(ship); if self.AutoPlayerMode then self:AssignAIStrategicOrder(ship,"BLUE",true) else self:ApplyPolicyToShip(ship,true) end
        else
            -- mn.createShip hands back an invalid handle when ship_create refuses
            -- the class, so this used to drop the hull with nothing in the log and
            -- the queue only reported a generic refund.
            self:Log(string.format("SPAWN FAILED: %s (%s) slot %d/%d at %.0f, %.0f, %.0f",name,option.class,i,count,pos.x,pos.y,pos.z))
        end
        end)
        if not ok then failed=true; self:Log("SPAWN INITIALIZATION FAILED: "..name..": "..tostring(err)) end
    end
    if #spawned>1 then self:RegisterLogicalWing(spawned,wingLabel) end
    if #spawned==count and not failed then return true,spawned end
    return false,spawned
end

function RTS:NotifyNewUnits(spawned)
    local popup=self.NewUnitPopup
    local now=self:UINow()
    if popup and popup.expiresAt and now>popup.expiresAt then popup=nil end
    if popup==nil then popup={signatures={}} end
    for _,ship in ipairs(spawned or {}) do
        if shipAlive(ship) and self:IsMovableFriendly(ship) then
            local signature=ship:getSignature()
            if not tableContainsSignature(popup.signatures,signature) then popup.signatures[#popup.signatures+1]=signature end
        end
    end
    if #popup.signatures==0 then return end
    popup.expiresAt=self.PossessedSignature==nil and now+(self.Config.UI.NewUnitPopupSeconds or 5) or nil
    self.NewUnitPopup=popup
end

-- Warp-in points for hulls that are building: the spawn point the job's first hull
-- will use (GetSpawnFrame, the same placement the arrival uses). Recomputed every few
-- seconds per job rather than every frame, because GetSpawnFrame scans the ship list.
function RTS:GetBuildSignatures(now)
    local signatures={}
    local carrier=self:GetCarrier()
    if not shipAlive(carrier) then return signatures end
    for _,job in ipairs(self.BuildQueue or {}) do
        if job.started==true and job.option and job.option.class then
            if job.signatureAt==nil or now-job.signatureAt>=5 then
                local class=tb.ShipClasses[job.option.class]
                job.signaturePos=class and (self:GetSpawnFrame(carrier,class,1,job.option.count or 1)) or nil
                job.signatureAt=now
            end
            if job.signaturePos then signatures[#signatures+1]={pos=job.signaturePos,job=job} end
        end
    end
    return signatures
end

function RTS:GetProductionQueueStatus(kind, now, automatic)
    now=tonumber(now) or mn.getMissionTime()
    local current=nil; local queued=0
    if automatic then
        local state=self.AIStates and self.AIStates[kind]
        current=state and state.queue or nil
    elseif kind=="BLUE" then
        current=self.BuildQueue and self.BuildQueue[1] or nil
        queued=math.max(0,(self.BuildQueue and #self.BuildQueue or 0)-self:GetBuildQueueSlots("BLUE"))
    end
    if current==nil then return nil end
    local option=current.option or current.entry or {}
    local label=option.label or option.class or "UNKNOWN"
    local count=current.count or option.count or 1
    local remaining
    local hasFinishTime=current.finishTime~=nil and tonumber(current.finishTime)>0
    if current.started==true or (hasFinishTime and current.finishTime>now) then
        remaining=math.max(0,(current.finishTime or now)-now)
    else
        local duration=self:GetEscalationProfile()
        local scale=duration and duration.buildTimeScale or 1
        remaining=math.max(0,(option.time or (current.estimate and current.estimate.time) or 0)*scale)
    end
    local waitingForCapacity=false
    if automatic and remaining<=0 then
        local cap=self:GetFleetCap(kind)
        waitingForCapacity=self:CountFactionCombatants(kind)+(tonumber(count) or 1)>cap
    end
    local active=0
    if not automatic and kind=="BLUE" then
        for _,item in ipairs(self.BuildQueue or {}) do if item.started and (item.blockedAt or item.finishTime>now) then active=active+1 end end
    end
    return {label=label,count=count,remaining=remaining,queued=queued,active=active,slots=not automatic and self:GetBuildQueueSlots(kind) or 1,started=current.started==true,waitingForCapacity=waitingForCapacity}
end

function RTS:UpdateBuildQueue(now)
    if self.AftermathActive then return end
    if #self.BuildQueue == 0 then return end
    local carrier = self:GetCarrier()
    if carrier == nil then return end
    local active=0
    for _,item in ipairs(self.BuildQueue) do if item.started and (item.blockedAt or item.finishTime>now) then active=active+1 end end
    local duration=self:GetEscalationProfile(); local scale=duration and duration.buildTimeScale or 1
    for _,item in ipairs(self.BuildQueue) do
        if active>=self:GetBuildQueueSlots("BLUE") then break end
        if not item.started then
            item.started=true; item.startTime=now
            item.finishTime=now+item.option.time*scale*self:GetBuildTimeMultiplier("BLUE")
            self:EmitAIEvent("PRODUCTION",{action="BUILD_STARTED",producer="PLAYER",faction="BLUE",
                jobId=item.id,class=item.option.class,role=item.option.role,tier=item.option.tier,count=item.option.count or 1,
                cost=item.option.cost,buildSeconds=item.finishTime-now,queuedAt=item.queuedAt or now,
                startTime=now,finishTime=item.finishTime},now)
            active=active+1
        end
    end
    for i=#self.BuildQueue,1,-1 do
        local current=self.BuildQueue[i]
        if current.started and now>=current.finishTime then
            if self:CountFactionCombatants("BLUE")+(current.option.count or 1)>self:GetFleetCap("BLUE") then
                if current.blockedAt==nil then current.blockedAt=now; self:EmitAIEvent("PRODUCTION",{action="BUILD_BLOCKED",producer="PLAYER",faction="BLUE",
                    jobId=current.id,class=current.option.class,count=current.option.count or 1,cost=current.option.cost,reason="FLEET_CAP",finishTime=current.finishTime},now) end
            else
                -- Retire first, and keep created hulls outside the protected call.
                -- A failure cannot retry the job or refund a hull already spawned.
                table.remove(self.BuildQueue,i)
                local spawned={}
                local ok,success,returned=pcall(function()
                    local s,sp=self:SpawnFriendly(current.option,spawned)
                    return s,sp
                end)
                if ok and returned then spawned=returned end
                if not ok then
                    self:Log("SPAWN RAISED for "..tostring(current.option.class)..": "..tostring(success))
                    success=false
                end
                local signatures={}
                for _,ship in ipairs(spawned or {}) do if shipValid(ship) then signatures[#signatures+1]=ship:getSignature() end end
                if success then
                    self:SetStatus(current.option.label.." deployed",2)
                    self:EmitAIEvent("PRODUCTION",{action="UNIT_SPAWNED",producer="PLAYER",faction="BLUE",jobId=current.id,class=current.option.class,
                        role=current.option.role,tier=current.option.tier,requestedCount=current.option.count or 1,spawnedCount=#signatures,
                        shipSignatures=signatures,cost=current.option.cost,queuedAt=current.queuedAt or current.startTime,
                        startedAt=current.startTime,completedAt=now,buildSeconds=now-(current.startTime or now),
                        capacityWaitSeconds=current.blockedAt and math.max(0,now-current.blockedAt) or 0},now)
                else
                    local requested=current.option.count or 1
                    local refund=math.floor(current.option.cost*math.max(0,requested-#signatures)/requested+0.5); local before=self.CommandPoints
                    self.CommandPoints=self.CommandPoints+refund; self:RecordAIEconomyFlow("BLUE","refund",refund)
                    self:SetStatus(#signatures>0 and ("Build partly failed; "..refund.." CP refunded") or "Build failed; command points refunded",3)
                    self:EmitAIEvent("PRODUCTION",{action="BUILD_FAILED",producer="PLAYER",faction="BLUE",jobId=current.id,class=current.option.class,
                        role=current.option.role,tier=current.option.tier,requestedCount=requested,spawnedCount=#signatures,
                        shipSignatures=signatures,cost=current.option.cost,refundedCP=refund,cpBefore=before,cpAfter=self.CommandPoints,
                        completedAt=now,reason=ok and "PARTIAL_OR_FAILED_SPAWN" or "SPAWN_RAISED"},now)
                end
                if #signatures>0 then self:NotifyNewUnits(spawned) end
            end
        end
    end
end

function RTS:SpawnFactionUnit(className,anchor,team,prefix,waveNumber,unitIndex,offsetIndex,slot,total,nameOverride,batch,spawned)
    if not shipAlive(anchor) or team==nil or not team:isValid() then return nil end
    local class=tb.ShipClasses[className]; if class==nil or not class:isValid() then self:Log("Invalid faction class: "..className); return nil end
    self.EnemySerial=self.EnemySerial+1; local serial=self.EnemySerial; local pos,orient=self:GetSpawnFrame(anchor,class,slot or 1,total or 1,batch)
    if pos==nil then return nil end
    local name=self:GetSafeShipName(nameOverride or (prefix.." W"..tostring(waveNumber).."-"..tostring(unitIndex).."-"..tostring(serial)))
    local ship=mn.createShip(name,class,orient,pos,team,true); self:InvalidateShipList()
    if shipValid(ship) then
        if spawned then spawned[#spawned+1]=ship end
        if self.RecordShipCreated then self:RecordShipCreated(ship,true) end
        self:ApplyFactionVisual(ship,self.FactionKeyByTeam and self.FactionKeyByTeam[lower(team.Name)])
        local ok,err=pcall(function() ship:warpIn(); self:EnableFullArsenal(ship) end)
        if not ok then self:Log("SPAWN INITIALIZATION FAILED: "..name..": "..tostring(err)) end
        return ship
    end
    self:Log(string.format("SPAWN FAILED: %s (%s) at %.0f, %.0f, %.0f",name,className,pos.x,pos.y,pos.z)); return nil
end

function RTS:SpawnConfiguredWave(waves, index, anchor, prefix, countMultiplier)
    local wave = waves[index]
    if wave == nil or not shipValid(anchor) then return end
    local serial = 0; local total = 0; local spawned={}; local classCounts={}; local replacementValue=0
    for _, unit in ipairs(wave.units) do total = total + math.max(1, math.ceil(unit.count * countMultiplier)) end
    for _, unit in ipairs(wave.units) do
        local count = math.max(1, math.ceil(unit.count * countMultiplier))
        for i = 1, count do
            serial = serial + 1
            local ship=self:SpawnFactionUnit(unit.class, anchor, anchor.Team, prefix, index, i, serial, serial, total, nil, index)
            if shipValid(ship) then
                spawned[#spawned+1]=ship:getSignature()
                classCounts[unit.class]=(classCounts[unit.class] or 0)+1
                replacementValue=replacementValue+self:GetStrategicUnitValue(ship,self:GetFactionKey(ship))
            end
        end
    end
    self:EmitAIEvent("PRODUCTION",{action="WAVE_SPAWNED",producer="REINFORCEMENT",faction=self:GetFactionKey(anchor),
        wave=index,prefix=prefix,requestedCount=total,spawnedCount=#spawned,shipSignatures=spawned,
        classCounts=classCounts,cost=0,replacementValue=replacementValue,economyTreatment="free-reinforcement"},mn.getMissionTime())
end

function RTS:UpdateEnemyWaves(now)
    if self.AftermathActive then return end
    if self.Config.AI==nil or self.Config.AI.UseLegacyWaves~=true then return end
    if self.SetupActive or self.BattleVictor~=nil or self.ScenarioStartTime==nil then return end
    local elapsed=now-self.ScenarioStartTime; local waves=self.Config.EnemyWaves or {}
    if self:IsFactionEnabled("RED") then while not self.RedEliminated and self.WaveIndex<=#waves and elapsed>=(waves[self.WaveIndex].time or math.huge) do self:SpawnConfiguredWave(waves,self.WaveIndex,self:GetEnemyCommand(),"RTS Red",1); self.WaveIndex=self.WaveIndex+1 end end
    if self:IsFactionEnabled("GOLD") then local gwaves=self.Config.GoldWaves or {}; while not self.GoldEliminated and self.GoldWaveIndex<=#gwaves and elapsed>=(gwaves[self.GoldWaveIndex].time or math.huge) do self:SpawnConfiguredWave(gwaves,self.GoldWaveIndex,self:GetThirdCommand(),"RTS Gold",1); self.GoldWaveIndex=self.GoldWaveIndex+1 end end
end

function RTS:UpdateEconomy(now)
    if self.AftermathActive or self.SetupActive or self.ScenarioStartTime == nil or self.BlueEliminated or self.BattleVictor ~= nil then self.LastIncomeTime = now; return end
    local delta = now - self.LastIncomeTime
    if delta <= 0 then return end
    local ramp=self:GetAIIncomeRamp(now)
    local income=delta * self.ActiveIncomePerSecond * ramp * self:GetIncomeMultiplier("BLUE")
    self.CommandPoints = self.CommandPoints + income
    self:RecordAIEconomyFlow("BLUE","income",income)
    self.LastIncomeTime = now
end

function RTS:InitializeSetupHold()
    self:EachShip(function(ship)
        if ship.Name ~= self.Config.ObserverShip then
            ship:clearOrders()
            ship:giveOrder(ORDER_STAY_STILL, nil, nil, 1.5)
        end
    end)
end

function RTS:InitializeUnitOrders()
    self:EachShip(function(ship)
        if ship.Name~=self.Config.ObserverShip then
            self:EnableFullArsenal(ship); self:AuditShipArsenal(ship)
            if self:IsStaticDefense(ship) then return end
            local kind=self:GetFactionKey(ship)
            if kind=="BLUE" then
                if self:IsCommandStation(ship) then self:HoldShip(ship,.70)
                elseif self.AutoPlayerMode then self:AssignAIStrategicOrder(ship,"BLUE",true)
                else self:ApplyPolicyToShip(ship,true) end
            elseif kind and self:IsFactionEnabled(kind) then
                if self:IsCommandStation(ship) then self:HoldShip(ship,.72)
                else self:AssignAIStrategicOrder(ship,kind,true) end
            end
        end
    end)
    self:ApplyFactionVisuals()
end
