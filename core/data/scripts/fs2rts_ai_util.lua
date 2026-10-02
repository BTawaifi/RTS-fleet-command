-- Pure helpers for the coordinated AI modules.

local function valid(s) return s~=nil and s:isValid() end
local function sig(s) return valid(s) and s:getSignature() or -1 end
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function distance(a,b) return a.Position:getDistance(b.Position) end
local function health(s) return clamp(s.HitpointsLeft/math.max(1,s.HitpointsMax),0,1) end
local function doctrine(self) return self.Config.AI.Doctrine or {} end
local function mobileRole(role) return role=='fighter' or role=='bomber' end
local function heavyRole(role) return role=='capital' or role=='heavy' or role=='juggernaut' end
local function balanceDefinition(self)
    local setup=self.Config.Setup or {}
    local economy=setup.Economies and setup.Economies[self.SetupEconomyIndex] or {}
    local difficulty=setup.Difficulties and setup.Difficulties[self.SetupDifficultyIndex] or {}
    local duration=setup.Durations and setup.Durations[self.SetupDurationIndex] or {}
    local baseDistance=setup.BaseDistances and setup.BaseDistances[self.SetupBaseDistanceIndex] or {}
    local ai=self.Config.AI or {}
    local playerCatalog={}
    for _,option in ipairs(self.BuildCatalog or {}) do
        playerCatalog[#playerCatalog+1]={class=option.class,label=option.label,key=option.key,
            role=option.role,tier=option.tier,count=option.count,cost=option.cost,buildSeconds=option.time}
    end
    local rosters={}
    for _,kind in ipairs({'BLUE','RED','GOLD'}) do
        local entries={}
        for _,entry in ipairs(self:GetAIRoster(kind) or {}) do
            local role=entry.role or 'fighter'
            local count=(role=='fighter' or role=='bomber') and (self.Config.Economy.StrikeWingSize or 4) or 1
            local one=self:GetPurchaseEstimate(entry.class,entry.tier or 1,1)
            local purchase=self:GetPurchaseEstimate(entry.class,entry.tier or 1,count)
            if purchase then
                entries[#entries+1]={class=entry.class,role=role,tier=entry.tier or 1,weight=entry.weight or 1,
                    count=count,unitCost=one and one.cost or nil,purchaseCost=purchase.cost,
                    unitBuildSeconds=one and one.time or nil,purchaseBuildSeconds=purchase.time}
            else
                entries[#entries+1]={class=entry.class,role=role,tier=entry.tier or 1,weight=entry.weight or 1,
                    count=count,available=false}
            end
        end
        rosters[kind]=entries
    end
    local difficultyIncome=difficulty.aiIncome or 1
    local durationAIIncome=duration.aiIncomeScale or 1
    local durationPlayerIncome=duration.playerIncomeScale or 1
    return {
        setup={difficulty=difficulty.name,economy=economy.name,duration=duration.name,
            baseDistance=baseDistance.name,baseDistanceUnits=baseDistance.distance,
            factionCount=self.SetupFactionCount,autoPlayer=self.AutoPlayerMode==true},
        economy={playerStartingCP=economy.startCP,playerBaseIncomePerSecond=economy.income*durationPlayerIncome,
            playerFleetCap=self.Config.Economy.FleetCap,aiStartingCP=economy.startCP*(ai.StartingCPScale or .92),
            aiBaseIncomePerSecond=economy.income*durationAIIncome*difficultyIncome*(ai.IncomeScale or .95),
            aiFleetCap=ai.FleetCap or 64,difficultyIncomeScale=difficultyIncome,
            durationPlayerIncomeScale=durationPlayerIncome,durationAIIncomeScale=durationAIIncome,
            aiBuildSpeed=difficulty.aiBuildSpeed or 1,buildTimeScale=duration.buildTimeScale or 1,
            bounties=self.Config.Bounties},
        awareness={source='all living ships in StrategicThreatSnapshot',sensorLimited=false,
            playerFogAffectsAI=false,stationThreatRadius=doctrine(self).ThreatRadius or ai.StationDefenseRadius,
            localEngageRadius=ai.LocalEngageRadius},
        costFormula=self.Config.CostFormula,playerCatalog=playerCatalog,aiRosters=rosters,
    }
end
local function json(v)
    if type(v)=='number' then return v==v and math.abs(v)<math.huge and string.format('%.4f',v) or 'null' end
    if type(v)=='boolean' then return tostring(v) end
    if type(v)=='string' then return '"'..v:gsub('[%z\1-\31\\"]',function(c) return string.format('\\u%04x',string.byte(c)) end)..'"' end
    if type(v)~='table' then return 'null' end
    local parts={}
    if #v>0 then for _,x in ipairs(v) do parts[#parts+1]=json(x) end; return '['..table.concat(parts,',')..']' end
    local keys={}; for k in pairs(v) do keys[#keys+1]=k end
    table.sort(keys,function(a,b) return tostring(a)<tostring(b) end)
    for _,k in ipairs(keys) do parts[#parts+1]=json(tostring(k))..':'..json(v[k]) end
    return '{'..table.concat(parts,',')..'}'
end

local function newBaseDamageFaction()
    return {hitCount=0,shieldDamage=0,hullDamage=0,weapons={}}
end

local function baseDamageBucketKey(targetName,weaponClass,weaponSubtype,sourceKind,damageType,ballistic,beamWeapon,attackerFaction)
    local fields={targetName,weaponClass,weaponSubtype,sourceKind,damageType,tostring(ballistic),tostring(beamWeapon),attackerFaction}
    for i,value in ipairs(fields) do value=tostring(value or 'UNKNOWN'); fields[i]=#value..':'..value end
    return table.concat(fields)
end

local function baseDamageRows(factionData)
    local rows={}
    for _,row in pairs((factionData and factionData.weapons) or {}) do rows[#rows+1]=row end
    table.sort(rows,function(a,b)
        if a.hullDamage~=b.hullDamage then return a.hullDamage>b.hullDamage end
        if a.shieldDamage~=b.shieldDamage then return a.shieldDamage>b.shieldDamage end
        if a.weaponClass~=b.weaponClass then return a.weaponClass<b.weaponClass end
        return a.targetName<b.targetName
    end)
    return rows
end

local function baseDamageSummary(factionData,elapsedSeconds)
    factionData=factionData or newBaseDamageFaction()
    elapsedSeconds=math.max(0,tonumber(elapsedSeconds) or 0)
    return {hitCount=factionData.hitCount,shieldDamage=factionData.shieldDamage,hullDamage=factionData.hullDamage,
        shieldDamagePerSecond=elapsedSeconds>0 and factionData.shieldDamage/elapsedSeconds or 0,
        hullDamagePerSecond=elapsedSeconds>0 and factionData.hullDamage/elapsedSeconds or 0,
        elapsedSeconds=elapsedSeconds,byWeapon=baseDamageRows(factionData)}
end

local function newCombatDamageFaction()
    return {hitCount=0,lethalHits=0,shieldDamage=0,hullDamage=0,matchups={},friendlyFirePairs={},friendlyFirePairCount=0,
        friendlyFireOverflow={hitCount=0,lethalHits=0,shieldDamage=0,hullDamage=0}}
end

local FRIENDLY_FIRE_PAIR_LIMIT=256

local function combatDamageBucketKey(targetClass,weaponClass,weaponSubtype,sourceKind,damageType,ballistic,beamWeapon,attackerFaction,attackerClass)
    local fields={targetClass,weaponClass,weaponSubtype,sourceKind,damageType,tostring(ballistic),tostring(beamWeapon),attackerFaction,attackerClass}
    for i,value in ipairs(fields) do value=tostring(value or 'UNKNOWN'); fields[i]=#value..':'..value end
    return table.concat(fields)
end

local function combatDamageRows(factionData)
    local rows={}
    for _,row in pairs((factionData and factionData.matchups) or {}) do rows[#rows+1]=row end
    table.sort(rows,function(a,b)
        if a.hullDamage~=b.hullDamage then return a.hullDamage>b.hullDamage end
        if a.lethalHits~=b.lethalHits then return a.lethalHits>b.lethalHits end
        if a.targetClass~=b.targetClass then return a.targetClass<b.targetClass end
        if a.weaponClass~=b.weaponClass then return a.weaponClass<b.weaponClass end
        return a.attackerClass<b.attackerClass
    end)
    return rows
end

local function friendlyFireRows(factionData)
    local rows={}
    for _,row in pairs((factionData and factionData.friendlyFirePairs) or {}) do rows[#rows+1]=row end
    table.sort(rows,function(a,b)
        if a.hullDamage~=b.hullDamage then return a.hullDamage>b.hullDamage end
        if a.lethalHits~=b.lethalHits then return a.lethalHits>b.lethalHits end
        if a.attackerSignature~=b.attackerSignature then return a.attackerSignature<b.attackerSignature end
        return a.targetSignature<b.targetSignature
    end)
    return rows
end

local function combatDamageSummary(factionData,elapsedSeconds,includeFriendlyFirePairs)
    factionData=factionData or newCombatDamageFaction()
    elapsedSeconds=math.max(0,tonumber(elapsedSeconds) or 0)
    local summary={hitCount=factionData.hitCount,lethalHits=factionData.lethalHits,
        shieldDamage=factionData.shieldDamage,hullDamage=factionData.hullDamage,
        shieldDamagePerSecond=elapsedSeconds>0 and factionData.shieldDamage/elapsedSeconds or 0,
        hullDamagePerSecond=elapsedSeconds>0 and factionData.hullDamage/elapsedSeconds or 0,
        elapsedSeconds=elapsedSeconds,byMatchup=combatDamageRows(factionData)}
    if includeFriendlyFirePairs then
        summary.friendlyFirePairs=friendlyFireRows(factionData)
        summary.friendlyFireOverflow=factionData.friendlyFireOverflow
        summary.friendlyFirePairScope='interval'
    end
    return summary
end

return {
    valid = valid,
    sig = sig,
    clamp = clamp,
    distance = distance,
    health = health,
    doctrine = doctrine,
    mobileRole = mobileRole,
    heavyRole = heavyRole,
    balanceDefinition = balanceDefinition,
    json = json,
    newBaseDamageFaction = newBaseDamageFaction,
    baseDamageBucketKey = baseDamageBucketKey,
    baseDamageRows = baseDamageRows,
    baseDamageSummary = baseDamageSummary,
    newCombatDamageFaction = newCombatDamageFaction,
    FRIENDLY_FIRE_PAIR_LIMIT = FRIENDLY_FIRE_PAIR_LIMIT,
    combatDamageBucketKey = combatDamageBucketKey,
    combatDamageRows = combatDamageRows,
    friendlyFireRows = friendlyFireRows,
    combatDamageSummary = combatDamageSummary,
}
