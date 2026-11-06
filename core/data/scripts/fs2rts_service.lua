-- Individual survival and finite, paid tender fleet services.
local R=require 'fs2rts_state'
local RTS=R
local U=require 'fs2rts_util'
local alive,vec=U.shipAlive,U.vec
local function config(self) return self.Config.Station.FleetService end
local function hull(ship) return ship.HitpointsLeft/math.max(1,ship.HitpointsMax) end
-- Service owns the ship until completion or a fresh command cancels it.
local function servicePriority()
    return 0.97
end

local function validOrderType(order)
    if order:isValid() then return order:getType() end
    return nil
end

local function holdServiceShip(self,ship,service,focused,now,arrivedNow)
    local priority=servicePriority()
    if arrivedNow then
        ship:clearOrders()
        local physics=ship.Physics
        if physics and not focused then physics.Velocity=vec(0,0,0); physics.RotationalVelocity=vec(0,0,0) end
        if ship:giveOrder(ORDER_STAY_STILL,nil,nil,priority)~=true then
            service.arrived=false; service.holdSince=nil
            self:SetFleetServicePhase(ship,service,'ORDER_FAILED',now)
            return false
        end
    elseif not self.Paused and not focused then
        local physics=ship.Physics
        local velocity=physics and physics.Velocity
        if velocity then physics.Velocity=vec(velocity.x*.35,velocity.y*.35,velocity.z*.35) end
    end
    local holding=false
    for i=1,#ship.Orders do
        local order=ship.Orders[i]
        if order then
            local valid,kind=pcall(validOrderType,order)
            if valid and kind==ORDER_STAY_STILL then holding=true end
        end
    end
    if not holding then
        service.holdSince=now
        ship:clearOrders()
        if ship:giveOrder(ORDER_STAY_STILL,nil,nil,priority)~=true then
            self:SetFleetServicePhase(ship,service,'ORDER_FAILED',now)
            return false
        end
    end
    return true
end
local function baseAttackRules(self) return config(self).BaseAttack or {} end

-- Remembers when a faction's command station last lost hull or shield between two
-- service ticks. Absolute amounts are compared, so a larger maximum after an upgrade
-- does not read as damage and regeneration never does.
local function watchStation(self,kind,now)
    local station=self:GetFactionCommandShip(kind)
    if not alive(station) then self.BaseAttackWatch[kind]=nil; return end
    local rules=baseAttackRules(self)
    local watch=self.BaseAttackWatch[kind] or {}
    self.BaseAttackWatch[kind]=watch
    local shields=station.Shields
    local shieldLeft=shields and shields.CombinedLeft or 0
    local shieldMax=shields and shields.CombinedMax or 0
    local hullLost=watch.hull~=nil and watch.hull-station.HitpointsLeft>=station.HitpointsMax*(rules.HullDrop or .002)
    local shieldLost=watch.shield~=nil and shieldMax>0 and watch.shield-shieldLeft>=shieldMax*(rules.ShieldDrop or .02)
    if hullLost or shieldLost then watch.hitAt=now end
    watch.hull=station.HitpointsLeft; watch.shield=shieldLeft
end

function RTS:IsBaseUnderAttack(kind,now)
    local watch=self.BaseAttackWatch and self.BaseAttackWatch[kind]
    return watch~=nil and watch.hitAt~=nil and now-watch.hitAt<=(baseAttackRules(self).WindowSeconds or 20)
end

local function releaseVisitDock(self,ship,service)
    local tender=self:FindShipBySignature(service.serviceAnchor)
    if tender then self:ReleaseTenderDock(tender,ship) end
end

-- Ends a visit early and hands the ship back to its parked player order or to the
-- planner. The retry delay keeps it from walking straight back to the pad.
local function InterruptFleetService(self,ship,s,now,reason,threat)
    local sid=ship:getSignature(); local kind=self:GetFactionKey(ship)
    local parked=self.UserOrders and self.UserOrders[sid]
    releaseVisitDock(self,ship,s)
    self.FleetServices[sid]=nil
    self:SetShipCommandDiscipline(ship,false); self:SetShipTurretLock(ship,false)
    self.AIOrderState[sid]=nil; self.PolicyApplied[sid]=nil
    s.destination=nil; s.destinationAnchor=nil; s.holdSince=nil
    self:EmitAIEvent('FLEET_SERVICE_INTERRUPTED',{ship=sid,faction=kind,
        phase=s.phase,reason=reason,
        threat=alive(threat) and threat:getSignature() or nil,
        spent=s.spent,hull=hull(ship)},now)
    self.FleetServiceCooldown[sid]=now+(config(self).RetrySeconds or 30)
    ship:clearOrders()
    local resume=parked~=nil and parked.kind~='service' and parked or nil
    if resume~=nil then self.UserOrders[sid]=resume end
    if kind=='BLUE' then
        if resume~=nil then self:ReissueUserOrder(ship,resume) else self:ReturnToDefaultControl(ship) end
    else self:AssignAIStrategicOrder(ship,kind,true) end
end

function RTS:IsFleetServiceShip(ship)
    return alive(ship) and ship.Name~=self.Config.ObserverShip
        and not self:IsCommandStation(ship) and not self:IsStaticDefense(ship)
        and self:GetFactionKey(ship)~=nil
end

function RTS:GetFleetAmmo(ship)
    local banks={}; local low=1
    for _,list in ipairs({ship.PrimaryBanks,ship.SecondaryBanks}) do
        for i=1,#list do
            local b=list[i]
            if b.AmmoMax>0 then banks[#banks+1]=b; low=math.min(low,b.AmmoLeft/b.AmmoMax) end
        end
    end
    return low,banks
end

-- Fraction of a bomber's heavy ordnance left, over all of its secondary banks that carry
-- weapons of at least BomberOrdnanceCargoSize. GetFleetAmmo reports the emptiest bank, so a
-- bomber that has fired one of two torpedo banks reads 0 with half its torpedoes still
-- loaded; this sums rounds instead. Returns nil for a ship with no such bank.
function RTS:GetBomberOrdnanceAmmo(ship)
    local minimum=config(self).BomberOrdnanceCargoSize
    local left,max=0,0
    local banks=ship.SecondaryBanks
    for i=1,#banks do
        local bank=banks[i]
        local weapon=bank.WeaponClass
        if bank.AmmoMax>0 and weapon:isValid() and (weapon.CargoSize or 0)>=minimum then
            left=left+bank.AmmoLeft; max=max+bank.AmmoMax
        end
    end
    if max<=0 then return nil end
    return left/max
end

function RTS:CanStartAmmoService(ship,role)
    -- Bombers and craft without a usable main battery need ordnance to fight.
    -- Otherwise book repair capacity before recalling a healthy ship merely
    -- for missiles: an unlimited queue parked half the fleet behind its base.
    if role=='bomber' then return true end
    local ranges=self:GetShipWeaponRanges(ship)
    if ranges.primary<=0 and ranges.beam<=0 then return true end
    local c=config(self); local kind=self:GetFactionKey(ship); local booked=0
    local function weight(unit)
        local r=self:GetShipRole(unit)
        return (r=='capital' or r=='heavy' or r=='juggernaut') and math.min(2,c.Slots) or 1
    end
    for id in pairs(self.FleetServices or {}) do
        local owner=self:FindShipBySignature(id)
        if alive(owner) and self:GetFactionKey(owner)==kind then booked=booked+weight(owner) end
    end
    return booked+weight(ship)<=c.Slots
end

function RTS:GetFleetSubsystems(ship)
    local systems,lowest,total={},1,0
    for i=1,#ship do
        local sub=ship[i]
        if sub:isValid() and sub.HitpointsMax>0 then
            systems[#systems+1]=sub; total=total+sub.HitpointsMax
            lowest=math.min(lowest,sub.HitpointsLeft/sub.HitpointsMax)
        end
    end
    return lowest,systems,total
end

function RTS:GetFleetLocalThreat(ship)
    local nearest,best=nil,math.huge
    local position=ship.Position; local radius=config(self).DangerRadius
    local px,py,pz=position.x,position.y,position.z
    local faction=self:GetFactionKey(ship); local team=ship.Team
    for _,row in ipairs(self:GetAISpatialCandidates(position,radius)) do
        local other=row.ship
        if alive(other) and other.Name~=self.Config.ObserverShip then
            local distance=self:GetAIContextDistance(row,px,py,pz)
            -- Only a nearer candidate can change the answer. Keep stable tie
            -- order while avoiding IFF/bank reads for the rest of the sphere.
            if distance<=radius and distance<best then
                local profile=row.profile or self:AIProfile(other)
                if profile.armed and distance<=(profile.range or 0)+(ship.Radius or 0)+(other.Radius or 0)+400
                    and self:AIContextEnemies(ship,row,faction,team) then nearest,best=other,distance end
            end
        end
    end
    return nearest
end

function RTS:IsFleetFocusedByHostiles(ship,now)
    local id=ship:getSignature(); local kind=self:GetFactionKey(ship)
    for faction,attackers in pairs((self.AITargetedBy or {})[id] or {}) do
        if faction~=kind then
            for _,attacker in pairs(attackers) do
                if alive(attacker) and self:AreEnemies(ship,attacker)
                    and ship.Position:getDistance(attacker.Position)<=config(self).DangerRadius then return true end
            end
        end
    end
    local hit=self.AIStats and self.AIStats.hits and self.AIStats.hits[id]
    return hit~=nil and hit.hostileTime~=nil
        and now-hit.hostileTime<=(self.Config.AI.Doctrine.FocusEvidenceSeconds or 8)
end

function RTS:GetFleetServiceSummary(kind)
    local active,waiting=0,0
    for id in pairs(self.FleetServiceRequests or {}) do
        local ship=self:FindShipBySignature(id)
        if alive(ship) and self:GetFactionKey(ship)==kind then waiting=waiting+1 end
    end
    for id,s in pairs(self.FleetServices or {}) do
        local ship=self:FindShipBySignature(id)
        if alive(ship) and self:GetFactionKey(ship)==kind then
            if s.phase=='REPAIR_REARM' or s.phase=='WAIT_CP' then active=active+1 else waiting=waiting+1 end
        end
    end
    return string.format('SERVICE %d active / %d waiting',active,waiting)
end

function RTS:GetFleetServiceLabel(ship)
    if not alive(ship) then return nil end
    local s=self.FleetServices and self.FleetServices[ship:getSignature()]
    if not s then
        local request=self.FleetServiceRequests and self.FleetServiceRequests[ship:getSignature()]
        return request and (request.assignedTender and 'TENDER EN ROUTE' or 'WAITING FOR TENDER') or nil
    end
    return string.format('%s: %s | HULL %d%% / AMMO %d%% / SYS %d%%',s.reason:gsub('_',' '),s.phase:gsub('_',' '),
        math.floor(100*hull(ship)),math.floor(100*self:GetFleetAmmo(ship)),math.floor(100*self:GetFleetSubsystems(ship)))
end

function RTS:SetFleetServicePhase(ship,s,phase,now)
    if s.phase==phase then return end
    s.phase=phase
    self:EmitAIEvent('FLEET_SERVICE',{ship=ship:getSignature(),faction=self:GetFactionKey(ship),
        phase=phase,reason=s.reason,visit=s.visit,hull=hull(ship),ammo=self:GetFleetAmmo(ship)},now)
end

function RTS:BeginFleetService(ship,reason,now,manual,anchorOverride)
    if self.AftermathActive then return false end
    if not self:IsFleetServiceShip(ship) or self:IsFieldTender(ship) then return false end
    local pilot=self.PossessedSignature==ship:getSignature()
    if pilot and (not manual or reason~='PILOT_SERVICE') then return false end
    if self.IsShipWithdrawing and self:IsShipWithdrawing(ship) then return false end
    if not self:IsServiceAnchorFor(ship,anchorOverride) or not self:IsTenderAlongside(anchorOverride,ship) then return false end
    self.FleetServices=self.FleetServices or {}
    local id=ship:getSignature()
    if self.FleetServices[id] then
        local current=self.FleetServices[id]
        current.manual=current.manual or manual==true
        return current.serviceAnchor==anchorOverride:getSignature()
    end
    local station=anchorOverride
    -- Release any prior move lock: FSO needs dynamic AI enabled to evade a
    -- locked missile, and its hit reactions preserve the assigned service goal.
    if not pilot then self:SetShipCommandDiscipline(ship,false) end
    local s={reason=reason,started=now,lastUpdate=now,lastHull=ship.HitpointsLeft,
        ammoCredit={},manual=manual==true,spent=0,
        serviceAnchor=station:getSignature(),pilot=pilot}
    self.FleetServiceSerial=(self.FleetServiceSerial or 0)+1; s.visit=self.FleetServiceSerial
    -- Park the prior player order during recovery and restore it on completion.
    local order=self.UserOrders and self.UserOrders[id]
    s.pendingOrder=(not pilot and order and order.kind~='service') and order or nil
    self.FleetServices[id]=s
    if not pilot then self.AIOrderState[id]=nil; self.PolicyApplied[id]=nil end
    if self.RecordServiceStart then self:RecordServiceStart(ship,now) end
    self:SetFleetServicePhase(ship,s,'QUEUED',now)
    if not pilot then self:SetShipCommandDiscipline(ship,false); self:SetShipTurretLock(ship,true) end
    return true
end

-- Public. RTS:SetUserOrder only drops the record, which leaves the service waypoint
-- and its cached slot behind; the input layer calls this to genuinely free a ship
-- for a new task before issuing it, then issues the new order normally. Nothing in
-- this file calls it: the service tick must not cancel itself under the player.
function RTS:CancelFleetServiceForShip(ship,keepOrder)
    if not alive(ship) then return false end
    self.FleetServices=self.FleetServices or {}
    local id=ship:getSignature()
    local s=self.FleetServices[id]
    if not s then return false end
    releaseVisitDock(self,ship,s)
    if s.pilot then self.FleetServices[id]=nil; return true end
    self.FleetServices[id]=nil; self.AIOrderState[id]=nil; self.PolicyApplied[id]=nil
    self:SetShipCommandDiscipline(ship,false); self:SetShipTurretLock(ship,false)
    s.destination=nil; s.destinationAnchor=nil; s.holdSince=nil
    local current=self.UserOrders[id]
    local order=keepOrder or (current and current.kind~='service' and current) or s.pendingOrder
    if order then
        self.UserOrders[id]=order
        self:ReissueUserOrder(ship,order)
        return true
    end
    self.UserOrders[id]=nil
    ship:clearOrders()
    return true
end

function RTS:FinishFleetService(ship,s,now)
    local id=ship:getSignature()
    self:SetFleetServicePhase(ship,s,'READY',now)
    if self.RecordServiceFinish then self:RecordServiceFinish(ship,now,s) end
    releaseVisitDock(self,ship,s)
    if s.pilot then
        self.FleetServices[id]=nil
        self.FleetServiceCooldown[id]=now+config(self).RetrySeconds
        self.PilotSupportNotice={text='TENDER SERVICE COMPLETE',untilTime=self:UINow()+3}
        return
    end
    self.FleetServices[id]=nil; self.AIOrderState[id]=nil; self.PolicyApplied[id]=nil
    self:SetShipCommandDiscipline(ship,false); self:SetShipTurretLock(ship,false)
    self.FleetServiceCooldown[id]=now+config(self).RetrySeconds
    -- A finished automatic visit starts a downtime before the hull may be requested again.
    self.FieldServiceReadyAt=self.FieldServiceReadyAt or {}
    self.FieldServiceReadyAt[id]=now+((self.Config.FieldSupport.Seek or {}).ServiceDowntimeSeconds or 0)
    -- Existing manual intent survives automatic self-preservation; explicit
    -- SERVICE ends by handing the ship back to its normal owner.
    local order=self.UserOrders[id]
    if order and order.kind=='service' then self:ClearUserOrder(ship); order=nil end
    -- Hand back whatever the player asked for before the ship was pulled in, so
    -- the round trip is a round trip and not a silent order drop.
    if s.pendingOrder then order=s.pendingOrder; self.UserOrders[id]=order end
    ship:clearOrders()
    if self:GetFactionKey(ship)=='BLUE' then
        if order then self:ReissueUserOrder(ship,order) else self:ReturnToDefaultControl(ship) end
    else self:AssignAIStrategicOrder(ship,self:GetFactionKey(ship),true) end
end

-- Countermeasures and afterburner fuel are restocked for free during a visit, at a
-- rate that fills an empty reserve within MinimumRecoverySeconds.
local function restockedAmount(state,key,left,max,dt,seconds,whole)
    if type(left)~='number' or type(max)~='number' or max<=0 or left>=max then return 0 end
    local credit=(state[key] or 0)+max*dt/math.max(1,seconds)
    local amount=credit
    if whole then amount=math.floor(credit) end
    state[key]=credit-amount
    return math.min(amount,max-left)
end

local function restockConsumables(ship,state,dt,seconds)
    local class=ship.Class
    if not class then return end
    local countermeasures=restockedAmount(state,'countermeasureCredit',ship.CountermeasuresLeft,class.CountermeasuresMax,dt,seconds,true)
    if countermeasures>0 then ship.CountermeasuresLeft=ship.CountermeasuresLeft+countermeasures end
    local fuel=restockedAmount(state,'afterburnerCredit',ship.AfterburnerFuelLeft,class.AfterburnerFuelMax,dt,seconds,false)
    if fuel>0 then ship.AfterburnerFuelLeft=ship.AfterburnerFuelLeft+fuel end
end

-- The visit used up its time budget while others wait: the ship goes back to the queue,
-- automatic and ranked lower for each turn it has already had.
local function rotateFleetVisit(self,ship,s,now)
    local request=s.request
    self:EmitAIEvent('FLEET_SERVICE_INTERRUPTED',{ship=ship:getSignature(),faction=self:GetFactionKey(ship),
        phase=s.phase,reason='VISIT_LIMIT',spent=s.spent,hull=hull(ship)},now)
    self:CancelFleetServiceForShip(ship,s.pendingOrder)
    if request then
        request.manual=false
        request.rotations=(request.rotations or 0)+1
        self:RestoreFleetServiceRequest(ship,request)
    end
end

function RTS:ServiceFleetShip(ship,s,station,now,slots,threat)
    local c=config(self); local dt=math.min(c.TickSeconds*2,math.max(0,now-s.lastUpdate))
    local readyHull=s.manual and 1 or c.ReadyHull
    s.lastUpdate=now
    local hitNow=ship.HitpointsLeft<s.lastHull-.01
    s.lastHull=ship.HitpointsLeft
    if not self:IsServiceAnchorFor(ship,station) then
        self:SetFleetServicePhase(ship,s,'TENDER_LOST',now)
        return 0
    end
    local focused=self:IsFleetFocusedByHostiles(ship,now)
    if not self:IsTenderAlongside(station,ship) then
        s.arrived=false
        self:SetFleetServicePhase(ship,s,'TENDER_EN_ROUTE',now)
        return 0
    end
    local arrivedNow=not s.arrived
    if arrivedNow then
        s.arrived=true; s.holdSince=now; dt=0
    end
    -- Support-ship rule: a requester that is hit while its hull is below AbortHull
    -- breaks off the service.
    if not s.pilot and hitNow and hull(ship)<(c.AbortHull or .30) then
        InterruptFleetService(self,ship,s,now,'HIT_BELOW_ABORT_HULL',threat)
        return 0
    end
    if not s.pilot and not holdServiceShip(self,ship,s,focused,now,arrivedNow) then return 0 end
    -- Arrival is physical. Time spent travelling/queued never accumulates repair.
    local ammo,banks=self:GetFleetAmmo(ship)
    local observer
    if s.pilot then
        observer=self:GetObserver()
        if not alive(observer) then self:SetFleetServicePhase(ship,s,'PILOT_PROXY_LOST',now); return 0 end
        ammo,banks=1,{}
        for _,list in ipairs({ship.PrimaryBanks,observer.SecondaryBanks}) do
            for i=1,#list do
                local bank=list[i]
                if bank.AmmoMax>0 then banks[#banks+1]=bank; ammo=math.min(ammo,bank.AmmoLeft/bank.AmmoMax) end
            end
        end
    end
    local subsystemHealth,systems,totalSubsystemHull=self:GetFleetSubsystems(ship)
    if now-s.started>=c.MinimumRecoverySeconds and hull(ship)>=readyHull-.0001 and ammo>=c.ReadyAmmo and subsystemHealth>=readyHull-.0001
        then self:FinishFleetService(ship,s,now); return 0 end
    local role=self:GetShipRole(ship)
    local weight=(role=='capital' or role=='heavy' or role=='juggernaut') and math.min(2,c.Slots) or 1
    if slots<weight then self:SetFleetServicePhase(ship,s,'QUEUED',now); return 0 end
    -- Dockable pairs are serviced only while docked: nothing is repaired or rearmed
    -- on the approach, and the visit keeps its slot until the dock completes.
    if not s.pilot and self:IsDockedServiceRequired(station,ship) and not station:isDocked(ship) then
        self:SetFleetServicePhase(ship,s,'DOCKING',now)
        return weight
    end
    s.workSeconds=(s.workSeconds or 0)+dt
    local value=math.max(1,self:GetStrategicUnitValue(ship,self:GetFactionKey(ship)))
    local budget=self:GetFactionCP(self:GetFactionKey(ship)); local spent=0; local budgetBlocked=false
    local missing=math.max(0,readyHull*ship.HitpointsMax-ship.HitpointsLeft)
    local heal=math.min(missing,ship.HitpointsMax*c.HullPerSecond*dt,budget/value/c.HullCostFraction*ship.HitpointsMax)
    if heal>0 then
        spent=heal/ship.HitpointsMax*value*c.HullCostFraction
        if self:SpendFactionCP(self:GetFactionKey(ship),spent) then ship.HitpointsLeft=ship.HitpointsLeft+heal else heal=0; spent=0 end
    end
    local systemRepair=0
    for _,sub in ipairs(systems) do
        local missingSub=math.max(0,readyHull*sub.HitpointsMax-sub.HitpointsLeft)
        local rate=value*c.SubsystemCostFraction/math.max(1,totalSubsystemHull)
        local amount=math.min(missingSub,sub.HitpointsMax*c.SubsystemPerSecond*dt,self:GetFactionCP(self:GetFactionKey(ship))/rate)
        if amount>0 and self:SpendFactionCP(self:GetFactionKey(ship),amount*rate) then
            sub.HitpointsLeft=sub.HitpointsLeft+amount; spent=spent+amount*rate; systemRepair=systemRepair+amount
        end
    end
    local bankCount=math.max(1,#banks)
    for i,b in ipairs(banks) do
        local want=math.max(0,math.ceil(b.AmmoMax*c.ReadyAmmo)-b.AmmoLeft)
        if want>0 then
            -- Native AmmoLeft is integer; carry fractional rounds only while
            -- actually receiving service, never while travelling or waiting.
            local credit=(s.ammoCredit[i] or 0)+b.AmmoMax*c.AmmoPerSecond*dt
            local cost=value*c.AmmoCostFraction/bankCount/math.max(1,b.AmmoMax)
            local rounds=math.min(want,math.floor(credit),math.floor(self:GetFactionCP(self:GetFactionKey(ship))/cost))
            if math.floor(credit)>0 and rounds==0 then budgetBlocked=true end
            s.ammoCredit[i]=credit-math.floor(credit)
            if rounds>0 and self:SpendFactionCP(self:GetFactionKey(ship),rounds*cost) then
                b.AmmoLeft=b.AmmoLeft+rounds; spent=spent+rounds*cost
            end
        end
    end
    restockConsumables(ship,s,dt,c.MinimumRecoverySeconds)
    if s.pilot then ship.SecondaryBanks=observer.SecondaryBanks end
    s.spent=s.spent+spent; s.hullRepaired=(s.hullRepaired or 0)+heal; s.lastHull=ship.HitpointsLeft
    self:SetFleetServicePhase(ship,s,(budgetBlocked or self:GetFactionCP(self:GetFactionKey(ship))<=.001) and 'WAIT_CP' or 'REPAIR_REARM',now)
    if spent>0 then
        self:EmitAIEvent('FLEET_SERVICE_WORK',{ship=ship:getSignature(),faction=self:GetFactionKey(ship),
            healed=heal,subsystemRepair=systemRepair,spent=spent,totalSpent=s.spent,hull=hull(ship),ammo=self:GetFleetAmmo(ship)},now)
    end
    if not s.pilot and s.workSeconds>=(c.VisitSeconds or math.huge) and self:HasWaitingServiceRequest(station,ship) then
        rotateFleetVisit(self,ship,s,now)
        return 0
    end
    return weight
end

-- Destroyed subsystems slowly repair themselves once the ship has taken no
-- hull, shield or subsystem damage for RegenQuietSeconds. Ships docked for paid
-- service are left to ServiceFleetShip.
function RTS:UpdateSubsystemRegen(now)
    if self.AftermathActive or now<(self.NextSubsystemRegen or 0) then return end
    local c=config(self); local dt=math.min(now-(self.LastSubsystemRegen or now),2)
    self.NextSubsystemRegen=now+1; self.LastSubsystemRegen=now
    local state=self.SubsystemRegen or {}; self.SubsystemRegen=state
    local seen={}
    for _,ship in ipairs(self:GetShipList()) do
        if self:IsFleetServiceShip(ship) then
            local id=ship:getSignature(); seen[id]=true
            local s=state[id]; if not s then s={quietAt=now,dead={}}; state[id]=s end
            local shields=ship.Shields and ship.Shields.CombinedLeft or 0
            local sum,hit=0,ship.HitpointsLeft<(s.hull or ship.HitpointsLeft)-.01 or shields<(s.shields or shields)-.01
            for i=1,#ship do
                local sub=ship[i]
                if sub:isValid() and sub.HitpointsMax>0 then
                    sum=sum+sub.HitpointsLeft
                    if sub.HitpointsLeft<=0 then s.dead[i]=true end
                end
            end
            if hit or sum<(s.sub or sum)-.01 then s.quietAt=now end
            if now-s.quietAt>=c.RegenQuietSeconds and not (self.FleetServices or {})[id] then
                for i in pairs(s.dead) do
                    local sub=ship[i]
                    if sub:isValid() then
                        sub.HitpointsLeft=math.min(sub.HitpointsMax,sub.HitpointsLeft+sub.HitpointsMax*c.RegenPerSecond*dt)
                        if sub.HitpointsLeft>=sub.HitpointsMax then s.dead[i]=nil end
                    else s.dead[i]=nil end
                end
                sum=0
                for i=1,#ship do if ship[i]:isValid() and ship[i].HitpointsMax>0 then sum=sum+ship[i].HitpointsLeft end end
            end
            s.hull=ship.HitpointsLeft; s.shields=shields; s.sub=sum
        end
    end
    for id in pairs(state) do if not seen[id] then state[id]=nil end end
end

function RTS:UpdateFleetServices(now)
    if self.AftermathActive then return end
    local c=config(self)
    if now<(self.NextFleetServiceThink or 0) then return end
    self.NextFleetServiceThink=now+c.TickSeconds
    self.FleetServices=self.FleetServices or {}; self.FleetServiceCooldown=self.FleetServiceCooldown or {}
    self.SurvivalDangerSince=self.SurvivalDangerSince or {}
    self.BaseAttackWatch=self.BaseAttackWatch or {}
    for _,kind in ipairs(self:GetFactionKeys()) do watchStation(self,kind,now) end
    local ships={}; self:EachShip(function(ship) if self:IsFleetServiceShip(ship) then ships[#ships+1]=ship end end)
    -- One spatial context per service tick, shared with local strength queries.
    local owned=self.StrategicThreatSnapshot==nil
    local function ensureContext()
        if not self.StrategicThreatSnapshot then
            self.StrategicThreatSnapshot=self:BuildStrategicThreatSnapshot()
            self:BuildAIContext(self.StrategicThreatSnapshot)
        end
    end
    local function localThreat(ship)
        ensureContext()
        return self:GetFleetLocalThreat(ship)
    end
    -- Active visits also read targeting evidence when their remembered threat
    -- survives, so they need a fresh context even without a nearest-threat scan.
    if next(self.FleetServices) then ensureContext() end
    local threats={}; local present={}
-- Signatures currently holding a committed base strike inside their own beam
-- reach. Populated during the dispatch loop, read by the outmatched reasons
-- and by HULL_LOW. Local to the pass so a stale entry cannot survive a frame.
local assaultHold={}
    for _,ship in ipairs(ships) do
        local id=ship:getSignature(); present[id]=true
        -- Keep the pad latched, but danger must describe the visitor's current
        -- location; a living attacker elsewhere cannot hold a ready crew here.
        local rec=self.FleetServices[id]
        local hp=hull(ship)
        -- Outmatched recovery requires hull below ReturnHull. Healthy focus
        -- cannot use a strength result; ammo/subsystem admission still samples
        -- danger below before it actually starts service. Active visits always
        -- retain their safety scans.
        local needsDanger=rec~=nil or (self.PossessedSignature~=id and not self.UserOrders[id]
            and hp<c.ReturnHull)
        local threat=nil
        if needsDanger then
            threat=localThreat(ship)
            if rec then rec.threatSignature=threat and threat:getSignature() or nil end
        end
        threats[id]=threat
        if self.PossessedSignature~=id and not rec then
            local ammo=self:GetFleetAmmo(ship)
            local reason
            local pressured=alive(threat)
            local friend,enemy=0,0
            if pressured then friend,enemy=self:AILocalStrength(ship,ship.Position,c.DangerRadius,false,threat) end
            local role=self:GetShipRole(ship)
            local strikeRole=role=='bomber' or role=='capital' or role=='heavy' or role=='juggernaut'
            -- A base's large hull is not evidence that a healthy siege unit
            -- loses its intended matchup. Mobile opposition still triggers
            -- the local force test; damage always triggers recovery.
            local siegeMatchup=strikeRole and pressured and (self:IsCommandStation(threat)
                or self:IsStaticDefense(threat) or self:IsCapitalTarget(threat))
            local outmatched=pressured and not siegeMatchup and enemy>math.max(1,friend)*c.DisadvantageRatio
            -- Does this hull currently hold a committed strike on a station
            -- inside its own reach? Computed here because both the outmatched
            -- reasons below and HULL_LOW further down need the same answer, and
            -- the outmatched test is what the commitment is meant to survive.
            local holding=false
            do
                local doctrine=(self.Config.AI and self.Config.AI.Doctrine) or {}
                if doctrine.AssaultHoldEnabled~=false then
                    local aiOrder=self.AIOrderState and self.AIOrderState[id]
                    if aiOrder and (aiOrder.mission=='PRIMARY' or aiOrder.mission=='ESCORT') then
                        local objective=self:FindShipBySignature(aiOrder.targetSignature)
                        -- isValid presence is checked explicitly: this is a hot
                        -- path and the objective is whatever the AI last recorded,
                        -- so it must not be trusted to be a full engine object.
                        if alive(objective) and type(objective.isValid)=="function" and self:IsCommandStation(objective) then
                            -- Read the PREBUILT profile index, never AIProfile().
                            -- AIProfile walks every bank of every turret of every
                            -- subsystem, so calling it per ship here would rebuild
                            -- the whole strategic picture once per hull per service
                            -- pass. A missing entry simply falls back to the
                            -- configured hold distance.
                            local profile=(self.AIProfileIndex or {})[id]
                            local reach=math.max(doctrine.AssaultHoldDistance or 8000,(profile and profile.range) or 0)
                            holding=ship.Position:getDistance(objective.Position)<=reach
                        end
                    end
                end
            end
            if holding then assaultHold[id]=true end
            local focused=pressured and self:IsFleetFocusedByHostiles(ship,now)
            if outmatched and focused then self.SurvivalDangerSince[id]=self.SurvivalDangerSince[id] or now else self.SurvivalDangerSince[id]=nil end
            local order=self.UserOrders[id]
            local retryReady=now>=(self.FleetServiceCooldown[id] or 0)
            -- Explicit commands own even a critically damaged hull. Automatic
            -- recovery is for unassigned ships; the player chooses SERVICE.
            if retryReady and not order and hp<=c.CriticalHull and pressured then reason='SELF_PRESERVATION'
        elseif retryReady and not order and focused and outmatched and not assaultHold[ship:getSignature()]
            and hp<c.ReturnHull and enemy>math.max(1,friend)*c.AvoidFightRatio then reason='AVOID_OVERWHELMING_FIGHT'
        elseif retryReady and not order and focused and outmatched and not assaultHold[ship:getSignature()]
            and hp<c.ReturnHull and now-(self.SurvivalDangerSince[id] or now)>=c.DangerSeconds then reason='OUTMATCHED'
            elseif not order and retryReady then
                local aiOrder=self.AIOrderState and self.AIOrderState[id]
                local objective=aiOrder and self:FindShipBySignature(aiOrder.targetSignature)
                -- A committed strike is a real operating regime, not just an
                -- ammo exception. HULL_LOW used to fire at ReturnHull (0.40)
                -- UNPRESSURED, so it was the dominant reason a committed
                -- heavy or juggernaut turned back, and the two outmatched
                -- reasons pulled a committed escort off while its own beams
                -- were already landing. The commitment is GEOMETRIC, not a
                -- timer: inside the range where this hull's own beams reach the
                -- station, retreating throws that damage away. Outside it, the
                -- old thresholds apply unchanged.
                local committedBase=aiOrder and (aiOrder.mission=='PRIMARY' or aiOrder.mission=='ESCORT')
                    and alive(objective) and self:IsCommandStation(objective)
                local ammoThreshold=committedBase and c.CommittedStrikeReturnAmmo or role=='fighter' and c.FighterReturnAmmo or c.ReturnAmmo
                -- Order of priority: a damaged hull, damaged systems, then ammunition.
                -- Every ship but a bomber keeps its primary guns when its ordnance runs
                -- out, so rearming is optional for it and never pulls it out of a fight.
                -- A bomber's ordnance is its weapon, so it still goes.
                local ammoLevel=ammo
                if role=='bomber' then ammoLevel=self:GetBomberOrdnanceAmmo(ship) or ammo end
                local ammoLow=ammoLevel<ammoThreshold and self:CanStartAmmoService(ship,role)
                if ammoLow and role~='bomber' and not threat then threat=localThreat(ship); threats[id]=threat end
                local keepsFighting=ammoLow and role~='bomber' and alive(threat)
                if hp<(holding and c.AssaultHullFloor or c.ReturnHull) then reason='HULL_LOW'
                elseif self:GetFleetSubsystems(ship)<c.ReturnHull then reason='SYSTEMS_DAMAGED'
                elseif ammoLow and not keepsFighting then reason='AMMO_LOW' end
            end
            if reason and not threat then threat=localThreat(ship); threats[id]=threat end
            if reason then self:RequestFleetService(ship,reason,now,false) end
        end
    end
    self:UpdateFieldSupport(now,localThreat)
    table.sort(ships,function(a,b)
        local sa,sb=self.FleetServices[a:getSignature()],self.FleetServices[b:getSignature()]
        if (sa~=nil)~=(sb~=nil) then return sa~=nil end
        if sa and sb and (sa.prioritized==true)~=(sb.prioritized==true) then return sa.prioritized==true end
        if sa and sb and sa.started~=sb.started then return sa.started<sb.started end
        if sa and sb then
            local pa,pb=self:GetFleetServiceCrewPriority(a,sa),self:GetFleetServiceCrewPriority(b,sb)
            if pa~=pb then return pa>pb end
        end
        return a:getSignature()<b:getSignature()
    end)
    local slots={}
    for _,ship in ipairs(ships) do
        local id=ship:getSignature(); local s=self.FleetServices[id]
        if s and (self.PossessedSignature~=id or s.pilot) then
            if not threats[id] then threats[id]=localThreat(ship) end
            local anchor=self:GetFleetServiceAnchor(ship,s)
            if not anchor then
                local request=s.request
                self:CancelFleetServiceForShip(ship,s.pendingOrder)
                if request then self:RestoreFleetServiceRequest(ship,request) end
            else
                local key=anchor:getSignature()
                if slots[key]==nil then slots[key]=self.Config.FieldSupport.Slots end
                slots[key]=slots[key]-self:ServiceFleetShip(ship,s,anchor,now,slots[key],threats[id])
            end
        end
    end
    for id in pairs(self.FleetServices) do if not present[id] then self.FleetServices[id]=nil; self.SurvivalDangerSince[id]=nil; self.FleetServiceCooldown[id]=nil end end
    -- Drop the whole AI context, not just the snapshot. BuildAIContext above
    -- repopulated AIShipIndex/AIProfileIndex/AITargetedBy/AISpatialGrid/
    -- AILocalCache from this pass; leaving them set let every reader outside a
    -- strategic window consume a grid and index from an unrelated, up-to-2s
    -- old pass. UpdateAIStrategicObjectives clears the same set the same way.
    if owned then
        self.StrategicThreatSnapshot=nil
        self.AIShipIndex=nil; self.AIProfileIndex=nil; self.AITargetedBy=nil
        self.AISpatialGrid=nil; self.AILocalCache=nil
    end
end

function RTS:GetFleetServiceCrewPriority(ship,service)
    local c=config(self); local role=self:GetShipRole(ship)
    local slots=(role=='capital' or role=='heavy' or role=='juggernaut') and math.min(2,c.Slots) or 1
    local exposure=self:GetCrewExposureEstimate(ship)
    return exposure*math.max(0,(service.manual and 1 or c.ReadyHull)-hull(ship))/math.max(1,slots)
end

function RTS:ServiceSelected()
    local count=0; local now=mn.getMissionTime()
    for _,ship in ipairs(self:GetSelectedFriendlyShips()) do
        if self:RequestFleetService(ship,'PLAYER_SERVICE',now,true) then count=count+1 end
    end
    self:SetStatus(count>0 and ('Support requested for '..count..' ships; tenders will come to them') or 'No selected ships can request tender service',3)
end

return R
