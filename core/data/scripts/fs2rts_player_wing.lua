-- Temporarily expose logical wingmates to the native player-wing HUD and orders.
local U=require 'fs2rts_util'
local R=require 'fs2rts_state'
local valid,alive=U.shipValid,U.shipAlive

function R:GetPilotWingmates()
    local logical=self:GetLogicalWing(self:GetPossessedShip())
    local group=self:GetPilotCommGroup()
    if group then logical={label='Control group '..group,signatures=self.ControlGroups[group]} end
    local result={}
    if logical then
        for _,id in ipairs(logical.signatures) do
            local ship=self:FindShipBySignature(id)
            if alive(ship) and id~=self.PossessedSignature and ship.Name~=self.Config.ObserverShip
                and self:IsMovableFriendly(ship) and not self:IsCommandStation(ship) then result[#result+1]=ship end
        end
    end
    return result,logical and logical.label
end

function R:OnPilotCommMenuOpened()
    if self.Enabled and self.PossessedSignature and not self.PendingPilotEject then
        self.PilotCommMenuActive=true
        self.PilotCommMenuPending=true
    end
end

function R:OnPilotCommMenuClosed()
    self.PilotCommMenuActive=false
    self.PilotCommMenuPending=nil
end

function R:UpdatePilotCommMenu()
    if not self.PilotCommMenuPending or not mn.CommItems then return end
    -- Logical wings are not native mission wings on upstream. Open the native
    -- broadcast command list; the command-issued hook filters it to our wing.
    for i=1,#mn.CommItems do
        local item=mn.CommItems[i]
        if item.Name=='All Fighters' then
            self.PilotCommMenuPending=nil
            if item.Active then item:selectItem() end
            return
        end
    end
end

-- Native broadcasts fan out through this hook before installing each goal.
-- Never allow a wing goal to carry the hidden player proxy out of the mission.
function R:GetPilotCommRecipients(recipient)
    local allowed={}
    for _,ship in ipairs(self:GetPilotWingmates()) do allowed[ship:getSignature()]=true end
    local result={}
    if not recipient then return result end
    recipient:forAllShips(function(ship)
        if alive(ship) and allowed[ship:getSignature()] and ship:getSignature()~=self.PossessedSignature
            and ship.Name~=self.Config.ObserverShip and self:IsMovableFriendly(ship) and not self:IsCommandStation(ship) then
            result[#result+1]=ship
        end
    end)
    return result
end

local function depart(order,name)
    return name=='Depart' or order=='Depart' or (order~=nil and order==SQUAD_MESSAGE_DEPART)
end

function R:GetPilotCommGroup()
    for group=1,4 do
        for _,id in ipairs((self.ControlGroups or {})[group] or {}) do
            if id==self.PossessedSignature then return group end
        end
    end
end

function R:ShouldOverridePilotCommOrder(recipient,order,name)
    if not self.Enabled then return false end
    if depart(order,name) then return true end
    if self.PossessedSignature==nil or self.PendingPilotEject or self.Paused then return true end
    local permitted=self:GetPilotCommRecipients(recipient)
    local total=0
    if recipient then recipient:forAllShips(function() total=total+1 end) end
    return total==0 or #permitted~=total or order~=nil
end

function R:OnPilotCommOrder(recipient,order,target,subsystem,name)
    if not self.Enabled then return end
    if depart(order,name) then
        self.PilotCommWarningUntil=self:UINow()+4
        self.PilotCommWarningText='DEPART IS DISABLED'
        self:SetStatus('Depart is disabled in fleet command.',4)
        return
    end
    local permitted=self:GetPilotCommRecipients(recipient)
    local group=self:GetPilotCommGroup()
    if self.PossessedSignature==nil or self.PendingPilotEject or self.Paused or #permitted==0
        or (not group and self:ShouldOverridePilotCommOrder(recipient)) then
        self.PilotCommWarningUntil=self:UINow()+4
        self.PilotCommWarningText='COMMAND YOUR WING / GROUP ONLY'
        self:SetStatus('Commands are limited to your wingmates. Your hull, stations and other wings are protected.',4)
        return
    end
    local nativeKind,orderTarget,orderSubsystem
    if order~=nil then
        local function is(key,label) return name==label or order==label or (order~=nil and _G['SQUAD_MESSAGE_'..key]~=nil and order==_G['SQUAD_MESSAGE_'..key]) end
        orderTarget=target
        if is('ATTACK_TARGET','Attack my target') then nativeKind=ORDER_ATTACK
        elseif is('DISABLE_TARGET','Disable my target') then nativeKind=ORDER_DISABLE
        elseif is('DISARM_TARGET','Disarm my target') then nativeKind=ORDER_DISARM
        elseif is('PROTECT_TARGET','Protect my target') then nativeKind=ORDER_GUARD
        elseif is('IGNORE_TARGET','Ignore my target') then nativeKind=ORDER_IGNORE_SHIP
        elseif is('ENGAGE_ENEMY','Engage enemy') then nativeKind=ORDER_ATTACK_ANY; orderTarget=nil
        elseif is('FORMATION','Form on my wing') or is('COVER_ME','Cover me') then nativeKind=ORDER_GUARD; orderTarget=self:GetPossessedShip()
        elseif is('STAY_NEAR_ME','Stay near me') then nativeKind=ORDER_STAY_NEAR; orderTarget=self:GetPossessedShip()
        elseif is('STAY_NEAR_TARGET','Stay near my target') then nativeKind=ORDER_STAY_NEAR
        elseif is('KEEP_SAFE_DIST','Keep safe distance') then nativeKind=ORDER_KEEP_SAFE_DISTANCE; orderTarget=nil
        elseif is('DISABLE_SUBSYSTEM','Destroy my subsystem') then nativeKind=ORDER_ATTACK; orderSubsystem=subsystem end
        if nativeKind==nil or (orderTarget~=nil and not alive(orderTarget))
            or (nativeKind~=ORDER_ATTACK_ANY and nativeKind~=ORDER_KEEP_SAFE_DISTANCE and orderTarget==nil) then
            self:SetStatus('This command has no valid fleet-group target.',3); return
        end
        if (nativeKind==ORDER_ATTACK or nativeKind==ORDER_DISABLE or nativeKind==ORDER_DISARM)
            and not self:AreEnemies(self:GetPossessedShip(),orderTarget) then
            self:SetStatus('Attack commands require a hostile target.',3); return
        end
        local token=table.concat({group or 'wing',tostring(order),target and valid(target) and target:getSignature() or 0,mn.getMissionTime()},':')
        if self.PilotCommGroupToken==token then return end
        self.PilotCommGroupToken=token
        permitted=self:GetPilotWingmates()
    end
    self.PilotCommOrders=self.PilotCommOrders or {}
    for _,ship in ipairs(permitted) do
        local id=ship:getSignature()
        if not self.PilotCommOrders[id] then self.PilotCommOrders[id]={previous=self.UserOrders[id]} end
        self:SetUserOrder(ship,{kind='wing'})
        if nativeKind then
            ship:clearOrders(); ship:giveOrder(nativeKind,orderTarget,orderSubsystem,.95)
            if nativeKind==ORDER_GUARD or nativeKind==ORDER_STAY_NEAR then self:SetNativeGuardRange(ship,orderTarget,self.Config.AI.CohesionRadius) end
        end
    end
end

function R:RestorePilotCommOrders()
    self.PilotCommMenuPending=nil
    self.PilotCommGroupToken=nil
    for id,saved in pairs(self.PilotCommOrders or {}) do
        local ship=self:FindShipBySignature(id)
        if alive(ship) and self.UserOrders[id] and self.UserOrders[id].kind=='wing' then
            self.UserOrders[id]=saved.previous
            if saved.previous then self:ReissueUserOrder(ship,saved.previous) else self:ReturnToDefaultControl(ship) end
        end
    end
    self.PilotCommOrders=nil
end

function R:JoinPilotNativeWing(pilot)
    if self.Config and self.Config.Pilot and self.Config.Pilot.NativeWingExtensions==false then return nil end
    local detached,detachError=self:LeavePilotNativeWing()
    if not detached then return nil,detachError end
    local logical=self:GetLogicalWing(pilot)
    local observer=self:GetObserver()
    if logical==nil then return nil end
    if not alive(pilot) or not valid(observer) then return nil,'native player wing is unavailable' end

    local ok,wing=pcall(function() return observer:getWing() end)
    if not ok or wing==nil then return nil,'native player wing is unavailable' end
    local countOk,count=pcall(function() return #wing end)
    local nameOk,name=pcall(function() return wing.Name end)
    if not countOk or count<0 or not nameOk or name==nil or name=='' then
        return nil,'native player wing is unavailable; rebuild FSO with dynamic wing support'
    end

    local members={}
    for _,signature in ipairs(logical.signatures) do
        if signature~=pilot:getSignature() and signature~=observer:getSignature() then
            local ship=self:FindShipBySignature(signature)
            if alive(ship) then
                local wingOk,shipWing=pcall(function() return ship:getWing() end)
                local memberCountOk,memberCount=pcall(function() return #shipWing end)
                if not wingOk or not memberCountOk then return nil,'native wing roster could not be read' end
                if memberCount>0 then
                    local memberNameOk,memberName=pcall(function() return shipWing.Name end)
                    if not memberNameOk or memberName~=name then
                        return nil,'logical wingmate already belongs to another native wing'
                    end
                else members[#members+1]=ship end
            end
        end
    end
    if #members==0 then return nil,'logical wing has no available wingmates' end

    local state={wing=wing,name=name,label=logical.label,displayName=wing.DisplayName,members={}}
    for _,ship in ipairs(members) do
        local addedOk,added,hudWingIndex,hudSlot=pcall(function() return wing:addPlayerWingMember(ship) end)
        if not addedOk or added~=true then
            local failure=addedOk and 'native player wing rejected the logical wing' or
                'native player-wing API unavailable; rebuild FSO with dynamic wing support'
            if #state.members==0 then return nil,failure end
            self.PilotNativeWing=state; self.PilotNativeWingLabel=logical.label
            pcall(function() wing.DisplayName=logical.label end)
            for _,entry in ipairs(state.members) do
                local member=self:FindShipBySignature(entry.signature)
                entry.userOrderApplied=true
                if alive(member) then pcall(function() self:SetUserOrder(member,{kind='wing',wingName=name,wingLabel=logical.label}) end) end
            end
            local cleaned,cleanupError=self:LeavePilotNativeWing()
            if cleaned then return nil,failure end
            return nil,cleanupError
        end
        local signature=ship:getSignature()
        state.members[#state.members+1]={signature=signature,order=self.UserOrders[signature],
            hudWingIndex=hudWingIndex,hudSlot=hudSlot,userOrderApplied=false}
    end

    self.PilotNativeWing=state
    self.PilotNativeWingLabel=logical.label
    pcall(function() wing.DisplayName=logical.label end)
    for _,entry in ipairs(state.members) do
        local ship=self:FindShipBySignature(entry.signature)
        if alive(ship) then
            entry.userOrderApplied=true
            local setOk=pcall(function() self:SetUserOrder(ship,{kind='wing',wingName=name,wingLabel=logical.label}) end)
            if not setOk or self.UserOrders[entry.signature]==nil or self.UserOrders[entry.signature].kind~='wing' then
                local _,leaveError=self:LeavePilotNativeWing()
                return nil,leaveError or 'RTS could not hand wing control back safely'
            end
        end
    end
    return logical.label
end

function R:LeavePilotNativeWing(wingState)
    local state=wingState or self.PilotNativeWing
    if state==nil then return true end
    local remaining={}
    for i=#state.members,1,-1 do
        local entry=state.members[i]
        local ship=self:FindShipBySignature(entry.signature)
        local detached=not alive(ship)
        if alive(ship) then
            local removeOk,removed=pcall(function() return state.wing:removePlayerWingMember(ship) end)
            detached=removeOk and removed==true
        end
        if not detached then
            remaining[#remaining+1]=entry
            if entry.userOrderApplied then
                self.UserOrders[entry.signature]={kind='wing',wingName=state.name,wingLabel=self.PilotNativeWingLabel or state.name}
            end
        elseif entry.userOrderApplied then
            if entry.order~=nil and entry.order.kind~='service' then
                self.UserOrders[entry.signature]=entry.order
            else
                self.UserOrders[entry.signature]=nil
            end
            self.PolicyApplied[entry.signature]=nil
            self.AIOrderState[entry.signature]=nil
            if alive(ship) then
                if self.UserOrders[entry.signature]~=nil then self:ReissueUserOrder(ship,self.UserOrders[entry.signature])
                else self:ReturnToDefaultControl(ship) end
            end
        end
    end
    state.members=remaining
    if #remaining==0 then
        pcall(function() state.wing.DisplayName=state.displayName end)
        if wingState==nil then self.PilotNativeWing=nil end
        self.PilotNativeWingLabel=nil
        return true
    end
    self.PilotNativeWing=state
    self.PilotNativeWingLabel=state.label
    return false,'native wing cleanup incomplete; attached ships remain under wing command'
end

return R
