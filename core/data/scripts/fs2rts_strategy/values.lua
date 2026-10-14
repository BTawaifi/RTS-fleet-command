-- Strategic values, pursuit constants and role lists.
local _shared = require "fs2rts_strategy.common"
local RTS, shipValid, shipAlive, canAutoEngage = _shared.RTS, _shared.shipValid, _shared.shipAlive, _shared.canAutoEngage

local Config = require "fs2rts_config"

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
        if shipAlive(old) and self:IsFactionEnabled(self:GetFactionKey(old)) and shipAlive(source) and canAutoEngage(self,source,old) then return old end
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
