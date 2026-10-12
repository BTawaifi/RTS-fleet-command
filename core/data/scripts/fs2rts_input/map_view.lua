-- Tactical map view state, UI metrics and map geometry.
local _shared = require "fs2rts_input.common"
local RTS, clamp, vec = _shared.RTS, _shared.clamp, _shared.vec

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
    m.panelPadding = m.pad(12)
    m.buttonPadding = m.pad(8)
    m.sectionGap = m.pad(8)
    m.margin = m.pad(ui.Margin or 14)
    m.gap = m.pad(ui.RightPanelGap or 12)
    m.topBarHeight = m.pad(44)
    m.rightPanelWidth = m.pad(ui.RightPanelWidth or 410)
    m.selectionWidth = m.pad(ui.SelectionWidth or 410)
    m.selectionHeight = m.pad(ui.SelectionHeight or 330)
    m.policyHeight = m.pad(ui.PolicyHeight or 196)
    m.optionsHeight = math.max(m.pad(ui.OptionsHeight or 48),2*m.lineHeight+m.pad(40))
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
    m.mapButtonWidths = { pop = m.pad(64), fit = m.pad(36), zoomOut = m.pad(24), zoomIn = m.pad(24) }
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
        v={zoom=1,cx=0,cz=0,popped=false,alpha=0.75,shapes=true,
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

function RTS:GetBattleMapHalfExtent()
    local profile=self:GetBaseDistanceProfile(); local d=profile and profile.distance or 18000
    return math.max(self.Config.TacticalMap.HalfExtent or 15000,d*0.72+2000,self.ScenarioMapHalfExtent or 0)
end

function RTS:GetTacticalMapHalfExtent()
    return math.max(self:GetBattleMapHalfExtent(),self.ExtractionExtent or 0)
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
