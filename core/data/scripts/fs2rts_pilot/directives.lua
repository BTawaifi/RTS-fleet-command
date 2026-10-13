-- Pilot tactical orders, navigation and directives.
local _shared = require "fs2rts_pilot.common"
local RTS, shipAlive, shipValid, vec, objectValid = _shared.RTS, _shared.shipAlive, _shared.shipValid, _shared.vec, _shared.objectValid

function RTS:GetPilotTacticalOrder()
    local pilot=self:GetPossessedShip()
    local withdrawal=shipValid(pilot) and self.Withdrawals and self.Withdrawals[pilot:getSignature()]
    if withdrawal then
        return {mission='WITHDRAW',destination=withdrawal.destination,operationPhase=withdrawal.phase,
            reason='IRREVERSIBLE EXTRACTION'},'EXTRACTION'
    end
    local order=self.PilotPreviousUserOrder
    local source='YOUR ORDER'
    if not order then
        order=self.PilotAIObjective; source='LAST AI ORDER'
        -- Possession removes this ship from AI execution. Read its wing's
        -- current assignment when available without issuing goals from HUD.
        if self.AutoPlayerMode and order and order.group then
            local latest,bestId=nil,nil
            for id,candidate in pairs(self.AIOrderState or {}) do
                if candidate.group==order.group then
                    local member=self:FindShipBySignature(id)
                    if shipAlive(member) and self:IsFriendly(member) and (not latest
                        or (candidate.installedAt or 0)>(latest.installedAt or 0)
                        or ((candidate.installedAt or 0)==(latest.installedAt or 0) and id<bestId)) then
                        latest,bestId=candidate,id
                    end
                end
            end
            if latest then order=latest; source='AI WING ORDER' end
        end
    end
    if not order then
        local pilot=self:GetPossessedShip()
        if shipAlive(pilot) then
            local target=pilot.Target
            if not shipAlive(target) or not self:AreEnemies(pilot,target) then target=self:FindShipBySignature(self.PilotSuggestedTarget) end
            if (not shipAlive(target) or not self:AreEnemies(pilot,target)) and self:UINow()>=(self.PilotSuggestedAt or -1) then
                self.PilotSuggestedAt=self:UINow()+1
                local nearest=math.huge
                self:EachShip(function(candidate)
                    if shipAlive(candidate) and self:AreEnemies(pilot,candidate) and candidate.Name~=self.Config.ObserverShip then
                        local distance=pilot.Position:getDistance(candidate.Position)
                        if distance<nearest then target=candidate; nearest=distance end
                    end
                end)
            end
            if shipAlive(target) and self:AreEnemies(pilot,target) then
                self.PilotSuggestedTarget=target:getSignature()
                order={mission='ENGAGE',targetSignature=target:getSignature(),reason='HOSTILE_CONTACT'}
                source='SUGGESTED TASK'
            end
        end
    end
    return order,source
end

function RTS:GetPilotNavigationPoint(order)
    if not order then return nil end
    if order.destination and self:IsFiniteVector(order.destination) then return order.destination,'RALLY' end
    local target=order.targetSignature and self:FindShipBySignature(order.targetSignature)
    if shipAlive(target) then return target.Position,'TARGET' end
end

function RTS:GetPilotObjectiveLines()
    local lines={'','','',''}
    local order,source=self:GetPilotTacticalOrder()
    if not order then lines[1]='No live tactical target'; return lines end
    local task=tostring(order.mission or order.kind or order.label or 'ORDER'):gsub('_',' ')
    if task=='PRIMARY' then task='ASSAULT' end
    lines[1]=source..': '..task
    if order.targetSignature then
        local target=self:FindShipBySignature(order.targetSignature)
        lines[2]=shipAlive(target) and ('TARGET: '..target.Name) or 'Target destroyed / unavailable'
    end
    if order.operationPhase then lines[3]='PHASE: '..tostring(order.operationPhase):gsub('_',' ') end
    if order.posture then lines[3]=lines[3]..(lines[3]~='' and ' | ' or '')..tostring(order.posture):gsub('_',' ') end
    if order.reason then lines[4]='WHY: '..tostring(order.reason):gsub('_',' ') end
    local point,label=self:GetPilotNavigationPoint(order)
    local pilot=self:GetPossessedShip()
    if point and shipAlive(pilot) then
        local delta=point-pilot.Position
        local orientation=pilot.Orientation
        local forward,right,up=orientation:getFvec(),orientation:getRvec(),orientation:getUvec()
        local function dot(a,b) return a.x*b.x+a.y*b.y+a.z*b.z end
        local along,lateral,vertical=dot(delta,forward),dot(delta,right),dot(delta,up)
        local yaw=math.deg(math.atan2(lateral,along))
        local pitch=math.deg(math.atan2(vertical,math.sqrt(along*along+lateral*lateral)))
        lines[3]=string.format('%s %.1f km | %s %.0f deg | %s %.0f deg',label,delta:getDistance(vec(0,0,0))/1000,
            yaw<0 and 'LEFT' or 'RIGHT',math.abs(yaw),pitch<0 and 'DOWN' or 'UP',math.abs(pitch))
        if label=='RALLY' then lines[2]=lines[2]..(lines[2]~='' and ' | ' or '')..string.format('MOVE TO %.0f, %.0f, %.0f',point.x,point.y,point.z) end
        if order.posture then lines[4]=tostring(order.posture):gsub('_',' ')..' | '..lines[4] end
        if order.operationPhase then lines[4]=tostring(order.operationPhase):gsub('_',' ')..' | '..lines[4] end
    end
    return lines
end

function RTS:UpdatePilotDirectives(clear)
    if not mn.Events then return end
    local names={'RTS Pilot Task','RTS Pilot Target','RTS Pilot Phase','RTS Pilot Reason'}
    local lines=clear and {'','','',''} or self:GetPilotObjectiveLines()
    for i,name in ipairs(names) do
        local event=mn.Events[name]
        if objectValid(event) then
            -- Native directives copy into a 256-byte display buffer. Keep each
            -- field bounded; the stock gauge owns wrapping, color and placement.
            local text=self:FitPilotDirective(lines[i])
            if event.DirectiveText~=text then event.DirectiveText=text end
        elseif not self.PilotDirectiveWarningShown then
            self:Log('Pilot tactical directive events missing from this mission')
            self.PilotDirectiveWarningShown=true
        end
    end
end

function RTS:FitPilotDirective(text)
    -- Stock FSO splits an event only once. Bound the continuation too, leaving
    -- room for its 12-pixel indent inside the 167-pixel retail directives frame.
    local previous=gr.CurrentFont
    local font=gr.Fonts and gr.Fonts[1]
    if font and font:isValid() then gr.CurrentFont=font end
    local lines=self:WrapTextLinesToWidth(text,150,2)
    local result=table.concat(lines,'\n'):sub(1,200)
    if previous then gr.CurrentFont=previous end
    return result
end

function RTS:OnPilotCountermeasureFired(source,weapon)
    local observer=self:GetObserver()
    if not self.Enabled or not self.PossessedSignature or not shipValid(source) or not shipValid(observer)
        or source:getSignature()~=observer:getSignature() or not objectValid(weapon) then return end
    local ship=self:GetPossessedShip()
    if self.Paused or self.PendingPilotEject or not shipAlive(ship) or self:IsShipWithdrawing(ship) or ship.CountermeasuresLeft<=0 then
        weapon:vanish()
        return
    end
    -- The native action already launched one decoy from the mirrored proxy.
    -- Transfer its ownership after launch initialization; a second Lua launch
    -- duplicates it because an overridden binding leaves FSO's fire bit set.
    weapon.Parent=ship
    ship.CountermeasuresLeft=ship.CountermeasuresLeft-1
    observer.CountermeasuresLeft=ship.CountermeasuresLeft
end

function RTS:SetPilotWeaponCycleHooks(enabled)
    local actions={'CYCLE_NEXT_PRIMARY','CYCLE_PREV_PRIMARY','CYCLE_SECONDARY'}
    if not io.Keybinding then return end
    for _,action in ipairs(actions) do
        local binding=io.Keybinding[action]
        if not binding or binding.Name~=action or type(binding.registerHook)~='function' then return end
    end
    for _,action in ipairs(actions) do
        local direction=action=='CYCLE_PREV_PRIMARY' and -1 or 1
        local binding=io.Keybinding[action]
        if enabled then
            binding:registerHook(function()
                if not self.Enabled or not self.PossessedSignature then return false end
                if not self.PilotTurretGroups or #self.PilotTurretGroups==0 then return false end
                local ship=self:GetPossessedShip()
                local banks=shipValid(ship) and (action=='CYCLE_SECONDARY' and ship.SecondaryBanks or ship.PrimaryBanks)
                if banks and #banks>0 then return false end
                if not self.Paused and not self.PendingPilotEject then self:CyclePilotTurretGroup(direction) end
                return true
            end,false,true)
        end
        binding:enableScripting(enabled)
    end
    self.PilotWeaponCycleHooksActive=enabled
end
