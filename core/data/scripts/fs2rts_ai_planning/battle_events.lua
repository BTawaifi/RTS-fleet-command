-- AI battle-end and station-death telemetry.
return function(RTS, _shared)
local shipAlive, DEFAULT_FACTION_ORDER, distance, sig, valid, baseDamageRows = _shared.shipAlive, _shared.DEFAULT_FACTION_ORDER, _shared.distance, _shared.sig, _shared.valid, _shared.baseDamageRows

-- Why a battle ended, and who was ahead when it did.
--
-- The FACTION samples give a snapshot every 30 s and the base-damage telemetry
-- gives cumulative damage per weapon, but nothing joined the two: a finished
-- match could not say who killed which base, with what, or from what position.
-- This emits that join at the moment a command station is destroyed, and a
-- periodic CONTEST record that says how each faction's groups are actually
-- allocated and whether any of them are making progress toward their target.
function RTS:EmitContestRecord(kind,groups,station,primary,now)
    if not self:IsAITraceActive() then return end
    local cadence=(self.Config.AI or {}).ContestSampleSeconds or 10
    self.AIContestSampleAt=self.AIContestSampleAt or {}
    if now-(self.AIContestSampleAt[kind] or -1e9)<cadence then return end
    self.AIContestSampleAt[kind]=now
    self.AIContestProgress=self.AIContestProgress or {}
    local present={}; local prefix=tostring(kind)..'/'

    local primarySignature=valid(primary) and primary:getSignature() or nil
    local onBase,onGroups,stalledGroups=0,0,0
    local worstStall=0; local missions={}; local nodes={}
    for _,g in ipairs(groups or {}) do
        local target=g.target
        local targetSignature=valid(target) and sig(target) or nil
        -- Named "range" not "distance": a local called distance shadows the
        -- distance() helper this module closes over, and the call below would
        -- then be a call on nil.
        local range=nil
        if valid(target) and g.units and g.units[1] and shipAlive(g.units[1]) then
            range=distance(g.units[1],target)
        end
        -- "Progress" is a reduction in range to the current objective. A group
        -- assigned to attack that stops closing is the signature of a capital
        -- that accepted its order and then sat there, which is exactly what the
        -- engine does when ai_chase refuses a fighter target.
        local key=prefix..tostring(g.id); present[key]=true
        local state=self.AIContestProgress[key]
        if state==nil or state.mission~=(g.mission or 'IDLE') or state.target~=targetSignature then
            state={mission=g.mission or 'IDLE',target=targetSignature,lastDistance=range,lastProgressAt=now}
            self.AIContestProgress[key]=state
        end
        if range~=nil and state.lastDistance~=nil and range<state.lastDistance-150 then
            state.lastDistance=range; state.lastProgressAt=now
        elseif range~=nil then state.lastDistance=range end
        local stalled=math.max(0,now-(state.lastProgressAt or now))
        if (g.mission=="PRIMARY" or g.mission=="SCREEN" or g.mission=="INTERCEPT") and stalled>30 then
            stalledGroups=stalledGroups+1
            if stalled>worstStall then worstStall=stalled end
        end
        if targetSignature==primarySignature then onBase=onBase+(g.value or 0) else onGroups=onGroups+(g.value or 0) end
        missions[g.mission or 'IDLE']=(missions[g.mission or 'IDLE'] or 0)+1
        nodes[#nodes+1]={group=g.id,role=g.role,mission=g.mission or 'IDLE',value=g.value or 0,
            ships=#(g.units or {}),distance=range,stalledSeconds=stalled,
            targetIsStation=targetSignature==primarySignature}
    end
    -- Retain stall history for present groups only, without dropping another
    -- faction's progress when this faction is sampled.
    for key in pairs(self.AIContestProgress) do
        if key:sub(1,#prefix)==prefix and not present[key] then self.AIContestProgress[key]=nil end
    end
    -- Orders that stopped being valid: a live order pointing at a dead target is
    -- how "the ship ignores my command" shows up in the aggregate.
    local staleOrders,serviced,alive=0,0,0
    for id,state in pairs(self.AIOrderState or {}) do
        if state.targetSignature~=nil then
            local target=self:FindShipBySignature(state.targetSignature)
            if not valid(target) then staleOrders=staleOrders+1 end
        end
    end
    if self.FleetServices then for _ in pairs(self.FleetServices) do serviced=serviced+1 end end
    self:EmitAIEvent('CONTEST',{
        faction=kind,time=now,primaryName=valid(primary) and primary.Name or 'NONE',
        primaryX=valid(primary) and primary.Position and primary.Position.x or nil,
        primaryZ=valid(primary) and primary.Position and primary.Position.z or nil,
        stationHull=valid(station) and station.HitpointsMax>0 and station.HitpointsLeft/station.HitpointsMax or nil,
        valueOnPrimary=onBase,valueOnGroups=onGroups,groupCount=#nodes,
        missionCounts=missions,stalledGroups=stalledGroups,worstStallSeconds=worstStall,
        staleOrders=staleOrders,servicedShips=serviced,groups=nodes,
    },now)
end

-- Emitted the instant a command station dies, so an outcome can be explained
-- without replaying the whole battle.
function RTS:EmitOutcomeCause(kind,now)
    local faction=self:GetFactionDefinition(kind)
    local targetName=faction and faction.station or nil
    local rows=baseDamageRows(self.BaseDamageTelemetry and self.BaseDamageTelemetry.totalByFaction
        and self.BaseDamageTelemetry.totalByFaction[kind] or nil)
    -- A row without targetName is one this emitter cannot attribute, so keep it
    -- rather than silently dropping the evidence.
    local function forThisBase(row) return row.targetName==nil or row.targetName==targetName end
    local total=0
    for _,row in ipairs(rows) do if forThisBase(row) then total=total+(row.hullDamage or 0) end end
    local killers={}
    for _,row in ipairs(rows) do
        if forThisBase(row) then
            killers[#killers+1]={weapon=row.weaponClass,subtype=row.weaponSubtype,
                attackerFaction=row.attackerFaction,source=row.sourceKind,
                beam=row.beamWeapon==true,damageType=row.damageType,
                hullDamage=row.hullDamage,hitCount=row.hitCount,
                share=total>0 and (row.hullDamage or 0)/total or 0}
        end
    end
    table.sort(killers,function(a,b) return (a.hullDamage or 0)>(b.hullDamage or 0) end)
    local snapshot={}
    local factionKeys=self.GetFactionKeys and self:GetFactionKeys() or DEFAULT_FACTION_ORDER
    for _,other in ipairs(factionKeys) do
        local state=self.AIStates and self.AIStates[other] or nil
        local station=self:GetFactionCommandShip(other)
        snapshot[other]={alive=other~=kind and self:IsFactionEnabled(other) and valid(station) or false,
            commandPoints=(other=="BLUE") and self.CommandPoints or (state and state.cp) or 0,
            stationHull=valid(station) and station.HitpointsMax>0 and station.HitpointsLeft/station.HitpointsMax or 0,
            eliminated=self:IsFactionEliminated(other)}
    end
    self:EmitAIEvent('OUTCOME_CAUSE',{
        faction=kind,targetName=targetName,time=now,
        elapsed=now-(self.ScenarioStartTime or now),
        totalAttributedHullDamage=total,killers=killers,snapshot=snapshot,
    },now)
end
end
