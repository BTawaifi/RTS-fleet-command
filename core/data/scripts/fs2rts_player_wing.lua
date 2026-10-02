-- Temporarily expose logical wingmates to the native player-wing HUD and orders.
local U=require 'fs2rts_util'
local R=require 'fs2rts_state'
local valid,alive=U.shipValid,U.shipAlive

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
