-- Production subroles and per-team limits. These never change a ship's strategic
-- role, price or native type; they only decide what a team may buy next.
local RTS=require 'fs2rts_state'
local U=require 'fs2rts_util'

local function limits(self)
    return self.Config.FleetLimits or {}
end

local function countLiveRoleShips(self,kind,role)
    local count=0
    for _,ship in ipairs(self:GetShipList()) do
        if U.shipAlive(ship) and self:GetFactionKey(ship)==kind
            and self:GetProductionRole(ship.Class.Name)==role then count=count+1 end
    end
    return count
end

function RTS:GetProductionRole(className)
    local known=self.ShipCostRoleMap and self.ShipCostRoleMap[className]
    if known then return known end
    for _,key in ipairs({'BlueRoster','RedRoster','GoldRoster'}) do
        for _,entry in ipairs(self.Config.AI[key] or {}) do
            if entry.class==className then return entry.role end
        end
    end
end

function RTS:IsCorvetteClass(className)
    for _,name in ipairs(limits(self).CorvetteClasses or {}) do
        if name==className then return true end
    end
    return false
end

-- 'corvette', 'destroyer' or 'juggernaut' for capital-category hulls; nil for
-- everything else. Every capital or heavy hull that is not a configured corvette
-- is a destroyer.
function RTS:GetCapitalCategory(className)
    if self:IsCorvetteClass(className) then return 'corvette' end
    local role=self:GetProductionRole(className)
    if role=='juggernaut' then return 'juggernaut' end
    if role=='capital' or role=='heavy' then return 'destroyer' end
end

-- True when the team may add `count` more of `className`. Only supercaps are
-- limited; liveCounts (from CountAIRoleUnits) avoids rescanning the fleet.
function RTS:CanProduceClass(kind,className,count,includeQueued,liveCounts)
    local role=self:GetProductionRole(className)
    if role~='juggernaut' then return true end
    local limit=limits(self).SupercapsPerTeam or 1
    local committed=liveCounts and (liveCounts.juggernaut or 0) or 0
    if not liveCounts then committed=countLiveRoleShips(self,kind,role) end
    if includeQueued then
        if kind=='BLUE' then
            for _,job in ipairs(self.BuildQueue or {}) do
                if self:GetProductionRole(job.option.class)==role then committed=committed+(job.option.count or 1) end
            end
        end
        local state=self.AIStates and self.AIStates[kind]
        if state and state.queue and self:GetProductionRole(state.queue.entry.class)==role then
            committed=committed+(state.queue.count or 1)
        end
    end
    return committed+(count or 1)<=limit
end

-- Which capital category the AI should buy next. Corvettes fill CorvettesPerDestroyer
-- slots per destroyer, so a cheap corvette does not consume the savings a
-- destroyer needs; a supercap comes after the first destroyer.
function RTS:GetAICapitalGoal(available,counts)
    local corvette=counts.corvette or 0
    local destroyer=counts.destroyer or 0
    if available.juggernaut and destroyer>0 and (counts.juggernaut or 0)==0 then return 'juggernaut' end
    local ratio=limits(self).CorvettesPerDestroyer or 2
    if available.corvette and (not available.destroyer or corvette<math.max(1,destroyer*ratio)) then return 'corvette' end
    if available.destroyer then return 'destroyer' end
    if available.juggernaut then return 'juggernaut' end
    if available.corvette then return 'corvette' end
end

return RTS
