-- Movement: destinations, safe formation spots and move waypoints.
local _shared = require "fs2rts_orders.common"
local RTS, shipAlive, vec, clamp, copyVec, objectValid, shapeOffsets, packedOffsets = _shared.RTS, _shared.shipAlive, _shared.vec, _shared.clamp, _shared.copyVec, _shared.objectValid, _shared.shapeOffsets, _shared.packedOffsets

function RTS:ClearStationDestination(ship,point,margin)
    local station=self:GetFactionCommandShip(self:GetFactionKey(ship))
    if not shipAlive(station) then return point,false end
    local radius=(station.Class.Model and station.Class.Model.Radius or 500)+(margin or 0)+300
    local delta=point-station.Position; local distance=delta:getDistance(vec(0,0,0))
    if distance>=radius then return point,false end
    if distance<1 then delta=ship.Position-station.Position; distance=delta:getDistance(vec(0,0,0)) end
    if distance<1 then delta=vec(0,0,-1); distance=1 end
    return station.Position+delta*(radius/distance),true
end

function RTS:ClampShipDestination(ship,point)
    local margin=self:GetShipFormationRadius(ship)*1.05
    local safe,clipped=self:ClampCommandPoint(point,margin)
    if not safe then return nil end
    local shifted
    safe,shifted=self:ClearStationDestination(ship,safe,margin)
    local bounded,edge=self:ClampCommandPoint(safe,margin)
    if not bounded then return nil end
    local _,overlap=self:ClearStationDestination(ship,bounded,margin)
    if overlap then return nil end
    return bounded,clipped or shifted or edge
end

function RTS:BuildSafeFormationDestinations(ships, target, formationId, facing)
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
    table.sort(ordered, function(a,b)
        if a.radius~=b.radius then return a.radius>b.radius end
        return a.ship:getSignature()<b.ship:getSignature()
    end)

    local shapeId = nil
    if self:GetFormationShape(formationId) ~= nil then shapeId = formationId
    elseif self:GetFormationShape(F.Default) ~= nil then shapeId = F.Default end
    local localOffsets
    if shapeId ~= nil then
        localOffsets = shapeOffsets(#ordered, shapeId, self:GetFormationShape(shapeId), baseGap)
        local originals={}
        for i,slot in ipairs(localOffsets) do originals[i]={lateral=slot.lateral,depth=slot.depth} end
        -- Expand only the slots that need hull clearance. A juggernaut must not
        -- space every pair of fighters by its own diameter. Preserve rows and
        -- columns by moving along the shape's original separation vector.
        for i,slot in ipairs(localOffsets) do
            if i>1 and (shapeId=="LINE_ABREAST" or shapeId=="COLUMN") then
                local prior=localOffsets[i-1]
                local needed=ordered[i].radius+ordered[i-1].radius+clearance
                if shapeId=="LINE_ABREAST" then
                    local step=originals[i].lateral-originals[i-1].lateral
                    slot.lateral=prior.lateral+(step>=0 and 1 or -1)*math.max(math.abs(step),needed)
                else
                    local step=originals[i].depth-originals[i-1].depth
                    slot.depth=prior.depth+(step>=0 and 1 or -1)*math.max(math.abs(step),needed)
                end
            else
                for attempt=1,math.max(1,i*4) do
                    local expanded=false
                    for j=1,i-1 do
                        local prior=localOffsets[j]
                        local px,pz=slot.lateral-prior.lateral,slot.depth-prior.depth
                        local needed=ordered[i].radius+ordered[j].radius+clearance
                        if px*px+pz*pz<needed*needed-.01 then
                            local dx,dz=originals[i].lateral-originals[j].lateral,originals[i].depth-originals[j].depth
                            local length=math.sqrt(dx*dx+dz*dz)
                            if length<.001 then dx,dz,length=1,0,1 end
                            slot.lateral=prior.lateral+dx/length*(needed+.01)
                            slot.depth=prior.depth+dz/length*(needed+.01)
                            expanded=true
                        end
                    end
                    if not expanded then break end
                end
            end
        end
        local cx,cz=0,0
        for _,slot in ipairs(localOffsets) do cx=cx+slot.lateral; cz=cz+slot.depth end
        for _,slot in ipairs(localOffsets) do slot.lateral=slot.lateral-cx/#ordered; slot.depth=slot.depth-cz/#ordered end
    else
        localOffsets = packedOffsets(ordered, baseGap, clearance, maxRowWidth)
    end
    local centerX,centerZ=0,0
    for _,ship in ipairs(ships) do centerX=centerX+ship.Position.x; centerZ=centerZ+ship.Position.z end
    centerX=centerX/#ships; centerZ=centerZ/#ships
    local dirX,dirZ=target.x-centerX,target.z-centerZ
    if self:IsFiniteVector(facing) then dirX,dirZ=facing.x-target.x,facing.z-target.z end
    local len=math.sqrt(dirX*dirX+dirZ*dirZ)
    if len<0.001 then dirX,dirZ,len=math.sin(self.CameraYaw),math.cos(self.CameraYaw),1 end
    dirX,dirZ=dirX/len,dirZ/len
    local rightX,rightZ=dirZ,-dirX

    local function footprint()
        local maxX,maxZ=0,0
        for i,slot in ipairs(localOffsets) do
            slot.ship=ordered[i].ship
            slot.ox=rightX*slot.lateral-dirX*slot.depth
            slot.oz=rightZ*slot.lateral-dirZ*slot.depth
            local margin=ordered[i].radius*1.05
            maxX=math.max(maxX,math.abs(slot.ox)+margin)
            maxZ=math.max(maxZ,math.abs(slot.oz)+margin)
        end
        return maxX,maxZ
    end
    local maxAbsX,maxAbsZ=footprint()
    local fits=maxAbsX<=arena and maxAbsZ<=arena
    for i,a in ipairs(localOffsets) do
        for j=1,i-1 do
            local b=localOffsets[j]
            local needed=ordered[i].radius+ordered[j].radius+clearance
            if (a.ox-b.ox)^2+(a.oz-b.oz)^2<needed^2-.01 then fits=false end
        end
    end
    if not fits then
        -- Oversized shapes may use ranks, but never shrink hull clearance.
        localOffsets=packedOffsets(ordered,baseGap,clearance,maxRowWidth)
        maxAbsX,maxAbsZ=footprint()
        if maxAbsX>arena or maxAbsZ>arena then return result,"Selection too large for command area; move smaller groups" end
    end

    -- Clamp the whole group, including its hull margins. Clamping each slot
    -- separately folded the outside ships into their neighbours at map edges.
    local safeCenter=self:ClampCommandPoint(target,0)
    safeCenter.x=clamp(safeCenter.x,-arena+maxAbsX,arena-maxAbsX)
    safeCenter.z=clamp(safeCenter.z,-arena+maxAbsZ,arena-maxAbsZ)
    safeCenter=self:ClearStationDestination(ordered[1].ship,safeCenter,math.sqrt(maxAbsX*maxAbsX+maxAbsZ*maxAbsZ))
    safeCenter.x=clamp(safeCenter.x,-arena+maxAbsX,arena-maxAbsX)
    safeCenter.z=clamp(safeCenter.z,-arena+maxAbsZ,arena-maxAbsZ)

    for _,slot in ipairs(localOffsets) do
        local p=vec(safeCenter.x+slot.ox,safeCenter.y,safeCenter.z+slot.oz)
        local _,overlap=self:ClearStationDestination(slot.ship,p,self:GetShipFormationRadius(slot.ship)*1.05)
        if overlap then return {},'Formation does not fit beside the station; move smaller groups' end
        result[#result+1]={ship=slot.ship,destination=p}
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
    if self.MoveTurretLocks then self.MoveTurretLocks[signature]=nil end
    local entry = self.MoveWaypoints[signature]
    self.MoveWaypoints[signature] = nil
    if entry then self.FreeMoveWaypoints[#self.FreeMoveWaypoints + 1] = entry end
end

function RTS:GetWithdrawalHomeClearance(ship)
    local withdrawal=(self.Withdrawals and self.Withdrawals[ship:getSignature()])
        or (self.Rearguards and self.Rearguards[ship:getSignature()])
    local area=withdrawal and self.ExtractionAreas and self.ExtractionAreas[withdrawal.faction]
    if not area or not self:IsFiniteVector(area.home) then return nil end
    local radius=tonumber(area.homeRadius)
    return area.home,radius and radius>0 and radius or 1800
end

function RTS:ConfigureMoveWaypoints(ship,destination)
    local first=self:GetOrCreateMoveWaypoint(ship)
    if not objectValid(first) then return nil end
    local path={destination}
    local station=self:GetFactionCommandShip(self:GetFactionKey(ship))
    local home,homeRadius=self:GetWithdrawalHomeClearance(ship)
    local withdrawing=home~=nil
    local center
    if withdrawing then center=home elseif shipAlive(station) then center=station.Position end
    if center~=nil then
        local radius=(withdrawing and homeRadius or (station.Class.Model and station.Class.Model.Radius or 500))
            +self:GetShipFormationRadius(ship)*1.05+300
        local function crosses(a,b)
            local delta=b-a; local length=delta.x^2+delta.y^2+delta.z^2
            if length<1 then return false end
            local offset=center-a
            local t=clamp((offset.x*delta.x+offset.y*delta.y+offset.z*delta.z)/length,0,1)
            return (a+delta*t):getDistance(center)<radius-.1
        end
        local start=ship.Position
        local escape,moved,escapeCost
        if withdrawing then
            local dx,dy,dz=start.x-center.x,start.y-center.y,start.z-center.z
            local distance=math.sqrt(dx*dx+dy*dy+dz*dz)
            if distance<radius then
                local pathX,pathZ=destination.x-start.x,destination.z-start.z
                local pathLength=math.sqrt(pathX*pathX+pathZ*pathZ)
                if pathLength<1 then return nil end
                local sideX,sideZ=-pathZ/pathLength,pathX/pathLength
                local clearance=radius+1
                for attempt=1,6 do
                    for _,side in ipairs({-1,1}) do
                        local candidate=vec(center.x+sideX*clearance*side,start.y,center.z+sideZ*clearance*side)
                        if not crosses(candidate,destination) then
                            local travel=start:getDistance(candidate)+candidate:getDistance(destination)
                            if not escape or travel<escapeCost then escape,escapeCost=candidate,travel end
                        end
                    end
                    if escape then break end
                    clearance=clearance*1.5
                end
                if not escape then return nil end
                moved=true; start=escape
            end
        else
            escape,moved=self:ClearStationDestination(ship,start,self:GetShipFormationRadius(ship)*1.05+100)
            if moved then start=escape end
        end
        if crosses(start,destination) then
            local dx,dz=destination.x-start.x,destination.z-start.z
            local length=math.sqrt(dx*dx+dz*dz)
            if length<1 then return nil end
            local best,cost=nil,math.huge
            for _,side in ipairs({-1,1}) do
                local distance=radius*1.5
                for attempt=1,6 do
                    local candidate=vec(center.x-dz/length*distance*side,(start.y+destination.y)/2,center.z+dx/length*distance*side)
                    local _,clipped=self:ClampCommandPoint(candidate,self:GetShipFormationRadius(ship)*1.05,withdrawing)
                    if not clipped and not crosses(start,candidate) and not crosses(candidate,destination) then
                        local travel=start:getDistance(candidate)+candidate:getDistance(destination)
                        if travel<cost then best,cost=candidate,travel end
                        break
                    end
                    distance=distance*1.6
                end
            end
            if not best then return nil end
            path=moved and {escape,best,destination} or {best,destination}
        elseif moved then path={escape,destination} end
    end
    local entry=self.MoveWaypoints[ship:getSignature()]
    if #path>1 and not entry.route then
        entry.route={first,mn.createWaypoint(destination,entry.list),mn.createWaypoint(destination,entry.list)}
    end
    for i,waypoint in ipairs(entry.route or {first}) do
        if not objectValid(waypoint) then return nil end
        waypoint.Position=copyVec(path[i] or destination)
    end
    return first
end

function RTS:MoveShipTo(ship, destination, priority)
    if not self:IsMovableFriendly(ship) or destination == nil then return false end
    if not self:IsFiniteVector(destination) then
        self:Log("REJECTED non-finite move destination for " .. tostring(ship.Name))
        return false
    end
    local safe,clipped=self:ClampShipDestination(ship,destination)
    if safe==nil then return false end
    local waypoint=self:ConfigureMoveWaypoints(ship,safe)
    if not objectValid(waypoint) then return false end
    ship:clearOrders()
    if ship:giveOrder(ORDER_WAYPOINTS_ONCE,waypoint,nil,priority or 0.95)~=true then return false end
    self:SetShipCommandDiscipline(ship,true)
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
