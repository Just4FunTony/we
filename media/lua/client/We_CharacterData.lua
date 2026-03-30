-- We: Character data manager (client-side)
-- Handles saving, loading, appearance capture, and character switching.

WeData = WeData or {}

local modDataRef = nil   -- cached reference into getGameTime():getModData()

-- B42 CharacterStat enum map (replaces the old stats:getHunger() API)
local STAT_ENUM = {
    Hunger      = CharacterStat.HUNGER,
    Thirst      = CharacterStat.THIRST,
    Fatigue     = CharacterStat.FATIGUE,
    Boredom     = CharacterStat.BOREDOM,
    Stress      = CharacterStat.STRESS,
    Pain        = CharacterStat.PAIN,
    Unhappiness = CharacterStat.UNHAPPINESS,
}

-- ─── Internal helpers ──────────────────────────────────────────────────────────

local function getPlayer()
    return getSpecificPlayer(0)
end

local function ensureModData()
    if modDataRef then return modDataRef end
    local md = getGameTime():getModData()
    if not md[We.MOD_DATA_KEY] then
        md[We.MOD_DATA_KEY] = {
            activeSlot = 1,
            homeX = nil, homeY = nil, homeZ = nil,
            slots  = {},
        }
        for i = 1, We.MAX_SLOTS do
            md[We.MOD_DATA_KEY].slots[i] = We.defaultSlot(i)
        end
    end
    modDataRef = md[We.MOD_DATA_KEY]
    return modDataRef
end

-- ─── Public API ────────────────────────────────────────────────────────────────

function WeData.init()
    modDataRef = nil   -- force re-fetch on game load
    local data = ensureModData()
    for i = 1, We.MAX_SLOTS do
        if not data.slots[i] then
            data.slots[i] = We.defaultSlot(i)
        else
            if not data.slots[i].appearance then
                data.slots[i].appearance = We.defaultSlot(i).appearance
            elseif not data.slots[i].appearance.itemVisuals then
                -- Migrate old saves that used the clothing{} dict format
                data.slots[i].appearance.itemVisuals = {}
            end
        end
    end
    print("[We] CharacterData initialised. Active slot: " .. data.activeSlot)
end

function WeData.getData()
    return ensureModData()
end

function WeData.getActiveSlot()
    return ensureModData().activeSlot
end

function WeData.getSlot(index)
    return ensureModData().slots[index]
end

function WeData.renameSlot(index, name)
    ensureModData().slots[index].name = name
end

function WeData.setHome(x, y, z)
    local data = ensureModData()
    data.homeX = x
    data.homeY = y
    data.homeZ = z
    print("[We] Home set → " .. x .. "," .. y .. "," .. z)
end

function WeData.clearHome()
    local data = ensureModData()
    data.homeX = nil
    data.homeY = nil
    data.homeZ = nil
end

-- Returns true if switching is allowed at the player's current position.
-- Multiplayer: must be inside a PZ safehouse the player owns/belongs to.
-- Singleplayer: must have a home set and be within HOME_SWITCH_RADIUS tiles.
function WeData.isAtHomeBase()
    local player = getPlayer()
    if not player then return false end

    local isMP = getWorld and getWorld():getGameMode() == "Multiplayer"

    if isMP then
        local sq = player.getCurrentSquare and player:getCurrentSquare()
        if sq and SafeHouse.isSafeHouse and SafeHouse.isSafeHouse(sq, player:getUsername(), true) then
            return true
        end
        return false
    end

    -- SP: radius check from home point
    local data = ensureModData()
    if not data.homeX then
        return false
    end

    local px, py = player:getX(), player:getY()
    local dx = px - data.homeX
    local dy = py - data.homeY
    local dist2  = dx * dx + dy * dy
    local limit2 = We.HOME_SWITCH_RADIUS * We.HOME_SWITCH_RADIUS
    local ok = dist2 <= limit2
    return ok
end

-- ─── Save slot ────────────────────────────────────────────────────────────────

function WeData.saveSlot(index)
    local player = getPlayer()
    if not player then return end

    local data  = ensureModData()
    local slot  = data.slots[index]
    local stats = player:getStats()
    local xpSys = player:getXp()

    -- Character name from descriptor (forename + surname)
    local desc = player:getDescriptor()
    if desc then
        local fore = desc:getForename() or ""
        local sur  = desc:getSurname()  or ""
        local full = (fore .. " " .. sur):match("^%s*(.-)%s*$")
        if full ~= "" then slot.name = full end
    end

    -- Position
    slot.x = player:getX()
    slot.y = player:getY()
    slot.z = player:getZ()

    -- Stats (B42 API: stats:get(CharacterStat.X))
    for _, key in ipairs(We.STATS_KEYS) do
        local statEnum = STAT_ENUM[key]
        if statEnum then
            slot.stats[key] = stats:get(statEnum)
        end
    end

    -- Inventory
    slot.inventory = {}
    local items = player:getInventory():getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        table.insert(slot.inventory, {
            fullType  = item:getFullType(),
            condition = item.getCondition and item:getCondition() or 100,
            uses      = item.getUsedDelta and item:getUsedDelta() or 0,
        })
    end

    -- Skills
    slot.skills = {}
    for i = 0, Perks.getMaxIndex() - 1 do
        local perk = Perks.fromIndex(i)
        slot.skills[i] = {
            level = player:getPerkLevel(perk),
            xp    = xpSys:getXP(perk),
        }
    end

    -- Profession
    if desc then
        local prof = desc:getCharacterProfession()
        slot.profession = prof and tostring(prof) or nil
    end

    -- Traits (stored as full "namespace:path" ResourceLocation strings)
    slot.traits = {}
    local knownTraits = player:getCharacterTraits():getKnownTraits()
    for i = 0, knownTraits:size() - 1 do
        local t = knownTraits:get(i)
        if t then
            local s = tostring(t)
            table.insert(slot.traits, s)
            print("[We] SaveTrait slot=" .. index .. " trait=" .. s)
        end
    end

    -- Appearance (for NPC dressing)
    slot.appearance = WeNPC.captureAppearance(player)

    print("[We] Slot " .. index .. " saved. traits=" .. #slot.traits)
end

-- ─── Load slot ────────────────────────────────────────────────────────────────

function WeData.loadSlot(index)
    local player = getPlayer()
    if not player then return end

    local slot = ensureModData().slots[index]
    if not slot or slot.x == nil then
        print("[We] Slot " .. index .. " has no saved data, skipping load.")
        return
    end

    local stats = player:getStats()
    local xpSys = player:getXp()

    -- Stats (B42 API: stats:set(CharacterStat.X, value))
    for _, key in ipairs(We.STATS_KEYS) do
        local statEnum = STAT_ENUM[key]
        if statEnum and slot.stats[key] then
            stats:set(statEnum, slot.stats[key])
        end
    end

    -- Position
    player:setX(slot.x)
    player:setY(slot.y)
    player:setZ(slot.z)

    -- Inventory + clothing
    if player.clearWornItems then player:clearWornItems() end
    player:getInventory():clear()
    for _, itemData in ipairs(slot.inventory) do
        local item = instanceItem(itemData.fullType)
        if item then
            if item.setCondition then item:setCondition(itemData.condition) end
            if item.setUsedDelta then item:setUsedDelta(itemData.uses) end
            player:getInventory():AddItem(item)
            -- Re-wear clothing items using each item's own body location
            local loc = item.getBodyLocation and item:getBodyLocation()
            if loc then
                pcall(player.setWornItem, player, loc, item)
            end
        end
    end

    -- Skills
    for i = 0, Perks.getMaxIndex() - 1 do
        local perk  = Perks.fromIndex(i)
        local saved = slot.skills[i]
        if saved then
            player:setPerkLevelDebug(perk, saved.level)
            xpSys:setXPToLevel(perk, saved.level)
        end
    end

    -- Profession
    if slot.profession then
        local desc = player:getDescriptor()
        if desc then
            local profEnum = CharacterProfession.get(ResourceLocation.of(slot.profession))
            if profEnum then desc:setCharacterProfession(profEnum) end
        end
    end

    -- Traits: CharacterTraitDefinition.get(rl):getType() is the confirmed working path
    -- (same pattern used in WeCharCreate.randomize via getTraits():get(i):getType()).
    if slot.traits then
        local knownTraits = player:getCharacterTraits():getKnownTraits()
        knownTraits:clear()
        for _, traitName in ipairs(slot.traits) do
            local rl       = ResourceLocation.of(traitName)
            local traitEnum
            local def = CharacterTraitDefinition.get and CharacterTraitDefinition.get(rl)
            if def then
                traitEnum = def:getType()
            elseif CharacterTrait and CharacterTrait.get then
                traitEnum = CharacterTrait.get(rl)
            end
            if traitEnum then
                knownTraits:add(traitEnum)
                print("[We] LoadTrait OK slot=" .. index .. " " .. traitName)
            else
                print("[We] LoadTrait MISS slot=" .. index .. " " .. traitName)
            end
        end
        print("[We] Traits loaded: " .. #slot.traits .. " saved, knownTraits size=" .. knownTraits:size())
    end

    -- Appearance: restore hair / skin / beard onto the player
    -- (clothing is re-worn below via the inventory restore)
    local app = slot.appearance
    if app then
        local vis = player:getHumanVisual()
        if vis then
            -- IsoPlayer uses setFemale(), not setFemaleEtc() (which is zombie-only)
            player:setFemale(app.female or false)
            local desc = player:getDescriptor()
            if desc then desc:setFemale(app.female or false) end

            if app.skinTexture and app.skinTexture ~= "" then
                vis:setSkinTextureName(app.skinTexture)
            end
            if app.hairStyle  then vis:setHairModel(app.hairStyle)  end
            if app.hairColor  then
                vis:setHairColor(ImmutableColor.new(app.hairColor.r, app.hairColor.g, app.hairColor.b, 1))
            end
            if app.beardStyle then vis:setBeardModel(app.beardStyle) end
            if app.beardColor then
                vis:setBeardColor(ImmutableColor.new(app.beardColor.r, app.beardColor.g, app.beardColor.b, 1))
            end
        end
        player:resetModelNextFrame()
        player:resetModel()
    end

    -- Refresh character info panel (traits / profession / avatar)
    local panel = getPlayerInfoPanel and getPlayerInfoPanel(0)
    if panel and panel.charScreen then
        panel.charScreen.refreshNeeded = true
    end

    print("[We] Slot " .. index .. " loaded.")
end

-- ─── Switch ───────────────────────────────────────────────────────────────────

function WeData.switchTo(index)
    local data = ensureModData()
    if index == data.activeSlot then return end

    local ok = WeData.isAtHomeBase()
    if not ok then
        local player = getPlayer()
        if player then
            HaloTextHelper.addBadText(player, We.getText("UI_We_Switch_noSafehouse"))
        end
        return
    end

    local prev = data.activeSlot

    WeData.saveSlot(prev)

    if data.slots[index].npcId then
        WeNPC.despawnForSlot(index)
    end

    if data.slots[prev].x ~= nil then
        WeNPC.spawnForSlot(prev)
    end

    -- For a new character: randomize BEFORE setting activeSlot so that any
    -- OnSave event firing mid-switch doesn't capture the old character's traits.
    local player = getPlayer()
    if data.slots[index].x == nil then
        if player then
            local summary = WeCharCreate.randomize(player)
            data.activeSlot = index            -- set NOW, after traits are ready
            data.slots[index].creation = summary
            if summary.charName then
                data.slots[index].name = summary.charName
            end
            WeData.saveSlot(index)
            WeCharCreate.showPopup(summary)
        end
        print("[We] New character created for slot " .. index)
    else
        data.activeSlot = index
        WeData.loadSlot(index)
    end

    if player then
        HaloTextHelper.addGoodText(player, We.getText("UI_We_SwitchedTo") .. data.slots[index].name)
    end
end

-- ─── Auto-save on game write ──────────────────────────────────────────────────

local function onSave()
    local data = ensureModData()
    WeData.saveSlot(data.activeSlot)
end

Events.OnSave.Add(onSave)
