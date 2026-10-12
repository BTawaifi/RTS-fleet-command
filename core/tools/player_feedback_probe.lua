-- Isolated native fixtures for player-reported combat/input/HUD behavior.
local R=require 'fs2rts'
local uiSeconds=R.ReviewProbeUISeconds or 15
local out=cf.openFile('player-feedback-probe.log','w','data')
assert(out and out:isValid())
local function log(s) out:write(s..'\n'); out:flush() end
local finished,stage,startTime=false,0,0
local pairsToCheck={}
local capital,victim,control,controlVictim
local flakCapital
local pilotBeamShots,pilotBeamHits,pilotProjectileShots=0,0,0
local firstMainBeamAt
local noContactPositions={}
local flakShots,flakBefore,flakVictim,flakOrigin,flakTangent,flakAt,flakGroup=0,0,nil,nil,nil,0,nil
engine.addHook('On Weapon Delete',function()
    local weapon=hv.Weapon
    if flakVictim and weapon and weapon:isValid() and R.Config.Pilot.FlakWeapons[weapon.Class.Name]
        and weapon.Parent:isValid() and flakCapital and weapon.Parent:getSignature()==flakCapital:getSignature() then
        log('FLAK_BURST distance='..weapon.Position:getDistance(flakVictim.Position)..' position='..tostring(weapon.Position)..' target='..tostring(flakVictim.Position))
    end
end)
engine.addHook('On Beam Fire',function()
    if capital and hv.User and hv.User:isValid() and hv.User:getSignature()==capital:getSignature() then
        pilotBeamShots=pilotBeamShots+1
        if hv.Beam.Class.Name~='AAAf' and not firstMainBeamAt then firstMainBeamAt=mn.getMissionTime() end
        log('PILOT_BEAM_FIRED '..hv.Beam.Class.Name)
    end
end)
engine.addHook('On Beam Collision',function()
    if capital and hv.Beam and hv.Beam:isValid() and hv.Beam.ParentShip:isValid()
        and hv.Beam.ParentShip:getSignature()==capital:getSignature() then pilotBeamHits=pilotBeamHits+1 end
end)
engine.addHook('On Turret Fired',function()
    if capital and hv.Ship and hv.Ship:isValid() and (hv.Ship:getSignature()==capital:getSignature()
        or (flakCapital and hv.Ship:getSignature()==flakCapital:getSignature()))
        and hv.Weapon and hv.Weapon:isValid() then
        pilotProjectileShots=pilotProjectileShots+1
        if R.Config.Pilot.FlakWeapons[hv.Weapon.Class.Name] then flakShots=flakShots+1 end
    end
end)
local movers={}
local uiAt,moveReports,facingStableAt=0,0,nil
local hintsChecked=false
local function check(condition,message) assert(condition,message); log('PASS '..message) end
local function quit()
    finished=true; R:SetTimeScale(1)
    ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
end
engine.addHook('On Frame',function()
    if finished then ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME']) end
end)
R.Config.Cinematic.Enabled=false
R.Config.AI.ExperimentalDamageTelemetry=false
for _,name in ipairs({'UpdateAIProduction','UpdateEnemyWaves','UpdateStations',
    'UpdateAIStrategicObjectives','UpdateFleetServices','UpdateDefaultPolicy'}) do R[name]=function() end end
-- Keep the real sentry director in this weapon-isolation fixture. Disabling
-- the whole station update otherwise disables the requested rear acquisition.
R.UpdateStations=function(self,now) self:UpdateSentryAim(now); self:UpdateMjolnirRange(now) end
local function target(name,class,pos,team)
    local s=mn.createShip(name,tb.ShipClasses[class],ba.createOrientationFromVectors(ba.createVector(0,0,1)),pos,team,true)
    assert(s and s:isValid(),name..' creation failed')
    R:InvalidateShipList()
    s:setFlag(true,'immobile','primaries-locked','secondaries-locked')
    for j=1,#s do if s[j]:isTurret() then s[j].TurretLocked=true end end
    s.HitpointsMax=1000000; s.HitpointsLeft=1000000
    s.Shields.CombinedLeft=0
    return s
end
local originalFrame=R.OnFrame
local originalPilotUpdate=R.UpdatePilotMode
local motionOrigin,motionForward
R.UpdatePilotMode=function(self,dt)
    if stage==2.1 then
        self:GetObserver().Target=nil
        assert(not self:GetObserver().Target:isValid(),'native no-target fixture cannot clear the proxy')
    end
    if stage==3.5 or stage==3.6 then
        local controls=self.ControlInfo or ba.getControlInfo()
        controls.Heading=stage==3.5 and 1 or 0
        controls.Forward=stage==3.5 and 1 or 0
        controls.ForwardCruise=0
    end
    return originalPilotUpdate(self,dt)
end
local originalControlDown=R.IsPilotControlDown
R.IsPilotControlDown=function(self,buttons,name)
    if name=='FIRE_PRIMARY' and stage==2.1 then return true end
    if name=='FIRE_PRIMARY' and stage==3.2 then return true end
    if (name=='FIRE_PRIMARY' or name=='FIRE_SECONDARY') and stage==3 then return true end
    return originalControlDown(self,buttons,name)
end
local originalHUD=R.DrawHUD
local titleFonts={}
local originalCentered=R.DrawCenteredText
R.DrawCenteredText=function(self,text,...)
    if self.PostBattleActive and (text=='VICTORY' or text=='DEFEAT' or text=='DRAW') then
        titleFonts[text]=tostring(gr.CurrentFont)
    end
    return originalCentered(self,text,...)
end
R.DrawHUD=function(self)
    if finished then return end
    local ok,err=pcall(originalHUD,self)
    if not ok then log('FAIL HUD '..tostring(err)); quit() end
end
local function probe(self)
    if stage==0 and self.SetupActive then
        self.SetupOpponents={RED=true,GOLD=true}; self.SetupAutoMode=false; self.SetupSentries=false
        self:StartScenario(); self.ActiveIncomePerSecond=0
        -- Isolated batteries are deliberately tens of km apart. Declare that
        -- diagnostic arena rather than making their contacts illegal targets.
        self.ScenarioMapHalfExtent=250000
        for _,name in ipairs({'SJ Sathanas','GTVA Colossus','SD Lucifer','GTD Orion'}) do
            local estimate=self:GetPurchaseEstimate(name,5,1)
            log('PRICE '..name..' CP='..estimate.cost..' seconds='..estimate.time..' radius='..estimate.radius)
        end
        local price=self:GetPurchaseEstimate('SJ Sathanas',5,1)
        check(price.cost==60000 and price.time==1500,'Sathanas costs 60000 CP and 1500 base build seconds')
        local beam=tb.WeaponClasses['BGreen']
        check(self:GetWeaponFiringRange(beam)==4000,'AI/HUD use the actual native BGreen firing reach')
        if not self.ReviewProbeHeadless then
            for i=1,#gr.Fonts do log('FONT '..i..' '..tostring(gr.Fonts[i])..' height='..gr.Fonts[i].Height) end
        end
        for i,kind in ipairs({'BLUE','GOLD','RED'}) do
            local pos=ba.createVector(80000+i*20000,0,-60000)
            local team=mn.Teams[kind=='RED' and self.Config.FriendlyTeam or self.Config.HostileTeam]
            local victim=target('Near fighter '..kind,'GTF Myrmidon',pos+ba.createVector(0,0,700),team)
            local sentry=self:CreateSentry(kind,self.Config.Station.Sentries.Classes[kind][1],pos,true)
            assert(sentry and sentry:isValid())
            sentry.Orientation=ba.createOrientationFromVectors(ba.createVector(0,0,1))
            pairsToCheck[#pairsToCheck+1]={kind=kind,target=victim,sentry=sentry}
        end
        capital=mn.createShip('Pilot combat fixture',tb.ShipClasses['GTD Orion'],
            ba.createOrientationFromVectors(ba.createVector(0,0,1)),ba.createVector(-80000,0,-50000),mn.Teams[self.Config.FriendlyTeam],true)
        victim=target('Pilot enemy fixture','GTD Hecate',capital.Position+ba.createVector(-3000,0,0),mn.Teams[self.Config.HostileTeam])
        self:EnableFullArsenal(capital)
        control=mn.createShip('Control combat fixture',tb.ShipClasses['GTD Orion'],
            ba.createOrientationFromVectors(ba.createVector(0,0,1)),ba.createVector(-80000,0,-20000),mn.Teams[self.Config.FriendlyTeam],true)
        controlVictim=target('Control enemy fixture','GTD Hecate',control.Position+ba.createVector(-3000,0,0),mn.Teams[self.Config.HostileTeam])
        self:EnableFullArsenal(control)
        control:giveOrder(ORDER_STAY_STILL,nil,nil,2)
        stage=1
    elseif stage==1 then
        self.AIOrderState[capital:getSignature()]={label='ASSAULT: '..victim.Name,mission='PRIMARY',
            reason='PRIMARY_ASSAULT',targetSignature=victim:getSignature(),group='Pilot objective fixture'}
        assert(self:StartPilotMode(capital))
        check(self.PilotAIObjective and self.AIOrderState[capital:getSignature()]==nil,
            'pilot captures its AI assignment without retaining executable AI control')
        check(table.concat(self:GetPilotObjectiveLines(),' '):find('LAST AI ORDER',1,true),
            'pilot objectives label the captured assignment accurately')
        check(self.ShowHotkeyHints==false,'control hints default off')
        self:OnKeyPressed('F10','F10'); self:OnKeyReleased('F10','F10')
        local primaryBinding=self:GetPilotBindingLabel('FIRE_PRIMARY')
        local secondaryBinding=self:GetPilotBindingLabel('FIRE_SECONDARY')
        log('PILOT BINDINGS primary='..primaryBinding..' secondary='..secondaryBinding)
        check(primaryBinding~='SEE FSO CONTROLS' and secondaryBinding~='SEE FSO CONTROLS','native pilot HUD resolves real fire bindings')
        self:GetObserver().Target=nil; self:UpdatePilotMode(ba.getRealFrametime())
        startTime=mn.getMissionTime(); self:SetTimeScale(8); stage=2
        if not self.ReviewProbeHeadless then
            stage=1.25
        end
    elseif stage==1.25 and mn.getMissionTime()-startTime>3 then
        local playerGauge=hu.getHUDGaugeHandle('Player shield'); local targetGauge=hu.getHUDGaugeHandle('Target shield')
        check(playerGauge and playerGauge:isValid() and targetGauge and targetGauge:isValid(),'native shield gauge names resolve')
        check(self.PilotHullHUDOverrides and self.PilotHullHUDOverrides['Player shield'],
            'native shieldless capital uses the real-hull portrait')
        check(mn.Events['RTS Pilot Task'].DirectiveText:find('LAST AI ORDER',1,true),'native mission event holds tactical task text')
        check(hu.getDirectiveLines()>0,'stock FreeSpace directives gauge renders tactical assignment')
        self:SetPaused(true); uiAt=self:UINow(); stage=1.5; log('UI READY capital possession')
    elseif stage==1.5 then
        if not hintsChecked and self:UINow()-uiAt>uiSeconds*.5 then
            self:OnKeyPressed('F10','F10'); self:OnKeyPressed('F10','F10')
            check(self.ShowHotkeyHints==false and self:ShouldOverrideKey('F10','F10'),
                'paused pilot hint toggle suppresses repeats and native action')
            hintsChecked=true; log('UI READY pilot hints hidden')
        end
        if self:UINow()-uiAt>uiSeconds then
            self:OnKeyReleased('F10','F10'); self:OnKeyPressed('F10','F10'); self:OnKeyReleased('F10','F10')
            check(self.ShowHotkeyHints==true,'pilot hints can be restored')
            self:SetPaused(false); startTime=mn.getMissionTime(); stage=2
        end
    elseif stage==2 and mn.getMissionTime()-startTime>35 then
        for _,p in ipairs(pairsToCheck) do
            p.frontDamage=1000000-p.target.HitpointsLeft
            log('NEAR_FIGHTER '..p.kind..' damage='..p.frontDamage)
            check(p.frontDamage>0,p.kind..' native sentry hits a nearby fighter without forced targeting')
            for i=1,#p.sentry do
                local t=p.sentry[i]
                if t:isTurret() then log('GUN '..p.kind..' '..t.Name..' HP='..t.HitpointsLeft..' FOV='..tostring(t:isTargetInFOV(p.target))..' local='..tostring(t.Position)..' target='..tostring(t.Target)..' weapon='..t.PrimaryBanks[1].WeaponClass.Name) end
            end
            p.target.Position=p.sentry.Position+ba.createVector(0,0,-700)
        end
        log('PILOT_AUTO_DAMAGE '..(1000000-victim.HitpointsLeft))
        check(victim.HitpointsLeft==1000000,'possessed capital does not fire without pilot input')
        log('CONTROL_DAMAGE '..(1000000-controlVictim.HitpointsLeft))
        local ready=0
        for _,g in ipairs(self.PilotTurretGroups or {}) do
            for _,e in ipairs(g.turrets) do
                if e.subsystem:isTargetInFOV(victim) and not e.wasLocked then ready=ready+1 end
            end
        end
        log('PILOT_WEAPONS groups='..#(self.PilotTurretGroups or {})..' in_arc='..ready)
        for _,g in ipairs(self.PilotTurretGroups) do for _,e in ipairs(g.turrets) do
            check(e.subsystem.TurretLocked,'possession suppresses automatic native turret fire')
        end end
        for _,g in ipairs(self.PilotTurretGroups or {}) do
            for _,e in ipairs(g.turrets) do
                local t=e.subsystem
                if t:isTargetInFOV(victim) then log('CAPGUN '..g.label..' lock='..tostring(t.TurretLocked)..' HP='..t.HitpointsLeft..' free='..tostring(t.BeamFree)..' target='..tostring(t.Target)..' reach='..t.PrimaryBanks[1].WeaponClass.Range) end
            end
        end
        -- Clearing the selected target alone is not a no-contact fixture:
        -- gunners may legitimately acquire nearby hostiles. Remove those
        -- contacts physically for this interval, then restore the same board.
        for _,contact in ipairs(self:GetShipList()) do
            if contact:isValid() and self:AreEnemies(capital,contact) then
                noContactPositions[#noContactPositions+1]={ship=contact,position=contact.Position}
                contact.Position=contact.Position+ba.createVector(0,100000,0)
            end
        end
        self.PilotBatteryCandidates=nil
        startTime=mn.getMissionTime(); stage=2.1
    elseif stage==2.1 and mn.getMissionTime()-startTime>3 then
        check(pilotBeamShots==0,'beams require a target while projectiles can fire forward')
        for _,row in ipairs(noContactPositions) do if row.ship:isValid() then row.ship.Position=row.position end end
        noContactPositions={}; self.PilotBatteryCandidates=nil
        stage=3
        self:GetObserver().Target=victim; self:UpdatePilotMode(ba.getRealFrametime())
        startTime=mn.getMissionTime(); stage=3
    elseif stage==3 and mn.getMissionTime()-startTime>35 then
        for _,p in ipairs(pairsToCheck) do
            local damage=1000000-p.target.HitpointsLeft
            log('REAR_FIGHTER '..p.kind..' total_damage='..damage)
            check(damage>p.frontDamage+25,p.kind..' native sentry reacquires a fighter behind it')
        end
        log('PILOT_TARGET_DAMAGE '..(1000000-victim.HitpointsLeft))
        check(victim.HitpointsLeft<1000000,'possessed capital tracks and damages a selected enemy in reach')
        log('PILOT_FIRING beams='..pilotBeamShots..' beamHits='..pilotBeamHits..' projectiles='..pilotProjectileShots)
        check(pilotBeamShots>0 and pilotBeamHits>0,'manual capital beam batteries fire and collide with a selected enemy')
        log('PILOT_MAIN_BEAM_DELAY '..tostring(firstMainBeamAt and firstMainBeamAt-startTime))
        check(firstMainBeamAt and firstMainBeamAt-startTime<10,'holding fire without a target does not consume the main beam cooldown')
        check(pilotProjectileShots>0,'manual capital projectile batteries also fire')
        check(self:GetShipWeaponRanges(capital).beam==4000,'pilot reach includes manually controlled beam turrets')
        check(controlVictim.HitpointsLeft<1000000,'unpossessed capital is the firing control')
        log('PILOT_TARGETS ship='..tostring(capital.Target)..' proxy='..tostring(self:GetObserver().Target))
        check(self:CyclePilotTargetSubsystem(1),'native subsystem targeting control selects a real subsystem')
        check(self.PilotTurretGroups[1].turrets[1].forcedOwner~=nil,'subsystem aim is installed through the upstream forced-target SEXP')
        self:ExitPilotMode(nil,false)
        flakCapital=mn.createShip('Pilot flak fixture',tb.ShipClasses['GTD Hecate'],capital.Orientation,
            capital.Position+ba.createVector(0,0,-10000),mn.Teams[self.Config.FriendlyTeam],true)
        assert(flakCapital:isValid()); self:EnableFullArsenal(flakCapital); self:InvalidateShipList()
        assert(self:StartPilotMode(flakCapital)); self:GetObserver().Target=victim
        for index,group in ipairs(self.PilotTurretGroups) do
            for _,entry in ipairs(group.turrets) do
                if entry.flakWeapon and not entry.wasLocked and not flakVictim then
                    for _,direction in ipairs({ba.createVector(1,0,0),ba.createVector(-1,0,0),ba.createVector(0,1,0),ba.createVector(0,-1,0),ba.createVector(0,0,1),ba.createVector(0,0,-1)}) do
                        local point=entry.subsystem.WorldPosition+direction*800
                        if entry.subsystem:isPositionInFOV(point) then
                            flakVictim=target('Local flak fighter','GTF Myrmidon',point,mn.Teams[self.Config.HostileTeam])
                            flakOrigin=point; flakTangent=math.abs(direction.y)>.5 and ba.createVector(1,0,0) or ba.createVector(0,1,0)
                            flakVictim:setFlag(false,'immobile')
                            flakVictim.Orientation=flakTangent:getOrientation()
                            flakVictim:giveOrder(ORDER_PLAY_DEAD,nil,nil,2)
                            flakVictim:doManeuver(1,0,0,0,true,0,0,.5,true,0)
                            flakGroup=index; break
                        end
                    end
                end
            end
        end
        check(flakVictim~=nil,'native flak fixture has a target within a real turret arc')
        self:SetTimeScale(1)
        self.PilotTurretGroupIndex=flakGroup; self:ApplyPilotTurretGroup(victim)
        flakBefore=flakShots; flakAt=mn.getMissionTime(); startTime=flakAt; stage=3.1
    elseif stage==3.1 and mn.getMissionTime()-startTime>3 then
        check(flakShots==flakBefore,'native local flak tracks without firing until the pilot trigger is held')
        flakVictim.HitpointsLeft=1000000
        startTime=mn.getMissionTime(); stage=3.2
    elseif stage==3.2 and mn.getMissionTime()-startTime>8 then
        log('LOCAL_FLAK shots='..(flakShots-flakBefore)..' damage='..(1000000-flakVictim.HitpointsLeft))
        check(flakShots>flakBefore and flakVictim.HitpointsLeft<1000000,'native manual flak leads and hits a moving nearby fighter while a distant capital is selected')
        check(self:GetObserver().Target==victim,'native local flak does not steal the player weapon target')
        self:ExitPilotMode(nil,false); assert(self:StartPilotMode(capital)); self:GetObserver().Target=victim
        self:SetTimeScale(8)
        motionOrigin=capital.Position:copy(); motionForward=capital.Orientation:getFvec()
        startTime=mn.getMissionTime(); stage=3.5
    elseif stage==3.5 and mn.getMissionTime()-startTime>8 then
        log('PILOT_MOTION distance='..capital.Position:getDistance(motionOrigin)..' forward='..tostring(capital.Orientation:getFvec()))
        check(capital.Position:getDistance(motionOrigin)>5,'capital forward input moves the real hull')
        local forward=capital.Orientation:getFvec()
        check(forward.x*motionForward.x+forward.y*motionForward.y+forward.z*motionForward.z<.995,'capital heading input rotates the real hull')
        startTime=mn.getMissionTime(); stage=3.6
    elseif stage==3.6 and mn.getMissionTime()-startTime>5 then
        local forward=capital.Orientation:getFvec()
        check(forward.x*motionForward.x+forward.y*motionForward.y+forward.z*motionForward.z<.995,'native AI does not turn the capital back after pilot rotation')
        self:ExitPilotMode('Probe finished',false)
        check(mn.Events['RTS Pilot Task'].DirectiveText=='' and self.PilotAIObjective==nil,'pilot exit clears native tactical directives and captured objectives')
        self.Selected={capital:getSignature()}
        self:IssueAttack(self:GetEnemyCommand())
        local pursuit=self.AIPursuit[capital:getSignature()]
        check(pursuit and capital.Orders[1]:getType()==ORDER_WAYPOINTS_ONCE,'manual capital attack approaches a station through a native waypoint')
        pursuit.anchoredAt=mn.getMissionTime()-100
        self:RefreshAIPursuit(mn.getMissionTime())
        check(self.AIPursuit[capital:getSignature()]==pursuit and pursuit.anchoredAt==mn.getMissionTime(),'manual capital pursuit refreshes with Auto Mode disabled')
        self:SetUserOrder(capital,{kind='hold'}); self:HoldShip(capital,.95)
        check(self.AIPursuit[capital:getSignature()]==nil,'retasking retires manual pursuit')
        for i=1,2 do
            local ship=mn.createShip('Move fixture '..i,tb.ShipClasses['GTF Myrmidon'],
                ba.createOrientationFromVectors(ba.createVector(0,0,-1)),ba.createVector(-15000+i*200,0,7500),mn.Teams[self.Config.FriendlyTeam],true)
            assert(ship:isValid()); ship:setFlag(true,'invulnerable','primaries-locked','secondaries-locked')
            movers[#movers+1]=ship
        end
        self:SetTimeScale(8); stage=4
    elseif stage==4 then
        self.Selected={movers[1]:getSignature(),movers[2]:getSignature()}
        self:SetSelectedFormation('LINE_ABREAST')
        self:IssueMove(ba.createVector(-15000,0,4000),ba.createVector(-14000,0,4000))
        self:FocusOnSelection(); startTime=mn.getMissionTime(); stage=5
    elseif stage==5 then
        if mn.getMissionTime()-startTime>moveReports*20 then
            moveReports=moveReports+1
            for _,ship in ipairs(movers) do
                local o=self.UserOrders[ship:getSignature()]
                log('TRANSIT '..ship.Name..' pos='..tostring(ship.Position)..' forward='..tostring(ship.Orientation:getFvec())..' order='..tostring(o and o.kind)..' face='..tostring(o and o.facing))
            end
        end
        local ready=true
        for _,ship in ipairs(movers) do
            local o=self.UserOrders[ship:getSignature()]
            ready=ready and o and o.kind=='hold' and ship.Orientation:getFvec().x>.999
        end
        if ready then facingStableAt=facingStableAt or mn.getMissionTime() else facingStableAt=nil end
        if ready and mn.getMissionTime()-facingStableAt>=3 then
            check(math.abs(movers[1].Position.x-movers[2].Position.x)<120,'native line is perpendicular to the drag heading')
            for _,ship in ipairs(movers) do log('MOVE '..ship.Name..' '..tostring(ship.Position)..' facing='..tostring(ship.Orientation:getFvec())) end
            check(true,'native waypoint arrival preserves parallel facing for both ships')
            local enemy=target('Attack formation fixture','GTF Myrmidon',ba.createVector(-15000,0,11000),mn.Teams[self.Config.HostileTeam])
            self:IssueAttack(enemy)
            log('ATTACK enemy='..tostring(self:IsPlayerEnemy(enemy))..' selected='..#self:GetSelectedFriendlyShips()..' found='..tostring(self:FindShipBySignature(enemy:getSignature())))
            for _,ship in ipairs(movers) do
                local order=self.UserOrders[ship:getSignature()]
                log('APPROACH '..ship.Name..' kind='..tostring(order and order.kind)..' approaching='..tostring(order and order.approaching)..' formation='..tostring(order and order.formation and order.formation.id)..' reach='..self:GetShipWeaponRange(ship))
                check(order and order.approaching and order.formation.id=='LINE_ABREAST','native attack begins with the selected loose formation')
                check(ship.Orders[1]:getType()==ORDER_WAYPOINTS_ONCE,'native attack approach has a real waypoint goal')
                self:SetUserOrder(ship,{kind='hold'}); self:HoldShip(ship,.95)
            end
            self:SetPaused(true); self:OnKeyPressed('F','F')
            check(self.Paused and self.CameraFocus:getDistance((movers[1].Position+movers[2].Position)/2)<1,'focus works while the native simulation remains paused')
            if self.ReviewProbeHeadless then log('COMPLETE native player feedback mechanics (rendered HUD skipped)'); quit(); return end
            self.Selected={movers[1]:getSignature()}; self.CameraFocus=ba.createVector(-15000,0,5000); self.CameraDistance=6500
            self:UpdateCameraTransform(); self.AnnouncementUntil=0
            self.UserOrders[movers[1]:getSignature()]={kind='hold'}
            uiAt=self:UINow(); log('UI READY selection'); stage=6
        elseif mn.getMissionTime()-startTime>90 then assert(false,'native move/arrival/facing failed within 90 simulation seconds') end
    elseif stage==6 and self:UINow()-uiAt>uiSeconds then
        self:RefreshSelectionListRects(gr.getScreenWidth(),gr.getScreenHeight())
        check(self.SelectionRows[1].rect.y1>self.LegendBottomY,'native selection rows clear the complete legend')
        self.AIOrderState[victim:getSignature()]={label='PRIVATE ORDER',reason='PRIVATE RATIONALE',targetSignature=capital:getSignature()}
        check(self:GetHoverOrderTarget(victim)==nil and self:GetHoverCourseProjection(victim,0,0)==nil,'native hostile inspection hides targets and courses')
        self.GameStatus='VICTORY'; self.BattleSummary={}; self.PostBattleActive=true; self.PostBattleResult='ALL OPPOSING STATIONS DESTROYED'
        uiAt=self:UINow(); log('UI READY victory'); stage=7
    elseif stage==7 and self:UINow()-uiAt>uiSeconds then
        check(titleFonts.VICTORY=='font02.vf' and tostring(gr.CurrentFont)=='font01.vf','native outcome title uses the existing large font and restores the HUD font')
        self.GameStatus='DEFEAT'; self.PostBattleResult='BLUE STATION DESTROYED'
        uiAt=self:UINow(); log('UI READY defeat'); stage=8
    elseif stage==8 and self:UINow()-uiAt>uiSeconds then
        check(titleFonts.DEFEAT=='font02.vf','native defeat title uses the existing large font without a texture')
        log('COMPLETE native player feedback regressions'); quit()
    end
end
R.OnFrame=function(self)
    if finished then return end
    local ok,err=pcall(function()
        originalFrame(self)
        if self.UpdateSentryAim and stage>0 then self:UpdateSentryAim(mn.getMissionTime()) end
        probe(self)
    end)
    if not ok then log('FAIL '..tostring(err)); quit() end
end
return true
