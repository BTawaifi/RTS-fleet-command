-- Auto mode, music and panel layout queries.
local _shared = require "fs2rts_input.common"
local RTS = _shared.RTS

function RTS:SetAutoPlayerMode(enabled)
    enabled=enabled==true
    if self.AutoPlayerMode==enabled then return end
    self.AutoPlayerMode=enabled
    local now=mn.getMissionTime()
    if enabled then
        if self.AIStates.BLUE==nil then self.AIStates.BLUE={cp=self.CommandPoints,income=0,lastIncome=now,queue=nil,nextThink=now+1,serial=0,eliminated=false,playerEconomy=true} end
        self:EachShip(function(ship) if self:IsMovableFriendly(ship) and self.UserOrders[ship:getSignature()]==nil and self.PossessedSignature~=ship:getSignature() then self:AssignAIStrategicOrder(ship,"BLUE",true) end end)
        self:SetStatus("BLUE AUTO MODE ENABLED",2)
    else
        if self.AIStates.BLUE and self.AIStates.BLUE.queue then
            local q=self.AIStates.BLUE.queue
            local refund=q.estimate and q.estimate.cost or 0
            local before=self.CommandPoints
            if refund>0 then
                self.CommandPoints=self.CommandPoints+refund
                self:RecordAIEconomyFlow("BLUE","refund",refund)
                self:EmitAIEvent("PRODUCTION",{action="QUEUE_CANCELLED",producer="AI",faction="BLUE",
                    class=q.entry and q.entry.class or "UNKNOWN",count=q.count or 1,cost=refund,
                    refundedCP=refund,cpBefore=before,cpAfter=self.CommandPoints,reason="AUTO_MODE_DISABLED"},now)
            end
            self.AIStates.BLUE.queue=nil
        end
        -- Dropping the state is what actually stops Blue production. Keeping it
        -- alive with playerEconomy=true let UpdateAIProduction keep re-syncing to
        -- the player's CP and buying ships after the mode was switched off.
        self.AIStates.BLUE=nil
        self:EachShip(function(ship)
            if self:IsMovableFriendly(ship) and self.UserOrders[ship:getSignature()]==nil then
                local sig=ship:getSignature(); self.AIOrderState[sig]=nil; self:ApplyPolicyToShip(ship,true)
            end
        end)
        self:SetStatus("BLUE AUTO MODE DISABLED - FLEET ON MANUAL CONTROL",2)
    end
end

-- Formation cycle. delta -1 walks backwards; the list wraps so a single button
-- reaches every shape without a separate picker panel.
function RTS:CycleSelectedFormation(delta)
    local types=self:GetFormationTypes()
    if types==nil or #types==0 then return end
    local current=self:GetSelectedFormation()
    local index=0
    for i,entry in ipairs(types) do if entry.id==current then index=i break end end
    local nextIndex=((index-1+(tonumber(delta) or 1))%#types)+1
    local id=types[nextIndex].id
    if not self:SetSelectedFormation(id) then return end
    for _,entry in ipairs(types) do if entry.id==id then self:SetStatus("FORMATION: "..string.upper(entry.label).." // "..entry.desc,2.4) break end end
end

function RTS:SetMusicMuted(muted,silent)
    local cfg=self.Config.Music or {}
    if cfg.Enabled==false then
        if not silent then self:SetStatus("Music muting is disabled in config",1.6) end
        return false
    end
    muted=muted==true
    local ok=self:SetEnvironmentMusicMuted(muted)
    if not ok then if not silent then self:SetStatus("Music mute unavailable in this engine build",2) end return false end
    self.MusicMuted=muted
    if not silent then self:SetStatus(muted and "MUSIC MUTED" or "MUSIC ON",1.6) end
    return true
end

function RTS:ToggleMusicMute()
    return self:SetMusicMuted(not self.MusicMuted)
end

function RTS:GetSelectionPanelRect(sw, sh)
    local m = self:GetUIMetrics(sw, sh)
    local y2 = m.sh - m.margin
    return { x1=m.margin, y1=y2 - m.selectionHeight, x2=m.margin + m.selectionWidth, y2=y2 }
end

function RTS:IsPointOnRTSUI(x,y)
    local sw,sh=gr.getScreenWidth(),gr.getScreenHeight()
    local m=self:GetUIMetrics(sw,sh)
    if self.EnvironmentPicker then return true end
    for _,rect in pairs(self.FleetLifeButtonRects or {}) do
        if self:PointInside(rect,x,y) then return true end
    end
    if self:PointInside(self.NewUnitPopupRect,x,y) then return true end
    if y>=0 and y<=m.topBarHeight then return true end
    if self:IsPointOnTacticalMap(x,y) then return true end
    if self:PointInside(self:GetProductionPanelRect(sw,sh),x,y) then return true end
    if self.PanelTab~='history' then
        if m.quickGroupsVisible and self:PointInside(self:GetQuickGroupPanelRect(sw,sh),x,y) then return true end
        if self:PointInside(self:GetPolicyPanelRect(sw,sh),x,y) then return true end
        if self:PointInside(self:GetOptionsPanelRect(sw,sh),x,y) then return true end
    end
    if self:PointInside(self:GetSelectionPanelRect(sw,sh),x,y) then return true end
    if #self:GetSelectedShips()>0 and x>=m.margin and x<=m.margin+m.selectionWidth
        and y>=m.statsTop and y<=self:GetSelectedStatsBottom(sw,sh) then return true end
    return false
end

function RTS:GetSelectedStatsBottom(sw,sh)
    local m=self:GetUIMetrics(sw,sh)
    return m.statsTop + ((#self:GetSelectedShips()==1) and m.statsSingleHeight or m.statsMultiHeight)
end
