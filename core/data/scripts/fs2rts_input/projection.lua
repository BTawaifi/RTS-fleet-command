-- Projection cache, screen gates and screen-to-plane mapping.
local _shared = require "fs2rts_input.common"
local U, RTS, vec, PICK_GATE_ASPECT_SLACK = _shared.U, _shared.RTS, _shared.vec, _shared.PICK_GATE_ASPECT_SLACK

local Config = require "fs2rts_config"

local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys

-- How many epochs an AMBIENT contact's projection may be reused for. A
-- reticle is a presence marker, not an animation, and at tactical range a
-- capital moves well under a pixel between two epochs, so refreshing the
-- ambient set on a round robin instead of every epoch is invisible and
-- removes two thirds of the calls. Selection and hover are always
-- re-projected: they are what the player is pointing at.
local AMBIENT_PROJECT_EPOCHS = 2

-- Entries whose ship has left the world are dropped by rebuilding the cache
-- from the live list. Every ambient epoch touches every live ship, so the
-- rebuild cannot orphan a live entry, and signatures the engine has recycled
-- onto unrelated hulls are caught by the owner check in ProjectShip as well.
local PROJECTION_PRUNE_EPOCHS = 30

-- Extra pixels around a pick that the gate accepts. The gate works in tangent
-- space and cannot know each hull's on-screen radius, so it takes the widest
-- one the pick rules could ask for plus this much slack.
local PICK_GATE_PAD_PIXELS = 24

-- A new projection epoch. Projections taken before this call are no longer
-- trusted.
--
-- HUD draws and mouse handlers start their own epochs. Cached answers are
-- valid only for that view/world sample; ambient contacts may use older epochs.
function RTS:BeginFrameProjection()
    self.ProjectionEpoch = (self.ProjectionEpoch or 0) + 1
    if self.ProjectionEpoch == 1 then
        self.ProjectionX, self.ProjectionY = {}, {}
        self.ProjectionOwner, self.ProjectionAt = {}, {}
        self.ProjectionPrunedAt = 0
    end
end

-- Returns screen x and screen y. x is false, not nil, when the engine reported
-- a projection overflow. maxAge is in EPOCHS: 0 means "from this epoch" and is
-- what every click path uses, because the ship a click selects has to be the
-- ship the player is looking at. The ambient reticle pass and the hover readout
-- - neither of which resolves a click - pass AMBIENT_PROJECT_EPOCHS.
function RTS:ProjectShip(ship, maxAge)
    if ship == nil then return false, false end
    local position = ship.Position
    if position == nil then return false, false end
    local X = self.ProjectionX
    local Y, O, A
    if X == nil then
        X, Y, O, A = {}, {}, {}, {}
        self.ProjectionX, self.ProjectionY = X, Y
        self.ProjectionOwner, self.ProjectionAt = O, A
    else
        Y, O, A = self.ProjectionY, self.ProjectionOwner, self.ProjectionAt
    end
    local epoch = self.ProjectionEpoch or 0
    local sig = ship:getSignature()
    local sx = X[sig]
    -- The owner check is what makes a recycled signature safe: the engine
    -- reuses signatures freely, and a stale entry for a dead hull must not be
    -- handed back for whatever now owns that number.
    if sx ~= nil and O[sig] == ship and (epoch - (A[sig] or -999)) <= maxAge then
        return sx, Y[sig]
    end
    local px, py = position:getScreenCoords()
    if px == false then px, py = false, false end
    X[sig] = px
    Y[sig] = py
    O[sig] = ship
    A[sig] = epoch
    return px, py
end

-- The unselected, unhovered pass over the fleet. Allowed to be a couple of
-- epochs behind; see AMBIENT_PROJECT_EPOCHS.
function RTS:ProjectShipAmbient(ship)
    return self:ProjectShip(ship, AMBIENT_PROJECT_EPOCHS)
end

-- True when the cache is due to be rebuilt from the live ship list. Exposed as
-- a function rather than a constant because the constant is a file local and
-- the ambient pass that needs it lives in hud.lua.
function RTS:ProjectionCacheNeedsPrune()
    return (self.ProjectionEpoch or 0) - (self.ProjectionPrunedAt or 0) >= PROJECTION_PRUNE_EPOCHS
end

function RTS:PruneProjectionCache()
    local oldX, oldY = self.ProjectionX, self.ProjectionY
    if oldX == nil then return end
    local oldO, oldA = self.ProjectionOwner, self.ProjectionAt
    local X, Y, O, A = {}, {}, {}, {}
    local list = self:GetShipList()
    for i = 1, #list do
        local ship = list[i]
        local sig = ship:getSignature()
        if oldX[sig] ~= nil and oldO[sig] == ship then
            X[sig] = oldX[sig]
            Y[sig] = oldY[sig]
            O[sig] = ship
            A[sig] = oldA[sig]
        end
    end
    self.ProjectionX, self.ProjectionY = X, Y
    self.ProjectionOwner, self.ProjectionAt = O, A
    self.ProjectionPrunedAt = self.ProjectionEpoch
end

-- Pre-projection frustum test.
--
-- The engine's projection (code/render/3dmath.cpp:247, with the basis scaling
-- from code/render/3dsetup.cpp:187) is exactly
--     sx = W/2 * (1 + (d.r / d.f) * window / tanH)
--     sy = H/2 * (1 - (d.u / d.f) / tanH)
-- so the set of world directions landing inside a screen rectangle is a
-- RECTANGLE in tangent space. A ship can therefore be rejected with about a
-- dozen floating point operations and no engine call at all, which is the
-- whole point: the alternative is the g3 frame.
--
-- Returns nil whenever any input is unavailable, and every caller then
-- projects everything. This is an optimisation; it is never load bearing.
function RTS:BuildScreenGate(sw, sh, cx, cy, radiusX, radiusY, slack)
    local camera = self.Camera
    if self.FollowSignature ~= nil and self.FollowCamera ~= nil then camera = self.FollowCamera end
    if camera == nil or camera.Orientation == nil or camera.Position == nil then return nil end
    if type(sw) ~= "number" or type(sh) ~= "number" or sw <= 0 or sh <= 0 then return nil end
    local okF, forward = pcall(function() return camera.Orientation:getFvec() end)
    if not okF or forward == nil then return nil end
    local okR, right = pcall(function() return camera.Orientation:getRvec() end)
    if not okR or right == nil then return nil end
    local okU, up = pcall(function() return camera.Orientation:getUvec() end)
    if not okU or up == nil then return nil end
    local halfW, halfH = sw * 0.5, sh * 0.5
    local gate = {}
    local origin = camera.Position
    gate.ox, gate.oy, gate.oz = origin.x, origin.y, origin.z
    gate.fx, gate.fy, gate.fz = forward.x, forward.y, forward.z
    gate.rx, gate.ry, gate.rz = right.x, right.y, right.z
    gate.ux, gate.uy, gate.uz = up.x, up.y, up.z
    -- Measure the actual screen-to-tangent mapping, including FSO's aspect
    -- scaling. Two rays per gate are cheaper than projecting every candidate,
    -- and avoid rejecting native on-screen picks through a guessed FOV model.
    local ok,center,corner=pcall(function()
        return gr.getVectorFromCoords(halfW,halfH,10000,false),gr.getVectorFromCoords(sw,0,10000,false)
    end)
    if not ok or not self:IsFiniteVector(center) or not self:IsFiniteVector(corner) then return nil end
    local function tangent(point)
        local dx,dy,dz=point.x-origin.x,point.y-origin.y,point.z-origin.z
        local depth=dx*forward.x+dy*forward.y+dz*forward.z
        if depth<=0 then return nil end
        return (dx*right.x+dy*right.y+dz*right.z)/depth,(dx*up.x+dy*up.y+dz*up.z)/depth
    end
    local ax,ay=tangent(center); local bx,by=tangent(corner)
    if ax==nil or bx==nil then return nil end
    local scaleX,scaleY=(bx-ax)/halfW,(by-ay)/halfH
    if not self:IsFiniteNumber(scaleX) or not self:IsFiniteNumber(scaleY) or scaleX<=0 or scaleY<=0 then return nil end
    gate.tanA=ax+(cx-halfW)*scaleX; gate.tanB=ay+(halfH-cy)*scaleY
    gate.tolA=(radiusX+2)*scaleX*(slack or 1); gate.tolB=(radiusY+2)*scaleY
    return gate
end

function RTS:PassesScreenGate(gate, position)
    local dx = position.x - gate.ox
    local dy = position.y - gate.oy
    local dz = position.z - gate.oz
    local depth = dx * gate.fx + dy * gate.fy + dz * gate.fz
    -- z <= 0 is exactly what the engine turns into PF_OVERFLOW: MIN_Z is 0.0f
    -- (code/render/3dmath.cpp:16) and g3_project_vertex flags z < MIN_Z
    -- (:239). The z == 0 case is the live hole in the old code: the engine
    -- takes a different branch for it and ORs in `PF_OVERFLOW & PF_PROJECTED`
    -- (:233), which is 2 & 1 == 0, so the overflow flag is CLEARED and the
    -- point is reported as screen (0,0). A hull sitting exactly on the camera
    -- plane was pickable at the top-left pixel of the screen.
    if depth <= 0 then return false end
    local lateral = (dx * gate.rx + dy * gate.ry + dz * gate.rz) / depth
    if math.abs(lateral - gate.tanA) > gate.tolA then return false end
    local vertical = (dx * gate.ux + dy * gate.uy + dz * gate.uz) / depth
    if math.abs(vertical - gate.tanB) > gate.tolB then return false end
    return true
end

-- The gate every picking path uses: a disc of the widest radius the call could
-- accept, centred on the cursor.
function RTS:BuildPickGate(mouseX, mouseY, sw, sh, radiusPixels)
    return self:BuildScreenGate(sw, sh, mouseX, mouseY,
        radiusPixels + PICK_GATE_PAD_PIXELS, radiusPixels + PICK_GATE_PAD_PIXELS,
        PICK_GATE_ASPECT_SLACK)
end

-- The gate the ambient contact pass uses: exactly "can this land on screen".
-- Zero radius means anything the projection would put outside the viewport is
-- rejected without a projection, and the caller gives it a border marker
-- instead, which is what it already did with the projected coordinate.
function RTS:BuildViewportGate(sw, sh)
    return self:BuildScreenGate(sw, sh, sw * 0.5, sh * 0.5, sw * 0.5, sh * 0.5, PICK_GATE_ASPECT_SLACK)
end

function RTS:ScreenToPlane(mouseX, mouseY, planeY)
    if self.Camera == nil then return nil end
    -- Use two points returned by FSO's *actual active view* instead of mixing
    -- getVectorFromCoords() with a separately cached camera origin. This avoids
    -- camera-state mismatches after orbit/zoom/follow transitions.
    local nearPoint=gr.getVectorFromCoords(mouseX,mouseY,1,false)
    local depth=math.max(50000,self:GetTacticalMapHalfExtent()*4)
    local farPoint=gr.getVectorFromCoords(mouseX,mouseY,depth,false)
    if not self:IsFiniteVector(nearPoint) or not self:IsFiniteVector(farPoint) then return nil end
    local dx,dy,dz=farPoint.x-nearPoint.x,farPoint.y-nearPoint.y,farPoint.z-nearPoint.z
    if math.abs(dy)<0.002 then
        self:Log("Rejected near-parallel screen ray for move command")
        return nil
    end
    local t=((planeY or 0)-nearPoint.y)/dy
    if not self:IsFiniteNumber(t) or t<=0 then return nil end
    local point=vec(nearPoint.x+dx*t,planeY or 0,nearPoint.z+dz*t)
    if not self:IsFiniteVector(point) then return nil end
    local safe,clipped=self:ClampCommandPoint(point,0)
    self.LastProjectionWasClamped=clipped
    return safe
end

function RTS:ShouldHideObject(object)
    if not self.Enabled or object == nil or not object:isValid() then return false end
    if object.Name == self.Config.ObserverShip then
        return self.PossessedSignature == nil
    end
    if self.PossessedSignature ~= nil and object:getSignature() == self.PossessedSignature then
        return true
    end
    -- Hotfix 4 deliberately never render-suppresses combat units. Earlier sensor state
    -- affects tactical information only; it can no longer make ships vanish because
    -- of stale signatures, selection, object reuse, or render-hook timing.
    return false
end
