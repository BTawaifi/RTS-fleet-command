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

local WEAPON_DISPLAY_NAMES={BGreen='Green heavy beam',BBlue='Blue heavy beam',BRed='Red heavy beam',
    TerSlash='Terran slash beam',LTerSlash='Light Terran slash beam',AAAf='Terran anti-fighter beam',
    SAAA='Shivan anti-fighter beam',BVas='Vasudan heavy beam',LRed='Light Shivan beam',
    ['Terran Huge Turret']='Heavy laser',['Terran Turret']='Defense laser'}

function RTS:GetWeaponDisplayName(weapon)
    local name=type(weapon)=='string' and weapon or weapon.Name
    if type(weapon)~='string' then
        local title=weapon.TechTitle
        if type(title)=='string' and title~='' and title~=name then return title end
        local display=tostring(weapon)
        if display~=name and not display:find('^table:') and not display:find('^userdata:') then return display end
    end
    return WEAPON_DISPLAY_NAMES[name] or name
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
    local ellipsis = "..."
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
function RTS:DrawWrappedTextToWidth(text,x,y,width,lineHeight,maxLines)
    local lines=self:WrapTextLinesToWidth(text,width,maxLines)
    for i,line in ipairs(lines) do gr.drawString(line,x,y+(i-1)*lineHeight) end
    return #lines*lineHeight
end

function RTS:TextHeight(text)
    local ok,height=pcall(gr.getStringHeight,tostring(text or "M"))
    return ok and type(height)=="number" and height>0 and height or 16
end

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

function RTS:GetBaseLayoutProfile()
    local list=self.Config.Setup.BaseLayouts or {}
    return list[self.SetupBaseLayoutIndex or 1] or list[1] or {id="CIRCLE",name="CIRCLE",desc="One ring with evenly spaced stations."}
end

function RTS:GetScenarioBasePosition(kind)
    local p = self.ScenarioBasePositions and self.ScenarioBasePositions[kind]
    if p ~= nil then return p end
    if kind == "BLUE" then return vec(-9000,0,0) end
    if kind == "RED" then return vec(9000,0,0) end
    local g=self.Config.ThirdFaction.StationPosition
    return vec(g.x,g.y,g.z)
end

function RTS:GetFactionBattleFacingPoint(kind)
    if not self.ScenarioBaseLayoutId or self.ScenarioBaseLayoutId=='CIRCLE' then return vec(0,0,0) end
    local origin=self.ScenarioBasePositions[kind]
    local best,closest=nil,math.huge
    for _,other in ipairs(self:GetFactionKeys()) do
        local p=self.ScenarioBasePositions[other]
        if other~=kind and origin and p and (self.SetupActive or not self:IsFactionEliminated(other)) then
            local distance=origin:getDistance(p)
            if distance<closest then best,closest=p,distance end
        end
    end
    return best or vec(0,0,0)
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
    local faction=self:GetFactionDefinition(kind)
    local teamKey = faction and faction.team or (kind=="BLUE" and self.Config.FriendlyTeam or self.Config.HostileTeam)
    self:EachShip(function(ship)
        if shipValid(ship) and ship.Name~=self.Config.ObserverShip and teamName(ship)==teamKey then
            ship.Position=vec(ship.Position.x+dx,ship.Position.y+dy,ship.Position.z+dz)
        end
    end)
end

function RTS:ApplyConfiguredBaseSpacing()
    if not self.SetupActive then return false end
    local profile=self:GetBaseDistanceProfile(); local d=profile.distance or 18000
    local keys=self:GetFactionKeys(); local count=#keys
    if count<2 then return false end
    local positions={}; local maxRadius=0
    local layout=self:GetBaseLayoutProfile().id
    if layout=="CIRCLE" and count==2 then
        positions[keys[1]]=vec(-d*.5,0,0); positions[keys[2]]=vec(d*.5,0,0); maxRadius=d*.5
    elseif layout=="CIRCLE" then
        local radius=d/(2*math.sin(math.pi/count))
        local startAngle=-math.pi*.5-math.pi/count
        for index,kind in ipairs(keys) do
            local angle=startAngle+2*math.pi*(index-1)/count
            positions[kind]=vec(radius*math.cos(angle),0,radius*math.sin(angle))
        end
        maxRadius=radius
    else
        local cx,cz=0,0
        local clusters=count>=9 and 3 or 2
        for index,kind in ipairs(keys) do
            local x,z
            if layout=="MULTI_CIRCLE" then
                local cluster=(index-1)%clusters
                local size=math.floor((count-1-cluster)/clusters)+1
                local localIndex=math.floor((index-1)/clusters)
                local centerAngle=math.pi+2*math.pi*cluster/clusters
                local angle=-math.pi*.5+2*math.pi*localIndex/size
                local radius=size>1 and 1 or 0
                x=3*math.cos(centerAngle)+radius*math.cos(angle)
                z=3*math.sin(centerAngle)+radius*math.sin(angle)
            else
                local angle=-math.pi*.5-math.pi/count+2*math.pi*(index-1)/count
                local radius=index%2==1 and 1 or .5
                x=radius*math.cos(angle); z=radius*math.sin(angle)
            end
            positions[kind]=vec(x,0,z); cx=cx+x/count; cz=cz+z/count
        end
        local nearest=math.huge
        for i=1,count do for j=i+1,count do nearest=math.min(nearest,positions[keys[i]]:getDistance(positions[keys[j]])) end end
        -- Different shapes retain the chosen minimum separation, not an arbitrary radius.
        local scale=d/nearest
        for _,kind in ipairs(keys) do
            local p=positions[kind]; p=vec((p.x-cx)*scale,0,(p.z-cz)*scale); positions[kind]=p
            maxRadius=math.max(maxRadius,p:getDistance(vec(0,0,0)))
        end
    end
    self.ScenarioBasePositions=positions
    self.ScenarioBaseLayoutId=layout
    self.ScenarioMapHalfExtent=math.max(self.Config.TacticalMap.HalfExtent or 15000,maxRadius+math.max(10000,d*.65))
    for _,kind in ipairs(self:GetFactionKeys()) do self:RepositionExistingFaction(kind,positions[kind]) end
    self.CameraDistance=math.max(self.CameraDistance or self.Config.Camera.Distance,maxRadius*1.7)
    self.CameraDistance=math.min(self.CameraDistance,self.Config.Camera.MaxDistance)
    self.CameraFocus=vec(0,0,0); self:UpdateCameraTransform()
end

function RTS:OpenPostBattle(resultText)
    if self.PostBattleActive then return end
    self.FreeCamActive=false
    self:StopBattleCam()
    self.PostBattleActive=true
    self.PostBattleResult=resultText or "BATTLE COMPLETE"
    if self.StrategicResult then self:EmitAIFinalBalance(self.StrategicResult.victor,mn.getMissionTime()) end
    if self.PossessedSignature~=nil then self:ExitPilotMode(nil,false) end
    if self.FollowSignature~=nil then self:ExitFollowMode(nil) end
    self.Selected={}
    -- allowZero is REQUIRED here. SetTimeScale replaces a zero with
    -- LastNonZeroTimeScale unless it is told the zero is intentional, so the
    -- old call here stopped the mod's own systems (OnFrame returns early on
    -- PostBattleActive) and left the ENGINE clock running: ships kept flying
    -- and weapons kept firing behind the result overlay. SetPaused is not used
    -- because the result overlay owns this stop separately from gameplay pause.
    self:SetTimeScale(0,true)
end

function RTS:ResumePostBattle()
    if not self.PostBattleActive or self.FleetFateFinal then return false end
    self.AftermathResultStatus=self.GameStatus; self.AftermathResultText=self.PostBattleResult
    self.AftermathStationCount=#self:GetLivingFactionKeys()
    self.PostBattleActive=false; self.GameStatus='ACTIVE'; self.Paused=false
    self:ClearInputGestures()
    self.ArmedSentryIndex=nil; self.ArmedCommand=nil
    self.NextSurvivorCombat=0
    self:SetTimeScale(1)
    self:SetStatus(self.AftermathActive and 'AFTERMATH // No construction, income, abilities or refitting'
        or 'BATTLE CONTINUES // Surviving stations retain their economies',8)
    self:EmitAIEvent('BATTLE_RESUMED',{stationsRemaining=self.AftermathStationCount},mn.getMissionTime())
    return true
end

function RTS:OpenSurvivorReport()
    if (not self.AftermathActive and not self.PlayerDefeatShown) or self.PostBattleActive then return end
    self.GameStatus=self.StrategicResult and self.AftermathResultStatus or 'DEFEAT'
    self.BattleSummary=self:BuildBattleSummary()
    self:OpenPostBattle(self.StrategicResult and self.AftermathResultText or 'YOUR STATION WAS LOST // GLOBAL BATTLE UNRESOLVED')
end

function RTS:RestartMission()
    self:SetTimeScale(1)
    local ok, ev = pcall(function() return ba.GameEvents["GS_EVENT_START_GAME"] end)
    if ok and ev ~= nil then
        local posted, result = pcall(function() return ba.postGameEvent(ev) end)
        if not posted or result == false then self:SetStatus("Restart failed - use Esc > Restart", 4)
        else
            -- State End runs after native mission teardown; release this world's handles while it is still live.
            self:Shutdown()
        end
    else self:SetStatus("Restart unavailable - use Esc > Restart", 4) end
end

function RTS:OpenExitMenu()
    if self.ExitMenuActive then return end
    if self.Paused then self:SetPaused(false) end
    self.ExitMenuResumeScale=self.TimeScale>0 and self.TimeScale or 1
    self.ExitMenuActive=true; self.EnvironmentPicker=false
    self:ClearInputGestures(); self:SetTimeScale(0,true)
end

function RTS:HandleExitMenuAction(action)
    if not self.ExitMenuActive or (action~='resume' and action~='restart' and action~='quit') then return false end
    self.ExitMenuActive=false; self:ClearInputGestures()
    self:SetTimeScale(self.ExitMenuResumeScale or 1); self.ExitMenuResumeScale=nil
    if action=='restart' then self:RestartMission()
    elseif action=='quit' then self:ExitMissionToMenu() end
    return true
end

function RTS:ExitMissionToMenu()
    self:EmitAIEvent('OBSERVATION_ENDED',{strategicVictor=self.StrategicResult and self.StrategicResult.victor or 'UNRESOLVED'},mn.getMissionTime())
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
            if id=="resume" then self:ResumePostBattle() elseif id=="restart" then self:RestartMission() elseif id=="exit" then self:ExitMissionToMenu()
            elseif id=='withdraw' then self:WithdrawPlayerFleet()
            elseif id=='prev' then self.ReportOffset=math.max(0,(self.ReportOffset or 0)-5)
            elseif id=='next' then self.ReportOffset=(self.ReportOffset or 0)+5
            elseif id:sub(1,5)=='page_' then self.ReportPage=id:sub(6); self.ReportOffset=0
            elseif id:sub(1,8)=='history_' then self.HistoryDetail=id:sub(9) end
            return true
        end
    end
    return false
end

function RTS:GetHoverOrderTarget(ship)
    if not shipValid(ship) or not self:IsFriendly(ship) then return nil,nil end
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
    if not self:IsFriendly(ship) then return "ENEMY CONTACT" end
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
    if not shipValid(ship) or not self:IsFriendly(ship) then return nil end
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
    local m=self:GetUIMetrics(sw,sh)
    local width=math.min(m.pad(440),math.max(180,sw-16))
    local friendly=self:IsFriendly(ship)
    local lh=math.max(m.lineHeight,self:TextHeight("M")+3)
    -- The action label is the longest string on the card. It wraps to a second row
    -- instead of being cut ("PRIMARY ...") and the rows below move down with it.
    local actionLines=friendly and self:WrapTextLinesToWidth("ACTION: "..self:GetHoverActionLabel(ship),width-18,2) or {}
    local extra=math.max(0,#actionLines-1)*lh
    local height=16+lh*(friendly and 9 or 3)+extra
    -- Keep clear of the right-hand column: the station upgrade and sentry buttons
    -- it describes were hidden behind the card.
    local columnLeft=sw-m.margin-m.rightPanelWidth-m.gap
    local x=clamp(mouseX+18,8,math.max(8,math.min(sw-width-8,columnLeft-width)))
    local y=clamp(mouseY+18,48,math.max(48,sh-height-8))
    gr.setColor(3,10,17,232); gr.drawRectangle(x,y,x+width,y+height,true)
    gr.setColor(85,210,235,245); gr.drawRectangle(x,y,x+width,y+height,false)
    gr.setColor(115,235,255,255); self:DrawTextLine(ship.Name or "SHIP",x+9,y+7,width-18)
    gr.setColor(200,220,235,255)
    self:DrawTextLine((ship.Class and ship.Class.Name or "UNKNOWN").." | "..self:GetFactionDisplayName(self:GetFactionKey(ship)).." | "..string.upper(self:GetShipRole(ship)),x+9,y+7+lh,width-18)
    if not friendly then
        local hp=ship.HitpointsMax>0 and clamp(ship.HitpointsLeft/ship.HitpointsMax*100,0,100) or 0
        local max=ship.Shields.CombinedMax or 0
        local shields=max>0 and clamp((ship.Shields.CombinedLeft or 0)/max*100,0,100) or 0
        self:DrawTextLine(string.format("Hull %.0f%% | Shields %.0f%%",hp,shields),x+9,y+7+2*lh,width-18)
        return
    end
    gr.setColor(240,245,250,255)
    -- Row 2 is the ACTION row (row 0 is the name, row 1 the class line).
    for i,line in ipairs(actionLines) do gr.drawString(line,x+9,y+7+(2+i-1)*lh) end
    if shipValid(target) then
        gr.setColor(255,220,125,255)
        self:DrawTextLine("TARGET: "..tostring(target.Name or "OBJECT"),x+9,(y+7+extra+3*lh),width-18)
    else
        gr.setColor(175,195,205,255); self:DrawTextLine("TARGET: none",x+9,(y+7+extra+3*lh),width-18)
    end
    if courseSeconds~=nil then
        gr.setColor(85,235,255,255)
        -- courseSeconds is the horizon of the drawn line at current speed, not an ETA.
        self:DrawTextLine(string.format("COURSE: straight line, %.1fs ahead",courseSeconds),x+9,(y+7+extra+4*lh),width-18)
    else
        gr.setColor(175,195,205,255); self:DrawTextLine("COURSE: stationary",x+9,(y+7+extra+4*lh),width-18)
    end
    local ranges=self:GetShipWeaponRanges(ship)
    gr.setColor(80,220,255,255)
    self:DrawTextLine(string.format("PRIMARY: %dm",ranges.primary),x+9,(y+7+extra+5*lh),width-18)
    gr.setColor(255,190,75,255)
    self:DrawTextLine(string.format("SECONDARY: %dm",ranges.secondary),x+9,(y+7+extra+6*lh),width-18)
    gr.setColor(205,140,255,255)
    self:DrawTextLine(string.format("BEAM: %dm",ranges.beam),x+9,(y+7+extra+7*lh),width-18)
    gr.setColor(175,195,205,255)
    self:DrawTextLine("Max loaded reach; arcs/target limits apply",x+9,(y+7+extra+8*lh),width-18)
end

function RTS:DrawCurrentHoverReadout()
    local hover=self.HoverReadout
    -- While placing a sentry the placement readout is the only cursor text that
    -- matters; a ship card under the cursor covered it.
    if self.ArmedCommand=="sentry" then return end
    if hover~=nil and shipValid(hover.ship) then
        self:DrawHoverReadout(hover.ship,hover.mouseX,hover.mouseY,hover.target,hover.courseSeconds)
    end
end
