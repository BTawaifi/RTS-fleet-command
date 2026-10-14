-- Faction keys, choices, species and display names.
local _shared = require "fs2rts_factions.common"
local AI_FACTION_ORDER, RTS, shipValid, factionForTeam = _shared.AI_FACTION_ORDER, _shared.RTS, _shared.shipValid, _shared.factionForTeam

function RTS:GetFactionKey(ship)
    if not shipValid(ship) then return nil end
    return factionForTeam(self,ship,ship.Team)
end

function RTS:GetFactionDefinition(key)
    return self.Config.Factions and self.Config.Factions[key] or nil
end

function RTS:IsCommandStation(ship)
    return shipValid(ship) and self.Config.FactionStationByName
        and self.Config.FactionStationByName[ship.Name]~=nil or false
end

function RTS:GetFactionKeys()
    self:RefreshFactionSetup()
    return self.ActiveFactionKeys or self.Config.FactionOrder or AI_FACTION_ORDER
end

function RTS:GetMaxFactionCount()
    -- ponytail: 12 slots although upstream's IFF mask permits more; a 27-team
    -- diagnostic run fell to 0.69x realtime. Raise only after a telemetry-light
    -- max-count match stays at or above realtime on the supported test engine.
    return math.min(12,#(self.Config.FactionOrder or AI_FACTION_ORDER))
end

function RTS:RefreshFactionSetup()
    local refresh=self.ActiveFactionKeys==nil
    if self.SetupFactionCountChoice~=nil and self.SetupFactionCountChoice~=self.SetupFactionCount then refresh=true end
    if self.SetupFactionCountChoice==nil and self.ActiveFactionCount~=nil
        and self.SetupFactionCount~=self.ActiveFactionCount then refresh=true end
    if self.SetupFactionCountChoice==nil and self.ActiveFactionSet and self.SetupOpponents then
        if (self.SetupOpponents.RED==true)~=(self.ActiveFactionSet.RED==true)
            or (self.SetupOpponents.GOLD==true)~=(self.ActiveFactionSet.GOLD==true) then refresh=true end
    end
    if refresh then self:UpdateFactionCount() end
end

function RTS:IsFactionEliminated(kind)
    if kind=="BLUE" then return self.BlueEliminated==true end
    if kind=="RED" then return self.RedEliminated==true end
    if kind=="GOLD" then return self.GoldEliminated==true end
    if self.FactionEliminated and self.FactionEliminated[kind]~=nil then return self.FactionEliminated[kind] end
    return false
end

function RTS:SetFactionEliminated(kind,value)
    self.FactionEliminated=self.FactionEliminated or {}
    self.FactionEliminated[kind]=value==true
    if kind=="BLUE" then self.BlueEliminated=value==true
    elseif kind=="RED" then self.RedEliminated=value==true
    elseif kind=="GOLD" then self.GoldEliminated=value==true end
end

function RTS:GetFactionChoice(kind)
    local chosen=self.FactionSpecies and self.FactionSpecies[kind]
    if chosen==nil then
        local def=self:GetFactionDefinition(kind)
        chosen=def and def.defaultSpecies or "TERRAN"
    end
    return (self.Config.FactionAliases or {})[chosen] or chosen
end

function RTS:GetFactionProfile(kind)
    local choice=self:GetFactionChoice(kind)
    return (self.Config.FactionProfiles or {})[choice] or self.Config.Species[choice]
end

function RTS:GetFactionSpecies(kind)
    local profile=self:GetFactionProfile(kind)
    return profile and profile.species or self:GetFactionChoice(kind)
end

function RTS:SetFactionChoice(kind,species)
    local def=self:GetFactionDefinition(kind)
    species=(self.Config.FactionAliases or {})[species] or species
    if not def or not (self.Config.FactionProfiles or {})[species] and not self.Config.Species[species] and species~="RANDOM" then return false end
    self.FactionSpecies=self.FactionSpecies or {}
    self.FactionSpecies[kind]=species
    self.RosterIndex=nil; self.FactionRosterCache=nil
    if kind=="BLUE" and self.RosterModelWarmup and self.RosterModelWarmup.done then self:BuildProductionCatalog() end
    return true
end

-- Keep the experiment/setup API accepting the original species keys.
function RTS:SetFactionSpecies(kind,species)
    return self:SetFactionChoice(kind,species)
end

function RTS:CycleFactionChoice(kind)
    local choices=self.Config.FactionChoices or {"TERRAN","SHIVAN","VASUDAN","RANDOM"}
    local current=self:GetFactionChoice(kind); local index=1
    for i,value in ipairs(choices) do if value==current then index=i; break end end
    return self:SetFactionChoice(kind,choices[index%#choices+1])
end

function RTS:CycleFactionSpecies(kind)
    local choices={"TERRAN","SHIVAN","VASUDAN","RANDOM"}
    local current=self:GetFactionSpecies(kind)
    local index=1
    for i,value in ipairs(choices) do if value==current then index=i; break end end
    return self:SetFactionSpecies(kind,choices[index%#choices+1])
end

function RTS:ResolveRandomFactionSpecies()
    local species={}
    for _,choice in ipairs(self.Config.FactionChoices or {"TERRAN","SHIVAN","VASUDAN"}) do
        if choice~="RANDOM" then species[#species+1]=choice end
    end
    for _,kind in ipairs(self:GetFactionKeys()) do
        if self:GetFactionChoice(kind)=="RANDOM" then
            self:SetFactionChoice(kind,species[math.random(#species)])
        end
    end
end

function RTS:GetFactionDisplayName(kind)
    local def=self:GetFactionDefinition(kind)
    if not def then return tostring(kind) end
    local race=self:GetFactionProfile(kind)
    return string.upper((race and race.label) or "RANDOM").." // "..(def.short or kind)
end

function RTS:RandomizeFactionColors()
    local indices={}; for index=1,#self.Config.FactionColors do indices[index]=index end
    for index=#indices,2,-1 do local other=math.random(index); indices[index],indices[other]=indices[other],indices[index] end
    self.FactionColorChoices={}
    for index,kind in ipairs(self.Config.FactionOrder) do self.FactionColorChoices[kind]=indices[index] end
    self.FactionColorCache=nil
end
