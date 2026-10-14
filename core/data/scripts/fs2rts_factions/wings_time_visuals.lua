-- Logical wings, time scale, faction ship control and visuals.
local _shared = require "fs2rts_factions.common"
local RTS, shipValid, tableContainsSignature, clamp = _shared.RTS, _shared.shipValid, _shared.tableContainsSignature, _shared.clamp

function RTS:RegisterLogicalWing(ships, label)
    if ships == nil or #ships == 0 then return nil end
    self.WingSerial = (self.WingSerial or 0) + 1
    local id = "W"..tostring(self.WingSerial)
    local wing = {id=id, label=label or id, signatures={}}
    self.RTSWings[id] = wing
    for _,ship in ipairs(ships) do
        if shipValid(ship) and not self:IsCommandStation(ship) and ship.Name~=self.Config.ObserverShip then
            local sig=ship:getSignature(); wing.signatures[#wing.signatures+1]=sig; self.WingBySignature[sig]=id
        end
    end
    if #wing.signatures==0 then self.RTSWings[id]=nil; return nil end
    if self.RecordWingHistory then self:RecordWingHistory(wing) end
    return wing
end

function RTS:GetLogicalWing(ship)
    if not shipValid(ship) then return nil end
    local id=self.WingBySignature[ship:getSignature()]
    return id and self.RTSWings[id] or nil
end

function RTS:SelectLogicalWing(ship, additive)
    local wing=self:GetLogicalWing(ship)
    if wing == nil then return false end
    local result=additive and self.Selected or {}
    for _,sig in ipairs(wing.signatures) do
        if self:FindShipBySignature(sig) ~= nil and not tableContainsSignature(result,sig) then result[#result+1]=sig end
    end
    self.Selected=result
    return true
end

-- allowZero is set only by the mod's own pause, which is the single caller
-- allowed to stop the engine clock. It has to bypass the mission-pause guard
-- below as well, otherwise the guard re-raises 0 to LastNonZeroTimeScale and
-- the pause silently does nothing.
function RTS:SetTimeScale(scale, allowZero)
    scale = tonumber(scale) or 1
    if scale < 0 then scale = 0 end
    if scale > 16 then scale = 16 end
    if scale <= 0 and not allowZero then scale = self.LastNonZeroTimeScale or 1 end
    self.TimeScale = scale
    if scale > 0 then self.LastNonZeroTimeScale = scale end
    local percent = math.floor(scale * 100 + 0.5)
    mn.runSEXP("(set-time-compression "..tostring(percent).." 0)")
end

-- Same steps as the top-bar speed buttons. From pause, steps from the last speed.
local TIME_SCALE_STEPS = {0.5, 1, 2, 4, 8, 16}

function RTS:StepTimeScale(delta)
    local current = (self.TimeScale or 1) > 0 and self.TimeScale or (self.LastNonZeroTimeScale or 1)
    local index = 1
    for i, step in ipairs(TIME_SCALE_STEPS) do if step <= current then index = i end end
    index = clamp(index + delta, 1, #TIME_SCALE_STEPS)
    if self.Paused then
        self.PausedTimeScale=TIME_SCALE_STEPS[index]
        self.LastNonZeroTimeScale=TIME_SCALE_STEPS[index]
    else self:SetTimeScale(TIME_SCALE_STEPS[index]) end
    self:SetStatus("Game speed: " .. TIME_SCALE_STEPS[index] .. "x", 1.2)
end

-- The mod owns its own pause: it stops the engine clock and gates every sim
-- update in OnFrame. Space toggles RTS pause; Escape opens the exit menu or
-- resumes and leaves possession.
function RTS:SetPaused(paused)
    paused = paused == true
    if self.Paused == paused then return end
    self.Paused = paused
    if paused then
        local observer=self.PossessedSignature and self:GetObserver()
        if shipValid(observer) then observer:setFlag(true,'secondaries-locked') end
        self.PausedTimeScale = self.TimeScale
        self:SetTimeScale(0, true)
    else
        self:SetTimeScale(self.PausedTimeScale or self.LastNonZeroTimeScale or 1, true)
        self.PausedTimeScale = nil
    end
    self:SetStatus(paused and (self.PossessedSignature and "PAUSED // Pause resumes // Esc returns to RTS"
        or "PAUSED // Space resumes // Esc opens exit menu") or "RESUMED", 2)
end

function RTS:TogglePause()
    self:SetPaused(not self.Paused)
end

function RTS:DisableFactionShips(kind)
    -- ship:vanish() instead of building a (ship-vanish "name") SEXP: names are
    -- not escaped there, so a quote in a ship name broke the call.
    local ships={}
    self:EachShip(function(ship) if self:GetFactionKey(ship)==kind then ships[#ships+1]=ship end end)
    for _,ship in ipairs(ships) do if shipValid(ship) then ship:vanish() end end
end

function RTS:ApplyFactionVisual(ship,kind)
    if not shipValid(ship) then return false end
    local def=self:GetFactionDefinition(kind)
    local colors=tb and tb.TeamColors
    local name=def and self:GetFactionTeamColorName(kind)
    local tc=colors and name and colors[name]
    if tc and tc:isValid() then
        ship.TeamColor=tc
        local r,g,b=self:GetFactionColor(kind)
        -- Upstream teamcolor components are read-only. Select matching paint
        -- presets and override each contact's native HUD IFF color separately.
        mn.runSEXP(string.format('(change-iff-color "%s" "%s" %d %d %d "%s")',self.Config.Factions.BLUE.team,ship.Team.Name,r,g,b,ship.Name))
        return true
    end
    return false
end

function RTS:ApplyFactionVisuals()
    self:EachShip(function(ship)
        local kind=self:GetFactionKey(ship)
        if kind then self:ApplyFactionVisual(ship,kind) end
    end)
end
