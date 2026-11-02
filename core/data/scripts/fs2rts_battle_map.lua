-- Opt-in battle map log. With Config.Diagnostics.BattleMapLog set, every
-- BattleMapSeconds the position, order, hull and nearest-enemy distance of every ship
-- is appended to battle-map.tsv in the mod's data folder. tools/battle_map_report.py
-- turns the file into clusters and base-defence numbers. Nothing here changes play.
--
--   P rows: time, faction, signature, class, role, x, z, hull, order, nearestEnemyMeters,
--           shield (0-1, -1 when the hull has none), native target signature ('-' when none),
--           distance to that target in meters (-1 when none), the strategic planner's target
--           signature ('-' when it has none), primary-weapon volleys since the last sample
--           (-1 unless Diagnostics.BattleMapVolleys is on)
--   B rows: time, faction, x, z, hull
--   D rows: time, struck faction, attacker faction, attacker class, weapon class, hits on that
--           faction's command station since the last sample (beam hits count once per
--           collision event, not per second)
--   M rows: free-form markers (scenario start, a command station lost, probe notes)
local RTS=require 'fs2rts_state'
local U=require 'fs2rts_util'
local shipAlive=U.shipAlive

local FILE_NAME='battle-map.tsv'

local function settings(self)
    return self.Config.Diagnostics or {}
end

local function number(value)
    return string.format('%.0f',value)
end

function RTS:BattleMapRow(...)
    local file=self.BattleMapFile
    if not file then return end
    file:write(table.concat({...},'\t')..'\n')
end

-- One file per scenario: a restarted match starts a fresh file instead of appending
-- rows whose clock has gone back to zero.
function RTS:OpenBattleMapLog()
    if self.BattleMapFile and self.BattleMapScenario==self.ScenarioStartTime then return true end
    if self.BattleMapOpenFailed then return false end
    if self.BattleMapFile then self.BattleMapFile:close(); self.BattleMapFile=nil end
    if cf==nil then self.BattleMapOpenFailed=true; return false end
    local file=cf.openFile(FILE_NAME,'w','data')
    if not file or not file:isValid() then self.BattleMapOpenFailed=true; return false end
    self.BattleMapFile=file
    self.BattleMapScenario=self.ScenarioStartTime
    self.BattleMapStations={}
    self.BattleMapHits={}
    self.BattleMapVolleys={}
    self:BattleMapRow('M','start','interval',tostring(settings(self).BattleMapSeconds or 30))
    self:RegisterBattleMapHooks()
    return true
end

local function countVolley(self,user)
    local volleys=self.BattleMapVolleys
    if settings(self).BattleMapVolleys~=true or volleys==nil or not shipAlive(user) then return end
    local signature=user:getSignature()
    volleys[signature]=(volleys[signature] or 0)+1
end

-- weapon is the colliding weapon or beam; its parent is the ship that fired it.
local function countStationHit(self,struckFaction,weapon)
    local hits=self.BattleMapHits
    if hits==nil or weapon==nil or not weapon:isValid() then return end
    local parent=weapon.Parent
    local attackerFaction,attackerClass='NONE','NONE'
    if shipAlive(parent) then
        attackerFaction=self:GetFactionKey(parent) or 'NONE'
        attackerClass=parent.Class.Name
    end
    local key=table.concat({struckFaction,attackerFaction,attackerClass,weapon.Class.Name},'\t')
    hits[key]=(hits[key] or 0)+1
end

-- A failing hook must not break play, but it must not be silent either: the first few
-- distinct failures are written to the log as hookError markers.
local MAX_HOOK_ERRORS=5

local function noteHookError(self,hookName,message)
    self.BattleMapHookErrors=self.BattleMapHookErrors or {}
    local seen=self.BattleMapHookErrors
    local text=hookName..': '..tostring(message):gsub('[\t\r\n]+',' ')
    if seen[text] or (seen.count or 0)>=MAX_HOOK_ERRORS then return end
    seen[text]=true; seen.count=(seen.count or 0)+1
    self:BattleMapRow('M','hookError',text)
end

local function onVolley(self)
    local ok,message=pcall(countVolley,self,hv['User'])
    if not ok then noteHookError(self,'On Primary Fire',message) end
end

local function onStationCollision(self,struckFaction)
    local ok,message=pcall(countStationHit,self,struckFaction,hv['Weapon'] or hv['Beam'])
    if not ok then noteHookError(self,'station collision',message) end
end

-- The engine hooks outlive a scenario, so each is registered once per session and the
-- counters they fill are re-created with every log file.
function RTS:RegisterBattleMapHooks()
    -- The engine library is a userdata object in the game and a plain table in tests.
    if engine==nil or type(engine.addHook)~='function' then
        self:BattleMapRow('M','hooks','unavailable',type(engine),engine~=nil and type(engine.addHook) or '-')
        return
    end
    self.BattleMapHooked=self.BattleMapHooked or {}
    for _,kind in ipairs(self:GetFactionKeys()) do
        local definition=self:GetFactionDefinition(kind)
        local stationName=definition and definition.station
        if type(stationName)=='string' and stationName~='' and not self.BattleMapHooked[stationName] then
            self.BattleMapHooked[stationName]=true
            local conditions={['Ship']=stationName}
            local weapon=engine.addHook('On Weapon Collision',function() onStationCollision(self,kind) end,conditions)
            local beam=engine.addHook('On Beam Collision',function() onStationCollision(self,kind) end,conditions)
            self:BattleMapRow('M','hooks','station',kind,stationName,tostring(weapon),tostring(beam))
        end
    end
    if settings(self).BattleMapVolleys==true and not self.BattleMapHooked['On Primary Fire'] then
        self.BattleMapHooked['On Primary Fire']=true
        local volley=engine.addHook('On Primary Fire',function() onVolley(self) end)
        self:BattleMapRow('M','hooks','volley',tostring(volley))
    end
end

-- What a ship is doing, as one word: the AI order, a player order, or why it has none.
function RTS:GetBattleMapOrder(ship)
    local signature=ship:getSignature()
    local ai=self.AIOrderState and self.AIOrderState[signature]
    if ai and ai.mission then return ai.mission end
    if self.FleetServices and self.FleetServices[signature] then return 'SERVICE' end
    if self.PossessedSignature==signature then return 'PILOT' end
    local user=self.UserOrders and self.UserOrders[signature]
    if user and user.kind then return 'USER:'..user.kind end
    return 'NONE'
end

local function nearestEnemyDistance(self,ship,ships)
    local best=math.huge
    for _,other in ipairs(ships) do
        if other~=ship and not self:IsStaticDefense(other) and self:AreEnemies(ship,other) then
            local d=ship.Position:getDistance(other.Position)
            if d<best then best=d end
        end
    end
    return best==math.huge and -1 or best
end

local function shieldFraction(ship)
    local shields=ship.Shields
    if shields==nil then return -1 end
    local maximum=shields.CombinedMax or 0
    if maximum<=0 then return -1 end
    return math.min(1,(shields.CombinedLeft or 0)/maximum)
end

local function readTarget(ship)
    return ship.Target
end

-- The ship's current native target, or nil. The read is protected because the handle can
-- go stale between frames.
local function nativeTarget(ship)
    local ok,target=pcall(readTarget,ship)
    if ok and shipAlive(target) then return target end
    return nil
end

local function targetColumns(ship)
    local target=nativeTarget(ship)
    if not target then return '-',number(-1) end
    return tostring(target:getSignature()),number(ship.Position:getDistance(target.Position))
end

local function plannedTarget(self,ship)
    local state=self.AIOrderState and self.AIOrderState[ship:getSignature()]
    if state and state.targetSignature~=nil then return tostring(state.targetSignature) end
    return '-'
end

local function volleyCount(self,ship)
    if settings(self).BattleMapVolleys~=true then return number(-1) end
    return number(self.BattleMapVolleys[ship:getSignature()] or 0)
end

local function writeShips(self,elapsed,ships)
    for _,ship in ipairs(ships) do
        if not self:IsCommandStation(ship) then
            local targetSignature,targetDistance=targetColumns(ship)
            self:BattleMapRow('P',number(elapsed),self:GetFactionKey(ship),tostring(ship:getSignature()),ship.Class.Name,
                self:GetShipRole(ship),number(ship.Position.x),number(ship.Position.z),
                string.format('%.3f',ship.HitpointsLeft/math.max(1,ship.HitpointsMax)),self:GetBattleMapOrder(ship),
                number(nearestEnemyDistance(self,ship,ships)),string.format('%.2f',shieldFraction(ship)),
                targetSignature,targetDistance,plannedTarget(self,ship),volleyCount(self,ship))
        end
    end
end

local function writeHits(self,elapsed)
    local keys={}
    for key in pairs(self.BattleMapHits) do keys[#keys+1]=key end
    table.sort(keys)
    for _,key in ipairs(keys) do
        self:BattleMapRow('D',number(elapsed),key,number(self.BattleMapHits[key]))
    end
    self.BattleMapHits={}
end

local function writeStations(self,elapsed,ships)
    local present={}
    for _,ship in ipairs(ships) do
        if self:IsCommandStation(ship) then
            local kind=self:GetFactionKey(ship)
            present[kind]=true; self.BattleMapStations[kind]=true
            self:BattleMapRow('B',number(elapsed),kind,number(ship.Position.x),number(ship.Position.z),
                string.format('%.4f',ship.HitpointsLeft/math.max(1,ship.HitpointsMax)))
        end
    end
    for kind in pairs(self.BattleMapStations) do
        if not present[kind] then
            self:BattleMapRow('M','stationLost',kind,number(elapsed))
            self.BattleMapStations[kind]=nil
        end
    end
end

function RTS:UpdateBattleMapLog(now)
    local c=settings(self)
    if c.BattleMapLog~=true or self.ScenarioStartTime==nil then return end
    if now<(self.NextBattleMapSample or 0) then return end
    if not self:OpenBattleMapLog() then return end
    self.NextBattleMapSample=now+math.max(5,c.BattleMapSeconds or 30)
    local elapsed=now-self.ScenarioStartTime
    local ships={}
    for _,ship in ipairs(self:GetShipList()) do
        if shipAlive(ship) and self:GetFactionKey(ship) then ships[#ships+1]=ship end
    end
    writeStations(self,elapsed,ships)
    writeShips(self,elapsed,ships)
    self.BattleMapVolleys={}
    writeHits(self,elapsed)
    self.BattleMapFile:flush()
end

return RTS
