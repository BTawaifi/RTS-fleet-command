-- Opt-in upstream profiler. Never loaded by ordinary gameplay.
local R=require 'fs2rts'
local out=cf.openFile('performance-probe.log','w','data')
assert(out and out:isValid())
local names={
    'OnFrame','DrawHUD','DrawWorldOverlays','DrawTacticalMap','DrawTopBar',
    'DrawSelectedUnitStats','DrawSelectionPanel','DrawBuildPanel','DrawStationPanel',
    'DrawQuickGroupsPanel','DrawOptionsPanel','DrawPolicyPanel','DrawControls',
    'DrawCurrentHoverReadout','UpdatePilotMode','ApplyPilotTurretGroup','UpdatePilotTurretFire',
    'UpdatePilotDirectives','MirrorPilotTelemetryToObserver','DisarmObserverWeapons',
    'DisarmObserverTurrets','UpdateStations','UpdateStationPointDefense','UpdateFleetServices',
    'BuildStrategicThreatSnapshot','BuildAIContext','ObserveAIExecution','UpdateFactionStrategicPlan',
    'UpdateAIStrategicObjectives','SummarizeAI','UpdateAIProduction','UpdateEnemyWaves',
    'UpdateDefaultPolicy','UpdateAttackFormations','UpdateAIPursuitGoals','AuditWorldPositions',
    'UpdateBuildQueue','ObserveStationBeamHits','UpdateSentryAim','UpdateSentryConstruction',
    'GetSpawnFrame','FlushAITrace','EmitAIEvent','GetPilotWeaponInventory','DrawPilotHUD',
    'GetFleetLocalThreat','AILocalStrength','ScoreAIObjective','GetFactionThreats',
    'UpdateFleetLife','UpdatePassageInterception','UpdateDefeatedFleetExtraction',
    'AIContextEnemies','GetAISpatialCandidates','AIProfile','AIRoleMatch',
    'IsAutomaticTargetPermitted','IsAutomaticTargetInArena','AreEnemies',
    'GetStrategicWeapons','GetCombatValue','IsCapitalTarget'
}
local phase,at,measuring,finished=0,0,false,false
local stats,frames={},{}
local phases={'quiet','crowded','pilot','paused','traced','normal_speed','churn'}
local duration=R.ReviewProbeUISeconds or 15
local capital,contacts={},{}
local churnWaves,wingsBefore=0,0
local function count(t) local n=0; for _ in pairs(t or {}) do n=n+1 end; return n end
local function log(s) out:write(s..'\n'); out:flush() end
local function finish()
    finished=true; measuring=false
    R:SetTimeScale(1)
    ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME'])
end
local function wrap(name,fn)
    return function(self,...)
        if not measuring then return fn(self,...) end
        local start=time.getCurrentTime()
        local a,b,c,d,e=fn(self,...)
        local elapsed=(time.getCurrentTime()-start):getSeconds()*1000
        local row=stats[name]
        if not row then row={calls=0,ms=0,max=0}; stats[name]=row end
        row.calls=row.calls+1; row.ms=row.ms+elapsed; row.max=math.max(row.max,elapsed)
        if name=='OnFrame' or name=='DrawHUD' then
            local samples=frames[name] or {}; frames[name]=samples; samples[#samples+1]=elapsed
        end
        return a,b,c,d,e
    end
end
for _,name in ipairs(names) do
    if R[name] and (not R.ReviewProbeCoarseProfile or name=='OnFrame' or name=='DrawHUD') then R[name]=wrap(name,R[name]) end
end
log('PROFILE mode='..(R.ReviewProbeCoarseProfile and 'frame-only' or 'detailed'))
R.Config.Cinematic.Enabled=false
R.Config.AI.ExperimentalDamageTelemetry=false
local function board()
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do
        local base=R:GetFactionCommandShip(kind)
        base:setFlag(true,'invulnerable')
        local team=base.Team
        local wing={}
        for i=1,60 do
            local p=ba.createVector(((i%10)-5)*600,((i%3)-1)*80,((math.floor(i/10)-3)*650))
                +ba.createVector(kind=='BLUE' and -5000 or kind=='RED' and 5000 or 0,0,kind=='GOLD' and 5000 or 0)
            local ship=mn.createShip('Perf '..kind..' '..i,tb.ShipClasses[kind=='RED' and 'SF Mara' or 'GTF Myrmidon'],
                ba.createOrientationFromVectors(ba.createVector(0,0,1)),p,team,true)
            assert(ship:isValid()); ship:setFlag(true,'invulnerable')
            contacts[#contacts+1]=ship
            wing[#wing+1]=ship
            if #wing==4 then R:RegisterLogicalWing(wing,'Perf '..kind..' '..i); wing={} end
        end
        for i,class in ipairs({'GTD Hecate','GTVA Colossus','SJ Sathanas'}) do
            local ship=mn.createShip('Perf capital '..kind..' '..i,tb.ShipClasses[class],
                ba.createOrientationFromVectors(ba.createVector(0,0,1)),
                ba.createVector((i-2)*6500,0,kind=='BLUE' and -9000 or kind=='RED' and 9000 or 0),team,true)
            assert(ship:isValid()); ship:setFlag(true,'invulnerable'); R:EnableFullArsenal(ship)
            if kind=='BLUE' then capital[#capital+1]=ship end
        end
    end
    R:InvalidateShipList()
    -- Keep this workload's population fixed. Production choice still runs,
    -- but economy/queued jobs cannot make A/B fleet sizes drift.
    R.CommandPoints=0; R.ActiveIncomePerSecond=0; R.BuildQueue={}
    for _,state in pairs(R.AIStates) do state.cp=0; state.income=0; state.queue=nil end
    R.Selected={contacts[1]:getSignature(),contacts[2]:getSignature(),contacts[3]:getSignature(),contacts[4]:getSignature()}
    R.LastAIStrategicUpdate=-100
end
local function begin(nextPhase)
    measuring=false; stats={}; frames={}; phase=nextPhase; at=time.getCurrentTime()
    if phase==2 then board(); R:SetTimeScale(4)
    elseif phase==3 then
        assert(R:StartPilotMode(capital[2])); R:GetObserver().Target=contacts[61]
    elseif phase==4 then R:ExitPilotMode(nil,false); R:SetPaused(true)
    elseif phase==5 then
        R:SetPaused(false); R.Config.AI.TraceFileEnabled=true; R.Config.AI.DetailedUnitTelemetry=true
        R.Config.AI.DetailedDecisionTelemetry=true; R:StartAITrace()
    elseif phase==6 then
        R:CloseAITrace(); R.Config.AI.TraceFileEnabled=false
        R.Config.AI.DetailedUnitTelemetry=false; R.Config.AI.DetailedDecisionTelemetry=false
        R:SetTimeScale(1)
    elseif phase==7 then wingsBefore=count(R.RTSWings); R:SetTimeScale(4)
    end
    -- Startup/spawn/model costs are recorded separately from steady frames.
    log('BEGIN phase='..phases[phase]..' ships='..#R:GetShipList()..' memoryKB='..collectgarbage('count'))
end
local function report()
    if phase==7 then log('CHURN waves='..churnWaves..' wingsBefore='..wingsBefore..' wingsAfter='..count(R.RTSWings)..' contestGroups='..count(R.AIContestProgress)) end
    for _,name in ipairs(names) do
        local row=stats[name]
        if row then log(string.format('PROFILE phase=%s method=%s calls=%d totalMS=%.4f maxMS=%.4f',phases[phase],name,row.calls,row.ms,row.max)) end
    end
    for name,samples in pairs(frames) do
        table.sort(samples)
        local n=#samples
        local median=(samples[math.floor((n+1)/2)]+samples[math.ceil((n+1)/2)])/2
        log(string.format('FRAME phase=%s method=%s n=%d medianMS=%.4f p95MS=%.4f p99MS=%.4f',phases[phase],name,#samples,
            median,samples[math.max(1,math.ceil(n*.95))],samples[math.max(1,math.ceil(n*.99))]))
    end
    log('END phase='..phases[phase]..' memoryKB='..collectgarbage('count'))
end
local original=R.OnFrame
R.OnFrame=function(self)
    if finished then return end
    local ok,err=pcall(function()
        original(self)
        if phase==0 and self.Enabled and self.SetupActive then
            self.SetupOpponents={RED=true,GOLD=true}; self.SetupAutoMode=true; self.SetupSentries=false
            self:StartScenario()
            local music,backdrop=self.EnvironmentMusicIndex,self.EnvironmentBackdropIndex
            self.EnvironmentPicker=true; self.EnvironmentMusicIndex=nil
            self.EnvironmentBackdropIndex=#self.Config.Environment.NebulaBackdrops
            self:DrawFleetLifeOverlay(gr.getScreenWidth(),gr.getScreenHeight())
            self.EnvironmentPicker=false; self.EnvironmentMusicIndex=music; self.EnvironmentBackdropIndex=backdrop
            log('PASS native scene picker with no music selection and last nebula')
            begin(1)
        elseif phase>0 then
            local elapsed=(time.getCurrentTime()-at):getSeconds()
            if phase==7 and churnWaves<10 then
                churnWaves=churnWaves+1; local wing={}
                for i=1,4 do
                    local ship=mn.createShip('Churn '..churnWaves..' '..i,tb.ShipClasses['GTF Myrmidon'],
                        ba.createOrientationFromVectors(ba.createVector(0,0,1)),
                        ba.createVector(-18000,0,-12000),mn.Teams[R.Config.FriendlyTeam],true)
                    assert(ship:isValid()); wing[#wing+1]=ship
                end
                R:RegisterLogicalWing(wing,'Churn '..churnWaves)
                for _,ship in ipairs(wing) do ship:kill() end
                R:InvalidateShipList()
            end
            measuring=elapsed>=2
            if elapsed>=(phase==1 and 6 or duration+2) and (phase~=7 or churnWaves>=10) then
                measuring=false; report()
                if phase==#phases then log('COMPLETE all performance phases sampled'); finish() else begin(phase+1) end
            end
        end
    end)
    if not ok then log('FAIL '..tostring(err)); finish() end
end
engine.addHook('On Frame',function() if finished then ba.postGameEvent(ba.GameEvents['GS_EVENT_QUIT_GAME']) end end)
return true
