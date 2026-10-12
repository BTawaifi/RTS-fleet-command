-- Lean auto-start and starting-position probe for frozen RTS match batches.
local RTS = require 'fs2rts'
local SETUP = require 'batch_setup'
local ARRANGEMENT_DEGREES = SETUP.rotation or 0
local started, ended = false, false
local startup=cf.openFile('acceptance-startup.log','w','data')
assert(startup and startup:isValid())
local function mark(message) startup:write(message..'\n'); startup:flush() end
mark('LOADED headless acceptance driver')

-- Headless batches have no cinematic presentation. Its real-frame clock is
-- not an experiment clock; leave normal interactive startup unchanged.
RTS.Config.Cinematic.Enabled = false
RTS.Config.AI.TraceFileEnabled = true
RTS.Config.AI.DetailedUnitTelemetry = SETUP.telemetry~=false
RTS.Config.AI.ExperimentalDamageTelemetry = SETUP.telemetry~=false
-- This driver is for the explicitly modified headless engine, not upstream.
RTS.ResolvedDamageTelemetryAvailable = true
if SETUP.equalEconomy then
    local initialize=RTS.InitializeAIStates
    RTS.InitializeAIStates=function(self,now)
        initialize(self,now)
        for kind,state in pairs(self.AIStates) do
            if kind~='BLUE' then
                state.cp=self.CommandPoints
                state.income=self.ActiveIncomePerSecond
            end
        end
    end
end

local applySpacing = RTS.ApplyConfiguredBaseSpacing
RTS.ApplyConfiguredBaseSpacing = function(self)
    applySpacing(self)
    local angle = math.rad(ARRANGEMENT_DEGREES)
    local c, s = math.cos(angle), math.sin(angle)
    for _, faction in ipairs(self:GetFactionKeys()) do
        local p = self.ScenarioBasePositions[faction]
        if p then
            local rotated = ba.createVector(p.x * c + p.z * s, p.y, -p.x * s + p.z * c)
            self.ScenarioBasePositions[faction] = rotated
            self:RepositionExistingFaction(faction, rotated)
        end
    end
end

local startScenario = RTS.StartScenario
RTS.StartScenario = function(self)
    self.SetupDifficultyIndex = SETUP.difficulty or 2
    self.SetupEconomyIndex = SETUP.economy or 2
    self.SetupBaseDistanceIndex = SETUP.distance or self.Config.Setup.DefaultBaseDistance or 2
    if SETUP.layout then
        local wanted=string.upper(SETUP.layout):gsub('-','_')
        local found=false
        for index,layout in ipairs(self.Config.Setup.BaseLayouts) do
            if layout.id==wanted then self.SetupBaseLayoutIndex=index; found=true; break end
        end
        assert(found,'Unsupported frozen start layout: '..SETUP.layout)
    end
    if SETUP.factions then self.SetupFactionCountChoice=SETUP.factions
    else self.SetupOpponents = {RED = SETUP.red~=false, GOLD = SETUP.gold~=false} end
    if SETUP.mirror then self:SetFactionSpecies('BLUE','SHIVAN'); self:SetFactionSpecies('RED','SHIVAN') end
    self.SetupAutoMode = true
    self:UpdateFactionCount()
    if SETUP.profiles then
        local choices={}; for _,choice in ipairs(self.Config.FactionChoices) do if choice~='RANDOM' then choices[#choices+1]=choice end end
        for index,kind in ipairs(self:GetFactionKeys()) do self:SetFactionChoice(kind,choices[(index-1)%#choices+1]) end
    end
    if SETUP.factionChoices then
        local keys=self:GetFactionKeys()
        assert(#SETUP.factionChoices==#keys,'Frozen faction choice count differs from active slots')
        for index,kind in ipairs(keys) do
            self:SetFactionChoice(kind,SETUP.factionChoices[index])
            assert(self:GetFactionChoice(kind)==SETUP.factionChoices[index],'Frozen faction identity was not admitted')
        end
    end
    if SETUP.blueFaction then self:SetFactionChoice('BLUE',SETUP.blueFaction) end
    if SETUP.redFaction then self:SetFactionChoice('RED',SETUP.redFaction) end
    startScenario(self)
    if self.ScenarioStartTime and not self.SetupActive then
        local positions = {}; local choices={}; local colors={}
        for _, faction in ipairs(self:GetFactionKeys()) do
            local station = self:GetFactionCommandShip(faction)
            if station and station:isValid() then
                local p = station.Position
                positions[faction] = {x = p.x, y = p.y, z = p.z}
                choices[faction]=self:GetFactionChoice(faction)
                colors[faction]=self:GetFactionColorIndex(faction)
            end
        end
        self:EmitAIEvent('ACCEPTANCE_SETUP', {
            difficultyIndex = self.SetupDifficultyIndex,
            economyIndex = self.SetupEconomyIndex,
            distanceIndex = self.SetupBaseDistanceIndex,
            layoutIndex = self.SetupBaseLayoutIndex or 1,
            tierUnlocks = self:GetEscalationProfile().tierUnlocks,
            factionCount = self.SetupFactionCount,
            autoPlayer = self.AutoPlayerMode == true,
            equalEconomy = SETUP.equalEconomy==true,
            arrangementDegrees = ARRANGEMENT_DEGREES,
            stationPositions = positions,
            factionChoices = choices,
            factionColors = colors,
        }, mn.getMissionTime())
    end
end

local onFrame = RTS.OnFrame
RTS.OnFrame = function(self)
    if not started then mark('FRAME setup='..tostring(self.SetupActive)..' cinematic='..tostring(self.CinematicActive)) end
    onFrame(self)
    if not started and self.SetupActive then
        self.CombatTelemetryEnabled = true
        mark('START scenario')
        self:StartScenario()
        started=self.ScenarioStartTime~=nil and not self.SetupActive
        mark('STARTED '..tostring(started))
        if started then self:FlushAITrace(); startup:close() end
    elseif not ended and self.PostBattleActive and not self.StrategicResult then
        -- Personal station loss must not stop the other factions' match.
        self:EmitAIEvent('PLAYER_DEFEAT', {globalResolved=false}, mn.getMissionTime())
        self:ResumePostBattle()
    elseif not ended and self.StrategicResult then
        ended = true
        self:EmitAIEvent('BATTLE_END', {result = self.GameStatus=='VICTORY' and 'BLUE' or tostring(self.GameStatus or 'UNKNOWN'),
            globalResolved=true,victorFaction=self.StrategicResult.victor,reason=self.PostBattleResult},
            mn.getMissionTime())
        self:CloseAITrace()
        local event = ba.GameEvents['GS_EVENT_QUIT_GAME']
        if event ~= nil then ba.postGameEvent(event) end
    end
end

return true
