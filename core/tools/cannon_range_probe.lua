-- Isolated native combat check. Load instead of review_engine_probe, using its SCT.
-- Works with upstream rendered FSO or the experimental headless engine.
local R=require 'fs2rts'
local out=cf.openFile('cannon-range-probe.log','w','data')
assert(out and out:isValid())
local started,finished,startTime=false,false,nil
local physicsElapsed=0
local armorShots={}; local armorStarted=false
local targets={}
local fighterChecks={}
local capitalBeamArmorRows={}
local paidPosition,paidCost,paidBank
local fightersChecked=false
local capitalIndex,capitalAt=0,0
local capitalRows={}
local capitalBySignature={}
local armorRows={}
local armorCollisionBySignature={}
local capitalBeamArmorBySignature={}
local debrisRows={}
local debrisBySignature={}
local accelerated=false
engine.addHook('On Weapon Collision',function()
    local target,weapon=hv['Self'],hv['Weapon']
    local slot=target and target:isValid() and armorCollisionBySignature[target:getSignature()]
    if slot and weapon and weapon:isValid() and weapon.Class.Name=='Cyclops' then
        slot.row.cyclopsContacts[slot.index]=slot.row.cyclopsContacts[slot.index]+1
        local hit=hv['Hitpos']
        if hit then
            local center=target.Position
            slot.row.cyclopsHits[slot.index][#slot.row.cyclopsHits[slot.index]+1]={
                x=hit.x-center.x,y=hit.y-center.y,z=hit.z-center.z}
        end
    end
end)
engine.addHook('On Debris Collision',function()
    local ship=hv.Ship
    local row=ship and ship:isValid() and debrisBySignature[ship:getSignature()]
    if row and hv.Debris and hv.Debris:isValid() and hv.Debris:getSignature()==row.piece:getSignature() then
        row.contacts=row.contacts+1
        row.hullDamage=1000000-ship.HitpointsLeft
    end
end)
local function recordShot(row,turret,name)
    local key=turret.CanonicalName..'/'..name
    row.shots[key]=(row.shots[key] or 0)+1
end
engine.addHook('On Beam Fire',function()
    local row=hv.User and hv.User:isValid() and capitalBySignature[hv.User:getSignature()]
    if row then
        row.beams=row.beams+1
        recordShot(row,hv.Beam.ParentSubsystem,hv.Beam.Class.Name)
    end
end)
engine.addHook('On Beam Collision',function()
    local parent=hv.Beam and hv.Beam:isValid() and hv.Beam.ParentShip
    local row=parent and parent:isValid() and capitalBySignature[parent:getSignature()]
    if row then row.hits=row.hits+1 end
end)
engine.addHook('On Beam Fire',function()
    local user=hv.User and hv.User:isValid() and hv.User
    local row=user and capitalBeamArmorBySignature[user:getSignature()]
    if row then row.fires=row.fires+1 end
end)
engine.addHook('On Beam Collision',function()
    local beam=hv.Beam and hv.Beam:isValid() and hv.Beam
    local parent=beam and beam.ParentShip
    local row=parent and parent:isValid() and capitalBeamArmorBySignature[parent:getSignature()]
    if row then row.hits=row.hits+1 end
end)
engine.addHook('On Turret Fired',function()
    local row=hv.Ship and hv.Ship:isValid() and capitalBySignature[hv.Ship:getSignature()]
    if row and hv.Weapon and hv.Weapon:isValid() then
        row.projectiles=row.projectiles+1
        recordShot(row,hv.Weapon.ParentTurret,hv.Weapon.Class.Name)
        local weapon=hv.Weapon; local target=weapon.Target:isValid() and weapon.Target or weapon.ParentTurret.Target
        if R.PossessedSignature==hv.Ship:getSignature() and target:isValid() and not R.Config.Pilot.FlakWeapons[weapon.Class.Name]
            and (target:getFlag('immobile') or target.Physics.Velocity:getDistance(ba.createVector(0,0,0))<.01) then
            local delta=target.Position-weapon.Position; local velocity=weapon.Physics.Velocity
            local length=delta:getDistance(ba.createVector(0,0,0))*velocity:getDistance(ba.createVector(0,0,0))
            if length>1 then
                row.aimChecks=(row.aimChecks or 0)+1
                local dot=(delta.x*velocity.x+delta.y*velocity.y+delta.z*velocity.z)/length
                if dot<.985 then
                    row.badAim=(row.badAim or 0)+1
                    if row.badAim<=8 then out:write('AIM_MISS '..row.name..' '..weapon.Class.Name..' turret='..weapon.ParentTurret.CanonicalName..' target='..target.Name..' dot='..dot..'\n'); out:flush() end
                end
            end
        end
    end
end)
local originalControl=R.IsPilotControlDown
R.IsPilotControlDown=function(self,buttons,name)
    if capitalIndex>0 and capitalIndex<=#capitalRows and (name=='FIRE_PRIMARY' or name=='FIRE_SECONDARY') then return true end
    return originalControl(self,buttons,name)
end
local function log(message) out:write(message..'\n'); out:flush() end
local function quit()
    finished=true; R:SetTimeScale(1)
    ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
end
engine.addHook('On Frame',function()
    if finished then ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME']) end
end)
R.Config.Cinematic.Enabled=false
R.Config.AI.ExperimentalDamageTelemetry=false
-- Disable unrelated combat/economy directors in this fixture, not in the mod.
for _,name in ipairs({'UpdateAIProduction','UpdateEnemyWaves','UpdateStations',
    'UpdateAIStrategicObjectives','UpdateFleetServices','UpdateDefaultPolicy'}) do R[name]=function() end end
local originalFrame=R.OnFrame
local function probe(self)
    if not started and self.Enabled and self.SetupActive then
        self.SetupOpponents={RED=true,GOLD=true}; self.SetupAutoMode=false; self.SetupSentries=false
        self:StartScenario()
        -- Separate battery/armor fixtures live far apart to avoid crossfire.
        -- Declare their diagnostic arena; production targeting rejects contacts
        -- outside the normal match boundary, as it should.
        self.ScenarioMapHalfExtent=600000
        self.ActiveIncomePerSecond=0
        for j=1,2 do
            local pos=ba.createVector(-400000-j*40000,0,-300000)
            local victim=mn.createShip('Debris armor control '..j,tb.ShipClasses['GTD Hecate'],ba.createOrientationFromVectors(ba.createVector(0,0,1)),pos,mn.Teams[self.Config.HostileTeam],true)
            local source=mn.createShip('Debris source '..j,tb.ShipClasses['GTD Hecate'],ba.createOrientationFromVectors(ba.createVector(0,0,1)),pos+ba.createVector(10000,0,0),mn.Teams[self.Config.FriendlyTeam],true)
            assert(victim:isValid() and source:isValid())
            victim:setFlag(true,'immobile','primaries-locked','secondaries-locked','lock-all-turrets')
            source:setFlag(true,'immobile','primaries-locked','secondaries-locked','lock-all-turrets')
            victim.HitpointsMax=1000000; victim.HitpointsLeft=1000000; victim.Shields.CombinedLeft=0
            if j==1 then
                victim.ArmorClass='RTS Command Hull'
                for k=1,#victim do victim[k].ArmorClass='RTS Command Hull' end
            end
            -- Same native collision on both hulls: amplify fragment mass to
            -- reproduce a lethal impulse without depending on random battles.
            local index=1
            for k=2,#source.Class.Model.Submodels do
                if source.Class.Model.Submodels[k].Radius>source.Class.Model.Submodels[index].Radius then index=k end
            end
            local piece=mn.createDebris(source,index,pos+ba.createVector(0,0,-4000),source.Orientation,DC_IS_HULL,1000000)
            assert(piece:isValid(),'native hull debris creation failed')
            piece.Physics.Mass=victim.Physics.Mass
            piece.Physics.RotationalVelocity=ba.createVector(0,0,0)
            piece.Physics.Velocity=ba.createVector(0,0,3000)
            piece.DoNotExpire=true
            debrisRows[j]={target=victim,piece=piece,contacts=0,hullDamage=0}
            debrisBySignature[victim:getSignature()]=debrisRows[j]
        end
        for i,name in ipairs({'Subach HL-7','Prometheus R','Tempest','Tornado','Cyclops','Vasudan Flux Cannon'}) do
            local row={name=name,targets={},cyclopsContacts={0,0},cyclopsHits={{},{}}}; armorRows[#armorRows+1]=row
            for j=1,2 do
                local pos=ba.createVector(-60000-i*20000,0,50000+j*10000)
                -- Cyclops is a 200 m radius blast with only a 100 m
                -- full-damage core. Fenris surface contacts landed ~110 m
                -- from center; small differences in projectile hit position
                -- changed blast attenuation despite equal 4/4 direct hits.
                -- Use one small identical target in both lanes so Cyclops
                -- direct + shockwave damage stays inside its full-damage core.
                local targetClass=(name=='Cyclops' or name=='Vasudan Flux Cannon') and 'GTF Myrmidon' or 'GTC Fenris'
                local victim=mn.createShip('Armor control '..i..' '..j,tb.ShipClasses[targetClass],ba.createOrientationFromVectors(ba.createVector(0,0,1)),pos,mn.Teams[self.Config.HostileTeam],true)
                assert(victim:isValid()); victim:setFlag(true,'immobile','primaries-locked','secondaries-locked')
                for b=1,#victim do if victim[b]:isTurret() then victim[b].TurretLocked=true end end
                victim.HitpointsMax=1000000; victim.HitpointsLeft=1000000; victim.Shields.CombinedLeft=0
                if j==1 then
                    victim.ArmorClass='RTS Command Hull'
                    for k=1,#victim do victim[k].ArmorClass='RTS Command Hull' end
                end
                row.targets[j]=victim
                armorCollisionBySignature[victim:getSignature()]={row=row,index=j}
                local hit= victim:checkRayCollision(pos+ba.createVector(0,0,-5000),pos+ba.createVector(0,0,5000))
                assert(hit,'armor fixture ray misses the model')
                armorShots[#armorShots+1]={name=name,victim=victim,position=hit+ba.createVector(0,0,-200)}
            end
        end
        paidPosition=self:FindSentrySpot('BLUE'); assert(paidPosition,'no legal paid placement site')
        local paidOption=self:GetSentryOptions('BLUE')[1]
        paidCost=paidOption.cost; paidBank=self.CommandPoints
        self.ArmedCommand='sentry'; self.ArmedSentryIndex=1
        self:ExecuteStationArmedCommand(paidPosition)
        assert(#self.PendingSentries==1 and self.CommandPoints==paidBank-paidCost,'paid player placement did not queue exactly once')
        for i,label in ipairs({'BLUE','RED','GOLD','CONTROL'}) do
            local kind=label=='CONTROL' and 'BLUE' or label
            local pos=ba.createVector(60000+i*20000,0,-45000)
            local victimTeam=mn.Teams[kind=='RED' and self.Config.FriendlyTeam or self.Config.HostileTeam]
            local target=mn.createShip('Range target '..label,tb.ShipClasses['GTC Fenris'],
                ba.createOrientationFromVectors(ba.createVector(0,0,1)),pos+ba.createVector(0,0,6000),victimTeam,true)
            assert(target:isValid(),'target creation failed')
            target:setFlag(true,'immobile','primaries-locked','secondaries-locked','lock-all-turrets')
            target.HitpointsMax=1000000; target.HitpointsLeft=1000000
            if label=='BLUE' then target.ArmorClass='RTS Base Hull' end
            local option=self.Config.Station.Sentries.Classes[kind][1]
            local sentry=self:CreateSentry(kind,option,pos,true)
            assert(sentry and sentry:isValid(),'sentry creation failed: '..kind)
            sentry.Orientation=ba.createOrientationFromVectors(ba.createVector(0,0,1))
            local banks,screens=0,0
            for j=1,#sentry do
                local turret=sentry[j]
                if turret:isTurret() then
                    turret.Target=target
                    for b=1,#turret.PrimaryBanks do
                        local name=turret.PrimaryBanks[b].WeaponClass.Name
                        if name==option.weapon then banks=banks+1
                        elseif name==self.Config.Station.Sentries.ScreenWeapon then screens=screens+1
                        else assert(false,'unexpected sentry weapon: '..name) end
                    end
                end
            end
            assert(banks==2,'asymmetric native cannon count: '..kind..' '..banks)
            assert(screens==2,'missing native close-defense banks: '..kind)
            targets[label]=target
            log('READY '..label..' two cannon banks, stationary target at 6000 m')
        end
        -- A native capital-ship beam SEXP fires the same actual retail turret
        -- bank into three paired armor classes. This isolates Command Hull from
        -- the 10% fleet Base Hull and an unarmored control.
        for i,label in ipairs({'COMMAND','BASE','CONTROL'}) do
            local pos=ba.createVector(300000+i*10000,0,-300000)
            local target=mn.createShip('Capital beam armor '..label,tb.ShipClasses['GTC Fenris'],
                ba.createOrientationFromVectors(ba.createVector(0,0,1)),pos,mn.Teams[self.Config.HostileTeam],true)
            assert(target:isValid(),'capital beam armor target creation failed: '..label)
            target:setFlag(true,'immobile','primaries-locked','secondaries-locked','lock-all-turrets')
            target.HitpointsMax=1000000; target.HitpointsLeft=1000000; target.Shields.CombinedLeft=0
            if label=='COMMAND' then target.ArmorClass='RTS Command Hull'
            elseif label=='BASE' then target.ArmorClass='RTS Base Hull' end
            local shooter=mn.createShip('Capital beam shooter '..label,tb.ShipClasses['GTD Orion'],
                ba.createOrientationFromVectors(ba.createVector(0,0,1)),pos+ba.createVector(0,0,-1500),mn.Teams[self.Config.FriendlyTeam],true)
            assert(shooter:isValid(),'capital beam shooter creation failed: '..label)
            self:EnableFullArsenal(shooter)
            local beamTurret,selectedBeamName=nil,nil
            for j=1,#shooter do
                local turret=shooter[j]
                if turret:isTurret() then
                    local beamBank=nil
                    for b=1,#turret.PrimaryBanks do if turret.PrimaryBanks[b].WeaponClass:isBeam() then beamBank=turret.PrimaryBanks[b]; break end end
                    if beamBank and not beamTurret then beamTurret=turret; selectedBeamName=beamBank.WeaponClass.Name; turret.TurretLocked=false
                    else turret.TurretLocked=true end
                end
            end
            assert(beamTurret,'GTD Orion has no native beam turret')
            -- Prevent native AI target acquisition from adding unsampled
            -- projectiles or beams to the explicit fire-beam measurement.
            shooter:giveOrder(ORDER_PLAY_DEAD,nil,nil,2)
            local beamRow={name=label,target=target,shooter=shooter,fires=0,hits=0}
            capitalBeamArmorRows[#capitalBeamArmorRows+1]=beamRow
            capitalBeamArmorBySignature[shooter:getSignature()]=beamRow
            local sexp=string.format('(fire-beam "%s" "%s" "%s" "<none>" true)',
                shooter.Name,beamTurret.CanonicalName,target.Name)
            beamRow.sexp=sexp
            log('CAPITAL_BEAM_ARMOR_QUEUED '..label..' source='..beamTurret.Name..' canonical='..tostring(beamTurret.CanonicalName)..' weapon='..selectedBeamName..' armor='..tostring(target.ArmorClass))
        end
        for i,kind in ipairs({'BLUE','RED','GOLD'}) do
            local pos=ba.createVector(60000+i*20000,0,-80000)
            local team=mn.Teams[kind=='RED' and self.Config.FriendlyTeam or self.Config.HostileTeam]
            local fighter=mn.createShip('Incoming fighter '..kind,tb.ShipClasses['GTF Myrmidon'],
                ba.createOrientationFromVectors(ba.createVector(0,0,-1)),pos+ba.createVector(0,0,4500),team,true)
            assert(fighter:isValid()); fighter:setFlag(true,'primaries-locked','secondaries-locked')
            fighter:giveOrder(ORDER_PLAY_DEAD,nil,nil,2)
            fighter:doManeuver(1,0,0,0,true,0,0,.4,true,0)
            fighter.HitpointsMax=100000; fighter.HitpointsLeft=100000; fighter.Shields.CombinedLeft=0
            local sentry=self:CreateSentry(kind,self.Config.Station.Sentries.Classes[kind][1],pos,true)
            assert(sentry and sentry:isValid())
            fighterChecks[#fighterChecks+1]={kind=kind,fighter=fighter,sentry=sentry}
        end
        for i,name in ipairs({'GTD Orion','GTD Hecate','GTVA Colossus','SJ Sathanas'}) do
            local pos=ba.createVector(60000+i*30000,0,-120000)
            local hull=mn.createShip('Manual '..name,tb.ShipClasses[name],ba.createOrientationFromVectors(ba.createVector(0,0,1)),pos,mn.Teams[self.Config.FriendlyTeam],true)
            local target=mn.createShip('Manual target '..i,tb.ShipClasses['GTD Hecate'],ba.createOrientationFromVectors(ba.createVector(0,0,1)),pos+ba.createVector(0,0,4000),mn.Teams[self.Config.HostileTeam],true)
            assert(hull:isValid() and target:isValid())
            hull:setFlag(true,'immobile','invulnerable'); target:setFlag(true,'immobile','primaries-locked','secondaries-locked')
            target:giveOrder(ORDER_PLAY_DEAD,nil,nil,2)
            for j=1,#target do if target[j]:isTurret() then target[j].TurretLocked=true end end
            target.HitpointsMax=10000000; target.HitpointsLeft=10000000; target.Shields.CombinedLeft=0
            self:EnableFullArsenal(hull)
            -- Give every mount a legal local contact in its barrel direction.
            -- A single distant target cannot exercise the short defense lasers
            -- or opposite broadside, even though ALL groups are enabled.
            for j=1,#hull do
                local turret=hull[j]
                if turret:isTurret() and (#turret.PrimaryBanks>0 or #turret.SecondaryBanks>0) then
                    local muzzle,normal=turret:getNextFiringPosition()
                    local reach=800
                    for _,banks in ipairs({turret.PrimaryBanks,turret.SecondaryBanks}) do
                        for b=1,#banks do reach=math.min(reach,self:GetWeaponFiringRange(banks[b].WeaponClass)*.6) end
                    end
                    local contact=muzzle+normal*math.max(100,reach)
                    local localTarget=mn.createShip('Battery contact '..i..' '..j,tb.ShipClasses['GTF Myrmidon'],
                        ba.createOrientationFromVectors(ba.createVector(0,0,1)),contact,mn.Teams[self.Config.HostileTeam],true)
                    assert(localTarget:isValid()); localTarget:setFlag(true,'immobile','invulnerable','primaries-locked','secondaries-locked')
                    localTarget:giveOrder(ORDER_PLAY_DEAD,nil,nil,2)
                    log('CONTACT '..name..' '..turret.CanonicalName..' distance='..reach..' arc='..tostring(turret:isPositionInFOV(localTarget.Position)))
                    localTarget.HitpointsMax=1000000; localTarget.HitpointsLeft=1000000; localTarget.Shields.CombinedLeft=0
                end
            end
            -- Inactive matrix hulls must not contribute automatic fire.
            hull:giveOrder(ORDER_PLAY_DEAD,nil,nil,2)
            for j=1,#hull do if hull[j]:isTurret() then hull[j].TurretLocked=true end end
            local row={name=name,ship=hull,target=target,beams=0,hits=0,projectiles=0,shots={}}
            capitalRows[#capitalRows+1]=row; capitalBySignature[hull:getSignature()]=row
        end
        self:InvalidateShipList()
        started=true; startTime=mn.getMissionTime(); self:SetTimeScale(1)
    elseif started and not finished and physicsElapsed>=110 and capitalIndex>#capitalRows then
        local missed={}
        for kind,target in pairs(targets) do
            assert(target:isValid(),'target disappeared: '..kind)
            local damage=1000000-target.HitpointsLeft
            log('DAMAGE '..kind..' '..damage)
            if damage<=0 then missed[#missed+1]=kind end
        end
        assert(#missed==0,'cannon did not damage a 6000 m target: '..table.concat(missed,','))
        local capped=1000000-targets.BLUE.HitpointsLeft
        local uncapped=1000000-targets.CONTROL.HitpointsLeft
        assert(capped<=uncapped*.15,'cannon blast bypassed the RTS base armor damage cap')
        assert(fightersChecked,'incoming fighter screen test did not run')
        local debrisCapped=debrisRows[1].hullDamage
        local debrisControl=debrisRows[2].hullDamage
        log('DEBRIS_ARMOR capped='..debrisCapped..' control='..debrisControl..' cappedContacts='..debrisRows[1].contacts..' controlContacts='..debrisRows[2].contacts)
        local beamDamage={}
        for _,row in ipairs(capitalBeamArmorRows) do
            beamDamage[row.name]=1000000-row.target.HitpointsLeft
            log('CAPITAL_BEAM_ARMOR '..row.name..' damage='..beamDamage[row.name]..' fires='..row.fires..' hits='..row.hits)
            assert(beamDamage[row.name]>0,'native BGreen beam did not hit '..row.name..' armor target')
        end
        assert(math.abs(beamDamage.COMMAND/beamDamage.CONTROL-.25)<.03,
            'command-station capital beam factor is not 25%')
        assert(math.abs(beamDamage.BASE/beamDamage.CONTROL-.10)<.03,
            'fleet capital beam factor changed from 10%')
        assert(math.abs(beamDamage.COMMAND/beamDamage.BASE-2.5)<.5,
            'capital beams do not deal 2.5x damage to a command station versus fleet armor')
        assert(debrisControl>51000,'native debris control did not reproduce a station-killing impact')
        assert(debrisRows[1].contacts>0 and debrisRows[2].contacts>0,'native debris fixture missed a control hull')
        assert(debrisCapped<=250*debrisRows[1].contacts,'command armor failed to bound the native debris impact')
        for _,row in ipairs(armorRows) do
            local capped=1000000-row.targets[1].HitpointsLeft
            local control=1000000-row.targets[2].HitpointsLeft
            local function hitList(values)
                local items={}; for _,hit in ipairs(values) do items[#items+1]=string.format('(%.0f,%.0f,%.0f)',hit.x,hit.y,hit.z) end
                return table.concat(items,';')
            end
            log('LIGHT_ARMOR '..row.name..' capped='..capped..' control='..control
                ..' cyclopsCollisions='..row.cyclopsContacts[1]..'/'..row.cyclopsContacts[2]
                ..' cappedHitpos='..hitList(row.cyclopsHits[1])..' controlHitpos='..hitList(row.cyclopsHits[2]))
            assert(control>0 and capped>0,'armor control weapons did not collide: '..row.name)
            local expected=row.name=='Cyclops' and 1 or row.name=='Vasudan Flux Cannon' and .025 or .05
            assert(math.abs(capped/control-expected)<.015,'station damage ratio is wrong: '..row.name)
        end
        local deployed=false
        for _,sentry in ipairs(self:GetFactionSentries('BLUE')) do
            if sentry.Position:getDistance(paidPosition)<5 and self.SentryCosts[sentry:getSignature()]==paidCost then deployed=true end
        end
        log('PAID_PLACEMENT deployed='..tostring(deployed)..' pending='..#self.PendingSentries..' bank='..self.CommandPoints..' expected='..(paidBank-paidCost))
        assert(deployed and #self.PendingSentries==0 and self.CommandPoints==paidBank-paidCost,'paid sentry did not complete at the requested site')
        log('PASS native paid player sentry construction completes at requested position without duplicate charge')
        log('PASS native RTS base armor caps cannon blast damage')
        log('COMPLETE all three native cannons hit beyond retail lifetime'); quit()
    end
end
R.OnFrame=function(self)
    if finished then return end
    local ok,err=pcall(function()
        local wasStarted=started
        originalFrame(self); probe(self)
        if wasStarted then physicsElapsed=physicsElapsed+ba.getMissionFrametime() end
        if started and not finished then
            if not armorStarted and physicsElapsed>=1 then
                -- Launch after cold fixture assets load, so weapon clocks cannot expire before flight.
                for _,shot in ipairs(armorShots) do
                    for _=1,4 do
                        local weapon=mn.createWeapon(tb.WeaponClasses[shot.name],ba.createOrientationFromVectors(ba.createVector(0,0,1)),shot.position,self:GetCarrier())
                        assert(weapon:isValid(),'native armor projectile creation failed'); weapon.Target=shot.victim
                    end
                end
                for _,row in ipairs(capitalBeamArmorRows) do assert(mn.runSEXP(row.sexp),'native armor beam launch rejected') end
                armorStarted=true
            end
            -- Loading advances mission time without moving the debris fixture.
            if not accelerated and physicsElapsed>=5 then accelerated=true; self:SetTimeScale(16) end
            self:UpdateSentryConstruction(mn.getMissionTime()); self:UpdateSentryAim(mn.getMissionTime())
            local current=capitalRows[capitalIndex]
            if capitalIndex==0 or (current and physicsElapsed-capitalAt>=35
                and ((current.aimChecks or 0)>10 or physicsElapsed-capitalAt>=70)) then
                if capitalIndex>0 then
                    local row=capitalRows[capitalIndex]
                    local failures={}
                    log('CAPITAL_MATRIX '..row.name..' beams='..row.beams..' hits='..row.hits..' projectiles='..row.projectiles)
                    for _,group in ipairs(self.PilotTurretGroups or {}) do
                        for _,entry in ipairs(group.turrets) do
                            local turret=entry.subsystem
                            for family,banks in pairs({primary=turret.PrimaryBanks,secondary=turret.SecondaryBanks}) do
                                for b=1,#banks do
                                    local weapon=banks[b].WeaponClass
                                    local index=turret.CanonicalName
                                    local shots=row.shots[index..'/'..weapon.Name] or 0
                                    log('BANK '..row.name..' '..tostring(turret.WorldPosition)..' '..family..' '..weapon.Name..' shots='..shots..' arc='..tostring(turret:isTargetInFOV(row.target))..' locked='..tostring(entry.wasLocked))
                                    local slot=family=='primary' and b or 3+b
                                    if shots==0 or not (entry.cooldowns and entry.cooldowns[slot]) then
                                        local target=turret.Target
                                        if target:isValid() then
                                            local muzzle,normal=turret:getNextFiringPosition()
                                            local delta=target.Position-muzzle; local length=delta:getDistance(ba.createVector(0,0,0))
                                            log('MISSED_BANK '..index..' target='..target.Name..' distance='..length..' centerArc='..tostring(turret:isPositionInFOV(target.Position))..' dot='..((delta.x*normal.x+delta.y*normal.y+delta.z*normal.z)/length)..' fov='..turret:getFOVs()..' beamFree='..tostring(turret.BeamFree))
                                        else log('MISSED_BANK '..index..' NO TARGET') end
                                        failures[#failures+1]=index..'/'..weapon.Name
                                    end
                                end
                            end
                        end
                    end
                    assert(#failures==0,'loaded manual banks never fired with local contacts: '..row.name..' '..table.concat(failures,','))
                    assert(row.beams>0 and row.hits>0 and row.projectiles>0,row.name..' did not fire both beam and projectile batteries under manual control')
                    log('PROJECTILE_AIM '..row.name..' checked='..(row.aimChecks or 0)..' wrong='..(row.badAim or 0))
                    assert((row.aimChecks or 0)>10 and (row.badAim or 0)==0,row.name..' projectiles do not aim at stationary contacts')
                    self:ExitPilotMode(nil,false)
                end
                capitalIndex=capitalIndex+1
                if capitalIndex<=#capitalRows then
                    local row=capitalRows[capitalIndex]
                    for j=1,#row.ship do if row.ship[j]:isTurret() then row.ship[j].TurretLocked=false end end
                    assert(self:StartPilotMode(row.ship)); self:GetObserver().Target=row.target
                    assert(self.PilotWeaponCycleHooksActive,'upstream remapped bank-cycle overrides were not installed')
                    capitalAt=physicsElapsed
                end
            end
            if not fightersChecked and physicsElapsed>=40 then
                for _,row in ipairs(fighterChecks) do
                    local distance=row.sentry.Position:getDistance(row.fighter.Position)
                    local damage=100000-row.fighter.HitpointsLeft
                    log('FIGHTER_SCREEN '..row.kind..' distance='..distance..' damage='..damage)
                    assert(distance>2500 and damage>0,row.kind..' did not hit an incoming fighter beyond close-defense range')
                end
                fightersChecked=true
            end
        end
    end)
    if not ok then log('FAIL '..tostring(err)); quit() end
end
return true
