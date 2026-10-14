-- Shared locals of fs2rts_hud, moved out of its parts so every part binds the same values.
-- Loaded first by the aggregator; parts import the names they use from the returned table.

local U = require "fs2rts_util"

local RTS = require "fs2rts_state"

local clamp, lower, vec, copyVec, distance2, objectValid, shipValid, shipAlive, teamName, tableContainsSignature
    = U.clamp, U.lower, U.vec, U.copyVec, U.distance2, U.objectValid, U.shipValid, U.shipAlive, U.teamName, U.tableContainsSignature

local function rangeRingCameraKey(self,sw,sh)
    local camera=self.Camera
    if self.FollowSignature~=nil and self.FollowCamera~=nil then camera=self.FollowCamera end
    if camera==nil or camera.Position==nil or camera.Orientation==nil then return nil end
    local ok,forward,right,up=pcall(function()
        return camera.Orientation:getFvec(),camera.Orientation:getRvec(),camera.Orientation:getUvec()
    end)
    if not ok or not self:IsFiniteVector(camera.Position) or not self:IsFiniteVector(forward)
        or not self:IsFiniteVector(right) or not self:IsFiniteVector(up) then return nil end
    local p=camera.Position
    return {sw,sh,tonumber(camera.FOV) or 0,p.x,p.y,p.z,
        forward.x,forward.y,forward.z,right.x,right.y,right.z,up.x,up.y,up.z}
end

local function sameRangeRingKey(entry,cx,cy,cz,range,segments,screenX,screenY,cameraKey)
    if entry.cx~=cx or entry.cy~=cy or entry.cz~=cz or entry.range~=range or entry.segments~=segments
        or entry.screenX~=screenX or entry.screenY~=screenY or cameraKey==nil then return false end
    for i=1,#cameraKey do if entry.cameraKey[i]~=cameraKey[i] then return false end end
    return true
end

-- Colour per controller (see GetShipController); shared by rows, legend, card.
local CONTROLLER_COLORS={order={255,220,90},policy={110,200,255},auto={120,235,140},pilot={235,130,255},station={200,210,215},sentry={255,175,90}}

-- The selection panel's action buttons. Layout and labels are fixed for the
-- session: they come from the configured key bindings, which do not change
-- while the mod is loaded. So the two row lists and the nine label strings are
-- built once here instead of every frame, and the only per-frame state is
-- whether each button is enabled and whether it is the armed one. This panel is
-- drawn on every frame for as long as anything is selected, so it was a steady
-- drip of short-lived tables and string garbage.
local ACTION_BUTTON_ROWS={{"selectall","hold","engage","release","service"},
                         {"move","attack","pilot","focus"}}

local ACTION_BUTTON_LABELS={selectall="ALL",hold="HOLD",engage="ENGAGE",release="RELEASE",
    service="SERVICE",move="MOVE",attack="ATTACK",pilot="PILOT",focus="FOCUS"}

local ARMED_COMMAND_HINTS={move="MOVE: click destination",attack="ATTACK: click enemy",
    sentry="SENTRY: click placement (Shift: repeat)",strike="STRIKE: click target area"}

-- Fills ACTION_BUTTON_LABELS from the live bindings, so a rebind still reaches
-- the labels; called on the first draw and whenever the table is replaced.
local function bindActionButtonLabels(rts)
    local controls=rts.Config.HomeworldControls or {}
    ACTION_BUTTON_LABELS.selectall="ALL ("..(controls.SelectAll or "L")..")"
    ACTION_BUTTON_LABELS.hold="HOLD ("..(controls.Stop or "R")..")"
    ACTION_BUTTON_LABELS.engage="ENGAGE ("..(controls.Engage or "T")..")"
    ACTION_BUTTON_LABELS.release="RELEASE("..(controls.Release or "G")..")"
    ACTION_BUTTON_LABELS.service="SERVICE"
    ACTION_BUTTON_LABELS.move="MOVE ("..(controls.ArmMove or "M")..")"
    ACTION_BUTTON_LABELS.attack="ATTACK ("..(controls.ArmAttack or "K")..")"
    ACTION_BUTTON_LABELS.pilot="PILOT ("..rts.Config.Pilot.ToggleKey..")"
    ACTION_BUTTON_LABELS.focus="FOCUS ("..(controls.Focus or "F")..")"
    rts.ActionButtonLabelsBound=controls
end

local ROLE_BADGES={fighter="F",bomber="B",escort="E",capital="C",heavy="H",juggernaut="J",sentry="S",station="HQ",support="+"}

-- Faction colours shared by the tactical map icons and the world reticles so a
-- contact reads the same in both views.
-- Declared at file scope, ABOVE first use. These used to sit ~150 lines lower,
-- just above GetReticleFactionKey; DrawTacticalMap referenced them earlier in
-- the file, so Lua resolved a nil global and every selected contact on the
-- tactical map raised "attempt to index global 'RETICLE_COLOR_SELECTED'
-- (a nil value)" from inside the per-ship EachShip callback.
local RETICLE_COLORS={friendly={70,220,255},hostile={255,75,75},third={255,190,70}}

-- Hoisted: these were three-entry table literals evaluated inside the per-ship
-- loop, twice a frame for every decorated contact.
local RETICLE_COLOR_SELECTED={255,225,50}

local RETICLE_COLOR_HOVERED={255,255,180}

return {
    U = U,
    RTS = RTS,
    clamp = clamp,
    vec = vec,
    objectValid = objectValid,
    shipValid = shipValid,
    shipAlive = shipAlive,
    rangeRingCameraKey = rangeRingCameraKey,
    sameRangeRingKey = sameRangeRingKey,
    CONTROLLER_COLORS = CONTROLLER_COLORS,
    ACTION_BUTTON_ROWS = ACTION_BUTTON_ROWS,
    ACTION_BUTTON_LABELS = ACTION_BUTTON_LABELS,
    ARMED_COMMAND_HINTS = ARMED_COMMAND_HINTS,
    bindActionButtonLabels = bindActionButtonLabels,
    ROLE_BADGES = ROLE_BADGES,
    RETICLE_COLORS = RETICLE_COLORS,
    RETICLE_COLOR_SELECTED = RETICLE_COLOR_SELECTED,
    RETICLE_COLOR_HOVERED = RETICLE_COLOR_HOVERED,
}
