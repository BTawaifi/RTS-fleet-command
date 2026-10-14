-- Pilot weapon helpers: flak, bank state and firing slots.
local _shared = require "fs2rts_pilot.common"
local U = _shared.U

local Config = require "fs2rts_config"

local AI_FACTION_ORDER, sortedNumericKeys = U.AI_FACTION_ORDER, U.sortedNumericKeys
