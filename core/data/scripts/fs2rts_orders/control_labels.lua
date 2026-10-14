-- Control labels, armed-command hints and pilot hand-back.
local _shared = require "fs2rts_orders.common"
local RTS, shipValid = _shared.RTS, _shared.shipValid

-- Who is driving a ship right now: "pilot", "order" (player), "auto"
-- (Auto Mode AI), "policy", "station" or "enemy". Drives the selection UI.
function RTS:GetShipController(ship)
    if not self:IsFriendly(ship) then return "enemy" end
    local sig=ship:getSignature()
    if self.PossessedSignature==sig then return "pilot" end
    if self:IsCommandStation(ship) then return "station" end
    if self:IsStaticDefense(ship) then return "sentry" end
    if self.UserOrders[sig]~=nil then return "order" end
    if self.AutoPlayerMode then return "auto" end
    return "policy"
end

local POLICY_SUMMARY={HOLD="hold position until ordered",STANDOFF="escort your station",ENGAGE="hunt enemies",RETREAT="pull back behind your station"}

-- One readable line saying who controls the ship and what it is doing.
function RTS:GetShipControlDescription(ship)
    if not self:IsFriendly(ship) then return self:GetShipCommandLabel(ship) end
    local service=self:GetFleetServiceLabel(ship)
    if service and self.PossessedSignature~=ship:getSignature() then return service end
    local controller=self:GetShipController(ship)
    if controller=="pilot" then return "PILOTED BY YOU" end
    if controller=="station" then return "COMMAND STATION" end
    if controller=="sentry" then return "SENTRY GUN: STATIONARY AUTO DEFENSE" end
    if controller=="enemy" then return self:GetShipCommandLabel(ship) end
    local sig=ship:getSignature()
    if controller=="order" then
        local order=self.UserOrders[sig]
        local target=order.targetSignature and self:FindShipBySignature(order.targetSignature)
        if shipValid(target) then return "YOUR ORDER: "..string.upper(order.kind).." "..target.Name end
        if order.kind=="move" then return "YOUR ORDER: MOVE to point" end
        if order.kind=="hold" then return "YOUR ORDER: HOLD position" end
        if order.kind=="engage" then return "YOUR ORDER: ENGAGE hostiles" end
        if order.kind=="wing" then return "YOUR WING: NATIVE SQUAD COMMANDS" end
        return "YOUR ORDER: "..string.upper(tostring(order.kind))
    end
    if controller=="auto" then
        return "AUTO MODE: FLEET AI"
    end
    return "POLICY: "..tostring(self.GlobalPolicy).." ("..(POLICY_SUMMARY[self.GlobalPolicy] or "default")..")"
end

-- Hand selected ships back from player orders to the policy / Auto Mode.
function RTS:ReleaseSelected()
    local released=0
    for _,ship in ipairs(self:GetSelectedFriendlyShips()) do
        local order=self.UserOrders[ship:getSignature()]
        if order~=nil and order.kind~="pilot" and self:IsMovableFriendly(ship) then
            self:ClearUserOrder(ship)
            self:ReturnToDefaultControl(ship)
            released=released+1
        end
    end
    if released>0 then
        self:SetStatus("Released "..released.." ships to "..(self.AutoPlayerMode and "Auto Mode" or ("policy: "..tostring(self.GlobalPolicy))),2.5)
    else
        self:SetStatus("No selected ships are under your orders",2)
    end
end

-- MOVE / ATTACK buttons arm the next left click as that order.
function RTS:ArmCommand(kind)
    if self.ArmedCommand==kind then self.ArmedCommand=nil; return end
    local movable=0
    for _,ship in ipairs(self:GetSelectedFriendlyShips()) do if self:IsMovableFriendly(ship) then movable=movable+1 end end
    if movable==0 then self:SetStatus("Select your ships first",2); return end
    self.ArmedCommand=kind
    self:SetStatus(kind=="move" and "MOVE: left-click a destination (right-click cancels)" or "ATTACK: left-click an enemy (right-click cancels)",3)
end

-- Returns true when the click was consumed by an armed command.
function RTS:ExecuteArmedCommand(x,y)
    local kind=self.ArmedCommand
    if kind==nil then return false end
    if kind=="sentry" or kind=="strike" then
        local station=self:GetCarrier()
        self:ExecuteStationArmedCommand(self:ScreenToPlane(x,y,station and station.Position.y or self.CameraFocus.y))
        return true
    end
    if kind=="move" then
        local destination=self:ScreenToPlane(x,y,self.CameraFocus.y)
        if destination then self:IssueMove(destination) end
        self.ArmedCommand=nil
    else
        local hostile=self:GetShipAtScreen(x,y,false,true)
        if hostile then self:IssueAttack(hostile); self.ArmedCommand=nil
        else self:SetStatus("ATTACK: click an enemy ship (right-click cancels)",2) end
    end
    return true
end
