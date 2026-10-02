-- Tactical map, picking, UI hit-testing, mouse/keyboard input.
local Config = require "fs2rts_config"
local U = require "fs2rts_util"
local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys
local RTS = require "fs2rts_state"
local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

-- ---------------------------------------------------------------------------
-- Screen projection: one engine call per ship per frame, and as few ships as
-- possible reach that call.
-- ---------------------------------------------------------------------------
--
-- getScreenCoords is not a cheap query. code/scripting/api/objs/vecmath.cpp:668
--
--     bool do_g3 = G3_count < 1;
--     if (do_g3) g3_start_frame(1);
--     g3_rotate_vertex(&vtx, &v3);
--     g3_project_vertex(&vtx);
--     if (do_g3) g3_end_frame();
--
-- Scripting never runs inside a g3 frame, so do_g3 is true on every single
-- call and the mod opens and closes a full 3D frame per projection. There is
-- no Lua binding that opens one, so these cannot be batched; the only wins
-- available are to make one call per ship and to make it for fewer ships.
--
-- It returns FALSE, not nil, when the vertex carries PF_OVERFLOW. Every test
-- below therefore compares against `false` explicitly: `coords ~= nil` is
-- true for the engine's own off-screen answer and would treat a contact
-- behind the camera as a screen position.

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

-- gr.getEyeFOV returns the camera's raw fov "zoom". FSO uses a HORIZONTAL fov
-- and multiplies the zoom by PROJ_FOV_FACTOR before projecting
-- (code/render/3dsetup.h:57, code/render/3dsetup.cpp:127 and :193), and the
-- horizontal extent additionally carries gr_screen.aspect * h / w
-- (code/render/3dsetup.cpp:96), which scripting cannot read at all. The slack
-- below is the allowance for that unreadable aspect term on the horizontal
-- axis; the vertical axis needs none and is exact.
local FSO_PROJ_FOV_FACTOR = 1.39626348
local PICK_GATE_ASPECT_SLACK = 1.6

-- A new projection epoch. Projections taken before this call are no longer
-- trusted.
--
-- An epoch is not an engine frame counter: FSO has no scripting binding for
-- one (there is no getFrameCount in code/scripting/api/libs), so the epoch is
-- advanced explicitly at the two points where the world cannot change under a
-- cached answer. That is the whole safety argument: OnFrame is the only thing
-- that integrates ship motion and it runs before both, UpdateCameraTransform
-- is only ever called from OnFrame or from inside a mouse handler, and no
-- consumer reads a projection between two of these calls. So a mouse handler
-- may reuse a projection the HUD drew earlier in the same engine frame, and
-- may not reuse one from before the last epoch change.
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
    local fov = nil
    local okFov, eyeFov = pcall(function() return gr.getEyeFOV() end)
    if okFov and type(eyeFov) == "number" and eyeFov > 0 then fov = eyeFov * FSO_PROJ_FOV_FACTOR end
    if fov == nil then
        fov = (camera.FOV or (self.Config.Camera or {}).FOV or 0.9) * FSO_PROJ_FOV_FACTOR
    end
    local tanH = math.tan(fov * 0.5)
    if not (tanH > 0) or tanH > 1000 then return nil end
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
    -- Everything below is in half-screen units scaled by tanH, so a point in
    -- front of the camera at lateral offset l and depth f lands at l*tanH/f.
    gate.tanH = tanH
    gate.tanA = (cx - halfW) / halfW * tanH
    gate.tanB = (halfH - cy) / halfH * tanH
    gate.tolA = (radiusX / halfW) * tanH * (slack or 1)
    gate.tolB = (radiusY / halfH) * tanH
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
    local lateral = (dx * gate.rx + dy * gate.ry + dz * gate.rz) * gate.tanH / depth
    if math.abs(lateral - gate.tanA) > gate.tolA then return false end
    local vertical = (dx * gate.ux + dy * gate.uy + dz * gate.uz) * gate.tanH / depth
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

-- Map view state: zoom/pan apply to both the docked and popped-out map.
-- Popped out, the map is a movable, resizable, semi-transparent window.
function RTS:GetMapHeaderHeight()
    local m=self:GetUIMetrics(); return m.mapHeader
end

-- One derived layout table for the whole HUD.
--
-- The HUD used to hard-code every rectangle, row pitch and padding in pixels
-- against a 1920x1080 design. That is not merely untidy at other sizes, it is
-- broken: the right-hand column is a fixed stack whose total height (about
-- 864px) exceeds a 720p screen, so the production panel was squeezed to 32px
-- and its row loop drew nothing at all.
--
-- Two rules drive this table.
--
-- 1. The font is a fixed 16px-tall proportional bitmap face
--    (font01.vf, code/graphics/software/font.cpp:246; gr_get_font_height
--    returns 16 at font.cpp:766). Nothing in scripting changes it, so NO
--    vertical metric may shrink below its design value; only horizontal padding
--    and panel extents grow. That is why m.pad() is a floor, not a scale.
-- 2. Whatever the screen is, the layout must FIT. So the right column is
--    solved from the bottom up: the essential panels (production, options,
--    policy) are reserved first, and the tactical map plus the quick-group
--    strip give up height until the rest fits.

-- Screen size, guarded. gr.getScreenWidth/getScreenHeight are the engine's own
-- (code/scripting/api/libs/graphics.cpp, the ADE bindings of gr_get_screen_width
-- and gr_get_screen_height), but a headless double may not provide them, and a
-- layout table that raises inside a draw call takes the whole frame with it.
local function resolveScreenSize(sw, sh)
    if sw == nil then local ok, value = pcall(gr.getScreenWidth); if ok then sw = value end end
    if sh == nil then local ok, value = pcall(gr.getScreenHeight); if ok then sh = value end end
    return math.max(320, math.floor(tonumber(sw) or 1280)), math.max(240, math.floor(tonumber(sh) or 720))
end

function RTS:GetUIMetrics(sw, sh)
    sw, sh = resolveScreenSize(sw, sh)
    local cached = self.UIMetrics
    if cached ~= nil and cached.sw == sw and cached.sh == sh then return cached end

    -- 1.0 at 1920x1080 and below; grows with the screen so a 4K panel does not
    -- get a corner-sized HUD. Capped because the font does not grow with it.
    local scale = clamp(math.min(sw/1920, sh/1080), 1, 1.75)
    local m = { sw=sw, sh=sh, scale=scale }
    function m.pad(v) return math.max(v, math.floor(v*scale+0.5)) end

    local ui = self.Config.UI or {}
    local map = self.Config.TacticalMap or {}

    m.charWidth = 8
    -- gr_get_font_height() is 16 for font01, so 17 is the tightest safe pitch.
    m.lineHeight = math.max(17, m.pad(17))
    m.margin = m.pad(ui.Margin or 14)
    m.gap = m.pad(ui.RightPanelGap or 12)
    m.topBarHeight = m.pad(44)
    m.rightPanelWidth = m.pad(ui.RightPanelWidth or 410)
    m.selectionWidth = m.pad(ui.SelectionWidth or 410)
    m.selectionHeight = m.pad(ui.SelectionHeight or 330)
    m.policyHeight = m.pad(ui.PolicyHeight or 196)
    m.optionsHeight = m.pad(ui.OptionsHeight or 48)
    m.quickGroupHeight = m.pad(ui.QuickGroupHeight or 86)
    m.mapHeader = m.pad(24)
    m.mapPreferredHeight = m.pad(map.Height or 238)
    m.mapTop = m.pad(map.Top or 58)
    m.mapWidth = m.pad(map.Width or 410)
    -- Popped-out map chrome: five buttons laid out right to left. The window's
    -- minimum width is derived from this so the row can never run off the left
    -- edge of a map the player has dragged to the screen edge.
    m.mapButtonGap = math.max(4, m.pad(4))
    m.mapButtonHeight = math.max(20, m.pad(20))
    m.mapButtonWidths = { pop = m.pad(64), shapes = m.pad(74), fit = m.pad(36), zoomOut = m.pad(24), zoomIn = m.pad(24) }
    local chrome = m.pad(8)
    for _,w in pairs(m.mapButtonWidths) do chrome = chrome + w + m.mapButtonGap end
    m.mapChromeWidth = chrome

    -- Production panel internals. The row count is derived from these by
    -- counting, never by a second hard-coded formula, so the count and the
    -- loop that draws the rows cannot disagree again.
    m.buildNavTop = m.pad(34)
    m.buildNavHeight = m.pad(28)
    m.buildFirstRowOffset = m.pad(36)
    m.buildRowHeight = m.pad(44)
    m.buildRowPitch = math.max(m.pad(50), m.buildRowHeight + 6)
    m.buildFooter = m.pad(74)
    m.buildTabTop = m.pad(5)
    m.buildTabHeight = m.pad(24)
    m.buildMinHeight = m.buildNavTop + m.buildFirstRowOffset + m.buildRowHeight + m.buildFooter
    m.buildMaxHeight = m.pad(ui.ProductionMaxHeight or 350)

    -- Selection card.
    m.statsTop = m.topBarHeight + m.pad(14)
    m.statsSingleHeight = m.pad(314)
    m.statsMultiHeight = m.pad(134)
    m.selectionRowHeight = m.pad(21)

    -- Solve the right-hand column from the bottom up.
    local bottom = sh - m.margin
    local mapFloor = m.pad(110)
    local function available(quickH, gaps)
        return bottom - m.mapTop - (m.policyHeight + m.optionsHeight + quickH + gaps * m.gap)
    end
    -- Aim for a three-row build page, then let the map take whatever is left up
    -- to its preferred height. This is what makes the column adapt instead of
    -- being a fixed 864px stack that overflowed a 720p screen.
    local desiredProduction = math.min(m.buildMaxHeight, m.buildMinHeight + 2 * m.buildRowPitch)
    -- Priority order for a short screen: the map keeps a readable minimum, the
    -- quick-group strip goes next (it is a convenience over controls that also
    -- have number-key and wing-key bindings, and the control groups keep
    -- working through HandleUILeftClick because the rect table is simply
    -- empty), and build capacity is given up last. Deciding this against the
    -- DESIRED build page rather than the bare one-row minimum is what keeps the
    -- row count from dipping at 768p, where the strip used to be kept and cost
    -- a whole row.
    local quickH, gaps = m.quickGroupHeight, 3
    if available(quickH, gaps) - m.gap - desiredProduction < mapFloor then quickH, gaps = 0, 2 end
    local avail = available(quickH, gaps)
    m.mapHeight = clamp(avail - m.gap - desiredProduction, mapFloor, m.mapPreferredHeight)
    m.quickGroupsVisible = quickH > 0
    m.quickGroupHeight = quickH

    local prodTop = m.mapTop + m.mapHeight + m.gap
    local prodBottom = bottom - (m.policyHeight + m.optionsHeight + quickH + gaps * m.gap)
    m.productionHeight = clamp(prodBottom - prodTop, m.buildMinHeight, avail - m.gap - mapFloor)

    self.UIMetrics = m
    return m
end

function RTS:GetMapView()
    local v=self.MapView
    if v==nil then
        local sw,sh=gr.getScreenWidth(),gr.getScreenHeight()
        local m=self:GetUIMetrics(sw,sh)
        v={zoom=1,cx=0,cz=0,popped=false,alpha=0.75,
            w=math.min(sw-m.margin*2,math.max(280,m.mapWidth+math.floor(m.mapWidth*0.4))),
            h=math.min(sh-m.margin*2,math.max(200,m.mapHeight+math.floor(m.mapHeight*0.5)))}
        v.x=math.floor((sw-v.w)/2); v.y=math.floor((sh-v.h)/2); self.MapView=v
    end
    return v
end

-- Whole map window including the popped-out header bar.
--
-- Both of these used to build a fresh four-number table on every call, and
-- WorldToTacticalMap calls GetTacticalMapRect once per ship, so the tactical
-- map was allocating a rectangle per contact per frame and re-deriving the
-- same answer every time. The rect is frame-invariant: it comes out of the
-- cached UI metrics and the window geometry, and neither moves while a ship is
-- being projected. The key below is exactly the set of inputs, so a resize or
-- a window drag invalidates it and nothing else does.
function RTS:GetTacticalMapFrame()
    local v = self:GetMapView()
    if not v.popped then return self:GetTacticalMapRect() end
    local key = "p|" .. v.x .. "|" .. v.y .. "|" .. v.w .. "|" .. v.h
    local cached = self.MapFrameCache
    if cached ~= nil and cached.key == key then return cached.rect end
    local rect = { x1 = v.x, y1 = v.y, x2 = v.x + v.w, y2 = v.y + v.h }
    self.MapFrameCache = { key = key, rect = rect }
    return rect
end

-- Drawable map area (world content only).
function RTS:GetTacticalMapRect()
    local v = self:GetMapView()
    local key
    if v.popped then
        key = "p|" .. v.x .. "|" .. v.y .. "|" .. v.w .. "|" .. v.h .. "|" .. self:GetMapHeaderHeight()
    else
        -- tostring on the metrics table is identity for a given screen size and
        -- changes the moment the layout solve re-runs, which is the only thing
        -- that can move the docked rect.
        key = "d|" .. tostring(self:GetUIMetrics())
    end
    local cached = self.MapRectCache
    if cached ~= nil and cached.key == key then return cached.rect end
    local rect
    if v.popped then
        local h = self:GetMapHeaderHeight()
        rect = { x1 = v.x, y1 = v.y + h, x2 = v.x + v.w, y2 = v.y + v.h }
    else
        rect = self:GetDockedMapRect()
    end
    self.MapRectCache = { key = key, rect = rect }
    return rect
end

-- Fixed top-right slot; the right-hand panels stack under it even when popped
-- out. Height comes from the column solve in GetUIMetrics, so the map yields
-- space to the panels below it on a short screen instead of pushing them off
-- the bottom.
function RTS:GetDockedMapRect()
    local m = self:GetUIMetrics()
    local x2 = m.sw - m.margin
    local x1 = x2 - m.mapWidth
    return { x1 = x1, y1 = m.mapTop, x2 = x2, y2 = m.mapTop + m.mapHeight }
end

function RTS:SetMapZoom(zoom, anchorX, anchorY)
    local v=self:GetMapView(); local before=anchorX and self:TacticalMapToWorld(anchorX,anchorY)
    v.zoom=clamp(zoom,1,12)
    if before then local after=self:TacticalMapToWorld(anchorX,anchorY); v.cx=v.cx+(before.x-after.x); v.cz=v.cz+(before.z-after.z) end
    self:ClampMapCenter()
end

function RTS:ClampMapCenter()
    local v=self:GetMapView(); local half=self:GetTacticalMapHalfExtent(); local limit=half-half/v.zoom
    v.cx=clamp(v.cx,-limit,limit); v.cz=clamp(v.cz,-limit,limit)
end

function RTS:GetTacticalMapHalfExtent()
    local profile=self:GetBaseDistanceProfile(); local d=profile and profile.distance or 18000
    return math.max(self.Config.TacticalMap.HalfExtent or 15000,d*0.72+2000)
end

-- Third return value is false when the position lies outside the zoomed view.
function RTS:WorldToTacticalMap(position)
    return self:WorldToTacticalMapIn(position, self:GetTacticalMapRect(), self:GetMapView(),
        self:GetTacticalMapHalfExtent())
end

-- The same mapping with its frame-invariant inputs passed in. Every one of
-- these is a function call that re-derives the window geometry, the map centre
-- and the configured half extent, and WorldToTacticalMap is called once per
-- ship, so the map pass was re-deriving all three for every contact. The hot
-- callers resolve them once and call this per ship.
function RTS:WorldToTacticalMapIn(position, rect, view, halfExtent)
    local scaled = halfExtent / view.zoom
    local rx = (position.x - view.cx) / scaled
    local rz = (position.z - view.cz) / scaled
    local nx = clamp(rx, -1, 1)
    local nz = clamp(rz, -1, 1)
    local px = rect.x1 + (nx + 1) * 0.5 * (rect.x2 - rect.x1)
    local py = rect.y2 - (nz + 1) * 0.5 * (rect.y2 - rect.y1)
    return px, py, (nx == rx and nz == rz)
end

function RTS:TacticalMapToWorld(x,y)
    local rect=self:GetTacticalMapRect(); local v=self:GetMapView(); local half=self:GetTacticalMapHalfExtent()/v.zoom
    local nx=clamp((x-rect.x1)/(rect.x2-rect.x1),0,1)*2-1; local nz=(1-clamp((y-rect.y1)/(rect.y2-rect.y1),0,1))*2-1
    return vec(v.cx+nx*half,self.CameraFocus.y,v.cz+nz*half)
end

function RTS:IsPointOnTacticalMap(x, y)
    return self:PointInside(self:GetTacticalMapFrame(), x, y)
end

-- Map window buttons, header drag, resize grip and opacity slider.
-- Returns true when the press was consumed.
function RTS:HandleMapUIPress(x, y)
    local v=self:GetMapView(); local b=self.MapButtonRects or {}
    if b.zoomIn and self:PointInside(b.zoomIn,x,y) then self:SetMapZoom(v.zoom*1.5); return true end
    if b.zoomOut and self:PointInside(b.zoomOut,x,y) then self:SetMapZoom(v.zoom/1.5); return true end
    if b.fit and self:PointInside(b.fit,x,y) then v.zoom=1; v.cx=0; v.cz=0; return true end
    if b.shapes and self:PointInside(b.shapes,x,y) then v.shapes=not v.shapes; return true end
    if b.pop and self:PointInside(b.pop,x,y) then v.popped=not v.popped; self:ClampMapWindow(); return true end
    if not v.popped then return false end
    if b.slider and self:PointInside(b.slider,x,y) then self.MapWindowDrag={kind="alpha"}; self:UpdateMapWindowDrag(x,y); return true end
    if b.grip and self:PointInside(b.grip,x,y) then self.MapWindowDrag={kind="resize",x=x,y=y,w=v.w,h=v.h}; return true end
    if y>=v.y and y<v.y+self:GetMapHeaderHeight() and x>=v.x and x<=v.x+v.w then self.MapWindowDrag={kind="move",x=x,y=y,ox=v.x,oy=v.y}; return true end
    return false
end

function RTS:UpdateMapWindowDrag(x, y)
    local d=self.MapWindowDrag; if d==nil then return end; local v=self:GetMapView()
    if d.kind=="move" then v.x=d.ox+(x-d.x); v.y=d.oy+(y-d.y)
    elseif d.kind=="resize" then v.w=d.w+(x-d.x); v.h=d.h+(y-d.y)
    elseif d.kind=="alpha" then local s=self.MapButtonRects.slider; v.alpha=clamp((x-s.x1)/math.max(1,s.x2-s.x1),0.15,1) end
    self:ClampMapWindow()
end

function RTS:ClampMapWindow()
    local v=self:GetMapView(); local sw,sh=gr.getScreenWidth(),gr.getScreenHeight()
    local m=self:GetUIMetrics(sw,sh)
    -- A popped-out window has to stay big enough for its own header buttons, so
    -- the floor is the measured width of that button row rather than a guess.
    local minW=math.max(280,m.mapChromeWidth+m.pad(20)); local minH=math.max(200,m.mapHeader+120)
    v.w=clamp(v.w,minW,math.max(minW,sw-m.margin*2)); v.h=clamp(v.h,minH,math.max(minH,sh-m.margin*2))
    v.x=clamp(v.x,m.margin,math.max(m.margin,sw-m.margin-v.w)); v.y=clamp(v.y,m.margin,math.max(m.margin,sh-m.margin-v.h))
end

-- The one predicate the tactical map uses to decide what a click or a drag can
-- pick.
--
-- There were three, and they did not agree. SelectMapClick took
-- IsFriendly OR IsPlayerEnemy, GetMapShipAt took the same set but expressed as
-- a raw observer-name compare, and SelectMapBox took IsFriendly only. The
-- player-visible consequence is that clicking an enemy raider on the map put
-- it in the selection and the identical drag one pixel over refused to, and
-- dragging a box over a Vasudan (third-faction) contact silently selected
-- nothing. Click and drag now ask the same question, so they cannot disagree
-- about what is hostile.
--
-- Note this makes the map's box select include hostiles, which the WORLD box
-- select still does not. That asymmetry is deliberate and is called out in the
-- report: the world drag is a fleet gesture matched to SelectAll, whereas a
-- map click already selected hostiles so the player could right-click them for
-- an order. Widening the world drag would put hostile hulls into a move
-- gesture's selection.
function RTS:IsMapSelectableTarget(ship)
    if not shipValid(ship) or ship.Name == self.Config.ObserverShip then return false end
    if self:IsFriendly(ship) then return true end
    return self:IsPlayerEnemy(ship)
end

function RTS:SelectMapClick(mouseX, mouseY)
    local best = nil
    local bestScore = math.huge
    local pick = self.Config.TacticalMap.PickRadiusPixels or 10
    local view = self:GetMapView()
    local rect = self:GetTacticalMapRect()
    local half = self:GetTacticalMapHalfExtent()
    self:EachShip(function(ship)
        if self:IsMapSelectableTarget(ship) then
            local sx, sy, inView = self:WorldToTacticalMapIn(ship.Position, rect, view, half)
            local score = distance2(mouseX, mouseY, sx, sy)
            if inView and score <= pick * pick and score < bestScore then best, bestScore = ship, score end
        end
    end)
    if not shipValid(best) then
        -- An empty map click clears the selection. It used to clear Selected
        -- but leave PrimarySelectionSignature pointing at whatever was
        -- selected a moment ago, so every downstream "the primary ship" read
        -- - the order the last clicked ship was given, the detail card, the
        -- station panel - acted on a ship the player had just deselected.
        if not self.ShiftDown then self.Selected = {}; self.PrimarySelectionSignature = nil end
        return
    end
    local sig = best:getSignature()
    if self.ShiftDown then
        if tableContainsSignature(self.Selected, sig) then
            local result = {}
            for _, current in ipairs(self.Selected) do if current ~= sig then result[#result + 1] = current end end
            self.Selected = result
        else
            self.Selected[#self.Selected + 1] = sig
        end
    else
        self.Selected = { sig }
    end
    -- SelectMapBox has always published this; a map click did not, so a ship
    -- picked off the map never became the primary and the detail card and the
    -- station panel showed the previous selection.
    if self.PrimarySelectionSignature ~= nil and not tableContainsSignature(self.Selected, self.PrimarySelectionSignature) then
        self.PrimarySelectionSignature = nil
    end
    self.PrimarySelectionSignature = self.Selected[1]
end

function RTS:SelectMapBox(x1, y1, x2, y2)
    local rect = self:GetTacticalMapRect()
    local left = clamp(math.min(x1, x2), rect.x1, rect.x2)
    local right = clamp(math.max(x1, x2), rect.x1, rect.x2)
    local top = clamp(math.min(y1, y2), rect.y1, rect.y2)
    local bottom = clamp(math.max(y1, y2), rect.y1, rect.y2)
    local result = self.ShiftDown and self.Selected or {}
    local view = self:GetMapView()
    local half = self:GetTacticalMapHalfExtent()

    self:EachShip(function(ship)
        if self:IsMapSelectableTarget(ship) then
            local sx, sy, inView = self:WorldToTacticalMapIn(ship.Position, rect, view, half)
            if not inView then return end
            if sx >= left and sx <= right and sy >= top and sy <= bottom then
                local sig = ship:getSignature()
                if not tableContainsSignature(result, sig) then result[#result + 1] = sig end
            end
        end
    end)
    self.Selected = result; self.PrimarySelectionSignature=self.Selected[1]
end

function RTS:GetMapShipAt(mouseX, mouseY)
    local best, bestScore = nil, math.huge
    local pick = self.Config.TacticalMap.PickRadiusPixels or 10
    local view = self:GetMapView()
    local rect = self:GetTacticalMapRect()
    local half = self:GetTacticalMapHalfExtent()
    self:EachShip(function(ship)
        if self:IsMapSelectableTarget(ship) then
            local sx, sy, inView = self:WorldToTacticalMapIn(ship.Position, rect, view, half)
            local score = distance2(mouseX, mouseY, sx, sy)
            if inView and score <= pick * pick and score < bestScore then best, bestScore = ship, score end
        end
    end)
    return best
end

-- Minimap RMB mirrors the world RMB: hostile = attack, friendly = guard,
-- empty = move. With nothing selected it still jumps the camera.
function RTS:MapRightClick(x, y)
    if #self:GetSelectedFriendlyShips() == 0 then self:JumpCameraFromMap(x, y); return end
    local ship = self:GetMapShipAt(x, y)
    if shipValid(ship) and self:IsPlayerEnemy(ship) then self:IssueAttack(ship); self:SetOrderPing(ship.Position,"attack"); return end
    if shipValid(ship) and self:IsFriendly(ship) then self:IssueGuard(ship); self:SetOrderPing(ship.Position,"guard"); return end
    local target = self:TacticalMapToWorld(x, y)
    self:IssueMove(target); self:SetOrderPing(target,"move")
end

-- Short-lived map marker so a minimap order is visibly acknowledged.
function RTS:SetOrderPing(position, kind)
    -- A missing acknowledgement marker is cosmetic; a crash here kills the whole
    -- input handler on the player's own click. Same class as the copyVec(nil) in
    -- $On Waypoints Done. Callers pass ship.Position, a ScreenToPlane result or a
    -- raw focus vector, all of which can be absent on a degenerate pick.
    if position==nil or not self:IsFiniteVector(position) then return end
    local sigs={}; for _,s in ipairs(self:GetSelectedFriendlyShips()) do sigs[#sigs+1]=s:getSignature() end
    self.OrderPing={pos=copyVec(position),kind=kind,sigs=sigs,untilTime=self:UINow()+2}
end

function RTS:JumpCameraFromMap(x, y)
    if self.FollowSignature ~= nil then self:ExitFollowMode() end
    local world = self:TacticalMapToWorld(x, y)
    self.CameraFocus = world
    gr.setCamera(self.Camera)
    self:UpdateCameraTransform()
    self:SetStatus("Tactical camera repositioned", 1.2)
end

-- Cost order in this loop is the whole point of the function, because it runs
-- over every ship in the world on every click, every right-button press and
-- every frame of hover.
--
--   1. the observer's NAME          - one property read
--   2. the team                     - was being resolved up to THREE times per
--                                    ship, because IsFriendly, IsHostile and
--                                    IsThirdFaction each re-derive teamName,
--                                    and teamName is four reads (isValid,
--                                    getBreedName, Team.Name, string.lower)
--   3. the tangent-space gate       - about a dozen flops, no engine call
--   4. the cached projection        - free for a ship already seen this epoch
--   5. "cannot be further than the widest radius in play" - one subtraction
--   6. only then getDistance and Class.Model.Radius, the two expensive reads
--
-- Steps 5 and 6 are the reorder: the exact pick radius depends on the hull's
-- own model radius and its distance from the camera, and both were read for
-- every ship in the world before anything had established that the ship could
-- be within reach at all.
-- projectAge is the projection tolerance in EPOCHS and defaults to 0, meaning
-- "from this epoch", which is what every click path needs: the ship a click
-- selects must be the ship the player is looking at. The only caller that
-- passes anything else is the hover readout, which is an inspection aid drawn
-- over a contact the reticle pass has normally already projected this frame,
-- and a one-frame-old position is exactly as good there.
function RTS:GetShipAtScreen(mouseX, mouseY, includeFriendly, includeEnemies, hoverPick, projectAge)
    local best = nil
    local bestScore = math.huge
    local screenH = math.max(1, gr.getScreenHeight())
    local screenW = math.max(1, gr.getScreenWidth())
    local sel = self.Config.Selection or {}
    local activeCamera = self.Camera
    if self.FollowSignature ~= nil and self.FollowCamera ~= nil then activeCamera = self.FollowCamera end
    local baseRadius = sel.BasePickRadiusPixels or 20

    -- The widest radius any of the per-ship rules below can produce. Used for
    -- the gate and for the cheap range test; the exact radius is only derived
    -- for a ship that has already passed both.
    local reach = sel.MaxPickRadiusPixels or 110
    if hoverPick then
        local capital = sel.CapitalHoverPickRadiusPixels or 280
        if capital > reach then reach = capital end
    end
    local reachSquared = reach * reach
    local gate = self:BuildPickGate(mouseX, mouseY, screenW, screenH, reach)

    local observer = self.Config.ObserverShip
    local friendlyTeam = self.Config.FriendlyTeam
    local hostileTeam = self.Config.HostileTeam
    local thirdTeam = self.Config.ThirdTeam
    local cameraPosition = activeCamera ~= nil and activeCamera.Position or nil

    self:EachShip(function(ship)
        if ship.Name == observer then return end
        local team = lower(teamName(ship))
        local allowed = false
        if includeFriendly and team == friendlyTeam then allowed = true end
        if not allowed and includeEnemies and (team == hostileTeam or team == thirdTeam) then allowed = true end
        if not allowed then return end
        local position = ship.Position
        if position == nil then return end
        if gate ~= nil and not self:PassesScreenGate(gate, position) then return end
        local sx, sy = self:ProjectShip(ship, projectAge or 0)
        if sx == false then return end

        local score = distance2(mouseX, mouseY, sx, sy)
        if score > reachSquared then return end

        local radius = baseRadius
        if cameraPosition ~= nil then
            local dist = position:getDistance(cameraPosition)
            local modelRadius = 30
            if ship.Class and ship.Class.Model then modelRadius = ship.Class.Model.Radius end
            -- Keep click/selection tolerance unchanged; broad hull picking is
            -- only for passive hover inspection of capital-sized targets.
            local maxPickRadius = sel.MaxPickRadiusPixels
            if hoverPick and self:IsCapitalTarget(ship) then
                maxPickRadius = math.max(maxPickRadius, sel.CapitalHoverPickRadiusPixels or 280)
            end
            radius = clamp((modelRadius / math.max(dist, 1)) * screenH * 1.35, baseRadius, maxPickRadius)
        end
        if score <= radius * radius and score < bestScore then
            best = ship
            bestScore = score
        end
    end)
    return best
end

function RTS:SelectClick(mouseX, mouseY)
    local ship=self:GetShipAtScreen(mouseX,mouseY,true,true)
    if ship==nil then if not self.ShiftDown then self.Selected={}; self.PrimarySelectionSignature=nil end; return end
    if self.CtrlDown then self:SelectSameClass(ship,true); self.PrimarySelectionSignature=ship:getSignature(); return end
    local sig=ship:getSignature()
    if self.ShiftDown then
        if tableContainsSignature(self.Selected,sig) then
            local n={}; for _,v in ipairs(self.Selected) do if v~=sig then n[#n+1]=v end end; self.Selected=n
            if self.PrimarySelectionSignature==sig then self.PrimarySelectionSignature=self.Selected[1] end
        else self.Selected[#self.Selected+1]=sig; self.PrimarySelectionSignature=sig end
    else self.Selected={sig}; self.PrimarySelectionSignature=sig end
end

function RTS:SelectBox(x1, y1, x2, y2)
    local left = math.min(x1, x2)
    local right = math.max(x1, x2)
    local top = math.min(y1, y2)
    local bottom = math.max(y1, y2)
    local result = self.ShiftDown and self.Selected or {}
    local sw = math.max(1, gr.getScreenWidth())
    local sh = math.max(1, gr.getScreenHeight())
    -- Reject a ship that cannot land inside the rubber band before it costs a
    -- projection. The exact box test still runs after the projection, so this
    -- can only ever be a superset.
    local gate = self:BuildScreenGate(sw, sh, (left + right) * 0.5, (top + bottom) * 0.5,
        (right - left) * 0.5, (bottom - top) * 0.5, PICK_GATE_ASPECT_SLACK)

    self:EachShip(function(ship)
        if self:IsFriendly(ship) then
            local position = ship.Position
            if position ~= nil and (gate == nil or self:PassesScreenGate(gate, position)) then
                local sx, sy = self:ProjectShip(ship, 0)
                if sx ~= false and sx >= left and sx <= right and sy >= top and sy <= bottom then
                    local sig = ship:getSignature()
                    if not tableContainsSignature(result, sig) then result[#result + 1] = sig end
                end
            end
        end
    end)
    self.Selected = result; self.PrimarySelectionSignature=self.Selected[1]
end

function RTS:PointInside(rect, x, y)
    return rect ~= nil and x >= rect.x1 and x <= rect.x2 and y >= rect.y1 and y <= rect.y2
end


function RTS:GetPolicyPanelRect(sw, sh)
    local m = self:GetUIMetrics(sw, sh)
    local x2 = m.sw - m.margin
    local x1 = x2 - m.rightPanelWidth
    local y2 = m.sh - m.margin
    local y1 = y2 - m.policyHeight
    return { x1=x1, y1=y1, x2=x2, y2=y2 }
end

function RTS:GetOptionsPanelRect(sw, sh)
    local policy = self:GetPolicyPanelRect(sw, sh)
    local m = self:GetUIMetrics(sw, sh)
    return { x1=policy.x1, y1=policy.y1-m.gap-m.optionsHeight, x2=policy.x2, y2=policy.y1-m.gap }
end

-- Vertical budget the production panel has, in pixels: the band between the
-- bottom of the docked map and the top of the quick-group strip.
function RTS:GetProductionPanelRect(sw, sh)
    local m = self:GetUIMetrics(sw, sh)
    local mapRect = self:GetDockedMapRect()
    local x1, x2 = m.sw - m.margin - m.rightPanelWidth, m.sw - m.margin
    local y1 = mapRect.y2 + m.gap
    if self.PanelTab == "station" then
        -- The station tab is laid out in its own fixed pixels (fs2rts_station.lua
        -- is not one of the files that may be rescaled) and needs 276px of
        -- content inside the 36/76 band insets DrawBuildPanel hands it, so the
        -- panel is sized to that requirement rather than to the column's slack.
        -- Quick groups, options and policy are not drawn while this tab is up,
        -- so the station panel is free to use the whole column.
        local wanted = clamp(m.pad(430), m.pad(388), m.pad(388) + m.pad(120))
        return { x1=x1, y1=y1, x2=x2, y2=y1 + wanted }
    end
    return { x1=x1, y1=y1, x2=x2, y2=y1 + m.productionHeight }
end

function RTS:GetQuickGroupPanelRect(sw,sh)
    local m=self:GetUIMetrics(sw,sh)
    local prod=self:GetProductionPanelRect(sw,sh)
    if not m.quickGroupsVisible then
        return { x1=prod.x1, y1=prod.y2, x2=prod.x2, y2=prod.y2 }
    end
    return { x1=prod.x1, y1=prod.y2+m.gap, x2=prod.x2, y2=prod.y2+m.gap+m.quickGroupHeight }
end

-- How many build rows the production panel can actually draw. Counted from the
-- same geometry the drawing loop uses; the old version computed a page size
-- from (height-142)/50 while the loop tested against (y2-74) with a 50px pitch,
-- and those two constants did not agree, which is how a 768p screen ended up
-- with a page size of one and a loop that broke before drawing even that.
function RTS:CountBuildRows(sw, sh)
    local m = self:GetUIMetrics(sw, sh)
    local rect = self:GetProductionPanelRect(sw, sh)
    local y = rect.y1 + m.buildNavTop + m.buildFirstRowOffset
    local limit = rect.y2 - m.buildFooter
    local rows = 0
    while y + m.buildRowHeight <= limit do
        rows = rows + 1
        y = y + m.buildRowPitch
        if rows >= 8 then break end
    end
    return math.max(1, rows)
end

function RTS:SetAutoPlayerMode(enabled)
    enabled=enabled==true
    if self.AutoPlayerMode==enabled then return end
    self.AutoPlayerMode=enabled
    local now=mn.getMissionTime()
    if enabled then
        if self.AIStates.BLUE==nil then self.AIStates.BLUE={cp=self.CommandPoints,income=0,lastIncome=now,queue=nil,nextThink=now+1,serial=0,eliminated=false,playerEconomy=true} end
        self:EachShip(function(ship) if self:IsMovableFriendly(ship) and self.UserOrders[ship:getSignature()]==nil and self.PossessedSignature~=ship:getSignature() then self:AssignAIStrategicOrder(ship,"BLUE",true) end end)
        self:SetStatus("BLUE AUTO MODE ENABLED",2)
    else
        if self.AIStates.BLUE and self.AIStates.BLUE.queue then
            local q=self.AIStates.BLUE.queue
            local refund=q.estimate and q.estimate.cost or 0
            local before=self.CommandPoints
            if refund>0 then
                self.CommandPoints=self.CommandPoints+refund
                self:RecordAIEconomyFlow("BLUE","refund",refund)
                self:EmitAIEvent("PRODUCTION",{action="QUEUE_CANCELLED",producer="AI",faction="BLUE",
                    class=q.entry and q.entry.class or "UNKNOWN",count=q.count or 1,cost=refund,
                    refundedCP=refund,cpBefore=before,cpAfter=self.CommandPoints,reason="AUTO_MODE_DISABLED"},now)
            end
            self.AIStates.BLUE.queue=nil
        end
        -- Dropping the state is what actually stops Blue production. Keeping it
        -- alive with playerEconomy=true let UpdateAIProduction keep re-syncing to
        -- the player's CP and buying ships after the mode was switched off.
        self.AIStates.BLUE=nil
        self:EachShip(function(ship)
            if self:IsMovableFriendly(ship) and self.UserOrders[ship:getSignature()]==nil then
                local sig=ship:getSignature(); self.AIOrderState[sig]=nil; self:ApplyPolicyToShip(ship,true)
            end
        end)
        self:SetStatus("BLUE AUTO MODE DISABLED - FLEET ON MANUAL CONTROL",2)
    end
end

-- Formation cycle. delta -1 walks backwards; the list wraps so a single button
-- reaches every shape without a separate picker panel.
function RTS:CycleSelectedFormation(delta)
    local types=self:GetFormationTypes()
    if types==nil or #types==0 then return end
    local current=self:GetSelectedFormation()
    local index=0
    for i,entry in ipairs(types) do if entry.id==current then index=i break end end
    local nextIndex=((index-1+(tonumber(delta) or 1))%#types)+1
    local id=types[nextIndex].id
    if not self:SetSelectedFormation(id) then return end
    for _,entry in ipairs(types) do if entry.id==id then self:SetStatus("FORMATION: "..string.upper(entry.label).." // "..entry.desc,2.4) break end end
end
---- FSO exposes no runtime volume control for the event score, but every stream
-- (mission $Event Music, menu music) shares one global handle table, so
-- pausing handle -1 silences the music without touching weapons or UI audio.
function RTS:SetMusicMuted(muted,silent)
    local cfg=self.Config.Music or {}
    if cfg.Enabled==false then
        if not silent then self:SetStatus("Music muting is disabled in config",1.6) end
        return false
    end
    muted=muted==true
    self.MusicMuted=muted
    local ok=false
    pcall(function()
        if ad==nil then error("audio library unavailable") end
        ad.pauseMusic(-1,muted)
        ok=true
    end)
    if not ok then if not silent then self:SetStatus("Music mute unavailable in this engine build",2) end return false end
    if not silent then self:SetStatus(muted and "MUSIC MUTED" or "MUSIC ON",1.6) end
    return true
end

function RTS:ToggleMusicMute()
    return self:SetMusicMuted(not self.MusicMuted)
end

function RTS:GetSelectionPanelRect(sw, sh)
    local m = self:GetUIMetrics(sw, sh)
    local y2 = m.sh - m.margin
    return { x1=m.margin, y1=y2 - m.selectionHeight, x2=m.margin + m.selectionWidth, y2=y2 }
end

function RTS:IsPointOnRTSUI(x,y)
    local sw,sh=gr.getScreenWidth(),gr.getScreenHeight()
    local m=self:GetUIMetrics(sw,sh)
    if y>=0 and y<=m.topBarHeight then return true end
    if self:IsPointOnTacticalMap(x,y) then return true end
    if self:PointInside(self:GetProductionPanelRect(sw,sh),x,y) then return true end
    if m.quickGroupsVisible and self:PointInside(self:GetQuickGroupPanelRect(sw,sh),x,y) then return true end
    if self:PointInside(self:GetPolicyPanelRect(sw,sh),x,y) then return true end
    if self:PointInside(self:GetOptionsPanelRect(sw,sh),x,y) then return true end
    if self:PointInside(self:GetSelectionPanelRect(sw,sh),x,y) then return true end
    if #self:GetSelectedShips()>0 and x>=m.margin and x<=m.margin+m.selectionWidth
        and y>=m.statsTop and y<=self:GetSelectedStatsBottom(sw,sh) then return true end
    return false
end

function RTS:GetSelectedStatsBottom(sw,sh)
    local m=self:GetUIMetrics(sw,sh)
    return m.statsTop + ((#self:GetSelectedShips()==1) and m.statsSingleHeight or m.statsMultiHeight)
end

function RTS:HandleUILeftClick(x,y)
    if self.SetupActive then return self:HandleSetupClick(x,y) end
    for tab,rect in pairs(self.PanelTabRects or {}) do if self:PointInside(rect,x,y) then self.PanelTab=tab; return true end end
    if self.PanelTab=="station" and self:HandleStationPanelClick(x,y) then return true end
    for scale,rect in pairs(self.TimeButtonRects or {}) do if self:PointInside(rect,x,y) then if scale=="pause" then self:TogglePause() elseif self.Paused then self:SetPaused(false) end; if scale~="pause" then self:SetTimeScale(tonumber(scale)) end; return true end end
    if self:PointInside(self.AutoModeRect,x,y) then self:SetAutoPlayerMode(not self.AutoPlayerMode); return true end
    if self:PointInside(self.FormationButtonRect,x,y) then self:CycleSelectedFormation(1); return true end
    if self:PointInside(self.MusicButtonRect,x,y) then self:ToggleMusicMute(); return true end
    for group,rect in pairs(self.QuickGroupRects or {}) do
        if self:PointInside(rect,x,y) then
            local n=tonumber(group); if self.CtrlDown or (self:GetControlGroupCount(n)==0 and #self:GetSelectedFriendlyShips()>0) then self:AssignControlGroup(n) else self:RecallControlGroup(n) end
            return true
        end
    end
    for index=1,self.SelectionRowsShown or 0 do
        local row=self.SelectionRows[index]
        if row.rect and self:PointInside(row.rect,x,y) then
            local sigs={}; for _,sig in ipairs(row.sigs) do if self:IsSelectableShip(self:FindShipBySignature(sig)) then sigs[#sigs+1]=sig end end
            if #sigs>0 then self.Selected=sigs; self.PrimarySelectionSignature=sigs[1] end
            return true
        end
    end
    for index,rect in pairs(self.BuildButtonRects or {}) do if self:PointInside(rect,x,y) then self:QueueBuildOption(self.BuildCatalog[index]); return true end end
    if self:PointInside(self.BuildNavRects.prev,x,y) then self.BuildPage=math.max(1,self.BuildPage-1); return true end
    if self.BuildNavRects.filter and self:PointInside(self.BuildNavRects.filter,x,y) then
        local filters={"all","fighter","bomber","escort","capital"}; local current=self.BuildRoleFilter or "all"
        for i,value in ipairs(filters) do if value==current then self.BuildRoleFilter=filters[i%#filters+1]; break end end
        self.BuildPage=1; return true
    end
    if self:PointInside(self.BuildNavRects.next,x,y) then local pages=math.max(1,math.ceil(#self:GetVisibleBuildCatalog()/self.BuildRowsPerPage)); self.BuildPage=math.min(pages,self.BuildPage+1); return true end
    for action,rect in pairs(self.ActionButtonRects) do if self:PointInside(rect,x,y) then if action=="selectall" then self:SelectAll() elseif action=="hold" then self:HoldSelected() elseif action=="engage" then self:EngageSelected() elseif action=="release" then self:ReleaseSelected() elseif action=="service" then self:ServiceSelected() elseif action=="move" then self:ArmCommand("move") elseif action=="attack" then self:ArmCommand("attack") elseif action=="pilot" then self:EnterPilotFromSelection() elseif action=="focus" then self:FocusOnSelection() end; return true end end
    for policy,rect in pairs(self.PolicyButtonRects) do if self:PointInside(rect,x,y) then self:SetGlobalPolicy(policy); return true end end
    return false
end

function RTS:OnMousePressed(button)
    if not self.Enabled or self.PossessedSignature~=nil then return end
    -- A mouse event is an epoch boundary: nothing can move a ship or the camera
    -- between this point and the end of the handler, so anything projected
    -- earlier in this handler is as current as anything projected later in it.
    self:BeginFrameProjection()
    self:DisarmObserverWeapons()
    if self.CinematicActive then local cfg=self.Config.Cinematic or {}; if cfg.AllowSkip~=false and cfg.SkipOnAnyInput~=false then self:EndIntroCinematic(true) end; return end
    if self.BattleCamActive then self:StopBattleCam(); self.SwallowMouseRelease=true; return end
    local x,y=io.getMouseX(),io.getMouseY()
    if self.PostBattleActive then return end
    if self.SetupActive then return end
    if bit.checkBit(button,0) then
        if self:HandleMapUIPress(x,y) then self.LeftDrag=nil; self.MapDrag=nil; return end
        if self:IsPointOnTacticalMap(x,y) then self.MapDrag={x1=x,y1=y,x2=x,y2=y}; self.LeftDrag=nil
        else
            -- onUI is load bearing. A press is the only place that knows where
            -- the gesture started, and the release has to be able to tell a
            -- click that began on a panel from a box-select that happened to
            -- finish over one.
            self.LeftDrag={x1=x,y1=y,x2=x,y2=y,alt=self.AltDown==true,onUI=self:IsPointOnRTSUI(x,y)}
        end
    elseif bit.checkBit(button,1) then
        if self.FollowSignature~=nil then self.FollowOrbitDrag={x=x,y=y,startX=x,startY=y,moved=false}
        elseif self:CanStartFacingDrag(x,y) then
            -- Right drag from empty space with a selection is a move order, not a
            -- camera orbit: press sets the destination, drag sets the facing.
            self.RightDrag={x=x,y=y,x1=x,y1=y,startX=x,startY=y,moved=false,worldX=x,worldY=y,facingDrag=true}
            self.MovePreview=nil
        else self.RightDrag={x=x,y=y,startX=x,startY=y,moved=false} end
    elseif bit.checkBit(button,2) then
        if self:IsPointOnTacticalMap(x,y) then self.MapPanDrag={x=x,y=y}; return end
        if self.FollowSignature~=nil then self:ExitFollowMode("Tactical camera") end
        self.MiddleDrag={x=x,y=y,startX=x,startY=y,moved=false}
    end
end

function RTS:OnMouseMoved()
    if not self.Enabled or self.PossessedSignature~=nil or self.CinematicActive or self.PostBattleActive then return end
    self:BeginFrameProjection()
    local x,y=io.getMouseX(),io.getMouseY()
    if self.MapWindowDrag then self:UpdateMapWindowDrag(x,y); return end
    if self.MapPanDrag then
        local a=self:TacticalMapToWorld(self.MapPanDrag.x,self.MapPanDrag.y); local b=self:TacticalMapToWorld(x,y); local v=self:GetMapView()
        v.cx=v.cx+(a.x-b.x); v.cz=v.cz+(a.z-b.z); self:ClampMapCenter(); self.MapPanDrag.x=x; self.MapPanDrag.y=y; return
    end
    if self.MapDrag then self.MapDrag.x2=x; self.MapDrag.y2=y elseif self.LeftDrag then self.LeftDrag.x2=x; self.LeftDrag.y2=y end
    local threshold=self.Config.Camera.DragThresholdPixels or 5
    if self.FollowOrbitDrag then
        local d=self.FollowOrbitDrag; local dx=x-d.x; local dy=y-d.y; local tx=x-d.startX; local ty=y-d.startY
        if tx*tx+ty*ty>threshold*threshold then d.moved=true end
        if d.moved then
            local slow=self.ShiftDown and (self.Config.Camera.ShiftSlowMultiplier or .35) or 1
            self.FollowYawOffset=(self.FollowYawOffset or 0)-dx*(self.Config.Camera.MouseOrbitYaw or .006)*slow
            self.FollowPitchOffset=clamp((self.FollowPitchOffset or .22)+dy*(self.Config.Camera.MouseOrbitPitch or .004)*slow,-1.18,1.18)
            local ship=self:FindShipBySignature(self.FollowSignature); if shipValid(ship) then self:UpdateFollowCamera(ship) end
        end
        d.x=x; d.y=y
        return
    end
    local function orbit(drag)
        local dx=x-drag.x; local dy=y-drag.y; local tdx=x-drag.startX; local tdy=y-drag.startY
        if tdx*tdx+tdy*tdy>threshold*threshold then drag.moved=true end
        if drag.moved then
            local mult=self.ShiftDown and (self.Config.Camera.ShiftSlowMultiplier or .35) or 1
            self.CameraYaw=self.CameraYaw-dx*(self.Config.Camera.MouseOrbitYaw or .006)*mult
            self.CameraPitch=clamp(self.CameraPitch+dy*(self.Config.Camera.MouseOrbitPitch or .004)*mult,math.rad(self.Config.Camera.MinPitchDegrees),math.rad(self.Config.Camera.MaxPitchDegrees))
            self:UpdateCameraTransform()
        end
        drag.x=x; drag.y=y
    end
    if self.MiddleDrag then
        local dx=x-self.MiddleDrag.x; local dy=y-self.MiddleDrag.y; local tdx=x-self.MiddleDrag.startX; local tdy=y-self.MiddleDrag.startY
        if tdx*tdx+tdy*tdy>threshold*threshold then self.MiddleDrag.moved=true end
        if self.MiddleDrag.moved and (dx~=0 or dy~=0) then
            local sh=math.max(1,gr.getScreenHeight()); local upp=(2*self.CameraDistance*math.tan((self.Camera.FOV or self.Config.Camera.FOV)*.5)/sh)*(self.Config.Camera.MousePanScale or 1)
            if self.ShiftDown then upp=upp*(self.Config.Camera.ShiftSlowMultiplier or .35) end
            local sy,cy=math.sin(self.CameraYaw),math.cos(self.CameraYaw)
            self.CameraFocus.x=self.CameraFocus.x-cy*dx*upp+sy*dy*upp; self.CameraFocus.z=self.CameraFocus.z+sy*dx*upp+cy*dy*upp; self:UpdateCameraTransform()
        end
        self.MiddleDrag.x=x; self.MiddleDrag.y=y
    end
    if self.RightDrag then
        local drag=self.RightDrag
        if drag.facingDrag then
            -- Track the cursor on the command plane so the HUD can draw the
            -- destination and the facing arrow while the drag is live. The
            -- drag threshold is measured from the press point, not the last
            -- move event, so a fast drag cannot be missed.
            local tdx=x-drag.startX; local tdy=y-drag.startY
            if tdx*tdx+tdy*tdy>threshold*threshold then drag.moved=true end
            drag.worldX=x; drag.worldY=y
            local destination=self:ScreenToPlane(drag.x1,drag.y1,self.CameraFocus.y)
            local facing=self:ScreenToPlane(x,y,self.CameraFocus.y)
            self.MovePreview=destination and {destination=destination,facing=facing} or nil
            return
        end
        orbit(drag)
    end
end

-- A facing drag only makes sense on a real move order: something selected, not
-- over the HUD, and starting on empty space.
function RTS:CanStartFacingDrag(x,y)
    if self.ArmedCommand~=nil or self.Paused or self.BattleCamActive or self.FreeCamActive then return false end
    if self:IsPointOnRTSUI(x,y) or self:IsPointOnTacticalMap(x,y) then return false end
    if #self:GetSelectedFriendlyShips()==0 then return false end
    if self:GetShipAtScreen(x,y,true,true)~=nil then return false end
    return true
end

-- An armed command released on the tactical map.
--
-- Only sentry and strike were handled here. MOVE and ATTACK fell straight
-- through to SelectMapClick/SelectMapBox, so arming MOVE (M or the MOVE
-- button), pressing MOVE on the map and clicking the destination changed the
-- selection instead of moving the fleet, and the armed state survived so the
-- next world click moved it to somewhere the player never looked. The map is
-- where an RTS player issues orders, so an armed order has to work there.
--
-- Returns true when it consumed the release. A release that started on the
-- map but ended off it is still consumed, which is what the sentry and strike
-- path already did, so the click does not fall through and select a hull in
-- the world instead.
function RTS:ExecuteMapArmedCommand(x, y)
    local kind = self.ArmedCommand
    if kind == nil then return false end
    if not self:IsPointOnTacticalMap(x, y) then return true end
    if kind == "sentry" or kind == "strike" then
        self:ExecuteStationArmedCommand(self:TacticalMapToWorld(x, y))
        return true
    end
    if kind == "move" then
        local target = self:TacticalMapToWorld(x, y)
        if self:IsFiniteVector(target) then self:IssueMove(target); self:SetOrderPing(target, "move") end
        self.ArmedCommand = nil
        return true
    end
    if kind == "attack" then
        local target = self:GetMapShipAt(x, y)
        if shipValid(target) and self:IsPlayerEnemy(target) then
            self:IssueAttack(target)
            self:SetOrderPing(target.Position, "attack")
        else
            self:SetStatus("ATTACK: click an enemy contact on the map (right-click cancels)", 2)
        end
        self.ArmedCommand = nil
        return true
    end
    return false
end

function RTS:OnMouseReleased(button)
    if not self.Enabled or self.PossessedSignature~=nil then return end
    self:BeginFrameProjection()
    -- The click that closed cinematic mode must not also select or issue an order.
    if self.SwallowMouseRelease then self.SwallowMouseRelease=false; return end
    if self.MapWindowDrag and bit.checkBit(button,0) then self.MapWindowDrag=nil; return end
    if self.MapPanDrag and bit.checkBit(button,2) then self.MapPanDrag=nil; return end
    if self.CinematicActive then return end
    local x,y=io.getMouseX(),io.getMouseY()
    if self.PostBattleActive then
        if bit.checkBit(button,0) then self:HandlePostBattleClick(x,y) end
        self.LeftDrag=nil; self.MapDrag=nil; self.RightDrag=nil; self.MiddleDrag=nil; self.FollowOrbitDrag=nil; self.MovePreview=nil
        return
    end
    if bit.checkBit(button,0) then
        if self.SetupActive then self:HandleSetupClick(x,y); self.LeftDrag=nil; self.MapDrag=nil; return end
        if self.MapDrag then
            local drag=self.MapDrag; self.MapDrag=nil
            if self:ExecuteMapArmedCommand(x,y) then return end
            local dx=x-drag.x1; local dy=y-drag.y1; local threshold=self.Config.Selection.DragThresholdPixels
            if dx*dx+dy*dy<=threshold*threshold then self:SelectMapClick(x,y) else self:SelectMapBox(drag.x1,drag.y1,x,y) end
            return
        end
        -- A left press that began in the world owns its release.
        --
        -- The press is the only place that knows where the gesture started. It
        -- used to be thrown away, so HandleUILeftClick ran on every left
        -- release regardless of origin: drag a box-select across the build
        -- panel and releasing over the PRODUCTION row queued a ship, and
        -- releasing over MUSIC toggled the music off. A drag that started on
        -- the world now never reaches a panel; a press that started on a panel
        -- behaves exactly as before.
        local worldGesture = self.LeftDrag ~= nil and not self.LeftDrag.onUI
        local dragged = false
        if worldGesture then
            local drag = self.LeftDrag
            local dx = x - drag.x1; local dy = y - drag.y1
            local threshold = self.Config.Selection.DragThresholdPixels
            dragged = (dx * dx + dy * dy) > threshold * threshold
        end
        if worldGesture and dragged then
            local drag = self.LeftDrag; self.LeftDrag = nil
            self:SelectBox(drag.x1, drag.y1, x, y)
            if drag.alt then self:FocusOnSelection() end
            return
        end
        if not worldGesture and self:HandleUILeftClick(x,y) then self.LeftDrag=nil; return end
        if self:IsPointOnRTSUI(x,y) then self.LeftDrag=nil; return end
        if self.LeftDrag and self.LeftDrag.alt then
            local drag=self.LeftDrag; self.LeftDrag=nil
            local dx=x-drag.x1; local dy=y-drag.y1; local threshold=self.Config.Selection.DragThresholdPixels
            if dx*dx+dy*dy>threshold*threshold then
                self:SelectBox(drag.x1,drag.y1,x,y)
                self:FocusOnSelection()
            else
                local target=self:GetShipAtScreen(x,y,true,true)
                local focus=target and target.Position or self:ScreenToPlane(x,y,self.CameraFocus.y)
                if focus~=nil then
                    if self.FollowSignature~=nil then self:ExitFollowMode("Tactical camera") end
                    self.CameraFocus=copyVec(focus); self:UpdateCameraTransform()
                    self:SetStatus(target and ("Focused: "..target.Name) or "Focused tactical area",1.2)
                end
            end
            return
        end
        if self.LeftDrag then local dx=x-self.LeftDrag.x1; local dy=y-self.LeftDrag.y1; local threshold=self.Config.Selection.DragThresholdPixels; if dx*dx+dy*dy<=threshold*threshold then if not self:ExecuteArmedCommand(x,y) and not self:HandleDoubleClick(x,y) then self:SelectClick(x,y) end else self:SelectBox(self.LeftDrag.x1,self.LeftDrag.y1,x,y) end end
        self.LeftDrag=nil
    elseif bit.checkBit(button,1) then
        if self.FollowOrbitDrag then self.FollowOrbitDrag=nil; return end
        local drag=self.RightDrag; self.RightDrag=nil
        if drag~=nil and drag.facingDrag then
            self.MovePreview=nil
            local destination=self:ScreenToPlane(drag.x1,drag.y1,self.CameraFocus.y)
            if destination==nil then return end
            local facing=nil
            if drag.moved then facing=self:ScreenToPlane(drag.worldX,drag.worldY,self.CameraFocus.y) end
            self:IssueMove(destination,facing)
            return
        end
        if drag~=nil and drag.moved then return end
        if self.ArmedCommand~=nil then self.ArmedCommand=nil; self:SetStatus("Order cancelled",1.2); return end
        if self:IsPointOnTacticalMap(x,y) then self:MapRightClick(x,y); return end
        if self:IsPointOnRTSUI(x,y) then return end
        local selected=self:GetSelectedFriendlyShips(); if #selected==0 then return end
        local hostile=self:GetShipAtScreen(x,y,false,true); if hostile then self:IssueAttack(hostile); return end
        local friendly=self:GetShipAtScreen(x,y,true,false); if friendly then self:IssueGuard(friendly); return end
        local destination=self:ScreenToPlane(x,y,self.CameraFocus.y); if destination then self:IssueMove(destination) end
    elseif bit.checkBit(button,2) then self.MiddleDrag=nil end
end

function RTS:OnMouseWheel(delta)
    if not self.Enabled or self.PossessedSignature ~= nil or self.CinematicActive or self.BattleCamActive or delta == nil or delta == 0 then return end
    local factor = self.Config.Camera.ZoomFactor

    if self.FollowSignature ~= nil then
        if delta > 0 then self.FollowZoom = self.FollowZoom * (factor ^ delta)
        else self.FollowZoom = self.FollowZoom / (factor ^ (-delta)) end
        self.FollowZoom = clamp(self.FollowZoom, 0.35, 3.5)
        local ship = self:FindShipBySignature(self.FollowSignature)
        if shipValid(ship) then self:UpdateFollowCamera(ship) end
        return
    end

    -- Sins-style zoom-to-cursor: keep the world point under the cursor anchored
    -- while changing altitude/distance.
    local mx, my = io.getMouseX(), io.getMouseY()
    if self:IsPointOnTacticalMap(mx, my) then local v=self:GetMapView(); self:SetMapZoom(v.zoom*(1.25^delta),mx,my); return end
    local anchorBefore = self:ScreenToPlane(mx, my, self.CameraFocus.y)
    if delta > 0 then self.CameraDistance = self.CameraDistance * (factor ^ delta)
    else self.CameraDistance = self.CameraDistance / (factor ^ (-delta)) end
    self.CameraDistance = clamp(self.CameraDistance, self.Config.Camera.MinDistance, self.Config.Camera.MaxDistance)
    self:UpdateCameraTransform()
    local anchorAfter = self:ScreenToPlane(mx, my, self.CameraFocus.y)
    if anchorBefore ~= nil and anchorAfter ~= nil then
        self.CameraFocus.x = self.CameraFocus.x + (anchorBefore.x - anchorAfter.x)
        self.CameraFocus.z = self.CameraFocus.z + (anchorBefore.z - anchorAfter.z)
        self:UpdateCameraTransform()
    end
end

function RTS:OnKeyPressed(key,rawKey)
    if not self.Enabled or key==nil then return end
    local rawEarly=rawKey or key; rawEarly=string.gsub(rawEarly,"^Shift%-",""); rawEarly=string.gsub(rawEarly,"^Ctrl%-",""); rawEarly=string.gsub(rawEarly,"^Alt%-","")
    -- The dedicated Pause key is a GAMEPLAY pause, always. It used to be routed
    -- to the mod's own pause only when AI.DisableMissionPause was set, so with
    -- that off the key fell through to the engine and opened the native game
    -- pause (with its restart/abort menu) instead of stopping the battle. Match
    -- the Esc rule below: while the RTS session owns the screen, Pause stops
    -- time here and never reaches the engine. Alt+Pause still falls through so
    -- the player can reach Options / Controls / Restart / Abort.
    -- Read the Pause control through a guard: this runs at the top of the hook,
    -- before the rest of the file's controls.* reads, so a missing controls
    -- table here would throw on every key press rather than on one binding.
    local pauseControl=(type(controls)=="table" and controls.Pause) or "__no_pause_control__"
    if (rawEarly=="Pause" or rawEarly=="Break" or rawEarly==pauseControl) and not string.find(key,"Alt",1,true) then
        if not self.PostBattleActive and not self.SetupActive and not self.CinematicActive then self:TogglePause(); return end
    end
    if rawEarly=="Esc" or rawEarly=="Escape" then
        -- Esc drives the mod's own pause. ShouldOverrideKey lets it through to
        -- the native menu while paused, so the player can still reach
        -- Options / Controls / Restart / Abort from there.
        if not self.PostBattleActive and not self.SetupActive and not self.CinematicActive then self:TogglePause() end
        return
    end
    if self.CinematicActive then
        local cfg=self.Config.Cinematic or {}
        if cfg.RestartShotKey~=nil and rawEarly==cfg.RestartShotKey then self:CinematicRestartShot(); return end
        if cfg.NextShotKey~=nil and rawEarly==cfg.NextShotKey then self:CinematicNextShot(1); return end
        if cfg.PreviousShotKey~=nil and rawEarly==cfg.PreviousShotKey then self:CinematicNextShot(-1); return end
        if cfg.AllowSkip~=false and cfg.SkipOnAnyInput~=false then self:EndIntroCinematic(true) end
        return
    end
    if self.PostBattleActive then return end
    if self.SetupActive then return end
    if self.Paused then return end
    if self.BattleCamActive then if rawEarly==((self.Config.HomeworldControls or {}).Cinematic or "C") then if string.find(key,"Shift",1,true) then self:ToggleFreeCam() else self:StopBattleCam() end end; return end
    if key==self.Config.Pilot.ToggleKey then self:TogglePilotMode(); return end
    if self.PossessedSignature~=nil then
        if self.PilotTurretGroups and #self.PilotTurretGroups>1 and rawEarly==self.Config.Pilot.TurretGroupPreviousKey then self:CyclePilotTurretGroup(-1)
        elseif self.PilotTurretGroups and #self.PilotTurretGroups>1 and rawEarly==self.Config.Pilot.TurretGroupNextKey then self:CyclePilotTurretGroup(1)
        elseif self.PilotTurretGroups and #self.PilotTurretGroups>1 and rawEarly==self.Config.Pilot.TurretGroupToggleKey then self:TogglePilotTurretGroup()
        elseif self.PilotTurretGroups and #self.PilotTurretGroups>0 and rawEarly==self.Config.Pilot.TurretSubsystemKey then self:TogglePilotTargetSubsystem()
        elseif self.PilotTurretGroups and #self.PilotTurretGroups>0 and rawEarly==self.Config.Pilot.TurretSubsystemPreviousKey then self:CyclePilotTargetSubsystem(-1)
        elseif self.PilotTurretGroups and #self.PilotTurretGroups>0 and rawEarly==self.Config.Pilot.TurretSubsystemNextKey then self:CyclePilotTargetSubsystem(1) end
        return
    end
    local lower=string.lower(tostring(key)); if string.find(lower,"shift",1,true) then self.ShiftDown=true end; if string.find(lower,"ctrl",1,true) then self.CtrlDown=true end; if string.find(lower,"alt",1,true) then self.AltDown=true end
    local raw=rawEarly; self.KeyDown[raw]=true; local controls=self.Config.HomeworldControls or {}
    if self.FollowSignature~=nil and (raw==(controls.PanForward or "W") or raw==(controls.PanBackward or "S") or raw==(controls.PanLeft or "A") or raw==(controls.PanRight or "D") or raw=="Up" or raw=="Down" or raw=="Left" or raw=="Right") then self:ExitFollowMode("Tactical camera") end

    local wingIndex=nil
    local wingKeys={controls.Wing1 or "F1",controls.Wing2 or "F2",controls.Wing3 or "F3",controls.Wing4 or "F4"}
    for i,wkey in ipairs(wingKeys) do if raw==wkey then wingIndex=i break end end
    if wingIndex then
        if self.CtrlDown then self:AssignControlGroup(wingIndex) else self:RecallControlGroup(wingIndex) end
        return
    end
    -- Legacy digit aliases: Ctrl+1..9 still assigns a control group.
    local group=string.match(key,"^Ctrl%-(%d)$"); if group then self:AssignControlGroup(tonumber(group)); return end

    -- Digit keys are an absolute speed ladder that doubles per key: 1=1x,
    -- 2=2x, 3=4x, 4=8x, 0=16x. They used to be relative (1 slower / 2 pause /
    -- 3 faster / 4 reset), which made the number on the key unrelated to the
    -- speed you got. Stepping with =/- and the top-bar buttons is unchanged.
    -- Deliberately keyed on the literal digits, NOT on controls.TimeSlower and
    -- friends: those names carry the old relative meaning and FSO resolves
    -- them to their own defaults, so aliasing them made "1" mean 8x. Those
    -- config entries now only drive the top-bar buttons.
    local speedKeys={["1"]=1,["2"]=2,["3"]=4,["4"]=8,["0"]=16}
    local absolute=speedKeys[raw]
    if absolute~=nil then
        self:SetPaused(false)
        self:SetTimeScale(absolute)
        self:SetStatus("Game speed: "..absolute.."x",1.2)
    elseif raw=="=" or raw=="Pad +" then self:StepTimeScale(1)
    elseif self.CtrlDown and (raw=="Space" or raw=="Spacebar") then if self.FollowSignature~=nil then self:ExitFollowMode() end; self:FocusOnSelection()
    elseif raw==(controls.SelectAll or "L") then self:SelectAll()
    elseif raw==(controls.Stop or "R") then self:HoldSelected()
    elseif raw==(controls.Engage or "T") then self:EngageSelected()
    elseif raw=="=" or raw=="Pad +" then self:StepTimeScale(1)
    elseif raw=="-" or raw=="Pad -" then self:StepTimeScale(-1)
    elseif raw==(controls.MuteMusic or "N") then self:ToggleMusicMute()
    elseif raw==(controls.Release or "G") then self:ReleaseSelected()
    elseif raw==(controls.ArmMove or "M") then self:ArmCommand("move")
    elseif raw==(controls.ArmAttack or "K") then self:ArmCommand("attack")
    elseif raw==(controls.Focus or "F") then if self.FollowSignature~=nil then self:ExitFollowMode() end; self:FocusOnSelection()
    elseif raw==(controls.FocusBase or "H") then if self.FollowSignature~=nil then self:ExitFollowMode() end; self:FocusOnBase()
    elseif raw==(controls.Chase or "B") then self:ToggleChaseOnSelection()
    elseif raw==(controls.ZoomFar or "Q") then if self.FollowSignature~=nil then self:ExitFollowMode() end; self.CameraDistance=self.Config.Camera.MaxDistance; self:UpdateCameraTransform()
    elseif raw==(controls.ZoomNear or "E") then if self.FollowSignature~=nil then self:ExitFollowMode() end; self.CameraDistance=self.Config.Camera.MinDistance; self:UpdateCameraTransform()
    elseif raw==(controls.HoldPolicy or "J") then self:SetGlobalPolicy("HOLD")
    elseif raw==(controls.PassivePolicy or "Z") then self:SetGlobalPolicy("RETREAT")
    elseif raw==(controls.DefensivePolicy or "X") then self:SetGlobalPolicy("STANDOFF")
    elseif raw==(controls.AggressivePolicy or "V") then self:SetGlobalPolicy("ENGAGE")
    elseif raw==(controls.Cinematic or "C") then if string.find(key,"Shift",1,true) then self:ToggleFreeCam() else self:ToggleBattleCam() end
    end
end

-- Dedicated chase-mode shortcut. Toggles the follow camera on the ship under the
-- cursor, falling back to the primary selection when the cursor is on empty
-- space, so it is a real key rather than only Alt+double-click.
function RTS:ToggleChaseOnSelection()
    if self.FollowSignature~=nil then self:ExitFollowMode("Tactical camera") return end
    local target=self:GetShipAtScreen(io.getMouseX(),io.getMouseY(),true,true)
    if target==nil then target=self:GetPrimarySelectedShip() end
    if not shipValid(target) then self:SetStatus("Nothing to chase - select a ship first",1.4) return end
    self.Selected={target:getSignature()}; self.PrimarySelectionSignature=target:getSignature()
    self:StartFollowMode(target)
end

function RTS:OnKeyReleased(key,rawKey)
    if not self.Enabled or key==nil then return end
    if self.PossessedSignature~=nil then return end
    local raw=rawKey or key; raw=string.gsub(raw,"^Shift%-",""); raw=string.gsub(raw,"^Ctrl%-",""); raw=string.gsub(raw,"^Alt%-",""); self.KeyDown[raw]=nil; self.FastKeyDown[raw]=nil
    local lower=string.lower(tostring(key)); local rlower=string.lower(tostring(rawKey or ""))
    -- Modifier state is owned by the modifier keys alone. Clearing Shift when a
    -- pan key comes up dropped the slow-pan modifier mid-gesture while the
    -- Shift key was still physically held.
    if string.find(lower,"shift",1,true) or string.find(rlower,"shift",1,true) then self.ShiftDown=false end
    if string.find(lower,"ctrl",1,true) or string.find(rlower,"ctrl",1,true) then self.CtrlDown=false end
    if string.find(lower,"alt",1,true) or string.find(rlower,"alt",1,true) then self.AltDown=false end
end

function RTS:ShouldOverrideKey(key,rawKey)
    if self.Enabled~=true or key==nil then return false end
    local raw=rawKey or key; raw=string.gsub(raw,"^Shift%-",""); raw=string.gsub(raw,"^Ctrl%-",""); raw=string.gsub(raw,"^Alt%-","")
    if self:IsMissionPauseDisabled() and (raw=="Pause" or raw=="Break") and not string.find(key,"Alt",1,true) then return true end
    -- Swallow Esc while the session owns the screen so the native pause menu
    -- cannot flash; while paused it falls through so the player can still use it.
    if raw=="Esc" or raw=="Escape" then return not (self.Paused==true and not self.PostBattleActive) end
    if self.CinematicActive then return true end
    if self.PostBattleActive then return false end
    if self.PossessedSignature~=nil then
        local groups=self.PilotTurretGroups
        return key==self.Config.Pilot.ToggleKey or (groups and #groups>0 and
            (raw==self.Config.Pilot.TurretGroupPreviousKey or raw==self.Config.Pilot.TurretGroupNextKey
             or raw==self.Config.Pilot.TurretGroupToggleKey or raw==self.Config.Pilot.TurretSubsystemKey
             or raw==self.Config.Pilot.TurretSubsystemPreviousKey or raw==self.Config.Pilot.TurretSubsystemNextKey))
    end
    if self.SetupActive then return false end
    if self.BattleCamActive then return true end
    local c=self.Config.HomeworldControls or {}
    local handled={[self.Config.Pilot.ToggleKey]=true,[c.SelectAll or "L"]=true,[c.Stop or "R"]=true,[c.Engage or "T"]=true,[c.Release or "G"]=true,["="]=true,["-"]=true,["Pad +"]=true,["Pad -"]=true,[c.MuteMusic or "N"]=true,[c.ArmMove or "M"]=true,[c.ArmAttack or "K"]=true,[c.Focus or "F"]=true,[c.FocusBase or "H"]=true,[c.Chase or "B"]=true,[c.HoldPolicy or "J"]=true,[c.PanForward or "W"]=true,[c.PanBackward or "S"]=true,[c.PanLeft or "A"]=true,[c.PanRight or "D"]=true,["Up"]=true,["Down"]=true,["Left"]=true,["Right"]=true,[c.ZoomFar or "Q"]=true,[c.ZoomNear or "E"]=true,[c.PassivePolicy or "Z"]=true,[c.DefensivePolicy or "X"]=true,[c.AggressivePolicy or "V"]=true,[c.Cinematic or "C"]=true,[c.TimeSlower or "1"]=true,[c.TimePause or "2"]=true,[c.TimeFaster or "3"]=true,[c.TimeReset or "4"]=true,[c.Wing1 or "F1"]=true,[c.Wing2 or "F2"]=true,[c.Wing3 or "F3"]=true,[c.Wing4 or "F4"]=true}
    if self.CtrlDown and (raw=="Space" or raw=="Spacebar") then return true end
    return handled[raw]==true
end

function RTS:ResetCameraView()
    self.FollowSignature = nil
    self.FollowZoom = 1.0
    gr.setCamera(self.Camera)
    local c = self.Config.Camera
    self.CameraFocus = vec(c.Focus.x, c.Focus.y, c.Focus.z)
    self.CameraDistance = c.Distance
    self.CameraPitch = math.rad(c.PitchDegrees)
    self.CameraYaw = math.rad(c.YawDegrees)
    self:UpdateCameraTransform()
end


function RTS:FocusOnBase()
    if self.FollowSignature ~= nil then self:ExitFollowMode() end
    local base = self:GetCarrier()
    if shipValid(base) then
        self.CameraFocus = copyVec(base.Position)
        self.CameraDistance = math.max(self.Config.Camera.MinDistance, math.min(self.CameraDistance, self.Config.Camera.Distance))
        self:UpdateCameraTransform()
        self:SetStatus("Focused Blue Station", 1.2)
    else
        self:ResetCameraView()
    end
end

function RTS:UpdateCameraInput(dt)
    if self.FollowSignature ~= nil then return end
    local distanceScale=clamp(self.CameraDistance/math.max(1,self.Config.Camera.Distance),.25,5)
    local multiplier=self.ShiftDown and (self.Config.Camera.ShiftSlowMultiplier or .35) or 1
    local speed=self.Config.Camera.PanSpeed*dt*distanceScale*multiplier
    local sinYaw,cosYaw=math.sin(self.CameraYaw),math.cos(self.CameraYaw); local forwardX,forwardZ=sinYaw,cosYaw; local rightX,rightZ=cosYaw,-sinYaw
    local moveForward,moveRight=0,0; local controls=self.Config.HomeworldControls or {}
    if self.KeyDown[controls.PanForward or "W"] or self.KeyDown["Up"] then moveForward=moveForward+1 end
    if self.KeyDown[controls.PanBackward or "S"] or self.KeyDown["Down"] then moveForward=moveForward-1 end
    if self.KeyDown[controls.PanRight or "D"] or self.KeyDown["Right"] then moveRight=moveRight+1 end
    if self.KeyDown[controls.PanLeft or "A"] or self.KeyDown["Left"] then moveRight=moveRight-1 end
    if self.Config.Camera.EdgePanEnabled==true then
        local mx,my=io.getMouseX(),io.getMouseY(); local sw,sh=gr.getScreenWidth(),gr.getScreenHeight(); local edgeX=sw*self.Config.Camera.EdgePanFraction; local edgeY=sh*self.Config.Camera.EdgePanFraction
        if mx<=edgeX then moveRight=moveRight-1 end; if mx>=sw-edgeX then moveRight=moveRight+1 end; if my<=edgeY then moveForward=moveForward+1 end; if my>=sh-edgeY then moveForward=moveForward-1 end
    end
    if moveForward~=0 or moveRight~=0 then self.CameraFocus.x=self.CameraFocus.x+(forwardX*moveForward+rightX*moveRight)*speed; self.CameraFocus.z=self.CameraFocus.z+(forwardZ*moveForward+rightZ*moveRight)*speed; self:UpdateCameraTransform() end
end
