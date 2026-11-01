-- Field tenders: unarmed mobile workshops that act as fleet-service anchors beside
-- the command station. A tender supplies a ship on a right-click (the supply order),
-- and an idle tender services nearby ships that have fallen below the auto-supply
-- levels. The service itself (pads, repair rates, CP cost) is fs2rts_service.lua.
local RTS=require 'fs2rts_state'
local U=require 'fs2rts_util'
local shipAlive=U.shipAlive

-- Orders that own a ship too firmly for a tender to pull it out on its own.
local UNSUPPLIED_ORDERS={attack=true,attack_wing=true,pilot=true,wing=true,service=true}
local MOVING_SPEED=15

local function settings(self)
    return self.Config.FieldSupport or {}
end

local function distanceBetween(a,b)
    return a.Position:getDistance(b.Position)
end

function RTS:IsFieldTenderClass(className)
    for _,name in pairs(settings(self).Classes or {}) do
        if name==className then return true end
    end
    return false
end

function RTS:IsFieldTender(ship)
    return shipAlive(ship) and self:IsFieldTenderClass(ship.Class.Name)
end

function RTS:GetFieldTenderOption(kind)
    local c=settings(self)
    local classes=c.Classes or {}
    local className=classes[self:GetFactionSpecies(kind)] or classes.TERRAN
    local class=className and tb.ShipClasses[className]
    if not class or not class:isValid() or not (self.ShipCostMap and self.ShipCostMap[className]) then return nil end
    return {class=className,label='Field tender',role='support',tier=1,count=1,cost=c.Cost,time=c.BuildSeconds}
end

-- Live tenders of a faction, plus those waiting in its build queue when asked.
function RTS:CountFieldTenders(kind,includeQueued)
    local count=0
    for _,ship in ipairs(self:GetShipList()) do
        if self:IsFieldTender(ship) and self:GetFactionKey(ship)==kind then count=count+1 end
    end
    if not includeQueued then return count end
    if kind=='BLUE' then
        for _,job in ipairs(self.BuildQueue or {}) do
            if self:IsFieldTenderClass(job.option.class) then count=count+(job.option.count or 1) end
        end
    end
    local state=self.AIStates and self.AIStates[kind]
    local queue=state and state.queue
    if queue and queue.entry and self:IsFieldTenderClass(queue.entry.class) then count=count+(queue.count or 1) end
    return count
end

function RTS:IsServiceAnchorFor(ship,anchor)
    return shipAlive(anchor) and anchor:getSignature()~=ship:getSignature()
        and self:GetFactionKey(anchor)==self:GetFactionKey(ship)
        and (self:IsCommandStation(anchor) or self:IsFieldTender(anchor))
end

-- A new anchor invalidates every pad position that was computed against the old one.
function RTS:ResetServicePad(record)
    record.padPoint=nil; record.padStation=nil; record.padAnchorPosition=nil
    record.padApproachX=nil; record.padApproachZ=nil; record.arrived=false; record.holdSince=nil
    record.ammoCredit={}
end

-- The station or tender a ship services at. A visit keeps its anchor until that
-- anchor is lost; a new visit takes the nearest one.
function RTS:GetFleetServiceAnchor(ship,record)
    local current=record and record.serviceAnchor and self:FindShipBySignature(record.serviceAnchor)
    if self:IsServiceAnchorFor(ship,current) then return current end
    local best=self:GetFactionCommandShip(self:GetFactionKey(ship))
    if not self:IsServiceAnchorFor(ship,best) then best=nil end
    local nearest=best and distanceBetween(ship,best) or math.huge
    for _,candidate in ipairs(self:GetShipList()) do
        if self:IsFieldTender(candidate) and self:IsServiceAnchorFor(ship,candidate) then
            local d=distanceBetween(ship,candidate)
            if d<nearest then best=candidate; nearest=d end
        end
    end
    if record then
        record.serviceAnchor=best and best:getSignature() or nil
        self:ResetServicePad(record)
    end
    return best
end

-- Where a tender stops: on its own side of the target, a stand-off outside both hulls.
local function GetSupplyRendezvous(self,tender,target)
    local gap=(tender.Radius or 50)+(target.Radius or 50)+self.Config.Station.FleetService.StandOff
    local dx=tender.Position.x-target.Position.x
    local dy=tender.Position.y-target.Position.y
    local dz=tender.Position.z-target.Position.z
    local distance=math.sqrt(dx*dx+dy*dy+dz*dz)
    if distance<=gap*1.5 or distance<=0 then return nil end
    local scale=gap/distance
    return U.vec(target.Position.x+dx*scale,target.Position.y+dy*scale,target.Position.z+dz*scale)
end

-- True when `tender` can supply `target`: a tender, and a mobile ship of its own faction.
function RTS:CanSupplyTarget(tender,target)
    return self:IsFieldTender(tender) and shipAlive(target) and tender:getSignature()~=target:getSignature()
        and self:IsFleetServiceShip(target) and self:GetFactionKey(target)==self:GetFactionKey(tender)
end

-- Puts the tender on its way to the target. Called when the order is given and
-- whenever the order is reissued after an interruption.
function RTS:ReissueSupplyOrder(tender,order)
    local target=self:FindShipBySignature(order.targetSignature)
    if not self:CanSupplyTarget(tender,target) then
        self:ClearUserOrder(tender); self:ReturnToDefaultControl(tender)
        return false
    end
    local point=GetSupplyRendezvous(self,tender,target)
    if point then return self:MoveShipTo(tender,point,.95) end
    tender:clearOrders(); self:HoldShip(tender,.95)
    return true
end

-- Sends `target` to be serviced by `tender` and moves the tender next to it.
function RTS:SupplyShip(tender,target,now)
    if not self:CanSupplyTarget(tender,target) then return false end
    if not self:BeginFleetService(target,'FIELD_SUPPLY',now,true,tender) then return false end
    self:SetUserOrder(target,{kind='service'})
    self:SetUserOrder(tender,{kind='supply',targetSignature=target:getSignature()})
    self:ReissueSupplyOrder(tender,self.UserOrders[tender:getSignature()])
    return true
end

-- Sends `ship` to be serviced at `tender`, ahead of ships the tender picked up by itself.
function RTS:SendShipToTender(ship,tender,now)
    if not self:CanSupplyTarget(tender,ship) then return false end
    if not self:BeginFleetService(ship,'FIELD_SUPPLY',now,true,tender) then return false end
    self.FleetServices[ship:getSignature()].prioritized=true
    self:SetUserOrder(ship,{kind='service'})
    return true
end

-- The right-click on a friendly `target`: a selected tender supplies the target, and any
-- other selected ship is serviced by a target that is a tender. False leaves the click
-- to the ordinary guard order.
function RTS:TrySupply(ship,target,now)
    if self:IsFieldTender(ship) and self:SupplyShip(ship,target,now) then return true end
    return self:IsFieldTender(target) and self:SendShipToTender(ship,target,now)
end

-- A tender parks where it is and services from there until given another order.
function RTS:HoldFieldTender(tender)
    self:SetUserOrder(tender,{kind='hold'})
    self:ReissueUserOrder(tender,self.UserOrders[tender:getSignature()])
end

-- The ship a queued tender is delivered to: the ship that was selected when it was
-- bought. Nil when there is none (or it is gone), so the build falls back to the station.
function RTS:GetJobProductionAnchor(job)
    local signature=job and job.deliverySignature
    local anchor=signature and self:FindShipBySignature(signature)
    if shipAlive(anchor) and self:GetFactionKey(anchor)=='BLUE' then return anchor end
    if job then job.deliverySignature=nil end
    return nil
end

local function TenderIsMoving(tender)
    local velocity=tender.Physics and tender.Physics.Velocity
    if not velocity then return false end
    return math.sqrt(velocity.x*velocity.x+velocity.y*velocity.y+velocity.z*velocity.z)>MOVING_SPEED
end

local function CountTenderVisitors(self,tender)
    local signature=tender:getSignature(); local count=0
    for _,record in pairs(self.FleetServices or {}) do
        if record.serviceAnchor==signature then count=count+1 end
    end
    return count
end

local function NeedsSupply(self,ship,limits)
    if ship.HitpointsLeft/math.max(1,ship.HitpointsMax)<limits.Hull then return true end
    if self:GetFleetAmmo(ship)<limits.Ammo then return true end
    return self:GetFleetSubsystems(ship)<limits.Systems
end

local function CanAutoSupply(self,tender,ship,limits,now)
    if ship:getSignature()==tender:getSignature() or not self:IsFleetServiceShip(ship) then return false end
    if self:GetFactionKey(ship)~=self:GetFactionKey(tender) or self:IsFieldTender(ship) then return false end
    local id=ship:getSignature()
    if (self.FleetServices or {})[id] or self.PossessedSignature==id then return false end
    if now<((self.FleetServiceCooldown or {})[id] or 0) then return false end
    if distanceBetween(ship,tender)>limits.Radius then return false end
    local order=self.UserOrders[id]
    if order and UNSUPPLIED_ORDERS[order.kind] then return false end
    local aiOrder=self.AIOrderState and self.AIOrderState[id]
    if aiOrder and aiOrder.mission=='PRIMARY' then return false end
    return NeedsSupply(self,ship,limits)
end

local function NearestAutoSupplyShip(self,tender,limits,now,threatOf)
    local best,nearest=nil,math.huge
    for _,ship in ipairs(self:GetShipList()) do
        if shipAlive(ship) and CanAutoSupply(self,tender,ship,limits,now) then
            local d=distanceBetween(ship,tender)
            if d<nearest and not threatOf(ship) then best=ship; nearest=d end
        end
    end
    return best
end

local function AutoSupply(self,tender,now,threatOf)
    local limits=settings(self).AutoSupply
    if not limits or (limits.Radius or 0)<=0 or TenderIsMoving(tender) then return end
    if CountTenderVisitors(self,tender)>=settings(self).Slots then return end
    local ship=NearestAutoSupplyShip(self,tender,limits,now,threatOf)
    if ship then self:BeginFleetService(ship,'FIELD_SUPPLY',now,false,tender) end
end

-- A supply order ends when its target is gone or no longer being serviced by this tender.
local function SupplyOrderIsDone(self,tender,order)
    local target=self:FindShipBySignature(order.targetSignature)
    if not self:CanSupplyTarget(tender,target) then return true end
    local record=(self.FleetServices or {})[target:getSignature()]
    return record==nil or record.serviceAnchor~=tender:getSignature()
end

-- The AI's one-off tender purchase: once it fields enough ships, with the CP to pay and
-- no emergency under way. Returns a build choice in ChooseAIBuild's shape, or nil.
function RTS:ChooseAITender(kind,state,counts,slots)
    local rules=settings(self).AI or {}
    if (rules.MinFleet or 0)<=0 or slots<1 or (counts.total or 0)<rules.MinFleet then return nil end
    local emergency=self.AIProductionEmergency and self.AIProductionEmergency[kind]
    if emergency and emergency.emergency==true then return nil end
    if self:CountFieldTenders(kind,true)>=(rules.MaxPerTeam or 1) then return nil end
    local option=self:GetFieldTenderOption(kind)
    local estimate=option and self:GetPurchaseEstimate(option.class,option.tier,1)
    if not estimate or estimate.cost>state.cp then return nil end
    local entry={class=option.class,role='support',tier=option.tier,label=option.label,weight=1}
    return {entry=entry,estimate=estimate,count=1,category='support',telemetry={}}
end

-- Per service tick: finish completed supply orders, then let idle tenders pick up work.
-- threatOf(ship) returns a nearby hostile or nil (the service tick's own threat scan).
function RTS:UpdateFieldSupport(now,threatOf)
    for _,tender in ipairs(self:GetShipList()) do
        if self:IsFieldTender(tender) then
            local order=self.UserOrders[tender:getSignature()]
            if order and order.kind=='supply' then
                if SupplyOrderIsDone(self,tender,order) then self:HoldFieldTender(tender) end
            else
                AutoSupply(self,tender,now,threatOf)
            end
        end
    end
end

return RTS
