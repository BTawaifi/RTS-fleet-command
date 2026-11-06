-- Native-style feedback for the real hull flown in pilot mode. FSO plays its own hit
-- flash and missile-lock warning only for its player object, which here is the
-- observer proxy, so this reproduces the same two effects for the flown hull.
local shared=require "fs2rts_pilot.common"
local RTS,objectValid,shipAlive=shared.RTS,shared.objectValid,shared.shipAlive

-- Engine values: ship_hit_pain adds damage * Generic_pain_flash_factor / 15 to the red
-- flash, the flash fades at 0.75 per second, and it is drawn as red * 128.
local FLASH_PER_DAMAGE=1/15
local FLASH_FADE_PER_SECOND=.75
local FLASH_COLOR_SCALE=128
-- Game sound slots of the heat-seeker and aspect-lock launch warnings.
local HEATLOCK_WARN_SOUND=25
local ASPECTLOCK_WARN_SOUND=42
local MAX_TRACKED_MISSILES=64

local function newFeedback(ship,now)
    return {signature=ship:getSignature(),hull=ship.HitpointsLeft,shield=0,flash=0,updatedAt=now,missiles={},count=0}
end

local function shieldTotal(ship)
    local shields=ship.Shields
    return shields and shields.CombinedLeft or 0
end

local function lockSound(weapon)
    local class=weapon.Class
    if class and (class.heatEffectiveness or 0)>0 then return HEATLOCK_WARN_SOUND end
    return ASPECTLOCK_WARN_SOUND
end

local function playSound(index)
    pcall(ad.playGameSound,index)
end

local function forget(feedback,signature)
    if feedback.missiles[signature]~=nil then
        feedback.missiles[signature]=nil
        feedback.count=feedback.count-1
    end
end

local function updateFlash(feedback,ship,now)
    local hull=ship.HitpointsLeft
    local shield=shieldTotal(ship)
    local damage=math.max(0,feedback.hull-hull)+math.max(0,feedback.shield-shield)
    feedback.hull=hull; feedback.shield=shield
    local elapsed=math.max(0,now-feedback.updatedAt)
    feedback.updatedAt=now
    feedback.flash=math.min(1,math.max(0,feedback.flash-FLASH_FADE_PER_SECOND*elapsed)+damage*FLASH_PER_DAMAGE)
end

local function checkMissiles(feedback,signature)
    for missileSignature,missile in pairs(feedback.missiles) do
        if not objectValid(missile.weapon) then
            forget(feedback,missileSignature)
        elseif not missile.warned then
            local target=missile.weapon.HomingObject
            if objectValid(target) and target:getSignature()==signature then
                missile.warned=true
                playSound(missile.sound)
            end
        end
    end
end

function RTS:StartPilotFeedback(ship)
    self.PilotFeedback=shipAlive(ship) and newFeedback(ship,self:UINow()) or nil
    if self.PilotFeedback then self.PilotFeedback.shield=shieldTotal(ship) end
end

function RTS:StopPilotFeedback()
    self.PilotFeedback=nil
end

-- Called from the weapon-created hook for every new weapon; only hostile missiles are kept.
function RTS:NotePilotThreatWeapon(weapon,parent)
    local feedback=self.PilotFeedback
    if not feedback or feedback.count>=MAX_TRACKED_MISSILES then return end
    local class=weapon.Class
    if not (class and class:isMissile()) then return end
    if not (objectValid(parent) and self:IsHostile(parent)) then return end
    local signature=weapon:getSignature()
    if feedback.missiles[signature]~=nil then return end
    feedback.missiles[signature]={weapon=weapon,sound=lockSound(weapon),warned=false}
    feedback.count=feedback.count+1
end

function RTS:ForgetPilotThreatWeapon(weapon)
    local feedback=self.PilotFeedback
    if feedback then forget(feedback,weapon:getSignature()) end
end

function RTS:UpdatePilotFeedback()
    local ship=self:GetPossessedShip()
    local feedback=self.PilotFeedback
    if not shipAlive(ship) or self.PendingPilotEject or self.Paused then return end
    if not feedback or feedback.signature~=ship:getSignature() then
        self:StartPilotFeedback(ship)
        return
    end
    updateFlash(feedback,ship,self:UINow())
    if feedback.count>0 then checkMissiles(feedback,feedback.signature) end
end

function RTS:DrawPilotFeedbackFlash()
    local feedback=self.PilotFeedback
    if not feedback or feedback.flash<=0 then return end
    gr.flashScreen(math.floor(feedback.flash*FLASH_COLOR_SCALE),0,0)
end
