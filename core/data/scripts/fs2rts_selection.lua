-- Selection, logical wings, control groups, status line.
local Config = require "fs2rts_config"
local U = require "fs2rts_util"
local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys
local RTS = require "fs2rts_state"
local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

function RTS:IsShipOnScreen(ship)
    if not shipValid(ship) then return false end
    local sx, sy = ship.Position:getScreenCoords()
    if sx == false then return false end
    return sx >= 0 and sx <= gr.getScreenWidth() and sy >= 0 and sy <= gr.getScreenHeight()
end


function RTS:GetNextWingCallsign(kind)
    local names={"Alpha","Beta","Gamma","Delta","Epsilon","Zeta","Eta","Theta","Iota","Kappa","Lambda","Mu","Nu","Xi","Omicron","Pi","Rho","Sigma","Tau","Upsilon","Phi","Chi","Psi","Omega"}
    self.WingNameCounters=self.WingNameCounters or {}
    self.WingNameCounters[kind]=(self.WingNameCounters[kind] or 0)+1
    local n=self.WingNameCounters[kind]
    local base=names[((n-1)%#names)+1]
    local cycle=math.floor((n-1)/#names)+1
    if cycle>1 then base=base.."-"..tostring(cycle) end
    return self:GetFactionDisplayName(kind).." "..base
end

function RTS:SelectWingForShip(ship, additive)
    if not shipValid(ship) then return false end
    local logical=self:GetLogicalWing(ship)
    local result=additive and self.Selected or {}
    local added=0
    if logical ~= nil then
        for _,sig in ipairs(logical.signatures) do
            local member=self:FindShipBySignature(sig)
            if self:IsSelectableShip(member) and not tableContainsSignature(result,sig) then result[#result+1]=sig; added=added+1 end
        end
        if added>0 then self.Selected=result; self.PrimarySelectionSignature=ship:getSignature(); self:SetStatus(logical.label.." selected ("..tostring(added)..")",1.5); return true end
    end
    local ok, wing=pcall(function() return ship:getWing() end)
    if ok and wing~=nil then
        local countOk,count=pcall(function() return #wing end)
        if countOk and count and count>0 then
            for i=1,count do
                local member=wing[i]
                if self:IsSelectableShip(member) then local sig=member:getSignature(); if not tableContainsSignature(result,sig) then result[#result+1]=sig; added=added+1 end end
            end
            if added>0 then
                self.Selected=result; self.PrimarySelectionSignature=ship:getSignature()
                local name="Wing"; pcall(function() if wing.Name and wing.Name~="" then name=wing.Name end end)
                self:SetStatus(name.." selected ("..tostring(added)..")",1.5); return true
            end
        end
    end
    self.Selected=additive and result or {ship:getSignature()}; self.PrimarySelectionSignature=ship:getSignature(); return false
end

function RTS:SelectSameClass(reference, allVisibleMap)
    if not shipValid(reference) then return end
    local className = reference.Class and reference.Class.Name or ""
    if className == "" then return end

    local result = self.ShiftDown and self.Selected or {}
    local refFriendly = self:IsFriendly(reference)
    local refEnemy = self:IsPlayerEnemy(reference)
    self:EachShip(function(ship)
        if not self:IsSelectableShip(ship) then return end
        if ship.Class == nil or ship.Class.Name ~= className then return end
        if refFriendly and not self:IsFriendly(ship) then return end
        if refEnemy and not self:IsPlayerEnemy(ship) then return end
        if not allVisibleMap and not self:IsShipOnScreen(ship) then return end
        local sig = ship:getSignature()
        if not tableContainsSignature(result, sig) then result[#result + 1] = sig end
    end)
    self.Selected = result
    self:SetStatus("Selected " .. tostring(#result) .. " " .. className, 1.3)
end

function RTS:HandleDoubleClick(mouseX, mouseY, tacticalMap)
    local now=self:UINow(); local ship
    if tacticalMap then ship=self:GetMapShipAt(mouseX,mouseY) else ship=self:GetShipAtScreen(mouseX,mouseY,true,true) end
    local clickKey=shipValid(ship) and ship:getSignature() or 0
    local cfg=self.Config.Selection; local maxDelay=cfg.DoubleClickSeconds or .32; local maxDist=cfg.DoubleClickMaxDistancePixels or 12
    local isDouble=self.LastLeftClickKey==clickKey and now-self.LastLeftClickTime<=maxDelay and distance2(mouseX,mouseY,self.LastLeftClickX,self.LastLeftClickY)<=maxDist*maxDist
    self.LastLeftClickTime=now; self.LastLeftClickX=mouseX; self.LastLeftClickY=mouseY; self.LastLeftClickKey=clickKey
    if not isDouble or not shipValid(ship) then return false end
    self.LastLeftClickTime=-100; self.LastLeftClickKey=nil
    if shipValid(ship) then
        if self.AltDown then
            if self.FollowSignature==ship:getSignature() then self:ExitFollowMode("Tactical camera")
            else self.Selected={ship:getSignature()}; self.PrimarySelectionSignature=ship:getSignature(); self:StartFollowMode(ship) end
        else
            self:SelectWingForShip(ship,self.ShiftDown)
        end
    end
    return true
end

function RTS:FocusOnSelection()
    local ships = self:GetSelectedShips()
    if #ships == 0 then return end
    if self.BattleCamActive then self:StopBattleCam() end
    self:ExitFollowMode()

    local x, y, z = 0, 0, 0
    for _, ship in ipairs(ships) do
        x = x + ship.Position.x
        y = y + ship.Position.y
        z = z + ship.Position.z
    end
    self.CameraFocus = vec(x / #ships, y / #ships, z / #ships)
    self:UpdateCameraTransform()
end

function RTS:SelectAll()
    self.Selected = {}
    self:EachShip(function(ship)
        -- shipAlive, not just IsFriendly: a hull in its death roll is still a
        -- valid object, so it was being counted, selected, and then silently
        -- dropped when an order was issued to it.
        if self:IsFriendly(ship) and shipAlive(ship) and not self:IsCommandStation(ship) then
            self.Selected[#self.Selected + 1] = ship:getSignature()
        end
    end)
    self.PrimarySelectionSignature=self.Selected[1]
    self:SetStatus("Selected all combat units", 2)
end

function RTS:SelectNewUnitPopup()
    local selected={}
    for _,signature in ipairs(self.NewUnitPopup and self.NewUnitPopup.signatures or {}) do
        local ship=self:FindShipBySignature(signature)
        if shipAlive(ship) and self:IsMovableFriendly(ship) then selected[#selected+1]=signature end
    end
    self.NewUnitPopup=nil
    if #selected==0 then self:SetStatus("NEW UNITS ARE NO LONGER AVAILABLE",2); return end
    self.Selected=selected; self.PrimarySelectionSignature=selected[1]
    self:SetStatus("Selected "..#selected.." newly deployed unit"..(#selected==1 and "" or "s"),2)
end


-- Read-only: drawn every frame. Dead members are pruned by OnShipDeath and
-- RecallControlGroup, so a draw call no longer rewrites the groups.
function RTS:GetControlGroupCount(group)
    local count=0
    for _,sig in ipairs(self.ControlGroups[group] or {}) do if self:IsMovableFriendly(self:FindShipBySignature(sig)) then count=count+1 end end
    return count
end

function RTS:AssignControlGroup(group)
    if group<1 or group>4 then return end
    self.ControlGroups[group]={}
    for _,sig in ipairs(self.Selected) do local ship=self:FindShipBySignature(sig); if self:IsMovableFriendly(ship) then self.ControlGroups[group][#self.ControlGroups[group]+1]=sig end end
    self:SetStatus("Control group "..group.." assigned ("..#self.ControlGroups[group]..")",2)
end

function RTS:RecallControlGroup(group)
    if group<1 or group>4 then return end
    local source=self.ControlGroups[group]; if source==nil then return end
    local recalled={}
    for _,sig in ipairs(source) do
        local ship=self:FindShipBySignature(sig)
        if self:IsMovableFriendly(ship) and shipAlive(ship) then recalled[#recalled+1]=sig end
    end
    self.Selected=recalled
    -- The group must be a SEPARATE table. Assigning self.Selected here made the
    -- control group and the live selection the same table, so every later
    -- additive selection silently grew the group and the quick-group count
    -- changed with no assign action.
    local stored={}
    for _,sig in ipairs(recalled) do stored[#stored+1]=sig end
    self.ControlGroups[group]=stored
    self.PrimarySelectionSignature=recalled[1]
    self:SetStatus("Control group "..group.." selected ("..#recalled..")",1.5)
end

function RTS:SetStatus(message, seconds)
    self.StatusMessage = message
    self.StatusUntil = self:UINow() + (seconds or 2)
end
