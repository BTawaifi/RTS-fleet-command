-- Isolate stock siege engagement against identical, separated, undefended stations.
local R=require 'fs2rts'
local out=cf.openFile('siege-probe.log','w','data')
assert(out and out:isValid())
local function log(s) out:write(s..'\n'); out:flush() end
local started,finished
local rows,bySignature={},{}
local byTarget={}
local sample
local frame=R.OnFrame
R.Config.Cinematic.Enabled=false
for _,name in ipairs({'UpdateAIProduction','UpdateEnemyWaves','UpdateAIStrategicObjectives','UpdateDefaultPolicy','UpdateStations','UpdateFleetServices','EvaluateFactionVictory','AuditWorldPositions'}) do R[name]=function() end end
engine.addHook('On Weapon Created',function()
    local weapon=hv.Weapon
    if weapon and weapon:isValid() and weapon.Parent:isValid() then
        local row=bySignature[weapon.Parent:getSignature()]
        if row then local name=weapon.Class.Name; row.shots[name]=(row.shots[name] or 0)+1 end
    end
end)
engine.addHook('On Beam Fire',function()
    local beam=hv.Beam
    if beam and beam:isValid() and beam.ParentShip:isValid() then
        local row=bySignature[beam.ParentShip:getSignature()]
        if row then local name=beam.Class.Name; row.shots[name]=(row.shots[name] or 0)+1 end
    end
end)
engine.addHook('On Weapon Collision',function()
    local current=sample; sample=nil
    if current and hv.Ship==current.row.target and hv.Weapon==current.weapon then
        current.row.directDamage=current.row.directDamage+math.max(0,current.hull-current.row.target.HitpointsLeft)
        current.row.hits=current.row.hits+1
    end
end,{},function()
    sample=nil
    local weapon=hv.Weapon
    if weapon and weapon:isValid() and weapon.Parent:isValid() and hv.Ship and hv.Ship:isValid() then
        local row=bySignature[weapon.Parent:getSignature()]
        if row and byTarget[hv.Ship:getSignature()]==row then sample={row=row,weapon=weapon,hull=row.target.HitpointsLeft} end
    end
    return false
end)
local function run()
    if not started then
        if not R.SetupActive or not R.RosterModelWarmup or not R.RosterModelWarmup.done then return end
        R.SetupFactionCountChoice=2; R.SetupAutoMode=false; R.SetupSentries=false
        R:SetFactionChoice('BLUE','GTA'); R:SetFactionChoice('RED','SHIVAN'); R:StartScenario()
        for _,ship in ipairs(R:GetShipList()) do
            R:SetShipTurretLock(ship,true); ship:setFlag(true,'primaries-locked','secondaries-locked')
            ship:clearOrders(); ship:giveOrder(ORDER_STAY_STILL,nil,nil,.99)
        end
        local classes={'GTB Medusa','GVB Sekhmet','SB Shaitan','SB Nahema','SB Nephilim','SB Seraphim',
            'GTD Orion','GVD Typhon','SCv Moloch','SD Ravana'}
        for band,range in ipairs({3000,8000}) do
            for index,class in ipairs(classes) do
                local target=mn.createShip('Siege base '..band..'-'..index,tb.ShipClasses['GVI Cairo'],nil,
                    ba.createVector(index*30000,band*30000,0),mn.Teams.friendly,true)
                assert(target and target:isValid(),'siege target creation failed')
                target.HitpointsMax=5000000; target.HitpointsLeft=5000000
                target:setFlag(true,'primaries-locked','secondaries-locked')
                R:SetShipTurretLock(target,true)
                target:giveOrder(ORDER_STAY_STILL,nil,nil,.99)
                local point=target.Position+ba.createVector(0,500,range)
                local ship=mn.createShip('Siege '..band..'-'..index,tb.ShipClasses[class],nil,point,mn.Teams.hostile,true)
                assert(ship and ship:isValid(),'siege actor creation failed')
                local role=R:GetShipRole(ship)
                assert(role=='bomber' or role=='capital' or role=='heavy','unexpected siege role: '..tostring(role))
                ship:setFlag(true,'invulnerable','no-dynamic'); ship.Orientation=(target.Position-point):getOrientation()
                R:EnableFullArsenal(ship); ship.Target=target
                assert(ship:giveOrder(ORDER_ATTACK,target,nil,.99)==true,'native siege order refused')
                local count=role=='bomber' and 4 or 1
                local tier=role=='heavy' and 4 or (role=='capital' and 3 or (class=='SB Shaitan' and 1 or 2))
                local estimate=R:GetPurchaseEstimate(class,tier,count)
                assert(estimate and estimate.cost>0,'missing actual wing price')
                local banks={}
                for i=1,#ship.SecondaryBanks do
                    local bank=ship.SecondaryBanks[i]
                    banks[#banks+1]=bank.WeaponClass.Name..':'..bank.AmmoLeft
                end
                log('LOADOUT class='..class..' quantity='..count..' purchaseCP='..estimate.cost..' banks='..table.concat(banks,','))
                local row={ship=ship,target=target,cost=estimate.cost/count,class=class,range=range,shots={},hits=0,directDamage=0}
                rows[#rows+1]=row; bySignature[ship:getSignature()]=row
                byTarget[target:getSignature()]=row
            end
        end
        started=mn.getMissionTime(); R:SetTimeScale(4)
    elseif mn.getMissionTime()-started>=120 then
        for _,row in ipairs(rows) do
            local weapons={}; for name,count in pairs(row.shots) do weapons[#weapons+1]=name..':'..count end; table.sort(weapons)
            local hullRemoved=5000000-row.target.HitpointsLeft
            log(string.format('SIEGE class=%s startRange=%d finalRange=%.1f hits=%d directHull=%.1f hullRemoved=%.1f hullPerCP=%.3f shots=%s',
                row.class,row.range,row.ship.Position:getDistance(row.target.Position),row.hits,row.directDamage,hullRemoved,hullRemoved/row.cost,table.concat(weapons,',')))
            if row.class=='SB Nahema' or row.class=='SB Nephilim' or row.class=='SB Seraphim' then
                assert((row.shots.Trebuchet or 0)>0,'native selection did not fire loaded Trebuchet: '..row.class)
            end
        end
        assert(rows[1].directDamage>0,'near Medusa positive control did not damage station')
        log('COMPLETE stock siege control; no faction-balance verdict')
        finished=true; R:SetTimeScale(1); ba.postGameEvent(ba.GameEvents.GS_EVENT_QUIT_GAME)
    end
end
R.OnFrame=function(self)
    frame(self)
    if finished then ba.postGameEvent(ba.GameEvents.GS_EVENT_QUIT_GAME); return end
    local ok,message=pcall(run)
    if not ok then log('FAIL '..tostring(message)); finished=true; self:SetTimeScale(1); ba.postGameEvent(ba.GameEvents.GS_EVENT_QUIT_GAME) end
end
