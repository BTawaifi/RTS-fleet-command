-- The shared RTS table every fs2rts_* module adds its methods to.
local Config = require "fs2rts_config"

local RTS = {
    Enabled = false,
    Config = Config,
}

return RTS
