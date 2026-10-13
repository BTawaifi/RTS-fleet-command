-- Unit orders: hold, engage, user orders and target rules.
local _shared = require "fs2rts_orders.common"
local U, RTS, shipValid, shipAlive, copyVec, vec, clamp = _shared.U, _shared.RTS, _shared.shipValid, _shared.shipAlive, _shared.copyVec, _shared.vec, _shared.clamp

local Config = require "fs2rts_config"

local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys

local BASE_DAMAGE_ROLES={bomber=true,escort=true,capital=true,heavy=true,juggernaut=true}

function RTS:HoldShip(ship, priority)
    if not self:IsFriendly(ship) then return end
    self:SetShipCommandDiscipline(ship,true)
    ship:clearOrders()
    -- Arrived / on station: release the move-order turret lock.
    self:SetShipTurretLock(ship,false)
    ship:giveOrder(ORDER_STAY_STILL, nil, nil, priority or 0.95)
end

function RTS:EngageShip(ship, priority)
    if not shipValid(ship) then return end
    if self.FleetServices and self.FleetServices[ship:getSignature()] then return end
    self:SetShipCommandDiscipline(ship,false)
    ship:clearOrders()
    self:SetShipTurretLock(ship,false)
    local sig=ship:getSignature()
    self.EngageTargets[sig]=nil
    if self:GetShipRole(ship)=="bomber" then
        local target=self:FindBomberPriorityTarget(ship)
        if shipValid(target) then
            -- A single-target goal ends when the target dies; OnShipDeath uses
            -- this to re-engage instead of leaving the bomber idle.
            self.EngageTargets[sig]=target:getSignature()
            ship:giveOrder(ORDER_ATTACK,target,nil,priority or 0.95); return
        end
    end
    ship:giveOrder(ORDER_ATTACK_ANY,nil,nil,priority or 0.95)
end

function RTS:SetUserOrder(ship, order)
    if not self:IsMovableFriendly(ship) then return end
    if order.kind=="attack" or order.kind=="attack_wing" then
        local target=self:FindShipBySignature(order.targetSignature)
        if not self:CanDamageCommandStation(ship,target) then return false end
    end
    local sig = ship:getSignature()
    self.UserOrders[sig] = order
    self:SetShipCommandDiscipline(ship,order.kind=='move' or order.kind=='hold')
    self:DropPursuit(sig)
    if order.kind~='move' and order.kind~='service' then self:SetShipTurretLock(ship,false) end
    -- A fresh manual order genuinely frees the ship. Dropping only the record
    -- left the service waypoint and its cached slot live, so the ship kept
    -- drifting back to the station after the player had re-tasked it.
    if order.kind~='service' and self.FleetServices and self.FleetServices[sig] then
        self.FleetServices[sig].destination=nil
        self.FleetServices[sig].destinationAnchor=nil
        self.FleetServices[sig].holdSince=nil
        self.FleetServices[sig]=nil
    end
    self.PolicyApplied[sig] = nil
    -- Drop any Auto Mode objective: OnShipDeath clearOrders() every ship whose
    -- AIOrderState targets the dead ship, which silently wiped player orders.
    self.AIOrderState[sig] = nil
end

-- Hand a ship with no player order back to whoever owns it by default.
function RTS:ReturnToDefaultControl(ship)
    if not shipValid(ship) then return end
    if self.FleetServices and self.FleetServices[ship:getSignature()] then return end
    if self:IsStaticDefense(ship) then return end
    self:SetShipCommandDiscipline(ship,false)
    self:SetShipTurretLock(ship,false)
    if self:IsCommandStation(ship) then self:HoldShip(ship, .70); return end
    if self.AutoPlayerMode then
        -- AssignAIStrategicOrder can decline (no primary target yet); clear first
        -- so a stale goal such as PLAY_DEAD or a dead attack target cannot linger.
        ship:clearOrders()
        self:AssignAIStrategicOrder(ship, "BLUE", true)
    else
        self:ApplyPolicyToShip(ship, true)
    end
end

function RTS:ClearUserOrder(ship)
    if not shipValid(ship) then return end
    local sig = ship:getSignature()
    self.UserOrders[sig] = nil
    self:SetShipCommandDiscipline(ship,false)
    self:DropPursuit(sig)
    self.PolicyApplied[sig] = nil
end

function RTS:ResolveAttackWingTarget(order, excludedSignature)
    local wing=order and order.targetWing and self.RTSWings and self.RTSWings[order.targetWing]
    if wing==nil then return nil end
    local function eligible(signature)
        if signature==excludedSignature then return nil end
        local target=self:FindShipBySignature(signature)
        if shipAlive(target) and self:IsPlayerEnemy(target) then return target end
    end
    local target=eligible(order.targetSignature)
    if target~=nil then return target end
    for _,signature in ipairs(wing.signatures or {}) do
        target=eligible(signature)
        if target~=nil then return target end
    end
    return nil
end

function RTS:HandleAttackWingTargetDeath(deadSignature)
    for sig,order in pairs(self.UserOrders or {}) do
        if order.kind=="attack_wing" and order.targetSignature==deadSignature then
            local owner=self:FindShipBySignature(sig)
            local target=self:ResolveAttackWingTarget(order,deadSignature)
            if shipValid(owner) and shipValid(target) then
                order.targetSignature=target:getSignature()
                self:ReissueUserOrder(owner,order)
            else
                self.UserOrders[sig]=nil; self.PolicyApplied[sig]=nil
                if shipValid(owner) then owner:clearOrders(); self:ReturnToDefaultControl(owner) end
            end
        end
    end
end

function RTS:GetShipCommandLabel(ship)
    if not shipValid(ship) then return "-" end
    if not self:IsFriendly(ship) then return self:IsCommandStation(ship) and "COMMAND STATION" or "ENEMY CONTACT" end
    local service=self:GetFleetServiceLabel(ship)
    if service then return service end
    if self:IsStaticDefense(ship) then return "SENTRY DEFENSE: AUTO TURRETS" end
    local order=self.UserOrders[ship:getSignature()]
    if order~=nil then
        if order.kind=="attack" then return "PLAYER ORDER: ATTACK"
        elseif order.kind=="attack_wing" then return "PLAYER ORDER: ATTACK WING"
        elseif order.kind=="guard" then return "PLAYER ORDER: GUARD"
        elseif order.kind=="move" then return "PLAYER ORDER: MOVE"
        elseif order.kind=="hold" then return "PLAYER ORDER: HOLD"
        elseif order.kind=="engage" then return "PLAYER ORDER: ENGAGE"
        elseif order.kind=="pilot" then return "PLAYER ORDER: PILOT CONTROL"
        elseif order.kind=="wing" then return "PLAYER WING: NATIVE SQUAD COMMANDS" end
    end
    if self:IsCommandStation(ship) and self:GetFactionKey(ship)=="BLUE" then return self:GetFactionDisplayName("BLUE").." STATION / PRIMARY DEFENSE" end
    local state=self.AutoPlayerMode and self.AIOrderState[ship:getSignature()]
    if state and state.label then return state.label end
    return "DEFAULT POLICY: "..tostring(self.GlobalPolicy)
end

function RTS:FindNearestHostile(position,attacker)
    local best = nil
    local bestDistance = math.huge
    self:EachShip(function(ship)
        if self:IsPlayerEnemy(ship) and (not attacker or not self.CanAutoEngage or self:CanAutoEngage(attacker,ship)) then
            local distance = ship.Position:getDistance(position)
            if distance < bestDistance then best, bestDistance = ship, distance end
        end
    end)
    return best
end

function RTS:GetRetreatDestination(ship)
    local carrier = self:GetCarrier()
    if not shipValid(carrier) then return copyVec(ship.Position) end

    local threat = self:FindNearestHostile(carrier.Position,carrier)
    local dx, dz
    if shipValid(threat) then
        dx = carrier.Position.x - threat.Position.x
        dz = carrier.Position.z - threat.Position.z
    else
        local forward = carrier.Orientation:getFvec()
        dx = -forward.x
        dz = -forward.z
    end

    local length = math.sqrt(dx * dx + dz * dz)
    if length < 0.001 then dx, dz, length = 0, -1, 1 end
    dx, dz = dx / length, dz / length
    local sideX, sideZ = -dz, dx

    local policy = self.Config.Policy
    local sig = ship:getSignature()
    local slot = (sig % 7) - 3
    local spread = slot * ((policy.RetreatSpread or 900) / 6)
    local distance = policy.RetreatDistance or 2800

    return vec(
        carrier.Position.x + dx * distance + sideX * spread,
        carrier.Position.y,
        carrier.Position.z + dz * distance + sideZ * spread
    )
end

function RTS:CanDamageCommandStation(ship,target)
    return not self:IsCommandStation(target) or self:CanDamageBase(ship) or self:GetShipRole(ship)=='fighter'
end

function RTS:CanDamageBase(ship)
    -- AI siege capability; player fighter chip attacks use CanDamageCommandStation.
    return BASE_DAMAGE_ROLES[self:GetShipRole(ship)]==true
end

function RTS:IsMovableFriendly(ship)
    return self:IsFriendly(ship) and not (self.IsShipWithdrawing and self:IsShipWithdrawing(ship))
        and not self:IsCommandStation(ship) and ship.Name ~= self.Config.ObserverShip and not self:IsStaticDefense(ship)
end

function RTS:IsFiniteNumber(value)
    return type(value) == "number" and value == value and math.abs(value) < 100000000
end

function RTS:IsFiniteVector(value)
    return value ~= nil and self:IsFiniteNumber(value.x) and self:IsFiniteNumber(value.y) and self:IsFiniteNumber(value.z)
end

function RTS:GetCommandArenaHalfExtent()
    local fraction = self.Config.Formation.CommandAreaFraction or 0.90
    return math.max(4500, self:GetBattleMapHalfExtent() * fraction)
end

function RTS:ClampCommandPoint(point, margin, withdrawal)
    if not self:IsFiniteVector(point) then return nil, true end
    local half = self:GetCommandArenaHalfExtent()
    if withdrawal then half=math.max(half,self:GetTacticalMapHalfExtent()*(self.Config.Formation.CommandAreaFraction or .90)) end
    margin = math.max(0, margin or 0)
    local bound = math.max(500, half - math.min(margin, half * 0.40))
    local x = clamp(point.x, -bound, bound)
    local z = clamp(point.z, -bound, bound)
    -- Keep vertical commands bounded too. ScreenToPlane normally supplies one
    -- stable battle-plane Y, but a focused/chase camera must never create a
    -- thousands-of-kilometres vertical waypoint.
    local vertical = half * (self.Config.Formation.VerticalCommandFraction or 0.35)
    local y = clamp(point.y, -vertical, vertical)
    local clipped = math.abs(x-point.x) > 0.01 or math.abs(z-point.z) > 0.01 or math.abs(y-point.y) > 0.01
    return vec(x,y,z), clipped
end

function RTS:GetShipFormationRadius(ship)
    if not shipValid(ship) then return 80 end
    local ok, radius = pcall(function() return ship.Class.Model.Radius end)
    if not ok or not self:IsFiniteNumber(radius) or radius <= 0 then return 80 end
    return radius
end
