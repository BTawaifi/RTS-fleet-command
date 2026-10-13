-- Station tab: panel drawing, hover text and click handling.
local _shared = require "fs2rts_station.common"
local RTS, shipAlive, clamp, vec, TRACKS, cfg, canAutoEngage = _shared.RTS, _shared.shipAlive, _shared.clamp, _shared.vec, _shared.TRACKS, _shared.cfg, _shared.canAutoEngage

-- Highest-value enemy ship near our station, for the AI's strike.
function RTS:FindStrikeTarget(kind, station)
    local ability = self:GetFactionAbilityProfile(kind)
    -- One pass to collect the escort positions, then a flat scan. This was a
    -- nested O(n*m) walk: the inner loop only broke when a friendly was FOUND,
    -- so every "safe" candidate rescanned the whole ship list, and each
    -- iteration called GetFactionKey twice (each of which does teamName, a
    -- tostring and a string.lower). At a full board that is ~50,000 iterations
    -- and ~300,000 string allocations inside a single frame, and it runs twice
    -- per wall second under time compression.
    local escorts = {}
    for _, friendly in ipairs(self:GetShipList()) do
        if shipAlive(friendly) and self:GetFactionKey(friendly) == kind then
            local p = friendly.Position
            escorts[#escorts+1] = {x=p.x, y=p.y, z=p.z}
        end
    end
    local best, bestHull = nil, 0
    local escortsLocal = escorts; local guardRadius = ability.radius
    for _, ship in ipairs(self:GetShipList()) do
        local key = self:GetFactionKey(ship)
        if shipAlive(ship) and key ~= nil and key ~= kind and not self:IsCommandStation(ship)
            and canAutoEngage(self,station,ship)
            and ship.Position:getDistance(station.Position) <= ability.range and ship.HitpointsMax > bestHull then
            local sp = ship.Position; local sx,sy,sz = sp.x,sp.y,sp.z
            local safe = true
            for i=1,#escortsLocal do
                local e = escortsLocal[i]
                local dx=sx-e.x; local dy=sy-e.y; local dz=sz-e.z
                if dx*dx+dy*dy+dz*dz < guardRadius*guardRadius then safe=false; break end
            end
            if safe then best, bestHull = ship, ship.HitpointsMax end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- STATION panel (tab of the production panel)
-- ---------------------------------------------------------------------------
-- Deterministic hit-test order, topmost-first. Both the click handler and the
-- tooltip walked the rect table with pairs(), whose order is undefined in Lua:
-- they returned on the first rect that contained the point, so if any two rects
-- ever overlapped, which one won was arbitrary - and the tooltip could describe
-- a different button than the one the click fired. Reverse draw order (ability
-- is drawn last, so it sits on top) and test that way.
local function orderedButtonKeys(rects)
    local keys = {}
    for key in pairs(rects or {}) do keys[#keys+1] = key end
    table.sort(keys, function(a, b)
        local function rank(k)
            if k == "ability" then return 5 end
            if k:match("^sentry_") then return 4 end
            if k == "sell" then return 3 end
            if k:match("^track_") then return 2 end
            if k == "station" then return 1 end
            return 0
        end
        return rank(a) > rank(b)
    end)
    return keys
end

function RTS:DrawStationPanel(x1, y1, x2, y2)
    local kind = "BLUE"; local now = mn.getMissionTime(); local state = self:GetStationState(kind)
    local station = self:GetFactionCommandShip(kind); local rects = {}
    self.StationButtonRects = rects
    if not shipAlive(station) then gr.setColor(255, 90, 90, 255); gr.drawString(self:GetFactionDisplayName("BLUE").." station destroyed", x1 + 4, y1 + 4); return end
    rects.station = {x1=x1,y1=y1,x2=x2,y2=y1+20}

    local hullPct = math.floor(100 * station.HitpointsLeft / math.max(1, station.HitpointsMax))
    local ceilingPct=math.floor(100*(1-(state.scarHull or 0)/math.max(1,station.HitpointsMax)))
    self:DrawFactionInsignia(kind,x1+4,y1,x1+24,y1+20)
    gr.setColor(200, 225, 235, 255); gr.drawString("HULL " .. hullPct .. "%", x1 + 30, y1 + 2)
    if state.upgrade then
        local up = state.upgrade; local t = clamp((now - up.startTime) / math.max(1, up.finishTime - up.startTime), 0, 1)
        local bx1 = x1 + 118; local bx2 = x2 - 4
        gr.setColor(40, 60, 70, 255); gr.drawRectangle(bx1, y1 + 3, bx2, y1 + 15, true)
        gr.setColor(255, 220, 110, 255); gr.drawRectangle(bx1, y1 + 3, bx1 + (bx2 - bx1) * t, y1 + 15, true)
        gr.setColor(10, 20, 25, 255); gr.drawString(self.Config.Station.Tracks[up.track].label .. " L" .. up.level .. "  " .. math.ceil(up.finishTime - now) .. "s", bx1 + 6, y1 + 3)
    end

    gr.setColor(170,205,215,255); gr.drawString(self:GetFleetServiceSummary(kind)..' | BASE LIMIT '..ceilingPct..'%',x1+4,y1+22,x2-4,y1+40)
    local y = y1 + 44
    for _, track in ipairs(TRACKS) do
        local t = self.Config.Station.Tracks[track]; local level = self:GetUpgradeLevel(kind, track)
        local offer, reason = self:GetUpgradeOffer(kind, track, now)
        local pips = string.rep("#", level) .. string.rep("-", 3 - level)
        local label
        if offer == nil then label = "[" .. pips .. "] " .. t.label .. "  MAX"
        elseif reason == "TIER" then label = "[" .. pips .. "] " .. t.label .. "  L" .. offer.level .. " needs T" .. offer.tier
        else label = "[" .. pips .. "] " .. t.label .. "  L" .. offer.level .. "  " .. offer.cost .. " CP  " .. math.ceil(offer.seconds * (self:GetEscalationProfile().buildTimeScale or 1)) .. "s" end
        local r = { x1 = x1, y1 = y, x2 = x2, y2 = y + 24 }; rects["track_" .. track] = r
        self:DrawButton(r, label, offer ~= nil and reason == nil, false)
        y = y + 26
    end

    local sentries = self:GetSentrySlotCount(kind); local placed=#self:GetFactionSentries(kind)
    local building=sentries-placed
    gr.setColor(200, 225, 235, 255)
    gr.drawString(string.format("SENTRIES %d/%d%s   RANGE %.1f km", placed, self:GetSentryCap(kind), building>0 and (" ("..building.." BUILDING)") or "", self:GetSentryRadius(kind) / 1000), x1 + 4, y + 2, x2-60, y+20)
    local sell = { x1 = x2 - 56, y1 = y - 2, x2 = x2, y2 = y + 18 }; rects.sell = sell
    self:DrawButton(sell, "SELL", true, false)
    y = y + 22
    local options = self:GetSentryOptions(kind)
    local w = math.floor((x2 - x1 - 4) / 2); local bx = x1
    local tier = self:GetCurrentEscalationTier(now)
    for i, option in ipairs(options) do
        -- 44px holds two lines, so the build time wraps to its own row instead of being
        -- dropped. The label reads "name cost CP" then "Ns build", with no dangling "/".
        local r = { x1 = bx, y1 = y, x2 = bx + w, y2 = y + 44 }; rects["sentry_" .. i] = r
        local short = option.class:gsub("^%S+%s", "")
        local armed = self.ArmedCommand == "sentry" and self.ArmedSentryIndex == i
            self:DrawButton(r, option.tier <= tier and (short .. " " .. option.cost .. " CP " .. cfg(self).Sentries.BuildSeconds .. "s build") or (short .. " T" .. option.tier),
            option.tier <= tier and self.CommandPoints >= option.cost and sentries < self:GetSentryCap(kind), armed)
        bx = bx + w + 4
        if i % 2 == 0 then bx=x1; y=y+50 end
    end
    if #options % 2 == 1 then y=y+50 end
    y = y + 4

    -- A missing Ability.BLUE entry used to raise here ("attempt to index local
    -- 'ability'") and again in HandleStationPanelClick and DrawStationTooltip.
    -- DrawStationPanel runs every HUD frame, so this took the whole frame down.
    -- Degrade to an unnamed, free, permanently-unready ability rather than
    -- aborting the render.
    local ability = self:GetFactionAbilityProfile(kind)
    local r = { x1 = x1, y1 = y, x2 = x2, y2 = y + 26 }; rects.ability = r
    local abilityStatus=self:GetAbilityStatus(kind,now)
    local abilityReady=abilityStatus=="READY"
    local abilityLabel=ability.name..": "..abilityStatus
    self:DrawButton(r, abilityLabel, abilityReady, self.ArmedCommand == "strike")
end

-- Hover text for the STATION tab, drawn left of the panel.
function RTS:DrawStationTooltip(panel)
    local mx, my = io.getMouseX(), io.getMouseY(); local lines, title = nil, nil
    for _, key in ipairs(orderedButtonKeys(self.StationButtonRects)) do
        local r = self.StationButtonRects[key]
        if self:PointInside(r, mx, my) then
            local track = key:match("^track_(.+)$")
            if key == "station" then
                title = self:GetFactionDisplayName("BLUE").." STATION"; lines = { "Hover an upgrade to inspect its three levels.",
                    "One upgrade at a time; ship production continues.",
                    "SERVICE sends selected ships to the station's far side.",
                    "A green + on the map marks ships recovering.",
                    tostring(cfg(self).FleetService.Slots).." service slots; capitals use two. Damage pauses work.",
                    "Repair: 0.4% hull/s to 90%; rearm: 4% payload/s.",
                    "Full hull repair costs 35% of ship CP; full ammo 12%.",
                    "Subsystems: 1%/s to 90%; full repair costs 15%.",
                    "Base repairs recover 60% of damage; scars lower BASE LIMIT." }
            elseif track then
                local t = self.Config.Station.Tracks[track]
                -- A missing track definition used to raise on t.label here.
                -- The hover tooltip is drawn every frame the mouse is over the
                -- panel, so this aborted the HUD frame rather than just
                -- skipping one line of help text.
                if t == nil then return end
                title = t.label; lines = {}
                for i = 1, 3 do lines[#lines + 1] = "L" .. i .. " (T" .. (t.tiers[i] or 0) .. ", " .. (t.costs[i] or 0) .. " CP): " .. (t.desc[i] or "") end
            elseif key:match("^sentry_") then
                local option = self:GetSentryOptions("BLUE")[tonumber(key:match("%d+"))]
                if option then
                    -- Report the hull the sentry will actually have.
                    -- CreateSentry sets option.hull and Defenses L2 then applies
                    -- HullBonus on top, so the bare config number understated
                    -- every sentry built after that upgrade.
                    local hull = option.hull
                    local bonus = self:GetUpgradeLevel("BLUE", "defenses") >= 2
                        and (cfg(self).Sentries.HullBonus or 1.5) or 1
                    if bonus ~= 1 then hull = math.floor(hull * bonus) end
                    title = option.class
                    lines = { "Tier " .. option.tier .. "  |  " .. option.cost .. " CP  |  Hull " .. hull .. "  |  build "..cfg(self).Sentries.BuildSeconds.."s",
                        string.upper(option.role).." | "..self:DescribeSentryRange(option),
                        "Click, then left-click inside the station radius.", "Assembly cancels and refunds if enemies reach the site.", "Hold Shift to place several." } end
            elseif key == "ability" then
                -- Read from Station.Ability.BLUE rather than restating the
                -- numbers: the hardcoded 12 km/1200/5 s/900 m had already
                -- drifted from the config, and omitted innerRadius entirely.
                --
                -- The inner radius is the DEADLIEST part of the blast, not a safe
                -- hollow. ship_explode_area_calc_damage applies FULL max_damage
                -- for dist < inner_rad and attenuates to zero at outer_rad
                -- (ship.cpp:9233-9236), which is the opposite of what this
                -- tooltip claimed. A player who trusted it and parked inside
                -- the ring took the full 1200.
                local ability = self:GetFactionAbilityProfile("BLUE")
                title = ability.name
                lines = { "Command L3 ability, " .. (ability.cost or 0) .. " CP, " .. (ability.cooldown or self.Config.Station.Ability.Cooldown or 0) .. "s cooldown." }
                if ability.kind=="strike" then
                    lines[#lines+1]=string.format("Within %.0f km: %d blast damage after %gs.",
                        (ability.range or 0)/1000, ability.damage or 0, ability.delay or 0)
                    lines[#lines+1]=string.format("Full %d damage inside %.0f m, tapering to nothing at %.0f m.",ability.damage or 0, ability.innerRadius or 0, ability.radius or 0)
                    lines[#lines+1]="Refused, cooldown untouched, if no enemy is inside the blast."
                    lines[#lines+1]="Shields and armor apply. FRIENDLY FIRE; keep allies clear."
                elseif ability.kind=="reinforcement" then
                    lines[#lines+1]=(ability.count or 1).." x "..ability.class.." arrive near your station."
                    lines[#lines+1]="Full purchase price; saves build time. Needs all fleet slots."
                    lines[#lines+1]="Failed hulls refund their share; created hulls remain paid."
                else
                    local roles={}; for role in pairs(ability.roles or {fighter=true,bomber=true}) do roles[#roles+1]=role end
                    table.sort(roles)
                    lines[#lines+1]=string.format("+%.0f%% speed for %gs within %.1f km.",(ability.speedMultiplier-1)*100,ability.seconds,ability.radius/1000)
                    lines[#lines+1]="Applies to: "..table.concat(roles,", ")
                    lines[#lines+1]="No eligible ships: no charge or cooldown. Cannot stack."
                end
            elseif key == "sell" then
                title = "SELL SENTRIES"; lines = { "Removes selected sentries for " .. math.floor((self.Config.Station.Sentries.SellRefund or 0.5) * 100) .. "% of their cost." }
            end
        end
    end
    if lines == nil then return end
    local sw,sh=gr.getScreenWidth(),gr.getScreenHeight()
    local w=math.min(470,sw-20)
    local x1=clamp(panel.x1-10-w,10,sw-w-10); local x2=x1+w
    local model = title == self:GetFactionDisplayName("BLUE").." STATION" and self:GetCarrier() or nil
    local lineHeight=math.max(17,self:TextHeight('M')+2)
    local maxLines=math.max(1,math.floor((sh-54-(model and 140 or 0))/lineHeight))
    local wrapped={}
    for _,line in ipairs(lines) do
        if #wrapped>=maxLines then break end
        for _,piece in ipairs(self:WrapTextLinesToWidth(line,w-20,maxLines-#wrapped)) do wrapped[#wrapped+1]=piece end
    end
    local height=34+#wrapped*lineHeight+(model and 140 or 0)
    local y1=clamp(my-20,10,sh-height-10); local y2=y1+height
    gr.setColor(4, 10, 18, 235); gr.drawRectangle(x1, y1, x2, y2, true); gr.setColor(100, 190, 220, 255); gr.drawRectangle(x1, y1, x2, y2, false)
    gr.setColor(235, 245, 250, 255); self:DrawCenteredTextClipped(title, x1 + 10, x2 - 10, y1 + 8)
    gr.setColor(160, 200, 215, 255); for i, line in ipairs(wrapped) do self:DrawCenteredText(line, x1 + 10, x2 - 10, y1 + 28 + (i - 1) * lineHeight) end
    if model then self:DrawRotatingModel(model.Class.Name,x1+165,y2-140,x1+305,y2) end
end

-- Returns true when the click hit the STATION tab.
function RTS:HandleStationPanelClick(x, y)
    for _, key in ipairs(orderedButtonKeys(self.StationButtonRects)) do
        local r = self.StationButtonRects[key]
        if self:PointInside(r, x, y) then
            local track = key:match("^track_(.+)$")
            if track then self:BuyUpgrade("BLUE", track)
            elseif key == "sell" then self:SellSelectedSentries()
        elseif key == "ability" then
            local ability=self:GetFactionAbilityProfile("BLUE")
            local strikeCost=ability.cost or 0
            -- Same rule as the sentry buttons: the drawn state is greyed out
            -- when the strike is unaffordable, so do not arm a target cursor the
            -- player cannot pay for either.
            local status=self:GetAbilityStatus("BLUE",mn.getMissionTime())
            if status=="READY" and ability.kind=="strike" then
                self.ArmedCommand = "strike"; self:SetStatus(ability.name..": left-click a target area (right-click cancels)", 3)
            elseif status=="READY" then
                if self:UseFactionAbility("BLUE") then self:SetStatus(ability.name.." activated",3)
                else self:SetStatus(ability.name.." unavailable",2) end
            elseif status:match("s$") then
                self:SetStatus(ability.name.." recharging: "..status,2)
            elseif status:match("CP$") then
                self:SetStatus("Insufficient command points for "..ability.name.." ("..strikeCost.." needed)",2)
            else
                self:SetStatus(ability.name.." unavailable: "..status,2)
            end
            else
                local index = tonumber(key:match("^sentry_(%d+)$"))
                local option = index and self:GetSentryOptions("BLUE")[index]
                if option then
                    if option.tier > self:GetCurrentEscalationTier() then self:SetStatus("Needs escalation tier " .. option.tier, 2)
                    -- The button is already drawn greyed out for these two cases
                    -- (DrawStationPanel), but the click handler never repeated
                    -- the check, so a click armed a cursor for a placement the
                    -- player cannot pay for and every world click then reported
                    -- the same refusal. Arm only what can actually be placed.
                    elseif self.CommandPoints < option.cost then
                        self:SetStatus("Insufficient command points for " .. option.class .. " (" .. option.cost .. " needed)", 2)
                    elseif self:GetSentrySlotCount("BLUE") >= self:GetSentryCap("BLUE") then
                        self:SetStatus("Sentry cap reached", 2)
                    else
                        self.ArmedCommand = "sentry"; self.ArmedSentryIndex = index
                        self:SetStatus("PLACE " .. option.class .. ": left-click inside the station radius (Shift: keep placing)", 3)
                    end
                end
            end
            return true
        end
    end
    return false
end

-- Executes an armed sentry/strike click at a world position.
function RTS:ExecuteStationArmedCommand(pos)
    local station = self:GetCarrier()
    if not shipAlive(station) then self.ArmedCommand = nil; return end
    if not self:IsFiniteVector(pos) then return end
    pos = vec(pos.x, station.Position.y, pos.z)
    if self.ArmedCommand == "strike" then
        if self:QueueOrbitalStrike("BLUE", pos) then self.ArmedCommand = nil end
    elseif self.ArmedCommand == "sentry" then
        local option = self:GetSentryOptions("BLUE")[self.ArmedSentryIndex or 1]
        -- The command points the cursor was armed against can be spent on
        -- something else while it sits on the map. Disarm rather than
        -- re-issuing a placement that can never succeed, so the next click is a
        -- fresh decision instead of the same refusal.
        if option and self.CommandPoints < option.cost then
            self.ArmedCommand = nil
            self:SetStatus("Not enough command points for " .. option.class .. " - placement cancelled", 2)
            return
        end
        local placed = option and self:PlaceSentry("BLUE", option, pos, false)
        if placed and not self.ShiftDown then self.ArmedCommand = nil end
    end
end
