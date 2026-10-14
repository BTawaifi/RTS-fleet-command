-- Tier multipliers and spawn placement helpers.
local _shared = require "fs2rts_factions.common"
local RTS, shipValid, vec = _shared.RTS, _shared.shipValid, _shared.vec

function RTS:GetTierMultiplier(tier)
    local t = self.Config.CostFormula.TierMultipliers or {1.0,1.75,2.75,4.5}
    return t[tier or 1] or t[#t] or 1
end

-- allowModelLoad defaults to true. The death path passes false: a ship dying
-- is the worst possible moment to page a POF, and a pricing failure there must
-- not abort the rest of the $On Ship Death handler.
function RTS:GetPurchaseEstimate(className, tier, count, allowModelLoad)
    if allowModelLoad == nil then allowModelLoad = true end
    local base = self.ShipCostMap[className]
    if base == nil then
        local ok, est = pcall(function() return self:EstimateShipCost(tb.ShipClasses[className], allowModelLoad) end)
        base = ok and est or nil
        if base ~= nil then self.ShipCostMap[className] = base end
    end
    if base == nil then return nil end
    count = count or 1
    local mult = self:GetTierMultiplier(tier or 1)
    local cost = math.floor((base.cost * mult * count + 12.5) / 25) * 25
    local floor=((self.Config.CostFormula or {}).PurchaseCostFloor or {})[className]
    if floor and floor*count>cost then
        cost=floor*count
        -- Preserve the same CP-to-time relation; a price increase must not
        -- leave the old cheap hull's short build time behind.
        base={time=cost/count*(self.Config.CostFormula.BuildSecondsPerCP or .025)/mult,radius=base.radius}
    end
    local timeMult = count > 1 and (self.Config.Economy.WingBuildTimeMultiplier or 1.75) or 1
    return {cost=cost, time=base.time * mult * timeMult, count=count, radius=base.radius}
end

-- Capital placement is deliberately separated from the fighter grid: the strike
-- frame's clearance and its 6x-spacing retry fan both grow with hull radius, so
-- a juggernaut either lands far outside its own base or materialises inside an
-- enemy station's kill ring before it has been ordered.
function RTS:IsCapitalSpawnClass(className, radius)
    if radius >= ((self.Config.CostFormula or {}).HugeRadius or 1200) then return true end
    for _, option in ipairs(self.Config.ProductionClasses or {}) do
        if option.class == className then return option.role == "capital" or option.role == "heavy" or option.role == "juggernaut" end
    end
    for _, kind in ipairs(self:GetFactionKeys()) do
        local e = self:GetAIRosterEntry(kind, className)
        if e ~= nil then return e.role == "capital" or e.role == "heavy" or e.role == "juggernaut" end
    end
    return false
end

-- Pull a spawn candidate back to MinEnemyBaseSeparation from the nearest hostile
-- command station, and hand back that station so the caller can try a fallback.
function RTS:SeparateFromHostileStation(pos, anchor, toward)
    local separation = self:GetEnemyBaseSeparation()
    local station, closest = nil, nil
    for _, key in ipairs(self:GetLivingFactionKeys()) do
        local other = self:GetFactionCommandShip(key)
        if shipValid(other) and other ~= anchor and self:IsCommandStation(other) and self:AreEnemies(anchor, other) then
            local d = pos:getDistance(other.Position)
            if closest == nil or d < closest then closest, station = d, other end
        end
    end
    if station == nil or closest >= separation then return pos, nil end
    local dx, dy, dz = pos.x - station.Position.x, pos.y - station.Position.y, pos.z - station.Position.z
    local len = math.sqrt(dx*dx + dy*dy + dz*dz)
    if len < 1 then dx, dy, dz, len = toward.x, toward.y, toward.z, 1 end
    return vec(station.Position.x + dx/len*separation, station.Position.y + dy/len*separation, station.Position.z + dz/len*separation), station
end

-- Fallback when the pulled-back spot is still blocked: the far intersection of
-- the anchor->centre line with a sphere of `distance` around the hostile station,
-- which by construction sits on our own side of the battlefield.
function RTS:FrontLineSpawn(anchor, toward, station, distance)
    local ax, ay, az = anchor.Position.x, anchor.Position.y, anchor.Position.z
    local ex, ey, ez = ax - station.Position.x, ay - station.Position.y, az - station.Position.z
    local b = 2 * (toward.x*ex + toward.y*ey + toward.z*ez)
    local c = ex*ex + ey*ey + ez*ez - distance*distance
    local disc = b*b - 4*c
    if disc >= 0 then
        local t = (-b + math.sqrt(disc)) / 2
        if t > 0 then return vec(ax + toward.x*t, ay + toward.y*t, az + toward.z*t) end
    end
    local e = math.sqrt(ex*ex + ey*ey + ez*ez)
    if e < 1 then e = 1 end
    return vec(station.Position.x + ex/e*distance, station.Position.y + ey/e*distance, station.Position.z + ez/e*distance)
end

-- Never spawn closer than this to any hostile station, clamped against how far
-- apart the two bases actually are. MinEnemyBaseSeparation is an absolute
-- number, but at the CLOSE base distance (12000) it exactly equals the base
-- separation, so EVERY candidate in the forward ring sat between the two bases,
-- tooClose() rejected all 16 retries, and the pull-back path then resolved to
-- the player's own station. Clamp to a fraction of the real separation.
function RTS:GetEnemyBaseSeparation()
    local cap=self.Config.CapitalSpawn or {}
    local want=cap.MinEnemyBaseSeparation or 12000
    if self.GetBaseDistanceProfile~=nil then
        local profile=self:GetBaseDistanceProfile()
        local baseDistance=profile and profile.distance or nil
        if type(baseDistance)=="number" and baseDistance>0 then
            return math.min(want,baseDistance*0.55)
        end
    end
    return want
end
