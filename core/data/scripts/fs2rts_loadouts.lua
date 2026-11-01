-- One profile table feeds player production, AI production, scripted
-- reinforcements and the build-panel preview. Profiles replace secondary banks
-- only; guns, armor and hull are the retail ship's.
local RTS=require 'fs2rts_state'
local U=require 'fs2rts_util'

local profiles={
    ['SB Shaitan']={label='Light siege bomber',secondary={'RTS Shivan Torpedo'}},
    ['SB Nephilim']={label='Siege bomber',secondary={'Rockeye','Piranha','RTS Shivan Torpedo','RTS Shivan Torpedo'}},
    ['SB Taurvi']={label='Heavy strike bomber',secondary={'Trebuchet','RTS Shivan Torpedo'}},
    ['SB Nahema']={label='Precision strike bomber',secondary={'RTS Shivan Torpedo','Trebuchet','Rockeye'}},
    ['SB Seraphim']={label='Heavy siege bomber',secondary={'Rockeye','Trebuchet','RTS Shivan Torpedo','RTS Shivan Torpedo'}},
    ['GTB Athena']={label='Light siege bomber',secondary={'Cyclops'}},
    ['GTB Artemis']={label='Siege bomber',secondary={'Hornet','Cyclops','Cyclops'}},
    ['GTB Boanerges']={label='Heavy siege bomber',secondary={'Trebuchet','Cyclops','Cyclops'}},
    ['GTB Medusa']={label='Siege bomber',secondary={'Hornet','Cyclops','Cyclops'}},
    ['GTB Ursa']={label='Heavy siege bomber',secondary={'Hornet','Cyclops','Cyclops'}},
    ['GTB Zeus']={label='Subsystem suppression',secondary={'Trebuchet','Stiletto II','Cyclops'}},
    ['GVB Bakha']={label='Precision siege bomber',secondary={'Cyclops','Stiletto II'}},
    ['GVB Sekhmet']={label='Heavy siege bomber',secondary={'Hornet','Cyclops','Cyclops'}},
    ['GVB Osiris']={label='Subsystem suppression',secondary={'Cyclops','Stiletto II','Trebuchet'}},
    ['GTF Loki']={label='Light interceptor',secondary={'Tempest','Tempest'}},
    ['GTF Pegasus']={label='Fast interceptor',secondary={'Tempest','Tempest'}},
    ['GTF Perseus']={label='Interceptor',secondary={'Tempest','Trebuchet'}},
    ['GTF Ares']={label='Heavy assault fighter',secondary={'Trebuchet','Harpoon','Harpoon'}},
    ['GTF Erinyes']={label='Heavy assault fighter',secondary={'Trebuchet','Trebuchet'}},
    ['GVF Tauret']={label='Fleet defense fighter',secondary={'Hornet','Harpoon'}},
    ['GVF Serapis']={label='Interceptor',secondary={'Tempest','Harpoon'}},
    ['GVF Ptah']={label='Heavy interceptor',secondary={'Trebuchet','Harpoon'}},
    ['SF Mara']={label='Fleet defense fighter',secondary={'Rockeye','Rockeye'}},
    ['SF Basilisk']={label='Heavy assault fighter',secondary={'Trebuchet','Rockeye'}},
    ['SF Dragon']={label='Fast interceptor',secondary={'Trebuchet','Trebuchet'}},
    ['SF Aeshma']={label='Interceptor',secondary={'Rockeye','Trebuchet'}},
    ['SF Astaroth']={label='Heavy assault fighter',secondary={'Trebuchet','Rockeye'}},
}

local function ammoFor(class,bankIndex,weapon)
    local cargo=math.max(.001,weapon.CargoSize or 1)
    return math.floor(class:getSecondaryBankCapacity(bankIndex)/cargo+.5)
end

function RTS:GetClassLoadout(className)
    return profiles[className]
end

-- Secondary banks a class launches with: {index,weapon,ammo,replaced}. A profile
-- weapon that is unknown, or too bulky for the bank to hold a single round, falls
-- back to the retail weapon so a bank is never emptied by the profile.
function RTS:ResolveSecondaryLoadout(className)
    local class=tb.ShipClasses[className]
    if not class or not class:isValid() then return {} end
    local profile=profiles[className]
    local defaults=class.defaultSecondaries
    local banks={}
    for index=1,#defaults do
        local weapon=defaults[index]
        local replaced=false
        local name=profile and profile.secondary[index]
        local wanted=name and tb.WeaponClasses[name]
        if wanted and wanted:isValid() and wanted.Name~=(weapon and weapon:isValid() and weapon.Name or '')
            and ammoFor(class,index,wanted)>=1 then
            weapon=wanted; replaced=true
        end
        if weapon and weapon:isValid() then
            banks[#banks+1]={index=index,weapon=weapon,ammo=ammoFor(class,index,weapon),replaced=replaced}
        end
    end
    return banks
end

function RTS:ApplySpawnLoadout(ship)
    if not U.shipValid(ship) then return end
    if not profiles[ship.Class.Name] then return end
    self.SpawnLoadoutWeaponsLoaded=self.SpawnLoadoutWeaponsLoaded or {}
    local installed=0
    for _,entry in ipairs(self:ResolveSecondaryLoadout(ship.Class.Name)) do
        if entry.replaced and entry.index<=#ship.SecondaryBanks then
            local name=entry.weapon.Name
            if self.SpawnLoadoutWeaponsLoaded[name]==nil then
                self.SpawnLoadoutWeaponsLoaded[name]=entry.weapon:loadWeapon()==true
            end
            if self.SpawnLoadoutWeaponsLoaded[name] then
                local bank=ship.SecondaryBanks[entry.index]
                bank.WeaponClass=entry.weapon
                bank.AmmoLeft=bank.AmmoMax
                installed=installed+1
            else
                self:Log('LOADOUT WEAPON WILL NOT LOAD: '..name)
            end
        end
    end
    return installed
end

function RTS:GetBuildLoadoutLines(className)
    local class=tb.ShipClasses[className]
    if not class or not class:isValid() then return {} end
    local profile=profiles[className]
    local lines={profile and profile.label or 'Standard loadout'}
    local primaries=class.defaultPrimaries
    for i=1,#primaries do
        local weapon=primaries[i]
        if weapon and weapon:isValid() then lines[#lines+1]='Gun '..i..': '..self:GetWeaponDisplayName(weapon) end
    end
    for _,entry in ipairs(self:ResolveSecondaryLoadout(className)) do
        lines[#lines+1]='Missile '..entry.index..': '..self:GetWeaponDisplayName(entry.weapon)..' x'..entry.ammo
    end
    return lines
end

return RTS
