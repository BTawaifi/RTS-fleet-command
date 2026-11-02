-- Field tenders: unarmed mobile workshops that act as fleet-service anchors beside
-- the command station. A tender supplies a ship on a right-click (the supply order)
-- and, with no order, goes looking for ships that need supply. A ship it services
-- parks alongside it. The service itself (pads, repair rates, CP cost) is
-- fs2rts_service.lua.
local RTS=require 'fs2rts_state'
local U=require 'fs2rts_util'
local shipAlive=U.shipAlive

-- Orders that own a ship too firmly for a tender to pull it out on its own.
local UNSUPPLIED_ORDERS={attack=true,attack_wing=true,pilot=true,wing=true,service=true}
local MOVING_SPEED=15
local RALLY_MIN_SHIPS=3

local function settings(self)
    return self.Config.FieldSupport or {}
end

local function seekSettings(self)
    return settings(self).Seek or {}
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

-- Hull gap and arrival tolerance for ships serviced at `anchor`: a tender is
-- approached closely, a station from further out.
function RTS:GetServiceGeometry(anchor)
    local station=self.Config.Station.FleetService
    if self:IsFieldTender(anchor) then
        local c=settings(self)
        return c.StandOff or station.StandOff,c.ArrivalRadius or station.ArrivalRadius
    end
    return station.StandOff,station.ArrivalRadius
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

-- A tender with ships alongside must stay where it is: the planner leaves it alone.
function RTS:IsFieldTenderBusy(ship)
    return self:IsFieldTender(ship) and CountTenderVisitors(self,ship)>0
end

-- Stops the tender where it is. ORDER_STAY_STILL does not brake, so the speed is
-- bled off directly, as for ships holding a service pad.
function RTS:HoldDockedTender(tender)
    if not TenderIsMoving(tender) then return end
    tender:clearOrders(); self:HoldShip(tender,.9)
    local physics=tender.Physics
    if physics then physics.Velocity=U.vec(0,0,0) end
end

-- Where a tender stops beside its target: on its own side, a stand-off outside both hulls.
local function GetSupplyRendezvous(self,tender,target)
    local standOff=self:GetServiceGeometry(tender)
    local gap=(tender.Radius or 50)+(target.Radius or 50)+standOff
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

-- The tender's supply order: it flies to the target; the target is taken in once
-- the tender is within JoinRange (see ServeSupplyOrder).
function RTS:SupplyShip(tender,target)
    if not self:CanSupplyTarget(tender,target) then return false end
    self:SetUserOrder(tender,{kind='supply',targetSignature=target:getSignature(),reissuedAt=mn.getMissionTime()})
    self:ReissueSupplyOrder(tender,self.UserOrders[tender:getSignature()])
    return true
end

-- Sends `ship` to be serviced at `tender`, ahead of ships the tender picked up by itself.
function RTS:SendShipToTender(ship,tender,now)
    if not self:CanSupplyTarget(tender,ship) then return false end
    if not self:BeginFleetService(ship,'FIELD_SUPPLY',now,true,tender) then return false end
    self.FleetServices[ship:getSignature()].prioritized=true
    self:SetUserOrder(ship,{kind='service'})
    self:HoldDockedTender(tender)
    return true
end

-- The right-click on a friendly `target`: a selected tender supplies the target, and any
-- other selected ship is serviced by a target that is a tender. False leaves the click
-- to the ordinary guard order.
function RTS:TrySupply(ship,target,now)
    if self:IsFieldTender(ship) and self:SupplyShip(ship,target) then return true end
    return self:IsFieldTender(target) and self:SendShipToTender(ship,target,now)
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

local function NeedsSupply(self,ship,limits)
    if ship.HitpointsLeft/math.max(1,ship.HitpointsMax)<limits.Hull then return true end
    if self:GetFleetAmmo(ship)<limits.Ammo then return true end
    return self:GetFleetSubsystems(ship)<limits.Systems
end

-- A ship a tender may take on its own: no firm order, not already in service, not
-- on a committed strike. Whether it needs anything is a separate question.
local function IsSupplyCandidate(self,tender,ship,now)
    if ship:getSignature()==tender:getSignature() or not self:IsFleetServiceShip(ship) then return false end
    if self:GetFactionKey(ship)~=self:GetFactionKey(tender) or self:IsFieldTender(ship) then return false end
    local id=ship:getSignature()
    if (self.FleetServices or {})[id] or self.PossessedSignature==id then return false end
    if now<((self.FleetServiceCooldown or {})[id] or 0) then return false end
    local order=self.UserOrders[id]
    if order and UNSUPPLIED_ORDERS[order.kind] then return false end
    local aiOrder=self.AIOrderState and self.AIOrderState[id]
    return not (aiOrder and aiOrder.mission=='PRIMARY')
end

-- Need x size / distance: a big ship, one with damaged systems and a near one come first.
local function SupplyScore(self,tender,ship)
    local seek=seekSettings(self)
    local hullMissing=1-ship.HitpointsLeft/math.max(1,ship.HitpointsMax)
    local systemsMissing=1-self:GetFleetSubsystems(ship)
    local ammoMissing=1-self:GetFleetAmmo(ship)
    local need=math.max(0,hullMissing)+(seek.SystemsWeight or 1)*math.max(0,systemsMissing)+(seek.AmmoWeight or .5)*math.max(0,ammoMissing)
    local priced=self.ShipCostMap and self.ShipCostMap[ship.Class.Name]
    local cost=priced and priced.cost or 0
    local size=math.min(seek.SizeCap or 4,1+cost/(seek.SizeCost or 2500))
    return need*size/(1+distanceBetween(ship,tender)/(seek.DistanceScale or 6000))
end

local function NeedySupplyCandidates(self,tender,now,maxDistance)
    local limits=settings(self).AutoSupply
    local list={}
    for _,ship in ipairs(self:GetShipList()) do
        if shipAlive(ship) and IsSupplyCandidate(self,tender,ship,now) and NeedsSupply(self,ship,limits)
            and (maxDistance==nil or distanceBetween(ship,tender)<=maxDistance) then
            list[#list+1]={ship=ship,score=SupplyScore(self,tender,ship)}
        end
    end
    table.sort(list,function(a,b) return a.score>b.score end)
    return list
end

-- Best-scoring needy ship with no hostile close by, looking at the top few only.
local function BestSupplyTarget(self,tender,now,threatOf,maxDistance)
    local list=NeedySupplyCandidates(self,tender,now,maxDistance)
    for i=1,math.min(#list,seekSettings(self).ThreatChecks or 4) do
        if not threatOf(list[i].ship) then return list[i].ship end
    end
    return nil
end

-- Per-tender memory of what it is heading for and when it last gave a move order.
local function SeekState(self,tender)
    self.FieldTenderSeek=self.FieldTenderSeek or {}
    local signature=tender:getSignature()
    self.FieldTenderSeek[signature]=self.FieldTenderSeek[signature] or {}
    return self.FieldTenderSeek[signature]
end

local function IsKeptTarget(self,tender,seek,now)
    local target=seek.targetSignature and self:FindShipBySignature(seek.targetSignature)
    if not shipAlive(target) or now-(seek.pickedAt or -math.huge)>=(seekSettings(self).RepickSeconds or 10) then return nil end
    if not IsSupplyCandidate(self,tender,target,now) or not NeedsSupply(self,target,settings(self).AutoSupply) then return nil end
    return target
end

local function PickTarget(self,tender,seek,now,threatOf)
    local kept=IsKeptTarget(self,tender,seek,now)
    if kept then return kept end
    local target=BestSupplyTarget(self,tender,now,threatOf)
    seek.targetSignature=target and target:getSignature() or nil
    seek.pickedAt=now
    return target
end

local function MoveTender(self,tender,seek,point,tag,now)
    local rules=seekSettings(self)
    if seek.moveTag==tag and seek.movePoint and now-(seek.movedAt or -math.huge)<(rules.ReissueSeconds or 5)
        and seek.movePoint:getDistance(point)<400 then return end
    seek.moveTag=tag; seek.movePoint=point; seek.movedAt=now
    self:MoveShipTo(tender,point,rules.MovePriority or .7)
end

-- Where an idle tender waits: behind the friendly ship nearest the fleet's centre,
-- toward its own station. Nil when there is no fleet to trail.
local function GetFleetRallyPoint(self,tender)
    local kind=self:GetFactionKey(tender)
    local ships,x,z={},0,0
    for _,ship in ipairs(self:GetShipList()) do
        if shipAlive(ship) and self:GetFactionKey(ship)==kind and self:IsFleetServiceShip(ship) and not self:IsFieldTender(ship) then
            ships[#ships+1]=ship; x=x+ship.Position.x; z=z+ship.Position.z
        end
    end
    if #ships<RALLY_MIN_SHIPS then return nil end
    x=x/#ships; z=z/#ships
    local heart,nearest=nil,math.huge
    for _,ship in ipairs(ships) do
        local dx,dz=ship.Position.x-x,ship.Position.z-z
        local d=dx*dx+dz*dz
        if d<nearest then heart=ship; nearest=d end
    end
    local point=heart.Position
    local station=self:GetFactionCommandShip(kind)
    if shipAlive(station) then
        local dx,dz=station.Position.x-point.x,station.Position.z-point.z
        local length=math.sqrt(dx*dx+dz*dz)
        if length>1 then
            local trail=math.min(seekSettings(self).FleetTrail or 1200,length)
            point=U.vec(point.x+dx/length*trail,point.y,point.z+dz/length*trail)
        end
    end
    return point
end

-- The ship the planner should escort for this tender: what it is heading for, else nil.
function RTS:GetTenderEscortTarget(tender)
    local seek=self.FieldTenderSeek and shipAlive(tender) and self.FieldTenderSeek[tender:getSignature()]
    local target=seek and seek.targetSignature and self:FindShipBySignature(seek.targetSignature)
    return shipAlive(target) and target or nil
end

-- The planner moves AI tenders (and the player's in Auto Mode) by escort orders.
local function PlannerMovesTender(self,tender)
    if self:GetFactionKey(tender)~='BLUE' then return true end
    local id=tender:getSignature()
    return self.AutoPlayerMode==true and self.PossessedSignature~=id and self.UserOrders[id]==nil
end

local function BeginTenderService(self,tender,ship,now,manual)
    if not self:BeginFleetService(ship,'FIELD_SUPPLY',now,manual,tender) then return false end
    self:HoldDockedTender(tender)
    return true
end

-- A supply order ends when its ship is serviced or gone; the tender is then released
-- to look for work on its own.
local function ReleaseTender(self,tender)
    self:ClearUserOrder(tender)
    self:ReturnToDefaultControl(tender)
end

local function ServeSupplyOrder(self,tender,order,now)
    local target=self:FindShipBySignature(order.targetSignature)
    if not self:CanSupplyTarget(tender,target) then ReleaseTender(self,tender); return end
    local record=(self.FleetServices or {})[target:getSignature()]
    if record and record.serviceAnchor==tender:getSignature() then
        order.started=true; self:HoldDockedTender(tender); return
    end
    if order.started then ReleaseTender(self,tender); return end
    if distanceBetween(tender,target)<=(seekSettings(self).JoinRange or 1500) then
        if BeginTenderService(self,tender,target,now,true) then
            self.FleetServices[target:getSignature()].prioritized=true
            self:SetUserOrder(target,{kind='service'})
            order.started=true
        else
            ReleaseTender(self,tender)
        end
        return
    end
    if now-(order.reissuedAt or -math.huge)>=(seekSettings(self).ReissueSeconds or 5) then
        order.reissuedAt=now; self:ReissueSupplyOrder(tender,order)
    end
end

-- Takes needy ships close to the tender while it has a free slot. They fly the last
-- stretch themselves, so the tender does not have to move.
local function TakeNearbyShip(self,tender,now,threatOf)
    local limit=settings(self).Slots
    if CountTenderVisitors(self,tender)>=limit then return end
    local ship=BestSupplyTarget(self,tender,now,threatOf,seekSettings(self).NearbyRange or 3000)
    if ship then BeginTenderService(self,tender,ship,now,false) end
end

-- A tender with no player order: keep the ships alongside serviced, otherwise go
-- to the neediest ship, otherwise trail the fleet.
local function DriveTender(self,tender,now,threatOf)
    local seek=SeekState(self,tender)
    TakeNearbyShip(self,tender,now,threatOf)
    if CountTenderVisitors(self,tender)>0 then
        self:HoldDockedTender(tender); seek.targetSignature=nil; return
    end
    local target=PickTarget(self,tender,seek,now,threatOf)
    if target and distanceBetween(tender,target)<=(seekSettings(self).JoinRange or 1500) then
        if threatOf(target) then seek.targetSignature=nil
        else BeginTenderService(self,tender,target,now,false) end
        return
    end
    if PlannerMovesTender(self,tender) then return end
    local point=target and GetSupplyRendezvous(self,tender,target)
    if point then MoveTender(self,tender,seek,point,target:getSignature(),now); return end
    if target then return end
    local rally=GetFleetRallyPoint(self,tender)
    if rally and distanceBetween(tender,{Position=rally})>(seekSettings(self).JoinRange or 1500) then
        MoveTender(self,tender,seek,rally,'rally',now)
    end
end

-- A tender the player has ordered elsewhere keeps its order; ships already near it
-- are still serviced once it is stationary.
local function DriveOrderedTender(self,tender,now,threatOf)
    if TenderIsMoving(tender) then return end
    TakeNearbyShip(self,tender,now,threatOf)
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

-- Per service tick, for every tender: serve its supply order, or work on its own.
-- threatOf(ship) returns a nearby hostile or nil (the service tick's own threat scan).
function RTS:UpdateFieldSupport(now,threatOf)
    for _,tender in ipairs(self:GetShipList()) do
        if self:IsFieldTender(tender) then
            local order=self.UserOrders[tender:getSignature()]
            if order and order.kind=='supply' then
                ServeSupplyOrder(self,tender,order,now)
            elseif order then
                DriveOrderedTender(self,tender,now,threatOf)
            else
                DriveTender(self,tender,now,threatOf)
            end
        end
    end
end

return RTS
