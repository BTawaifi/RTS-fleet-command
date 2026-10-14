-- Formation shapes and row offsets.
local _shared = require "fs2rts_orders.common"
local RTS = _shared.RTS

-- A shape id is honoured only when it is both a listed type and a defined
-- shape; anything else falls back to the row-packing layout.
function RTS:GetFormationShape(id)
    local F=self.Config.Formation or {}
    local shapes=F.Shapes
    if type(id)~="string" or type(shapes)~="table" or type(shapes[id])~="table" then return nil end
    local types=F.Types
    if type(types)=="table" and #types>0 then
        for _,entry in ipairs(types) do
            if type(entry)=="table" and entry.id==id then return shapes[id] end
        end
        return nil
    end
    return shapes[id]
end

function RTS:GetFormationTypes()
    local F=self.Config.Formation or {}
    return F.Types or {}
end

function RTS:GetSelectedFormation()
    local F=self.Config.Formation or {}
    if self:GetFormationShape(self.SelectedFormation)~=nil then return self.SelectedFormation end
    if self:GetFormationShape(F.Default)~=nil then return F.Default end
    local types=F.Types
    if type(types)=="table" and type(types[1])=="table" and type(types[1].id)=="string" then return types[1].id end
    return nil
end

function RTS:SetSelectedFormation(id)
    if self:GetFormationShape(id)==nil then return false end
    self.SelectedFormation=id
    return true
end
