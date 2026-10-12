-- Match-local identities, confirmed fates, and player-ordered extraction.
local R=require 'fs2rts_state'
local U=require 'fs2rts_util'
local alive,valid,vec,copy=U.shipAlive,U.shipValid,U.vec,U.copyVec
local crewBands={fighter=1,bomber=1,escort=2,capital=3,heavy=4,juggernaut=4}
local crewBandLabels={'SMALL','MEDIUM','LARGE','VERY LARGE'}

function R:GetCrewExposureEstimate(ship)
    local band=crewBands[self:GetShipRole(ship)] or 1
    return band,crewBandLabels[band]
end

function R:ResetFleetLife()
    self.UnitHistory={}; self.HistoryBySignature={}; self.WingHistory={}; self.HistorySerial=0; self.TerminalShipSignatures={}
    self.Withdrawals={}; self.Rearguards={}; self.ExtractionAreas={}; self.ExtractionOperations={}; self.ExtractionExtent=nil; self.FactionStationRadii={}
    self.AllowWithdrawal={}; self.PassageTurretOverrides={}; self.NextFleetLife=0
    self.StrategicResult=nil; self.PlayerStationLostAt=nil; self.PlayerDefeatShown=false
    self.FleetRecoveryNotice=nil; self.FleetFateFinal=false; self.ReportPage='SUMMARY'; self.ReportOffset=0
    self.CrewProjectileBefore=nil
    self.FleetCitationNotice=nil
end

function R:GetUnitHistory(ship)
    if not valid(ship) then return nil end
    local id=self.HistoryBySignature and self.HistoryBySignature[ship:getSignature()]
    return id and self.UnitHistory[id] or nil
end

function R:RecordShipCreated(ship,newCommission)
    if not alive(ship) or ship.Name==self.Config.ObserverShip or self:IsCommandStation(ship) or self:IsStaticDefense(ship) then return nil end
    self.UnitHistory=self.UnitHistory or {}; self.HistoryBySignature=self.HistoryBySignature or {}
    local old=self:GetUnitHistory(ship)
    if (self.TerminalShipSignatures or {})[ship:getSignature()] and not newCommission then return old end
    if old and old.fate=='PRESENT' then return old end
    local faction=self:GetFactionKey(ship); if not faction then return nil end
    -- Death dedupe belongs to the commissioned lifetime, not a reused slot.
    if self.BountyProcessed then self.BountyProcessed[ship:getSignature()]=nil end
    if self.TerminalShipSignatures then self.TerminalShipSignatures[ship:getSignature()]=nil end
    self.HistorySerial=(self.HistorySerial or 0)+1
    local id='SHIP '..self.HistorySerial
    local record={id=id,signature=ship:getSignature(),faction=faction,class=ship.Class.Name,name=ship.Name,
        commissionedAt=mn.getMissionTime(),lowestHull=ship.HitpointsLeft/math.max(1,ship.HitpointsMax),
        recoveries=0,serviceVisits=0,pilotSeconds=0,fate='PRESENT'}
    local _,label=self:GetCrewExposureEstimate(ship); record.crewExposureEstimate=label
    self.UnitHistory[id]=record; self.HistoryBySignature[record.signature]=id
    return record
end

function R:RecordWingHistory(wing)
    self.WingHistory=self.WingHistory or {}
    local history=self.WingHistory[wing.id]
    if not history then history={id=wing.id,label=wing.label,members={}}; self.WingHistory[wing.id]=history end
    for _,signature in ipairs(wing.signatures) do
        local ship=self:FindShipBySignature(signature); local r=self:GetUnitHistory(ship) or self:RecordShipCreated(ship)
        if r and not r.originalWing then r.originalWing=wing.id; history.members[#history.members+1]=r.id end
    end
end

function R:RecordServiceStart(ship,now)
    local r=self:GetUnitHistory(ship) or self:RecordShipCreated(ship)
    if r then
        r.serviceEntryHull=ship.HitpointsLeft/math.max(1,ship.HitpointsMax)
        local threshold=self.Config.Station.FleetService.ReturnHull
        r.serviceCitationEligible=not r.friendlyDamageEpisode and r.serviceEntryHull<=threshold
            and (r.hostileProjectileHull or 0)>=1-threshold
    end
end

function R:RecordServiceFinish(ship,now,service)
    local r=self:GetUnitHistory(ship); if not r then return end
    r.serviceVisits=r.serviceVisits+1
    if r.serviceEntryHull and r.serviceEntryHull<.98 then
        r.recoveries=r.recoveries+1
        if r.faction=='BLUE' then self:SetStatus(r.name..' returned from damaged service',4) end
    end
    if r.serviceCitationEligible and service and (service.hullRepaired or 0)>=ship.HitpointsMax*self.Config.Station.FleetService.ReturnHull then
        r.recoveryRejoinPending=true
    end
    r.serviceCitationEligible=nil; r.hostileProjectileHull=0; r.friendlyDamageEpisode=nil
    r.serviceEntryHull=nil
end

function R:AwardFleetCitation(record,kind,reason)
    record.citations=record.citations or {}
    if record.citations[kind] then return false end
    record.citations[kind]={reason=reason,time=mn.getMissionTime()}
    if record.faction=='BLUE' then self.FleetCitationNotice={name=record.name,reason=reason,untilTime=self:UINow()+8} end
    self:EmitAIEvent('FLEET_CITATION',{history=record.id,ship=record.signature,faction=record.faction,kind=kind,reason=reason})
    return true
end

function R:RegisterCrewProjectileEvidence()
    if self.CrewProjectileEvidenceInstalled then return end
    -- Projectile damage is applied between override evaluation and the normal
    -- collision callback upstream. Beam contacts do not have this ordering.
    local installed=engine.addHook('On Weapon Collision',function()
        local sample=self.CrewProjectileBefore; self.CrewProjectileBefore=nil
        if not sample or hv.Ship~=sample.target or hv.Weapon~=sample.weapon or not valid(sample.target) then return end
        local record=self:GetUnitHistory(sample.target)
        if not record or record.id~=sample.history or record.fate~='PRESENT' then return end
        local removed=math.max(0,sample.hull-sample.target.HitpointsLeft)/math.max(1,sample.target.HitpointsMax)
        if removed<=0 then return end
        if sample.hostile then record.hostileProjectileHull=(record.hostileProjectileHull or 0)+removed
        else record.friendlyDamageEpisode=true; record.serviceCitationEligible=false; record.recoveryRejoinPending=nil end
    end,{},function()
        self.CrewProjectileBefore=nil
        if self.Enabled and not self.SetupActive and not self.CinematicActive then
            local target,weapon=hv.Ship,hv.Weapon
            local source=U.objectValid(weapon) and weapon.Parent or nil
            local record=valid(target) and self:GetUnitHistory(target)
            if record and record.fate=='PRESENT' and valid(source) and source:getBreedName()=='Ship' then
                self.CrewProjectileBefore={target=target,weapon=weapon,history=record.id,hull=target.HitpointsLeft,hostile=self:AreEnemies(source,target)}
            end
        end
        return false
    end)
    self.CrewProjectileEvidenceInstalled=installed==true
    if not installed then self:Log('CREW CITATION EVIDENCE UNAVAILABLE: projectile hook registration failed') end
end

function R:RecordFleetCombatKill(source,target)
    if self.SetupActive or self.CinematicActive or not valid(source) or not valid(target)
        or not self:AreEnemies(source,target) or self:IsCommandStation(target) or self:IsStaticDefense(target) then return end
    local record=self:GetUnitHistory(source)
    if not record or record.fate~='PRESENT' then return end
    if record.recoveryRejoinPending and not self:IsShipWithdrawing(source) and not (self.FleetServices or {})[record.signature] then
        self:AwardFleetCitation(record,'RECOVERY_REJOIN','Recovered from hostile fire and returned to effective combat')
        record.recoveryRejoinPending=nil
    end
    local beneficiary=valid(target.Target) and self:GetUnitHistory(target.Target)
    local withdrawal=beneficiary and (self.Withdrawals or {})[beneficiary.signature]
    if beneficiary and beneficiary.faction==record.faction and beneficiary.id~=record.id
        and beneficiary.fate=='PRESENT' and withdrawal and withdrawal.history==beneficiary.id
        and not withdrawal.departureStarted and not self:IsShipWithdrawing(source) then
        beneficiary.coverContributors=beneficiary.coverContributors or {}
        beneficiary.coverContributors[record.id]=true
    end
end

function R:RecordPilotTime(ship,now,entering)
    local r=self:GetUnitHistory(ship) or self:RecordShipCreated(ship); if not r then return end
    if entering then r.pilotStartedAt=now
    elseif r.pilotStartedAt then r.pilotSeconds=r.pilotSeconds+math.max(0,now-r.pilotStartedAt); r.pilotStartedAt=nil end
end

function R:RecordUnitFate(ship,fate,reason)
    local r=self:GetUnitHistory(ship); if not r or r.fate~='PRESENT' then return false end
    if r.pilotStartedAt then self:RecordPilotTime(ship,mn.getMissionTime(),false) end
    r.fate=fate; r.fateAt=mn.getMissionTime(); r.reason=reason
    if fate=='ESCAPED' then
        for id in pairs(r.coverContributors or {}) do
            local contributor=self.UnitHistory[id]
            if contributor then self:AwardFleetCitation(contributor,'WITHDRAWAL_COVER','Removed a pursuing threat; '..r.name..' escaped') end
        end
    end
    self.TerminalShipSignatures=self.TerminalShipSignatures or {}; self.TerminalShipSignatures[r.signature]=true
    r.afterResult=self.StrategicResult~=nil
    r.withdrawing=self.Withdrawals and self.Withdrawals[r.signature]~=nil or false
    if r.faction=='BLUE' and r.originalWing then
        local wing=self.WingHistory and self.WingHistory[r.originalWing]
        if wing and not wing.lastOriginalFateNotice then
            local present=false
            for _,memberId in ipairs(wing.members) do
                local member=self.UnitHistory[memberId]
                if member and member.fate=='PRESENT' then present=true; break end
            end
            if not present then
                wing.lastOriginalFateNotice=fate
                self:SetStatus('LAST ORIGINAL MEMBER OF '..wing.label..' '..fate,5)
            end
        end
    end
    return true
end

function R:IsShipWithdrawing(ship)
    return valid(ship) and self.Withdrawals and self.Withdrawals[ship:getSignature()]~=nil or false
end

function R:IsAutomaticTargetPermitted(attacker,target)
    if not self.Withdrawals or next(self.Withdrawals)==nil then return true end
    local withdrawal=self.Withdrawals and self.Withdrawals[target:getSignature()]
    return not withdrawal or not withdrawal.inCorridor or (self.AllowWithdrawal or {})[self:GetFactionKey(attacker)]==false
end

function R:IsAutomaticTargetInArena(attacker,target,position)
    local withdrawal=self.Withdrawals and next(self.Withdrawals) and self.Withdrawals[target:getSignature()]
    if withdrawal and withdrawal.inCorridor and (self.AllowWithdrawal or {})[self:GetFactionKey(attacker)]==false then return true end
    local p=position or target.Position
    if not self:IsFiniteVector(p) then return false end
    local half=self:GetBattleMapHalfExtent()
    return math.abs(p.x)<=half and math.abs(p.z)<=half
end

function R:CanAutoEngage(attacker,target)
    if self.AIProfileIndex and valid(attacker) and valid(target) then
        local profile=self.AIProfileIndex[target:getSignature()]
        local row=profile and profile.contextRow
        if row and row.ship==target and row.hostileTo then
            local hostile=self:AIContextEnemies(attacker,row,self:GetFactionKey(attacker),attacker.Team)
            return hostile
        end
    end
    return self:AreEnemies(attacker,target) and self:IsAutomaticTargetPermitted(attacker,target)
        and self:IsAutomaticTargetInArena(attacker,target)
end

function R:GetExtractionArea(kind)
    self.ExtractionAreas=self.ExtractionAreas or {}
    if self.ExtractionAreas[kind] then return self.ExtractionAreas[kind] end
    local home=self:GetScenarioBasePosition(kind); if not home then return nil end
    local length=math.sqrt(home.x^2+home.z^2); local dx,dz=length>1 and home.x/length or 1,length>1 and home.z/length or 0
    local half=self:GetTacticalMapHalfExtent(); local center=vec(home.x+dx*14000,home.y,home.z+dz*14000)
    -- Extraction adds a bounded outer sector; committed ships cannot turn it
    -- into an attack staging area. Normal arena geometry stays inside it.
    self.ExtractionExtent=math.max(self.ExtractionExtent or half,math.abs(center.x)+10000,math.abs(center.z)+10000)
    local station=self:GetFactionCommandShip(kind)
    local area={center=center,home=vec(home.x,home.y,home.z),homeRadius=(self.FactionStationRadii or {})[kind] or (valid(station) and station.Radius or 1800),
        radius=8000,direction=vec(dx,0,dz),slots={}}
    self.ExtractionAreas[kind]=area
    return area
end

function R:BeginShipWithdrawal(ship)
    if not alive(ship) or ship.Name==self.Config.ObserverShip or self:IsCommandStation(ship) or self:IsStaticDefense(ship) then return false end
    local sig=ship:getSignature(); self.Withdrawals=self.Withdrawals or {}
    if self.Withdrawals[sig] then return true end
    local kind=self:GetFactionKey(ship)
    if not kind or not (self:IsFactionEliminated(kind) or self.AftermathActive) then return false end
    local area=self:GetExtractionArea(kind); if not area then return false end
    self.Rearguards[sig]=nil
    for _,operation in pairs(self.ExtractionOperations or {}) do
        if operation.rearguardSignature==sig then operation.rearguardSignature=nil; operation.rearguard=nil end
    end
    local radius=ship.Radius or 50; local destination
    for i=0,96 do
        local angle=i*2.399963; local spread=i==0 and 0 or math.sqrt(i)*(radius*2+500)
        local p=area.center+vec(math.cos(angle)*spread,(i%3-1)*math.min(radius,500),math.sin(angle)*spread)
        local free=area.center:getDistance(p)+radius<=area.radius
        for _,slot in pairs(area.slots) do if p:getDistance(slot.point)<radius+slot.radius+350 then free=false; break end end
        if free then
            for _,otherKind in ipairs(self:GetLivingFactionKeys()) do
                local station=self:GetFactionCommandShip(otherKind)
                if otherKind~=kind and alive(station) and station.Position:getDistance(p)<11000+(station.Radius or 0)+radius then free=false; break end
            end
        end
        if free then destination=p; break end
    end
    local record=self:GetUnitHistory(ship) or self:RecordShipCreated(ship)
    if self.CancelFleetServiceForShip then self:CancelFleetServiceForShip(ship) end
    self:ClearPassageInterception(ship,nil,false)
    ship.Target=nil
    for i=1,#ship do local turret=ship[i]; if turret:isTurret() then turret.Target=nil end end
    self.UserOrders[sig]=nil; self.PolicyApplied[sig]=nil; self.AIOrderState[sig]=nil
    ship:clearOrders(); self:SetShipCommandDiscipline(ship,true); self:SetShipTurretLock(ship,true)
    local withdrawal={faction=kind,destination=destination,committedAt=mn.getMissionTime(),history=record and record.id,
        originalTeam=ship.Team,phase=destination and 'WITHDRAWING // EXPOSED' or 'STRANDED // NO CLEAR CORRIDOR'}
    self.Withdrawals[sig]=withdrawal
    if destination then area.slots[sig]={point=destination,radius=radius} end
    if kind=='BLUE' then self:SetStatus(ship.Name..': '..withdrawal.phase,4) end
    return true
end

function R:WithdrawSelected()
    local count=0
    for _,ship in ipairs(self:GetSelectedFriendlyShips()) do if self:BeginShipWithdrawal(ship) then count=count+1 end end
    if count==0 then self:SetStatus('Withdrawal requires station loss or a resolved battle',4) end
    return count
end

function R:WithdrawPlayerFleet()
    local count=0
    for _,ship in ipairs(self:GetShipList()) do if self:GetFactionKey(ship)=='BLUE' and self:BeginShipWithdrawal(ship) then count=count+1 end end
    if self.PostBattleActive then self:ResumePostBattle() end
    return count
end

function R:ClearDepartingShipReferences(ship)
    local sig=ship:getSignature()
    self:ClearFleetLifeReferences(ship)
    if self.PossessedSignature==sig then self:ExitPilotMode(nil,false) end
    if self.FollowSignature==sig then self:ExitFollowMode('Ship departed') end
    if self.FleetServices then self.FleetServices[sig]=nil end
    if self.FleetServiceCooldown then self.FleetServiceCooldown[sig]=nil end
    local wingId=self.WingBySignature[sig]; local wing=wingId and self.RTSWings[wingId]
    if wing then for i=#wing.signatures,1,-1 do if wing.signatures[i]==sig then table.remove(wing.signatures,i) end end; if #wing.signatures==0 then self.RTSWings[wingId]=nil end end
    self.WingBySignature[sig]=nil; self.UserOrders[sig]=nil; self.PolicyApplied[sig]=nil; self.PolicyDefend[sig]=nil; self.AIOrderState[sig]=nil
    self:ReleaseMoveWaypoint(sig)
    if self.CommandDiscipline then self.CommandDiscipline[sig]=nil end
    self:HandleAttackWingTargetDeath(sig)
    for owner,order in pairs(self.UserOrders) do
        if order.targetSignature==sig then local s=self:FindShipBySignature(owner); self.UserOrders[owner]=nil; if valid(s) then s:clearOrders(); self:ReturnToDefaultControl(s) end end
    end
    for owner,order in pairs(self.AIOrderState) do if order.targetSignature==sig then local s=self:FindShipBySignature(owner); self.AIOrderState[owner]=nil; if valid(s) then s:clearOrders() end end end
    for _,list in pairs(self.ControlGroups or {}) do for i=#list,1,-1 do if list[i]==sig then table.remove(list,i) end end end
    for i=#self.Selected,1,-1 do if self.Selected[i]==sig then table.remove(self.Selected,i) end end
    self.EngageTargets[sig]=nil; for owner,target in pairs(self.EngageTargets) do if target==sig then self.EngageTargets[owner]=nil end end
    self:InvalidateShipList()
end

function R:OnShipDeparture(ship,method)
    if not self.Enabled or not valid(ship) or ship.Name==self.Config.ObserverShip then return end
    local escaped=method=='SHIP_DEPARTED_WARP' or method=='SHIP_DEPARTED_BAY' or method=='SHIP_DEPARTED'
    self:RecordUnitFate(ship,escaped and 'ESCAPED' or 'REMOVED',method)
    self:ClearDepartingShipReferences(ship)
    local sig=ship:getSignature(); self.Withdrawals[sig]=nil
    for _,area in pairs(self.ExtractionAreas) do area.slots[sig]=nil end
end

function R:EnterPassageCorridor(ship,w)
    w.inCorridor=true; w.phase='IN DEPARTURE CORRIDOR'
    ship.Team=mn.Teams['RTS Passage']; self:ApplyFactionVisual(ship,w.faction)
    local signature=ship:getSignature()
    for _,attacker in ipairs(self:GetShipList()) do
        local sig=attacker:getSignature(); local order=self.UserOrders[sig]
        local explicit=order and (order.kind=='attack' or order.kind=='attack_wing') and order.targetSignature==signature
        if alive(attacker) and not explicit and self.PossessedSignature~=sig and not self:CanAutoEngage(attacker,ship) then
            local ai=self.AIOrderState[sig]
            if (ai and ai.targetSignature==signature) or valid(attacker.Target) and attacker.Target:getSignature()==signature then
                attacker:clearOrders(); attacker.Target=nil; self.AIOrderState[sig]=nil; self.PolicyApplied[sig]=nil
            end
            for i=1,#attacker do local sub=attacker[i]; if sub:isTurret() and valid(sub.Target) and sub.Target:getSignature()==signature then sub.Target=nil; sub:targetingOverride(false) end end
        end
    end
end

local function passageWeaponCanReach(self,ship,target)
    local range=self:GetShipWeaponRange(ship)
    if range<=0 then return false end
    return ship.Position:getDistance(target.Position)-(target.Radius or 0)-(ship.Radius or 0)<=range
end

function R:ClearPassageInterception(ship,targetSignature,resumeDefault)
    local sig=ship:getSignature()
    local owned=self.PassageTurretOverrides and self.PassageTurretOverrides[sig]
    if targetSignature==nil then targetSignature=owned and owned.targetSignature end
    if targetSignature~=nil then
        if valid(ship.Target) and ship.Target:getSignature()==targetSignature then ship.Target=nil end
        for i=1,#ship do
            local turret=ship[i]
            if turret:isTurret() and valid(turret.Target) and turret.Target:getSignature()==targetSignature then
                turret.Target=nil
                turret:targetingOverride(false)
            end
        end
    elseif owned then
        for i=1,#ship do local turret=ship[i]; if turret:isTurret() then turret:targetingOverride(false) end end
    end
    if self.PassageTurretOverrides then self.PassageTurretOverrides[sig]=nil end
    if owned and owned.automatic and resumeDefault~=false and self.UserOrders[sig]==nil
        and self.AIOrderState[sig]==nil and alive(ship) then
        ship:clearOrders(); self:ReturnToDefaultControl(ship)
    end
end

function R:ClearPassageReferencesTo(signature)
    for _,attacker in ipairs(self:GetShipList()) do
        if valid(attacker) then
            local attackerSignature=attacker:getSignature()
            local owned=self.PassageTurretOverrides and self.PassageTurretOverrides[attackerSignature]
            if owned and owned.targetSignature==signature then
                self:ClearPassageInterception(attacker,signature)
            else
                if valid(attacker.Target) and attacker.Target:getSignature()==signature then attacker.Target=nil end
                for i=1,#attacker do
                    local turret=attacker[i]
                    if turret:isTurret() and valid(turret.Target) and turret.Target:getSignature()==signature then
                        turret.Target=nil; turret:targetingOverride(false)
                    end
                end
            end
        end
    end
end

function R:ClearFleetLifeReferences(ship)
    local sig=ship:getSignature()
    self:ClearPassageReferencesTo(sig)
    self:ClearPassageInterception(ship,nil,false)
    if self.Rearguards then self.Rearguards[sig]=nil end
    for _,operation in pairs(self.ExtractionOperations or {}) do
        if operation.rearguardSignature==sig then operation.rearguardSignature=nil; operation.rearguard=nil end
    end
    for owner,entry in pairs(self.AIPursuit or {}) do
        if owner==sig or entry.targetSignature==sig then self:DropPursuit(owner) end
    end
end

function R:UpdateFleetLife(now)
    if now<(self.NextFleetLife or 0) then return end
    self.NextFleetLife=now+.5
    for signature in pairs(self.TerminalShipSignatures or {}) do
        if not valid(self:FindShipBySignature(signature)) then self.TerminalShipSignatures[signature]=nil; self.HistoryBySignature[signature]=nil end
    end
    for _,ship in ipairs(self:GetShipList()) do
        if alive(ship) then
            local r=self:GetUnitHistory(ship) or self:RecordShipCreated(ship)
            if r and r.fate=='PRESENT' then
                local hp=ship.HitpointsLeft/math.max(1,ship.HitpointsMax); r.lowestHull=math.min(r.lowestHull,hp)
                if r.faction=='BLUE' and hp<=(self.Config.Station.FleetService.AutoHull or .35)
                    and not r.criticalNotice and (self.UserOrders[r.signature] or self.PossessedSignature==r.signature) then
                    r.criticalNotice=true; self.FleetRecoveryNotice={id=r.id,untilTime=self:UINow()+10}
                end
            end
            local w=self.Withdrawals and self.Withdrawals[ship:getSignature()]
            if w and w.destination and not w.departureStarted then
                if not w.inCorridor and ship.Position:getDistance(w.destination)<=math.max(1800,(ship.Radius or 0)+600) then self:EnterPassageCorridor(ship,w) end
                local speed=ship.Physics.VelocityMax
                if speed and math.abs(speed.z or 0)<.1 then w.phase='STRANDED // NO PROPULSION'
                elseif ship.Position:getDistance(w.destination)<=math.max(450,(ship.Radius or 0)*.25) then
                    if self.PossessedSignature==ship:getSignature() then self:ExitPilotMode('Extraction: returning to command',false) end
                    ship:clearOrders(); self:SetShipTurretLock(ship,true)
                    w.departureStarted=ship:warpOut()==true
                    if not w.departureStarted then w.phase='STRANDED // DEPARTURE REFUSED' end
                elseif self.PossessedSignature~=ship:getSignature() then
                    local waypoint=self:ConfigureMoveWaypoints(ship,w.destination)
                    if U.objectValid(waypoint) then
                        if not w.orderIssuedAt or now-w.orderIssuedAt>=5 or #ship.Orders==0 then
                            ship:clearOrders(); ship:giveOrder(ORDER_WAYPOINTS_ONCE,waypoint,nil,.99); w.orderIssuedAt=now
                        end
                        self:SetShipCommandDiscipline(ship,true); self:SetShipTurretLock(ship,true)
                    else w.phase='STRANDED // ROUTE UNAVAILABLE' end
                end
            end
        end
    end
    if next(self.Withdrawals or {}) or next(self.PassageTurretOverrides or {}) then self:UpdatePassageInterception() end
end

function R:UpdatePassageInterception()
    self.PassageTurretOverrides=self.PassageTurretOverrides or {}
    for _,ship in ipairs(self:GetShipList()) do
        if alive(ship) and self.PossessedSignature~=ship:getSignature() and not self:IsShipWithdrawing(ship) then
            local sig=ship:getSignature(); local order=self.UserOrders[sig]
            local ai=self.AIOrderState and self.AIOrderState[sig]
            local target,explicit,autoAcquired=nil,false,false
            if order~=nil then
                if (order.kind=='attack' or order.kind=='attack_wing') and order.targetSignature~=nil then
                    target=order.kind=='attack_wing' and self:ResolveAttackWingTarget(order) or self:FindShipBySignature(order.targetSignature)
                    explicit=valid(target)
                end
            elseif ai and ai.targetSignature then target=self:FindShipBySignature(ai.targetSignature)
            elseif valid(ship.Target) then target=ship.Target
            elseif self.AllowWithdrawal[self:GetFactionKey(ship)]==false then
                local bestDistance=math.huge
                for _,candidate in ipairs(self:GetShipList()) do
                    if alive(candidate) then
                        local withdrawal=self.Withdrawals and self.Withdrawals[candidate:getSignature()]
                        if withdrawal and withdrawal.inCorridor and self:CanAutoEngage(ship,candidate)
                            and passageWeaponCanReach(self,ship,candidate) then
                            local distance=ship.Position:getDistance(candidate.Position)
                            if distance<bestDistance then target,bestDistance=candidate,distance end
                        end
                    end
                end
                autoAcquired=valid(target)
            end

            local withdrawal=valid(target) and self.Withdrawals and self.Withdrawals[target:getSignature()]
            local permitted=withdrawal and withdrawal.inCorridor and self:AreEnemies(ship,target)
                and (explicit or self:CanAutoEngage(ship,target)) and passageWeaponCanReach(self,ship,target)
            local owned=self.PassageTurretOverrides[sig]
            if permitted then
                local automatic=autoAcquired or (owned and owned.automatic and order==nil and ai==nil)
                if automatic then
                    if not owned or not owned.automatic or owned.targetSignature~=target:getSignature() or not valid(ship.Target) then
                        ship:clearOrders()
                        if ship:giveOrder(ORDER_ATTACK,target,nil,.75)~=true then
                            self:ClearPassageInterception(ship,owned and owned.targetSignature,false)
                            ship.Target=nil
                            target=nil; permitted=false
                        end
                    end
                end
                if permitted then
                    if automatic or explicit then ship.Target=target end
                    self.PassageTurretOverrides[sig]={targetSignature=target:getSignature(),automatic=automatic==true}
                end
                for i=1,#ship do
                    local turret=ship[i]
                    if permitted and turret:isTurret() and not turret.TurretLocked then turret.Target=target end
                end
            elseif owned then
                self:ClearPassageInterception(ship,owned.targetSignature)
            end
        end
    end
end

function R:FindDefeatedFleetTarget(ship,kind)
    local killer=self.FactionDefeatedBy and self.FactionDefeatedBy[kind]
    local base=killer and self:GetFactionCommandShip(killer)
    if self:CanDamageBase(ship) and alive(base) and self:CanAutoEngage(ship,base) then return base end

    local canHitBase=self:CanDamageBase(ship)
    local best,bestRank,bestDistance=nil,math.huge,math.huge
    for _,candidate in ipairs(self:GetShipList()) do
        if alive(candidate) and candidate~=ship and self:CanAutoEngage(ship,candidate) then
            local faction=self:GetFactionKey(candidate)
            local station=self:IsCommandStation(candidate)
            if not station or canHitBase then
                local rank=(killer and faction==killer) and 0 or (killer and 100000000 or 0)
                if station then rank=rank+1000000 elseif self:IsStaticDefense(candidate) then rank=rank+100000 end
                local distance=ship.Position:getDistance(candidate.Position)
                if rank<bestRank or rank==bestRank and (distance<bestDistance or distance==bestDistance and candidate:getSignature()<best:getSignature()) then
                    best,bestRank,bestDistance=candidate,rank,distance
                end
            end
        end
    end
    return best
end

function R:UpdateDefeatedFleetExtraction(now)
    self.ExtractionOperations=self.ExtractionOperations or {}
    self.Rearguards=self.Rearguards or {}
    for _,kind in ipairs(self:GetFactionKeys()) do
        if self:IsFactionEliminated(kind) and (kind~='BLUE' or self.AutoPlayerMode) then
            local operation=self.ExtractionOperations[kind]
            local ships={}
            for _,ship in ipairs(self:GetShipList()) do
                if alive(ship) and self:GetFactionKey(ship)==kind and not self:IsCommandStation(ship)
                    and not self:IsStaticDefense(ship) and ship.Name~=self.Config.ObserverShip then ships[#ships+1]=ship end
            end
            if not operation then
                operation={startedAt=now}; self.ExtractionOperations[kind]=operation
                local best,score
                for _,ship in ipairs(ships) do
                    local role=self:GetShipRole(ship)
                    if self:AIProfile(ship).armed and ship.HitpointsLeft/math.max(1,ship.HitpointsMax)>(self.Config.Station.FleetService.CriticalHull or .22)
                        and (role=='escort' or role=='fighter' or role=='capital') then
                        local distance=math.huge
                        for _,enemy in ipairs(self:GetShipList()) do
                            if alive(enemy) and self:CanAutoEngage(ship,enemy) then distance=math.min(distance,ship.Position:getDistance(enemy.Position)) end
                        end
                        local value=distance+(role=='escort' and -2000 or 0)
                        if not score or value<score or value==score and ship:getSignature()<best:getSignature() then best,score=ship,value end
                    end
                end
                operation.rearguard=best and self.WingBySignature[best:getSignature()]
                operation.rearguardSignature=best and best:getSignature()
                self:SetStatus(self:GetFactionDisplayName(kind)..': fleet withdrawing; cover may still engage',5)
            end
            local others=false
            for _,ship in ipairs(ships) do
                local id=ship:getSignature()
                local manual=kind=='BLUE' and (self.UserOrders[id] or self.PossessedSignature==id)
                local cover=operation.rearguard and self.WingBySignature[id]==operation.rearguard or id==operation.rearguardSignature
                local withdrawal=self.Withdrawals[id]
                if not cover and not manual then self:BeginShipWithdrawal(ship); withdrawal=self.Withdrawals[id] end
                local history=self:GetUnitHistory(ship)
                if not cover and not manual and history and history.fate=='PRESENT' and withdrawal and withdrawal.destination
                    and not (withdrawal.phase or ''):find('STRANDED',1,true) then others=true end
            end
            for _,ship in ipairs(ships) do
                local id=ship:getSignature()
                local cover=operation.rearguard and self.WingBySignature[id]==operation.rearguard or id==operation.rearguardSignature
                local manual=kind=='BLUE' and (self.UserOrders[id] or self.PossessedSignature==id)
                if cover and not manual and not self:IsShipWithdrawing(ship) then
                    local critical=ship.HitpointsLeft/math.max(1,ship.HitpointsMax)<=(self.Config.Station.FleetService.CriticalHull or .22)
                    local target=self:FindDefeatedFleetTarget(ship,kind)
                    if critical then self:BeginShipWithdrawal(ship)
                    elseif not others then
                        if target then
                            local mission=self:IsCommandStation(target) and 'PRIMARY' or 'INTERCEPT'
                            if self:IssueStrategicOrder(ship,target,'AI RETALIATION: '..target.Name,mission,now,true) then
                                self.AIOrderState[id].reason='RETALIATE_BASE_KILLER'
                            end
                        else self:BeginShipWithdrawal(ship) end
                    else
                        local area=self:GetExtractionArea(kind); local guard=self.Rearguards[id]
                        if not guard then
                            local index=0; for _ in pairs(self.Rearguards) do index=index+1 end
                            guard={faction=kind,point=area.home+area.direction*(area.homeRadius+(ship.Radius or 0)+800)
                                +vec(-area.direction.z,0,area.direction.x)*((index%5-2)*((ship.Radius or 0)*2+250))}
                            self.Rearguards[id]=guard
                        end
                        local nearest,distance,rank=nil,4500,math.huge
                        local killer=self.FactionDefeatedBy and self.FactionDefeatedBy[kind]
                        for _,enemy in ipairs(self:GetShipList()) do
                            if alive(enemy) and self:CanAutoEngage(ship,enemy)
                                and (not self:IsCommandStation(enemy) or self:CanDamageBase(ship)) then
                                local d=guard.point:getDistance(enemy.Position)
                                local candidateRank=(killer and self:GetFactionKey(enemy)==killer) and 0 or 1
                                if d<4500 and (candidateRank<rank or candidateRank==rank and d<distance) then
                                    nearest,distance,rank=enemy,d,candidateRank
                                end
                            end
                        end
                        if ship.Position:getDistance(guard.point)>6000 or not nearest and ship.Position:getDistance(guard.point)>900 then
                            local point=self:ConfigureMoveWaypoints(ship,guard.point)
                            if U.objectValid(point) then ship:clearOrders(); ship:giveOrder(ORDER_WAYPOINTS_ONCE,point,nil,.95); self:SetShipCommandDiscipline(ship,true); self:SetShipTurretLock(ship,true) end
                        else
                            self:SetShipCommandDiscipline(ship,false); self:SetShipTurretLock(ship,false)
                            ship:clearOrders(); ship:giveOrder(nearest and ORDER_ATTACK or ORDER_STAY_STILL,nearest,nil,.95)
                            self.AIOrderState[id]={mission='REARGUARD',label='COVER WITHDRAWAL',destination=guard.point,
                                targetSignature=nearest and nearest:getSignature(),assignedAt=operation.startedAt,installedAt=now,
                                reason=nearest and killer and self:GetFactionKey(nearest)==killer and 'RETALIATE_BASE_KILLER' or 'COVER_EXTRACTION'}
                        end
                    end
                end
            end
        end
    end
end

function R:GetFleetHistorySummary()
    local summary={lost=0,escaped=0,present=0,stranded=0,recoveries=0,piloted=0,afterResultLosses=0,citations=0,records={},wings={}}
    for _,record in pairs(self.UnitHistory or {}) do
        if record.faction=='BLUE' then
            summary.records[#summary.records+1]=record.id
            summary.recoveries=summary.recoveries+record.recoveries
            for _ in pairs(record.citations or {}) do summary.citations=summary.citations+1 end
            if record.pilotSeconds>0 or record.pilotStartedAt then summary.piloted=summary.piloted+1 end
            if record.fate=='LOST' then summary.lost=summary.lost+1; if record.afterResult then summary.afterResultLosses=summary.afterResultLosses+1 end
            elseif record.fate=='ESCAPED' then summary.escaped=summary.escaped+1
            elseif record.fate=='PRESENT' then summary.present=summary.present+1; local w=self.Withdrawals[record.signature]; if w and w.phase:find('STRANDED',1,true) then summary.stranded=summary.stranded+1 end end
        end
    end
    table.sort(summary.records,function(a,b) return tonumber(a:match('%d+'))<tonumber(b:match('%d+')) end)
    for id,wing in pairs(self.WingHistory or {}) do
        local first=self.UnitHistory[wing.members[1]]
        if first and first.faction=='BLUE' then
            local row={id=id,label=wing.label,original=#wing.members,lost=0,escaped=0,present=0}
            for _,member in ipairs(wing.members) do local r=self.UnitHistory[member]; if r.fate=='LOST' then row.lost=row.lost+1 elseif r.fate=='ESCAPED' then row.escaped=row.escaped+1 elseif r.fate=='PRESENT' then row.present=row.present+1 end end
            summary.wings[#summary.wings+1]=row
        end
    end
    table.sort(summary.wings,function(a,b) return a.label<b.label end)
    return summary
end

function R:FocusHistoryShip(id,service)
    local r=self.UnitHistory[id]; local ship=r and r.fate=='PRESENT' and self:FindShipBySignature(r.signature)
    if not alive(ship) then return false end
    self.Selected={r.signature}; self.PrimarySelectionSignature=r.signature
    self:FocusOnSelection()
    if service then return self:BeginFleetService(ship,'PLAYER_SERVICE',mn.getMissionTime(),true) end
    return true
end

function R:HandleFleetLifeClick(x,y)
    if self.EnvironmentPicker then
        for id,rect in pairs(self.EnvironmentButtonRects or {}) do
            if self:PointInside(rect,x,y) then
                if id=='close' then self.EnvironmentPicker=false; return true end
                local kind,action=id:match('^(%a+)_(%a+)$')
                if kind then
                    local music=kind=='music'
                    local list,selected
                    if music then list,selected=self.Config.Music.Tracks,self.EnvironmentMusicIndex
                    else list,selected=self.Config.Environment.NebulaBackdrops,self.EnvironmentBackdropIndex end
                    local choice=action=='random' and 'RANDOM' or (((selected or 1)-1+(action=='prev' and -1 or 1))%#list+1)
                    if music then self.SetupMusicChoice=choice; if ad and ad.playMusic then self:SetEnvironmentMusic(choice) end
                    else self.SetupBackdropChoice=choice; self:SetNebulaBackdrop(choice) end
                end
                return true
            end
        end
        return true
    end
    for id,rect in pairs(self.FleetLifeButtonRects or {}) do
        if self:PointInside(rect,x,y) then
            if id=='withdraw' then self:WithdrawSelected()
            elseif id=='passage' then
                self.AllowWithdrawal.BLUE=self.AllowWithdrawal.BLUE==false and true or false
                self:SetStatus(self.AllowWithdrawal.BLUE==false and 'INTERCEPT ON: enemies may fire on departing ships' or 'INTERCEPT OFF: departing ships are not intercepted',4)
                if self.AllowWithdrawal.BLUE~=false then
                    for _,ship in ipairs(self:GetShipList()) do local w=self.Withdrawals[ship:getSignature()]; if w and w.inCorridor then self:EnterPassageCorridor(ship,w) end end
                end
            elseif id=='report' then self:OpenSurvivorReport()
            elseif id=='focus' or id=='service' then self:FocusHistoryShip(self.FleetRecoveryNotice.id,id=='service') end
            return true
        end
    end
    return false
end

return R
