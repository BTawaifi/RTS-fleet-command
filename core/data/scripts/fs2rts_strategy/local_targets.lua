-- Local threat, primary target selection, order assignment and validation.
local _shared = require "fs2rts_strategy.common"
local sortedNumericKeys, RTS, shipAlive, shipValid, canAutoEngage = _shared.sortedNumericKeys, _shared.RTS, _shared.shipAlive, _shared.shipValid, _shared.canAutoEngage

function RTS:FindFactionLocalThreat(kind, station, radius)
    if not shipValid(station) then return nil end
    local best, bestDist = nil, radius or math.huge
    self:EachShip(function(other)
        if shipAlive(other) and other.Name ~= self.Config.ObserverShip and canAutoEngage(self,station,other) then
            if not self:IsCommandStation(other) then
                local d = other.Position:getDistance(station.Position)
                if d < bestDist then best, bestDist = other, d end
            end
        end
    end)
    return best
end

function RTS:FindUnitLocalThreat(ship, radius)
    if not shipValid(ship) then return nil end
    local best, bestDist = nil, radius or math.huge
    self:EachShip(function(other)
        if shipAlive(other) and other.Name ~= self.Config.ObserverShip and canAutoEngage(self,ship,other) then
            if not self:IsCommandStation(other) then
                local d = other.Position:getDistance(ship.Position)
                if d < bestDist then best, bestDist = other, d end
            end
        end
    end)
    return best
end

function RTS:SelectFactionPrimaryTarget(kind)
    local source=self:GetFactionCommandShip(kind); if not shipAlive(source) then return nil end
    local candidates={}; local factionKeys=self:GetFactionKeys()
    for _,otherKind in ipairs(factionKeys) do
        if otherKind~=kind and self:IsFactionEnabled(otherKind) then
            local station=self:GetFactionCommandShip(otherKind)
            if shipAlive(station) and self:AreEnemies(source,station) then
                candidates[#candidates+1]={kind=otherKind,ship=station}
            end
        end
    end
    if #candidates==0 then return nil end

    -- This is the preferred opening front, not a timer that turns every wing.
    -- The commander assigns surviving groups persistent fronts independently.
    local preferredKind=nil
    if #factionKeys==3 and self.Config.ThreeFactionTargetCycle~=nil
        and self:IsFactionEnabled(self.Config.ThreeFactionTargetCycle[kind]) then
        preferredKind=self.Config.ThreeFactionTargetCycle[kind]
    elseif #factionKeys>2 then
        for index,candidateKind in ipairs(factionKeys) do
            if candidateKind==kind then preferredKind=factionKeys[index%#factionKeys+1]; break end
        end
    end
    if self.ScenarioBaseLayoutId and self.ScenarioBaseLayoutId~='CIRCLE' then preferredKind=nil end
    local preferred=nil
    for _,candidate in ipairs(candidates) do if candidate.kind==preferredKind then preferred=candidate end end

    table.sort(candidates,function(a,b)
        if preferred~=nil then
            if a.kind==preferredKind and b.kind~=preferredKind then return true end
            if b.kind==preferredKind and a.kind~=preferredKind then return false end
        end
        local ad=a.ship.Position:getDistance(source.Position)
        local bd=b.ship.Position:getDistance(source.Position)
        if math.abs(ad-bd)>1 then return ad<bd end
        return tostring(a.kind)<tostring(b.kind)
    end)
    return candidates[1].ship
end

function RTS:AssignAIStrategicOrder(ship,kind,force)
    if not shipValid(ship) or self:IsStaticDefense(ship) or (self.IsShipWithdrawing and self:IsShipWithdrawing(ship)) then return end
    local station=self:GetFactionCommandShip(kind); if not shipValid(station) or ship:getSignature()==station:getSignature() then return end
    local sig=ship:getSignature()
    if kind=="BLUE" then if not self.AutoPlayerMode or self.PossessedSignature==sig or self.UserOrders[sig]~=nil then return end end
    local primary=self:GetStablePrimaryTarget(kind); if not shipValid(primary) then return end
    if not self:CanDamageBase(ship) then self:IssueStrategicOrder(ship,station,"AI SCREEN: DEFEND "..station.Name,"SCREEN",mn.getMissionTime(),force)
    else self:IssueStrategicOrder(ship,primary,"AI PRIMARY: COMMITTED STRIKE ON "..primary.Name,"PRIMARY",mn.getMissionTime(),force) end
end

function RTS:ValidateStrategicOrderTargets(now)
    -- FSO may clear or retarget a goal after it has been installed. Reassert
    -- only attack orders whose native target is missing or no longer hostile;
    -- a valid hostile retarget is left alone so the engine can react locally.
    local orderState=self.AIOrderState or {}
    for _,sig in ipairs(sortedNumericKeys(orderState)) do
        local state=orderState[sig]
        if state and state.targetSignature~=nil then
            local ship=self:FindShipBySignature(sig); local target=self:FindShipBySignature(state.targetSignature)
            if self:IsAutomaticAIUnit(ship) then
            local hostileTarget=shipAlive(ship) and shipAlive(target) and canAutoEngage(self,ship,target)
            local withdrawalTarget=shipAlive(ship) and shipAlive(target) and self:AreEnemies(ship,target) and not hostileTarget
            local friendlyGoal=shipAlive(target) and self:GetFactionKey(ship)==self:GetFactionKey(target)
                and (state.mission=="SCREEN" or state.mission=="ESCORT" or state.mission=="REGROUP"
                    or state.mission=="RETREAT" or state.mission=="LURE")
            -- SCREEN normally guards the friendly station, but a screen wing
            -- assigned to an actual hostile must receive the same repair.
            if hostileTarget or friendlyGoal or withdrawalTarget or not shipValid(target) then
                if hostileTarget or friendlyGoal then
                    local status,goalPresent=self:GetNativeObjectiveStatus(ship,state)
                    local repairInterval=(self.Config.AI.Doctrine or {}).NativeTargetRepairInterval or 6
                    local age=now-(state.installedAt or state.assignedAt or now)
                    local repair=status=="NATIVE_ORDER_PREEMPTED" or status=="NATIVE_TARGET_FRIENDLY" or status=='PLANNER_TARGET_MISMATCH'
                        or (status=="NATIVE_TARGET_LOST" and goalPresent~=true and age>=repairInterval)
                    if repair and now-(state.lastRepair or -math.huge)>=repairInterval then
                        local subsystem=state.subsystemIndex and target[state.subsystemIndex]
                        if subsystem and (not subsystem:isValid() or subsystem.HitpointsLeft<=0) then subsystem=nil end
                        self:IssueStrategicOrder(ship,target,state.label,state.mission,now,true,
                            {destination=state.destination,subsystem=subsystem,subsystemIndex=subsystem and state.subsystemIndex or nil})
                        local repaired=self.AIOrderState[sig]
                        if repaired then repaired.lastRepair=now end
                    end
                elseif withdrawalTarget and shipValid(ship) then
                    ship:clearOrders(); self.AIOrderState[sig]=nil
                    self:AssignAIStrategicOrder(ship,self:GetFactionKey(ship),true)
                elseif shipValid(ship) then
                    self.AIOrderState[sig]=nil
                end
            else
                -- Dying and captured/realigned targets are no longer legal goals.
                ship:clearOrders(); self.AIOrderState[sig]=nil
                self:EmitAIEvent('EXECUTION',{ship=sig,target=state.targetSignature,status='TARGET_INVALID',
                    reason=shipAlive(target) and 'TARGET_NO_LONGER_HOSTILE' or 'TARGET_DEAD'},now)
            end
            end
        end
    end
end

function RTS:UpdateAIStrategicObjectives(now)
    if self.AftermathActive or self.Config.AI==nil or self.Config.AI.Enabled==false or self.SetupActive or self.PostBattleActive then return end
    local queue=self.AIStrategicPlanQueue
    if queue==nil then
        if now-self.LastAIStrategicUpdate<(self.Config.AI.StrategicOrderInterval or 12) then return end
        self.LastAIStrategicUpdate=now
        -- Collect execution state once, then spread the three independent
        -- faction plans over adjacent frames to avoid one combined Lua spike.
        self.StrategicThreatSnapshot=self:BuildStrategicThreatSnapshot()
        self:BuildAIContext(self.StrategicThreatSnapshot)
        self:ObserveAIExecution(now)
        self:ValidateStrategicOrderTargets(now)
        queue={}
        for _,faction in ipairs(self:GetFactionKeys()) do
            if faction=="BLUE" then
                if self.AutoPlayerMode and not self:IsFactionEliminated(faction) then queue[#queue+1]=faction end
            elseif not self:IsFactionEliminated(faction) then queue[#queue+1]=faction end
        end
        self.AIStrategicPlanQueue=queue
    else
        -- Positions and weapon mounts can change while another faction was
        -- planned, so each queued faction receives a fresh spatial snapshot.
        self.StrategicThreatSnapshot=self:BuildStrategicThreatSnapshot()
        self:BuildAIContext(self.StrategicThreatSnapshot)
    end
    local kind=table.remove(queue,1)
    if kind and self:IsFactionEnabled(kind) and not self:IsFactionEliminated(kind)
        and (kind~="BLUE" or self.AutoPlayerMode) then self:UpdateFactionStrategicPlan(kind,now,false) end
    if #queue==0 then
        self:SummarizeAI(now)
        self.AIStrategicPlanQueue=nil
    end
    self.StrategicThreatSnapshot=nil
    self.AIShipIndex=nil; self.AIProfileIndex=nil; self.AITargetedBy=nil
    self.AISpatialGrid=nil; self.AILocalCache=nil
end

-- A stationless faction still has hostile ships. Keep their existing attack
-- until its target dies; capitals need refreshed waypoints for unpursued hulls.
-- After Resume this is the combat-only director for every automatic survivor.
function RTS:UpdateSurvivorCombat(now)
    if self.SetupActive or self.PostBattleActive or now<(self.NextSurvivorCombat or 0) then return end
    self.NextSurvivorCombat=now+2
    self:UpdateDefeatedFleetExtraction(now)
end
