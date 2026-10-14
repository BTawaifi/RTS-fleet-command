-- Coordinated planning and observation helpers. Scores are estimates; acquisition,
-- movement, hull loss and collision observations remain separate evidence.
return function(RTS)
require("fs2rts_ai_telemetry")(RTS)
require("fs2rts_ai_planning")(RTS)
end
