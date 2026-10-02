-- AI strategic planning, threats and orders.
local Config = require "fs2rts_config"
local U = require "fs2rts_util"
local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys
local RTS = require "fs2rts_state"
local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

-- Same priority the bare ORDER_ATTACK branch installs, so nothing else in the
-- order stack shifts when a pursuit replaces a chase goal.
local ATTACK_ORDER_PRIORITY=0.88
local PURSUIT_LEAD_SECONDS=4
local PURSUIT_REFRESH_SECONDS=1.5
-- objecttypes.tbl '+Actively Pursues' covers cruiser/corvette/capital but not
-- fighter, bomber or support, and omits the "command" class type entirely, so
-- ai_chase sets AIM_NONE on those targets. IsUnpursuedTarget also treats a
-- command station as unpursued for every attacker, because no hull pursues one.
local UNPURSUED_TARGET_ROLES={fighter=true,bomber=true,support=true}
-- Escorts are included because they stalled just as far as capitals on a base
-- attack; the attack order has to be driven by a waypoint, not a chase goal.
local HEAVY_ATTACKER_ROLES={capital=true,heavy=true,juggernaut=true,escort=true}

function RTS:GetStrategicUnitValue(ship,kind)
    if not shipValid(ship) then return 0 end
    local entry=self:GetAIRosterEntry(kind,ship.Class.Name); local tier=entry and entry.tier or 1
    -- Runs inside $On Ship Death, so never page a POF and never raise here.
    local est=self:GetPurchaseEstimate(ship.Class.Name,tier,1,false)
    return est and est.cost or (self.ShipCostMap[ship.Class.Name] and self.ShipCostMap[ship.Class.Name].cost) or 100
end

function RTS:GetStablePrimaryTarget(kind)
    local sig=self.FactionPrimaryTargets[kind]
    if sig~=nil then
        local old=self:FindShipBySignature(sig)
        local source=self:GetFactionCommandShip(kind)
        if shipAlive(old) and self:IsFactionEnabled(self:GetFactionKey(old)) and shipAlive(source) and self:AreEnemies(source,old) then return old end
    end
    local target=self:SelectFactionPrimaryTarget(kind)
    self.FactionPrimaryTargets[kind]=shipValid(target) and target:getSignature() or nil
    return target
end

function RTS:GetCombatValue(ship,firepower)
    if not shipAlive(ship) then return 0 end
    if firepower==nil then local _,_,_,_,power=self:GetStrategicWeapons(ship); firepower=power end
    local shields=ship.Shields and ship.Shields.CombinedLeft or 0
    return math.sqrt(math.max(0,ship.HitpointsLeft+shields))*math.sqrt(math.max(0,firepower or 0))
end

function RTS:GetAIAssaultStrengthRatio()
    local doctrine=self.Config.AI.Doctrine or {}
    local difficulty=self.Config.Setup.Difficulties[self.SetupDifficultyIndex] or {}
    return (doctrine.AssaultStrengthRatio or 1)/math.max(.5,difficulty.aiAggression or 1)
end

-- Keep surviving wings on their front. Balance new groups between live enemy
-- bases instead of rotating the entire fleet on a timer.
function RTS:AssignAIAssaultFronts(kind,groups,preferred)
    self.AIAssaultTargets=self.AIAssaultTargets or {}
    local assignments=self.AIAssaultTargets[kind] or {}; self.AIAssaultTargets[kind]=assignments
    local fronts,load,present={},{},{}
    local source=self:GetFactionCommandShip(kind)
    for _,enemy in ipairs(AI_FACTION_ORDER) do
        local base=self:GetFactionCommandShip(enemy)
        if enemy~=kind and self:IsFactionEnabled(enemy) and shipAlive(base) and self:AreEnemies(source,base) then
            fronts[#fronts+1]=base; load[base:getSignature()]=0
        end
    end
    for _,g in ipairs(groups) do
        present[g.id]=true
        g.primary=nil
        local target=self:FindShipBySignature(assignments[g.id])
        if shipAlive(target) and load[target:getSignature()]~=nil then
            g.primary=target
            if not g.screen then load[target:getSignature()]=load[target:getSignature()]+math.max(1,g.value) end
        else assignments[g.id]=nil end
    end
    for id in pairs(assignments) do if not present[id] then assignments[id]=nil end end
    for _,g in ipairs(groups) do
        if not g.primary then
            local best=nil
            local function share(base)
                if #fronts<2 then return 1 end
                local main=clamp((self.Config.AI.Doctrine or {}).PrimaryFrontShare or .7,.05,.95)
                return base==preferred and main or (1-main)/(#fronts-1)
            end
            for _,base in ipairs(fronts) do
                if not best or load[base:getSignature()]/share(base)<load[best:getSignature()]/share(best)
                    or (load[base:getSignature()]/share(base)==load[best:getSignature()]/share(best) and base==preferred) then best=base end
            end
g.primary=best
            if best then assignments[g.id]=best:getSignature(); load[best:getSignature()]=load[best:getSignature()]+math.max(1,g.value) end
        end
    end
end

-- ASSAULT GROUP POOLING. Disabled unless
-- Station.AI.Doctrine.PoolAssaultGroupsEnabled is true, in which case this
-- returns the input table untouched, so the default path is byte for byte the
-- pre-existing behaviour.
--
-- Group identity is assigned once at fs2rts_strategy.lua:687 as
-- (logical wing id or ship signature)..role, and every strategic tick rebuilds
-- the whole group list from wing membership. No code path anywhere merges two
-- groups, so the simultaneous group count is exactly the number of surviving
-- wings plus unwinged hulls. That makes it a direct function of purchase rate
-- rather than of tactics, and it is the mechanism behind both the fragmentation
-- and the churn: CommitAIGroup issues one independent order per group, so N
-- half-strength wings produce N independent decisions per tick.
--
-- Only groups that are genuinely interchangeable are folded together:
--   - same role, so no mixed-weapon group is formed
--   - both already carrying the same mission, so no in-flight plan is rewritten
--   - both already on the same primary front, so no wing is redirected
--   - neither already holding its own target, so nothing overrides a decision
--   - neither defending, luring, feinting or probing, and neither already
--     assault-reserved, homeguard, capital-suppressed or a bomber escort, so
--     the interception, taunt, lure, reserve and preemption paths each keep
--     their own group
--   - their centroids are within PoolAssaultGroupsRadius, which picks the host
--     a wing folds into (the nearest compatible one, so a line of wings
--     collapses as a whole rather than pairwise)
--   - the WIDEST hull-to-hull distance between them, added to both groups'
--     own spreads, stays within RegroupDistance, which is the real
--     admissibility test. A group wider than that trips FORMATION_RECOVERY on
--     its next tick and churns forever.
-- The surviving group keeps the lower id for deterministic telemetry, absorbs
-- the other's units, and re-derives value, spread, centroid and ordnance so
-- every later consumer (retreat hull tests, formation slots, coverage) sees one
-- real group. pooledCentroidX is scratch and is cleared before returning;
-- pooledFrom is a per-tick diagnostic, not state that outlives the group.
function RTS:PoolAIAssaultGroups(groups)
    local doctrine=(self.Config.AI and self.Config.AI.Doctrine) or {}
    if doctrine.PoolAssaultGroupsEnabled~=true then return groups end
    local radius=tonumber(doctrine.PoolAssaultGroupsRadius) or 0
    if radius<=0 then return groups end

    local function centroidX(g)
        local x,n=0,0
        for _,ship in ipairs(g.units) do
            if shipAlive(ship) and ship.Position then x=x+ship.Position.x; n=n+1 end
        end
        return n>0 and x/n or nil,n
    end
    -- Groups are folded into the nearest compatible host rather than the first
    -- one found, so a line of wings travelling together collapses into one
    -- group instead of only its leading pair.
    local function widestGap(a,b)
        local widest=0
        for _,sa in ipairs(a.units) do
            if shipAlive(sa) and sa.Position then
                for _,sb in ipairs(b.units) do
                    if shipAlive(sb) and sb.Position then
                        local d=sa.Position:getDistance(sb.Position)
                        if d>widest then widest=d end
                    end
                end
            end
        end
        return widest
    end

    local kept={}
    local regroupLimit=tonumber(doctrine.RegroupDistance) or math.huge
    for _,g in ipairs(groups) do
        local cx=g.pooledCentroidX
        if cx==nil then cx=centroidX(g) end
        if cx==nil or g.defending or g.luring or g.feint or g.probing or g.target~=nil
            or g.homeguard or g.assaultReserved or g.capitalSuppression or g.escortBomber then
            g.pooledCentroidX=cx
            kept[#kept+1]=g
        else
            local host,bestGap=nil,math.huge
            for _,other in ipairs(kept) do
                if other.role==g.role and other.mission==g.mission and other.target==nil
                    and not other.defending and not other.luring and not other.feint
                    and not other.probing and not other.homeguard and not other.assaultReserved
                    and not other.capitalSuppression and not other.escortBomber
                    and other.pooledCentroidX~=nil and shipValid(other.primary) and shipValid(g.primary)
                    and other.primary:getSignature()==g.primary:getSignature() then
                    local gap=math.abs(other.pooledCentroidX-cx)
                    if gap<radius and gap<bestGap then host=other; bestGap=gap end
                end
            end
            -- The merged group's spread is the largest of the two groups' own
            -- spreads and the WIDEST hull-to-hull distance between them (the
            -- nearest gap understates it and would admit a host whose outer
            -- ships straddle both groups). A merge that would push the result
            -- past RegroupDistance is refused outright: such a group trips
            -- FORMATION_RECOVERY on the very next tick (mission=="PRIMARY" and
            -- g.spread>RegroupDistance) and would churn forever, so pooling it
            -- would be worse than not pooling it.
            local gap=host and widestGap(host,g) or math.huge
            local mergedSpread=host and math.max(host.spread or 0,g.spread or 0,gap) or math.huge
            if host and mergedSpread<=regroupLimit then
                for _,ship in ipairs(g.units) do host.units[#host.units+1]=ship end
                table.sort(host.units,function(a,b) return a:getSignature()<b:getSignature() end)
                host.value=host.value+g.value
                host.armed=host.armed or g.armed
                host.spread=mergedSpread
                host.pooledFrom=(host.pooledFrom or 1)+1
                local ships=0; local x=0
                for _,ship in ipairs(host.units) do
                    if shipAlive(ship) and ship.Position then ships=ships+1; x=x+ship.Position.x end
                end
                host.pooledCentroidX=ships>0 and x/ships or host.pooledCentroidX
                -- A merged group's worst-armed hull is the group's floor, which is
                -- what every ordnance consumer downstream expects.
                local carries,loaded=self:GetShipOrdnance(host.units[1])
                host.ordnance=math.min(host.ordnance or carries,carries)
                host.ordnanceLoaded=math.min(host.ordnanceLoaded or loaded,loaded)
            else
                g.pooledCentroidX=cx
                kept[#kept+1]=g
            end
        end
    end
    for _,g in ipairs(kept) do g.pooledCentroidX=nil end
    return kept
end


function RTS:RecordAIOrderTelemetry(kind,mission,status,result)
    if not self.CombatTelemetryEnabled then return end
    local audit=self.AIOrderTelemetry or {attempts=0,success=0,failed=0,rejected=0,unchanged=0,byMission={},byResult={}}
    self.AIOrderTelemetry=audit
    local faction=tostring(kind or "?"); local label=tostring(mission or "NONE"); local outcome=tostring(status or "unknown")
    audit.attempts=audit.attempts+1
    if outcome=="success" then audit.success=audit.success+1
    elseif outcome=="failed" then audit.failed=audit.failed+1
    elseif outcome=="rejected" then audit.rejected=audit.rejected+1
    elseif outcome=="unchanged" then audit.unchanged=audit.unchanged+1 end
    audit.byMission[faction]=audit.byMission[faction] or {}
    audit.byMission[faction][label]=audit.byMission[faction][label] or {success=0,failed=0,rejected=0,unchanged=0}
    audit.byMission[faction][label][outcome]=(audit.byMission[faction][label][outcome] or 0)+1
    local resultKey=outcome..":"..tostring(result)
    audit.byResult[resultKey]=(audit.byResult[resultKey] or 0)+1
end

function RTS:IsHeavyAttackHull(ship)
    if not shipAlive(ship) then return false end
    return HEAVY_ATTACKER_ROLES[self:GetShipRole(ship)]==true
end

function RTS:IsUnpursuedTarget(target)
    if not shipAlive(target) then return false end
    -- A command station is never on any hull's +Actively Pursues list: those
    -- lists enumerate mobile class types (transport, freighter, cruiser,
    -- corvette, capital, super cap, drydock, knossos) and omit "command". So
    -- ORDER_ATTACK on a base installs a chase goal the engine then refuses, and
    -- the attacker sits where it was. A station's computed role is "capital"
    -- (its hull radius is large), which is why this has to test the station
    -- itself rather than the role. Measured: capitals and escorts assigned a
    -- PRIMARY attack on a base stalled 10-12 km out for up to 17 minutes.
    if self:IsCommandStation(target) then return true end
    return UNPURSUED_TARGET_ROLES[self:GetShipRole(target)]==true
end

function RTS:IsPursuitPair(ship,target,subsystem)
    -- A subsystem-targeted attack must stay a native ORDER_ATTACK: that order is
    -- the only way to aim at a specific turret, and the pursuit waypoint carries
    -- no subsystem, so it would silently degrade to a hull-level attack.
    if subsystem~=nil then return false end
    return self:IsHeavyAttackHull(ship) and self:IsUnpursuedTarget(target)
end

-- A move goal to a leading intercept point. The goal terminates on arrival, so
-- RefreshAIPursuit re-anchors it; without that the capital reaches the stale
-- point once and then sits there holding nothing.
function RTS:IssuePursuitOrder(ship,target,priority,arrivalDistance)
    if not shipAlive(ship) or not shipAlive(target) then return false end
    local sig=ship:getSignature()
    if self.FleetServices and self.FleetServices[sig] then return false end
    local point=copyVec(target.Position)
    local vel=target.Physics and target.Physics.Velocity
    if vel and self:IsFiniteVector(vel) then
        local vx,vz=vel.x or 0,vel.z or 0
        local speed=math.sqrt(vx*vx+vz*vz)
        if speed>1 then
            local top=math.max(speed,math.abs((target.Physics.VelocityMax or {}).z or speed))
            -- Never lead by more than half a target's own top speed: a big
            -- hull is slow and would otherwise sail past a fast fighter.
            local lead=math.min(PURSUIT_LEAD_SECONDS,0.5*top/speed)
            point=vec(point.x+vx*lead,point.y,point.z+vz*lead)
        end
    end
    local safe=self:ClampCommandPoint(point,self:GetShipFormationRadius(ship)*1.05)
    if not safe then return false end
    local waypoint=self:GetOrCreateMoveWaypoint(ship)
    if not objectValid(waypoint) then return false end
    ship:clearOrders()
    waypoint.Position=copyVec(safe)
    if ship:giveOrder(ORDER_WAYPOINTS_ONCE,waypoint,nil,priority or ATTACK_ORDER_PRIORITY)~=true then return false end
    self.AIPursuit=self.AIPursuit or {}
    local entry=self.AIPursuit[sig]
    if entry==nil then entry={}; self.AIPursuit[sig]=entry end
    entry.targetSignature=target:getSignature(); entry.anchoredAt=mn.getMissionTime()
    entry.arrivalDistance=arrivalDistance or 900
    return true
end

function RTS:DropPursuit(sig)
    if self.AIPursuit then self.AIPursuit[sig]=nil end
end

function RTS:IssueStrategicOrder(ship,target,label,mission,now,force,options)
    if not shipAlive(ship) or not shipAlive(target) then return false end
    if self.FleetServices and self.FleetServices[ship:getSignature()] then return false end
    local sig=ship:getSignature(); local tsig=target:getSignature(); local previous=self.AIOrderState[sig]; local kind=self:GetFactionKey(ship)
    local enemies=self:AreEnemies(ship,target)
    local destination=options and options.destination
    local subsystem=options and options.subsystem
    local subsystemIndex=options and options.subsystemIndex
    if destination and (not self:IsFiniteVector(destination) or (mission~='REGROUP' and mission~='RETREAT')) then return false end
    if subsystem and (not enemies or not subsystem:isValid() or subsystem.HitpointsLeft<=0
        or not objectValid(subsystem:getParent()) or subsystem:getParent():getSignature()~=tsig
        or type(subsystemIndex)~='number' or subsystemIndex~=math.floor(subsystemIndex)
        or subsystemIndex<1 or subsystemIndex>#target
        or target[subsystemIndex].Name~=subsystem.Name) then return false end
    local guard=(mission=="SCREEN" or mission=="ESCORT" or mission=="REGROUP" or mission=="RETREAT" or mission=="LURE") and not enemies and self:GetFactionKey(ship)==self:GetFactionKey(target)
    if not guard and not enemies then
        -- Do not clear a valid order when a stale/invalid planner target is
        -- presented. This is the last gate before an engine attack goal.
        if previous and previous.targetSignature==tsig then self.AIOrderState[sig]=nil end
        self:RecordAIOrderTelemetry(kind,mission,"rejected",false)
        return false
    end
    local samePoint=not destination and not (previous and previous.destination)
        or destination and previous and previous.destination and destination:getDistance(previous.destination)<100
    if not force and previous and previous.targetSignature==tsig and previous.mission==mission
        and samePoint and previous.subsystemIndex==subsystemIndex then
        self:RecordAIOrderTelemetry(kind,mission,"unchanged",true)
        return
    end
    local moveWaypoint
    if destination then
        local safe=self:ClampCommandPoint(destination,self:GetShipFormationRadius(ship)*1.05)
        if not safe then return false end
        moveWaypoint=self:GetOrCreateMoveWaypoint(ship)
        if not objectValid(moveWaypoint) then return false end
        destination=copyVec(safe)
    end
ship:clearOrders()
    local given
    local arrivalDistance
    local pursuit=false
    if destination then
        -- Pure movement goal (RETREAT, REGROUP, LURE): a single waypoint on a
        -- freshly cleared order list. There is no FSO SEXP for a coordinate
        -- fly-to (only ai-fly-to-ship exists), so ORDER_WAYPOINTS_ONCE against
        -- the pooled waypoint is the only engine primitive that moves a hull to
        -- a point. clearOrders above removes any prior attack target, which is
        -- what keeps the transit from engaging.
        moveWaypoint.Position=copyVec(destination)
        given=ship:giveOrder(ORDER_WAYPOINTS_ONCE,moveWaypoint,nil,ATTACK_ORDER_PRIORITY)
        arrivalDistance=900
    elseif guard and (mission=="RETREAT" or mission=="LURE") then
        arrivalDistance=math.ceil((target.Radius or 0)+(ship.Radius or 0)+1400)
        -- giveOrder(ORDER_FLY_TO) leaves float_data=0 in FSO 26.0.1.
        -- The SEXP contract exposes a real, safe arrival distance instead.
        if not ship.Name:find('["\\%c]') and not target.Name:find('["\\%c]') then
            given=mn.runSEXP(string.format('(add-ship-goal "%s" (ai-fly-to-ship "%s" 90 %d))',ship.Name,target.Name,arrivalDistance))
        end
    elseif guard then given=ship:giveOrder(ORDER_GUARD,target,nil,.84)
    elseif self:IsPursuitPair(ship,target,subsystem) then
        arrivalDistance=900
        pursuit=self:IssuePursuitOrder(ship,target,ATTACK_ORDER_PRIORITY,arrivalDistance)
        given=pursuit and true or false
    else given=ship:giveOrder(ORDER_ATTACK,target,subsystem,ATTACK_ORDER_PRIORITY) end
    -- FSO returns false/nil when a goal cannot be installed (for example when
    -- the ship is being deleted or the target became invalid between the check
    -- and the call). Do not cache a successful-looking assignment in that case;
    -- the next strategic tick must be allowed to retry it.
    if given~=true then
        self.AIOrderState[sig]=nil
        if pursuit then self:DropPursuit(sig) end
        self:RecordAIOrderTelemetry(kind,mission,"failed",given)
        return false
    end
    local same=previous and previous.targetSignature==tsig and previous.mission==mission
    self.AIOrderState[sig]=same and previous or {targetSignature=tsig,label=label,mission=mission,assignedAt=now or mn.getMissionTime()}
    self.AIOrderState[sig].installedAt=now or mn.getMissionTime()
    self.AIOrderState[sig].arrivalDistance=arrivalDistance
    self.AIOrderState[sig].destination=destination
    self.AIOrderState[sig].subsystemIndex=subsystemIndex
    -- A pursuit is a live move goal, not a single chase assignment: the
    -- refresh pass re-anchors it while the pair stays valid.
    self.AIOrderState[sig].pursuitAt=pursuit and (now or mn.getMissionTime()) or nil
    if not pursuit then self:DropPursuit(sig) end
    self:RecordAITransition(ship,previous,self.AIOrderState[sig],same and "ORDER_REISSUED" or "ORDER_ACCEPTED",now)
    self:RecordAIOrderTelemetry(kind,mission,"success",given)
    return true
end

-- Re-anchor every live pursuit so the move goal never expires into an idle
-- capital. Runs on its own cadence, independent of StrategicOrderInterval.
function RTS:RefreshAIPursuit(now)
    local pursuit=self.AIPursuit
    if not pursuit then return end
    local interval=(self.Config.AI.Doctrine or {}).PursuitRefreshInterval or PURSUIT_REFRESH_SECONDS
    for sig,entry in pairs(pursuit) do
        local state=self.AIOrderState and self.AIOrderState[sig]
        local ship=self:FindShipBySignature(sig)
        local target=state and self:FindShipBySignature(state.targetSignature)
        if not state or not state.pursuitAt or state.targetSignature~=entry.targetSignature
            or not shipAlive(ship) or not self:IsAutomaticAIUnit(ship)
            or not shipAlive(target) or not self:AreEnemies(ship,target) then
            pursuit[sig]=nil
        elseif now-(entry.anchoredAt or 0)>=interval then
            if self:IssuePursuitOrder(ship,target,ATTACK_ORDER_PRIORITY,entry.arrivalDistance) then
                entry.anchoredAt=now; state.pursuitAt=now
            else
                state.pursuitAt=nil; pursuit[sig]=nil
            end
        end
    end
end

-- ORDER_ATTACK_ANY runs the same class-type-filtered target search, so a
-- capital under the engage (T) order never acquires a fighter and idles. Give
-- it a moving anchor while it has no usable native target, and hand the goal
-- straight back to the engine as soon as it does.
function RTS:RefreshEngagePursuit(now)
    if not self.UserOrders then return end
    local interval=(self.Config.AI.Doctrine or {}).PursuitRefreshInterval or PURSUIT_REFRESH_SECONDS
    local radius=(self.Config.AI.Doctrine or {}).EngagePursuitRadius or 12000
    for sig,order in pairs(self.UserOrders) do
        if order.kind~="engage" then
            if self.EngagePursuit then self.EngagePursuit[sig]=nil end
        else
            local ship=self:FindShipBySignature(sig)
            local entry=self.EngagePursuit and self.EngagePursuit[sig]
            local native=shipValid(ship) and ship.Target or nil
            if not self:IsHeavyAttackHull(ship) then
                if entry then self.EngagePursuit[sig]=nil end
            elseif objectValid(native) then
                -- Engine has acquired something; stop overriding its goal.
                if entry then self.EngagePursuit[sig]=nil; self:EngageShip(ship,0.95) end
            else
                self.EngagePursuit=self.EngagePursuit or {}
                entry=entry or {}; self.EngagePursuit[sig]=entry
                if now-(entry.anchoredAt or 0)>=interval then
                    local victim=self:FindUnitLocalThreat(ship,radius)
                    if self:IsPursuitPair(ship,victim) and self:IssuePursuitOrder(ship,victim,ATTACK_ORDER_PRIORITY) then
                        entry.anchoredAt=now; entry.targetSignature=victim:getSignature()
                    elseif entry.targetSignature~=nil then
                        self.EngagePursuit[sig]=nil; self:EngageShip(ship,0.95)
                    else entry.anchoredAt=now end
                end
            end
        end
    end
end

function RTS:UpdateAIPursuitGoals(now)
    local interval=(self.Config.AI.Doctrine or {}).PursuitRefreshInterval or PURSUIT_REFRESH_SECONDS
    if now-(self.NextAIPursuitRefresh or 0)<interval then return end
    self.NextAIPursuitRefresh=now+interval
    self:RefreshAIPursuit(now)
    self:RefreshEngagePursuit(now)
end

-- 'armed' in the profile is false for any hull whose only mounts are destroyed
-- turrets, so a capital that lost its turrets looked identical to a ship that
-- is out of missiles. Returns carries (any ammo-bearing bank survives) and
-- loaded (at least one of those banks still has rounds).
function RTS:GetShipOrdnance(ship)
    if not shipValid(ship) then return false,false end
    local function scan(list,carries,loaded)
        for i=1,#list do
            local bank=list[i]
            if objectValid(bank) and (bank.AmmoMax or 0)>0 then
                carries=true
                if (bank.AmmoLeft or 0)>0 then loaded=true end
            end
        end
        return carries,loaded
    end
    local function mount(field,carries,loaded)
        for i=1,#ship do
            local turret=ship[i]
            if objectValid(turret) and not turret.TurretLocked then
                carries,loaded=scan(turret[field],carries,loaded)
            end
        end
        return carries,loaded
    end
    local carries,loaded=scan(ship.SecondaryBanks,false,false)
    carries,loaded=mount("SecondaryBanks",carries,loaded)
    if not carries then
        carries,loaded=scan(ship.PrimaryBanks,false,false)
        carries,loaded=mount("PrimaryBanks",carries,loaded)
    end
    return carries,loaded
end

-- Beam mounts need a real reach. FSO does not expose beam weapon range to
-- scripting at all, so GetStrategicWeapons used to record r=0 for every beam,
-- and four call sites inherited that zero:
--   GetFactionThreats  - a beam attacker was never "inRange" of a station
--                        except inside the station's own model radius, leaving a
--                        3-5 km blind band at the outer edge of the fight;
--   ScoreAIObjective   - eta charged as (d - range) at zero range;
--   AIRoleMatch        - heavies refused every intercept past 1,800 m;
--   GetFleetLocalThreat- no ship ever saw a beam platform as a threat at range.
-- The measured consequence was that escorts/heavies/juggernauts, the only hulls
-- with sustained DPS against a 132,600 HP station, never closed: p05 approach
-- 9,667 m and a minimum of 4,067 m, while missile-armed fighters reached 1,251 m.
--
-- A nominal per-role reach, raised by evidence from real hits, restores the
-- engagement length the threat model needs. Learned evidence can only raise the
-- nominal value, never lower it, so a bad sample cannot hide a real reach.
function RTS:GetBeamNominalRange(ship)
    if not shipValid(ship) then return 0 end
    local doctrine=(self.Config.AI and self.Config.AI.Doctrine) or {}
    if doctrine.BeamRangeEnabled==false then return 0 end
    local className=ship.Class and ship.Class.Name or nil
    if className==nil then return doctrine.BeamNominalRange or 0 end
    self.BeamRangeByClass=self.BeamRangeByClass or {}
    local cached=self.BeamRangeByClass[className]
    if cached~=nil then return cached end
    -- Classify from PURE CONFIG DATA. Do not call GetShipRole or
    -- IsCommandStation here: GetStrategicWeapons runs this once per weapon per
    -- AI pass, and routing that through the role/command-station helpers made
    -- the engine hard-crash with no Lua error at all, at mission teardown. A
    -- plain scan of the roster cannot recurse and cannot touch an engine
    -- object, which is all this needs.
    local role=nil
    for _,option in ipairs(self.Config.ProductionClasses or {}) do
        if option.class==className then role=option.role; break end
    end
    if role==nil then
        local cfg=self.Config
        if className==cfg.CarrierShip or className==cfg.EnemyCommandShip
            or className==cfg.ThirdCommandShip or className==cfg.ObserverShip then role="station" end
    end
    local byRole=doctrine.BeamRangesByRole or {}
    local value=byRole[role]
    if type(value)~="number" then value=doctrine.BeamNominalRange or 0 end
    local peak=doctrine.BeamRangeMax or 12000
    if value>peak then value=peak end
    self.BeamRangeByClass[className]=value
    return value
end

function RTS:GetBeamMountRange(ship)
    -- Nominal only, and deliberately so. An earlier version kept a running
    -- maximum learned from real station hits and read it back through
    -- owner:getSignature() here, where owner is a TURRET SUBSYSTEM for turret
    -- mounts. That call hard-crashes the engine with no Lua error and no output
    -- at all, at mission teardown - it ran the entire match cleanly and then
    -- died before writing engine-result.json. The learned component was the
    -- optional half of the design anyway: a platform that never arrives never
    -- lands a hit, so it can never learn, and the nominal per-role value is
    -- what actually restores the engagement length the threat model needs.
    local doctrine=(self.Config.AI and self.Config.AI.Doctrine) or {}
    if doctrine.BeamRangeEnabled==false then return 0 end
    local value=self:GetBeamNominalRange(ship)
    local peak=doctrine.BeamRangeMax or 12000
    if value>peak then value=peak end
    return value
end

function RTS:GetStrategicWeapons(ship)
    local mounts={}
    local armed=false; local profileBeam=false; local maximumRange=0; local firepower=0
    local function addBankList(owner,banks,position,includeMount)
        local reach=0; local mountBeam=false
        for i=1,#banks do
            local bank=banks[i]; local weapon=bank.WeaponClass
            if includeMount and objectValid(bank) and objectValid(weapon) and ((bank.AmmoMax or 0)<=0 or (bank.AmmoLeft or 0)>0) then
                armed=true
                local beam=weapon:isBeam()
                local cycle=math.max(.25,weapon.FireWait or 1)
                local damage=math.max(1,weapon.Damage or 0)
                if beam then damage=damage*math.max(.1,weapon.BeamLife or 1); cycle=cycle+(weapon.BeamWarmup or 0)+(weapon.BeamLife or 0) end
                firepower=firepower+damage/cycle*(owner==ship and 1 or owner.FireRateMultiplier)
                profileBeam=profileBeam or beam
                if includeMount then
                    -- Range is the projectile table cap. FSO's separate beam
                    -- range is not exposed here: retain its current target as
                    -- intent evidence and use actual hits for range evidence.
                    local r=weapon.Range or 0
                    -- Pass ship, never owner: owner is the turret subsystem for
                    -- turret mounts, and resolving a role from a turret would
                    -- dereference a nil turret.Class.Name.
                    if beam then mountBeam=true; r=self:GetBeamMountRange(ship) else r=math.min(r,(weapon.Speed or 0)*(weapon.LifeMax or 0)) end
                    if self:IsFiniteNumber(r) then reach=math.max(reach,r) end
                end
            end
        end
        if includeMount and (reach>0 or mountBeam) then
            mounts[#mounts+1]={range=reach,position=position,target=owner.Target,beam=mountBeam}
            maximumRange=math.max(maximumRange,reach)
        end
    end
    local function addOwner(owner,position,includeMount)
        addBankList(owner,owner.PrimaryBanks,position,includeMount)
        addBankList(owner,owner.SecondaryBanks,position,includeMount)
    end
    -- There is no 'weapons-locked' flag in the engine (the real names are
    -- 'primaries-locked' and 'secondaries-locked', plus 'lock-all-turrets').
    -- Asking for a name that does not exist logs a warning on every call and
    -- always returns false, which made this guard dead code. The per-bank tests
    -- below already exclude each locked bank, so the outer test only has to
    -- skip a ship with nothing armed at all.
    local primariesLocked = ship:getFlag('primaries-locked')
    local secondariesLocked = ship:getFlag('secondaries-locked')
    if not (primariesLocked and secondariesLocked) then
        addBankList(ship,ship.PrimaryBanks,ship.Position,not primariesLocked)
        addBankList(ship,ship.SecondaryBanks,ship.Position,not secondariesLocked)
    end
    for i=1,#ship do
        local turret=ship[i]
        if objectValid(turret) and not turret.TurretLocked then
            -- A destroyed or locked turret cannot contribute combat strength.
            local includeMount=turret.HitpointsMax<=0 or turret.HitpointsLeft>0
            addOwner(turret,includeMount and turret.WorldPosition or nil,includeMount)
        end
    end
    return mounts,armed,profileBeam,maximumRange,firepower
end

function RTS:RecordStationBeamHit(target,attacker,now,source)
    local stationSig=target:getSignature()
    local attackerSig=attacker:getSignature()
    self.StationBeamHits=self.StationBeamHits or {}
    self.StationBeamHits[stationSig]=self.StationBeamHits[stationSig] or {}
    self.StationBeamHits[stationSig][attackerSig]=now
    self.StationBeamHitSeen=self.StationBeamHitSeen or {}
    self.StationBeamHitSeen[stationSig]=self.StationBeamHitSeen[stationSig] or {}
    if not self.StationBeamHitSeen[stationSig][attackerSig] then
        self.StationBeamHitSeen[stationSig][attackerSig]=true
        if self.CombatTelemetryEnabled then
            self:EmitAIEvent("STATION_BEAM_HIT",{targetName=target.Name,targetFaction=self:GetFactionKey(target),
                attackerSignature=attackerSig,attackerName=attacker.Name,
                attackerClass=attacker.Class and attacker.Class.Name or "UNKNOWN",
                attackerFaction=self:GetFactionKey(attacker),source=source or "UNKNOWN",
                distance=attacker.Position:getDistance(target.Position)},now)
        end
    end
end

function RTS:RegisterStationBeamHitHook()
    if self.StationBeamHookRegistered then return end
    local ok=engine.addHook("On Beam Collision",function()
        if not self.Enabled or self.SetupActive or self.PostBattleActive then return end
        local target=hv["Self"]
        local beam=hv["Beam"]
        if not objectValid(target) or target:getBreedName()~="Ship" or not self:IsCommandStation(target)
            or not objectValid(beam) then return end
        local attacker=beam.ParentShip
        if shipValid(attacker) and self:AreEnemies(target,attacker) then
            self:RecordStationBeamHit(target,attacker,mn.getMissionTime(),"ON_BEAM_COLLISION")
        end
    end)
    self.StationBeamHookRegistered=ok==true
    if not self.StationBeamHookRegistered then self:Log("Station beam tracking unavailable: On Beam Collision hook registration failed") end
end

function RTS:ObserveStationBeamHits(now)
    -- Beam contacts arrive through On Beam Collision. Only age the small
    -- station/attacker cache periodically; never scan every live beam per frame.
    if now<(self.NextStationBeamCleanup or 0) then return end
    self.NextStationBeamCleanup=now+1
    self.StationBeamHits=self.StationBeamHits or {}
    local memory=(self.Config.AI.Doctrine or {}).BeamHitMemorySeconds or 6
    for stationSig,hits in pairs(self.StationBeamHits) do
        for attackerSig,time in pairs(hits) do if now-time>memory then hits[attackerSig]=nil end end
        if next(hits)==nil then self.StationBeamHits[stationSig]=nil end
    end
end

function RTS:BuildStrategicThreatSnapshot()
    local snapshot={}
    self:EachShip(function(ship)
        if ship.Name~=self.Config.ObserverShip and shipAlive(ship) then
            local mounts,armed,beam,reach,power=self:GetStrategicWeapons(ship)
            snapshot[#snapshot+1]={ship=ship,mounts=mounts,armed=armed,profileBeam=beam,maxRange=reach,firepower=power}
        end
    end)
    return snapshot
end

function RTS:GetFactionThreats(kind,station,radius,lurePursuers)
    local threats={}; local total=0; local urgent=false
    local stationRadius=station.Radius or (station.Class.Model and station.Class.Model.Radius) or 0
    for _,row in ipairs(self.StrategicThreatSnapshot or self:BuildStrategicThreatSnapshot()) do
        local other=row.ship
        -- Static defenses are not station threats. A sentry sits on a fixed
        -- point inside Sentries.ControlRadius of its OWN base, and the bases
        -- are BaseDistances (9000 m) apart, so the closest an enemy sentry can
        -- stand to our base is 5000 m: inside ThreatRadius (6500). It then
        -- entered the threat list at full GetCombatValue, which set
        -- threat.attacking on a single recorded beam hit and tripped the
        -- emergency gate in UpdateFactionStrategicPlan (the `local emergency=`
        -- loop below) - cap jumps from MaxDefenseFleetFraction (0.50) to
        -- EmergencyDefenseFleetFraction (0.70) of the whole fleet and every
        -- group reacts. A turret that cannot manoeuvre, cannot be intercepted
        -- and cannot be chased should not drive a fleet-wide recall; its guns
        -- are already answered by the station's own defenses. It is still
        -- counted as front DEFENSE in UpdateFactionStrategicPlan, which is the
        -- side where a static gun genuinely matters.
        if shipAlive(other) and row.armed and not self:IsStaticDefense(other) and self:AreEnemies(station,other) then
            local d=other.Position:getDistance(station.Position)
            local inRange=false; local attacking=false
            local shipTargetingStation=objectValid(other.Target) and other.Target:getSignature()==station:getSignature()
            local targetingStation=shipTargetingStation
            local beamCapable=false
            local hits=(self.StationBeamHits or {})[station:getSignature()]
            local hitTime=hits and hits[other:getSignature()]
            local memory=(self.Config.AI.Doctrine or {}).BeamHitMemorySeconds or 6
            if hitTime and mn.getMissionTime()-hitTime<=memory then inRange=true; attacking=true end
            for _,mount in ipairs(row.mounts) do
                beamCapable=beamCapable or mount.beam==true
                if objectValid(mount.target) and mount.target:getSignature()==station:getSignature() then targetingStation=true end
                if mount.position:getDistance(station.Position)<=mount.range+stationRadius then
                    inRange=true
                    if objectValid(mount.target) and mount.target:getSignature()==station:getSignature() then attacking=true end
                end
            end
            local homeDefenseEligible=inRange or d<=radius+stationRadius
            -- A mobile capital that has explicitly selected this station is
            -- a bomber-suppression target even before it enters the local
            -- screen radius. Keep it out of ordinary fighter screening until
            -- it is nearby or its weapons can reach the station.
            local capitalIntent=not self:IsCommandStation(other) and self:IsCapitalTarget(other)
                and beamCapable and shipTargetingStation
            if inRange or (not self:IsCommandStation(other) and d<=radius+stationRadius) or capitalIntent then
                local v=row.profile and row.profile.value or self:GetCombatValue(other,row.firepower)
                local big=self:IsCapitalTarget(other); local role=self:GetShipRole(other)
                local immediate=attacking or (inRange and (big or role=="bomber"))
                threats[#threats+1]={ship=other,value=v,distance=d,capital=big,urgent=immediate,attacking=attacking,
                    targetingStation=targetingStation,homeDefenseEligible=homeDefenseEligible,
                    pursuingLure=(lurePursuers or {})[other:getSignature()]==true}
                total=total+v; urgent=urgent or immediate
            end
        end
    end
    table.sort(threats,function(a,b)
        if a.urgent~=b.urgent then return a.urgent end
        if a.attacking~=b.attacking then return a.attacking end
        if a.value~=b.value then return a.value>b.value end
        return a.ship:getSignature()<b.ship:getSignature()
    end)
    return threats,total,urgent
end

function RTS:ChooseAIFeintTarget(kind,primary,radius)
    if not shipValid(primary) then return primary end
    local station=self:GetFactionCommandShip(kind)
    local best,bestScore=nil,math.huge
    for _,row in ipairs(self:GetAISpatialCandidates(primary.Position,radius)) do
        local target=row.ship
        if shipAlive(target) and target.Name~=self.Config.ObserverShip
            and not self:IsCommandStation(target) and self:AreEnemies(station,target) then
            local role=self:GetShipRole(target)
            if role=="fighter" then
                local targeters=(self.AITargetedBy or {})[target:getSignature()]
                local alreadyEngaged=targeters and targeters[kind] and next(targeters[kind])~=nil
                local distanceToBase=target.Position:getDistance(primary.Position)
                if not alreadyEngaged and distanceToBase<=radius then
                    local faction=self:GetFactionKey(target)
                    local score=distanceToBase+self:GetStrategicUnitValue(target,faction)*0.05
                    if best==nil or score<bestScore
                        or (score==bestScore and target:getSignature()<best:getSignature()) then
                        best=target; bestScore=score
                    end
                end
            end
        end
    end
    -- Attack an unengaged screen target to draw defenders away while bombers
    -- keep the base strike. If no screen target is available, pressure the base.
    return best or primary
end

-- HEAVY ASSAULT OBJECTIVE LOCK. Default OFF: with both doctrine flags unset
-- this returns its inputs untouched and UpdateFactionStrategicPlan behaves
-- exactly as it shipped.
--
-- Why it exists, and why it lives here rather than in ChooseAIOperationTarget.
-- ChooseAIOperationTarget (fs2rts_operations.lua:192) scores a candidate with
-- `rank*100000 - distance - covered`, where a static defence is rank 3 for a
-- strike group and the objective of the operation itself - the enemy command station,
-- a capital target by name - is rank 1. The 200,000 gap cannot be closed by
-- distance, which is bounded by ~(station radius + 6000) for every candidate,
-- so every sentry in the defender ring outranks the station for a capital
-- unconditionally. Measured on capgate-20261001, over 2906 heavy PRIMARY
-- decisions: 44.8% targeted a sentry, 16.4% the station, and
-- localThreatSignature == target occurred 0 times with hardLocalThreat false in
-- 100% - because ApplyAIOperationOrder runs at the END of the per-group loop,
-- after every local-threat decision, and returns with context.locked=true. The
-- heavy group was never choosing; it was being told.
--
-- This is a veto on the value operations returns, deliberately placed at the
-- only seam this file owns. Two separate flags, because the sentry bucket and
-- the mobile bucket are different problems with different evidence.
function RTS:ApplyAssaultObjectiveLock(g,target,mission,context)
    local doctrine=(self.Config.AI and self.Config.AI.Doctrine) or {}
    local lockStatic=doctrine.AssaultStaticDefenceLock==true
    local lockMobile=doctrine.AssaultMobileThreatLock==true
    g.assaultLock=nil
    if not (lockStatic or lockMobile) then return target,mission end
    -- Bombers are excluded on purpose and not by oversight: turret suppression
    -- is what a bomber wing is for, and GetAISuppressionSubsystem already
    -- reserves SIEGE_TURRET_TARGET/SUBSYSTEM_SUPPRESSION for them. Escorts are
    -- excluded because Doctrine.AssaultEscortWings already gives the strike
    -- anchor their job, and a mixed wing must not be split by this gate.
    if g.role~='capital' and g.role~='heavy' and g.role~='juggernaut' then return target,mission end
    if mission~='PRIMARY' then return target,mission end
    local op=g.operation
    if not op or not shipAlive(op.target) or not self:IsCommandStation(op.target) then return target,mission end
    -- Already pressing the station, or already the station: nothing to veto.
    if not shipValid(target) or target==op.target then return target,mission end
    local lead=g.units and g.units[1]
    if not shipAlive(lead) or not self:AreEnemies(lead,target) then return target,mission end
    local isStatic=self:IsStaticDefense(target)
    if isStatic and not lockStatic then return target,mission end
    if not isStatic and not lockMobile then return target,mission end
    local bound,corridor
    if isStatic then
        bound=doctrine.AssaultStaticDefenceThreatDistance or 0
        corridor=doctrine.AssaultStaticDefenceCorridorWidth or 0
    else
        bound=doctrine.AssaultMobileThreatDistance or 0
        corridor=doctrine.AssaultMobileThreatCorridorWidth or 0
    end
    -- REACTIVE. The diverted hull must be the local threat of this group - the
    -- hostile the planner already identified as pressing it - and no member may
    -- have fallen further than the bound from it. Identity is required, not
    -- just proximity: g.hardLocalThreat is a statement about SOME local threat,
    -- so honouring it for an arbitrary target would re-admit exactly the
    -- behaviour being gated.
    local reactive=false; local threatDistance=-1
    if shipValid(g.localThreat) and g.localThreat:getSignature()==target:getSignature() then
        threatDistance=math.huge
        for _,member in ipairs(g.units or {}) do
            if shipAlive(member) and member.Position then
                threatDistance=math.min(threatDistance,member.Position:getDistance(target.Position))
            end
        end
        if threatDistance==math.huge then threatDistance=-1 end
        reactive=threatDistance>=0 and threatDistance<=bound
    end
    -- CORRIDOR. Disabled when width is 0, which is the shipped default, because
    -- it is measurably vacuous: over the 1301 sentry diversions the
    -- perpendicular offset from the centroid->station axis is p50 689 m and
    -- p90 2008 m, so a 3000 m corridor admits 97.5% of them and 5000 m admits
    -- all of them. That is structural - sentry placement is capped at station
    -- radius + 4 km - so no width that still admits a sentry blocking the lane
    -- can exclude one that is not.
    local inCorridor=false; local corridorOffset=-1
    if corridor>0 then
        local x,z,count=0,0,0
        for _,member in ipairs(g.units or {}) do
            if shipAlive(member) and member.Position then
                x=x+member.Position.x; z=z+member.Position.z; count=count+1
            end
        end
        if count>0 then
            x=x/count; z=z/count
            local ax,az=op.target.Position.x,op.target.Position.z
            local dx,dz=ax-x,az-z
            local length=math.sqrt(dx*dx+dz*dz)
            if length>1 then
                dx, dz = dx/length, dz/length
                local along=(target.Position.x-x)*dx+(target.Position.z-z)*dz
                corridorOffset=math.abs((target.Position.x-x)*dz-(target.Position.z-z)*dx)
                inCorridor=along>0 and along<length and corridorOffset<=corridor
            end
        end
    end
    if reactive or inCorridor then return target,mission end
    -- Hold the station. Deliberately not touching context.locked: the
    -- operation set it, and the retention gate in CommitAIGroup reads it, so the
    -- group stays committed to the front for the whole tick instead of
    -- re-deriving the same sentry on the next StrategicOrderInterval.
    g.assaultLock={held=op.target:getSignature(),rejected=target:getSignature(),
        staticDefence=isStatic,threatDistance=threatDistance,corridorOffset=corridorOffset}
    context.reason='ASSAULT_OBJECTIVE_HELD'
    return op.target,mission
end

function RTS:UpdateFactionStrategicPlan(kind,now,force)
    local station=self:GetFactionCommandShip(kind); if not shipValid(station) then return end
    if not self.AIStats then self:ResetCoordinatedAI() end
    local ownsSnapshot=self.StrategicThreatSnapshot==nil
    if ownsSnapshot then self.StrategicThreatSnapshot=self:BuildStrategicThreatSnapshot(); self:BuildAIContext(self.StrategicThreatSnapshot) end
    local primary=self:GetStablePrimaryTarget(kind)
    local doctrine=self.Config.AI.Doctrine or {}; local threatRadius=doctrine.ThreatRadius or self.Config.AI.StationDefenseRadius or 6000
    local lurePursuers=self:GetActiveLurePursuers(kind,now)
    local threats,threatValue,urgent=self:GetFactionThreats(kind,station,threatRadius,lurePursuers)
    self.AIProductionNeeds=self.AIProductionNeeds or {}
    local demand={fighter=0,bomber=0,escort=0}
    for _,threat in ipairs(threats) do
        local role=self:GetShipRole(threat.ship)
        local counter=threat.capital and "bomber" or (role=="bomber" and "fighter" or "escort")
        demand[counter]=demand[counter]+.5*threat.value/math.max(1,threatValue)
    end
    self.AIProductionNeeds[kind]=demand
    local groups={}; local byGroup={}; local totalValue=0; local screenEligibleValue=0
    local servicingCount=0; local playerControlledCount=0
    local ownedCount=0; local plannedCount=0
    self:EachShip(function(ship)
        if shipAlive(ship) and self:GetFactionKey(ship)==kind and ship:getSignature()~=station:getSignature() and ship.Name~=self.Config.ObserverShip and not self:IsStaticDefense(ship) then
            local sig=ship:getSignature()
            -- Ships in fleet service hold no strategic order by design, so they
            -- are counted apart from genuinely unordered ships. Both are tallied
            -- here because this is the only place that knows why a ship was
            -- left out of every group.
            ownedCount=ownedCount+1
            if self.FleetServices and self.FleetServices[sig] then
                servicingCount=servicingCount+1
            elseif kind=="BLUE" and (not self.AutoPlayerMode or self.PossessedSignature==sig or self.UserOrders[sig]~=nil) then
                playerControlledCount=playerControlledCount+1
            else
                local entry=self:GetAIRosterEntry(kind,ship.Class.Name); local role=entry and entry.role or self:GetShipRole(ship); local profile=self:AIProfile(ship); local v=profile.value
                local wing=self:GetLogicalWing(ship)
                local id=(wing and wing.id or tostring(sig))..":"..role
                local g=byGroup[id]
                if g==nil then g={id=id,units={},role=role,value=0,screen=false,committed=false,assaultReserved=false}; byGroup[id]=g; groups[#groups+1]=g end
                g.units[#g.units+1]=ship; g.value=g.value+v; totalValue=totalValue+v
                plannedCount=plannedCount+1
                g.armed=g.armed or profile.armed
                local carries,loaded=self:GetShipOrdnance(ship)
                g.ordnance=g.ordnance or carries
                g.ordnanceLoaded=g.ordnanceLoaded or loaded
                local prev=self.AIOrderState[sig]
                g.screen=g.screen or (prev~=nil and (prev.mission=="SCREEN" or prev.mission=="TRAP"))
                if role=="fighter" or role=="escort" then screenEligibleValue=screenEligibleValue+v end
            end
        end
    end)
-- ASSAULT GROUP POOLING, off unless Station.AI.Doctrine.PoolAssaultGroupsEnabled.
    -- A group's identity is (logical wing or ship signature)..role (line 687) and
    -- nothing in the planner ever merges two of them, so the simultaneous group
    -- count is simply the surviving wing count and grows with the purchase rate.
    -- Measured: 4.0 groups/faction at group_value_hhi 0.420 in the broken batch
    -- against 2.1 at 0.677 in the baseline, with 3.6x the order churn. Pooling
    -- folds wings that already share a role, a front and a mission - and are
    -- already next to each other - into one group, so one intent is one order.
    groups=self:PoolAIAssaultGroups(groups)
    self:PrepareAIGroups(groups,station,primary,now)
    self:AssignAIAssaultFronts(kind,groups,primary)
    for _,g in ipairs(groups) do
        local lead=g.units[1]
        local previous=lead and self.AIOrderState[lead:getSignature()] or nil
        if previous and shipAlive(g.primary) and (previous.mission=="PRIMARY" or previous.mission=="REGROUP")
            and (previous.assaultPrimarySignature==nil or previous.assaultPrimarySignature==g.primary:getSignature()) then
            g.committed=now-(previous.assaultStartedAt or previous.assignedAt or now)>=(doctrine.AssaultCommitSeconds or 25)
                or lead.Position:getDistance(g.primary.Position)<=(doctrine.AssaultCommitDistance or 5200)
        end
        if previous and now<(previous.feintUntil or 0) then
            g.probing=true; g.feint=true; g.feintUntil=previous.feintUntil
            g.feintTargetSignature=previous.feintTargetSignature
                or (previous.mission=="FEINT" and previous.targetSignature or nil)
        end
        if previous and previous.mission=="LURE" and now<(previous.lureUntil or 0) then
            g.luring=true; g.lureUntil=previous.lureUntil
            g.target=station; g.mission="LURE"
        end
    end
    -- A strategic primary is not a substitute for local combat awareness.
    -- When opposing mobile units meet in the lane between bases, mark the
    -- nearest hostile as an intercept candidate. Station-defense assignments
    -- below take priority; this candidate is used only by groups left over.
    local localRadius=(self.Config.AI and self.Config.AI.LocalEngageRadius) or 0
    if localRadius>0 then
        for _,g in ipairs(groups) do
            g.localThreat=self:ChooseAILocalThreat(g)
            g.localThreatSource=shipValid(g.localThreat) and "LOCAL_RADIUS" or nil
        end
    end
    local stationPct=station.HitpointsMax>0 and station.HitpointsLeft/station.HitpointsMax or 1; local critical=stationPct<=(doctrine.CriticalStationHullFraction or .35)
    -- Range capability deserves a response, but is not evidence that the
    -- entire fleet must abandon its offensive objective. Reserve full recall
    -- for active station attacks, close heavy threats, or critical base hull.
    local emergency=critical and #threats>0
    for _,threat in ipairs(threats) do
        if threat.attacking or (threat.urgent and threat.distance<=(station.Radius or 0)+(doctrine.HardEngageRadius or 1800)) then
            emergency=true; break
        end
    end
    -- Production may run before the next strategic frame; keep only this
    -- fresh signal so it can spend on a fast counter instead of waiting for a capital.
    self.AIProductionEmergency=self.AIProductionEmergency or {}
    self.AIProductionEmergency[kind]={emergency=emergency,time=now}
    local posture=critical and #threats>0 and "CRITICAL_DEFENSE" or urgent and "DEFENSIVE" or "BALANCED"
    local cap=(critical and emergency and 1 or emergency and (doctrine.EmergencyDefenseFleetFraction or .7) or (doctrine.MaxDefenseFleetFraction or .5))*totalValue
    local reserve=math.min((doctrine.ScreenReserveFraction or .38)*screenEligibleValue,cap)
    -- Do not let routine local contacts consume the entire faction. Reserve
    -- an assault element for the selected enemy station so the strategic
    -- objective continues to make progress while the rest screens/intercepts.
    local assaultFraction=clamp(doctrine.AssaultFleetFraction or .30,0,.80)
    local assaultReserveValue=totalValue*assaultFraction
    local assaultReservedValue=0
    local function assaultRole(g)
        return g.role=="capital" or g.role=="heavy" or g.role=="juggernaut" or g.role=="bomber"
    end
    -- Bomber wings are strike assets. Keep them assigned to the strategic
    -- capital/base target through routine fighter contacts; close or targeted
    -- threats are handled by the bomber-specific self-defense test below.
    for _,g in ipairs(groups) do
        if g.role=="bomber" then
            g.assaultReserved=true; assaultReservedValue=assaultReservedValue+g.value
        end
    end
    for _,g in ipairs(groups) do
        if assaultReservedValue<assaultReserveValue and assaultRole(g) and not g.assaultReserved then
            g.assaultReserved=true; assaultReservedValue=assaultReservedValue+g.value
        end
    end
    -- Escorts were never assault-reserved by the loop above: assaultRole covers
    -- capital/heavy/juggernaut/bomber only, and an escort is screen-eligible and
    -- otherwise defaults to target=station with the SCREEN mission. That left
    -- the bulk of the fleet's beam DPS with no base mission to accept at all.
    -- Reserve a bounded number of escort wings for the strike, excluding groups
    -- already screening so the release is one-way and the wings cannot oscillate
    -- between screen and strike every strategic tick.
    local escortWings=math.floor(doctrine.AssaultEscortWings or 0)
    if escortWings>0 then
        local taken=0
        for _,g in ipairs(groups) do
            if taken>=escortWings then break end
            if g.role=="escort" and not g.assaultReserved and not g.screen and g.target==nil and not emergency then
                g.assaultReserved=true
                assaultReservedValue=assaultReservedValue+g.value
                taken=taken+1
            end
        end
    end
    -- Do not fill a short assault reserve with arbitrary fighter wings. A
    -- smaller capital/heavy/bomber push is preferable to suppressing the
    -- local interception behavior of groups meant to screen the battle lane.
    local dv=0
    local threatBySignature={}
    for _,threat in ipairs(threats) do threatBySignature[threat.ship:getSignature()]=threat end
    local retainedCoverage={}
    local defenseCommitSeconds=doctrine.DefenseTargetCommitmentSeconds or 18
    local defenseReleaseRadius=threatRadius+(doctrine.DefenderReleaseDistance or 1500)
    -- Keep a station defender on its current hostile through short gaps in the
    -- threat candidate list. This prevents the planner's greedy reassignment
    -- from making wings bounce between nearby attackers as they cross radius
    -- or weapon-eligibility boundaries. Active base emergencies still override.
    for _,g in ipairs(groups) do
        local lead=g.units[1]
        local prior=lead and self.AIOrderState[lead:getSignature()] or nil
        if prior and (prior.mission=="SCREEN" or prior.mission=="TRAP") and prior.protected==station:getSignature() then
            local oldTarget=self:FindShipBySignature(prior.targetSignature)
            local distanceToStation=shipValid(oldTarget) and oldTarget.Position:getDistance(station.Position) or math.huge
            local age=now-(prior.assignedAt or now)
            if not emergency and age<defenseCommitSeconds and shipAlive(oldTarget)
                and self:AreEnemies(lead,oldTarget) and distanceToStation<=defenseReleaseRadius then
                local priorThreat=threatBySignature[prior.targetSignature]
                local telemetry={targetSignature=prior.targetSignature,age=age,
                    targetDistance=distanceToStation,releaseRadius=defenseReleaseRadius,
                    candidatePresent=priorThreat~=nil,retained=true}
                g.defenseRetention=telemetry
                g.target=oldTarget
                g.trapping=priorThreat~=nil and priorThreat.pursuingLure==true
                g.mission=g.trapping and "TRAP" or prior.mission
                g.defending=true
                dv=dv+g.value
                if priorThreat then
                    local signature=oldTarget:getSignature()
                    local match=self:AIRoleMatch(lead,oldTarget)
                    retainedCoverage[signature]=(retainedCoverage[signature] or 0)
                        +g.value*math.min(1.5,match)
                end
            else
                g.defenseRetention={targetSignature=prior.targetSignature,
                    age=age,targetDistance=distanceToStation,
                    releaseRadius=defenseReleaseRadius,retained=false,
                    reason=emergency and "EMERGENCY_OVERRIDE" or age>=defenseCommitSeconds and "COMMITMENT_EXPIRED" or
                        not shipAlive(oldTarget) and "TARGET_DEAD" or
                        not self:AreEnemies(lead,oldTarget) and "TARGET_NOT_HOSTILE" or "OUTSIDE_RELEASE_RADIUS"}
            end
        end
    end
    local function isScreen(g) return g.role=="fighter" or g.role=="escort" end
    local function responseTime(g,target)
        local eta=0
        for _,ship in ipairs(g.units) do
            local distance=ship.Position:getDistance(target.Position)
            eta=math.max(eta,math.max(0,distance-(target.Radius or 0))/math.max(1,math.abs(ship.Physics.VelocityMax.z)))
        end
        return eta
    end
    -- Assign whole available wings, crediting their value to one threat instead
    -- of spreading every fighter over a different target. Retain an existing
    -- interception on ties, but prefer ships that can arrive sooner.
    for _,threat in ipairs(threats) do
        local covered=retainedCoverage[threat.ship:getSignature()] or 0
        local required=threat.value*(doctrine.DefenseResponseRatio or 1.15)
        while threat.homeDefenseEligible~=false and covered<required and dv<cap do
            local best=nil; local bestScore=math.huge
            for _,g in ipairs(groups) do
                local match=self:AIRoleMatch(g.units[1],threat.ship)
                local suitable=(isScreen(g) or threat.capital or (critical and #threats>0)) and (match>=.2 or critical)
                local prior=self.AIOrderState[g.units[1]:getSignature()]
                local priorThreat=prior and threatBySignature[prior.targetSignature]
                local committedDefense=prior and (prior.mission=="SCREEN" or prior.mission=="TRAP") and prior.protected==station:getSignature() and priorThreat
                    and prior.targetSignature~=threat.ship:getSignature()
                    and now-(prior.assignedAt or now)<defenseCommitSeconds
                    and not emergency and not critical and not threat.attacking and not (threat.urgent and not priorThreat.urgent)
                suitable=suitable and not committedDefense
                local recallReserved=critical and emergency or emergency and dv+g.value<=cap
                if g.target==nil and not g.luring and suitable and (recallReserved or not g.assaultReserved) and (emergency or g.screen or not g.committed) then
                    local candidate=self:ScoreAIObjective(g,threat.ship,"SCREEN",{urgent=threat.urgent,reason="DEFEND_BASE"},covered,g.candidates~=nil)
                    if g.candidates then g.candidates[#g.candidates+1]=candidate end
                    local score=responseTime(g,threat.ship)/math.max(.1,match)-candidate.score*.1
                    if g.screen then score=score-(doctrine.DefenderRetentionSeconds or 10) end
                    local prev=self.AIOrderState[g.units[1]:getSignature()]
                    if prev and prev.targetSignature==threat.ship:getSignature() then score=score-(doctrine.DefenderRetentionSeconds or 10) end
                    if threat.capital and not isScreen(g) then score=score*.75 end
                    if best==nil or score<bestScore or (score==bestScore and g.id<best.id) then best=g; bestScore=score end
                end
            end
            if best==nil then break end
            best.target=threat.ship; best.defending=true; best.emergency=threat.urgent or critical
            best.trapping=threat.pursuingLure
            best.mission=best.trapping and "TRAP" or "SCREEN"
            covered=covered+best.value*math.min(1.5,(self:AIRoleMatch(best.units[1],threat.ship))); dv=dv+best.value
        end
    end
    for _,g in ipairs(groups) do
        local lead=g.units[1]
        local previous=lead and self.AIOrderState[lead:getSignature()] or nil
        if previous and previous.mission=="LURE" and now<(previous.lureUntil or 0) then
            g.luring=true; g.lureUntil=previous.lureUntil
            g.target=station; g.mission="LURE"
        end
        if g.role=="bomber" then
            g.targetedBy=self:FindAIGroupTargeter(g,kind,doctrine.BomberTargetedResponseRadius or localRadius)
            if shipValid(g.targetedBy) then
                g.localThreat=g.targetedBy; g.localThreatSource="DIRECT_TARGETER"
            end
        end
        if shipValid(g.localThreat) and not g.luring then
            -- A hostile inside the local engagement radius is a hard
            -- interception requirement.  Letting an uncommitted wing keep a
            -- remote strategic target is what caused ships to pass through
            -- each other and rely on the base screen to fight for them.
            if previous and previous.mission=="INTERCEPT" and previous.targetSignature~=nil then
                local oldTarget=self:FindShipBySignature(previous.targetSignature)
                if shipValid(oldTarget) and self:AreEnemies(lead,oldTarget) and oldTarget:getSignature()~=g.localThreat:getSignature() then
                    local oldDistance=lead.Position:getDistance(oldTarget.Position); local newDistance=lead.Position:getDistance(g.localThreat.Position)
                    local age=now-(previous.assignedAt or now); local retention=doctrine.LocalTargetRetentionSeconds or 8
                    local improvement=clamp(doctrine.RetargetImprovementRatio or .25,0,.90)
                    if age<retention or newDistance>oldDistance*(1-improvement) then g.localThreat=oldTarget end
                end
            end
            local hardRadius=g.role=="bomber" and (doctrine.BomberSelfDefenseRadius or 1200)
                or (doctrine.HardEngageRadius or (localRadius*0.5))
            local localDistance=math.huge
            for _,member in ipairs(g.units) do
                if shipValid(g.localThreat) then localDistance=math.min(localDistance,member.Position:getDistance(g.localThreat.Position)) end
            end
            local targeted=g.role=="bomber" and shipValid(g.targetedBy)
            g.hardLocalThreat=localDistance<=hardRadius or targeted
            if g.target==nil and (not g.assaultReserved or critical or g.hardLocalThreat) then
                g.target=g.localThreat
                g.mission="INTERCEPT"
            end
        end
    end
    -- A direct ship-level base attack order from a beam-capable capital is an
    -- early bomber response, even outside the local screen radius. A turret's
    -- aim alone is weaker evidence and only qualifies nearby; an observed hit
    -- is strongest and takes the full emergency path.
    local maxSuppressionWings=math.max(0,math.floor(doctrine.CapitalSuppressionBomberWings or 1))
    local capitalResponseRadius=doctrine.CapitalSuppressionRadius or threatRadius
    if not emergency and doctrine.CapitalSuppressionEnabled~=false and maxSuppressionWings>0 then
        local function isCapitalResponseThreat(threat)
            return threat.capital and (threat.urgent or threat.targetingStation)
        end
        local function capitalAttackEvidence(threat)
            if threat.attacking then return 2 end
            if threat.targetingStation then return 1 end
            return 0
        end
        local strongestCapitalEvidence=0
        for _,threat in ipairs(threats) do
            if isCapitalResponseThreat(threat) then
                strongestCapitalEvidence=math.max(strongestCapitalEvidence,capitalAttackEvidence(threat))
            end
        end
        local capitalReleaseRadius=capitalResponseRadius+(doctrine.DefenderReleaseDistance or 1500)
        local function findThreat(signature,retaining)
            local target=self:FindShipBySignature(signature)
            if not shipAlive(target) or not self:IsCapitalTarget(target)
                or self:IsCommandStation(target) or target==primary or not self:AreEnemies(station,target) then
                return nil
            end
            for _,threat in ipairs(threats) do
                if threat.ship:getSignature()==signature and isCapitalResponseThreat(threat) then
                    return target
                end
            end
            -- Once dispatched against a base-targeting capital, keep the
            -- bomber committed while that capital remains near the base, even
            -- if it switches targets to the responding wing.
            if retaining and target.Position:getDistance(station.Position)<=capitalReleaseRadius then return target end
            return nil
        end
        local retained={}; local assignedGroups={}; local assignedTargets={}
        for _,g in ipairs(groups) do
            local lead=g.units[1]
            local previous=lead and self.AIOrderState[lead:getSignature()] or nil
            if previous and previous.mission=="INTERCEPT" and previous.reason=="CAPITAL_THREAT_PREEMPTION" then
                local target=findThreat(previous.targetSignature,true)
                local priorEvidence=0
                for _,threat in ipairs(threats) do
                    if threat.ship:getSignature()==previous.targetSignature then
                        priorEvidence=capitalAttackEvidence(threat)
                        break
                    end
                end
                local displaced=strongestCapitalEvidence>priorEvidence
                if target and not displaced and g.target==nil and not g.hardLocalThreat and not g.luring and not g.probing then
                    retained[#retained+1]={group=g,target=target}
                end
            end
        end
        table.sort(retained,function(a,b) return a.group.id<b.group.id end)
        local activeWings=0
        for _,entry in ipairs(retained) do
            if activeWings>=maxSuppressionWings then break end
            local g=entry.group; local signature=entry.target:getSignature()
            g.target=entry.target; g.mission="INTERCEPT"; g.defending=true; g.capitalSuppression=true
            assignedGroups[g.id]=true; assignedTargets[signature]=true; activeWings=activeWings+1
        end
        for _,threat in ipairs(threats) do
            if activeWings>=maxSuppressionWings then break end
            local signature=threat.ship:getSignature()
            if isCapitalResponseThreat(threat) and not self:IsCommandStation(threat.ship)
                and threat.ship~=primary and shipAlive(threat.ship) and not assignedTargets[signature] then
                local best,bestScore,available= nil,math.huge,0
                for _,g in ipairs(groups) do
                    local lead=g.units[1]
                    local previous=lead and self.AIOrderState[lead:getSignature()] or nil
                    local previousIsAssault=previous==nil or previous.mission=="PRIMARY" or previous.mission=="REGROUP"
                    local localThreatMatches=not shipValid(g.localThreat) or g.localThreat==threat.ship
                    if g.role=="bomber" and g.assaultReserved and g.target==nil and not g.defending
                        and not assignedGroups[g.id] and not g.luring and not g.probing and not g.screen
                        and not g.hardLocalThreat and localThreatMatches and previousIsAssault then
                        local match=self:AIRoleMatch(lead,threat.ship)
                        if match>=.2 then
                            available=available+1
                            local score=responseTime(g,threat.ship)/math.max(.1,match)
                            if g.committed then score=score+100000 end
                            if best==nil or score<bestScore or (score==bestScore and g.id<best.id) then
                                best=g; bestScore=score
                            end
                        end
                    end
                end
                -- A non-immediate response must leave one bomber wing on the
                -- strategic strike. Immediate weapon-range threats can use
                -- the last available wing; the emergency path handles hits.
                if best and (threat.urgent or available>1) then
                    best.target=threat.ship; best.mission="INTERCEPT"
                    best.defending=true; best.capitalSuppression=true
                    assignedGroups[best.id]=true; assignedTargets[signature]=true; activeWings=activeWings+1
                end
            end
        end
    end
    table.sort(groups,function(a,b)
        if a.screen~=b.screen then return a.screen end
        local ad=responseTime(a,station); local bd=responseTime(b,station)
        if ad~=bd then return ad<bd end
        return a.id<b.id
    end)
    local bomberAnchor=nil
    for _,g in ipairs(groups) do
        if g.role=="bomber" and g.assaultReserved and not g.defending and not g.hardLocalThreat
            and not emergency and (g.target==nil or g.target==g.primary) and shipValid(g.primary) then
            if not bomberAnchor or g.value>bomberAnchor.value or (g.value==bomberAnchor.value and g.id<bomberAnchor.id) then
                bomberAnchor=g
            end
        end
    end
    local bomberEscort=nil
    if bomberAnchor and not emergency then
        local freeScreenValue=0; local candidate=nil; local candidateCost=math.huge
        for _,g in ipairs(groups) do
            if isScreen(g) and g.target==nil and not g.screen and not g.committed
                and not g.assaultReserved and not shipValid(g.localThreat) then
                freeScreenValue=freeScreenValue+g.value
                local speed=math.max(1,math.abs(g.units[1].Physics.VelocityMax.z))
                local cost=g.value/speed
                if candidate==nil or cost<candidateCost or (cost==candidateCost and g.id<candidate.id) then
                    candidate=g; candidateCost=cost
                end
            end
        end
        if candidate and freeScreenValue-candidate.value>=math.max(0,reserve-dv) then bomberEscort=candidate end
    end
    -- front.assault is the strength the planner believes it can put on a front.
    -- At this point the wings the SCREEN fallback further down will retain at
    -- home carry no target and no mission, so the `not g.defending` test below
    -- silently absorbed them too: the homeguard was counted as striking power
    -- the same tick it was being promised to the home station, which biases
    -- rawCanPush (and therefore canPush, posture and the LOCAL_INFERIORITY
    -- regroup fallback) optimistic by exactly the reserve that stays home.
    -- Replay the same retention the SCREEN fallback performs - same sorted
    -- order, same (g.screen or not g.committed) test, same reserve/dv budget -
    -- and exclude those wings from assault weight. This is a no-op when no wing
    -- is retained, and it only ever lowers assault weight toward the truth.
    do
        local pendingDv=dv
        for _,g in ipairs(groups) do
            if g.target==nil and g~=bomberEscort and isScreen(g)
                and (g.screen or not g.committed) and pendingDv<reserve then
                g.homeguard=true
                pendingDv=pendingDv+g.value
            end
        end
    end
    local missionCounts={}; local actualDefenseValue=0; local offenseValue=0
    self.AIPushHistory=self.AIPushHistory or {}
    local history=self.AIPushHistory[kind] or {}; self.AIPushHistory[kind]=history
    local frontPlans={}
    for _,g in ipairs(groups) do
        if shipAlive(g.primary) then
            local id=g.primary:getSignature()
            local front=frontPlans[id] or {target=g.primary,assault=0,defense=0}; frontPlans[id]=front
            if not g.defending and not g.homeguard then front.assault=front.assault+g.value end
        end
    end
    for id,front in pairs(frontPlans) do
        for _,row in ipairs(self.StrategicThreatSnapshot) do
            if shipAlive(row.ship) and self:GetFactionKey(row.ship)==self:GetFactionKey(front.target)
                and not self:IsCommandStation(row.ship) and row.ship.Position:getDistance(front.target.Position)<=threatRadius then
                front.defense=front.defense+row.profile.value
            end
        end
        front.rawCanPush=front.defense<=front.assault/self:GetAIAssaultStrengthRatio()
        local push=history[id]
        if not push then push={accepted=front.rawCanPush}; history[id]=push
        elseif front.rawCanPush==push.accepted then push.pending=nil; push.pendingSince=nil
        elseif push.pending~=front.rawCanPush then push.pending=front.rawCanPush; push.pendingSince=now
        elseif now-push.pendingSince>=(doctrine.MinimumCommitmentSeconds or 8) then push.accepted=front.rawCanPush; push.pending=nil; push.pendingSince=nil end
        front.canPush=push.accepted
    end
    for id in pairs(history) do if not frontPlans[id] then history[id]=nil end end
    local primarySignature=shipValid(primary) and primary:getSignature() or -1
    local selected=frontPlans[primarySignature]
    local enemyDefense=selected and selected.defense or 0
    local rawCanPush=selected and selected.rawCanPush or false
    local canPush=selected and selected.canPush or false
    if not emergency and canPush then posture="OFFENSIVE" end
    -- Make one visible, low-cost fighter probe while the strike assets stay on
    -- the enemy station. The probe is deterministic (no RNG) and tightly paced;
    -- it is a feint, not an invisible unit or a second full assault wave.
    local activeFeint=false
    for _,g in ipairs(groups) do
        local lead=g.units[1]
        local previous=lead and self.AIOrderState[lead:getSignature()] or nil
        if previous and now<(previous.feintUntil or 0) then
            activeFeint=true
            g.feint=true
            if g.probing and g.target==nil and not shipValid(g.localThreat) then
                local feintTarget=self:FindShipBySignature(g.feintTargetSignature)
                if not shipAlive(feintTarget) or not self:AreEnemies(lead,feintTarget) then feintTarget=primary end
                g.target=feintTarget; g.mission="FEINT"; g.feintUntil=previous.feintUntil
                g.feintTargetSignature=shipValid(feintTarget) and feintTarget:getSignature() or nil
            end
        end
    end
    if not activeFeint and doctrine.TauntEnabled~=false and not emergency and canPush
        and shipValid(primary) and assaultReservedValue>0 and now>=(self.AITauntNextAt[kind] or -math.huge) then
        local probe=nil; local probeCost=math.huge; local freeScreenValue=0
        for _,g in ipairs(groups) do
            if (g.role=="fighter" or g.role=="escort") and not g.screen and not g.assaultReserved
                and not g.committed and g.target==nil and not shipValid(g.localThreat)
                and g.minHull>=(doctrine.TauntMinHullFraction or .75) then
                freeScreenValue=freeScreenValue+g.value
                local speed=math.max(1,math.abs(g.units[1].Physics.VelocityMax.z))
                local cost=g.value/speed
                if probe==nil or cost<probeCost or (cost==probeCost and g.id<probe.id) then
                    probe=g; probeCost=cost
                end
            end
        end
        if probe and freeScreenValue-probe.value>=math.max(0,reserve-dv) then
            local decoyTarget=self:ChooseAIFeintTarget(kind,primary,doctrine.TauntTargetRadius or threatRadius)
            probe.target=decoyTarget; probe.mission="FEINT"; probe.feint=true
            probe.feintTargetSignature=shipValid(decoyTarget) and decoyTarget:getSignature() or nil
            -- Keep the probe window alive until the wing has reached the
            -- contested objective. An 18-second timer expired long before an
            -- enemy could react, leaving luring inert in full battles.
            local feintWindow=doctrine.TauntCommitSeconds or 18
            probe.feintUntil=now+math.max(feintWindow,responseTime(probe,decoyTarget)+feintWindow)
            self.AITauntNextAt[kind]=now+(doctrine.TauntCooldownSeconds or 90)
        end
    end
    local assaultAnchors={}
    for _,g in ipairs(groups) do
        if not g.defending and (g.role=="capital" or g.role=="heavy" or g.role=="juggernaut") then
            if g.primary then local id=g.primary:getSignature(); if not assaultAnchors[id] or g.value>assaultAnchors[id].value then assaultAnchors[id]=g end end
        end
    end
    local coverage={}
    for _,g in ipairs(groups) do if g.defending then local id=g.target:getSignature(); coverage[id]=(coverage[id] or 0)+g.value end end
    self:BuildAIOperations(kind,groups,station,now,threatValue,emergency)
    for _,g in ipairs(groups) do
        local lead=g.units[1]
        local primary=g.primary or primary
        local primarySignature=shipValid(primary) and primary:getSignature() or -1
        local front=frontPlans[primarySignature]
        local canPush=front and front.canPush or false
        local assaultAnchor=assaultAnchors[primarySignature]
        local previous=lead and self.AIOrderState[lead:getSignature()] or nil
        if previous and previous.mission=="LURE" and now>=(previous.lureUntil or 0)
            and not g.defending and not shipValid(g.localThreat) and not emergency and canPush and shipValid(primary) then
            g.target=primary; g.mission="PRIMARY"; g.expiredLure=true
        end
        -- Existing screens keep guarding the home station. Other reserved
        -- groups receive the strategic primary unless they have a hard local
        -- contact or this faction is in an emergency response.
        if g.target==nil and shipValid(primary) and not emergency and g.assaultReserved and not g.screen and not g.hardLocalThreat then
            g.target=primary; g.mission="PRIMARY"
        end
        if g.target==nil and g==bomberEscort then
            g.target=bomberAnchor.units[1]; g.mission="ESCORT"; g.escortBomber=true
        end
        if g.target==nil and isScreen(g) and dv<reserve and (g.screen or not g.committed) then g.target=station; dv=dv+g.value end
        local target=g.target or primary or station
        local mission=g.mission or ((g.target~=nil or not shipValid(primary)) and "SCREEN" or "PRIMARY")
        local releasedDefense=g.defenseRetention and not g.defenseRetention.retained and not emergency
        local context={emergency=g.emergency==true,locked=g.defending==true or releasedDefense==true or g.luring==true or g.expiredLure==true,urgent=g.emergency==true,posture=posture,
            reason=g.capitalSuppression and "CAPITAL_THREAT_PREEMPTION"
                or g.trapping and "TRAP_LURE_PURSUIT" or g.luring and (g.lureReason or "LURE_UNDER_PRESSURE")
                or g.expiredLure and "LURE_COMPLETE_REJOIN_ASSAULT"
                or g.feint and (g.feintTargetSignature~=primarySignature and "TAUNT_DECOY" or "TAUNT_PROBE")
                or g.escortBomber and "ESCORT_BOMBER_STRIKE" or g.defending and "DEFEND_BASE"
                or releasedDefense and g.defenseRetention.reason or nil,
            protected=g.defending and station:getSignature() or nil,
            assaultPrimarySignature=primarySignature,
            feintUntil=g.feintUntil,lureUntil=g.lureUntil,
            feintTargetSignature=g.feintTargetSignature}
        if mission=="INTERCEPT" and not g.defending then
            -- Coverage throttling is for ordinary contacts. A hostile inside
            -- the hard engagement radius must not be ignored just because
            -- other groups were assigned to it from farther away.
            if not g.hardLocalThreat and (coverage[target:getSignature()] or 0)>self:AIProfile(target).value*1.8 then
                local chosen=self:ChooseAILocalThreat(g,coverage)
                if shipValid(chosen) then target=chosen else target=primary or station; mission=shipValid(primary) and "PRIMARY" or "SCREEN" end
            end
            local previous=self.AIOrderState[g.units[1]:getSignature()]
            if g.hardLocalThreat and (not previous or previous.mission=="PRIMARY") then
                context.emergency=true; context.reason="INTERCEPT_IMMEDIATE_THREAT"
            elseif previous and previous.mission=="INTERCEPT" then
                local old=self:FindShipBySignature(previous.targetSignature)
                if shipValid(old) and now-previous.assignedAt>=(doctrine.LocalTargetRetentionSeconds or 8)
                    and g.units[1].Position:getDistance(target.Position)<g.units[1].Position:getDistance(old.Position)*(1-(doctrine.RetargetImprovementRatio or .25)) then
                    context.locked=true
                end
            end
        end
        local lead=g.units[1]; local friend,enemy=self:AILocalStrength(lead,lead.Position,doctrine.LocalStrengthRadius or 4500,false)
        local retreat=self.AIRetreatUntil[g.id] or -1
        local previous=self.AIOrderState[lead:getSignature()]
        local feinting=mission=="FEINT" or g.probing==true
            or (previous and now<(previous.feintUntil or 0))
        local pursuing=feinting and self:FindAIGroupTargeter(g,kind,localRadius) or nil
        if feinting and not g.luring and not g.defending and not emergency and shipValid(g.localThreat)
            and (enemy>math.max(1,friend)*(doctrine.LureForceRatio or 1.30) or shipValid(pursuing)) then
            g.luring=true; g.lureForceRatio=enemy/math.max(1,friend)
            g.lureReason=shipValid(pursuing) and "PURSUER_LOCKED" or "LOCAL_FORCE_DISADVANTAGE"
            -- Hold the withdrawal long enough to reach friendly defenses and
            -- give their screen one commitment window to catch pursuers.
            local returnAndTrap=responseTime(g,station)+(doctrine.DefenseTargetCommitmentSeconds or 18)
            g.lureUntil=now+math.max(doctrine.LureDurationSeconds or 18,returnAndTrap)
        end
        -- Break off as a unit only when a real share of the wing is hurt.
        -- g.minHull alone is the group-wide minimum, so one mauled escort used
        -- to recall the entire formation; a lone hull still breaks off
        -- (damagedFraction 1.0) and so does a wing that is mostly shot up.
        if not critical and g.minHull<=(doctrine.RetreatHullFraction or .22)
            and g.damagedFraction>=(doctrine.RetreatDamagedShipFraction or .5)
            and enemy>friend and not g.defending then
            retreat=now+(doctrine.RetreatCommitSeconds or 25); self.AIRetreatUntil[g.id]=retreat
        end
        if g.luring and now<(g.lureUntil or 0) and not g.defending then
            target=station; mission="LURE"; context.locked=true
            -- The lure is the SAME decoy continuing, so the feint window has to
            -- span it. Clearing feintUntil here ended the decoy's life while
            -- the wing was still baiting: the `g.probing` restore and the
            -- `activeFeint` test above both re-derive the decoy flag from
            -- previous.feintUntil, so the next tick stopped counting this wing
            -- as a decoy, the TACTIC record lost its TAUNT_DECOY identity, and
            -- - because a lure can outlast TauntCooldownSeconds (g.lureUntil is
            -- driven by responseTime(g,station), not by LureDurationSeconds) -
            -- the taunt launcher was free to start a SECOND decoy while the
            -- first was still in the field. Carry the window to the end of the
            -- lure so one taunt is one decoy.
            context.feintUntil=math.max(g.feintUntil or 0,g.lureUntil or 0)
            context.feintTargetSignature=g.feintTargetSignature
            context.reason=g.lureReason or "LURE_UNDER_PRESSURE"; context.lureUntil=g.lureUntil
        elseif not critical and retreat>now and not g.defending then
            target=station; mission="RETREAT"; context.locked=true; context.reason="RETREAT"
        elseif not g.defending and not g.armed and g.ordnance and not g.ordnanceLoaded then
            -- Only a genuinely dry group retreats. A capital that lost its
            -- turrets has no surviving ordnance bank at all and must keep its
            -- objective instead of being locked into RETREAT for the battle.
            target=station; mission="RETREAT"; context.locked=true; context.reason="WEAPONS_DISABLED"
        elseif not g.defending and (g.role=="support" or g.role=="transport") then
            target=assaultAnchor and assaultAnchor.units[1] or station; mission="ESCORT"; context.locked=true; context.reason="ESCORT_HIGH_VALUE_UNIT"
        elseif mission=="PRIMARY" and not canPush and not g.committed then
            target=assaultAnchor and assaultAnchor.units[1] or station
            if target:getSignature()==lead:getSignature() then target=station end
            mission="REGROUP"; context.locked=true; context.reason="LOCAL_INFERIORITY"
        elseif mission=="PRIMARY" and assaultAnchor and assaultAnchor~=g and isScreen(g) and not g.screen and not g.assaultReserved then
            target=assaultAnchor.units[1]; mission="ESCORT"; context.reason="SUPPORT_ASSAULT"; context.protected=target:getSignature()
        elseif mission=="PRIMARY" and #g.units>1 and g.spread>(doctrine.RegroupDistance or 2600) and not g.hardLocalThreat then
            target=station; mission="REGROUP"; context.locked=true; context.reason="FORMATION_RECOVERY"
        end
        if mission=="PRIMARY" and emergency and not critical and not g.defending then context.locked=true end
        if mission=="INTERCEPT" and not g.defending and shipValid(g.localThreat)
            and shipValid(target) and target:getSignature()==g.localThreat:getSignature() then
            local previous=self.AIOrderState[lead:getSignature()]
            context.localEngageOverride=not previous or previous.mission~="INTERCEPT"
            if context.localEngageOverride and not context.reason then context.reason="LOCAL_ENGAGEMENT" end
        end
        target,mission=self:ApplyAIOperationOrder(g,target,mission,context,station,now,coverage)
        target,mission=self:ApplyAssaultObjectiveLock(g,target,mission,context)
        mission=self:CommitAIGroup(g,target,mission,station,context,now,force)
        missionCounts[mission]=(missionCounts[mission] or 0)+#g.units
        if mission=="PRIMARY" or mission=="ESCORT" then offenseValue=offenseValue+g.value else actualDefenseValue=actualDefenseValue+g.value end
        if self:AreEnemies(lead,g.target) then local id=g.target:getSignature(); coverage[id]=(coverage[id] or 0)+g.value end
    end
    if self.CombatTelemetryEnabled then
        self:EmitAICohesion(kind,groups,station,primary,now)
        self:EmitContestRecord(kind,groups,station,primary,now)
    end
    if self.CombatTelemetryEnabled then
        self.AIPlanTelemetry[kind]={
            time=now,
            primarySignature=shipValid(primary) and primary:getSignature() or nil,
            primaryName=shipValid(primary) and primary.Name or "NONE",
            threatCount=#threats,
            threatValue=threatValue,
            urgent=urgent,
            critical=critical,
            emergency=emergency,
            groups=#groups,
            totalValue=totalValue,
            screenEligibleValue=screenEligibleValue,
            reserve=reserve,
            defenseValue=actualDefenseValue,
            offenseValue=offenseValue,
            -- 's' is the SummarizeAI summary, which does not exist yet: this
            -- runs before SummarizeAI and is per-faction. Count from the group
            -- builder's own tallies instead of dereferencing a nil global.
            -- Serviced and player-held ships are owned but deliberately
            -- unplanned, so they must be subtracted before reporting idle.
            idle=math.max(0,ownedCount-plannedCount-servicingCount-playerControlledCount),
            servicing=servicingCount,
            playerControlled=playerControlledCount,
            posture=posture,
            enemyDefenseValue=enemyDefense,
            canPush=canPush,
            rawCanPush=rawCanPush,
            assaultReserveValue=assaultReserveValue,
            assaultReservedValue=assaultReservedValue,
            missionCounts=missionCounts,
        }
    end
    if ownsSnapshot then
        self.StrategicThreatSnapshot=nil; self.AIShipIndex=nil; self.AIProfileIndex=nil
        self.AITargetedBy=nil; self.AISpatialGrid=nil; self.AILocalCache=nil
    end
end

function RTS:FindFactionLocalThreat(kind, station, radius)
    if not shipValid(station) then return nil end
    local best, bestDist = nil, radius or math.huge
    self:EachShip(function(other)
        if shipAlive(other) and other.Name ~= self.Config.ObserverShip and self:AreEnemies(station, other) then
            if other.Name ~= self.Config.CarrierShip and other.Name ~= self.Config.EnemyCommandShip and other.Name ~= self.Config.ThirdCommandShip then
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
        if shipAlive(other) and other.Name ~= self.Config.ObserverShip and self:AreEnemies(ship, other) then
            if other.Name ~= self.Config.CarrierShip and other.Name ~= self.Config.EnemyCommandShip and other.Name ~= self.Config.ThirdCommandShip then
                local d = other.Position:getDistance(ship.Position)
                if d < bestDist then best, bestDist = other, d end
            end
        end
    end)
    return best
end

function RTS:SelectFactionPrimaryTarget(kind)
    local source=self:GetFactionCommandShip(kind); if not shipAlive(source) then return nil end
    local candidates={}
    for _,otherKind in ipairs({"BLUE","RED","GOLD"}) do
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
    if self.SetupFactionCount>=3 and self.Config.ThreeFactionTargetCycle~=nil then
        preferredKind=self.Config.ThreeFactionTargetCycle[kind]
    end
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
    if not shipValid(ship) or self:IsStaticDefense(ship) then return end
    local station=self:GetFactionCommandShip(kind); if not shipValid(station) or ship:getSignature()==station:getSignature() then return end
    local sig=ship:getSignature()
    if kind=="BLUE" then if not self.AutoPlayerMode or self.PossessedSignature==sig or self.UserOrders[sig]~=nil then return end end
    local entry=self:GetAIRosterEntry(kind,ship.Class.Name); local role=entry and entry.role or self:GetShipRole(ship); local primary=self:GetStablePrimaryTarget(kind); if not shipValid(primary) then return end
    if role=="bomber" or role=="capital" or role=="heavy" or role=="juggernaut" then self:IssueStrategicOrder(ship,primary,"AI PRIMARY: COMMITTED STRIKE ON "..primary.Name,"PRIMARY",mn.getMissionTime(),force)
    else self:IssueStrategicOrder(ship,primary,"AI PRIMARY: ASSAULT "..primary.Name,"PRIMARY",mn.getMissionTime(),force) end
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
            local hostileTarget=shipAlive(ship) and shipAlive(target) and self:AreEnemies(ship,target)
            local friendlyGoal=shipAlive(target) and self:GetFactionKey(ship)==self:GetFactionKey(target)
                and (state.mission=="SCREEN" or state.mission=="ESCORT" or state.mission=="REGROUP"
                    or state.mission=="RETREAT" or state.mission=="LURE")
            -- SCREEN normally guards the friendly station, but a screen wing
            -- assigned to an actual hostile must receive the same repair.
            if hostileTarget or friendlyGoal or not shipValid(target) then
                if hostileTarget or friendlyGoal then
                    local status,goalPresent=self:GetNativeObjectiveStatus(ship,state)
                    local repairInterval=(self.Config.AI.Doctrine or {}).NativeTargetRepairInterval or 6
                    local age=now-(state.installedAt or state.assignedAt or now)
                    local repair=status=="NATIVE_ORDER_PREEMPTED" or status=="NATIVE_TARGET_FRIENDLY"
                        or (status=="NATIVE_TARGET_LOST" and goalPresent~=true and age>=repairInterval)
                    if repair and now-(state.lastRepair or -math.huge)>=repairInterval then
                        local subsystem=state.subsystemIndex and target[state.subsystemIndex]
                        if subsystem and (not subsystem:isValid() or subsystem.HitpointsLeft<=0) then subsystem=nil end
                        self:IssueStrategicOrder(ship,target,state.label,state.mission,now,true,
                            {destination=state.destination,subsystem=subsystem,subsystemIndex=subsystem and state.subsystemIndex or nil})
                        local repaired=self.AIOrderState[sig]
                        if repaired then repaired.lastRepair=now end
                    end
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
    if self.Config.AI==nil or self.Config.AI.Enabled==false or self.SetupActive or self.PostBattleActive then return end
    self:UpdateAIPursuitGoals(now)
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
        if self.AutoPlayerMode and not self.BlueEliminated then queue[#queue+1]="BLUE" end
        if self:IsFactionEnabled("RED") and not self.RedEliminated then queue[#queue+1]="RED" end
        if self:IsFactionEnabled("GOLD") and not self.GoldEliminated then queue[#queue+1]="GOLD" end
        self.AIStrategicPlanQueue=queue
    else
        -- Positions and weapon mounts can change while another faction was
        -- planned, so each queued faction receives a fresh spatial snapshot.
        self.StrategicThreatSnapshot=self:BuildStrategicThreatSnapshot()
        self:BuildAIContext(self.StrategicThreatSnapshot)
    end
    local kind=table.remove(queue,1)
    if kind=="BLUE" and self.AutoPlayerMode and not self.BlueEliminated then
        self:UpdateFactionStrategicPlan("BLUE",now,false)
    elseif kind=="RED" and self:IsFactionEnabled("RED") and not self.RedEliminated then
        self:UpdateFactionStrategicPlan("RED",now,false)
    elseif kind=="GOLD" and self:IsFactionEnabled("GOLD") and not self.GoldEliminated then
        self:UpdateFactionStrategicPlan("GOLD",now,false)
    end
    if #queue==0 then
        self:SummarizeAI(now)
        self.AIStrategicPlanQueue=nil
    end
    self.StrategicThreatSnapshot=nil
    self.AIShipIndex=nil; self.AIProfileIndex=nil; self.AITargetedBy=nil
    self.AISpatialGrid=nil; self.AILocalCache=nil
end
