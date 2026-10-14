-- Shared locals of fs2rts_orders, moved out of its parts so every part binds the same values.
-- Loaded first by the aggregator; parts import the names they use from the returned table.

local U = require "fs2rts_util"

local RTS = require "fs2rts_state"

local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

-- (lateral, depth) offsets for a named shape, in ship order.
local function shapeOffsets(n,id,shape,spacing)
    local gap=spacing*(tonumber(shape.spacing) or 1)
    if not (gap>0) then gap=spacing end
    if not (gap>0) then gap=1 end
    local rowDepth=gap*(tonumber(shape.depth) or 1)
    local taper=tonumber(shape.taper) or 0
    local out={}
    for i=1,n do
        local lateral,depth=0,0
        if id=="COLUMN" then
            depth=(i-1)*rowDepth
        elseif id=="TIGHT" then
            local cols=math.ceil(math.sqrt(n))
            lateral=((i-1)%cols-(cols-1)/2)*gap
            depth=math.floor((i-1)/cols)*rowDepth
        elseif id=="WEDGE" then
            local k=i-1
            local row=math.floor((math.sqrt(8*k+1)-1)/2)
            lateral=(k-row*(row+1)/2-row/2)*gap
            depth=row*rowDepth
        elseif id=="ECHELON" then
            lateral=(i-(n+1)/2)*gap
            depth=i*rowDepth*taper
        elseif id=="SCREEN" then
            lateral=(i-(n+1)/2)*gap
            local q=math.abs(lateral)/gap
            -- Positive depth TRAILS behind the core: slots are offset by
            -- -dir*depth, so a negative depth pushed the wings FORWARD of the
            -- centre, i.e. ahead of the target - the exact opposite of a screen
            -- shielding a slow core from a frontal attack.
            depth=q*q*rowDepth*taper
        else
            lateral=(i-(n+1)/2)*gap
        end
        out[i]={lateral=lateral,depth=depth}
    end
    return out
end

-- Legacy radius-aware row packing, kept as the fallback for unknown shapes.
local function packedOffsets(ordered,baseGap,clearance,maxRowWidth)
    local rows = {}; local row = {items={}, width=0, height=0}
    local function flushRow()
        if #row.items > 0 then rows[#rows+1] = row end
        row = {items={}, width=0, height=0}
    end
    for _,item in ipairs(ordered) do
        local diameter = math.max(baseGap, item.radius * 2.20 + clearance)
        local extra = (#row.items > 0) and clearance or 0
        if #row.items > 0 and row.width + extra + diameter > maxRowWidth then flushRow(); extra=0 end
        row.items[#row.items+1] = {size=diameter}
        row.width = row.width + extra + diameter
        row.height = math.max(row.height, diameter)
    end
    flushRow()

    local totalDepth = 0
    for i,r in ipairs(rows) do totalDepth = totalDepth + r.height + (i>1 and clearance or 0) end
    local depthCursor = -totalDepth * 0.5
    local localOffsets = {}
    for _,r in ipairs(rows) do
        local lateralCursor = -r.width * 0.5
        local depth = depthCursor + r.height * 0.5
        for index,item in ipairs(r.items) do
            if index > 1 then lateralCursor = lateralCursor + clearance end
            local lateral = lateralCursor + item.size * 0.5
            localOffsets[#localOffsets+1] = {lateral=lateral, depth=depth}
            lateralCursor = lateralCursor + item.size
        end
        depthCursor = depthCursor + r.height + clearance
    end
    return localOffsets
end

return {
    U = U,
    RTS = RTS,
    clamp = clamp,
    vec = vec,
    copyVec = copyVec,
    objectValid = objectValid,
    shipValid = shipValid,
    shipAlive = shipAlive,
    shapeOffsets = shapeOffsets,
    packedOffsets = packedOffsets,
}
