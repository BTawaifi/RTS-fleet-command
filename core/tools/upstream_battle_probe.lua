-- Native battle smoke coverage; variable-frame 16x is not a matched headless trial.
local R=require 'fs2rts'
local out=cf.openFile('upstream-battle-probe.log','w','data')
assert(out and out:isValid())
local function log(s) out:write(s..'\n'); out:flush() end
local original=R.OnFrame
local started,finished,lastSample
local function run()
    local now=mn.getMissionTime()
    if not started then
        if R.CinematicActive then R:EndIntroCinematic(true) end
        if not R.RosterModelWarmup or not R.RosterModelWarmup.done then return end
        R.SetupFactionCountChoice=2
        R:SetFactionChoice('BLUE','SHIVAN'); R:SetFactionChoice('RED','GTA')
        R.SetupAutoMode=true; R.SetupSentries=false; R.SetupAsteroids=false
        math.randomseed(2026101002) -- Planner seed only; upstream native RNG is separate.
        R:StartScenario(); assert(not R.SetupActive,'native battle failed to start')
        R.AIStates.RED.cp=R.CommandPoints
        R.AIStates.RED.income=R.ActiveIncomePerSecond
        started=now; lastSample=-60; R:SetTimeScale(16)
        log('START SHIVAN/GTA equal initial CP/base income; variable-frame 16x')
    end
    if now-started>=lastSample+60 then
        lastSample=now-started
        local home,enemy=R:GetFactionCommandShip('BLUE'),R:GetFactionCommandShip('RED')
        log(string.format('SAMPLE time=%.1f ships=%d homeHull=%.1f enemyHull=%.1f',
            now-started,#R:GetShipList(),home and home:isValid() and home.HitpointsLeft or 0,
            enemy and enemy:isValid() and enemy.HitpointsLeft or 0))
    end
    if R.BattleVictor~=nil or now-started>=(R.ReviewBattleSeconds or 2700) then
        local commissions={}
        for _,record in pairs(R.UnitHistory or {}) do
            if record.faction=='BLUE' then commissions[record.class]=(commissions[record.class] or 0)+1 end
        end
        local classes={}; for class,count in pairs(commissions) do classes[#classes+1]=class..':'..count end
        table.sort(classes)
        log('COMMISSIONS '..table.concat(classes,','))
        log('COMPLETE upstream battle smoke time='..(now-started)..' victor='..tostring(R.BattleVictor))
        finished=true; R:SetTimeScale(1); ba.postGameEvent(ba.GameEvents.GS_EVENT_QUIT_GAME)
    end
end
R.OnFrame=function(self)
    if finished then ba.postGameEvent(ba.GameEvents.GS_EVENT_QUIT_GAME); return end
    local ok,err=pcall(function() original(self); run() end)
    if not ok then log('FAIL '..tostring(err)); finished=true; self:SetTimeScale(1); ba.postGameEvent(ba.GameEvents.GS_EVENT_QUIT_GAME) end
end
