-- Unit orders, formations, movement, engagement policy.
local Config = require "fs2rts_config"
local U = require "fs2rts_util"
local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys
local RTS = require "fs2rts_state"
local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

function RTS:HoldShip(ship, priority)
    if not self:IsFriendly(ship) then return end
    ship:clearOrders()
    -- Arrived / on station: release the move-order turret lock.
    self:SetShipTurretLock(ship,false)
    ship:giveOrder(ORDER_STAY_STILL, nil, nil, priority or 0.95)
end

function RTS:EngageShip(ship, priority)
    if not shipValid(ship) then return end
    if self.FleetServices and self.FleetServices[ship:getSignature()] then return end
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
    local sig = ship:getSignature()
    self.UserOrders[sig] = order
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
    local service=self:GetFleetServiceLabel(ship)
    if service then return service end
    if self:IsStaticDefense(ship) then return "SENTRY DEFENSE: AUTO TURRETS" end
    if not self:IsFriendly(ship) then
        if ship.Name == self.Config.EnemyCommandShip or ship.Name == self.Config.ThirdCommandShip then return "CAPITAL STATION / DEFEAT OBJECTIVE" end
        local key = self:GetFactionKey(ship)
        local state = key and self.AIOrderState[ship:getSignature()] or nil
        if state and state.label then return state.label end
        return "AI: PRIMARY OBJECTIVE / LOCAL INTERCEPT"
    end
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
    if ship.Name==self.Config.CarrierShip then return "BLUE CAPITAL STATION / PRIMARY DEFENSE" end
    local state=self.AutoPlayerMode and self.AIOrderState[ship:getSignature()]
    if state and state.label then return state.label end
    return "DEFAULT POLICY: "..tostring(self.GlobalPolicy)
end

function RTS:FindNearestHostile(position)
    local best = nil
    local bestDistance = math.huge
    self:EachShip(function(ship)
        if self:IsPlayerEnemy(ship) then
            local distance = ship.Position:getDistance(position)
            if distance < bestDistance then best, bestDistance = ship, distance end
        end
    end)
    return best
end

function RTS:GetRetreatDestination(ship)
    local carrier = self:GetCarrier()
    if not shipValid(carrier) then return copyVec(ship.Position) end

    local threat = self:FindNearestHostile(carrier.Position)
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

function RTS:IsCommandStation(ship)
    if not shipValid(ship) then return false end
    return ship.Name == self.Config.CarrierShip or ship.Name == self.Config.EnemyCommandShip or ship.Name == self.Config.ThirdCommandShip
end

function RTS:IsMovableFriendly(ship)
    return self:IsFriendly(ship) and not self:IsCommandStation(ship) and ship.Name ~= self.Config.ObserverShip and not self:IsStaticDefense(ship)
end

function RTS:IsFiniteNumber(value)
    return type(value) == "number" and value == value and math.abs(value) < 100000000
end

function RTS:IsFiniteVector(value)
    return value ~= nil and self:IsFiniteNumber(value.x) and self:IsFiniteNumber(value.y) and self:IsFiniteNumber(value.z)
end

function RTS:GetCommandArenaHalfExtent()
    local fraction = self.Config.Formation.CommandAreaFraction or 0.90
    return math.max(4500, self:GetTacticalMapHalfExtent() * fraction)
end

function RTS:ClampCommandPoint(point, margin)
    if not self:IsFiniteVector(point) then return nil, true end
    local half = self:GetCommandArenaHalfExtent()
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

-- A shape id is honoured only when it is both a listed type and a defined
-- shape; anything else falls back to the row-packing layout.
function RTS:GetFormationShape(id)
    local F=self.Config.Formation or {}
    local shapes=F.Shapes
    if type(id)~="string" or type(shapes)~="table" or type(shapes[id])~="table" then return nil end
    local types=F.Types
    if type(types)=="table" and #types>0 then
        for _,entry in ipairs(types) do
            if type(entry)=="table" and entry.id==id then return shapes[id] end
        end
        return nil
    end
    return shapes[id]
end

function RTS:GetFormationTypes()
    local F=self.Config.Formation or {}
    return F.Types or {}
end

function RTS:GetSelectedFormation()
    local F=self.Config.Formation or {}
    if self:GetFormationShape(self.SelectedFormation)~=nil then return self.SelectedFormation end
    if self:GetFormationShape(F.Default)~=nil then return F.Default end
    local types=F.Types
    if type(types)=="table" and type(types[1])=="table" and type(types[1].id)=="string" then return types[1].id end
    return nil
end

function RTS:SetSelectedFormation(id)
    if self:GetFormationShape(id)==nil then return false end
    self.SelectedFormation=id
    return true
end

-- (lateral, depth) offsets for a named shape, in ship order.
local function shapeOffsets(n,id,shape,spacing)
    local gap=spacing*(tonumber(shape.spacing) or 1)
    if not (gap>0) then gap=spacing end
    if not (gap>0) then gap=1 end
    local rowDepth=gap*(tonumber(shape.depth) or 1)
    local taper=tonumber(shape.taper) or 0
    local out={}
    for i=1,n do
        local lateral,depth=0,0
        if id=="COLUMN" then
            depth=(i-1)*rowDepth
        elseif id=="TIGHT" then
            local cols=math.ceil(math.sqrt(n))
            lateral=((i-1)%cols-(cols+1)/2)*gap
            depth=math.floor((i-1)/cols)*rowDepth
        elseif id=="WEDGE" then
            local k=i-1
            local row=math.floor((math.sqrt(8*k+1)-1)/2)
            lateral=(k-row*(row+1)/2-row/2)*gap
            depth=row*rowDepth
        elseif id=="ECHELON" then
            lateral=(i-(n+1)/2)*gap
            depth=i*rowDepth*taper
        elseif id=="SCREEN" then
            lateral=(i-(n+1)/2)*gap
            local q=math.abs(lateral)/gap
            -- Positive depth TRAILS behind the core: slots are offset by
            -- -dir*depth, so a negative depth pushed the wings FORWARD of the
            -- centre, i.e. ahead of the target - the exact opposite of a screen
            -- shielding a slow core from a frontal attack.
            depth=q*q*rowDepth*taper
        else
            lateral=(i-(n+1)/2)*gap
        end
        out[i]={lateral=lateral,depth=depth}
    end
    return out
end

-- Legacy radius-aware row packing, kept as the fallback for unknown shapes.
local function packedOffsets(ordered,baseGap,clearance,maxRowWidth)
    local rows = {}; local row = {items={}, width=0, height=0}
    local function flushRow()
        if #row.items > 0 then rows[#rows+1] = row end
        row = {items={}, width=0, height=0}
    end
    for _,item in ipairs(ordered) do
        local diameter = math.max(baseGap, item.radius * 2.20 + clearance)
        local extra = (#row.items > 0) and clearance or 0
        if #row.items > 0 and row.width + extra + diameter > maxRowWidth then flushRow(); extra=0 end
        row.items[#row.items+1] = {size=diameter}
        row.width = row.width + extra + diameter
        row.height = math.max(row.height, diameter)
    end
    flushRow()

    local totalDepth = 0
    for i,r in ipairs(rows) do totalDepth = totalDepth + r.height + (i>1 and clearance or 0) end
    local depthCursor = -totalDepth * 0.5
    local localOffsets = {}
    for _,r in ipairs(rows) do
        local lateralCursor = -r.width * 0.5
        local depth = depthCursor + r.height * 0.5
        for index,item in ipairs(r.items) do
            if index > 1 then lateralCursor = lateralCursor + clearance end
            local lateral = lateralCursor + item.size * 0.5
            localOffsets[#localOffsets+1] = {lateral=lateral, depth=depth}
            lateralCursor = lateralCursor + item.size
        end
        depthCursor = depthCursor + r.height + clearance
    end
    return localOffsets
end

function RTS:BuildSafeFormationDestinations(ships, target, formationId)
    local result = {}
    if ships == nil or #ships == 0 or not self:IsFiniteVector(target) then return result end

    local F = self.Config.Formation or {}
    local arena = self:GetCommandArenaHalfExtent()
    local baseGap = F.Spacing or 450
    local clearance = F.InterShipClearance or 120
    local maxRowWidth = math.max(3000, arena * (F.MaxFormationWidthFraction or 1.10))

    -- Largest hulls first: they take the leading slot instead of dictating a
    -- uniform grid spacing for every fighter in the formation.
    local ordered = {}
    for _,ship in ipairs(ships) do ordered[#ordered+1] = {ship=ship, radius=self:GetShipFormationRadius(ship)} end
    table.sort(ordered, function(a,b) return a.radius > b.radius end)

    local shapeId = nil
    if self:GetFormationShape(formationId) ~= nil then shapeId = formationId
    elseif self:GetFormationShape(F.Default) ~= nil then shapeId = F.Default end
    local localOffsets
    if shapeId ~= nil then
        -- Scale the shape's gap up to fit the LARGEST hull in the group. The
        -- shapes only ever used Formation.Spacing (450 m), so two ~400 m
        -- capitals in LINE_ABREAST were 450 m apart and their hulls
        -- interpenetrated for the whole transit. packedOffsets was the
        -- radius-aware packer, but it is only reachable when no shape resolves,
        -- so it never ran and the only overlap guard in the file was dead.
        local maxRadius=0
        for _,item in ipairs(ordered) do if item.radius>maxRadius then maxRadius=item.radius end end
        local effectiveGap=math.max(baseGap,maxRadius*2.4)
        localOffsets = shapeOffsets(#ordered, shapeId, self:GetFormationShape(shapeId), effectiveGap)
    else
        localOffsets = packedOffsets(ordered, baseGap, clearance, maxRowWidth)
    end
    for index,slot in ipairs(localOffsets) do slot.ship = ordered[index].ship end

    local centerX,centerZ=0,0
    for _,ship in ipairs(ships) do centerX=centerX+ship.Position.x; centerZ=centerZ+ship.Position.z end
    centerX=centerX/#ships; centerZ=centerZ/#ships
    local dirX,dirZ=target.x-centerX,target.z-centerZ
    local len=math.sqrt(dirX*dirX+dirZ*dirZ)
    if len<0.001 then dirX,dirZ,len=math.sin(self.CameraYaw),math.cos(self.CameraYaw),1 end
    dirX,dirZ=dirX/len,dirZ/len
    local rightX,rightZ=dirZ,-dirX

    local maxAbsX,maxAbsZ=0,0
    for _,slot in ipairs(localOffsets) do
        slot.ox=rightX*slot.lateral-dirX*slot.depth
        slot.oz=rightZ*slot.lateral-dirZ*slot.depth
        maxAbsX=math.max(maxAbsX,math.abs(slot.ox)); maxAbsZ=math.max(maxAbsZ,math.abs(slot.oz))
    end

    -- If someone selects an absurd number of giant capitals, shrink the layout
    -- enough to keep every waypoint inside command space instead of ejecting the
    -- formation beyond the tactical map.
    local usable=arena*0.92
    local scale=1
    if maxAbsX>usable then scale=math.min(scale,usable/math.max(1,maxAbsX)) end
    if maxAbsZ>usable then scale=math.min(scale,usable/math.max(1,maxAbsZ)) end
    if scale<1 then
        for _,slot in ipairs(localOffsets) do slot.ox=slot.ox*scale; slot.oz=slot.oz*scale end
        maxAbsX=maxAbsX*scale; maxAbsZ=maxAbsZ*scale
        self:Log(string.format("Formation footprint compressed to %.2f to remain in command arena",scale))
    end

    local safeCenter=vec(target.x,target.y,target.z)
    safeCenter.x=clamp(safeCenter.x,-arena+maxAbsX,arena-maxAbsX)
    safeCenter.z=clamp(safeCenter.z,-arena+maxAbsZ,arena-maxAbsZ)
    safeCenter.y=self.CameraFocus and self.CameraFocus.y or 0

    for _,slot in ipairs(localOffsets) do
        local p=vec(safeCenter.x+slot.ox,safeCenter.y,safeCenter.z+slot.oz)
        local safe=self:ClampCommandPoint(p,self:GetShipFormationRadius(slot.ship)*1.05)
        if safe~=nil then result[#result+1]={ship=slot.ship,destination=safe} end
    end
    return result
end

function RTS:GetOrCreateMoveWaypoint(ship)
    local signature = ship:getSignature()
    local entry = self.MoveWaypoints[signature]
    if entry and entry.waypoint and entry.waypoint:isValid() then
        return entry.waypoint
    end
    -- FSO has no Lua call to delete a waypoint list, so lists of dead ships are
    -- pooled and reused instead of creating one more per ship ever ordered.
    local pool = self.FreeMoveWaypoints
    while #pool > 0 do
        local reused = table.remove(pool)
        if reused.waypoint and reused.waypoint:isValid() then
            reused.waypoint.Position = copyVec(ship.Position)
            self.MoveWaypoints[signature] = reused
            return reused.waypoint
        end
    end

    local listName = "RTS_MOVE_" .. tostring(signature)
    local list = mn.createWaypointList(listName)
    local waypoint = mn.createWaypoint(ship.Position, list)
    self.MoveWaypoints[signature] = { list = list, waypoint = waypoint }
    return waypoint
end

function RTS:ReleaseMoveWaypoint(signature)
    local entry = self.MoveWaypoints[signature]
    self.MoveWaypoints[signature] = nil
    if entry then self.FreeMoveWaypoints[#self.FreeMoveWaypoints + 1] = entry end
end

function RTS:MoveShipTo(ship, destination, priority)
    if not self:IsMovableFriendly(ship) or destination == nil then return false end
    if not self:IsFiniteVector(destination) then
        self:Log("REJECTED non-finite move destination for " .. tostring(ship.Name))
        return false
    end
    local safe,clipped=self:ClampCommandPoint(destination,self:GetShipFormationRadius(ship)*1.05)
    if safe==nil then return false end
    local waypoint=self:GetOrCreateMoveWaypoint(ship)
    if not objectValid(waypoint) then return false end
    ship:clearOrders()
    waypoint.Position=copyVec(safe)
    if ship:giveOrder(ORDER_WAYPOINTS_ONCE,waypoint,nil,priority or 0.95)~=true then return false end
    -- Lock turrets for the duration of the transit. Ship-level guns genuinely
    -- cannot fire under ORDER_WAYPOINTS_ONCE (ai_waypoints never reaches
    -- ship_fire_primary), but turret SUBSYSTEMS are driven by
    -- ai_process_subobjects -> ai_turret_execute_behavior, which has no goal-mode
    -- gate at all: find_turret_enemy picks any hostile in range and fires for the
    -- whole journey past an enemy base. The engine's turret AI returns
    -- immediately when Turret_Lock is set, and the property is writable from Lua,
    -- so this is the only available way to honour a move order.
    self:SetShipTurretLock(ship,true)
    if clipped then self:Log(string.format("Clamped move for %s to %.0f, %.0f, %.0f",ship.Name,safe.x,safe.y,safe.z)) end
    return true
end

-- Turret_Lock is a per-subsystem property; there is no ship-level equivalent.
function RTS:SetShipTurretLock(ship,locked)
    if not shipValid(ship) then return end
    for i=1,#ship do
        local subsystem=ship[i]
        if subsystem~=nil and subsystem:isValid() and subsystem:isTurret() then
            subsystem.TurretLocked=locked and true or false
        end
    end
end

-- One pass over the world per policy refresh, not one per ship: the defender
-- target is a property of the station, not of each unit.
function RTS:GetStationDefendTarget()
    local carrier = self:GetCarrier()
    if not shipValid(carrier) then return nil end
    local radius = self.Config.Policy.DefendRadius or self.Config.AI.StationDefenseRadius or 6500
    local best, bestDistance = nil, math.huge
    self:EachShip(function(ship)
        -- shipAlive, not just IsPlayerEnemy: a hostile in death roll is still
        -- a valid object, so a shipValid-only test let the whole player's fleet
        -- launch at a corpse that was already exploding. shipAlive also covers
        -- the dying flag, which is what a scripted kill leaves behind.
        if self:IsPlayerEnemy(ship) and shipAlive(ship) then
            local d = ship.Position:getDistance(carrier.Position)
            if d <= radius and d < bestDistance then best, bestDistance = ship, d end
        end
    end)
    return best
end

function RTS:ApplyPolicyToShip(ship, force, defendTarget)
    if not self:IsFriendly(ship) or ship.Name == self.Config.CarrierShip or self:IsStaticDefense(ship) then return end
    local sig = ship:getSignature()
    if self.FleetServices and self.FleetServices[sig] then return end
    if self.PossessedSignature == sig or self.UserOrders[sig] ~= nil then return end
    if not force and self.PolicyApplied[sig] == self.GlobalPolicy then return end

    local priority = self.Config.Policy.Priority or 0.65
    local reArmPursuit = false
    if self.GlobalPolicy == "ENGAGE" then
        self:EngageShip(ship, priority)
    elseif self.GlobalPolicy == "RETREAT" then
        self:MoveShipTo(ship, self:GetRetreatDestination(ship), priority)
    elseif self.GlobalPolicy == "HOLD" then
        -- No standing order beyond staying put. This is the default while Auto
        -- Mode is off, so an uncommanded fleet never fights on its own.
        self:HoldShip(ship, priority)
    else
        local carrier = self:GetCarrier()
        if shipValid(carrier) and ship ~= carrier then
            if defendTarget ~= nil and self:AreEnemies(ship, defendTarget) then
                -- Opportunistic intercept instead of orbiting while the station
                -- is under attack. Still anchored: a threat that never comes
                -- inside DefendRadius is never chased.
                --
                -- Through the same gate the AI uses. ORDER_ATTACK on a base
                -- installs a chase goal the engine then refuses to pursue (no
                -- hull lists the command class in +Actively Pursues), so a
                -- strike capital parked on the player's doorstep was never
                -- actually intercepted - the order looked applied and the fleet
                -- sat in guard orbits. This was the only ORDER_ATTACK issued
                -- outside the gate, and it was on the player's own fleet.
                if self:IsPursuitPair(ship, defendTarget) then
                    -- giveOrder's return value is not a success signal, and
                    -- IssuePursuitOrder reports a genuinely failed goal, so a
                    -- refused pursuit falls back to guarding the station rather
                    -- than to an order the engine will not carry out.
                    if not self:IssuePursuitOrder(ship, defendTarget, priority) then
                        self:DropPursuit(sig)
                        ship:clearOrders()
                        ship:giveOrder(ORDER_GUARD, carrier, nil, priority)
                    else
                        reArmPursuit = true
                    end
                else
                    ship:clearOrders()
                    ship:giveOrder(ORDER_ATTACK, defendTarget, nil, priority)
                end
            else
                ship:clearOrders()
                ship:giveOrder(ORDER_GUARD, carrier, nil, priority)
            end
        else
            self:HoldShip(ship, priority)
        end
    end
    self.PolicyApplied[sig] = self.GlobalPolicy
    -- A pursuit is anchored to a 4 s lead point and the goal ends on arrival,
    -- so an interceptor has to be re-anchored or it flies there once and then
    -- holds a stale point while the threat sails away. RefreshAIPursuit only
    -- re-anchors automatic AI units, and a player ship is not one, so the
    -- re-arm is handed to the policy refresh instead: leaving PolicyApplied
    -- clear makes UpdateDefaultPolicy re-issue this ship on its next pass.
    if reArmPursuit then self.PolicyApplied[sig] = nil end
    if defendTarget ~= nil then self.PolicyDefend[sig] = defendTarget:getSignature() else self.PolicyDefend[sig] = nil end
end

function RTS:SetGlobalPolicy(policy)
    if policy ~= "STANDOFF" and policy ~= "ENGAGE" and policy ~= "RETREAT" and policy ~= "HOLD" then return end
    if self.AutoPlayerMode then return end
    if self.GlobalPolicy == policy then return end
    self.GlobalPolicy = policy
    self.PolicyApplied = {}
    self.PolicyDefend = {}
    local defend = self.GlobalPolicy == "STANDOFF" and self:GetStationDefendTarget() or nil
    if not self.AutoPlayerMode then
        self:EachShip(function(ship)
            if self:IsFriendly(ship) and ship.Name ~= self.Config.CarrierShip and not self:IsStaticDefense(ship) then self:ApplyPolicyToShip(ship,true,defend) end
        end)
    end
    local label = policy == "RETREAT" and "RETREAT TO SAFE DISTANCE" or policy
    self:SetStatus("Default policy: " .. label .. " (manual orders override)", 3)
end

function RTS:UpdateDefaultPolicy(now)
    local interval=self.Config.Policy.RefreshInterval or 20
    if now-self.LastPolicyRefresh<interval then return end; self.LastPolicyRefresh=now
    -- Clean dead/invalid manual targets in both manual and Auto Mode. Once an
    -- explicit attack/guard target is gone, automatic control may resume.
    for sig,order in pairs(self.UserOrders) do
        local ship=self:FindShipBySignature(sig)
        if not shipValid(ship) then self.UserOrders[sig]=nil; self.PolicyApplied[sig]=nil
        elseif (order.kind=="attack" or order.kind=="guard" or order.kind=="attack_wing") and order.targetSignature~=nil then
            local target=order.kind=="attack_wing" and self:ResolveAttackWingTarget(order) or self:FindShipBySignature(order.targetSignature)
            if shipValid(target) then
                if order.kind=="attack_wing" and target:getSignature()~=order.targetSignature then
                    order.targetSignature=target:getSignature()
                    self:ReissueUserOrder(ship,order)
                end
            else self.UserOrders[sig]=nil; self.PolicyApplied[sig]=nil end
        end
    end
    if self.AutoPlayerMode then return end
    -- Not forced: only ships that do not already carry the current policy
    -- (new builds, ships just released from a player order). Forcing this every
    -- tick cleared and re-gave every idle ship's orders, resetting fights in
    -- progress. Policy changes and order hand-backs still force.
    -- The STANDOFF intercept is the exception: an appearing threat has to be
    -- able to pull units off the station orbit, so the defend target is part of
    -- the policy identity rather than a forced reissue.
    local defend = self.GlobalPolicy == "STANDOFF" and self:GetStationDefendTarget() or nil
    local defendSig = defend ~= nil and defend:getSignature() or nil
    self:EachShip(function(ship)
        if self:IsFriendly(ship) and ship.Name~=self.Config.CarrierShip and not self:IsStaticDefense(ship) then
            local sig=ship:getSignature()
            if self.UserOrders[sig]==nil and self.PossessedSignature~=sig then
                if self.PolicyDefend[sig] ~= defendSig then self.PolicyApplied[sig]=nil end
                self:ApplyPolicyToShip(ship,false,defend)
            end
        end
    end)
end

function RTS:ReissueUserOrder(ship, order)
    if not self:IsFriendly(ship) or order == nil then return false end
    if self.FleetServices and self.FleetServices[ship:getSignature()] then return false end
    if order.kind == "hold" then
        self:HoldShip(ship, 0.95)
        return true
    elseif order.kind == "engage" then
        self:EngageShip(ship, 0.95)
        return true
    elseif order.kind == "move" and order.destination ~= nil then
        self:MoveShipTo(ship, order.destination, 0.95)
        return true
    elseif order.kind == 'wing' then
        local pilot=self:FindShipBySignature(self.PossessedSignature)
        if shipAlive(pilot) then
            ship:clearOrders()
            return ship:giveOrder(ORDER_GUARD,pilot,nil,.95)==true
        end
    elseif (order.kind == "attack" or order.kind == "guard" or order.kind == "attack_wing") and order.targetSignature ~= nil then
        local target = order.kind=="attack_wing" and self:ResolveAttackWingTarget(order) or self:FindShipBySignature(order.targetSignature)
        if shipValid(target) then
            if order.kind=="attack_wing" then order.targetSignature=target:getSignature() end
            if (order.kind == "attack" or order.kind=="attack_wing") and not self:AreEnemies(ship,target) then
                self:ClearUserOrder(ship)
                self:ReturnToDefaultControl(ship)
                return false
            end
            ship:clearOrders()
            if order.kind == "attack" or order.kind=="attack_wing" then ship:giveOrder(ORDER_ATTACK, target, nil, 0.95)
            else ship:giveOrder(ORDER_GUARD, target, nil, 0.95) end
            return true
        end
    end

    self:ClearUserOrder(ship)
    self:ReturnToDefaultControl(ship)
    return false
end

-- Reconcile player movement orders the engine has taken away.
--
-- When a moving fighter/bomber is hit, ai_ship_hit deliberately lets
-- AIM_WAYPOINTS fall through into maybe_set_dynamic_chase, which switches the
-- ship to AIM_CHASE with resume_goal_time = Missiontime + 20. Nothing in the
-- scripting API can suppress that. The consequence was that a move order
-- simply evaporated: the ship peeled off, shot for 20 s, and then sat in
-- AIM_NONE, while UpdateDefaultPolicy skips anything carrying a UserOrder so
-- nothing else re-issued it. Re-issue instead, so the ship resumes its move
-- rather than parking where the fight was.
function RTS:ReconcileMoveOrders(now)
    if self.SetupActive or self.PostBattleActive or self.PossessedSignature~=nil then return end
    if now<(self.NextMoveReconcile or 0) then return end
    self.NextMoveReconcile=now+2
    -- getSignature() on an invalid handle raises, so guard it the way
    -- GetNativeObjectiveStatus does rather than trusting the order entry.
    local function sigOf(handle)
        if handle==nil then return nil end
        local ok,value=pcall(function() return handle:getSignature() end)
        if ok and type(value)=="number" then return value end
        return nil
    end
    for sig,order in pairs(self.UserOrders or {}) do
        if order.kind=="move" and self:IsFiniteVector(order.destination) then
            local ship=self:FindShipBySignature(sig)
            if shipAlive(ship) and not (self.FleetServices and self.FleetServices[sig]) then
                local entry=self.MoveWaypoints[sig]
                local intact=false
                local orders=ship.Orders
                for i=1,#orders do
                    local o=orders[i]
                    if o~=nil then
                        local valid,kind=pcall(function() return o:isValid() and o:getType() or nil end)
                        if valid and kind==ORDER_WAYPOINTS_ONCE and entry~=nil
                            and sigOf(o.Target)==sigOf(entry.waypoint) then intact=true end
                    end
                end
                if not intact then
                    if self:ReissueUserOrder(ship,order) then
                        self:Log(string.format("Re-issued lost move order for %s (engine diverted the ship)",ship.Name))
                    end
                end
            end
        end
    end
end

function RTS:HoldSelected()
    local issued = 0
    for _, ship in ipairs(self:GetSelectedFriendlyShips()) do
        if not self:IsCommandStation(ship) then
            self:SetUserOrder(ship, { kind = "hold" })
            self:HoldShip(ship, 0.95)
            issued = issued + 1
        end
    end
    if issued > 0 then self:SetStatus("Hold position", 2) end
end

function RTS:EngageSelected()
    local issued = 0
    for _, ship in ipairs(self:GetSelectedFriendlyShips()) do
        if not self:IsCommandStation(ship) then
            self:SetUserOrder(ship, { kind = "engage" })
            self:EngageShip(ship, 0.95)
            issued = issued + 1
        end
    end
    if issued > 0 then self:SetStatus("Engage hostiles", 2) end
end

function RTS:IssueMove(target,facing)
    if target==nil or not self:IsFiniteVector(target) then return end
    local selected=self:GetSelectedFriendlyShips(); local ships={}
    for _,ship in ipairs(selected) do if self:IsMovableFriendly(ship) then ships[#ships+1]=ship end end
    if #ships==0 then
        if #selected>0 then self:SetStatus("Command stations are fixed installations and cannot move",2.5) end
        return
    end

    local safeTarget,clipped=self:ClampCommandPoint(target,0)
    if safeTarget==nil then self:SetStatus("Invalid movement point rejected",2.5); return end
    local slots=self:BuildSafeFormationDestinations(ships,safeTarget,self:GetSelectedFormation())
    local issued=0
    for _,slot in ipairs(slots) do
        -- Record the order only once the engine accepted it: a recorded move with
        -- no waypoint goal never completes, and policy skips ordered ships.
        if self:MoveShipTo(slot.ship,slot.destination,0.95) then
            -- manual marks a directional (right-drag) command. OnWaypointsDone
            -- keeps manual orders out of the AI pool on arrival, so the drag
            -- result is the player's to keep rather than something the fleet
            -- doctrine re-tasks the next tick. A tap-to-move leaves it nil.
            local facingValue=(facing~=nil and self:IsFiniteVector(facing)) and copyVec(facing) or nil
            self:SetUserOrder(slot.ship,{kind="move",destination=copyVec(slot.destination),facing=facingValue,manual=facingValue~=nil})
            issued=issued+1
        end
    end
    if issued==0 then self:SetStatus("No valid movement orders issued",2.5); return end
    self.CommandMarker=copyVec(safeTarget); self.CommandMarkerUntil=self:UINow()+1.2
    self:SetStatus((clipped and "Move clamped to tactical area" or "Move formation").." // "..tostring(issued).." ships",1.8)
end

-- Right-drag move orders carry a facing point. FSO's set-object-facing SEXP only
-- rotates for as long as it is re-issued each frame, so the turn has to be driven
-- from the frame loop rather than fired once with the order.
-- Arrival is not detected here: a move order is ORDER_WAYPOINTS_ONCE, so the
-- engine fires $On Waypoints Done and OnWaypointsDone performs the move->hold
-- transition (preserving the commanded facing) exactly once.
function RTS:UpdateMoveFacings()
    if self.SetupActive or self.PostBattleActive or self.PossessedSignature~=nil then return end
    for sig,order in pairs(self.UserOrders or {}) do
        if (order.kind=="move" or order.kind=="hold") and order.facing~=nil and self:IsFiniteVector(order.facing) then
            local ship=self:FindShipBySignature(sig)
            if not shipAlive(ship) or (order.kind=="move" and not self:IsFiniteVector(order.destination)) then
                order.facing=nil
            else
                -- Aim at a point beyond the ship along the drag direction rather
                -- than at the facing point itself, so the hull actually turns.
                -- A hold carrying a facing is a ship that has ARRIVED and must
                -- keep the commanded heading, so it uses its current position
                -- as the origin; a move aims from its destination.
                local ox,oz
                if order.kind=="hold" then ox,oz=ship.Position.x,ship.Position.z
                else ox,oz=order.destination.x,order.destination.z end
                local dx=order.facing.x-ox; local dz=order.facing.z-oz
                local length=math.sqrt(dx*dx+dz*dz)
                if length>1 then
                    local nx,nz=dx/length,dz/length
                    -- Stop driving the turn once the hull is pointing at it. The
                    -- facing was only cleared on death or a bad destination, so
                    -- one right-drag pinned that ship to a per-frame SEXP parse
                    -- (string.format + a full SEXP lex/parse/evaluate, plus a
                    -- registry name lookup) for the rest of the match - 64 such
                    -- ships is ~3,800 parses/second, dwarfing every other
                    -- per-frame subsystem in the mod.
                    local fvec=nil
                    local ok=pcall(function() fvec=ship:getfvec(true) end)
                    if ok and fvec~=nil then
                        local dot=fvec.x*nx+fvec.z*nz
                        if dot>0.995 then
                            order.facing=nil
                        else
                            local aim=vec(ox+nx*10000,ship.Position.y,oz+nz*10000)
                            mn.runSEXP(string.format('(set-object-facing "%s" %.1f %.1f %.1f 2200 1)',ship.Name,aim.x,aim.y,aim.z))
                        end
                    else
                        local aim=vec(ox+nx*10000,ship.Position.y,oz+nz*10000)
                        mn.runSEXP(string.format('(set-object-facing "%s" %.1f %.1f %.1f 2200 1)',ship.Name,aim.x,aim.y,aim.z))
                    end
                end
            end
        end
    end
end

function RTS:IssueAttack(target)
    local ships = self:GetSelectedFriendlyShips()
    if #ships == 0 or not self:IsPlayerEnemy(target) then return end
    local targetSig = target:getSignature()
    local wing=self:GetLogicalWing(target)
    local wingMembers=0
    if wing~=nil then
        for _,sig in ipairs(wing.signatures or {}) do
            local member=self:FindShipBySignature(sig)
            if shipAlive(member) and self:IsPlayerEnemy(member) then wingMembers=wingMembers+1 end
        end
    end
    local orderKind=wingMembers>1 and "attack_wing" or "attack"
    for _, ship in ipairs(ships) do
        self:SetUserOrder(ship, { kind = orderKind, targetSignature = targetSig, targetWing = orderKind=="attack_wing" and wing.id or nil })
        ship:clearOrders()
        ship:giveOrder(ORDER_ATTACK, target, nil, 0.95)
    end
    self:SetStatus((orderKind=="attack_wing" and "Attack wing: " or "Attack: ") .. (wing and wing.label or target.Name), 2)
end

function RTS:IssueGuard(target)
    local ships = self:GetSelectedFriendlyShips()
    if #ships == 0 or not self:IsFriendly(target) then return end
    local targetSig = target:getSignature()
    for _, ship in ipairs(ships) do
        if ship ~= target then
            self:SetUserOrder(ship, { kind = "guard", targetSignature = targetSig })
            ship:clearOrders()
            ship:giveOrder(ORDER_GUARD, target, nil, 0.95)
        end
    end
    self:SetStatus("Guard: " .. target.Name, 2)
end

-- Who is driving a ship right now: "pilot", "order" (player), "auto"
-- (Auto Mode AI), "policy", "station" or "enemy". Drives the selection UI.
function RTS:GetShipController(ship)
    if not self:IsFriendly(ship) then return "enemy" end
    local sig=ship:getSignature()
    if self.PossessedSignature==sig then return "pilot" end
    if self:IsCommandStation(ship) then return "station" end
    if self:IsStaticDefense(ship) then return "sentry" end
    if self.UserOrders[sig]~=nil then return "order" end
    if self.AutoPlayerMode then return "auto" end
    return "policy"
end

local POLICY_SUMMARY={HOLD="hold position until ordered",STANDOFF="escort Blue Station",ENGAGE="hunt enemies",RETREAT="pull back behind station"}

-- One readable line saying who controls the ship and what it is doing.
function RTS:GetShipControlDescription(ship)
    local service=self:GetFleetServiceLabel(ship)
    if service and self.PossessedSignature~=ship:getSignature() then return service end
    local controller=self:GetShipController(ship)
    if controller=="pilot" then return "PILOTED BY YOU" end
    if controller=="station" then return "COMMAND STATION" end
    if controller=="sentry" then return "SENTRY GUN: STATIONARY AUTO DEFENSE" end
    if controller=="enemy" then return self:GetShipCommandLabel(ship) end
    local sig=ship:getSignature()
    if controller=="order" then
        local order=self.UserOrders[sig]
        local target=order.targetSignature and self:FindShipBySignature(order.targetSignature)
        if shipValid(target) then return "YOUR ORDER: "..string.upper(order.kind).." "..target.Name end
        if order.kind=="move" then return "YOUR ORDER: MOVE to point" end
        if order.kind=="hold" then return "YOUR ORDER: HOLD position" end
        if order.kind=="engage" then return "YOUR ORDER: ENGAGE hostiles" end
        if order.kind=="wing" then return "YOUR WING: NATIVE SQUAD COMMANDS" end
        return "YOUR ORDER: "..string.upper(tostring(order.kind))
    end
    if controller=="auto" then
        local state=self.AIOrderState[sig]
        return "AUTO MODE: "..((state and state.label) or "awaiting orders")
    end
    return "POLICY: "..tostring(self.GlobalPolicy).." ("..(POLICY_SUMMARY[self.GlobalPolicy] or "default")..")"
end

-- Hand selected ships back from player orders to the policy / Auto Mode.
function RTS:ReleaseSelected()
    local released=0
    for _,ship in ipairs(self:GetSelectedFriendlyShips()) do
        local order=self.UserOrders[ship:getSignature()]
        if order~=nil and order.kind~="pilot" and self:IsMovableFriendly(ship) then
            self:ClearUserOrder(ship)
            self:ReturnToDefaultControl(ship)
            released=released+1
        end
    end
    if released>0 then
        self:SetStatus("Released "..released.." ships to "..(self.AutoPlayerMode and "Auto Mode" or ("policy: "..tostring(self.GlobalPolicy))),2.5)
    else
        self:SetStatus("No selected ships are under your orders",2)
    end
end

-- MOVE / ATTACK buttons arm the next left click as that order.
function RTS:ArmCommand(kind)
    if self.ArmedCommand==kind then self.ArmedCommand=nil; return end
    local movable=0
    for _,ship in ipairs(self:GetSelectedFriendlyShips()) do if self:IsMovableFriendly(ship) then movable=movable+1 end end
    if movable==0 then self:SetStatus("Select your ships first",2); return end
    self.ArmedCommand=kind
    self:SetStatus(kind=="move" and "MOVE: left-click a destination (right-click cancels)" or "ATTACK: left-click an enemy (right-click cancels)",3)
end

-- Returns true when the click was consumed by an armed command.
function RTS:ExecuteArmedCommand(x,y)
    local kind=self.ArmedCommand
    if kind==nil then return false end
    if kind=="sentry" or kind=="strike" then
        local station=self:GetCarrier()
        self:ExecuteStationArmedCommand(self:ScreenToPlane(x,y,station and station.Position.y or self.CameraFocus.y))
        return true
    end
    if kind=="move" then
        local destination=self:ScreenToPlane(x,y,self.CameraFocus.y)
        if destination then self:IssueMove(destination) end
        self.ArmedCommand=nil
    else
        local hostile=self:GetShipAtScreen(x,y,false,true)
        if hostile then self:IssueAttack(hostile); self.ArmedCommand=nil
        else self:SetStatus("ATTACK: click an enemy ship (right-click cancels)",2) end
    end
    return true
end
