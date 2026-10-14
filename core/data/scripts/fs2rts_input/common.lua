-- Shared locals of fs2rts_input, moved out of its parts so every part binds the same values.
-- Loaded first by the aggregator; parts import the names they use from the returned table.

local U = require "fs2rts_util"

local RTS = require "fs2rts_state"

local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

-- ---------------------------------------------------------------------------
-- Screen projection: one engine call per ship per frame, and as few ships as
-- possible reach that call.
-- ---------------------------------------------------------------------------
--
-- getScreenCoords opens a g3 frame when no frame is active. Reuse projections
-- within an epoch and cull candidates before calling the native projector.
--
-- It returns FALSE, not nil, when the vertex carries PF_OVERFLOW. Every test
-- below therefore compares against `false` explicitly: `coords ~= nil` is
-- true for the engine's own off-screen answer and would treat a contact
-- behind the camera as a screen position.

-- Conservative horizontal overscan for contacts near the edge of a pick.
local PICK_GATE_ASPECT_SLACK = 1.6

return {
    U = U,
    RTS = RTS,
    clamp = clamp,
    lower = lower,
    vec = vec,
    copyVec = copyVec,
    distance2 = distance2,
    shipValid = shipValid,
    tableContainsSignature = tableContainsSignature,
    PICK_GATE_ASPECT_SLACK = PICK_GATE_ASPECT_SLACK,
}
