-- Native station hull/repair-ceiling control; all weapons quiet.
local R=require 'fs2rts'; local U=require 'fs2rts_ai_util'
local start=R.OnGameplayStart
local file=cf.openFile('scar-headless.jsonl','w','data'); assert(file and file:isValid())
local function log(event,data) file:write(U.json({event=event,data=data})..'\n'); file:flush() end
local began,home,damage,ceiling,finished,upgraded
local lastSample=-1
local function init(self)
    start(self); self:EndIntroCinematic(true); self.SetupOpponents={RED=true,GOLD=true}; self:StartScenario()
    self.Config.AI.Enabled=false; self.AutoPlayerMode=false; self.UpdateStationAI=function() end
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do
        local base=self:GetFactionCommandShip(kind); base:setFlag(true,'immobile','primaries-locked','secondaries-locked')
        for i=1,#base do if base[i]:isTurret() then base[i].TurretLocked=true end end
    end
    home=self:GetFactionCommandShip('BLUE'); self:GetStationState('BLUE').levels.armor=2
    began=mn.getMissionTime(); self:UpdateStations(began)
    damage=home.HitpointsMax*.20; home.HitpointsLeft=home.HitpointsLeft-damage
    ceiling=home.HitpointsMax-damage*.40
    log('SETUP',{damage=damage,maxHull=home.HitpointsMax,expectedCeiling=ceiling})
end
local function step(self)
    local now=mn.getMissionTime(); local elapsed=now-began
    self:UpdateStations(now)
    assert(home.HitpointsLeft<=ceiling+.1,'native repair crossed permanent damage ceiling')
    if elapsed<30 then assert(home.HitpointsLeft<=home.HitpointsMax-damage+.1,'native repair started before quiet deadline') end
    if elapsed-lastSample>=30 then
        lastSample=elapsed; log('STATE',{elapsed=elapsed,hull=home.HitpointsLeft,scar=self:GetStationState('BLUE').scarHull})
    end
    if elapsed>=290 and not upgraded then
        assert(math.abs(home.HitpointsLeft-ceiling)<.1,'native quiet repair did not reach its capped ceiling')
        local oldMax=home.HitpointsMax; local oldScar=self:GetStationState('BLUE').scarHull
        self:ApplyUpgrade('BLUE','armor',3); ceiling=ceiling*home.HitpointsMax/oldMax
        assert(math.abs(self:GetStationState('BLUE').scarHull-oldScar*home.HitpointsMax/oldMax)<.1,'native armor upgrade erased scars')
        upgraded=true
    end
    if elapsed>=310 then
        assert(upgraded and math.abs(home.HitpointsLeft-ceiling)<.1)
        log('PASS',{elapsed=elapsed,hull=home.HitpointsLeft,maxHull=home.HitpointsMax,
            scar=self:GetStationState('BLUE').scarHull,repairCeiling=ceiling})
        finished=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
    end
end
local function guard(fn,self)
    if finished then return end
    local ok,err=xpcall(function() fn(self) end,debug.traceback)
    if not ok then log('FAIL',{error=err}); finished=true; ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME']) end
end
R.OnGameplayStart=function(self) guard(init,self) end
R.OnFrame=function(self) guard(step,self) end
R.DrawHUD=function() end
