-- Match-local crew estimates, factual honors and protection; shared by live HUD and reports.
local R=require 'fs2rts_state'
local U=require 'fs2rts_util'
local alive,valid=U.shipAlive,U.shipValid
local kinds={'RECOVERY_REJOIN','WITHDRAWAL_COVER','GALLANTRY','DISTINGUISHED_SERVICE','JUSTIFIED_SACRIFICE'}

function R:ResetFleetHumanity()
    self.InstallationHistory={}; self.InstallationBySignature={}; self.FleetProtection={}
    self.FleetHumanityNotices={}; self.NextFleetProtection=0
    self.FleetHistoryOffset=0; self.LiveHistoryDetail=nil
    self.FleetHistoryFilter='all'; self.FleetHistoryCitationIndex=0; self.ShowFleetCost=false; self.FleetCostKeyHeld=false
end

function R:InitializeCrewRecord(record,ship)
    local c=self.Config.FleetHumanity
    local role=self:IsCommandStation(ship) and 'station' or self:GetShipRole(ship)
    record.role=role
    local count=c.ClassCrew[ship.Class.Name]
    if count==nil then count=c.RoleCrew[role] end
    if type(count)=='number' and count>=0 and count<math.huge then record.crewComplement=math.floor(count) end
    record.crewBasis='design estimate v'..c.ModelVersion
    record.crewEstimatedDead=0; record.crewMissing=0
end

function R:GetInstallationHistory(ship,create)
    if not valid(ship) or not self:IsCommandStation(ship) then return nil end
    self.InstallationHistory=self.InstallationHistory or {}; self.InstallationBySignature=self.InstallationBySignature or {}
    local signature=ship:getSignature(); local id=self.InstallationBySignature[signature]
    if id then return self.InstallationHistory[id] end
    if not create or self.SetupActive or self.CinematicActive then return nil end
    self.HistorySerial=(self.HistorySerial or 0)+1; id='BASE '..self.HistorySerial
    local record={id=id,signature=signature,faction=self:GetFactionKey(ship),name=ship.Name,class=ship.Class.Name,
        commissionedAt=mn.getMissionTime(),fate='PRESENT',installation=true}
    self:InitializeCrewRecord(record,ship)
    self.InstallationHistory[id]=record; self.InstallationBySignature[signature]=id
    return record
end

function R:PushFleetHumanityNotice(text,priority)
    self.FleetHumanityNotices=self.FleetHumanityNotices or {}
    local notices=self.FleetHumanityNotices
    notices[#notices+1]={text=text,priority=priority or 1,untilTime=self:UINow()+12}
    if not self.ShowFleetCost then self:SetStatus(text:gsub(' // EST DEAD.*',''),6) end
    if #notices>12 then table.remove(notices,1) end
end

function R:RecordCrewFate(record)
    if record.fate=='LOST' and record.crewComplement then
        -- Model v1: destruction estimates 80% dead; the remainder is unconfirmed, never claimed rescued.
        record.crewEstimatedDead=math.floor(record.crewComplement*self.Config.FleetHumanity.DestructionDeathFraction+.5)
        record.crewMissing=record.crewComplement-record.crewEstimatedDead
    end
    if record.faction=='BLUE' and (record.fate=='LOST' or record.fate=='ESCAPED') then
        local detail=record.fate=='LOST' and (record.crewComplement and
            (' // EST DEAD '..record.crewEstimatedDead..' / MISSING '..record.crewMissing) or ' // CREW UNKNOWN') or ''
        self:PushFleetHumanityNotice((record.everPiloted and 'YOU FLEW '..record.name or record.name)..' // '..record.fate..detail,
            record.everPiloted and 3 or 2)
    end
end

function R:GetPilotHistorySeconds(record)
    return (record.pilotSeconds or 0)+(record.pilotStartedAt and math.max(0,mn.getMissionTime()-record.pilotStartedAt) or 0)
end

function R:GetRecordCitations(record)
    local entries={}
    for _,kind in ipairs(kinds) do
        local citation=(record.citations or {})[kind]
        if citation then entries[#entries+1]=citation end
    end
    return entries
end

function R:GetShipHistoryBadge(ship)
    if not self:IsFriendly(ship) then return '' end
    local record=self:GetUnitHistory(ship)
    if not record or record.fate~='PRESENT' then return '' end
    local parts={}
    if record.everPiloted then parts[#parts+1]='P' end
    if (record.recoveries or 0)>0 then parts[#parts+1]='R'..record.recoveries end
    local citations=self:GetRecordCitations(record)
    if #citations>0 then parts[#parts+1]='C'..#citations end
    local wing=record.originalWing and self.WingHistory[record.originalWing]
    if wing and #self:GetRecordCitations(wing)>0 then parts[#parts+1]='W' end
    return table.concat(parts,' ')
end

function R:GetShipHistoryLines(ship)
    local record=self:GetUnitHistory(ship) or self:GetInstallationHistory(ship,false)
    if not record then return {} end
    local lines={}
    if record.everPiloted then lines[#lines+1]='P // PILOTED BY YOU: '..math.floor(self:GetPilotHistorySeconds(record))..'s' end
    if (record.recoveries or 0)>0 then lines[#lines+1]='R // DAMAGED RETURNS: '..record.recoveries end
    lines[#lines+1]=record.crewComplement and ('CREW ABOARD: '..record.crewComplement..' (design estimate)') or 'CREW: UNKNOWN'
    for _,citation in ipairs(self:GetRecordCitations(record)) do lines[#lines+1]='C // '..citation.reason end
    local wing=record.originalWing and self.WingHistory[record.originalWing]
    if wing then for _,citation in ipairs(self:GetRecordCitations(wing)) do lines[#lines+1]='W // '..wing.label..': '..citation.reason end end
    local protection=(self.FleetProtection or {})[record.signature]
    local beneficiary=protection and self.UnitHistory[protection.history]
    if beneficiary then lines[#lines+1]='COVERING: '..beneficiary.name..' // EXPOSED CREW' end
    return lines
end

function R:GetFleetCrewSummary(faction)
    local s={dead=0,missing=0,aboard=0,escaped=0,unknown=0,shipsLost=0,basesLost=0,stranded=0,pilotedLost=0}
    for _,records in ipairs({self.UnitHistory or {},self.InstallationHistory or {}}) do
        for _,record in pairs(records) do
            if (faction and record.faction==faction) or (not faction and record.faction~='BLUE') then
                if record.crewComplement==nil then s.unknown=s.unknown+1
                elseif record.fate=='LOST' then s.dead=s.dead+(record.crewEstimatedDead or 0); s.missing=s.missing+(record.crewMissing or 0)
                elseif record.fate=='ESCAPED' then s.escaped=s.escaped+record.crewComplement
                else s.aboard=s.aboard+record.crewComplement end
                if record.fate=='LOST' then
                    local key=record.installation and 'basesLost' or 'shipsLost'; s[key]=s[key]+1
                    if record.everPiloted then s.pilotedLost=s.pilotedLost+1 end
                end
                local withdrawal=(self.Withdrawals or {})[record.signature]
                if record.fate=='PRESENT' and withdrawal and withdrawal.phase:find('STRANDED',1,true) then s.stranded=s.stranded+1 end
            end
        end
    end
    return s
end

function R:GetFleetCostLines()
    local lines={}
    for _,side in ipairs({{key='BLUE',name='YOUR COMMAND'},{name='OPPOSING COMMANDS'}}) do
        local s=self:GetFleetCrewSummary(side.key)
        lines[#lines+1]=side.name..': EST DEAD '..s.dead..' / MISSING '..s.missing..' / ESCAPED '..s.escaped
        lines[#lines+1]='  ABOARD '..s.aboard..' / UNKNOWN HULLS '..s.unknown..' / LOST '..s.shipsLost..' SHIPS, '..s.basesLost..' BASES'
    end
    return lines
end

function R:AwardWingCitation(wing,kind,reason)
    wing.citations=wing.citations or {}
    if wing.citations[kind] then return false end
    wing.citations[kind]={reason=reason,time=mn.getMissionTime()}
    local member=self.UnitHistory[wing.members[1]]
    if member and member.faction=='BLUE' then self:PushFleetHumanityNotice('WING CITATION // '..wing.label..': '..reason,1) end
    self:EmitAIEvent('WING_CITATION',{wing=wing.id,kind=kind,reason=reason})
    return true
end

function R:RecordCollectiveCover(beneficiary,contributors,outcome)
    local wings={}
    for id in pairs(contributors or {}) do
        local record=self.UnitHistory[id]
        if record then
            if record.fate=='LOST' then self:AwardFleetCitation(record,'JUSTIFIED_SACRIFICE',
                'Removed a threat before loss; '..beneficiary.name..' '..outcome) end
            if record.originalWing then wings[record.originalWing]=(wings[record.originalWing] or 0)+1 end
        end
    end
    for id,count in pairs(wings) do
        local wing=self.WingHistory[id]
        if wing and count>=2 then self:AwardWingCitation(wing,outcome=='escaped' and 'WITHDRAWAL_COVER' or 'GALLANTRY',
            'Two original members removed pursuing threats; '..beneficiary.name..' '..outcome) end
    end
end

function R:RecordExtendedFleetKill(source,target)
    local record=self:GetUnitHistory(source); local victim=self:GetUnitHistory(target)
    if not record or not victim or record.id==victim.id then return end
    record.killVictims=record.killVictims or {}
    if record.killVictims[victim.id] then return end
    local now=mn.getMissionTime(); record.killVictims[victim.id]=true
    record.hostileKills=(record.hostileKills or 0)+1
    if record.hostileKills>=5 and now-record.commissionedAt>=180 and not record.friendlyFireEver then
        self:AwardFleetCitation(record,'DISTINGUISHED_SERVICE','Five distinct hostile mobile kills over at least three minutes')
    end
    local wing=record.originalWing and self.WingHistory[record.originalWing]
    if wing then
        wing.killVictims=wing.killVictims or {}; wing.contributors=wing.contributors or {}
        wing.killVictims[victim.id]=true; wing.contributors[record.id]=true
        local kills,members=0,0
        for _ in pairs(wing.killVictims) do kills=kills+1 end
        for _ in pairs(wing.contributors) do members=members+1 end
        local first=self.UnitHistory[wing.members[1]]
        local clean=true
        for _,id in ipairs(wing.members) do if self.UnitHistory[id].friendlyFireEver then clean=false end end
        if clean and kills>=5 and members>=2 and first and now-first.commissionedAt>=180 then
            self:AwardWingCitation(wing,'DISTINGUISHED_SERVICE','Original members achieved five distinct hostile kills over three minutes')
        end
    end
    local protected=valid(target.Target) and self:GetUnitHistory(target.Target)
    if protected and protected.faction==record.faction and protected.id~=record.id and protected.fate=='PRESENT'
        and protected.lastHostileHullSource==victim.id and now-(protected.lastHostileHullTime or -100)<=8
        and (target.Target.HitpointsLeft/math.max(1,target.Target.HitpointsMax)<=self.Config.Station.FleetService.ReturnHull
            or self:IsShipWithdrawing(target.Target) or (self.FleetServices or {})[protected.signature]) then
        self:AwardFleetCitation(record,'GALLANTRY','Removed a recent damaging attacker threatening '..protected.name)
        protected.protectionContributors=protected.protectionContributors or {}; protected.protectionContributors[record.id]=true
    end
end

function R:GetCrewCoverScore(ship,benefit,distance)
    local hp=ship.HitpointsLeft/math.max(1,ship.HitpointsMax)
    local crew=self:GetCrewExposureEstimate(ship)
    local range=math.max(1,self:GetShipWeaponRange(ship))
    return distance+crew*1000/math.max(.22,hp)-math.min(benefit,12)*math.min(range,6000)/6
end

function R:UpdateCrewProtection(now)
    if self.SetupActive or self.CinematicActive or now<(self.NextFleetProtection or 0) then return end
    self.NextFleetProtection=now+2; self.FleetProtection=self.FleetProtection or {}
    local protected={}
    for signature,cover in pairs(self.FleetProtection) do
        local ship=self:FindShipBySignature(signature); local record=self.UnitHistory[cover.history]
        local beneficiary=record and record.fate=='PRESENT' and self:FindShipBySignature(record.signature)
        local manual=(self.UserOrders or {})[signature] or self.PossessedSignature==signature
        local own=self.AIOrderState[signature]
        local owns=own and own.protectionHistory==cover.history
        if not alive(ship) or manual or not owns or not alive(beneficiary) or (alive(ship) and self:GetFactionKey(ship)=='BLUE' and cover.policy~=self.GlobalPolicy)
            or not ((self.FleetServices or {})[record.signature] or self:IsShipWithdrawing(beneficiary))
            or ship.HitpointsLeft/math.max(1,ship.HitpointsMax)<=self.Config.Station.FleetService.ReturnHull then
            self.FleetProtection[signature]=nil
            if alive(ship) and not manual and owns then
                ship:clearOrders(); self.AIOrderState[signature]=nil; self.PolicyApplied[signature]=nil
                local kind=self:GetFactionKey(ship)
                if kind=='BLUE' then self:ReturnToDefaultControl(ship) else self:AssignAIStrategicOrder(ship,kind,true) end
            end
        else protected[record.id]=true end
    end
    local candidates={}
    for _,ship in ipairs(self:GetShipList()) do
        local record=self:GetUnitHistory(ship)
        if alive(ship) and record and not protected[record.id] and
            ((self.FleetServices or {})[record.signature] or self:IsShipWithdrawing(ship)) and self:IsFleetFocusedByHostiles(ship,now) then
            local weight=self:GetCrewExposureEstimate(ship)
            candidates[#candidates+1]={ship=ship,record=record,weight=weight*(1-ship.HitpointsLeft/math.max(1,ship.HitpointsMax)+1)}
        end
    end
    table.sort(candidates,function(a,b) if a.weight==b.weight then return a.record.id<b.record.id end return a.weight>b.weight end)
    for _,candidate in ipairs(candidates) do
        local best,score
        for _,ship in ipairs(self:GetShipList()) do
            local signature=ship:getSignature(); local order=self.AIOrderState[signature]; local role=self:GetShipRole(ship)
            local target=valid(ship.Target) and ship.Target
            local fighting=target and self:AreEnemies(ship,target) and ship.Position:getDistance(target.Position)<=self:GetShipWeaponRange(ship)
            if alive(ship) and ship~=candidate.ship and self:GetFactionKey(ship)==candidate.record.faction
                and (role=='fighter' or role=='escort') and not (self.UserOrders or {})[signature]
                and self.PossessedSignature~=signature and not self.FleetProtection[signature]
                and not (self.FleetServices or {})[signature] and not self:IsShipWithdrawing(ship)
                and not fighting and not (order and (order.mission=='PRIMARY' or order.mission=='ESCORT' or order.mission=='REARGUARD'))
                and ship.HitpointsLeft/math.max(1,ship.HitpointsMax)>=self.Config.Station.FleetService.ReadyHull
                and self:AIProfile(ship).armed then
                local distance=ship.Position:getDistance(candidate.ship.Position)
                local value=self:GetCrewCoverScore(ship,candidate.weight,distance)
                if distance<=self.Config.Station.FleetService.DangerRadius*2 and (not score or value<score) then best,score=ship,value end
            end
        end
        if best and self:IssueStrategicOrder(best,candidate.ship,'PROTECT CREW: '..candidate.record.name,'ESCORT',now,true)==true then
            local signature=best:getSignature()
            self:SetShipCommandDiscipline(best,false); self:SetShipTurretLock(best,false)
            self.FleetProtection[signature]={history=candidate.record.id,policy=self.GlobalPolicy}
            self.AIOrderState[signature].protectionHistory=candidate.record.id
            self.AIOrderState[signature].reason='CREW_PROTECTION'
        end
    end
end

return R
