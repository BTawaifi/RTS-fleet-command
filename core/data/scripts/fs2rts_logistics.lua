-- Mobile tenders answer fleet-service requests and provide paid repair and rearm.
local RTS=require 'fs2rts_state'
local U=require 'fs2rts_util'
local shipAlive,objectValid=U.shipAlive,U.objectValid
local stopAssignedTender

local function settings(self) return self.Config.FieldSupport or {} end
local function seekSettings(self) return settings(self).Seek or {} end
local function distanceBetween(a,b) return a.Position:getDistance(b.Position) end
-- Player orders that keep a ship out of automatic tender pickup (a committed strike or a service visit).
local UNSUPPLIED_ORDERS={attack=true,attack_wing=true,pilot=true,wing=true,service=true}

function RTS:IsFieldTenderClass(className)
    for _,name in pairs(settings(self).Classes or {}) do if name==className then return true end end
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
    return self:IsFieldTender(anchor) and anchor:getSignature()~=ship:getSignature()
        and self:GetFactionKey(anchor)==self:GetFactionKey(ship)
end

function RTS:GetServiceGeometry(anchor)
    local c=settings(self)
    return c.StandOff or 120,c.ArrivalRadius or 220
end

function RTS:ResetServicePad(record)
    record.padPoint=nil; record.padStation=nil; record.padAnchorPosition=nil
    record.padApproachX=nil; record.padApproachZ=nil; record.arrived=false; record.holdSince=nil
    record.ammoCredit={}
end

function RTS:GetFleetServiceAnchor(ship,record)
    local anchor=record and record.serviceAnchor and self:FindShipBySignature(record.serviceAnchor)
    return self:IsServiceAnchorFor(ship,anchor) and anchor or nil
end

local function shipRadius(ship)
    return ship.Radius or (ship.Class.Model and ship.Class.Model.Radius) or 50
end

function RTS:IsTenderAlongside(tender,ship)
    if not self:IsServiceAnchorFor(ship,tender) then return false end
    local standOff,arrival=self:GetServiceGeometry(tender)
    return distanceBetween(tender,ship)<=shipRadius(tender)+shipRadius(ship)+standOff+arrival
end

function RTS:CanSupplyTarget(tender,target)
    return self:IsFieldTender(tender) and shipAlive(target) and not self:IsFieldTender(target)
        and self:IsFleetServiceShip(target) and self:IsServiceAnchorFor(target,tender)
end

function RTS:RequestFleetService(ship,reason,now,manual,preferredTender)
    if self.AftermathActive or not self:IsFleetServiceShip(ship) or self:IsFieldTender(ship) then return false end
    local id=ship:getSignature()
    local pilot=self.PossessedSignature==id
    if (pilot and (not manual or reason~='PILOT_SERVICE')) or (self.IsShipWithdrawing and self:IsShipWithdrawing(ship)) then return false end
    if preferredTender and not self:CanSupplyTarget(preferredTender,ship) then return false end
    local active=(self.FleetServices or {})[id]
    if active then
        if preferredTender and active.serviceAnchor~=preferredTender:getSignature() then return false end
        active.manual=active.manual or manual==true
        return true
    end
    self.FleetServiceRequests=self.FleetServiceRequests or {}
    local request=self.FleetServiceRequests[id]
    if not request then
        self.FleetServiceRequestSerial=(self.FleetServiceRequestSerial or 0)+1
        request={reason=reason,requestedAt=now,serial=self.FleetServiceRequestSerial,manual=manual==true,pilot=pilot}
        self.FleetServiceRequests[id]=request
    elseif manual then
        if not request.manual then
            self.FleetServiceRequestSerial=(self.FleetServiceRequestSerial or 0)+1
            request.serial=self.FleetServiceRequestSerial
        end
        request.manual=true; request.reason=reason
    end
    if preferredTender then
        local preferred=preferredTender:getSignature()
        if request.assignedTender~=preferred then
            stopAssignedTender(self,request.assignedTender,id)
            request.assignedTender=nil
        end
        request.preferredTender=preferred
    end
    return true
end

function RTS:RestoreFleetServiceRequest(ship,request)
    if not shipAlive(ship) or not request or (self.PossessedSignature==ship:getSignature() and not request.pilot)
        or (self.IsShipWithdrawing and self:IsShipWithdrawing(ship)) then return end
    self.FleetServiceRequests=self.FleetServiceRequests or {}
    local id=ship:getSignature()
    if self.FleetServiceRequests[id] then return end
    request.assignedTender=nil; request.preferredTender=nil
    self.FleetServiceRequests[id]=request
end

stopAssignedTender=function(self,tenderId,targetId)
    if not tenderId then return end
    local tender=self:FindShipBySignature(tenderId)
    if not self:IsFieldTender(tender) then return end
    if self.FieldTenderSeek then self.FieldTenderSeek[tenderId]=nil end
    local order=(self.UserOrders or {})[tenderId]
    if order and order.kind=='supply' and order.targetSignature==targetId then
        self.UserOrders[tenderId]=nil
        tender:clearOrders()
    elseif not order then
        tender:clearOrders()
    end
end

function RTS:StopTenderForService(tenderId,targetId)
    stopAssignedTender(self,tenderId,targetId)
end

function RTS:ClearFleetServiceRequests()
    for id,request in pairs(self.FleetServiceRequests or {}) do
        stopAssignedTender(self,request.assignedTender,id)
    end
    self.FleetServiceRequests={}
end

function RTS:CancelFleetServiceRequestForShip(ship)
    if not ship or not ship:isValid() then return end
    local id=ship:getSignature()
    local requests=self.FleetServiceRequests or {}
    local request=requests[id]
    if request then
        requests[id]=nil
        stopAssignedTender(self,request.assignedTender,id)
    end
    if not self:IsFieldTenderClass(ship.Class.Name) then return end
    for _,waiting in pairs(requests) do
        if waiting.assignedTender==id then waiting.assignedTender=nil end
        if waiting.preferredTender==id then waiting.preferredTender=nil end
    end
    for targetId,service in pairs(self.FleetServices or {}) do
        if service.serviceAnchor==id then
            local target=self:FindShipBySignature(targetId)
            if shipAlive(target) then
                self:CancelFleetServiceForShip(target,service.pendingOrder)
                self:RestoreFleetServiceRequest(target,service.request)
            end
        end
    end
end

local function visitorWeight(self,ship)
    local role=self:GetShipRole(ship)
    if role=='capital' or role=='heavy' or role=='juggernaut' then return math.min(2,settings(self).Slots or 1) end
    return 1
end

local function usedSlots(self,tender)
    local count=0
    for id,record in pairs(self.FleetServices or {}) do
        if record.serviceAnchor==tender:getSignature() then
            local ship=self:FindShipBySignature(id)
            if shipAlive(ship) then count=count+visitorWeight(self,ship) end
        end
    end
    return count
end

function RTS:IsFieldTenderBusy(ship)
    return self:IsFieldTender(ship) and usedSlots(self,ship)>0
end

local function countRearmBays(ship)
    local class=ship and ship.Class
    local model=class and class.Model
    local bays=model and model.Dockingbays
    if not bays then return 0 end
    local count=0
    for i=1,#bays do
        local name=string.lower(bays[i]:getName() or '')
        if string.sub(name,1,5)~='cargo' then count=count+1 end
    end
    return count
end

local rearmBayCache={}

local function rearmBayCount(ship)
    local ok,className=pcall(function() return ship.Class.Name end)
    local cached=ok and rearmBayCache[className]
    if cached~=nil then return cached end
    local counted,count=pcall(countRearmBays,ship)
    if not counted then return 0 end
    if ok and className then rearmBayCache[className]=count end
    return count
end

local function hasOrderType(ship,kind)
    for i=1,#ship.Orders do
        local order=ship.Orders[i]
        if order then
            local ok,orderKind=pcall(order.getType,order)
            if ok and orderKind==kind then return true end
        end
    end
    return false
end

local function dockTable(self)
    self.FieldTenderDock=self.FieldTenderDock or {}
    return self.FieldTenderDock
end

-- A tender docks physically with a ship only when both models have a rearm-capable
-- docking bay. Pilot-controlled hulls and visits that already failed to dock use the
-- alongside fallback.
local function canDockWith(self,tender,ship)
    if settings(self).PhysicalDock==false then return false end
    if self.PossessedSignature==ship:getSignature() then return false end
    local dock=dockTable(self)[tender:getSignature()]
    if dock and dock.target==ship:getSignature() and dock.refused then return false end
    return rearmBayCount(tender)>0 and rearmBayCount(ship)>0
end

-- True when this visit is served docked: repair and rearm run only while the tender
-- is physically docked with the ship. A visit whose dock was refused, or whose
-- models have no rearm bay, is served alongside instead.
function RTS:IsDockedServiceRequired(tender,ship)
    return canDockWith(self,tender,ship)
end

local function pursueDock(self,tender,ship,now)
    local docks=dockTable(self)
    local id=tender:getSignature()
    local targetId=ship:getSignature()
    local dock=docks[id]
    if not dock or dock.target~=targetId then
        dock={target=targetId,startedAt=now,refused=false}
        docks[id]=dock
    end
    if tender:isDocked(ship) then return true end
    if dock.issuedAt and hasOrderType(tender,ORDER_DOCK) then return true end
    if dock.issuedAt and now-dock.issuedAt<(seekSettings(self).ReissueSeconds or 5) then return true end
    tender:clearOrders()
    if tender:giveOrder(ORDER_DOCK,ship,nil,seekSettings(self).MovePriority or .7)~=true then
        dock.refused=true
        return false
    end
    self:SetShipCommandDiscipline(tender,false)
    dock.issuedAt=now
    return true
end

-- True while the tender is docked with, or flying a dock approach to, this ship.
local function tenderIsDockingWith(self,tender,ship)
    local dock=dockTable(self)[tender:getSignature()]
    if not dock or dock.refused or dock.target~=ship:getSignature() then return false end
    return tender:isDocked(ship) or hasOrderType(tender,ORDER_DOCK)
end

function RTS:ReleaseTenderDock(tender,ship)
    if not shipAlive(tender) or not shipAlive(ship) then return end
    local docks=dockTable(self)
    local id=tender:getSignature()
    local dock=docks[id]
    if not dock or dock.target~=ship:getSignature() then return end
    docks[id]=nil
    if tender:isDocked(ship) then tender:setUndocked(ship) end
    if hasOrderType(tender,ORDER_DOCK) then tender:clearOrders() end
end

local function dockStillWanted(self,tender,dock)
    local service=(self.FleetServices or {})[dock.target]
    if service and service.serviceAnchor==tender:getSignature() then return true end
    local request=(self.FleetServiceRequests or {})[dock.target]
    return request~=nil and request.assignedTender==tender:getSignature()
end

-- A tender docks with one ship at a time. True while it is docked with, or flying
-- to dock with, a different ship that is still wanted.
local function dockedWithAnother(self,tender,ship)
    local dock=dockTable(self)[tender:getSignature()]
    if not dock or dock.refused or dock.target==ship:getSignature() then return false end
    return shipAlive(self:FindShipBySignature(dock.target)) and dockStillWanted(self,tender,dock)
end

local function sweepTenderDock(self,tender,now)
    local docks=dockTable(self)
    local id=tender:getSignature()
    local dock=docks[id]
    if not dock then return end
    local ship=self:FindShipBySignature(dock.target)
    if not shipAlive(ship) then
        docks[id]=nil
        if hasOrderType(tender,ORDER_DOCK) then tender:clearOrders() end
        return
    end
    if not dockStillWanted(self,tender,dock) then self:ReleaseTenderDock(tender,ship); return end
    if dock.refused or tender:isDocked(ship) then return end
    if distanceBetween(tender,ship)>(seekSettings(self).DockApproachRange or 1500) then
        dock.startedAt=now
    elseif now-dock.startedAt>(seekSettings(self).DockSeconds or 90) then
        dock.refused=true
        if hasOrderType(tender,ORDER_DOCK) then tender:clearOrders() end
    end
end

function RTS:HoldDockedTender(tender)
    local dockTarget=(dockTable(self)[tender:getSignature()] or {}).target
    local dockShip=dockTarget and self:FindShipBySignature(dockTarget)
    if shipAlive(dockShip) and tenderIsDockingWith(self,tender,dockShip) then return end
    local velocity=tender.Physics and tender.Physics.Velocity
    if not velocity then return end
    local speed=math.sqrt(velocity.x*velocity.x+velocity.y*velocity.y+velocity.z*velocity.z)
    local holding=false
    for i=1,#tender.Orders do
        local order=tender.Orders[i]
        if order and order:isValid() and order:getType()==ORDER_STAY_STILL then holding=true end
    end
    if not holding then
        tender:clearOrders()
        tender:giveOrder(ORDER_STAY_STILL,nil,nil,.95)
    end
    if speed>0 then tender.Physics.Velocity=U.vec(0,0,0) end
    if self.FieldTenderSeek then self.FieldTenderSeek[tender:getSignature()]=nil end
end

local function rendezvous(self,tender,target)
    local standOff,arrival=self:GetServiceGeometry(tender)
    local gap=shipRadius(tender)+shipRadius(target)+standOff+arrival*.5
    local dx=tender.Position.x-target.Position.x
    local dy=tender.Position.y-target.Position.y
    local dz=tender.Position.z-target.Position.z
    local distance=math.sqrt(dx*dx+dy*dy+dz*dz)
    if distance<=0 then return nil end
    local scale=gap/distance
    return U.vec(target.Position.x+dx*scale,target.Position.y+dy*scale,target.Position.z+dz*scale)
end

local function moveTender(self,tender,target,now)
    if canDockWith(self,tender,target) and pursueDock(self,tender,target,now) then return true end
    local point=rendezvous(self,tender,target)
    if not point then return false end
    self.FieldTenderSeek=self.FieldTenderSeek or {}
    local id=tender:getSignature()
    local state=self.FieldTenderSeek[id] or {}
    self.FieldTenderSeek[id]=state
    if state.targetSignature==target:getSignature() and state.movePoint
        and now-(state.movedAt or -math.huge)<(seekSettings(self).ReissueSeconds or 5)
        and state.movePoint:getDistance(point)<400 then return true end
    local destination=self:ClampShipDestination(tender,point)
    if not destination then return false end
    local waypoint=self:ConfigureMoveWaypoints(tender,destination)
    if not objectValid(waypoint) then return false end
    tender:clearOrders()
    if tender:giveOrder(ORDER_WAYPOINTS_ONCE,waypoint,nil,seekSettings(self).MovePriority or .7)~=true then return false end
    self:SetShipCommandDiscipline(tender,false)
    state.targetSignature=target:getSignature(); state.movePoint=U.copyVec(destination); state.movedAt=now
    return true
end

function RTS:ReissueSupplyOrder(tender,order)
    local target=self:FindShipBySignature(order.targetSignature)
    if not self:CanSupplyTarget(tender,target) then return false end
    if not self:RequestFleetService(target,'FIELD_SUPPLY',mn.getMissionTime(),true,tender) then return false end
    local request=self.FleetServiceRequests[target:getSignature()]
    if request then request.assignedTender=tender:getSignature() end
    if self:IsTenderAlongside(tender,target) then return true end
    return moveTender(self,tender,target,mn.getMissionTime())
end

function RTS:SupplyShip(tender,target)
    if not self:CanSupplyTarget(tender,target) then return false end
    local active=(self.FleetServices or {})[target:getSignature()]
    if active and active.serviceAnchor~=tender:getSignature() then return false end
    self:SetUserOrder(tender,{kind='supply',targetSignature=target:getSignature()})
    return self:ReissueSupplyOrder(tender,self.UserOrders[tender:getSignature()])
end

function RTS:SendShipToTender(ship,tender,now)
    if not self:CanSupplyTarget(tender,ship) then return false end
    return self:RequestFleetService(ship,'FIELD_SUPPLY',now,true,tender)
end

function RTS:TrySupply(ship,target,now)
    if self:IsFieldTender(ship) and self:SupplyShip(ship,target) then return true end
    return self:IsFieldTender(target) and self:SendShipToTender(ship,target,now)
end

function RTS:GetJobProductionAnchor(job)
    local signature=job and job.deliverySignature
    local anchor=signature and self:FindShipBySignature(signature)
    if shipAlive(anchor) and self:GetFactionKey(anchor)=='BLUE' then return anchor end
    if job then job.deliverySignature=nil end
    return nil
end

function RTS:GetTenderEscortTarget(tender) return nil end

local function needsSupply(self,ship)
    local limits=settings(self).AutoSupply
    return ship.HitpointsLeft/math.max(1,ship.HitpointsMax)<limits.Hull
        or self:GetFleetAmmo(ship)<limits.Ammo or self:GetFleetSubsystems(ship)<limits.Systems
end

local function supportedByAny(self,tenders,ship)
    for i=1,#tenders do
        if self:CanSupplyTarget(tenders[i],ship) then return true end
    end
    return false
end

-- One pass over the ships for all tenders that may take new work this tick.
local function enqueueAutomaticRequests(self,tenders,ships,now)
    if #tenders==0 then return end
    for _,ship in ipairs(ships) do
        local id=ship:getSignature()
        local order=(self.UserOrders or {})[id]
        local aiOrder=self.AIOrderState and self.AIOrderState[id]
        if not (self.FleetServices or {})[id] and not (self.FleetServiceRequests or {})[id]
            and self.PossessedSignature~=id and now>=((self.FleetServiceCooldown or {})[id] or 0)
            and now>=((self.FieldServiceReadyAt or {})[id] or 0)
            and not (order and UNSUPPLIED_ORDERS[order.kind])
            and not (aiOrder and aiOrder.mission=='PRIMARY') and supportedByAny(self,tenders,ship)
            and needsSupply(self,ship) then
            self:RequestFleetService(ship,'FIELD_SUPPLY',now,false)
        end
    end
end

local function pruneRequests(self)
    for id,request in pairs(self.FleetServiceRequests or {}) do
        local target=self:FindShipBySignature(id)
        if not shipAlive(target) or (self.PossessedSignature==id and not request.pilot)
            or (self.IsShipWithdrawing and self:IsShipWithdrawing(target)) then
            self.FleetServiceRequests[id]=nil
            stopAssignedTender(self,request.assignedTender,id)
        else
            local assigned=request.assignedTender and self:FindShipBySignature(request.assignedTender)
            if request.assignedTender and not self:CanSupplyTarget(assigned,target) then request.assignedTender=nil end
            local preferred=request.preferredTender and self:FindShipBySignature(request.preferredTender)
            if request.preferredTender and not self:CanSupplyTarget(preferred,target) then request.preferredTender=nil end
        end
    end
end

-- True when some other request could be served by this tender.
function RTS:HasWaitingServiceRequest(tender,exceptShip)
    local exceptId=exceptShip and exceptShip:getSignature()
    local tenderId=tender:getSignature()
    for id,request in pairs(self.FleetServiceRequests or {}) do
        if id~=exceptId and (not request.assignedTender or request.assignedTender==tenderId)
            and (not request.preferredTender or request.preferredTender==tenderId)
            and self:CanSupplyTarget(tender,self:FindShipBySignature(id)) then return true end
    end
    return false
end

-- Need x size / distance: a big ship, one with damaged systems and a near one rank first.
local function weightedNeed(self,ship)
    local seek=seekSettings(self)
    local hullMissing=1-ship.HitpointsLeft/math.max(1,ship.HitpointsMax)
    local systemsMissing=1-self:GetFleetSubsystems(ship)
    local ammoMissing=1-self:GetFleetAmmo(ship)
    local need=math.max(0,hullMissing)+(seek.SystemsWeight or 1)*math.max(0,systemsMissing)+(seek.AmmoWeight or .5)*math.max(0,ammoMissing)
    local priced=self.ShipCostMap and self.ShipCostMap[ship.Class.Name]
    local size=math.min(seek.SizeCap or 4,1+(priced and priced.cost or 0)/(seek.SizeCost or 2500))
    return need*size
end

-- The tender-independent part is computed once per request per tick.
local function supplyScore(self,tender,ship,request,now)
    if not request.weightedNeed or request.weightedNeedAt~=now then
        request.weightedNeed=weightedNeed(self,ship); request.weightedNeedAt=now
    end
    return request.weightedNeed/(1+distanceBetween(ship,tender)/(seekSettings(self).DistanceScale or 6000))
end

-- Priority order: player-issued requests first, in the order they were issued;
-- then automatic requests by supplyScore. A tender keeps the request it was already
-- assigned (within RepickSeconds) ahead of others of the same kind. Equal scores go
-- to the earlier request.
local function entryPrecedes(entry,other)
    if not other then return true end
    if entry.manual~=other.manual then return entry.manual end
    if entry.sticky~=other.sticky then return entry.sticky end
    if entry.manual then return entry.request.serial<other.request.serial end
    if entry.score~=other.score then return entry.score>other.score end
    return entry.request.serial<other.request.serial
end

local function chooseRequest(self,tender,order,nearby,availableSlots,now)
    local best
    local tenderId=tender:getSignature()
    local repick=seekSettings(self).RepickSeconds or 10
    for id,request in pairs(self.FleetServiceRequests or {}) do
        local ship=self:FindShipBySignature(id)
        if self:CanSupplyTarget(tender,ship) and (not order or order.targetSignature==id)
            and (not request.assignedTender or request.assignedTender==tenderId)
            and (not request.preferredTender or request.preferredTender==tenderId)
            and visitorWeight(self,ship)<=availableSlots
            and not (canDockWith(self,tender,ship) and dockedWithAnother(self,tender,ship))
            and (not nearby or self:IsTenderAlongside(tender,ship)) then
            local entry={request=request,ship=ship,manual=request.manual==true,
                sticky=request.assignedTender==tenderId and now-(request.assignedAt or -math.huge)<repick,
                score=request.manual and 0 or supplyScore(self,tender,ship,request,now)/(1+(request.rotations or 0))}
            if entryPrecedes(entry,best) then best=entry end
        end
    end
    if not best then return nil,nil end
    return best.request,best.ship
end

local function releaseOtherAssignments(self,tenderId,keepId)
    for id,request in pairs(self.FleetServiceRequests or {}) do
        if id~=keepId and request.assignedTender==tenderId then request.assignedTender=nil end
    end
end

local function acceptRequest(self,tender,ship,request,now)
    if not self:BeginFleetService(ship,request.reason,now,request.manual,tender) then return false end
    local id=ship:getSignature()
    self.FleetServiceRequests[id]=nil
    self.FleetServices[id].request=request
    request.assignedTender=nil
    if request.manual and not request.pilot and self:IsFriendly(ship) then self:SetUserOrder(ship,{kind='service'}) end
    if not (canDockWith(self,tender,ship) and pursueDock(self,tender,ship,now)) then self:HoldDockedTender(tender) end
    return true
end

local function displacedVisitor(self,tender)
    local best,bestRecord,alongside=nil,nil,false
    for id,record in pairs(self.FleetServices or {}) do
        local ship=self:FindShipBySignature(id)
        if record.serviceAnchor==tender:getSignature() and shipAlive(ship) then
            if self:IsTenderAlongside(tender,ship) then alongside=true
            elseif not bestRecord or record.started<bestRecord.started
                or (record.started==bestRecord.started and id<best:getSignature()) then
                best,bestRecord=ship,record
            end
        end
    end
    return best,bestRecord,alongside
end

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

local ORDERED_TENDER_MOVING_SPEED=15

local function tenderIsMoving(tender)
    local velocity=tender.Physics and tender.Physics.Velocity
    if not velocity then return false end
    return math.sqrt(velocity.x*velocity.x+velocity.y*velocity.y+velocity.z*velocity.z)>ORDERED_TENDER_MOVING_SPEED
end

-- A tender on a player order other than supply keeps that order. While it is
-- stationary it serves ships already alongside, but never travels for a request.
local function serveAlongsideOnly(self,tender,now)
    if tenderIsMoving(tender) then return end
    local available=math.max(0,(settings(self).Slots or 1)-usedSlots(self,tender))
    local request,ship=chooseRequest(self,tender,nil,true,available,now)
    if request and ship then acceptRequest(self,tender,ship,request,now) end
end

function RTS:UpdateFieldSupport(now,threatOf)
    self.FleetServiceRequests=self.FleetServiceRequests or {}
    pruneRequests(self)
    local ships=self:GetShipList()
    local intake={}
    for _,tender in ipairs(ships) do
        if self:IsFieldTender(tender) and self.PossessedSignature~=tender:getSignature() then
            local order=(self.UserOrders or {})[tender:getSignature()]
            if not order or order.kind=='supply' or not tenderIsMoving(tender) then intake[#intake+1]=tender end
        end
    end
    enqueueAutomaticRequests(self,intake,ships,now)
    for _,tender in ipairs(ships) do
        if self:IsFieldTender(tender) and self.PossessedSignature~=tender:getSignature() then
            local id=tender:getSignature()
            sweepTenderDock(self,tender,now)
            local order=(self.UserOrders or {})[id]
            if not order or order.kind=='supply' then
                local used=usedSlots(self,tender)
                local displaced,displacedRecord,alongside
                if used>0 then displaced,displacedRecord,alongside=displacedVisitor(self,tender) end
                if displaced then
                    if alongside then
                        self:CancelFleetServiceForShip(displaced,displacedRecord.pendingOrder)
                        self:RestoreFleetServiceRequest(displaced,displacedRecord.request)
                        self:HoldDockedTender(tender)
                    else
                        moveTender(self,tender,displaced,now)
                    end
                else
                    local available=math.max(0,(settings(self).Slots or 1)-used)
                    local request,ship=chooseRequest(self,tender,order,used>0,available,now)
                    if used>0 then self:HoldDockedTender(tender) end
                    if request and ship then
                        releaseOtherAssignments(self,id,ship:getSignature())
                        if request.assignedTender~=id then request.assignedAt=now end
                        request.assignedTender=id
                        if self:IsTenderAlongside(tender,ship) then acceptRequest(self,tender,ship,request,now)
                        elseif used==0 then moveTender(self,tender,ship,now) end
                    elseif order and used==0 then
                        self:ClearUserOrder(tender)
                        self:ReturnToDefaultControl(tender)
                    end
                end
            else
                serveAlongsideOnly(self,tender,now)
            end
        end
    end
end

return RTS
