-- Assault group pooling and front keeping.
local _shared = require "fs2rts_strategy.common"
local RTS, clamp, shipAlive, shipValid = _shared.RTS, _shared.clamp, _shared.shipAlive, _shared.shipValid

-- Keep surviving wings on their front. Balance new groups between live enemy
-- bases instead of rotating the entire fleet on a timer.
function RTS:AssignAIAssaultFronts(kind,groups,preferred)
    self.AIAssaultTargets=self.AIAssaultTargets or {}
    local assignments=self.AIAssaultTargets[kind] or {}; self.AIAssaultTargets[kind]=assignments
    local fronts,load,present={},{},{}
    local source=self:GetFactionCommandShip(kind)
    for _,enemy in ipairs(self:GetFactionKeys()) do
        local base=self:GetFactionCommandShip(enemy)
        if enemy~=kind and self:IsFactionEnabled(enemy) and shipAlive(base) and self:AreEnemies(source,base) then
            fronts[#fronts+1]=base; load[base:getSignature()]=0
        end
    end
    if self.ScenarioBaseLayoutId and self.ScenarioBaseLayoutId~='CIRCLE' and #fronts>1 then
        local closest=math.huge
        for _,base in ipairs(fronts) do closest=math.min(closest,source.Position:getDistance(base.Position)) end
        -- Win the nearby cluster before dividing a small fleet across distant circles.
        local nearby={}
        for _,base in ipairs(fronts) do
            if source.Position:getDistance(base.Position)<=closest*1.5+1 then nearby[#nearby+1]=base
            else load[base:getSignature()]=nil end
        end
        fronts=nearby
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
-- Group identity is assigned once at fs2rts_strategy/weapons.lua:151 as
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
