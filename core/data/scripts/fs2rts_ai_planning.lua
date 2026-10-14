-- AI context, objective scoring, group commits, execution observation.
return function(RTS)
local _shared = require("fs2rts_ai_planning.common")(RTS)
require("fs2rts_ai_planning.context")(RTS, _shared)
require("fs2rts_ai_planning.candidates")(RTS, _shared)
require("fs2rts_ai_planning.objective_scoring")(RTS, _shared)
require("fs2rts_ai_planning.group_roles")(RTS, _shared)
require("fs2rts_ai_planning.battle_events")(RTS, _shared)
require("fs2rts_ai_planning.commit")(RTS, _shared)
require("fs2rts_ai_planning.observation")(RTS, _shared)
require("fs2rts_ai_planning.summary")(RTS, _shared)
end
