-- Ship predicates, per-frame ship list and lookup helpers.
local _shared = require "fs2rts_factions.common"
local RTS, lower, shipValid = _shared.RTS, _shared.lower, _shared.shipValid

function RTS:IsRTSMission()
    local filename = lower(mn.getMissionFilename())
    return self.Config.MissionNames[filename] == true
end

function RTS:IsFriendly(ship)
    return shipValid(ship) and self:GetFactionKey(ship)=="BLUE"
end

function RTS:IsHostile(ship)
    local kind=shipValid(ship) and self:GetFactionKey(ship) or nil
    return kind~=nil and kind~="BLUE"
end

function RTS:IsThirdFaction(ship)
    local kind=shipValid(ship) and self:GetFactionKey(ship) or nil
    local index=kind and self.Config.FactionIndex and self.Config.FactionIndex[kind]
    return index~=nil and index>=3
end

function RTS:IsPlayerEnemy(ship)
    local kind=shipValid(ship) and self:GetFactionKey(ship) or nil
    return kind~=nil and kind~="BLUE"
end

function RTS:IsSelectableShip(ship)
    return shipValid(ship) and ship.Name ~= self.Config.ObserverShip
end

-- One ship list per frame instead of re-walking mn.Ships (a fresh handle per
-- ship per call) 6-8 times per HUD frame. OnFrame drops it each frame and
-- InvalidateShipList() drops it after every createShip; dead ships are
-- filtered by the isValid check on iteration.
function RTS:GetShipList()
    local list = self.ShipCache
    if list == nil then
        list = {}
        for i = 1, #mn.Ships do
            local ship = mn.Ships[i]
            if shipValid(ship) then list[#list + 1] = ship end
        end
        self.ShipCache = list
    end
    return list
end

function RTS:InvalidateShipList()
    self.ShipCache = nil
    self.ShipSignatureIndex = nil
end

function RTS:EachShip(callback)
    for _, ship in ipairs(self:GetShipList()) do
        if ship:isValid() then callback(ship) end
    end
end

function RTS:FindShipBySignature(signature)
    if type(signature)~="number" or signature<=0 or signature>2147483647 or signature~=signature or signature~=math.floor(signature) then return nil end
    -- Native lookup walks all used objects, including projectiles. Reuse the
    -- current frame's ship handles for ordinary repeated queries.
    local index=self.ShipSignatureIndex
    if index==nil then
        index={}
        for _,ship in ipairs(self:GetShipList()) do
            if shipValid(ship) then index[ship:getSignature()]=ship end
        end
        self.ShipSignatureIndex=index
    end
    local cached=index[signature]
    if shipValid(cached) then return cached end
    -- A script outside this mod can create a hull after the frame list was
    -- built. Do not cache misses: retain the used/create-list fallback.
    local object = mn.getObjectFromSignature(signature)
    if object ~= nil and object:isValid() and object:getBreedName() == "Ship" then index[signature]=object; return object end
    -- obj_get_by_signature only walks obj_used_list. A freshly created hull
    -- is already in mn.Ships but stays in obj_create_list until frame merge.
    -- Resolve it through the ship collection during that short interval.
    for i=1,#mn.Ships do
        local ship=mn.Ships[i]
        if shipValid(ship) and ship:getSignature()==signature then index[signature]=ship; return ship end
    end
    return nil
end

function RTS:GetObserver()
    local ship = mn.Ships[self.Config.ObserverShip]
    if shipValid(ship) then return ship end
    return nil
end

function RTS:GetCarrier()
    local ship = mn.Ships[self.Config.CarrierShip]
    if shipValid(ship) then return ship end
    return nil
end

function RTS:GetEnemyCommand()
    local ship = mn.Ships[self.Config.EnemyCommandShip]
    if shipValid(ship) then return ship end
    return nil
end

function RTS:GetThirdCommand()
    local ship = mn.Ships[self.Config.ThirdCommandShip]
    if shipValid(ship) then return ship end
    return nil
end
