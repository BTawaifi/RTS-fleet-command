-- Time formatting, announcements, enablement and ship roles.
local _shared = require "fs2rts_factions.common"
local AI_FACTION_ORDER, RTS, clamp, lower, shipValid = _shared.AI_FACTION_ORDER, _shared.RTS, _shared.clamp, _shared.lower, _shared.shipValid

function RTS:FormatTime(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Real seconds for UI timers (status, announcements, double-click, markers).
-- Mission time scales with game speed and stops at pause (speed 0), which made
-- messages vanish at 16x and never expire while paused. OnFrame accumulates
-- ba.getRealFrametime(), and OnFrame keeps running at speed 0.
function RTS:UINow()
    return self.UIClock or 0
end

function RTS:ShowAnnouncement(text, seconds, factionKey)
    self.AnnouncementText = tostring(text or "")
    self.AnnouncementFaction = factionKey
    self.AnnouncementUntil = self:UINow() + (seconds or 5)
end

function RTS:IsFactionEnabled(kind)
    self:RefreshFactionSetup()
    return self.ActiveFactionSet and self.ActiveFactionSet[kind]==true
        or kind=="BLUE" and true
        or self.SetupOpponents~=nil and self.SetupOpponents[kind]==true
end

function RTS:UpdateFactionCount()
    local order=self.Config.FactionOrder or AI_FACTION_ORDER
    local count=tonumber(self.SetupFactionCountChoice)
    local selected={"BLUE"}
    local manualCount=self.SetupFactionCountChoice==nil and self.ActiveFactionCount~=nil
        and self.SetupFactionCount~=self.ActiveFactionCount
    local legacySelection=self.SetupFactionCountChoice==nil and not manualCount
    if count==nil then
        if manualCount then count=self.SetupFactionCount
        else
            for i=2,#order do if self.SetupOpponents and self.SetupOpponents[order[i]] then selected[#selected+1]=order[i] end end
            if #selected==1 then selected[#selected+1]=order[2] end
            count=#selected
        end
    end
    count=math.floor(clamp(count,2,self:GetMaxFactionCount()))
    if not legacySelection then
        selected={}
        for i=1,count do selected[#selected+1]=order[i] end
    end
    self.SetupFactionCount=count
    self.ActiveFactionCount=count
    self.ActiveFactionKeys={}; self.ActiveFactionSet={}; self.FactionKeyByTeam={}
    self.FactionSpecies=self.FactionSpecies or {}
    for index,kind in ipairs(order) do
        local def=self:GetFactionDefinition(kind)
        if def then
            self.FactionKeyByTeam[lower(def.team or "")]=kind
            if self.FactionSpecies[kind]==nil then self.FactionSpecies[kind]=def.defaultSpecies or "TERRAN" end
        end
    end
    for _,kind in ipairs(selected) do self.ActiveFactionKeys[#self.ActiveFactionKeys+1]=kind; self.ActiveFactionSet[kind]=true end
    self.SetupOpponents=self.SetupOpponents or {}
    for index=2,#order do self.SetupOpponents[order[index]]=self.ActiveFactionSet[order[index]]==true end
end

function RTS:GetShipRole(ship)
    if not shipValid(ship) then return "combat" end
    if self:IsStaticDefense(ship) then return "sentry" end
    -- Role depends only on the class (static config + model radius), and this
    -- runs per ship per frame in hover picking and throughout the planner.
    local className = ship.Class.Name
    local cached = self.RoleByClass[className]
    if cached == nil then cached = self:ComputeClassRole(ship); self.RoleByClass[className] = cached end
    return cached
end

function RTS:IsStaticDefense(ship)
    return shipValid(ship) and self.StaticDefenseSignatures ~= nil
        and self.StaticDefenseSignatures[ship:getSignature()] == true
end

function RTS:ComputeClassRole(ship)
    for _, option in ipairs(self.Config.ProductionClasses or {}) do
        if option.class == ship.Class.Name then return option.role or "combat" end
    end
    for _, kind in ipairs(self:GetFactionKeys()) do
        local e = self:GetAIRosterEntry(kind, ship.Class.Name)
        if e ~= nil then return e.role or "combat" end
    end
    local name = string.upper(ship.Class.Name or "")
    if string.find(name, "GTB ", 1, true) or string.find(name, "GVB ", 1, true) or string.find(name, "SB ", 1, true) then return "bomber" end
    local r = ship.Class.Model and ship.Class.Model.Radius or 0
    if r >= 700 then return "capital" end
    return "fighter"
end

function RTS:IsCapitalTarget(ship)
    if not shipValid(ship) then return false end
    if self:IsCommandStation(ship) then return true end
    local role = self:GetShipRole(ship)
    if role == "capital" or role == "heavy" or role == "juggernaut" or role == "escort" then return true end
    local radius = ship.Class.Model and ship.Class.Model.Radius or 0
    return radius >= 220
end

function RTS:FindBomberPriorityTarget(ship)
    if not shipValid(ship) then return nil end
    local stationBest, capitalBest, capitalScore = nil, nil, -1
    self:EachShip(function(other)
        if shipValid(other) and (not self.IsShipWithdrawing or not self:IsShipWithdrawing(ship)) then
            local engageable=self.CanAutoEngage and self:CanAutoEngage(ship,other)
            if not self.CanAutoEngage then engageable=self:AreEnemies(ship,other) end
            if engageable then
            local isStation = self:IsCommandStation(other)
            if isStation then
                if stationBest == nil or other.Position:getDistance(ship.Position) < stationBest.Position:getDistance(ship.Position) then stationBest = other end
            elseif self:IsCapitalTarget(other) then
                local radius = other.Class.Model and other.Class.Model.Radius or 1
                local hull = math.max(1, other.HitpointsMax or 1)
                local score = radius * 4 + math.sqrt(hull) - other.Position:getDistance(ship.Position) * 0.01
                if score > capitalScore then capitalBest, capitalScore = other, score end
            end
            end
        end
    end)
    return stationBest or capitalBest
end

function RTS:EnableFullArsenal(ship)
    if not shipValid(ship) then return end
    -- Retail/FSPort capital beams may exist in the turret loadout but remain
    -- beam-locked unless explicitly freed.  Clear turret locks and free every
    -- beam-capable turret; pcall makes this harmless on non-turret subsystems.
    -- Station and ship creation both pass through this helper so native FSO's
    -- beam locks are cleared for whichever species hull a faction selected.
    for i = 1, #ship do
        local subsystem = ship[i]
        if subsystem ~= nil and subsystem:isValid() then
            pcall(function() subsystem.TurretLocked = false end)
            pcall(function() subsystem.BeamFree = true end)
        end
    end
end

function RTS:AuditShipArsenal(ship)
    if not shipValid(ship) then return end
    local turrets,primaries,secondaries,beams=0,0,0,0; local names={}
    for i=1,#ship do
        local subsystem=ship[i]
        if subsystem~=nil and subsystem:isValid() then
            local p,q=subsystem.PrimaryBanks,subsystem.SecondaryBanks; local pc,sc=0,0; pcall(function() pc=#p end); pcall(function() sc=#q end)
            if pc+sc>0 then turrets=turrets+1 end
            for b=1,pc do local bank=p[b]; if bank and bank:isValid() then primaries=primaries+1; local wc=bank.WeaponClass; if wc and wc:isValid() then names[#names+1]=wc.Name; if wc:isBeam() then beams=beams+1 end end end end
            for b=1,sc do local bank=q[b]; if bank and bank:isValid() then secondaries=secondaries+1; local wc=bank.WeaponClass; if wc and wc:isValid() then names[#names+1]=wc.Name end end end
        end
    end
    self:Log(string.format("ARSENAL %s [%s]: turrets=%d primaryBanks=%d secondaryBanks=%d beamBanks=%d weapons={%s}",ship.Name,ship.Class.Name,turrets,primaries,secondaries,beams,table.concat(names,", ")))
end
