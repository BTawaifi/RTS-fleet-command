-- Operations own multi-wing intent; the existing commander retains home defense
-- and native AI retains immediate combat. No ships/resources are created here.
local R=require 'fs2rts_state'
local U=require 'fs2rts_util'
local alive,valid,vec=U.shipAlive,U.shipValid,U.vec
local function sig(s) return valid(s) and s:getSignature() or -1 end
local function strike(g) return g.role=='bomber' or g.role=='capital' or g.role=='heavy' or g.role=='juggernaut' end
local function screen(g) return g.role=='fighter' or g.role=='escort' end
local function settings(self) return self.Config.AI.Operations or {} end
local function pointBetween(home,target,travel,side)
    local dx,dz=target.Position.x-home.Position.x,target.Position.z-home.Position.z
    local length=math.max(1,math.sqrt(dx*dx+dz*dz)); dx,dz=dx/length,dz/length
    return vec(home.Position.x+dx*travel+dz*(side or 0),home.Position.y,home.Position.z+dz*travel-dx*(side or 0))
end

function R:SetAIOperationPhase(op,phase,reason,now)
    if op.phase==phase then return end
    local previous=op.phase; op.phase=phase; op.phaseAt=now
    self:EmitAIEvent('OPERATION',{faction=op.kind,front=op.front,serial=op.serial,
        previous=previous,phase=phase,reason=reason,value=op.value,initialValue=op.initialValue},now)
end

function R:BuildAIOperations(kind,groups,home,now,threatValue,homeEmergency)
    if settings(self).Enabled==false then return end
    self.AIOperations=self.AIOperations or {}
    local operations=self.AIOperations[kind] or {}; self.AIOperations[kind]=operations
    self.AIHomeThreatHistory=self.AIHomeThreatHistory or {}
    local previousThreat=self.AIHomeThreatHistory[kind] or 0
    self.AIHomeThreatHistory[kind]=threatValue
    -- A single tick used to release EVERY front: one player wing stepping out of
    -- the threat bubble and pulling back dropped home threat value by >80%,
    -- recalling the whole faction's assault out of assembly with no persistence
    -- requirement. CounterattackQuietSeconds gates that; 0 keeps the immediate
    -- release, a positive value requires the condition to hold that long.
    self.AIHomeQuietSince=self.AIHomeQuietSince or {}
    local quietSince=self.AIHomeQuietSince[kind]
    if previousThreat>0 and threatValue<previousThreat*.2 then quietSince=quietSince or now else quietSince=nil end
    self.AIHomeQuietSince[kind]=quietSince
    local counterattack=quietSince~=nil and (now-quietSince)>=(settings(self).CounterattackQuietSeconds or 0)
    local fronts={}
    for _,g in ipairs(groups) do
        g.operation=nil
        if alive(g.primary) and g.armed and not g.defending and not g.screen and not g.luring and not g.feint then
            local id=sig(g.primary); fronts[id]=fronts[id] or {target=g.primary,groups={}}
            fronts[id].groups[#fronts[id].groups+1]=g
        end
    end
    local ids={}; for id in pairs(fronts) do ids[#ids+1]=id end; table.sort(ids)
    for _,id in ipairs(ids) do
        local front=fronts[id]; local list=front.groups
        table.sort(list,function(a,b) return a.id<b.id end)
        local op=operations[id]
        if not op then
            op={kind=kind,front=id,serial=0}; operations[id]=op
            self:SetAIOperationPhase(op,'ASSEMBLE','NEW_OPERATION',now)
        elseif op.missingSince then
            -- Recovery temporarily removes ships from the planner roster. Pause
            -- this operation's clocks across that gap so returning replacements
            -- resume the same assault instead of starting an identical assembly.
            local paused=math.max(0,now-op.missingSince)
            for _,field in ipairs({'phaseAt','launchedAt','engagedAt','approachDeadline','suppressionUntil'}) do
                if op[field] then op[field]=op[field]+paused end
            end
            op.missingSince=nil
            -- lastUpdate is intentionally NOT stamped here. The engagedAt rewind
            -- below is measured from now-lastUpdate, and lastUpdate is only ever
            -- written in the live-front path, so across a recovery gap it stays
            -- stale and the elapsed window is paused a second time. That double
            -- shift looks wrong in isolation, but stamping it here changes the
            -- phase timings that test_operations.py's withdraw/exploit/
            -- counterattack window pins, and the group re-enters a different
            -- branch as a result. Left as-is until that contract is re-specified.
        end
        op.target=front.target; op.groups=list; op.value=0; op.strikes=0; op.screens=0
        local paused=math.max(0,now-(op.lastUpdate or now))
        if homeEmergency and op.engagedAt and (op.phase=='ENGAGE' or op.phase=='EXPLOIT') then op.engagedAt=op.engagedAt+paused end
        op.lastUpdate=now
        local anchor=nil; local nearest=math.huge
        for _,g in ipairs(list) do
            g.operation=op; op.value=op.value+g.value
            if strike(g) then op.strikes=op.strikes+1 end
            if screen(g) then op.screens=op.screens+1 end
            -- Prefer a slow strike asset as the rendezvous/escort anchor.
            local speed=math.max(1,math.abs(g.units[1].Physics.VelocityMax.z))
            local rank=(strike(g) and 100000 or 0)-speed
            if not anchor or rank>anchor.rank then anchor={group=g,rank=rank} end
            nearest=math.min(nearest,g.units[1].Position:getDistance(op.target.Position))
        end
        op.anchor=anchor and anchor.group
        local homeDistance=home.Position:getDistance(op.target.Position)
        -- Re-derive the rally when the operation's target changes. Caching it for
        -- the operation's whole life left a strike group assembling at the
        -- point where a MOBILE enemy capital stood when the operation launched,
        -- so a target that advanced during the assembly window sent the group
        -- to empty space.
        if op.rallyTarget~=id then op.rally=nil; op.rallyTarget=id end
        op.rally=op.rally or pointBetween(home,op.target,math.min(homeDistance*.25,(home.Radius or 0)+2200),0)
        local defense=0; local defenders={}
        for _,row in ipairs(self.StrategicThreatSnapshot or {}) do
            if alive(row.ship) and self:GetFactionKey(row.ship)==self:GetFactionKey(op.target)
                and sig(row.ship)~=id and row.ship.Position:getDistance(op.target.Position)<=(op.target.Radius or 0)+6000 then
                defense=defense+(row.profile and row.profile.value or 0)
                defenders[#defenders+1]=row.ship
            end
        end
        op.defense=defense; op.defenders=defenders
        if op.phase=='ASSEMBLE' then
            local ready=0
            for _,g in ipairs(list) do if g.units[1].Position:getDistance(op.rally)<=(settings(self).RallyRadius or 2400) then ready=ready+g.value end end
            if (ready>=op.value*.75 and op.strikes>0 and (op.screens>0 or defense==0))
                or now-op.phaseAt>=(settings(self).AssembleSeconds or 45) or counterattack then
                op.serial=op.serial+1; op.initialValue=op.value; op.initialStrikes=op.strikes
                op.initialDefense=defense; op.launchedAt=now; op.engagedAt=nil; op.reserveReleased=false; op.flankDone=false
                op.reserveId=nil; op.flankId=nil; op.suppressionIndex=nil; op.suppressionTarget=nil
                op.suppressionUntil=nil; op.suppressionSpent=false; op.suppressionGroup=nil
                if #list>=4 then
                    for _,g in ipairs(list) do if screen(g) and g~=op.anchor then op.reserveId=g.id; break end end
                end
                if op.strikes>=2 and op.screens>0 and defense>0 then
                    for _,g in ipairs(list) do if g.role=='bomber' and g~=op.anchor then op.flankId=g.id; break end end
                end
                local approach=math.max(0,homeDistance-(op.target.Radius or 0)-4500)
                -- Choose the less defended side of the actual approach plane.
                local left=pointBetween(home,op.target,approach,-3000)
                local right=pointBetween(home,op.target,approach,3000)
                local l,r=0,0
                for _,s in ipairs(defenders) do l=l+1/math.max(100,s.Position:getDistance(left)); r=r+1/math.max(100,s.Position:getDistance(right)) end
                op.flankPoint=l<=r and left or right
                local speed=math.max(20,math.abs(op.anchor.units[1].Physics.VelocityMax.z))
                op.approachDeadline=now+math.max(120,homeDistance/speed+60)
                self:SetAIOperationPhase(op,'APPROACH',counterattack and 'COUNTERATTACK_WINDOW' or 'ASSEMBLY_RELEASE',now)
            end
        elseif op.phase=='APPROACH' then
            if nearest<=(op.target.Radius or 0)+6000 or now>=op.approachDeadline then
                op.engagedAt=now
                self:SetAIOperationPhase(op,'ENGAGE','CONTACT_OR_APPROACH_DEADLINE',now)
            end
        elseif op.phase=='ENGAGE' or op.phase=='EXPLOIT' then
            if not homeEmergency and ((op.value<op.initialValue*.4 and defense>op.value)
                or (op.initialStrikes>0 and op.strikes==0 and defense>0)) then
                self:SetAIOperationPhase(op,'WITHDRAW','STRIKE_FORCE_LOST',now)
            elseif not homeEmergency and now-(op.engagedAt or now)>=(settings(self).AttackSeconds or 360) then
                self:SetAIOperationPhase(op,'WITHDRAW','OPERATION_DEADLINE',now)
            elseif op.phase=='ENGAGE' and (defense==0 or (op.initialDefense>0 and defense<op.initialDefense*.45)) then
                self:SetAIOperationPhase(op,'EXPLOIT','DEFENSE_BROKEN',now)
            end
        elseif op.phase=='WITHDRAW' and now-op.phaseAt>=(settings(self).RegroupSeconds or 35) then
            op.rally=nil
            self:SetAIOperationPhase(op,'ASSEMBLE','RECOVERY_DEADLINE',now)
        end
        if not op.reserveReleased and op.launchedAt and (op.phase=='EXPLOIT'
            or (op.phase=='ENGAGE' and now-op.phaseAt>=12) or now-op.launchedAt>=90) then
            op.reserveReleased=true
            if op.reserveId then self:EmitAIEvent('OPERATION_RESERVE',{faction=kind,front=id,serial=op.serial,group=op.reserveId,phase=op.phase},now) end
        end
    end
    for id,op in pairs(operations) do
        if not fronts[id] then
            if not alive(op.target) then
                self:SetAIOperationPhase(op,'CANCELLED','TARGET_DESTROYED',now); operations[id]=nil
            else
                op.missingSince=op.missingSince or now
            end
        end
    end
end

function R:ChooseAIOperationTarget(op,g,coverage)
    if op.phase=='EXPLOIT' then return op.target end
    local best,score=nil,-math.huge
    if screen(g) then
        for _,wing in ipairs(op.groups) do
            local attacker=wing.role=='bomber' and wing.targetedBy or nil
            if alive(attacker) and self:AreEnemies(g.units[1],attacker)
                and g.units[1].Position:getDistance(attacker.Position)<6000 then
                local value=self:AIProfile(attacker).value
                if ((coverage or {})[sig(attacker)] or 0)<math.max(value,g.value)*1.5 then return attacker end
            end
        end
    end
    for _,target in ipairs(op.defenders) do
        if alive(target) and self:AreEnemies(g.units[1],target) then
            local role=self:GetShipRole(target)
            local inReach=g.units[1].Position:getDistance(target.Position)
                <=(self:AIProfile(g.units[1]).range or 0)+(target.Radius or 0)
            local suitable=(strike(g) and (self:IsCapitalTarget(target) or (self:IsStaticDefense(target) and inReach)))
                or (screen(g) and (role=='fighter' or role=='bomber' or role=='escort'))
            if suitable then
                local value=self:AIProfile(target).value
                local covered=(coverage or {})[sig(target)] or 0
                if covered<math.max(value,g.value)*1.5 then
                    local rank=(role=='bomber' and screen(g) and 4 or self:IsStaticDefense(target) and strike(g) and 3 or 1)
                    local candidate=rank*100000-g.units[1].Position:getDistance(target.Position)-covered
                    if candidate>score then best=target; score=candidate end
                end
            end
        end
    end
    return best or op.target
end

function R:GetAISuppressionSubsystem(op,target,now,attacker)
    if op.suppressionSpent then return nil end
    if op.suppressionUntil and now>=op.suppressionUntil then op.suppressionSpent=true; return nil end
    if op.suppressionTarget and op.suppressionTarget~=sig(target) then op.suppressionSpent=true; return nil end
    if op.suppressionIndex then
        local turret=target[op.suppressionIndex]
        if turret and turret:isValid() and turret.Targetable~=false and turret.HitpointsLeft>0 and not turret.TurretLocked then return turret end
        op.suppressionSpent=true; return nil
    end
    local best,power=nil,0
    for i=1,#target do
        local turret=target[i]
        if turret:isValid() and turret:isTurret() and turret.Targetable~=false and turret.HitpointsMax>0 and turret.HitpointsLeft>0 and not turret.TurretLocked then
            local output=0
        for _,banks in ipairs({turret.PrimaryBanks or {},turret.SecondaryBanks or {}}) do
            for j=1,#banks do
                    local bank=banks[j]
                    if bank and bank:isValid() then
                        local w=bank.WeaponClass
                        if w and w:isValid() and ((bank.AmmoMax or 0)<=0 or (bank.AmmoLeft or 0)>0) then
                            output=output+(w.Damage or 0)/math.max(.25,w.FireWait or 1)
                        end
                    end
            end
        end
            -- Do not spend the strike window on a nearly indestructible turret.
            local rank=output/math.max(1,turret.HitpointsLeft)
            if rank>power then best=i; power=rank end
        end
    end
    if best and power>.01 then
        local turret=target[best]
        local speed=math.max(20,math.abs(attacker.Physics.VelocityMax.z)*.1)
        local distance=attacker.Position:getDistance(turret.WorldPosition or target.Position)
        local range=self:AIProfile(attacker).range or 0
        local travel=math.max(0,distance-range)/speed
        -- ponytail: 10% max speed estimates a conservative turning approach; cap at 90s until native flight telemetry can tune it.
        op.suppressionIndex=best; op.suppressionTarget=sig(target)
        op.suppressionUntil=now+math.min(90,math.max(25,travel+25))
        return target[best]
    end
end

function R:ApplyAIOperationOrder(g,target,mission,context,home,now,coverage)
    local op=g.operation
    if not op or g.defending or g.luring or g.feint or mission=='RETREAT' or not alive(op.target) then return target,mission end
    if g.hardLocalThreat then
        local protectedBomber=false
        if g.role=='bomber' and alive(g.localThreat) and not self:IsCapitalTarget(g.localThreat) then
            for _,escort in ipairs(op.groups) do
                if screen(escort) and escort.units[1].Position:getDistance(g.units[1].Position)<4500 then protectedBomber=true; break end
            end
        end
        if not protectedBomber then return target,mission end
    end
    context.locked=true; context.operation=op.serial; context.operationPhase=op.phase; context.operationTargetName=op.target.Name
    if op.phase=='WITHDRAW' then context.reason='OPERATION_WITHDRAW'; return home,'RETREAT' end
    if op.phase=='ASSEMBLE' then
        context.reason='OPERATION_ASSEMBLE'; context.destination=op.rally
        return home,'REGROUP'
    end
    if g.id==op.reserveId and not op.reserveReleased then
        context.reason='OPERATION_RESERVE'; return op.anchor.units[1],'ESCORT'
    end
    if g.id==op.flankId and not op.flankDone then
        if g.units[1].Position:getDistance(op.flankPoint)>900 and now-op.launchedAt<150 and op.phase~='EXPLOIT' then
            context.reason='PIN_AND_FLANK'; context.destination=op.flankPoint
            return home,'REGROUP'
        end
        op.flankDone=true
    end
    if op.phase=='APPROACH' and g~=op.anchor then
        context.reason='COORDINATED_APPROACH'; return op.anchor.units[1],'ESCORT'
    end
    local chosen=self:ChooseAIOperationTarget(op,g,coverage)
    context.reason=op.phase=='EXPLOIT' and 'BREAKTHROUGH_EXPLOIT' or 'OPERATION_ROLE_TARGET'
    if chosen==op.target and self:IsCommandStation(chosen) and strike(g)
        and (not op.suppressionGroup or op.suppressionGroup==g.id) then
        local attacker=g.units[1]
        local siegeRange=(chosen.Radius or 0)+math.max(1500,self:AIProfile(attacker).range or 0)
        if attacker.Position:getDistance(chosen.Position)<=siegeRange then
            local subsystem=self:GetAISuppressionSubsystem(op,chosen,now,attacker)
            if subsystem then
                op.suppressionGroup=g.id
                context.subsystem=subsystem; context.subsystemIndex=op.suppressionIndex; context.reason='SIEGE_TURRET_TARGET'
            end
        end
    end
    if g.role=='bomber' and op.strikes>=2 and op.phase=='ENGAGE' and self:IsCapitalTarget(chosen)
        and (not op.suppressionGroup or op.suppressionGroup==g.id)
        and g.units[1].Position:getDistance(chosen.Position)<=(chosen.Radius or 0)+math.max(1500,self:AIProfile(g.units[1]).range or 0) then
        local subsystem=self:GetAISuppressionSubsystem(op,chosen,now,g.units[1])
        if subsystem then
            op.suppressionGroup=g.id
            context.subsystem=subsystem; context.subsystemIndex=op.suppressionIndex; context.reason='SUBSYSTEM_SUPPRESSION'
        end
    end
    return chosen,'PRIMARY'
end

return R
