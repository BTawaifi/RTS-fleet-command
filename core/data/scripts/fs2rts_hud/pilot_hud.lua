-- HUD pilot mode: weapon hints, hull readout, pilot panel.
local _shared = require "fs2rts_hud.common"
local RTS, objectValid, shipAlive, shipValid, clamp = _shared.RTS, _shared.objectValid, _shared.shipAlive, _shared.shipValid, _shared.clamp

function RTS:GetPilotWeaponHint(ship)
    local now=self:UINow(); local target=ship.Target
    local key=objectValid(target) and target:getSignature() or false
    local cached=self.PilotWeaponHint
    if cached and cached.target==key and cached.group==self.PilotTurretGroupIndex and now-cached.at<.25 then return cached.text end
    local text=objectValid(target) and 'TARGET IS NOT HOSTILE // CHECK YOUR AIM' or 'NO TARGET // AIMING FORWARD'
    if shipAlive(target) and self:IsPlayerEnemy(target) then
        local range=self:GetShipWeaponRange(ship)
        local distance=math.max(0,ship.Position:getDistance(target.Position)-(target.Radius or 0))
        text=string.format("REACH %.1f KM | TARGET %.1f KM",range/1000,distance/1000)
        if distance>range then text="OUT OF RANGE | "..text
        else text="WITHIN REACH // AIM AND COOLDOWNS STILL APPLY" end
    end
    self.PilotWeaponHint={target=key,group=self.PilotTurretGroupIndex,at=now,text=text}
    return text
end

function RTS:GetPilotWeaponInventory()
    local cached=self.PilotWeaponInventory; local now=self:UINow()
    if cached and cached.group==self.PilotTurretGroupIndex and now-cached.at<.25 then return cached end
    local result={primary=0,secondary=0,beams=0,beamRange=0,ranges={primary=0,secondary=0},at=now,group=self.PilotTurretGroupIndex}
    local ship=self:GetPossessedShip(); local selected=shipValid(ship) and ship.Target
    local localTargets={}
    for i,group in ipairs(self.PilotTurretGroups or {}) do
        if self.PilotTurretGroupIndex==nil or self.PilotTurretGroupIndex==i then
            for _,entry in ipairs(group.turrets) do
                local gun=entry.subsystem
                if objectValid(gun) and not entry.wasLocked and gun.HitpointsLeft>0 then
                    local target=gun.Target
                    if shipAlive(target) and target~=selected and shipValid(ship) and self:AreEnemies(ship,target) then
                        localTargets[target:getSignature()]=true
                    end
                    for _,kind in ipairs({'primary','secondary'}) do
                        local banks=kind=='primary' and gun.PrimaryBanks or gun.SecondaryBanks
                        for b=1,#banks do
                            local bank=banks[b]
                            if objectValid(bank) and objectValid(bank.WeaponClass) and ((bank.AmmoMax or 0)<=0 or (bank.AmmoLeft or 0)>0)
                                and (not bank.WeaponClass:isBeam() or gun.BeamFree~=false) then
                                result[kind]=result[kind]+1
                                result.ranges[kind]=math.max(result.ranges[kind],self:GetWeaponFiringRange(bank.WeaponClass))
                                if bank.WeaponClass:isBeam() then
                                    result.beams=result.beams+1
                                    result.beamRange=math.max(result.beamRange,self:GetWeaponFiringRange(bank.WeaponClass))
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    result.localTargets=0; for _ in pairs(localTargets) do result.localTargets=result.localTargets+1 end
    self.PilotWeaponInventory=result
    return result
end

function RTS:GetPilotBeamStatus(ship,inventory)
    if inventory.beams==0 then return nil end
    if not shipAlive(ship.Target) or not self:AreEnemies(ship,ship.Target) then return 'BEAMS: SELECT A HOSTILE TARGET / LOCAL GUNNERS (no forward fire)' end
    local distance=math.max(0,ship.Position:getDistance(ship.Target.Position)-(ship.Target.Radius or 0))
    if distance>inventory.beamRange then return string.format('BEAMS: SELECTED OUT OF REACH | MAX %.1f / TARGET %.1f km | LOCAL GUNNERS',inventory.beamRange/1000,distance/1000) end
    return string.format('BEAMS: %d BANKS | MAX %.1f km | ARCS, TARGET RULES AND COOLDOWNS APPLY',inventory.beams,inventory.beamRange/1000)
end

function RTS:GetPilotBindingLabel(action)
    local binding=io.Keybinding and io.Keybinding[action]
    if binding==nil or binding.Name=='' then return 'SEE FSO CONTROLS' end
    local first,second=binding:getInputName(true),binding:getInputName(false)
    if first==nil or first=='' then return second and second~='' and second or 'UNBOUND' end
    return second and second~='' and second~=first and (first..' / '..second) or first
end

function RTS:GetPilotWeaponCycles()
    local result,byName={},{}; local now=mn.getMissionTime()
    local cached=self.PilotWeaponCycleReadout
    if cached and cached.groups==self.PilotTurretGroups and cached.group==self.PilotTurretGroupIndex and now-cached.at<.1 then return cached.rows end
    for i,group in ipairs(self.PilotTurretGroups or {}) do
        if not self.PilotTurretGroupIndex or self.PilotTurretGroupIndex==i then
            for _,entry in ipairs(group.turrets) do
                local turret=entry.subsystem
                if objectValid(turret) and not entry.wasLocked and turret.HitpointsLeft>0 then
                    for _,kind in ipairs({'primary','secondary'}) do
                        local banks=kind=='primary' and turret.PrimaryBanks or turret.SecondaryBanks
                        for b=1,#banks do
                            local bank=banks[b]; local weapon=bank.WeaponClass
                            if objectValid(weapon) and (weapon.FireWait or 0)>0 and ((bank.AmmoMax or 0)<=0 or (bank.AmmoLeft or 0)>0)
                                and (not weapon:isBeam() or turret.BeamFree~=false) then
                                local row=byName[weapon.Name]
                                if not row then row={name=self:GetWeaponDisplayName(weapon),total=0,ready=0,left=0,cycle=weapon.FireWait}; byName[weapon.Name]=row; result[#result+1]=row end
                                local slot=kind=='primary' and b or 3+b
                                local left=math.max(0,((entry.cooldowns or {})[slot] or 0)-now)
                                row.total=row.total+1; row.ready=row.ready+(left==0 and 1 or 0); row.left=math.max(row.left,left)
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(result,function(a,b) if a.cycle~=b.cycle then return a.cycle>b.cycle end; return a.name<b.name end)
    self.PilotWeaponCycleReadout={rows=result,at=now,groups=self.PilotTurretGroups,group=self.PilotTurretGroupIndex}
    return result
end

function RTS:DrawPilotHullHUD()
    if not hu or not hu.getHUDGaugeHandle then return end
    local pilot=self:GetPossessedShip()
    local target=nil; if shipValid(pilot) then target=pilot.Target end
    self.PilotHullHUDOverrides=self.PilotHullHUDOverrides or {}
    -- Native generated icons use a fixed top-down view with the tech-room
    -- closeup camera. Long capital hulls can become a clipped vertical strip.
    -- Reuse the fitted portrait at the gauge's own base coordinates. Only
    -- shieldless hulls are replaced; native shield quadrants stay untouched.
    for _,item in ipairs({{'Player shield',pilot},{'Target shield',target}}) do
        local name,ship=item[1],item[2]
        local want=not self.PendingPilotEject and shipAlive(ship) and self:IsCapitalTarget(ship)
            and (ship.Shields.CombinedMax or 0)<=0
        local texture=want and self:GetShipThumbTexture(ship.Class.Name)
        -- A gauge handle is nil when the gauge is missing; HudGauge has no isValid method.
        local gauge=hu.getHUDGaugeHandle(name)
        local active=gauge~=nil and texture and objectValid(texture) or false
        if gauge~=nil and active~=(self.PilotHullHUDOverrides[name]==true) then gauge:setRenderOverride(active) end
        self.PilotHullHUDOverrides[name]=active
        if active then
            local x,y=gauge:getPosition(); local w,h=gauge:getBaseResolution()
            local previous=gr.CurrentResizeMode
            gr.setScreenScale(w,h); gr.CurrentResizeMode=GR_RESIZE_FULL
            gr.setColor(235,245,250,255); gr.drawImage(texture,x+16,y,x+96,y+80)
            local fraction=clamp(ship.HitpointsLeft/math.max(1,ship.HitpointsMax),0,1)
            gr.setColor(45,65,70,255); gr.drawRectangle(x+8,y+82,x+104,y+87,true)
            gr.setColor(fraction<.25 and 255 or 105,fraction<.25 and 110 or 235,160,255)
            gr.drawRectangle(x+8,y+82,x+8+96*fraction,y+87,true)
            gr.drawString(string.format('HULL %.0f%%',fraction*100),x+8,y+89)
            gr.CurrentResizeMode=previous; gr.resetScreenScale()
        end
    end
end

function RTS:DrawPilotHUD(sw, sh)
    if self.PilotCommMenuActive then return end
    local ship=self:GetPossessedShip()
    if not shipValid(ship) and not self.PendingPilotEject then return end
    local pilot=self.Config.Pilot or {}; local m=self:GetUIMetrics(sw,sh); local lh=m.lineHeight
    local width=math.min(m.pad(470),sw-2*m.margin)
    local x1=sw-m.margin-width; local x2=sw-m.margin; local y1=m.pad(18); local pad=m.panelPadding
    local rows={}; local hints={}
    local function add(text,colour,section)
        for index,line in ipairs(self:WrapTextLinesToWidth(text,width-2*pad,3)) do
            rows[#rows+1]={text=line,colour=colour,section=section and index==1,gap=section and index==1 and m.sectionGap or 0}
        end
    end
    local cyan={105,235,255}; local white={210,225,235}; local yellow={255,220,110}
    local function hint(text)
        for _,line in ipairs(self:WrapTextLinesToWidth(text,width-2*pad,3)) do hints[#hints+1]={text=line,colour=yellow} end
    end
    hint((self.Config.HotkeyHintsKey or 'F10')..(self.ShowHotkeyHints==false and ' SHOW CONTROL HINTS' or ' HIDE CONTROL HINTS'))
    hint((self.Config.FleetCostToggleKey or 'F9')..' CREW ESTIMATES')
    hint('SHIFT+'..((self.Config.HomeworldControls or {}).Cinematic or 'C')..' HIDE HUD')
    if self.PendingPilotEject then
        add('CRAFT DESTROYED',{255,135,95})
        add(string.format('RETURNING TO RTS IN %.1fs',math.max(0,self.PendingPilotEjectRemaining or 0)),yellow)
    else
        add('PILOT: '..ship.Name,cyan)
        for _,line in ipairs(self:GetShipHistoryLines(ship)) do add(line,yellow) end
        local notice=self.FleetRecoveryNotice
        if notice and self:UINow()<=notice.untilTime then
            local record=(self.UnitHistory or {})[notice.id]
            if record and record.fate=='PRESENT' then
                add(record.name..' // CRITICAL HULL',{255,135,95})
                add(self.BlueEliminated and 'STATION LOST // SERVICE UNAVAILABLE' or 'ESC: COMMAND VIEW FOR FOCUS / SERVICE',yellow)
            end
        end
        local wingmates,label=self:GetPilotWingmates()
        add(label and ('COMMAND: '..label..' | '..#wingmates..' UNITS') or 'COMMAND: SOLO',white)
        if self:UINow()<(self.PilotCommWarningUntil or 0) then add(self.PilotCommWarningText or 'OTHER RECIPIENTS BLOCKED',yellow) end
        local groups=self.PilotTurretGroups
        if groups and #groups>0 then
            add('TURRET BATTERY',cyan,true)
            local index=self.PilotTurretGroupIndex
            add(index and ('GROUP '..index..'/'..#groups..': '..groups[index].label) or 'GROUP: ALL ELIGIBLE TURRETS',white)
            local inventory=self:GetPilotWeaponInventory()
            for _,kind in ipairs({'primary','secondary'}) do
                add(string.upper(kind)..': '..inventory[kind]..' BANKS | '..string.format('%.1f',inventory.ranges[kind]/1000)..' KM',white)
                if self.ShowHotkeyHints~=false and (kind=='primary' or inventory[kind]>0) then
                    hint(string.upper(kind)..' FIRE: '..self:GetPilotBindingLabel(kind=='primary' and 'FIRE_PRIMARY' or 'FIRE_SECONDARY')..(inventory[kind]>0 and '' or ' (EMPTY)'))
                end
            end
            if inventory.beams>0 then add('BEAMS: '..inventory.beams..' BANKS',white) end
            local cycles=self:GetPilotWeaponCycles()
            if #cycles>0 then
                add('WEAPON CYCLES (EST.)',cyan,true)
                for i=1,#cycles do
                    local row=cycles[i]
                    add(string.format('%s: %d/%d READY%s',row.name,row.ready,row.total,row.left>0 and string.format(' | %.1fs',row.left) or ''),white)
                end
            end
            add('TARGETING',cyan,true)
            add('AIM: '..self:GetPilotTargetSubsystemLabel(),cyan)
            if shipValid(ship.Target) then add('SELECTED: '..ship.Target.Name,white) end
            if (inventory.localTargets or 0)>0 then add('LOCAL GUNNERS: '..inventory.localTargets..' OTHER TARGETS',cyan) end
            if self.ShowHotkeyHints~=false then
                hint('Hold fire; guns track local hostiles. Flak favors fighters.')
                if inventory.beams>0 then hint('Beams need a target and barrel alignment.') end
                hint(pilot.TurretGroupPreviousKey..' / '..pilot.TurretGroupNextKey..' group | '..pilot.TurretGroupToggleKey..' all groups')
                hint(pilot.TurretSubsystemKey..' hull/subsystem | '..pilot.TurretSubsystemPreviousKey..' / '..pilot.TurretSubsystemNextKey..' cycle aim')
            end
            if objectValid(ship.Target) then
                -- Two rows, not one: the combined line wrapped "KM" onto a row of its own.
                local hintText=self:GetPilotWeaponHint(ship)
                local status,detail=string.match(hintText,"^(OUT OF RANGE) | (.+)$")
                if status then add(status,yellow); add(detail,yellow) else add(hintText,yellow) end
            end
            if self.PilotTurretFiring then add('TRIGGER: HELD',{255,190,95}) end
        elseif self.ShowHotkeyHints~=false then
            hint('Use your FSO flight and weapon keys.')
        end
        if self.ShowHotkeyHints~=false then hint(pilot.ToggleKey..' RETURN TO RTS | C: COMMAND YOUR WING') end
    end
    local bottom=sh-m.margin
    if hu and hu.getHUDGaugeHandle then
        for _,name in ipairs({'Countermeasures','Weapons','Auto target'}) do
            local gauge=hu.getHUDGaugeHandle(name)
            if gauge~=nil then
                local gx,gy=gauge:getPosition(); local gw,gh=gauge:getBaseResolution()
                if gx*sw/gw>=x1 and gy*sh/gh>sh*.5 then bottom=math.min(bottom,gy*sh/gh-m.gap) end
            end
        end
    end
    local maxRows=math.max(3,math.floor((bottom-y1-4*pad-m.gap)/lh))
    local count=math.min(#rows,maxRows-math.min(2,#hints))
    local sectionSpace=0; for i=1,count do sectionSpace=sectionSpace+(rows[i].gap or 0) end
    while count>1 and count*lh+sectionSpace>(maxRows-math.min(2,#hints))*lh do sectionSpace=sectionSpace-(rows[count].gap or 0); count=count-1 end
    local bodyHeight=count*lh+sectionSpace
    gr.setColor(4,10,18,235); gr.drawRectangle(x1,y1,x2,y1+2*pad+bodyHeight,true)
    local rowY=y1+pad
    for i=1,count do
        local row=rows[i]; gr.setColor(row.colour[1],row.colour[2],row.colour[3],255)
        rowY=rowY+(row.gap or 0)
        if row.section then
            gr.setColor(18,42,54,255)
            gr.drawRectangle(x1+pad*.5,rowY,x2-pad*.5,rowY+lh,true)
            gr.setColor(row.colour[1],row.colour[2],row.colour[3],255)
        end
        self:DrawTextLine(row.text,x1+pad,rowY,width-2*pad-(i<=2 and m.pad(28) or 0))
        rowY=rowY+lh
    end
    self:DrawFactionInsignia("BLUE",x2-pad-m.pad(24),y1+pad,x2-pad,y1+pad+m.pad(24))
    local helpY=y1+2*pad+bodyHeight+m.gap
    local helpCount=math.max(0,math.min(#hints,math.floor((bottom-helpY-2*pad)/lh)))
    if #hints>helpCount and helpCount>1 then hints[helpCount]=hints[#hints] end
    gr.setColor(10,22,32,235); gr.drawRectangle(x1,helpY,x2,helpY+2*pad+helpCount*lh,true)
    gr.setColor(255,220,110,255)
    for i=1,helpCount do self:DrawTextLine(hints[i].text,x1+pad,helpY+pad+(i-1)*lh,width-2*pad) end
end

function RTS:DrawPilotObjectiveMarker(sw,sh)
    if self.PendingPilotEject then return end
    local point,label=self:GetPilotNavigationPoint(self:GetPilotTacticalOrder())
    if not point then return end
    local x,y=point:getScreenCoords()
    local m=self:GetUIMetrics(sw,sh); local radius=m.pad(12)
    if type(x)~='number' or type(y)~='number' or x<radius or x>sw-radius or y<radius or y>sh-radius then return end
    gr.setColor(255,220,110,255)
    gr.drawLine(x-radius,y,x,y-radius); gr.drawLine(x,y-radius,x+radius,y)
    gr.drawLine(x+radius,y,x,y+radius); gr.drawLine(x,y+radius,x-radius,y)
    self:DrawCenteredTextClipped(label,x-m.pad(80),x+m.pad(80),y+radius+m.pad(4))
end

function RTS:DrawHintsNotice(sw,sh)
    if self.SetupActive or self.CinematicActive or self.ScenarioStartTime==nil then return end
    local m=self:GetUIMetrics(sw,sh)
    gr.setColor(190,215,225,255)
    self:DrawCenteredTextClipped((self.Config.HotkeyHintsKey or 'F10'):gsub('-','+')..' SHOW/HIDE CONTROL HINTS',m.margin,sw-m.margin,sh-m.lineHeight-m.pad(4))
end
