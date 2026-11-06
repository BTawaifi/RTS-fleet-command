-- Picking and drawing the individual subsystems of an enemy ship, so the player can order
-- an attack on one turret, engine or sensor instead of the whole hull.
local _shared = require "fs2rts_orders.common"
local RTS, objectValid = _shared.RTS, _shared.objectValid

local PICK_PIXELS=20
local MARKER_PIXELS=4
local TURRET_COLOUR={255,170,60}
local SYSTEM_COLOUR={90,220,255}
local PICKED_COLOUR={255,235,90}
-- A subsystem is hidden when hull geometry stands this far (metres, or this fraction of the
-- hull radius, whichever is larger) in front of it on the line from the camera. A turret's
-- own base sits inside the hull, so a smaller gap would hide turrets that are in plain view.
local SIGHT_MARGIN=150
local SIGHT_MARGIN_FRACTION=.08
local SIGHT_REFRESH_SECONDS=.25
local SIGHT_EYE_SLACK=40
local SIGHT_KEEP_SECONDS=5
-- How far past a hull's projected radius the cursor may be and still consider its subsystems.
local HULL_SCREEN_REACH=1.25

local function pickable(subsystem)
    return objectValid(subsystem) and subsystem.Targetable~=false
        and (subsystem.HitpointsMax or 0)>0 and (subsystem.HitpointsLeft or 0)>0
end

-- Fighters and bombers have no subsystem worth picking from the map.
local function hasPickableRole(self,ship)
    local role=self:GetShipRole(ship)
    return role~='fighter' and role~='bomber'
end

local function cameraPosition(self)
    local camera=self.Camera
    if self.FollowSignature~=nil and self.FollowCamera~=nil then camera=self.FollowCamera end
    return camera and camera.Position or nil
end

-- True when the ship's own hull blocks the line from the eye to the subsystem.
local function hiddenByHull(ship,subsystem,eye,margin)
    local target=subsystem.WorldPosition
    if target==nil then return false end
    local ok,hit=pcall(ship.checkRayCollision,ship,eye,target)
    if not ok or hit==nil then return false end
    return eye:getDistance(target)-eye:getDistance(hit)>margin
end

-- Set of subsystem indices of the ship that the camera can see, refreshed a few times a
-- second. Nil when there is no camera to test from, in which case nothing is hidden.
local function sightOf(self,ship)
    local eye=cameraPosition(self)
    if eye==nil then return nil end
    local now=self:UINow()
    local cache=self.SubsystemSight
    if cache==nil then cache={}; self.SubsystemSight=cache end
    local id=ship:getSignature()
    local entry=cache[id]
    if entry and now-entry.time<SIGHT_REFRESH_SECONDS and entry.eye:getDistance(eye)<SIGHT_EYE_SLACK then return entry.visible end
    for key,old in pairs(cache) do
        if now-old.time>SIGHT_KEEP_SECONDS then cache[key]=nil end
    end
    local margin=math.max(SIGHT_MARGIN,(ship.Radius or 0)*SIGHT_MARGIN_FRACTION)
    local visible={}
    for i=1,#ship do
        local subsystem=ship[i]
        if pickable(subsystem) and not hiddenByHull(ship,subsystem,eye,margin) then visible[i]=true end
    end
    cache[id]={time=now,eye=eye,visible=visible}
    return visible
end

-- {index,x,y,subsystem} for each live subsystem of the ship that is in view and projects
-- onto the screen.
local function projectSubsystems(self,ship)
    local list={}
    local visible=sightOf(self,ship)
    for i=1,#ship do
        local subsystem=ship[i]
        if pickable(subsystem) and (visible==nil or visible[i]) then
            local position=subsystem.WorldPosition
            local x,y
            if position~=nil then x,y=position:getScreenCoords() end
            if x~=nil and x~=false then list[#list+1]={index=i,x=x,y=y,subsystem=subsystem} end
        end
    end
    return list
end

local function nearestEntry(entries,mx,my,radius)
    local best,bestDistance
    for _,entry in ipairs(entries) do
        local dx,dy=entry.x-mx,entry.y-my
        local distance=math.sqrt(dx*dx+dy*dy)
        if distance<=radius and (bestDistance==nil or distance<bestDistance) then best,bestDistance=entry,distance end
    end
    return best,bestDistance
end

-- True when the cursor is close enough to the hull's projection for its subsystems to matter.
local function cursorNearHull(self,ship,mx,my)
    local eye=cameraPosition(self)
    local sx,sy=self:ProjectShip(ship,1)
    if sx==false or eye==nil then return false end
    local reach=((ship.Radius or 0)/math.max(1,ship.Position:getDistance(eye)))*math.max(1,gr.getScreenHeight())*1.35*HULL_SCREEN_REACH
    local dx,dy=sx-mx,sy-my
    return dx*dx+dy*dy<=reach*reach
end

-- The hostile hull with a visible subsystem under the cursor, and that subsystem's index. This
-- is a pick on the subsystem itself, so it holds wherever on a large hull the cursor is, unlike
-- the hull-centre pick, which stops reaching a base once the camera is close to it.
function RTS:GetHostileSubsystemAtScreen(mx,my)
    local radius=self:GetUIMetrics().pad(PICK_PIXELS)
    local bestShip,bestIndex,bestDistance
    self:EachShip(function(ship)
        if not (objectValid(ship) and self:IsPlayerEnemy(ship) and hasPickableRole(self,ship)) then return end
        if not cursorNearHull(self,ship,mx,my) then return end
        local entry,distance=nearestEntry(projectSubsystems(self,ship),mx,my,radius)
        if entry and (bestDistance==nil or distance<bestDistance) then bestShip,bestIndex,bestDistance=ship,entry.index,distance end
    end)
    return bestShip,bestIndex
end

-- Index of the live, visible subsystem of this ship under the cursor, or nil on the bare hull.
function RTS:GetSubsystemAtScreen(ship,mx,my)
    if not (objectValid(ship) and hasPickableRole(self,ship)) then return nil end
    local entry=nearestEntry(projectSubsystems(self,ship),mx,my,self:GetUIMetrics().pad(PICK_PIXELS))
    return entry and entry.index or nil
end

-- The enemy a right-click lands on, and the subsystem under the cursor when there is one. A
-- fighter or bomber under the cursor is the target as before; otherwise a visible subsystem
-- on any hostile hull wins, so a turret the player sees marked is the one that gets ordered
-- instead of the click falling through to a move.
function RTS:GetHostileAtScreen(mx,my)
    local direct=self:GetShipAtScreen(mx,my,false,true)
    if direct and not hasPickableRole(self,direct) then return direct,nil end
    local hull,index=self:GetHostileSubsystemAtScreen(mx,my)
    if hull then return hull,index end
    return direct,nil
end

-- Markers for the enemy's visible subsystems while friendly ships are selected; the one a
-- right-click would order is highlighted and named.
function RTS:DrawHoveredSubsystems(ship,mx,my)
    if not (objectValid(ship) and self:IsPlayerEnemy(ship) and hasPickableRole(self,ship)) then return end
    if #self:GetSelectedFriendlyShips()==0 then return end
    local entries=projectSubsystems(self,ship)
    local m=self:GetUIMetrics()
    local picked=nearestEntry(entries,mx,my,m.pad(PICK_PIXELS))
    local half=m.pad(MARKER_PIXELS)
    for _,entry in ipairs(entries) do
        local colour=entry==picked and PICKED_COLOUR or (entry.subsystem:isTurret() and TURRET_COLOUR or SYSTEM_COLOUR)
        gr.setColor(colour[1],colour[2],colour[3],entry==picked and 255 or 190)
        gr.drawRectangle(entry.x-half,entry.y-half,entry.x+half,entry.y+half,false)
    end
    if picked then
        local subsystem=picked.subsystem
        local percent=math.floor(100*subsystem.HitpointsLeft/math.max(1,subsystem.HitpointsMax))
        gr.setColor(PICKED_COLOUR[1],PICKED_COLOUR[2],PICKED_COLOUR[3],255)
        gr.drawRectangle(picked.x-half*2,picked.y-half*2,picked.x+half*2,picked.y+half*2,false)
        gr.drawString((subsystem.Name or 'SUBSYSTEM')..' '..percent..'%',picked.x+half*3,picked.y-half)
    end
end

-- The pickable hostile hull whose projection the cursor is over, nearest centre first.
local function hullUnderCursor(self,mx,my)
    local best,bestDistance
    self:EachShip(function(ship)
        if not (objectValid(ship) and self:IsPlayerEnemy(ship) and hasPickableRole(self,ship)) then return end
        if not cursorNearHull(self,ship,mx,my) then return end
        local sx,sy=self:ProjectShip(ship,1)
        local distance=(sx-mx)^2+(sy-my)^2
        if bestDistance==nil or distance<bestDistance then best,bestDistance=ship,distance end
    end)
    return best
end

-- The hull whose subsystem markers to draw for the cursor: the one with a subsystem under it,
-- else the hull the ordinary hover pick found, else a hostile hull the cursor is over.
function RTS:GetSubsystemMarkerHull(hovered,mx,my)
    if #self:GetSelectedFriendlyShips()==0 then return hovered end
    return self:GetHostileSubsystemAtScreen(mx,my) or hovered or hullUnderCursor(self,mx,my)
end
