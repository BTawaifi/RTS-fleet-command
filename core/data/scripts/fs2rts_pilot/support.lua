-- Route the native rearm shortcut to the controlled hull's tender request.
local shared=require "fs2rts_pilot.common"
local RTS,shipAlive=shared.RTS,shared.shipAlive

local function pilotSupportAction()
    if not RTS.Enabled or not RTS.PossessedSignature then return false end
    if RTS.Paused or RTS.PendingPilotEject then return true end
    local ship=RTS:GetPossessedShip()
    if not shipAlive(ship) then return true end
    local id=ship:getSignature()
    local request=RTS.FleetServiceRequests and RTS.FleetServiceRequests[id]
    local service=RTS.FleetServices and RTS.FleetServices[id]
    if request or (service and service.pilot) then
        if request then RTS:CancelFleetServiceRequestForShip(ship) end
        if service and service.pilot then
            RTS:StopTenderForService(service.serviceAnchor,id)
            RTS:CancelFleetServiceForShip(ship)
        end
        RTS.FleetServiceCooldown=RTS.FleetServiceCooldown or {}
        RTS.FleetServiceCooldown[id]=mn.getMissionTime()+(RTS.Config.Station.FleetService.RetrySeconds or 30)
        RTS.PilotSupportNotice={text='TENDER REQUEST CANCELLED',untilTime=RTS:UINow()+3}
    elseif RTS:RequestFleetService(ship,'PILOT_SERVICE',mn.getMissionTime(),true) then
        RTS.PilotSupportNotice={text='TENDER REQUESTED',untilTime=RTS:UINow()+3}
    else
        RTS.PilotSupportNotice={text='TENDER SERVICE UNAVAILABLE',untilTime=RTS:UINow()+3}
    end
    return true
end

function RTS:SetPilotSupportHook(enabled)
    if not io.Keybinding then return false end
    local binding=io.Keybinding.REARM_MESSAGE
    if not binding or binding.Name~='REARM_MESSAGE' or type(binding.registerHook)~='function' then return false end
    if enabled then binding:registerHook(pilotSupportAction,false,true)
    elseif not self.PilotSupportHookActive then return false end
    binding:enableScripting(enabled)
    self.PilotSupportHookActive=enabled
    return true
end
