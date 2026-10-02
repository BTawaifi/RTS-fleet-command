-- Text drawing, base spacing, post-battle screen, hover readouts.
local Config = require "fs2rts_config"
local U = require "fs2rts_util"
local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys
local RTS = require "fs2rts_state"
local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

function RTS:Log(message)
    ba.print("[FS2RTS] " .. tostring(message) .. "\n")
end

-- Measured text width. FSO's default UI font is a proportional face
-- (font01.vf, loaded in code/graphics/software/font.cpp:246) and gr.getStringWidth
-- is the engine's own measurement for it (code/scripting/api/libs/graphics.cpp:1557).
-- Any layout that guesses a width per CHARACTER is wrong for this font, which
-- is why every horizontal budget in the HUD goes through here. The pcall keeps
-- the headless doubles usable: a test double that does not implement
-- getStringWidth falls back to the old character estimate instead of erroring.
function RTS:TextWidth(text)
    text = tostring(text or "")
    local ok, width = pcall(gr.getStringWidth, text)
    if ok and type(width) == "number" and width > 0 then return width end
    return #text * (self.UIMetrics and self.UIMetrics.charWidth or 8)
end

-- Cut a string to a PIXEL budget rather than a character count. Proportional
-- glyphs make the character count a fiction, and the old character-based
-- truncate() visibly cut long labels short or let them run past their pane.
function RTS:TruncateToWidth(text, maxWidth)
    text = tostring(text or "")
    maxWidth = math.floor(tonumber(maxWidth) or 0)
    if maxWidth <= 0 then return "" end
    if self:TextWidth(text) <= maxWidth then return text end
    local ellipsis = "."
    local lo, hi = 0, #text
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if self:TextWidth(string.sub(text, 1, mid) .. ellipsis) <= maxWidth then lo = mid else hi = mid - 1 end
    end
    if lo <= 0 then return "" end
    return string.sub(text, 1, lo) .. ellipsis
end

-- Wrap to a pixel budget, splitting on whitespace and hard-splitting words
-- that are wider than the column. maxLines is honoured by dropping the rest,
-- which is the same contract the character-based wrapper has always had.
function RTS:WrapTextLinesToWidth(text, maxWidth, maxLines)
    text = tostring(text or "")
    maxWidth = math.floor(tonumber(maxWidth) or 0)
    maxLines = math.max(1, math.floor(tonumber(maxLines) or 4))
    if maxWidth <= 0 then return {} end
    local lines = {}
    local current = ""
    local function push(line)
        if line ~= "" and #lines < maxLines then lines[#lines + 1] = line end
    end
    for word in string.gmatch(text, "%S+") do
        while self:TextWidth(word) > maxWidth and #lines < maxLines do
            if current ~= "" then push(current); current = "" end
            if #lines >= maxLines then break end
            local lo, hi = 0, #word
            while lo < hi do
                local mid = math.floor((lo + hi + 1) / 2)
                if self:TextWidth(string.sub(word, 1, mid)) <= maxWidth then lo = mid else hi = mid - 1 end
            end
            if lo <= 0 then lo = 1 end
            push(string.sub(word, 1, lo))
            word = string.sub(word, lo + 1)
        end
        if #lines >= maxLines then break end
        if word ~= "" then
            local candidate = current == "" and word or (current .. " " .. word)
            if self:TextWidth(candidate) > maxWidth and current ~= "" then
                push(current)
                current = word
            else
                current = candidate
            end
        end
    end
    if #lines < maxLines and current ~= "" then push(current) end
    return lines
end

-- Wrapping is pure, and the HUD re-wraps the same button labels every single
-- frame, so the result is memoised. The cache is keyed on the exact arguments
-- and bounded; a bounded cache is enough because the hot set is the handful of
-- labels on screen, not a growing stream of unique strings.
local WRAP_CACHE = {}
local WRAP_CACHE_SIZE = 0
local WRAP_CACHE_MAX = 512

function RTS:WrapTextLines(text, maxChars, maxLines)
    local key = tostring(text) .. "\1" .. tostring(maxChars) .. "\1" .. tostring(maxLines)
    local cached = WRAP_CACHE[key]
    if cached ~= nil then return cached end
    text = tostring(text or "")
    maxChars = math.max(4, math.floor(maxChars or 48))
    maxLines = math.max(1, math.floor(maxLines or 4))
    local lines = {}
    local current = ""

    local function pushLine(line)
        if line ~= "" and #lines < maxLines then lines[#lines + 1] = line end
    end

    for word in string.gmatch(text, "%S+") do
        while #word > maxChars and #lines < maxLines do
            if current ~= "" then pushLine(current); current = "" end
            if #lines >= maxLines then break end
            pushLine(string.sub(word, 1, maxChars))
            word = string.sub(word, maxChars + 1)
        end
        if #lines >= maxLines then break end
        if word ~= "" then
            local candidate = current == "" and word or (current .. " " .. word)
            if #candidate > maxChars and current ~= "" then
                pushLine(current)
                current = word
            else
                current = candidate
            end
        end
    end
    if #lines < maxLines and current ~= "" then pushLine(current) end
    if WRAP_CACHE_SIZE >= WRAP_CACHE_MAX then WRAP_CACHE = {}; WRAP_CACHE_SIZE = 0 end
    WRAP_CACHE[key] = lines
    WRAP_CACHE_SIZE = WRAP_CACHE_SIZE + 1
    return lines
end

-- Draw a single line with a guaranteed pixel budget. The three-argument
-- gr.drawString form is used deliberately: the five-argument form makes the
-- engine re-wrap and clip the string (code/scripting/api/libs/graphics.cpp:1467
-- calls str_wrap_to_width, and resizes the line list to (y2-y)/font_height),
-- while the three-argument form hands the string straight to gr_string
-- (graphics.cpp:1434). Wrapping here instead of in the engine means one line of
-- Lua produces exactly one line of glyphs, and nothing is silently reflowed into
-- a neighbour.
function RTS:DrawTextLine(text, x, y, maxWidth)
    text = tostring(text or "")
    if maxWidth ~= nil and maxWidth > 0 then text = self:TruncateToWidth(text, maxWidth) end
    gr.drawString(text, x, y)
end

function RTS:DrawWrappedText(text, x, y, maxChars, lineHeight, maxLines, x2, y2)
    lineHeight = lineHeight or 18
    local lines = self:WrapTextLines(text, maxChars, maxLines)
    for i, line in ipairs(lines) do
        local lineY = y + (i - 1) * lineHeight
        -- FSO drawString accepts either Message[, X1, Y1] or the complete
        -- Message, X1, Y1, X2, Y2 textbox form. Never pass a nil X2 as
        -- argument #4; that is a type error on current FSO builds.
        if x2 ~= nil then
            gr.drawString(line, x, lineY, x2, y2 or (lineY + lineHeight))
        else
            gr.drawString(line, x, lineY)
        end
    end
    return #lines * lineHeight
end


function RTS:DrawCenteredText(text, x1, x2, y, y2)
    text = tostring(text or "")
    local width = self:TextWidth(text)
    local x = math.floor(x1 + math.max(0, (x2 - x1 - width) / 2))
    if y2 ~= nil then gr.drawString(text, x, y, x2, y2) else gr.drawString(text, x, y) end
end

-- Centered and guaranteed to fit the box it is given. Callers that previously
-- passed the full string to a five-argument gr.drawString and let the engine
-- clip it now truncate first, so a long label degrades to a shortened one
-- instead of being re-wrapped over its neighbours.
function RTS:DrawCenteredTextClipped(text, x1, x2, y)
    text = self:TruncateToWidth(tostring(text or ""), (x2 - x1))
    self:DrawCenteredText(text, x1, x2, y)
end

function RTS:DrawCenteredWrappedText(text, x1, x2, y, maxChars, lineHeight, maxLines)
    lineHeight = lineHeight or 18
    local lines = self:WrapTextLines(text, maxChars, maxLines)
    for i, line in ipairs(lines) do
        self:DrawCenteredText(line, x1, x2, y + (i - 1) * lineHeight)
    end
    return #lines * lineHeight
end

-- Pixel-budget variant, for panels whose width is itself derived from the
-- screen. The character-count form cannot be used there: its budget would be a
-- guess about a proportional font.
function RTS:DrawCenteredWrappedTextToWidth(text, x1, x2, y, maxWidth, lineHeight, maxLines)
    lineHeight = lineHeight or 18
    local lines = self:WrapTextLinesToWidth(text, maxWidth, maxLines)
    for i, line in ipairs(lines) do
        self:DrawCenteredText(line, x1, x2, y + (i - 1) * lineHeight)
    end
    return #lines * lineHeight
end


function RTS:GetBaseDistanceProfile()
    local list = self.Config.Setup.BaseDistances or {}
    return list[self.SetupBaseDistanceIndex or 1] or list[1] or {name="STANDARD", distance=18000}
end

function RTS:GetScenarioBasePosition(kind)
    local p = self.ScenarioBasePositions and self.ScenarioBasePositions[kind]
    if p ~= nil then return p end
    if kind == "BLUE" then return vec(-9000,0,0) end
    if kind == "RED" then return vec(9000,0,0) end
    local g=self.Config.ThirdFaction.StationPosition
    return vec(g.x,g.y,g.z)
end

function RTS:RepositionExistingFaction(kind, desired)
    -- This is the only normal RTS path which directly writes ship.Position, and it
    -- is intentionally legal only while the pre-battle setup is active.
    if not self.SetupActive then
        self:Log("BLOCKED direct faction reposition after scenario start: " .. tostring(kind))
        return
    end
    local station=self:GetFactionCommandShip(kind)
    if not shipValid(station) or desired==nil then return end
    local old=copyVec(station.Position)
    local dx,dy,dz=desired.x-old.x,desired.y-old.y,desired.z-old.z
    local teamKey = kind=="BLUE" and self.Config.FriendlyTeam or self.Config.HostileTeam
    self:EachShip(function(ship)
        if shipValid(ship) and ship.Name~=self.Config.ObserverShip and teamName(ship)==teamKey then
            ship.Position=vec(ship.Position.x+dx,ship.Position.y+dy,ship.Position.z+dz)
        end
    end)
end

function RTS:ApplyConfiguredBaseSpacing()
    local profile=self:GetBaseDistanceProfile(); local d=profile.distance or 18000
    local blue,red,gold
    if self.SetupFactionCount >= 3 then
        local h=math.sqrt(3)*0.5*d
        blue=vec(-d*0.5,0,-h/3)
        red=vec(d*0.5,0,-h/3)
        gold=vec(0,0,2*h/3)
    else
        blue=vec(-d*0.5,0,0)
        if self:IsFactionEnabled("RED") then red=vec(d*0.5,0,0) else gold=vec(d*0.5,0,0) end
    end
    self.ScenarioBasePositions={BLUE=blue,RED=red,GOLD=gold}
    self:RepositionExistingFaction("BLUE",blue)
    if red~=nil then self:RepositionExistingFaction("RED",red) end
    self.CameraFocus=vec(0,0,0); self:UpdateCameraTransform()
end

function RTS:OpenPostBattle(resultText)
    if self.PostBattleActive then return end
    self.PostBattleActive=true
    self.PostBattleResult=resultText or "BATTLE COMPLETE"
    self:EmitAIFinalBalance(self.BattleVictor or self.GameStatus or self.PostBattleResult,mn.getMissionTime())
    if self.PossessedSignature~=nil then self:ExitPilotMode(nil,false) end
    if self.FollowSignature~=nil then self:ExitFollowMode(nil) end
    self.Selected={}
    -- allowZero is REQUIRED here. SetTimeScale replaces a zero with
    -- LastNonZeroTimeScale unless it is told the zero is intentional, so the
    -- old call here stopped the mod's own systems (OnFrame returns early on
    -- PostBattleActive) and left the ENGINE clock running: ships kept flying
    -- and weapons kept firing behind the result overlay. SetPaused is not used
    -- because it would leave the Esc key toggling a pause on a screen that has
    -- no resume, and would still be true when RestartMission calls
    -- SetTimeScale(1).
    self:SetTimeScale(0,true)
end

function RTS:RestartMission()
    self:SetTimeScale(1)
    local ok, ev = pcall(function() return ba.GameEvents["GS_EVENT_START_GAME"] end)
    if ok and ev ~= nil then
        local posted, result = pcall(function() return ba.postGameEvent(ev) end)
        if not posted or result == false then self:SetStatus("Restart failed - use Esc > Restart", 4) end
    else self:SetStatus("Restart unavailable - use Esc > Restart", 4) end
end

function RTS:ExitMissionToMenu()
    self:SetTimeScale(1)
    local ok, ev = pcall(function() return ba.GameEvents["GS_EVENT_END_GAME"] end)
    if ok and ev ~= nil then
        local posted, result = pcall(function() return ba.postGameEvent(ev) end)
        if not posted or result == false then self:SetStatus("Exit failed - use Esc > Quit", 4) end
    else self:SetStatus("Exit unavailable - use Esc > Quit", 4) end
end

function RTS:HandlePostBattleClick(x,y)
    for id,rect in pairs(self.PostBattleButtonRects or {}) do
        if self:PointInside(rect,x,y) then
            if id=="restart" then self:RestartMission() elseif id=="exit" then self:ExitMissionToMenu() end
            return true
        end
    end
    return false
end

function RTS:GetHoverOrderTarget(ship)
    if not shipValid(ship) then return nil,nil end
    local sig=ship:getSignature(); local order=self.UserOrders[sig]
    if order and order.targetSignature then
        local t=self:FindShipBySignature(order.targetSignature)
        if shipValid(t) then return t,string.upper(order.kind or "ORDER") end
    end
    local ai=self.AIOrderState[sig]
    if ai and ai.targetSignature then
        local t=self:FindShipBySignature(ai.targetSignature)
        if shipValid(t) then return t,ai.label or "TARGET" end
    end
    local ok,target=pcall(function() return ship.Target end)
    if ok and objectValid(target) then return target,"TARGET" end
    return nil,nil
end

function RTS:GetHoverActionLabel(ship)
    if not shipValid(ship) then return "UNKNOWN" end
    local sig=ship:getSignature()
    local order=self.UserOrders[sig]
    if order~=nil and order.kind~=nil then return "PLAYER ORDER: "..string.upper(tostring(order.kind)) end
    local state=self.AIOrderState[sig]
    if state~=nil then return tostring(state.label or state.mission or "AI ORDER") end
    local ok,target=pcall(function() return ship.Target end)
    if ok and objectValid(target) then return "ENGAGING "..tostring(target.Name or "TARGET") end
    return self:GetShipCommandLabel(ship)
end

function RTS:GetHoverCourseProjection(ship, startX, startY)
    if not shipValid(ship) then return nil end
    local velocity=ship.Physics and ship.Physics.Velocity or nil
    if velocity==nil or not self:IsFiniteVector(velocity) then return nil end
    local speedSquared=velocity.x*velocity.x+velocity.y*velocity.y+velocity.z*velocity.z
    if speedSquared<=1 then return nil end

    -- A longer, screen-space-readable projection is needed for slow capital
    -- hulls. It is deliberately based on current velocity, not a promise that
    -- the ship's AI will hold that heading through future turns.
    local isCapital=self:IsCapitalTarget(ship)
    local seconds=math.max(.1,self.Config.Selection.HoverTrajectorySeconds or 6)
    local maxSeconds=isCapital and math.max(seconds,self.Config.Selection.HoverCapitalTrajectoryMaxSeconds or 90) or seconds
    local minPixels=isCapital and (self.Config.Selection.HoverCapitalTrajectoryMinPixels or 32) or 0
    local projection=nil
    for _=1,12 do
        local ex,ey=(ship.Position+velocity*seconds):getScreenCoords()
        if ex~=false then
            projection={x=ex,y=ey,seconds=seconds}
            local dx,dy=ex-startX,ey-startY
            if not isCapital or dx*dx+dy*dy>=minPixels*minPixels or seconds>=maxSeconds then break end
            local nextSeconds=math.min(seconds*2,maxSeconds)
            if nextSeconds<=seconds then break end
            seconds=nextSeconds
        else
            -- Retain the longest on-screen segment. If the first projection is
            -- off-screen, shorten it until the course can be drawn.
            if projection~=nil then break end
            seconds=seconds*.5
            if seconds<.05 then break end
        end
    end
    return projection
end

function RTS:DrawHoverReadout(ship, mouseX, mouseY, target, courseSeconds)
    local sw,sh=gr.getScreenWidth(),gr.getScreenHeight()
    local width=math.min(440,math.max(180,sw-16))
    local height=100
    local x=clamp(mouseX+18,8,math.max(8,sw-width-8))
    local y=clamp(mouseY+18,48,math.max(48,sh-height-8))
    gr.setColor(3,10,17,232); gr.drawRectangle(x,y,x+width,y+height,true)
    gr.setColor(85,210,235,245); gr.drawRectangle(x,y,x+width,y+height,false)
    gr.setColor(115,235,255,255); gr.drawString(tostring(ship.Name or "SHIP"),x+9,y+7,x+width-9,y+25)
    gr.setColor(240,245,250,255); gr.drawString("ACTION: "..self:GetHoverActionLabel(ship),x+9,y+29,x+width-9,y+47)
    if shipValid(target) then
        gr.setColor(255,220,125,255)
        gr.drawString("TARGET: "..tostring(target.Name or "OBJECT"),x+9,y+51,x+width-9,y+69)
    else
        gr.setColor(175,195,205,255); gr.drawString("TARGET: none",x+9,y+51,x+width-9,y+69)
    end
    if courseSeconds~=nil then
        gr.setColor(85,235,255,255)
        gr.drawString(string.format("COURSE (LINEAR): %.1fs",courseSeconds),x+9,y+73,x+width-9,y+91)
    else
        gr.setColor(175,195,205,255); gr.drawString("COURSE: stationary",x+9,y+73,x+width-9,y+91)
    end
end

function RTS:DrawCurrentHoverReadout()
    local hover=self.HoverReadout
    if hover~=nil and shipValid(hover.ship) then
        self:DrawHoverReadout(hover.ship,hover.mouseX,hover.mouseY,hover.target,hover.courseSeconds)
    end
end
