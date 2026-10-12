-- HUD selected-unit card: action buttons, controller colours, loadout readout.
local _shared = require "fs2rts_hud.common"
local RTS, objectValid, clamp, shipValid, CONTROLLER_COLORS = _shared.RTS, _shared.objectValid, _shared.clamp, _shared.shipValid, _shared.CONTROLLER_COLORS

function RTS:GetActionButtonState(id,commandable,pilotable,hasSelection)
    if id=="selectall" then return true,false end
    if id=="pilot" then return pilotable,false end
    if id=="focus" then return hasSelection,false end
    if id=="move" then return commandable,self.ArmedCommand=="move" end
    if id=="attack" then return commandable,self.ArmedCommand=="attack" end
    return commandable,false
end

function RTS:GetControllerColor(ship,controller)
    if controller=="enemy" then
        local kind=self:GetFactionKey(ship)
        if kind then return self:GetFactionColor(kind) end
        return 255,165,145
    end
    local c=CONTROLLER_COLORS[controller] or CONTROLLER_COLORS.station
    return c[1],c[2],c[3]
end

-- Truncation is done in PIXELS, via RTS:TruncateToWidth in ui_text.lua. The
-- removed character-counting helper was wrong for FSO's proportional default
-- font: a 8px-per-character budget is narrower than the real glyphs for
-- capitals and wider for lowercase, so labels were cut at the wrong place and
-- overflowed their pane on the way out.

function RTS:GetSelectionRowOrderLabel(ship,controller)
    if controller=="enemy" then return "CONTACT" end
    if controller=="order" then return string.upper(tostring(self.UserOrders[ship:getSignature()].kind)) end
    if controller=="policy" then return tostring(self.GlobalPolicy) end
    if controller=="auto" then return "AUTO" end
    if controller=="pilot" then return "PILOT" end
    if controller=="sentry" then return "SENTRY" end
    if controller=="station" then return "STATION" end
    return self:GetShipShortOrderLabel(ship)
end

-- isTurret() raises on a subsystem handle that is not a turret, so the call
-- has to stay guarded. The guard used to be an inline closure built inside the
-- per-subsystem loop, which allocated a fresh pcall target for every subsystem
-- of every selected ship on every frame; hoisting it allocates nothing.
local function isTurretSubsystem(turret)
    local ok, isTurret = pcall(function() return turret:isTurret() end)
    return ok and isTurret == true
end

-- Full loadout readout. A capital keeps every weapon in turret subsystems, so
-- ship-level banks alone would report an empty arsenal for the hulls that
-- matter most.
function RTS:GetShipLoadout(ship)
    local entries={}
    local function collect(banks,label)
        for i=1,#banks do
            local bank=banks[i]; local weapon=bank.WeaponClass
            if objectValid(bank) and objectValid(weapon) then
                local name=weapon.Name or "UNKNOWN"
                local ammoMax=tonumber(bank.AmmoMax) or 0
                local ammoLeft=tonumber(bank.AmmoLeft) or 0
                local range=tonumber(weapon.Range) or 0
                if not weapon:isBeam() then range=math.min(range,(tonumber(weapon.Speed) or 0)*(tonumber(weapon.LifeMax) or 0)) end
                entries[#entries+1]={name=name,label=label,beam=weapon:isBeam(),range=range,
                    ammoMax=ammoMax,ammoLeft=ammoLeft,count=(label=="TURRET" and #entries or nil)}
            end
        end
    end
    collect(ship.PrimaryBanks or {},"PRIMARY")
    collect(ship.SecondaryBanks or {},"SECONDARY")
    local turrets=0; local lost=0
    for i=1,#ship do
        local turret=ship[i]
        if objectValid(turret) and isTurretSubsystem(turret) then
            turrets=turrets+1
            if turret.HitpointsMax>0 and turret.HitpointsLeft<=0 then lost=lost+1 end
            collect(turret.PrimaryBanks or {},"TURRET")
            collect(turret.SecondaryBanks or {},"TURRET")
        end
    end
    return entries,turrets,lost
end

-- Every field in the card is placed from the measured card box rather than
-- from a fixed 434x314 pixel rectangle, and each label is given an explicit
-- pixel budget. The card used to be a hard 14..448 / 58..372 box with internal
-- rows at literal y offsets, so on a 4K screen it was a postage stamp in the
-- corner and its long strings were clipped by the engine rather than by the
-- layout.
function RTS:DrawSelectedUnitStats(sw,sh)
    local ships=self:GetSelectedShips(); if #ships==0 then return end
    local m=self:GetUIMetrics(sw,sh)
    local x1,y1=m.margin,m.statsTop
    local x2=x1+m.selectionWidth
    local y2=y1+((#ships==1) and m.statsSingleHeight or m.statsMultiHeight)
    local pad=m.panelPadding; local inner=x2-pad; local lh=m.lineHeight
    gr.setColor(4,10,18,225); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(100,190,220,255); gr.drawRectangle(x1,y1,x2,y2,false)
    if #ships>1 then
        local total=0; local counts={order=0,policy=0,auto=0,pilot=0,sentry=0,station=0,enemy=0}
        for _,ship in ipairs(ships) do
            total=total+(ship.HitpointsMax>0 and clamp(ship.HitpointsLeft/ship.HitpointsMax*100,0,100) or 0)
            local controller=self:GetShipController(ship); counts[controller]=counts[controller]+1
        end
        gr.setColor(105,235,255,255); self:DrawTextLine("SELECTION STATS",x1+pad,y1+m.pad(10),inner-(x1+pad))
        gr.setColor(220,235,240,255)
        self:DrawTextLine("Units: "..#ships.."   Average hull: "..string.format("%.0f%%",total/#ships),x1+pad,y1+m.pad(10)+lh+4,inner-(x1+pad))
        -- The controller breakdown is laid out in a grid sized to the card
        -- rather than at a fixed 200px column pitch, which overflowed the pane
        -- on any width where the labels are wider than 200px.
        local columns=math.max(1,math.floor((x2-x1-2*pad)/(m.pad(150))))
        local cellW=math.floor((x2-x1-2*pad)/columns)
        local x=x1+pad; local y=y1+m.pad(10)+2*lh+8; local onLine=0
        for _,entry in ipairs({{"order","Your orders"},{"policy","Policy"},{"auto","Auto"},{"pilot","Piloted"},{"sentry","Sentry"},{"enemy","Enemy"}}) do
            local n=counts[entry[1]]
            if n>0 then
                if onLine==columns then x=x1+pad; y=y+lh+4; onLine=0 end
                local r,g,b=self:GetControllerColor(ships[1],entry[1]); gr.setColor(r,g,b,255)
                self:DrawTextLine(entry[2]..": "..n,x,y,cellW-6)
                x=x+cellW; onLine=onLine+1
            end
        end
        gr.setColor(155,185,198,255)
        self:DrawTextLine("Default policy: "..tostring(self.GlobalPolicy),x1+pad,y2-lh-6,inner-(x1+pad))
        return
    end
    local ship=ships[1]; local hp=ship.HitpointsMax>0 and clamp(ship.HitpointsLeft/ship.HitpointsMax*100,0,100) or 0; local sm=ship.Shields.CombinedMax or 0; local sl=ship.Shields.CombinedLeft or 0; local sp=sm>0 and clamp(sl/sm*100,0,100) or 0; local speed=math.abs(ship.Physics:getForwardSpeed()); local maxSpeed=math.abs(ship.Physics.VelocityMax.z); local wing=self:GetLogicalWing(ship)
    local y=y1+pad
    gr.setColor(105,235,255,255); self:DrawTextLine(ship.Name,x1+pad,y,inner-(x1+pad))
    local identity=ship.Class.Name
    local faction=self:GetFactionDisplayName(self:GetFactionKey(ship))
    if not ship.Name:find(faction,1,true) then identity=identity.." | "..faction end
    if wing and not ship.Name:find(wing.label,1,true) and not identity:find(wing.label,1,true) then identity=identity.." | "..wing.label end
    y=y+lh; gr.setColor(205,225,235,255)
    y=y+self:DrawWrappedTextToWidth(identity,x1+pad,y,inner-(x1+pad),lh,2)+6
    gr.setColor(220,235,240,255)
    self:DrawTextLine(string.format("Hull %.1f%% | Shields %.1f%%",hp,sp),x1+pad,y,inner-(x1+pad))
    y=y+lh; self:DrawTextLine(string.format("Speed %.0f / %.0f m/s",speed,maxSpeed),x1+pad,y,inner-(x1+pad))
    local controller=self:GetShipController(ship); local r,g,b=self:GetControllerColor(ship,controller)
    y=y+lh+6
    gr.setColor(r,g,b,255)
    y=y+self:DrawWrappedTextToWidth(self:GetShipControlDescription(ship),x1+pad,y,inner-(x1+pad),lh,2)
    y=y+4
    local role=self:GetShipRole(ship)
    gr.setColor(155,185,198,255); self:DrawTextLine("Role: "..string.upper(role),x1+pad,y,inner-(x1+pad))
    local friendly=self:IsFriendly(ship)
    if not friendly then return end
    local sig=ship:getSignature()
    local servicing=self.FleetServices and self.FleetServices[sig]~=nil
    local order=(not servicing and (controller=="auto" or controller=="policy") and self.AIOrderState and self.AIOrderState[sig]) or nil
    local obs=order and self.AIObservations and self.AIObservations[sig]
    local thought=nil
    if not thought and order then
        local target=self:FindShipBySignature(order.targetSignature)
        local why=string.upper(order.reason or order.status or "ACTIVE"):gsub('_',' ')
        local phase=order.operationPhase and (" ["..order.operationPhase.."]") or ""
        local objective=shipValid(target) and (" -> "..target.Name.." "..math.floor(ship.Position:getDistance(target.Position)).."m") or ""
        thought=string.upper(order.mission or "ORDER")..phase.." / "..why..objective
    end
    if obs and obs.stalled then thought="STALLED / NO CLOSING" elseif obs and obs.mode=="RETREATING" then thought="PRESERVING FORCE / RETREAT" end
    if thought then
        y=y+lh+4
        gr.setColor(255,220,110,255)
        y=y+self:DrawWrappedTextToWidth("TACTIC: "..thought,x1+pad,y,inner-(x1+pad),lh,2)-lh
    end
    local loadout,turrets,lostTurrets=self:GetShipLoadout(ship)
    if #loadout>0 or turrets>0 then
        y=y+lh+4
        gr.setColor(105,235,255,255); self:DrawTextLine("LOADOUT",x1+pad,y,inner-(x1+pad))
        y=y+lh
        -- 0.46 leaves room for "SECONDARY 160/160"; at 0.52 it was cut to "160/1...".
        local nameW=math.floor((x2-x1)*0.46)
        local seen={}
        for _,entry in ipairs(loadout) do
            if y>y2-m.pad(34) then break end
            local ammo=""
            if entry.ammoMax>0 then ammo=" "..math.floor(entry.ammoLeft).."/"..math.floor(entry.ammoMax) end
            local key=entry.name..ammo..tostring(entry.beam)
            if not seen[key] then
                seen[key]=true
                local kind=entry.beam and "BEAM" or (entry.label=="TURRET" and "TURRET" or entry.label)
                gr.setColor(200,225,235,255)
                self:DrawTextLine(self:GetWeaponDisplayName(entry.name),x1+pad,y,nameW)
                gr.setColor(145,180,195,255)
                self:DrawTextLine(kind..ammo,x1+pad+nameW+m.pad(4),y,inner-(x1+pad+nameW))
                y=y+lh
            end
        end
        local footer="Turrets: "..turrets..(lostTurrets>0 and ("  //  DESTROYED: "..lostTurrets) or "")
        gr.setColor(150,180,195,255); self:DrawTextLine(footer,x1+pad,y2-m.pad(20),inner-(x1+pad))
    end
end
