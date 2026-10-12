-- Faction colours, relations and combatant counts.
local _shared = require "fs2rts_factions.common"
local RTS, shipValid, shipAlive, factionForTeam = _shared.RTS, _shared.shipValid, _shared.shipAlive, _shared.factionForTeam

function RTS:GetFactionColorIndex(kind)
    if not self.FactionColorChoices then self:RandomizeFactionColors() end
    return self.FactionColorChoices[kind]
end

function RTS:SetFactionColor(kind,index)
    if not self:GetFactionDefinition(kind) or type(index)~="number" or index~=math.floor(index) or not self.Config.FactionColors[index] then return false end
    local previous=self:GetFactionColorIndex(kind)
    -- Occupied choices swap; every team keeps a unique color at twelve teams.
    for other,color in pairs(self.FactionColorChoices) do
        if other~=kind and color==index then self.FactionColorChoices[other]=previous; break end
    end
    self.FactionColorChoices[kind]=index; self.FactionColorCache=nil
    self:ApplyFactionVisuals()
    return true
end

function RTS:GetFactionTeamColorName(kind)
    local index=self:GetFactionColorIndex(kind)
    local definition=index and self:GetFactionDefinition(self.Config.FactionOrder[index])
    return definition and definition.teamColor
end

function RTS:GetFactionColor(kind)
    local index=self:GetFactionColorIndex(kind)
    local color=index and self.Config.FactionColors and self.Config.FactionColors[index]
    if color then return color[1],color[2],color[3] end
    return 200,200,200
end

function RTS:GetFactionColorTable(kind)
    self:GetFactionColorIndex(kind)
    self.FactionColorCache=self.FactionColorCache or {}
    local color=self.FactionColorCache[kind]
    if color==nil then
        local r,g,b=self:GetFactionColor(kind)
        color={r,g,b}; self.FactionColorCache[kind]=color
    end
    return color
end

function RTS:GetFactionCommandShip(key)
    local faction=self:GetFactionDefinition(key)
    local station=faction and faction.station and mn.Ships[faction.station]
    return shipValid(station) and station or nil
end

function RTS:AreEnemies(a, b)
    if not shipValid(a) or not shipValid(b) then return false end
    local aTeam,bTeam=a.Team,b.Team
    local withdrawals=self.Withdrawals and next(self.Withdrawals) and self.Withdrawals
    local aw=withdrawals and withdrawals[a:getSignature()]
    local bw=withdrawals and withdrawals[b:getSignature()]
    if aw and aw.inCorridor then aTeam=mn.Teams[self.Config.Factions[aw.faction].team] end
    if bw and bw.inCorridor then bTeam=mn.Teams[self.Config.Factions[bw.faction].team] end
    if aTeam == nil or bTeam == nil or not aTeam:isValid() or not bTeam:isValid() then return false end
    -- FSO IFF data is global and can be extended by another mod. Keep the RTS
    -- faction boundary explicit so a same-faction ship can never become an AI
    -- attack target even if an inherited IFF entry says the teams are hostile.
    if aTeam == bTeam then return false end
    -- Both handles and teams were validated above; re-entering GetFactionKey
    -- repeats the same native validity and Team reads for every AI pair.
    local aFaction,bFaction=factionForTeam(self,a,aTeam),factionForTeam(self,b,bTeam)
    if aFaction ~= nil and aFaction == bFaction then return false end
    return aTeam:attacks(bTeam)
end

function RTS:EnforceCursorState()
    -- Alt-tab / focus changes can make FSO reacquire relative mouse mode and
    -- leave the OS cursor hidden.  RTS mode owns an absolute visible pointer,
    -- while possession owns the captured/hidden mouse.  Reassert the desired
    -- state every frame so focus transitions cannot strand either mode.
    local piloting = self.PossessedSignature ~= nil
    -- The upstream setter calls mouse_flush even for an unchanged value,
    -- clearing held buttons and movement deltas. Only a mode transition needs it.
    if io.MouseControlStatus ~= piloting then io.MouseControlStatus = piloting end
    io.setCursorHidden(piloting or self.CinematicActive == true)
end

function RTS:CountFactionCombatants(key)
    local count = 0
    local station = self:GetFactionCommandShip(key)
    local stationSig = shipValid(station) and station:getSignature() or nil
    self:EachShip(function(ship)
        if shipAlive(ship) and self:GetFactionKey(ship) == key then
            -- Sentries have their own cap and never count against fleet cap.
            if ship:getSignature() ~= stationSig and not self:IsStaticDefense(ship) then count = count + 1 end
        end
    end)
    return count
end
