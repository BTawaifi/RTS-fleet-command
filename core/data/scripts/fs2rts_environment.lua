-- Retail asset-backed music and nebula art for the RTS mission.
local RTS = require "fs2rts_state"

local function validElement(element)
    if element == nil then return false end
    local ok, valid = pcall(function() return element:isValid() end)
    return ok and valid == true
end

function RTS:SetEnvironmentMusic(choice, silent)
    local config = self.Config.Music or {}
    local tracks = config.Tracks or {}
    if config.Enabled == false or #tracks == 0 then return false end
    local index = choice == "RANDOM" and math.random(#tracks) or tonumber(choice)
    if type(index) ~= "number" or index ~= math.floor(index) or not tracks[index] then return false end
    if ad == nil then return false end

    local filename = tracks[index].file
    if tracks[index].mediavps and cf and cf.fileExists
        and cf.fileExists(tracks[index].mediavps, "", true) then
        filename = tracks[index].mediavps
    end
    local ok, handle = pcall(function() return ad.playMusic(filename, 1, true) end)
    if not ok or type(handle) ~= "number" or handle < 0 then
        if not silent then self:SetStatus("Could not load music: " .. tracks[index].label, 2) end
        return false
    end

    local previous = self.EnvironmentMusicHandle
    if type(previous) == "number" and previous >= 0 then pcall(function() ad.stopMusic(previous, true) end) end
    ad.pauseMusic(handle,self.MusicMuted==true)
    self.EnvironmentMusicHandle = handle
    self.EnvironmentMusicIndex = index
    if not silent then self:SetStatus("MUSIC: " .. tracks[index].label, 2) end
    return true
end

function RTS:SetEnvironmentMusicMuted(muted)
    if ad == nil then return false end
    muted = muted == true
    local ok = pcall(function()
        if type(self.EnvironmentMusicHandle) == "number" and self.EnvironmentMusicHandle>=0 then
            ad.pauseMusic(self.EnvironmentMusicHandle, muted)
        end
    end)
    if not ok then return false end
    self.MusicMuted = muted
    return true
end

function RTS:SetNebulaBackdrop(choice, silent)
    local names = self.Config.Environment and self.Config.Environment.NebulaBackdrops or {}
    if #names == 0 then return false end
    local index = choice == "RANDOM" and math.random(#names) or tonumber(choice)
    if type(index) ~= "number" or index ~= math.floor(index) or not names[index] then return false end
    if mn == nil or type(mn.addBackgroundBitmapNew) ~= "function" then return false end

    -- Retail missions build a nebula from ~30 overlapping patches of
    -- one texture at scale 3-5, each shown at its natural proportions.
    -- Do the same: patches centred on an even spiral over the sphere, each with a
    -- random bank. One bitmap stretched over a big area looks smeared and a few
    -- large faces repeat the whole picture. ScaleX 10 x ScaleY 9.5 is about 95 degrees
    -- square (FSO widens X by 1.88 internally).
    local env=self.Config.Environment
    local count=env.BackdropPatches or 14
    local golden=math.pi*(3-math.sqrt(5)); local spin=math.random()*math.pi*2
    local created={}
    for n=0,count-1 do
        local y=1-2*(n+.5)/count
        local angle=spin+golden*n
        local x,z=math.sqrt(1-y*y)*math.cos(angle),math.sqrt(1-y*y)*math.sin(angle)
        local orientation=ba.createOrientation(-math.asin(y),math.random()*math.pi*2,math.atan2(x,z))
        local texture=names[index]
        local ok,element=pcall(function()
            return mn.addBackgroundBitmapNew(texture,orientation,env.BackdropScaleX or 10,env.BackdropScaleY or 9.5,1,1)
        end)
        if not ok or not validElement(element) then
            for _,fresh in ipairs(created) do
                local removed,result=pcall(function() return mn.removeBackgroundElement(fresh) end)
                if not removed or result~=true then
                    self.EnvironmentBackdropElements=self.EnvironmentBackdropElements or {}
                    self.EnvironmentBackdropElements[#self.EnvironmentBackdropElements+1]=fresh
                end
            end
            if not silent then self:SetStatus("Could not load nebula backdrop: " .. names[index], 2) end
            return false
        end
        created[#created+1]=element
    end

    local kept = {}
    for _, old in ipairs(self.EnvironmentBackdropElements or {}) do
        if validElement(old) then
            local removed, result = pcall(function() return mn.removeBackgroundElement(old) end)
            if not removed or result ~= true then kept[#kept+1] = old end
        end
    end
    for _,element in ipairs(created) do kept[#kept+1]=element end
    self.EnvironmentBackdropElements = kept
    self.EnvironmentBackdropIndex = index
    if not silent then self:SetStatus("NEBULA BACKDROP: " .. string.upper(names[index]), 2) end
    return true
end

function RTS:StopEnvironment()
    if ad ~= nil then
        if type(self.EnvironmentMusicHandle) == "number" and self.EnvironmentMusicHandle >= 0 then
            pcall(function() ad.stopMusic(self.EnvironmentMusicHandle, true) end)
        end
    end
    self.EnvironmentMusicHandle = nil
    self.EnvironmentMusicIndex = nil
    if mn ~= nil and type(mn.removeBackgroundElement) == "function" then
        for _, element in ipairs(self.EnvironmentBackdropElements or {}) do
            if validElement(element) then pcall(function() mn.removeBackgroundElement(element) end) end
        end
    end
    self.EnvironmentBackdropElements = {}
    self.EnvironmentBackdropIndex = nil
end

function RTS:RandomizeEnvironment(silent)
    local music = self.Config.Music or {}
    if music.Enabled ~= false and #(music.Tracks or {}) > 0 then self:SetEnvironmentMusic("RANDOM", silent) end
    local environment = self.Config.Environment or {}
    if environment.RandomBackdropOnStart ~= false then self:SetNebulaBackdrop("RANDOM", silent) end
end

return RTS
