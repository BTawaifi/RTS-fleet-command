-- Lean auto-start and starting-position probe for frozen RTS match batches.
local RTS = require 'fs2rts'
local ARRANGEMENT_DEGREES = 0
local started, ended = false, false

RTS.Config.AI.TraceFileEnabled = true
RTS.Config.AI.DetailedUnitTelemetry = true
RTS.Config.AI.ExperimentalDamageTelemetry = true

local applySpacing = RTS.ApplyConfiguredBaseSpacing
RTS.ApplyConfiguredBaseSpacing = function(self)
    applySpacing(self)
    local angle = math.rad(ARRANGEMENT_DEGREES)
    local c, s = math.cos(angle), math.sin(angle)
    for _, faction in ipairs({'BLUE', 'RED', 'GOLD'}) do
        local p = self.ScenarioBasePositions[faction]
        if p then
            local rotated = ba.createVector(p.x * c + p.z * s, p.y, -p.x * s + p.z * c)
            self.ScenarioBasePositions[faction] = rotated
            if faction ~= 'GOLD' then self:RepositionExistingFaction(faction, rotated) end
        end
    end
end

local startScenario = RTS.StartScenario
RTS.StartScenario = function(self)
    self.SetupDifficultyIndex = 2
    self.SetupEconomyIndex = 2
    self.SetupBaseDistanceIndex = 2
    self.SetupDurationIndex = 1
    self.SetupOpponents = {RED = true, GOLD = true}
    self.SetupAutoMode = true
    self:UpdateFactionCount()
    startScenario(self)
    if self.ScenarioStartTime and not self.SetupActive then
        local positions = {}
        for _, faction in ipairs({'BLUE', 'RED', 'GOLD'}) do
            local station = self:GetFactionCommandShip(faction)
            if station and station:isValid() then
                local p = station.Position
                positions[faction] = {x = p.x, y = p.y, z = p.z}
            end
        end
        self:EmitAIEvent('ACCEPTANCE_SETUP', {
            difficultyIndex = self.SetupDifficultyIndex,
            economyIndex = self.SetupEconomyIndex,
            distanceIndex = self.SetupBaseDistanceIndex,
            durationIndex = self.SetupDurationIndex,
            factionCount = self.SetupFactionCount,
            autoPlayer = self.AutoPlayerMode == true,
            arrangementDegrees = ARRANGEMENT_DEGREES,
            stationPositions = positions,
        }, mn.getMissionTime())
    end
end

local onFrame = RTS.OnFrame
RTS.OnFrame = function(self)
    onFrame(self)
    if not started and self.SetupActive then
        started = true
        self.CombatTelemetryEnabled = true
        self:StartScenario()
    elseif not ended and self.PostBattleActive then
        ended = true
        self:EmitAIEvent('BATTLE_END', {result = tostring(self.BattleVictor or self.GameStatus or 'UNKNOWN')},
            mn.getMissionTime())
        self:CloseAITrace()
        local event = ba.GameEvents['GS_EVENT_QUIT_GAME']
        if event ~= nil then ba.postGameEvent(event) end
    end
end

return true
