-- Isolated native fixtures for player-reported combat/input/HUD behavior.
local R=require 'fs2rts'
local uiSeconds=R.ReviewProbeUISeconds or 15
local out=cf.openFile('player-feedback-probe.log','w','data')
assert(out and out:isValid())
local function log(s) out:write(s..'\n'); out:flush() end
local finished,stage,startTime=false,0,0
local pairsToCheck={}
local capital,victim,control,controlVictim
local missileBomber,missileTarget
local pilotMissiles,missileTimes={},{}
local missileHomingSeen,missileExamined={},{}
local pilotSwarm,swarmHomingSeen={},{}
local swarmTriggerSent=false
engine.addHook('On Weapon Created',function()
    if (stage==3.7 or stage==3.72 or stage==3.75) and hv.Weapon and hv.Weapon:isValid() then
        local parent=hv.Weapon.Parent
        if parent and parent:isValid() and (parent==R:GetObserver() or parent==missileBomber) then
            if stage==3.7 then
                pilotMissiles[#pilotMissiles+1]=hv.Weapon
                missileTimes[#missileTimes+1]=mn.getMissionTime()
            else pilotSwarm[#pilotSwarm+1]=hv.Weapon end
        end
    end
end)
local flakCapital
local screenshots={}; local skyView=1
local originalBattleCam=R.UpdateBattleCam
local skyDirections={ba.createVector(0,0,1),ba.createVector(1,0,0),ba.createVector(0,0,-1),
    ba.createVector(-1,0,0),ba.createVector(0,1,0),ba.createVector(0,-1,0)}
R.UpdateBattleCam=function(self)
    if stage~=3.85 then return originalBattleCam(self) end
    self.Camera.Position=ba.createVector(0,20000,0)
    self.Camera.Orientation=skyDirections[skyView]:getOrientation()
    gr.setCamera(self.Camera)
end
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
    if stage==3.65 or stage==3.7 or stage==3.71 or stage==3.72 or stage==3.75 then
        self.ControlInfo.clearLuaButtonInfo()
        local held=stage==3.7 or stage==3.72 or (stage==3.75 and mn.getMissionTime()-startTime<.12)
        self.ControlInfo.PrimaryCount=0; self.ControlInfo.SecondaryCount=held and 1 or 0
    end
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
    local result=originalPilotUpdate(self,dt)
    -- Lua button bits do not inject continuous controls. Drive the native
    -- player fire API here; production Lua must not issue a second launch.
    if stage==3.7 or stage==3.72 then self:GetObserver():fireSecondary()
    elseif stage==3.75 and not swarmTriggerSent then
        self:GetObserver():fireSecondary(); swarmTriggerSent=true
    end
    return result
end
local originalControlDown=R.IsPilotControlDown
R.IsPilotControlDown=function(self,buttons,name)
    if name=='FIRE_SECONDARY' and (stage==3.7 or stage==3.72 or (stage==3.75 and mn.getMissionTime()-startTime<.12)) then return true end
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
    if not ok then log('FAIL HUD '..tostring(err)); quit(); return end
    local name
    if stage==3.65 and mn.getMissionTime()-startTime>.5 then name='pilot-native-banks'
    elseif stage==3.8 and self:UINow()-uiAt>.5 then name='director-close-shot'
    elseif stage==3.85 and self:UINow()-uiAt>.3 then name='sky-'..skyView
    elseif stage==6 and self:UINow()-uiAt>.3 then name='command-estimates-hidden'
    elseif stage==6.1 and self:UINow()-uiAt>.3 then name='crew-record-detail'
    elseif stage==6.2 and self:UINow()-uiAt>.3 then name='command-estimates-shown'
    elseif stage==7 and self:UINow()-uiAt>.3 then name='cost-of-command' end
    if name and not screenshots[name] and not self.ReviewProbeHeadless then
        local blob=gr.screenToBlob(); local file=cf.openFile(name..'.blob','w','data')
        assert(file and file:isValid() and #blob>1000,'native screenshot capture failed: '..name)
        file:write(blob); file:close(); screenshots[name]=true
    end
end
local function probe(self)
    if stage==3.7 then
        for i,missile in ipairs(pilotMissiles) do
            if not missileExamined[i] and missile:isValid() then
                log('PILOT_MISSILE '..i..' class='..missile.Class.Name..' target='..tostring(missile.Target)..' homing='..tostring(missile.HomingObject)..' parent='..tostring(missile.Parent))
                missileExamined[i]=true
            end
            if not missileHomingSeen[i] and missile:isValid() and missile.HomingObject:isValid() and missile.HomingObject==missileTarget then
                check(missile.Parent==missileBomber,'pilot missile belongs to the real bomber')
                missileHomingSeen[i]=true
            end
        end
    end
    if stage==3.75 then
        for i,missile in ipairs(pilotSwarm) do
            if not swarmHomingSeen[i] and missile:isValid() and missile.HomingObject:isValid() and missile.HomingObject==missileTarget then
                check(missile.Parent==missileBomber,'queued pilot swarm missile belongs to the real bomber')
                swarmHomingSeen[i]=true
            end
        end
    end
    if stage==0 and self.SetupActive then
        self.SetupOpponents={RED=true,GOLD=true}; self.SetupAutoMode=false; self.SetupSentries=false
        self:StartScenario(); self.ActiveIncomePerSecond=0
        check(self.SetupBackdropChoice=='RANDOM' and self.EnvironmentBackdropIndex~=nil and #self.EnvironmentBackdropElements==6,
            'native match start selects a random six-face nebula')
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
        missileBomber=mn.createShip('Pilot missile bomber',tb.ShipClasses['GTB Medusa'],
            ba.createOrientationFromVectors(ba.createVector(0,0,1)),ba.createVector(-40000,12000,-40000),mn.Teams[self.Config.FriendlyTeam],true)
        check(missileBomber:isValid(),'native missile fixture creates a turret-equipped bomber')
        self:InvalidateShipList()
        missileTarget=target('Pilot missile target','GTF Hercules',missileBomber.Position+ba.createVector(0,0,800),mn.Teams[self.Config.HostileTeam])
        check(tb.WeaponClasses['Harpoon']:loadWeapon(),'native aspect missile asset loads')
        check(missileBomber.Position:getDistance(missileTarget.Position)<self:GetWeaponFiringRange(tb.WeaponClasses['Harpoon']),
            'native missile contact is within the actual aspect-lock range')
        for b=1,#missileBomber.SecondaryBanks do missileBomber.SecondaryBanks[b].AmmoLeft=0 end
        missileBomber.SecondaryBanks[1].WeaponClass=tb.WeaponClasses['Harpoon']
        missileBomber.SecondaryBanks[1].AmmoLeft=3; missileBomber.SecondaryBanks[1].Armed=true
        missileBomber.SecondaryBanks.DualFire=false
        check(self:StartPilotMode(missileBomber),'native missile fixture enters possession')
        check(not self.PilotWeaponsHUDOverridden and #self:GetObserver().PrimaryBanks>0 and #self:GetObserver().SecondaryBanks>0,
            'turret-equipped bomber retains native primary and secondary weapon display')
        self:GetObserver().Target=missileTarget
        self:SetTimeScale(1); startTime=mn.getMissionTime(); stage=3.65
    elseif stage==3.65 and mn.getMissionTime()-startTime>5 then
        startTime=mn.getMissionTime(); stage=3.7
    elseif stage==3.7 and mn.getMissionTime()-startTime>15 then
        check(#pilotMissiles==3,'holding missile fire launches exactly the three carried missiles')
        check(missileBomber.SecondaryBanks[1].AmmoLeft==0 and self:GetObserver().SecondaryBanks[1].AmmoLeft==0,
            'native pilot missile ammunition depletes on both hull and HUD proxy')
        for i=1,#pilotMissiles do
            check(missileHomingSeen[i],'native pilot aspect missile tracks the selected target')
            if i>1 then check(missileTimes[i]-missileTimes[i-1]>=tb.WeaponClasses['Harpoon'].FireWait-.1,
                'native pilot missile launches respect bank cooldown') end
        end
        self.ControlInfo.SecondaryCount=0; self.ControlInfo.clearLuaButtonInfo()
        self:GetObserver().SecondaryBanks[1].AmmoLeft=1; self:GetObserver().SecondaryBanks[1].Armed=true
        missileBomber.SecondaryBanks=self:GetObserver().SecondaryBanks
        startTime=mn.getMissionTime(); stage=3.705
    elseif stage==3.705 and mn.getMissionTime()-startTime>3 then
        check(self:GetObserver():fireSecondary()>0 and self:GetObserver().SecondaryBanks[1].AmmoLeft==0
            and missileBomber.SecondaryBanks[1].AmmoLeft==1,'native last-shot fixture has an unmirrored expenditure')
        self:ExitPilotMode(nil,false)
        check(missileBomber.SecondaryBanks[1].AmmoLeft==0,'immediate pilot exit commits the last native missile expenditure')
        check(self:StartPilotMode(missileBomber),'last-shot bomber can be possessed again')
        check(self:GetObserver().SecondaryBanks[1].AmmoLeft==0,'immediate pilot re-entry cannot refund the last missile')
        self:GetObserver().Target=missileTarget
        check(tb.WeaponClasses['Hornet']:loadWeapon(),'native queued swarm asset loads')
        self:GetObserver().SecondaryBanks[1].WeaponClass=tb.WeaponClasses['Hornet']
        self:GetObserver().SecondaryBanks[1].AmmoLeft=4
        missileBomber.SecondaryBanks=self:GetObserver().SecondaryBanks
        missileTarget.Position=missileBomber.Position+ba.createVector(0,0,500)
        check(missileBomber.Position:getDistance(missileTarget.Position)<self:GetWeaponFiringRange(tb.WeaponClasses['Hornet']),
            'native swarm contact is inside its lock range')
        self:SetPaused(true); uiAt=self:UINow(); stage=3.72
    elseif stage==3.72 and self:UINow()-uiAt>2 then
        check(#pilotSwarm==0 and missileBomber.SecondaryBanks[1].AmmoLeft==4 and self:GetObserver().SecondaryBanks[1].AmmoLeft==4,
            'native secondary trigger cannot spend ammunition while paused')
        self.ControlInfo.clearLuaButtonInfo(); self:SetPaused(false)
        startTime=mn.getMissionTime(); stage=3.71
    elseif stage==3.71 and mn.getMissionTime()-startTime>5 then
        startTime=mn.getMissionTime(); stage=3.75
    elseif stage==3.75 and mn.getMissionTime()-startTime>8 then
        check(#pilotSwarm==4,'one native trigger tap completes exactly one four-missile swarm after release')
        check(missileBomber.SecondaryBanks[1].AmmoLeft==0 and self:GetObserver().SecondaryBanks[1].AmmoLeft==0,
            'queued native swarm depletes ammunition without refilling the proxy')
        for i=1,#pilotSwarm do check(swarmHomingSeen[i],'queued native swarm tracks the selected target') end
        self.ControlInfo.SecondaryCount=0; self:ExitPilotMode(nil,false)
        check(missileBomber.SecondaryBanks[1].AmmoLeft==0,'pilot exit preserves depleted ammunition')
        check(self:StartPilotMode(missileBomber),'depleted bomber can be possessed again')
        check(self:GetObserver().SecondaryBanks[1].AmmoLeft==0,'pilot re-entry does not refill missiles')
        self:ExitPilotMode(nil,false)
        self.FollowZoom=1; self.FollowYawOffset=0; self.FollowPitchOffset=.2
        self:UpdateFollowCamera(missileBomber,capital)
        local baseDistance=math.max(self.Config.Camera.FollowMinDistance,missileBomber.Radius*self.Config.Camera.FollowRadiusMultiplier)
        check(self.FollowCamera.Position:getDistance(missileBomber.Position)<=baseDistance*2+1,
            'native director stays close to the ship instead of framing a remote target')
        self.BattleCamActive=true; self.BattleCamSignature=missileBomber:getSignature()
        self.BattleCamTargetSignature=capital:getSignature()
        self.BattleCamShotStart=self:UINow(); self.BattleCamShotUntil=self:UINow()+4; self.BattleCamYawStart=0
        self:SetTimeScale(1); uiAt=self:UINow(); stage=3.8
    elseif stage==3.8 and self:UINow()-uiAt>1 then
        check(self:SetNebulaBackdrop(1,true) and #self.EnvironmentBackdropElements==6,
            'native backdrop creates six sky faces without a wrapped maximum-scale quad')
        self.BattleCamSignature=nil; self.BattleCamTargetSignature=nil
        uiAt=self:UINow(); stage=3.85
    elseif stage==3.85 and self:UINow()-uiAt>.6 then
        if skyView<6 then skyView=skyView+1; uiAt=self:UINow()
        else self:StopBattleCam(); self:SetTimeScale(8); stage=4 end
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
        check(not self.ShowFleetCost and self:GetLiveCostHeight()==0,'native crew estimates start hidden')
        check(require('fs2rts_util').shipAlive(false)==false,'native shared validity rejects boolean handles')
        check(self:StartPilotMode(movers[1]),'native personal-history craft can be piloted')
        self:ExitPilotMode(nil,false)
        local record=self:GetUnitHistory(movers[1])
        check(record.everPiloted and self:GetShipHistoryBadge(movers[1]):find('P',1,true),'native personal history persists after pilot exit')
        self.PanelTab='history'; self.LiveHistoryDetail=record.id
        local panel=self:GetProductionPanelRect(gr.getScreenWidth(),gr.getScreenHeight())
        check(panel.y2<gr.getScreenHeight()-self:GetUIMetrics().margin,'native CREWS panel ends after its content')
        uiAt=self:UINow(); stage=6.1
    elseif stage==6.1 and self:UINow()-uiAt>uiSeconds then
        local record=self:GetUnitHistory(movers[1]); local rect=self.FleetHistoryButtonRects[record.id]
        check(rect~=nil,'native CREWS list contains the piloted lifetime')
        local focus=self.CameraFocus
        check(self:HandleFleetHistoryClick(rect.x1+1,rect.y1+1) and self.LiveHistoryDetail==record.id and self.CameraFocus==focus,
            'native CREWS row selects without moving the camera')
        local fate=record.fate; record.fate='LOST'
        check(not self:FocusHistoryShip(record.id,false),'native archived crew focus rejects removed lifetime without indexing false')
        record.fate=fate; self.PanelTab='production'
        self:OnKeyPressed('F9','F9'); self:OnKeyPressed('F9','F9')
        check(self.ShowFleetCost and self:GetLiveCostHeight()>0,'native F9 repeat keeps estimates visible')
        self:OnKeyReleased('F9','F9'); uiAt=self:UINow(); stage=6.2
    elseif stage==6.2 and self:UINow()-uiAt>uiSeconds then
        self:OnKeyPressed('F9','F9'); self:OnKeyReleased('F9','F9')
        check(not self.ShowFleetCost,'native F9 toggles estimates off')
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
