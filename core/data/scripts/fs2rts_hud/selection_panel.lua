-- HUD selection panel: role badges, build catalog, panel layout.
local _shared = require "fs2rts_hud.common"
local RTS, CONTROLLER_COLORS, ACTION_BUTTON_ROWS, ACTION_BUTTON_LABELS, ARMED_COMMAND_HINTS, bindActionButtonLabels, ROLE_BADGES = _shared.RTS, _shared.CONTROLLER_COLORS, _shared.ACTION_BUTTON_ROWS, _shared.ACTION_BUTTON_LABELS, _shared.ARMED_COMMAND_HINTS, _shared.bindActionButtonLabels, _shared.ROLE_BADGES

-- Module level, not built inside the call. DrawRoleBadge runs once per build
-- row, once per selection row and once per decorated contact, so an eight-entry
-- table literal per call was a few hundred small tables a frame for a lookup of
-- two numbers.
local ROLE_BADGE_COLORS={fighter={70,175,225},bomber={225,125,55},escort={85,195,155},capital={185,160,225},heavy={230,190,90},juggernaut={240,105,105},sentry={170,190,200},station={110,170,200}}

local ROLE_BADGE_FALLBACK_COLOR={145,165,175}

function RTS:DrawRoleBadge(role,x,y,size)
    local glyph=ROLE_BADGES[role] or "?"
    local color=ROLE_BADGE_COLORS[role] or ROLE_BADGE_FALLBACK_COLOR; gr.setColor(color[1],color[2],color[3],255)
    gr.drawRectangle(x,y,x+size,y+size,false)
    -- +1: the cap glyphs sit high in their font cell, measured ~1.5px above centre at 1920.
    gr.setColor(240,245,248,255); self:DrawCenteredText(glyph,x,x+size,math.floor(y+(size-self:TextHeight(glyph))/2)+1)
end

function RTS:GetVisibleBuildCatalog()
    local filter=self.BuildRoleFilter or "all"; local visible={}
    for index,option in ipairs(self.BuildCatalog or {}) do
        local role=option.role
        if filter=="all" or role==filter or (filter=="capital" and (role=="heavy" or role=="juggernaut")) then
            visible[#visible+1]={index=index,option=option}
        end
    end
    return visible
end

-- Height of the selection panel's fixed header: title, hint, and the colour
-- legend (which wraps to a second line on a narrow pane). Both the row layout
-- and the panel's own drawing read this, so the rows cannot start above the
-- legend just because one of them ran first on a frame where the resolution
-- had changed.
function RTS:GetSelectionHeaderHeight(sw,sh)
    local rect=self:GetSelectionPanelRect(sw,sh)
    local m=self:GetUIMetrics(sw,sh)
    local lx=rect.x1+m.panelPadding; local lines=1
    for _,entry in ipairs({{"order","YOUR ORDER"},{"policy","POLICY"},{"auto","AUTO"},{"pilot","PILOT"},{"sentry","SENTRY"}}) do
        local w=self:TextWidth(entry[2])
        if lx+w>rect.x2-m.panelPadding then lx=rect.x1+m.panelPadding; lines=lines+1 end
        lx=lx+w+m.sectionGap
    end
    return m.panelPadding+((self.ShowHotkeyHints==false and 1 or 2)+lines)*m.lineHeight, m, rect
end

function RTS:DrawSelectionPanel(sw,sh)
    local rect=self:GetSelectionPanelRect(sw,sh); local x1,y1,x2,y2=rect.x1,rect.y1,rect.x2,rect.y2
    local m=self:GetUIMetrics(sw,sh); local pad=m.panelPadding; local lh=m.lineHeight
    local inner=x2-pad
    local ships=self:GetSelectedShips()
    gr.setColor(4,10,18,215); gr.drawRectangle(x1,y1,x2,y2,true); gr.setColor(100,190,220,255); gr.drawRectangle(x1,y1,x2,y2,false)
    gr.setColor(210,230,238,255); self:DrawTextLine("SELECTED: "..#ships,x1+pad,y1+pad,inner-(x1+pad))
    gr.setColor(150,180,195,255)
    if self.ShowHotkeyHints~=false then self:DrawTextLine("Right-click: move / attack / guard",x1+pad,y1+pad+lh,inner-(x1+pad)) end
    -- Colour legend. It used to advance x by (#label * 8) pixels, i.e. eight
    -- pixels per CHARACTER, which is not the width of a glyph in FSO's
    -- proportional font: the legend ran past the pane edge. It is measured now,
    -- and wraps to a second line rather than overflowing.
    local legendY=y1+pad+(self.ShowHotkeyHints==false and 1 or 2)*lh
    local lx=x1+pad; local legendWidth=inner-x1-pad
    for _,entry in ipairs({{"order","YOUR ORDER"},{"policy","POLICY"},{"auto","AUTO"},{"pilot","PILOT"},{"sentry","SENTRY"}}) do
        local c=CONTROLLER_COLORS[entry[1]]
        local w=self:TextWidth(entry[2])
        if lx+w>x2-pad then lx=x1+pad; legendY=legendY+lh end
        gr.setColor(c[1],c[2],c[3],255); gr.drawString(entry[2],lx,legendY)
        lx=lx+w+m.sectionGap
    end
    self.LegendBottomY=legendY+lh
    -- Row columns, measured from the pane instead of at literal 23/218/274.
    local badgeSize=math.max(17,m.pad(17))
    local hpX=x1+math.floor(m.selectionWidth*0.53)
    local labelX=x1+math.floor(m.selectionWidth*0.70)
    local nameX=x1+pad+badgeSize+m.pad(6)
    for index=1,self.SelectionRowsShown or 0 do
        local row=self.SelectionRows[index]; local r=row.rect
        if self.HoveredSelectionRow==index then gr.setColor(55,75,82,225); gr.drawRectangle(r.x1,r.y1,r.x2,r.y2,true) end
        local cr,cg,cb=self:GetControllerColor(row.ships[1],row.controller); gr.setColor(cr,cg,cb,255)
        local hp=0; local primary=false
        for _,ship in ipairs(row.ships) do
            hp=hp+(ship.HitpointsMax>0 and math.max(0,ship.HitpointsLeft/ship.HitpointsMax*100) or 0)
            if ship:getSignature()==self.PrimarySelectionSignature then primary=true end
        end
        -- The faction prefix ("GTA // ") is already conveyed by the badge and colour, and
        -- it is what pushed the rest of the name into the ellipsis.
        local name=#row.ships==1 and (tostring(row.ships[1].Name or ""):gsub("^%u+ // ","")) or (row.className.." x"..#row.ships)
        local role=self:GetShipRole(row.ships[1]); self:DrawRoleBadge(role,r.x1+3,r.y1+math.floor((m.selectionRowHeight-badgeSize)/2),badgeSize)
        self:DrawTextLine((primary and ">" or " ")..name,nameX,r.y1+math.floor((m.selectionRowHeight-lh)/2),hpX-nameX-m.pad(6))
        self:DrawTextLine(string.format("%3.0f%%",hp/#row.ships),hpX,r.y1+math.floor((m.selectionRowHeight-lh)/2),labelX-hpX-m.pad(4))
        self:DrawTextLine(row.label,labelX,r.y1+math.floor((m.selectionRowHeight-lh)/2),r.x2-labelX-m.pad(4))
    end
    if #self.SelectionRows>(self.SelectionRowsShown or 0) then
        local hidden=0; for index=(self.SelectionRowsShown or 0)+1,#self.SelectionRows do hidden=hidden+#self.SelectionRows[index].ships end
        gr.setColor(170,195,205,255); self:DrawTextLine("+ "..hidden.." more ships",x1+pad,self.SelectionMoreY,inner-(x1+pad))
    end

    local controls=self.Config.HomeworldControls or {}
    if self.ActionButtonLabelsBound~=controls then bindActionButtonLabels(self) end
    local commandable=false; local pilotable=false
    for _,ship in ipairs(self:GetSelectedFriendlyShips()) do
        if self:IsMovableFriendly(ship) then commandable=true end
        if self:IsPilotableShip(ship) then pilotable=true end
    end
    -- The action buttons, without the nine nested tables and nine label
    -- concatenations this used to build every frame. The layout and the labels
    -- are fixed for the session (they come from the configured key bindings),
    -- so they are module constants built once; only enabled and active change
    -- from frame to frame, and those are two values out of a function rather
    -- than a table each.
    self.ActionButtonRects={}; local gap=m.pad(8)
    local btnH=math.max(30,m.pad(30))
    local hasSelection=#ships>0
    for rowIndex,ids in ipairs(ACTION_BUTTON_ROWS) do
        local bw=math.floor(((x2-x1)-2*pad-gap*(#ids-1))/#ids)
        local by=y2-btnH-(rowIndex==1 and (btnH+math.max(8,m.pad(8))) or 0); local bx=x1+pad
        for _,id in ipairs(ids) do
            local br={x1=bx,y1=by,x2=bx+bw,y2=by+btnH}; self.ActionButtonRects[id]=br
            local enabled,active=self:GetActionButtonState(id,commandable,pilotable,hasSelection)
            local label=ACTION_BUTTON_LABELS[id]
            if self.ShowHotkeyHints==false then label=label:gsub(' %b()$','') end
            self:DrawButton(br,label,enabled,active); bx=bx+bw+gap
        end
    end

    -- Sentry placement shows its own readout at the cursor, so this hint would
    -- stack a second line on top of it.
    if self.ArmedCommand~=nil and self.ArmedCommand~="sentry" and self.ShowHotkeyHints~=false then
        local mx,my=io.getMouseX(),io.getMouseY()
        gr.setColor(255,220,90,255)
        self:DrawTextLine(ARMED_COMMAND_HINTS[self.ArmedCommand] or "",mx+18,my+18,math.max(120,m.sw-mx-40))
    end
end
