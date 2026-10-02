-- Pure helpers shared by the fs2rts_* modules.

local AI_FACTION_ORDER = {"BLUE", "RED", "GOLD"}

local function sortedNumericKeys(source)
    local keys = {}
    for key in pairs(source or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function lower(value)
    if value == nil then return "" end
    return string.lower(tostring(value))
end

local function vec(x, y, z)
    return ba.createVector(x, y, z)
end

local function copyVec(v)
    return vec(v.x, v.y, v.z)
end

local function distance2(x1, y1, x2, y2)
    local dx = x1 - x2
    local dy = y1 - y2
    return dx * dx + dy * dy
end

local function objectValid(object)
    return object ~= nil and object:isValid()
end

local function shipValid(ship)
    return objectValid(ship) and ship:getBreedName() == "Ship"
end

local function shipAlive(ship)
    -- Script kills enter death roll without necessarily zeroing native hull.
    return shipValid(ship) and not ship:isDying() and (tonumber(ship.HitpointsLeft) or 0)>0
end

local function teamName(ship)
    if not shipValid(ship) then return "" end
    return lower(ship.Team.Name)
end

local function tableContainsSignature(list, sig)
    for _, value in ipairs(list) do
        if value == sig then return true end
    end
    return false
end
return {
    AI_FACTION_ORDER = AI_FACTION_ORDER,
    sortedNumericKeys = sortedNumericKeys,
    clamp = clamp,
    lower = lower,
    vec = vec,
    copyVec = copyVec,
    distance2 = distance2,
    objectValid = objectValid,
    shipValid = shipValid,
    shipAlive = shipAlive,
    teamName = teamName,
    tableContainsSignature = tableContainsSignature,
}
