-- Opt-in upstream command/service mechanics; no fixture hooks in normal play.
local R=require 'fs2rts'
local out=cf.openFile('command-service-probe.log','w','data')
assert(out and out:isValid())
local function log(s) out:write(s..'\n'); out:flush() end
local function check(ok,s) assert(ok,s); log('PASS '..s) end
local finished,stage,at=false,0,0
local mover,enemy,destination,startDistance
local moverWeaponHits=0
local damageBase,damageFighter,damageBomber
local fighterBaseHits,bomberBaseHits,fighterBaseHull,fighterBaseDelta,bomberBaseHull=0,0,0,0,0
local expectedSubsystem,subsystemHpBefore,subsystemBaseHpBefore,subsystemHitsBefore
local baseVolley={}
local visitors={}; local initialCP
local isolated,rally,rallyDistance
local stationBeams={}; local beamLengths={}
local updateAIProduction=R.UpdateAIProduction
local updateStationAI=R.UpdateStationAI
local originalGetFleetCap=R.GetFleetCap
local scenarioIncome,capitalRequest,capitalClass,capitalCost
local capitalStartedAt,capitalCapOverride,capitalCapWaited,capitalSavingSeen,capitalQueueSeen
local capitalBeforeSignatures,capitalBuiltSignature,capitalVerifyAt
local capitalRequestUIStartedAt,capitalProgressLogged
local spawnAIProduction=R.SpawnAIProduction
R.SpawnAIProduction=function(self,kind,queued,spawned)
    local expected=kind=='BLUE' and capitalClass and queued.entry.class==capitalClass and queued.signaturePositions
    local first,result=spawnAIProduction(self,kind,queued,spawned)
    if kind=='BLUE' and capitalClass and queued.entry.class==capitalClass then
        check(expected and #expected==1 and first and first:isValid(),'native requested capital has a visible jump signature')
        check(first.Position:getDistance(expected[1].pos)<.1,'native capital arrives at the visible jump signature')
    end
    return first,result
end
local function restoreCapitalProbeOverrides()
    R.GetFleetCap=originalGetFleetCap
    capitalCapOverride=nil
end
engine.addHook('On Beam Fire',function()
    if hv.Beam and hv.Beam:isValid() and hv.Beam.Class.Name:sub(1,12)=='RTS Station ' then
        stationBeams[#stationBeams+1]={beam=hv.Beam,at=mn.getMissionTime()}
    end
end)
engine.addHook('On Weapon Collision',function()
    local target,weapon=hv['Self'],hv['Weapon']
    if target and target:isValid() and target.Name=='Command mover' and weapon and weapon:isValid() then
        moverWeaponHits=moverWeaponHits+1
    end
end,{['Ship']='Command mover'})
engine.addHook('On Ship Collision',function()
    local target=hv['Ship']; local weapon,beam=hv['Weapon'],hv['Beam']
    local parent=weapon and weapon:isValid() and weapon.Parent or beam and beam:isValid() and beam.ParentShip
    if not damageBase or not target or not target:isValid() or target:getSignature()~=damageBase:getSignature()
        or not parent or not parent:isValid() then return end
    if damageFighter and parent:getSignature()==damageFighter:getSignature() then fighterBaseHits=fighterBaseHits+1 end
    if damageBomber and parent:getSignature()==damageBomber:getSignature() then bomberBaseHits=bomberBaseHits+1 end
end,{['Ship']=R.Config.EnemyCommandShip})
local commAt,departSeen=0,false
local commOriginal=R.OnPilotCommOrder
R.OnPilotCommOrder=function(self,recipient,order,target,subsystem,name)
    if name=='Depart' then departSeen=true end
    return commOriginal(self,recipient,order,target,subsystem,name)
end
local original=R.OnFrame
local updateStations=R.UpdateStations
R.Config.Cinematic.Enabled=false
for _,name in ipairs({'UpdateAIProduction','UpdateEnemyWaves','UpdateStations','UpdateAIStrategicObjectives','UpdateDefaultPolicy'}) do R[name]=function() end end
local function quit()
    restoreCapitalProbeOverrides()
    finished=true; R:SetTimeScale(1)
    ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
end
engine.addHook('On Frame',function() if finished then ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME']) end end)
local function create(name,class,pos,team)
    local s=mn.createShip(name,tb.ShipClasses[class],ba.createOrientationFromVectors(ba.createVector(0,0,1)),pos,mn.Teams[team],true)
    assert(s:isValid(),name); R:InvalidateShipList(); return s
end
local function fireAtBase(parent)
    local direction=ba.createVector(1,0,0)
    local hit=damageBase:checkRayCollision(damageBase.Position-direction*6000,damageBase.Position+direction*6000)
    assert(hit,'station ray fixture found no valid hull impact point')
    local orientation=ba.createOrientationFromVectors(direction)
    local gun=tb.WeaponClasses['Subach HL-7']
    for i=1,32 do
        local side=(i%8-3.5)*6; local row=(math.floor((i-1)/8)-1.5)*6
        local projectile=mn.createWeapon(gun,orientation,hit-direction*80+ba.createVector(0,side,row),parent)
        assert(projectile:isValid(),'native base-impact projectile creation failed')
        baseVolley[#baseVolley+1]=projectile
    end
end
local function clearBaseVolley()
    for _,projectile in ipairs(baseVolley) do if projectile:isValid() then projectile:vanish() end end
    baseVolley={}
end
local function findStationTurret(station,beamOnly)
    for i=1,#station do
        local subsystem=station[i]
        if subsystem:isTurret() and subsystem.HitpointsLeft>0 then
            local hasBeam=false
            for b=1,#subsystem.PrimaryBanks do
                local weapon=subsystem.PrimaryBanks[b].WeaponClass
                if weapon:isValid() and weapon:isBeam() then hasBeam=true; break end
            end
            if hasBeam==beamOnly then return subsystem end
        end
    end
end
local function probe(self)
    local now=mn.getMissionTime()
    if stage==0 and self.SetupActive then
        self.SetupOpponents={RED=true,GOLD=true}; self.SetupAutoMode=false; self.SetupSentries=false
        check(self:SetFactionChoice('BLUE','GTVA'),'native request fixture selects the roster with an unlocked tier-3 capital')
        self:StartScenario(); scenarioIncome=self.ActiveIncomePerSecond; self.ActiveIncomePerSecond=0; self.CommandPoints=1000000
        local damageGuards=0
        for _,registered in pairs(self.BaseDamageProtectionHooks or {}) do if registered then damageGuards=damageGuards+1 end end
        check(damageGuards==7,'upstream submodel-aware guards register for all command stations')
        for _,s in ipairs(self:GetShipList()) do
            if s.Name~=self.Config.ObserverShip and not self:IsCommandStation(s) then s:vanish()
            else
                for i=1,#s do
                    if s[i]:isTurret() then
                        if not s[i].TurretLocked then log('UNLOCKED_START_TURRET '..s.Name..' '..tostring(s[i].Name)) end
                        check(s[i].TurretLocked,'command stations start with every turret locked: '..s.Name..'/'..tostring(s[i].Name))
                        s[i].TurretLocked=true
                    end
                end
            end
        end
        self:InvalidateShipList()
        for _,kind in ipairs({'BLUE','RED','GOLD'}) do
            local station=self:GetFactionCommandShip(kind)
            for level=1,3 do
                self:ApplyStationDefenseProgression(kind,level)
                local beamCount,openBeams,gunCount,openGuns=0,0,0,0
                for i=1,#station do
                    local turret=station[i]
                    if turret:isTurret() then
                        local beam=false
                        for b=1,#turret.PrimaryBanks do beam=beam or turret.PrimaryBanks[b].WeaponClass:isBeam() end
                        if beam then beamCount=beamCount+1; if not turret.TurretLocked then openBeams=openBeams+1 end
                        else gunCount=gunCount+1; if not turret.TurretLocked then openGuns=openGuns+1 end end
                    end
                end
                check(openBeams==(level==3 and beamCount or 0),'native '..kind..' base beams unlock only with Defense III')
                check(openGuns==(level==1 and math.ceil(gunCount/2) or gunCount),'native '..kind..' base guns unlock progressively')
            end
            self:ApplyStationDefenseProgression(kind,0)
        end
        for _,name in ipairs({'BVas','AAAf','SAAA','LRed','LTerSlash'}) do
            local station=tb.WeaponClasses['RTS Station '..name]
            check(station:isValid() and self:GetWeaponFiringRange(station)==6000,'station '..name..' has 6 km native reach')
            check(tb.WeaponClasses[name].Range~=6000,'fleet '..name..' range is preserved')
        end
        for _,kind in ipairs({'BLUE','RED','GOLD'}) do
            local station=self:GetFactionCommandShip(kind)
            for i=1,#station do for b=1,#station[i].PrimaryBanks do
                local weapon=station[i].PrimaryBanks[b].WeaponClass
                if weapon:isBeam() then check(weapon.Name:sub(1,12)=='RTS Station ','station mount uses its dedicated beam') end
            end end
        end
        local repairStation=self:GetFactionCommandShip('BLUE')
        local repairTurret=findStationTurret(repairStation,false)
        check(repairTurret~=nil,'station repair fixture has a live turret subsystem')
        local repairState=self.StationState.BLUE
        local savedRepairHP=repairTurret.HitpointsLeft
        local savedUpdateStationAI=self.UpdateStationAI
        self.UpdateStationAI=function() end
        updateStations(self,0)
        local maxRepairHP=repairTurret.HitpointsMax
        repairTurret.HitpointsLeft=maxRepairHP*.5; updateStations(self,1)
        check(repairState.lastDamageAt==1,'native station update detects turret damage')
        local damagedRepairHP=repairTurret.HitpointsLeft
        updateStations(self,1+self.Config.Station.ArmorRepairDelay)
        check(math.abs(repairTurret.HitpointsLeft-damagedRepairHP)<.01,'native station update waits through turret quiet delay')
        updateStations(self,11+self.Config.Station.ArmorRepairDelay)
        local expectedRepairHP=damagedRepairHP+maxRepairHP*self.Config.Station.FleetService.SubsystemPerSecond*10
        check(math.abs(repairTurret.HitpointsLeft-expectedRepairHP)<.1,'native station update repairs turret at service rate')
        local repairedRepairHP=repairTurret.HitpointsLeft
        self.AftermathActive=true; repairTurret.HitpointsLeft=repairedRepairHP-50; updateStations(self,42+self.Config.Station.ArmorRepairDelay)
        check(math.abs(repairTurret.HitpointsLeft-(repairedRepairHP-50))<.01,'native survivor phase disables station repair')
        self.AftermathActive=false; updateStations(self,43+self.Config.Station.ArmorRepairDelay)
        check(math.abs(repairTurret.HitpointsLeft-(repairedRepairHP-50))<.01
            and repairState.lastDamageAt==43+self.Config.Station.ArmorRepairDelay,
            'native repair resumes only after a fresh post-match quiet delay')
        repairTurret.HitpointsLeft=savedRepairHP; self.UpdateStationAI=savedUpdateStationAI
        damageBase=self:GetFactionCommandShip('RED'); damageBase.Shields.CombinedLeft=0
        damageFighter=create('Base guard fighter','GTF Myrmidon',damageBase.Position+ba.createVector(7000,3000,0),self.Config.FriendlyTeam)
        damageBomber=create('Base guard bomber','GTB Artemis',damageBase.Position+ba.createVector(7000,-3000,0),self.Config.FriendlyTeam)
        damageFighter:setFlag(true,'immobile'); damageBomber:setFlag(true,'immobile')
        fighterBaseHull=damageBase.HitpointsLeft; fireAtBase(damageFighter); at=now; stage=20
    elseif stage==20 and now-at>=2 then
        check(fighterBaseHits>0,'fighter projectiles reached the real command-station collision hook')
        check(math.abs(damageBase.HitpointsLeft-fighterBaseHull)<.01,'fighter projectiles cannot reduce command-station hull')
        fighterBaseDelta=fighterBaseHull-damageBase.HitpointsLeft
        clearBaseVolley(); bomberBaseHull=damageBase.HitpointsLeft; fireAtBase(damageBomber); at=now; stage=21
    elseif stage==21 and now-at>=2 then
        check(bomberBaseHits>0,'bomber projectiles reached the real command-station collision hook')
        check(damageBase.HitpointsLeft<bomberBaseHull-.01,'bomber retains native command-station damage')
        clearBaseVolley()
        damageBomber:setFlag(true,'primaries-locked','secondaries-locked')
        log(string.format('BASE_DAMAGE fighterHits=%d fighterHullDelta=%.3f bomberHits=%d bomberHullDelta=%.3f',
            fighterBaseHits,fighterBaseDelta,bomberBaseHits,bomberBaseHull-damageBase.HitpointsLeft))
        expectedSubsystem=findStationTurret(damageBase,false)
        check(expectedSubsystem~=nil,'command station has a non-beam turret subsystem for fighter suppression fire')
        damageFighter.Target=damageBase; damageFighter.TargetSubsystem=expectedSubsystem
        at=now; stage=22
    elseif stage==22 and now-at>=2 then
        subsystemHitsBefore=fighterBaseHits; subsystemHpBefore=expectedSubsystem.HitpointsLeft; subsystemBaseHpBefore=damageBase.HitpointsLeft
        fireAtBase(damageFighter); at=now; stage=24
    elseif stage==24 and now-at>=2 then
        check(fighterBaseHits>subsystemHitsBefore,'fighter fire reaches the targeted station turret')
        check(math.abs(expectedSubsystem.HitpointsLeft-subsystemHpBefore)<.01,
            'fighter fire cannot damage the station turret subsystem')
        local hullDamage=subsystemBaseHpBefore-damageBase.HitpointsLeft
        local chipLimit=tb.WeaponClasses['RTSF Subach HL-7'].Damage*#baseVolley*.05
        check(hullDamage>0 and hullDamage<=chipLimit+.01,
            'fighter turret fire damages only within the command-hull light-weapon chip limit')
        log(string.format('TURRET_BLOCKED subsystem=%s hits=%d hpDelta=%.3f hullDelta=%.3f',expectedSubsystem.Name,
            fighterBaseHits-subsystemHitsBefore,subsystemHpBefore-expectedSubsystem.HitpointsLeft,hullDamage))
        clearBaseVolley()
        expectedSubsystem=findStationTurret(damageBase,true)
        check(expectedSubsystem~=nil,'command station has a beam-weapon turret subsystem')
        damageFighter.TargetSubsystem=expectedSubsystem
        subsystemHitsBefore=fighterBaseHits; subsystemHpBefore=expectedSubsystem.HitpointsLeft; subsystemBaseHpBefore=damageBase.HitpointsLeft
        fireAtBase(damageFighter); at=now; stage=23
    elseif stage==23 and now-at>=2 then
        check(fighterBaseHits>subsystemHitsBefore,'fighter fire reaches the targeted station beam turret')
        check(math.abs(expectedSubsystem.HitpointsLeft-subsystemHpBefore)<.01,
            'fighter fire cannot damage the station beam weapon')
        local hullDamage=subsystemBaseHpBefore-damageBase.HitpointsLeft
        local chipLimit=tb.WeaponClasses['RTSF Subach HL-7'].Damage*#baseVolley*.05
        check(hullDamage>0 and hullDamage<=chipLimit+.01,
            'fighter beam-turret fire damages only within the command-hull light-weapon chip limit')
        log(string.format('BEAM_TURRET_BLOCKED subsystem=%s hits=%d hpDelta=%.3f hullDelta=%.3f',expectedSubsystem.Name,
            fighterBaseHits-subsystemHitsBefore,subsystemHpBefore-expectedSubsystem.HitpointsLeft,hullDamage))
        clearBaseVolley()
        damageFighter:vanish(); damageBomber:vanish(); self:InvalidateShipList()
        mover=create('Command mover','GTF Myrmidon',self:GetCarrier().Position+ba.createVector(0,0,-6500),self.Config.FriendlyTeam)
        mover.HitpointsMax=1000000; mover.HitpointsLeft=1000000; mover.Shields.CombinedLeft=0
        enemy=create('Command hitter','SF Mara',mover.Position+ba.createVector(0,0,-700),self.Config.HostileTeam)
        enemy:setFlag(true,'immobile','primaries-locked','secondaries-locked'); enemy:clearOrders()
        destination=mover.Position+ba.createVector(0,0,2500); startDistance=mover.Position:getDistance(destination)
        self.Selected={mover:getSignature()}; self:IssueAttack(enemy); self:IssueMove(destination)
        check(mover:getFlag('no-dynamic'),'move suppresses upstream hit diversion')
        at=now; stage=1
    elseif stage==1 then
        if now-at<8 and now>=(self.CommandProbeHitAt or 0) then
            self.CommandProbeHitAt=now+.5
            local p=mover.Position
            local hit=mover:checkRayCollision(p+ba.createVector(0,0,-1000),p+ba.createVector(0,0,1000))
            if hit then
                mn.createWeapon(tb.WeaponClasses['Subach HL-7'],ba.createOrientationFromVectors(ba.createVector(0,0,1)),hit+ba.createVector(0,0,-80),enemy)
            end
            if now-at>3 and not self.CommandProbeRepeated then self.CommandProbeRepeated=true; self:IssueMove(destination) end
        end
        if now-at>=12 then
            log('MOVE_WEAPON_COLLISIONS '..moverWeaponHits)
            check(mover.HitpointsLeft<1000000,'move fixture receives real hostile projectile hits')
            check(mover.Position:getDistance(destination)<startDistance-500,'damaged fighter continues toward the commanded point')
            self:OnWaypointsDone(mover)
            check(self.UserOrders[mover:getSignature()].kind=='hold','plain player move remains owned on arrival')
            self:EngageSelected(); check(not mover:getFlag('no-dynamic'),'combat restores native reactions')
            mover:vanish(); enemy:vanish(); self:InvalidateShipList()
            self.Selected={}
            for i=1,4 do
                local s=create('Service visitor '..i,'GTF Myrmidon',self:GetCarrier().Position+ba.createVector(i*500,0,-5000),self.Config.FriendlyTeam)
                s.HitpointsLeft=s.HitpointsMax*.5
                for b=1,#s.SecondaryBanks do s.SecondaryBanks[b].AmmoLeft=0 end
                s:giveOrder(ORDER_ATTACK,self:GetFactionCommandShip('RED'),nil,.95)
                visitors[#visitors+1]=s; self.Selected[#self.Selected+1]=s:getSignature()
            end
            self:ServiceSelected()
            for _,s in ipairs(visitors) do
                check(s.Orders[1]:getType()==ORDER_WAYPOINTS_ONCE,'service immediately replaces combat')
                check(not s:getFlag('no-dynamic'),'service keeps native evasive AI available')
                local rec=self.FleetServices[s:getSignature()]
                s.Position=self:GetFleetServicePoint(s,self:GetCarrier(),nil,rec.padApproachX,rec.padApproachZ)
            end
            initialCP=self.CommandPoints; at=now; stage=2
        end
    elseif stage==2 then
        if now-at>=14 then
            for _,s in ipairs(visitors) do
                check(s.HitpointsLeft>s.HitpointsMax*.5,'parallel visitor receives hull repair')
                check(self:GetFleetAmmo(s)>0,'parallel visitor receives actual ammunition')
            end
            check(self.CommandPoints<initialCP,'parallel repair and rearm spend actual CP')
            local s=visitors[1]; local rec=self.FleetServices[s:getSignature()]
            local station=self:GetCarrier()
            local threat=create('Native lateral service threat','SF Mara',s.Position+ba.createVector(2000,0,0),self.Config.HostileTeam)
            threat:setFlag(true,'immobile','primaries-locked','secondaries-locked'); threat.Target=s
            self:BuildAIContext(self:BuildStrategicThreatSnapshot())
            self:ServiceFleetShip(s,rec,station,now,4,threat)
            local bearing=threat.Position-station.Position
            local length=math.sqrt(bearing.x*bearing.x+bearing.z*bearing.z)
            check((rec.padApproachX*bearing.x+rec.padApproachZ*bearing.z)/length>.99,'native service pad moves opposite a lateral attacker')
            s.Position=rec.padPoint; rec.arrived=true
            s:clearOrders(); s:giveOrder(ORDER_STAY_STILL,nil,nil,.97)
            s.Physics.Velocity=ba.createVector(50,0,0)
            local previousHit=self.AIStats.hits[s:getSignature()]
            self.AIStats.hits[s:getSignature()]={hostileTime=now}
            self:ServiceFleetShip(s,rec,station,now,4,threat)
            check(math.abs(s.Physics.Velocity.x-50)<.1,'native service under fire preserves evasive velocity')
            self.AIStats.hits[s:getSignature()]=previousHit
            threat:vanish(); self:InvalidateShipList(); self:BuildAIContext(self:BuildStrategicThreatSnapshot())
            s.Position=self:GetCarrier().Position+ba.createVector(0,0,-6500); rec.arrived=false
            s:clearOrders(); s:giveOrder(ORDER_ATTACK,self:GetFactionCommandShip('RED'),nil,.99)
            self:MoveFleetServiceShip(s,rec,rec.destination,now,self:GetCarrier():getSignature())
            check(s.Orders[1]:getType()==ORDER_WAYPOINTS_ONCE,'cached service route repairs a stolen goal')
            self.Selected={s:getSignature()}; self:IssueMove(s.Position+ba.createVector(800,0,0))
            check(not self.FleetServices[s:getSignature()],'fresh manual command cancels service')
            self:RegisterLogicalWing({visitors[2],visitors[4]},'Probe native wing')
            self.Selected={visitors[2]:getSignature(),visitors[3]:getSignature(),self:GetCarrier():getSignature()}
            self:AssignControlGroup(1)
            check(#self.ControlGroups[1]==2,'station is excluded from a mixed control group')
            check(self:StartPilotMode(visitors[2]),'comm fixture enters possession')
            self:SetButtonControlMode(LUA_ADDITIVE_BUTTON_CONTROL)
            self.ControlInfo.useButtonControl(-1,'SQUADMSG_MENU')
            commAt=now; stage=3
        end
    elseif stage==3 or stage==5 or stage==7 then
        self.ControlInfo.clearLuaButtonInfo()
        local desired=stage==3 and 'Engage enemy' or stage==5 and 'Form on my wing' or 'Depart'
        for i=1,#mn.CommItems do
            if mn.CommItems[i].Name==desired then
                check(mn.CommItems[i]:selectItem(),'native comm selects '..desired)
                stage=stage+1; at=now; break
            end
        end
        assert(now-commAt<10,'native comm menu did not expose '..desired)
    elseif stage==4 and now-at>.5 then
        check(self.UserOrders[visitors[3]:getSignature()].kind=='wing','native comm commands the other grouped wing')
        check(self.UserOrders[visitors[4]:getSignature()].kind=='service','group comm leaves the ungrouped wingmate in service')
        self.ControlGroups={}
        self.ControlInfo.useButtonControl(-1,'SQUADMSG_MENU'); commAt=now; stage=5
    elseif stage==6 and now-at>.5 then
        local ship=visitors[4]
        check(self.UserOrders[ship:getSignature()].kind=='wing' and ship.Orders[1]:getType()==ORDER_GUARD,
            'ungrouped native comm applies the wing formation command')
        check(ship:getGuardRange(visitors[2])==self.Config.AI.CohesionRadius,'wing formation has a native pursuit leash')
        self.ControlInfo.useButtonControl(-1,'SQUADMSG_MENU'); commAt=now; stage=7
    elseif stage==8 and now-at>1 then
        check(departSeen,'Depart reached the real upstream comm-issued hook')
        for _,ship in ipairs(visitors) do check(not ship:isDepartingWarp(),'Depart cannot remove a fleet member') end
        self:ExitPilotMode(nil,false)
        isolated=create('Isolated survivor','GTF Myrmidon',self:GetCarrier().Position+ba.createVector(0,0,9000),self.Config.FriendlyTeam)
        self:SetAutoPlayerMode(true)
        self.StrategicThreatSnapshot=self:BuildStrategicThreatSnapshot(); self:BuildAIContext(self.StrategicThreatSnapshot)
        local g={id='Probe isolated wing',units={isolated},role='fighter',value=self:AIProfile(isolated).value,minHull=1,spread=0}
        self:CommitAIGroup(g,self:GetFactionCommandShip('RED'),'PRIMARY',self:GetCarrier(),{locked=true},now,true)
        local state=self.AIOrderState[isolated:getSignature()]
        check(state and state.mission=='REGROUP' and state.reason=='REJOIN_FLEET','real AI commit regroups an isolated fighter')
        rally=self:FindShipBySignature(state.targetSignature); rallyDistance=isolated.Position:getDistance(rally.Position)
        check(isolated.Orders[1]:getType()==ORDER_GUARD and self:GetFactionKey(rally)=='BLUE','regroup installs a native friendly guard goal')
        at=now; stage=9
    -- The created hull starts facing away from its guard target; let native AI turn before measuring travel.
    elseif stage==9 and now-at>=20 then
        local regroupDistance=isolated.Position:getDistance(rally.Position)
        log(string.format('REGROUP_DISTANCE initial=%.1f after=%.1f elapsed=%.1f',rallyDistance,regroupDistance,now-at))
        check(regroupDistance<rallyDistance-50,'isolated fighter physically returns toward support')
        local sampled={}
        for _,kind in ipairs({'BLUE','RED','GOLD'}) do
            local station=self:GetFactionCommandShip(kind)
            for i=1,#station do
                local turret=station[i]
                local name=turret:isTurret() and #turret.PrimaryBanks>0 and turret.PrimaryBanks[1].WeaponClass.Name
                if name and turret.PrimaryBanks[1].WeaponClass:isBeam() and not sampled[name] then
                    sampled[name]=true
                    -- This probe measures native beam range independently of
                    -- the Defense III/tier-five unlock, so briefly enable only
                    -- the mount being measured.
                    local wasLocked=turret.TurretLocked
                    turret.TurretLocked=false
                    local origin,normal=turret:getNextFiringPosition()
                    local target=create('Remote beam contact '..kind..' '..i,'GTD Hecate',origin+normal*18000,
                        kind=='BLUE' and self.Config.HostileTeam or self.Config.FriendlyTeam)
                    target:setFlag(true,'immobile','invulnerable','primaries-locked','secondaries-locked')
                    for j=1,#target do if target[j]:isTurret() then target[j].TurretLocked=true end end
                    turret.Target=target; turret.BeamFree=true; turret.NextFireTimestamp=now
                    turret:fireWeapon(1)
                    turret.TurretLocked=wasLocked
                end
            end
        end
        at=now; stage=10
    elseif stage==10 then
        for _,row in ipairs(stationBeams) do
            local beam=row.beam
            -- Warmup aim endpoints can retain the remote target's coordinates;
            -- native move truncates the ray when the damaging beam is active.
            if beam:isValid() and now>row.at+beam.Class.BeamWarmup+.1 and now<row.at+beam.Class.BeamWarmup+beam.Class.BeamLife-.1 then
                local length=beam.LastStart:getDistance(beam.LastShot)
                beamLengths[beam.Class.Name]=math.max(beamLengths[beam.Class.Name] or 0,length)
                assert(length<=6010,'active station beam exceeds 6 km: '..beam.Class.Name..' '..length)
            end
        end
        if now-at>10 then
            local count=0
            for name,length in pairs(beamLengths) do if length>1000 then count=count+1; log('BEAM_LENGTH '..name..' '..length) end end
            check(count==5,'all five station beam families have real active rays')
            check(true,'active station beams stay within 6 km even with an 18 km forced target')
            log('PASS actual escalation reached tier 3; begin requested capital Auto Mode proof')
            self:SetTimeScale(16); stage=11
        end
    elseif stage==11 then
        if capitalRequest==nil then
            if self:GetCurrentEscalationTier(now)<3 then return end
            check(not self.Paused and self.TimeScale==16,'native request clock is unpaused at the unlocked tier')
            check(not self.PostBattleActive and not self.ExitMenuActive and self.BattleVictor==nil
                and self.GameStatus=='ACTIVE' and self.ScenarioStartTime~=nil,
                'requested build starts while the global match remains active')
            check(type(scenarioIncome)=='number' and scenarioIncome>0,'selected scenario has positive configured player income')
            local chosen,estimate
            for _,entry in ipairs(self:GetAIRoster('BLUE')) do
                if entry.role=='capital' and (entry.tier or 1)<=self:GetCurrentEscalationTier(now) then
                    local price=self:GetPurchaseEstimate(entry.class,entry.tier or 1,1)
                    if price and (estimate==nil or price.cost<estimate.cost) then chosen,estimate=entry,price end
                end
            end
            check(chosen~=nil and estimate~=nil,'native Blue roster exposes an unlocked capital at tier 3')
            capitalClass=chosen.class; capitalCost=estimate.cost
            if not self.AutoPlayerMode then self:SetAutoPlayerMode(true) end
            local state=self.AIStates and self.AIStates.BLUE
            check(self.AutoPlayerMode and state and state.playerEconomy==true,'request uses the live Blue Auto Mode state')
            self.CommandPoints=0; state.cp=0; self.ActiveIncomePerSecond=scenarioIncome; self.LastIncomeTime=now
            state.nextThink=now
            capitalBeforeSignatures={}
            for _,ship in ipairs(self:GetShipList()) do
                if self:IsMovableFriendly(ship) then
                    capitalBeforeSignatures[ship:getSignature()]=true
                end
            end
            capitalCapOverride=self:CountFactionCombatants('BLUE')
            self.GetFleetCap=function(owner,kind)
                if kind=='BLUE' and capitalCapOverride~=nil then return capitalCapOverride end
                return originalGetFleetCap(owner,kind)
            end
            local accepted,request=self:RequestAutoBuild(capitalClass)
            check(accepted and request and request.status=='SAVING','native request accepts the unlocked capital')
            check(request.cost==capitalCost and state.productionReserve==capitalCost
                and state.savingRole=='player-request:'..request.id,'request reserves the full measured capital price')
            capitalRequest=request; capitalStartedAt=now; capitalCapWaited=false; capitalSavingSeen=false; capitalQueueSeen=false
            capitalRequestUIStartedAt=self:UINow(); capitalProgressLogged=false
            log(string.format('CAPITAL_REQUEST class=%s tier=%d cost=%.0f income=%.2f capFixture=%d',capitalClass,
                chosen.tier or 1,capitalCost,scenarioIncome,capitalCapOverride))
        end

        local state=self.AIStates.BLUE
        local cpBefore=self.CommandPoints
        updateAIProduction(self,now)
        if not capitalCapWaited and capitalRequest.status=='WAITING_FOR_CAP' then
            check(state.queue==nil and self.CommandPoints==cpBefore,'full-cap request waits without spending player CP')
            capitalCapWaited=true; capitalCapOverride=nil
            check(self:GetFleetCap('BLUE')>self:CountFactionCombatants('BLUE'),
                'cap fixture releases to the live Blue fleet limit')
            log('CAPITAL_REQUEST_CAP_WAIT released to the configured fleet cap')
        end
        if capitalCapWaited and not capitalProgressLogged
            and self:UINow()-(capitalRequestUIStartedAt or self:UINow())>=2 then
            log(string.format('CAPITAL_REQUEST_PROGRESS ui=%.1f mission=%.1f now=%.2f start=%.2f paused=%s exit=%s post=%s victor=%s game=%s scale=%.1f status=%s cp=%.2f nextThink=%.2f cap=%d units=%d',
                self:UINow()-capitalRequestUIStartedAt,now-capitalStartedAt,now,self.ScenarioStartTime or -1,
                tostring(self.Paused),tostring(self.ExitMenuActive),
                tostring(self.PostBattleActive),tostring(self.BattleVictor),tostring(self.GameStatus),self.TimeScale,
                tostring(capitalRequest.status),self.CommandPoints,state.nextThink or -1,
                self:GetFleetCap('BLUE'),self:CountFactionCombatants('BLUE')))
            capitalProgressLogged=true
            check(not self.PostBattleActive and not self.ExitMenuActive and self.GameStatus=='ACTIVE'
                and self.BattleVictor==nil,'requested build remains in an active match after cap release')
        end
        if state.queue and state.queue.autoBuildRequestId==capitalRequest.id and not capitalQueueSeen then
            check(state.queue.entry.class==capitalClass and state.queue.count==1 and capitalRequest.status=='BUILDING',
                'requested capital enters exactly one native production queue')
            check(math.abs((cpBefore-self.CommandPoints)-capitalCost)<.01,'native queue deducts exactly the reserved capital cost')
            capitalQueueSeen=true
            log(string.format('CAPITAL_REQUEST_QUEUED class=%s cpBefore=%.2f cpAfter=%.2f cost=%.2f',
                capitalClass,cpBefore,self.CommandPoints,capitalCost))
        elseif state.queue and capitalRequest.status~='COMPLETE' and state.queue.autoBuildRequestId~=capitalRequest.id then
            check(capitalRequest.status~='BUILDING','an ordinary Auto Mode queue replaced the requested capital')
        end
        if capitalCapWaited and capitalRequest.status=='SAVING' and not capitalSavingSeen then
            check(state.queue==nil and self.CommandPoints>0 and self.CommandPoints<capitalCost,
                'request accumulates actual configured income below capital affordability')
            check(state.productionReserve==capitalCost and state.savingRole=='player-request:'..capitalRequest.id,
                'station investment path retains the request reserve while saving')
            capitalSavingSeen=true
            log(string.format('CAPITAL_REQUEST_SAVING cp=%.2f required=%.2f income=%.2f',
                self.CommandPoints,capitalCost,scenarioIncome))
        end
        if capitalRequest.status=='COMPLETE' and self.AIStates.BLUE.LastAutoBuildRequest==capitalRequest then
            check(capitalCapWaited and capitalSavingSeen and capitalQueueSeen,'capital request passed cap wait, savings and queue stages')
            check(self.AutoPlayerMode and not self.AIStates.BLUE.AutoBuildRequest,'Auto Mode remains enabled and retires the completed request')
            self:InvalidateShipList()
            local created={}
            for _,ship in ipairs(self:GetShipList()) do
                if not capitalBeforeSignatures[ship:getSignature()] and ship.Class.Name==capitalClass
                    and self:IsMovableFriendly(ship) then created[#created+1]=ship end
            end
            check(#created==1,'native request completes with exactly one new capital hull')
            local built=created[1]; capitalBuiltSignature=built:getSignature()
            check(self:IsSelectableShip(built),'completed requested capital is selectable')
            local popup=self.NewUnitPopup
            check(popup and #popup.signatures==1 and popup.signatures[1]==capitalBuiltSignature,
                'completed capital appears in the native new-unit selection popup')
            self:DrawNewUnitPopup(gr.getScreenWidth(),gr.getScreenHeight())
            local button=self.NewUnitPopupSelectRect
            check(button and self:HandleUILeftClick((button.x1+button.x2)/2,(button.y1+button.y2)/2),
                'native popup click selects the requested capital')
            local selected=self:GetSelectedShips()
            check(#selected==1 and selected[1]:getSignature()==capitalBuiltSignature,
                'selected hull resolves to the completed native capital')
            capitalVerifyAt=now+24; stage=12
            log(string.format('CAPITAL_REQUEST_COMPLETE class=%s signature=%d',capitalClass,capitalBuiltSignature))
        elseif now-capitalStartedAt>2700 or self:UINow()-(capitalRequestUIStartedAt or self:UINow())>90 then
            check(false,string.format('requested capital timed out: state=%s cp=%.2f cost=%.2f income=%.2f',
                tostring(capitalRequest.status),self.CommandPoints,capitalCost,scenarioIncome))
        elseif self.AutoPlayerMode and state.AutoBuildRequest==capitalRequest then
            local station=self:GetFactionCommandShip('BLUE')
            if station and station:isValid() then updateStationAI(self,'BLUE',self:GetStationState('BLUE'),station,now) end
        end
    elseif stage==12 then
        updateAIProduction(self,now)
        if now>=capitalVerifyAt then
            self:InvalidateShipList()
            local built=0
            for _,ship in ipairs(self:GetShipList()) do
                if not capitalBeforeSignatures[ship:getSignature()] and ship.Class.Name==capitalClass
                    and self:IsMovableFriendly(ship) then built=built+1 end
            end
            check(built==1,'repeated native production updates do not duplicate the completed capital request')
            check(self.AIStates.BLUE.LastAutoBuildRequest==capitalRequest and not self.AIStates.BLUE.AutoBuildRequest
                and self.AutoPlayerMode,'completed request stays retired with Auto Mode on')
            check(self:IsSelectableShip(self:FindShipBySignature(capitalBuiltSignature)),
                'selected requested capital remains available after repeated production updates')
            log('COMPLETE upstream command ownership, parallel refit, native wing/group comm, AI regroup, bounded station beams and requested-capital Auto Mode')
            quit()
        end
    end
end
R.OnFrame=function(self)
    if finished then return end
    local ok,err=pcall(function() original(self); probe(self) end)
    if not ok then log('FAIL '..tostring(err)); quit() end
end
