-- We: Character data manager (client-side)
-- Handles saving, loading, appearance capture, and character switching.

WeData = WeData or {}

local modDataRef = nil   -- cached reference into getGameTime():getModData()

-- B42 CharacterStat enum map (replaces the old stats:getHunger() API)
local STAT_ENUM = {
    Hunger      = CharacterStat.HUNGER,
    Thirst      = CharacterStat.THIRST,
    Fatigue     = CharacterStat.FATIGUE,
    Endurance   = CharacterStat.ENDURANCE,
    Boredom     = CharacterStat.BOREDOM,
    Stress      = CharacterStat.STRESS,
    Pain        = CharacterStat.PAIN,
    Unhappiness = CharacterStat.UNHAPPINESS,
}

-- ─── Trait dump helper ────────────────────────────────────────────────────────

local function dumpTraits(label, player)
    local kt = player:getCharacterTraits():getKnownTraits()
    local names = {}
    for i = 0, kt:size() - 1 do
        local t = kt:get(i)
        if t then names[#names+1] = tostring(t) end
    end
    local desc = player:getDescriptor()
    local prof = desc and desc:getCharacterProfession()
    print("[We] " .. label
        .. " | live traits=" .. kt:size()
        .. " | prof=" .. tostring(prof)
        .. " | list=[" .. table.concat(names, ", ") .. "]")
end

local function dumpSlot(label, slot)
    local traits = slot.traits or {}
    local names = {}
    for _, t in ipairs(traits) do names[#names+1] = t end
    print("[We] " .. label
        .. " | slot.traits=" .. #traits
        .. " | slot.prof=" .. tostring(slot.profession)
        .. " | list=[" .. table.concat(names, ", ") .. "]")
end

local function summarizeTraits(traits)
    if not traits then return "[]" end
    local out = {}
    local maxCount = 12
    for i, t in ipairs(traits) do
        if i > maxCount then
            out[#out + 1] = "...(" .. tostring(#traits - maxCount) .. " more)"
            break
        end
        out[#out + 1] = tostring(t)
    end
    return "[" .. table.concat(out, ", ") .. "]"
end

local function getPerkLevelSafe(player, perkObj, perkType)
    local v1 = 0
    local v2 = 0
    if perkObj then
        local ok1, r1 = pcall(player.getPerkLevel, player, perkObj)
        if ok1 and r1 then v1 = tonumber(r1) or 0 end
    end
    if perkType then
        local ok2, r2 = pcall(player.getPerkLevel, player, perkType)
        if ok2 and r2 then v2 = tonumber(r2) or 0 end
    end
    return math.max(v1, v2)
end

local function getPerkXPSafe(xpSys, perkObj, perkType)
    local v1 = 0
    local v2 = 0
    if perkObj then
        local ok1, r1 = pcall(xpSys.getXP, xpSys, perkObj)
        if ok1 and r1 then v1 = tonumber(r1) or 0 end
    end
    if perkType then
        local ok2, r2 = pcall(xpSys.getXP, xpSys, perkType)
        if ok2 and r2 then v2 = tonumber(r2) or 0 end
    end
    return math.max(v1, v2)
end

local function applySavedSkillsForSlot(player, slot)
    if not player or not slot then return end
    local xpSys = player:getXp()
    for i = 1, Perks.getMaxIndex() do
        local perkType = Perks.fromIndex(i - 1)
        local perk = PerkFactory.getPerk(perkType)
        if perk and perk:getParent() ~= Perks.None then
            local perkKey = tostring(perkType or perk)
            local saved = (slot.skillsByName and slot.skillsByName[perkKey])
                or (slot.skills and (slot.skills[tostring(i - 1)] or slot.skills[i - 1]))
            if not saved and slot.skillsList then
                for _, entry in ipairs(slot.skillsList) do
                    if entry and (entry.perk == perkKey or tonumber(entry.idx) == (i - 1)) then
                        saved = entry
                        break
                    end
                end
            end
            if saved then
                pcall(player.setPerkLevelDebug, player, perkType, saved.level or 0)
                pcall(xpSys.setXPToLevel, xpSys, perkType, saved.level or 0)
                if saved.xp ~= nil then
                    local curXP = getPerkXPSafe(xpSys, perkType, perkType)
                    local delta = (saved.xp or 0) - (curXP or 0)
                    if delta > 0 then
                        pcall(xpSys.AddXP, xpSys, perkType, delta, false, false, false, false)
                    end
                end
            end
        end
    end
end

local pendingSkillRestore = nil
local function onTickReapplySkills()
    if not pendingSkillRestore then return end
    pendingSkillRestore.ticks = pendingSkillRestore.ticks - 1
    if pendingSkillRestore.ticks > 0 then return end
    local player = getSpecificPlayer(0)
    local data = WeData and WeData.getData and WeData.getData()
    local slot = data and data.slots and data.slots[pendingSkillRestore.slotIndex]
    if player and slot then
        applySavedSkillsForSlot(player, slot)
    end
    pendingSkillRestore = nil
end

local function applyTraitsLocally(player, professionRL, traitNames, sourceLabel)
    if not player then return end

    local desc = player:getDescriptor()
    if professionRL and desc then
        local prof = CharacterProfession.get(ResourceLocation.of(professionRL))
        if prof then
            desc:setCharacterProfession(prof)
        end
    end

    local traitEnums = {}
    local charTraits = player:getCharacterTraits()
    local knownTraits = charTraits:getKnownTraits()
    for _, traitName in ipairs(traitNames or {}) do
        local traitType = CharacterTrait.get(ResourceLocation.of(traitName))
        if traitType then
            traitEnums[#traitEnums + 1] = traitType
        end
    end

    -- B42 canonical path: mutate CharacterTraits object via remove/add.
    local toRemove = {}
    for i = 0, knownTraits:size() - 1 do
        local t = knownTraits:get(i)
        if t then
            toRemove[#toRemove + 1] = t
        end
    end
    for _, t in ipairs(toRemove) do
        pcall(charTraits.remove, charTraits, t)
    end
    for _, t in ipairs(traitEnums) do
        pcall(charTraits.add, charTraits, t)
    end

    -- Keep this too for UI/systems reading the raw trait collection.
    local runtimeTraits = player.getTraits and player:getTraits()
    if runtimeTraits then
        if runtimeTraits.clear then runtimeTraits:clear() end
        for _, traitType in ipairs(traitEnums) do
            if runtimeTraits.add then
                runtimeTraits:add(traitType)
            end
        end
    end

    dumpTraits("local apply " .. tostring(sourceLabel) .. " AFTER", player)
    local panel = getPlayerInfoPanel and getPlayerInfoPanel(0)
    if panel and panel.charScreen then
        panel.charScreen.refreshNeeded = true
    end
end

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
                data.slots[i].appearance.itemVisuals = {}
            end
        end
    end

    local player = getSpecificPlayer(0)
    print("[We] WeData.init: isClient=" .. tostring(isClient())
        .. " activeSlot=" .. data.activeSlot
        .. " player=" .. tostring(player ~= nil))

    if player then
        if isClient() then
            sendClientCommand(player, "We", "requestTraits", {slotIndex = data.activeSlot})
            print("[We] Init MP: sent requestTraits for slot " .. data.activeSlot)
        else
            -- SP: getKnownTraits() is the live reference (no snapshot problem).
            local slot = data.slots[data.activeSlot]
            if slot then
                dumpSlot("Init SP slot" .. data.activeSlot .. " BEFORE", slot)
                dumpTraits("Init SP player BEFORE", player)

                if not slot.traits or #slot.traits == 0 then
                    -- First run: capture traits + profession from the player's current state.
                    slot.traits = {}
                    local knownTraits = player:getCharacterTraits():getKnownTraits()
                    for i = 0, knownTraits:size() - 1 do
                        local t = knownTraits:get(i)
                        if t then table.insert(slot.traits, tostring(t)) end
                    end
                    local desc = player:getDescriptor()
                    if desc then
                        -- Seed default slot name from descriptor once (for legacy saves where
                        -- slot still has "Character N"). Keep stable afterwards.
                        local curName = tostring(slot.name or "")
                        if curName == "" or curName == ("Character " .. tostring(data.activeSlot)) then
                            local fore = desc:getForename() or ""
                            local sur  = desc:getSurname() or ""
                            local full = (fore .. " " .. sur):match("^%s*(.-)%s*$")
                            if full and full ~= "" then
                                slot.name = full
                            end
                        end
                        local prof = desc:getCharacterProfession()
                        if prof then slot.profession = tostring(prof) end
                    end
                    dumpSlot("Init SP slot" .. data.activeSlot .. " CAPTURED", slot)
                else
                    -- Subsequent runs: re-apply saved traits via server (clear()+add() on
                    -- client getKnownTraits() is a no-op — server path is the only one that works).
                    sendClientCommand(player, "We", "applyTraits", {
                        slotIndex  = data.activeSlot,
                        profession = slot.profession,
                        traits     = slot.traits or {},
                    })
                    print("[We] Init SP: sent applyTraits for slot " .. data.activeSlot
                        .. " count=" .. #(slot.traits or {}))
                    print("[We][TraitsFlow] init -> applyTraits"
                        .. " | activeSlot=" .. tostring(data.activeSlot)
                        .. " | reqSlot=" .. tostring(data.activeSlot)
                        .. " | prof=" .. tostring(slot.profession)
                        .. " | traits=" .. summarizeTraits(slot.traits or {}))
                    dumpSlot("Init SP slot" .. data.activeSlot .. " queued", slot)
                end
            else
                print("[We] Init SP: slot " .. data.activeSlot .. " is nil!")
            end
        end
    else
        print("[We] Init: player is nil, skipping trait init")
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

    if isClient() then
        -- MP: check if the player's current square is inside a safehouse they own or belong to.
        -- Avoid username string comparison — B42 prepends a slot number (e.g. "4Tony") which
        -- may not match the username stored in the safehouse record.
        local sq = player.getCurrentSquare and player:getCurrentSquare()
        if not sq then
            print("[We] isAtHomeBase MP: no current square")
            return false
        end
        -- getSafeHouse returns the safehouse object at the square (nil if not in one).
        local sh = SafeHouse.getSafeHouse and SafeHouse.getSafeHouse(sq)
        if not sh then
            print("[We] isAtHomeBase MP: square not in a safehouse")
            return false
        end
        -- hasSafehouse returns the safehouse object the player owns (nil if none).
        local playerSH = SafeHouse.hasSafehouse and SafeHouse.hasSafehouse(player)
        if playerSH and sh == playerSH then
            print("[We] isAtHomeBase MP: owner match, OK")
            return true
        end
        -- Member check: strip numeric slot prefix from username (B42 adds e.g. "4" prefix).
        local username = player:getUsername()
        local stripped = username:match("^%d+(.+)$") or username
        local result = SafeHouse.isSafeHouse(sq, stripped, false)
                    or SafeHouse.isSafeHouse(sq, username, false)
        print("[We] isAtHomeBase MP: member check username=" .. username
            .. " stripped=" .. stripped .. " result=" .. tostring(result))
        return result
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
    -- Skip saves that fire before WeData.init() — modDataRef is nil until init runs.
    -- An early OnSave (f:0) would read stale player state (wrong slot's traits/profession)
    -- and corrupt the stored data for the slot.
    if not modDataRef then
        print("[We] saveSlot(" .. tostring(index) .. "): skipped — modDataRef nil (pre-init)")
        return
    end
    local player = getPlayer()
    if not player then return end

    local data  = ensureModData()
    local slot  = data.slots[index]
    local stats = player:getStats()
    local xpSys = player:getXp()

    -- Keep slot.name stable. It is set on character creation (or explicit rename) and
    -- must not be overwritten from whichever descriptor is currently active during save.
    local desc = player:getDescriptor()

    -- Position
    slot.x = player:getX()
    slot.y = player:getY()
    slot.z = player:getZ()
    slot.temperature = player.getTemperature and player:getTemperature() or slot.temperature

    -- Stats (B42 API: stats:get(CharacterStat.X))
    for _, key in ipairs(We.STATS_KEYS) do
        local statEnum = STAT_ENUM[key]
        if statEnum then
            slot.stats[key] = tonumber(stats:get(statEnum)) or 0
        end
    end

    -- Save current moodle levels for accurate inactive-slot UI.
    local moodles = player:getMoodles()
    slot.moodles = {
        Hungry = moodles and (moodles:getMoodleLevel(MoodleType.HUNGRY) or 0) or 0,
        Thirst = moodles and (moodles:getMoodleLevel(MoodleType.THIRST) or 0) or 0,
        Endurance = moodles and (moodles:getMoodleLevel(MoodleType.ENDURANCE) or 0) or 0,
        Tired  = moodles and (moodles:getMoodleLevel(MoodleType.TIRED) or 0) or 0,
        Stress = moodles and (moodles:getMoodleLevel(MoodleType.STRESS) or 0) or 0,
        Pain   = moodles and (moodles:getMoodleLevel(MoodleType.PAIN) or 0) or 0,
        Bored  = moodles and (moodles:getMoodleLevel(MoodleType.BORED) or 0) or 0,
        Unhappy = moodles and (moodles:getMoodleLevel(MoodleType.UNHAPPY) or 0) or 0,
        Panic = moodles and (moodles:getMoodleLevel(MoodleType.PANIC) or 0) or 0,
        Sick = moodles and (moodles:getMoodleLevel(MoodleType.SICK) or 0) or 0,
        Hyperthermia = moodles and (moodles:getMoodleLevel(MoodleType.HYPERTHERMIA) or 0) or 0,
        Hypothermia = moodles and (moodles:getMoodleLevel(MoodleType.HYPOTHERMIA) or 0) or 0,
        HeavyLoad = moodles and (moodles:getMoodleLevel(MoodleType.HEAVY_LOAD) or 0) or 0,
    }

    -- Inventory
    slot.inventory = {}

    -- Worn clothing: use getItemVisuals + getLastStandString to preserve color tinting.
    local ivContainer = ItemVisuals and ItemVisuals.new()
    if ivContainer then
        player:getItemVisuals(ivContainer)
        for i = 0, ivContainer:size() - 1 do
            local iv = ivContainer:get(i)
            if iv then
                local s = iv.getLastStandString and iv:getLastStandString()
                if s then
                    table.insert(slot.inventory, { lastStandStr = s })
                end
            end
        end
    end

    -- Non-worn items (food, tools, weapons, etc.)
    local items = player:getInventory():getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local loc = item.getBodyLocation and item:getBodyLocation()
        if not loc then   -- skip worn clothing (already captured above)
            table.insert(slot.inventory, {
                fullType  = item:getFullType(),
                condition = item.getCondition and item:getCondition() or 100,
                uses      = item.getUsedDelta and item:getUsedDelta() or 0,
            })
        end
    end

    -- Skills (store as sequential list for serialization stability)
    slot.skills = {}
    slot.skillsByName = {}
    slot.skillsList = {}
    for i = 1, Perks.getMaxIndex() do
        local perkType = Perks.fromIndex(i - 1)
        local perk = PerkFactory.getPerk(perkType)
        if perk and perk:getParent() ~= Perks.None then
            local perkKey = tostring(perkType or perk)
            local skillEntry = {
                level = getPerkLevelSafe(player, perkType, perkType),
                xp    = getPerkXPSafe(xpSys, perkType, perkType),
                perk  = perkKey,
                idx   = i - 1,
            }
            slot.skills[tostring(i - 1)] = skillEntry
            slot.skillsByName[perkKey] = skillEntry
            table.insert(slot.skillsList, skillEntry)
        end
    end

    -- Body damage state
    slot.bodyDamage = {}
    local bdParts = player:getBodyDamage():getBodyParts()
    for i = 1, bdParts:size() do
        local bp = bdParts:get(i - 1)
        if bp then
            local entry = {}
            local isCut = bp.isCut and bp:isCut()
            if isCut then
                entry.cut = true
                if bp.getCutTime then entry.cutTime = bp:getCutTime() end
            end

            if bp.getScratchTime then
                local scratchTime = bp:getScratchTime()
                if scratchTime and scratchTime > 0 then
                    entry.scratch = true
                    entry.scratchTime = scratchTime
                end
            end

            if bp.getWoundInfectionLevel then
                local infLvl = bp:getWoundInfectionLevel()
                if infLvl and infLvl > 0 then entry.infLevel = infLvl end
            end

            if bp.getFractureTime then
                local fracTime = bp:getFractureTime()
                if fracTime and fracTime > 0 then
                    entry.fracture = true
                    entry.fracTime = fracTime
                end
            end

            local dwTime = bp.getDeepWoundTime and bp:getDeepWoundTime()
            if dwTime and dwTime > 0 then
                entry.deepWound = true
                entry.deepTime = dwTime
            end
            local hasDamageEntry = false
            for _ in pairs(entry) do
                hasDamageEntry = true
                break
            end
            if hasDamageEntry then
                slot.bodyDamage[i - 1] = entry
            end
        end
    end

    -- Profession (read from descriptor — this is safe because saveSlot is only called
    -- while the player is actively playing this slot, not mid-switch)
    if desc then
        local prof = desc:getCharacterProfession()
        slot.profession = prof and tostring(prof) or nil
    end

    -- Traits: slot.traits is the authoritative source.
    -- It is written only at character creation (randomize) and at init (first-run capture).
    -- Do NOT read getKnownTraits() here — saveSlot can fire while the player is mid-switch
    -- (e.g. OnSave before init, or right after loadSlot applied a different slot's traits),
    -- which would corrupt slot.traits with the wrong character's data.

    -- Appearance (for NPC dressing)
    slot.appearance = WeNPC.captureAppearance(player)

    dumpSlot("saveSlot(" .. index .. ")", slot)
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

    print("[We] loadSlot(" .. index .. "): isClient=" .. tostring(isClient()))
    dumpSlot("loadSlot(" .. index .. ") slot", slot)
    dumpTraits("loadSlot(" .. index .. ") player BEFORE", player)

    local desc = player:getDescriptor()
    if desc and slot.name and slot.name ~= "" then
        local fore, sur = tostring(slot.name):match("^%s*(%S+)%s+(.+)%s*$")
        if not fore then
            fore = tostring(slot.name):match("^%s*(.-)%s*$")
            sur = ""
        end
        if fore and fore ~= "" then
            desc:setForename(fore)
            desc:setSurname(sur or "")
        end
    end

    local stats = player:getStats()
    local xpSys = player:getXp()

    local function applySavedStats()
        for _, key in ipairs(We.STATS_KEYS) do
            local statEnum = STAT_ENUM[key]
            if statEnum and slot.stats[key] ~= nil then
                stats:set(statEnum, tonumber(slot.stats[key]) or 0)
            end
        end
    end

    -- Stats (B42 API: stats:set(CharacterStat.X, value))
    applySavedStats()

    -- Position
    player:setX(slot.x)
    player:setY(slot.y)
    player:setZ(slot.z)

    -- Inventory + clothing
    if player.clearWornItems then player:clearWornItems() end
    player:getInventory():clear()
    for _, itemData in ipairs(slot.inventory) do
        if itemData.lastStandStr then
            local item = ItemVisual.createLastStandItem and ItemVisual.createLastStandItem(itemData.lastStandStr)
            if item then
                player:getInventory():AddItem(item)
                local loc = item.getBodyLocation and item:getBodyLocation()
                if loc then pcall(player.setWornItem, player, loc, item) end
            end
        else
            local item = instanceItem(itemData.fullType)
            if item then
                if item.setCondition then item:setCondition(itemData.condition) end
                if item.setUsedDelta then item:setUsedDelta(itemData.uses) end
                player:getInventory():AddItem(item)
            end
        end
    end

    -- Body damage: always restore to full health first (prevents wound transfer),
    -- then re-apply this slot's saved wounds.
    local bd = player:getBodyDamage()
    bd:RestoreToFullHealth()
    if slot.bodyDamage then
        local bdParts = bd:getBodyParts()
        for i = 1, bdParts:size() do
            local bp = bdParts:get(i - 1)
            local saved = slot.bodyDamage[i - 1]
            if bp and saved then
                if saved.cut then
                    bp:setCut(true)
                    if saved.cutTime then bp:setCutTime(saved.cutTime) end
                end
                if saved.scratch then
                    bp:setScratched(true, false)
                    if saved.scratchTime then bp:setScratchTime(saved.scratchTime) end
                end
                if saved.infLevel and saved.infLevel > 0 then
                    bp:setWoundInfectionLevel(saved.infLevel)
                end
                if saved.fracture then
                    bp:setFractureTime(saved.fracTime or 21)
                end
                if saved.deepWound then
                    bp:generateDeepWound()
                    if bp.setDeepWoundTime and saved.deepTime then bp:setDeepWoundTime(saved.deepTime) end
                end
            end
        end
    end

    -- Skills
    applySavedSkillsForSlot(player, slot)

    -- Profession + traits: always route through server.
    -- SP: server applies to the server-side player and refreshes the Info panel directly.
    -- MP: server applies and sends traitsApplied back.
    -- (client-side getKnownTraits() is always a read-only snapshot — clear()+add() is a no-op)
    if slot.profession or (slot.traits and #slot.traits > 0) then
        -- B42 SP: ensure the currently active local player object is updated immediately.
        applyTraitsLocally(player, slot.profession, slot.traits or {}, "loadSlot(" .. index .. ")")

        sendClientCommand(player, "We", "applyTraits", {
            slotIndex  = index,
            profession = slot.profession,
            traits     = slot.traits or {},
        })
        print("[We] loadSlot(" .. index .. "): sent applyTraits, traits=" .. #(slot.traits or {}))
        print("[We][TraitsFlow] loadSlot -> applyTraits"
            .. " | activeSlot=" .. tostring(ensureModData().activeSlot)
            .. " | reqSlot=" .. tostring(index)
            .. " | prof=" .. tostring(slot.profession)
            .. " | traits=" .. summarizeTraits(slot.traits or {}))
    end

    -- Appearance: restore hair / skin / beard onto the player
    local app = slot.appearance
    if app then
        local vis = player:getHumanVisual()
        if vis then
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

    -- Re-apply stats after inventory/trait/model updates to avoid engine overwrites on load.
    applySavedStats()
    -- Re-apply skills after trait/profession updates that may touch perk state.
    applySavedSkillsForSlot(player, slot)
    pendingSkillRestore = { slotIndex = index, ticks = 10 }
    if slot.temperature ~= nil and player.setTemperature then
        player:setTemperature(slot.temperature)
    end
    local moodlesNow = player:getMoodles()
    slot.moodles = slot.moodles or {}
    if moodlesNow then
        slot.moodles.Hungry = moodlesNow:getMoodleLevel(MoodleType.HUNGRY) or 0
        slot.moodles.Thirst = moodlesNow:getMoodleLevel(MoodleType.THIRST) or 0
        slot.moodles.Endurance = moodlesNow:getMoodleLevel(MoodleType.ENDURANCE) or 0
        slot.moodles.Tired = moodlesNow:getMoodleLevel(MoodleType.TIRED) or 0
        slot.moodles.Stress = moodlesNow:getMoodleLevel(MoodleType.STRESS) or 0
        slot.moodles.Pain = moodlesNow:getMoodleLevel(MoodleType.PAIN) or 0
        slot.moodles.Bored = moodlesNow:getMoodleLevel(MoodleType.BORED) or 0
        slot.moodles.Unhappy = moodlesNow:getMoodleLevel(MoodleType.UNHAPPY) or 0
        slot.moodles.Panic = moodlesNow:getMoodleLevel(MoodleType.PANIC) or 0
        slot.moodles.Sick = moodlesNow:getMoodleLevel(MoodleType.SICK) or 0
        slot.moodles.Hyperthermia = moodlesNow:getMoodleLevel(MoodleType.HYPERTHERMIA) or 0
        slot.moodles.Hypothermia = moodlesNow:getMoodleLevel(MoodleType.HYPOTHERMIA) or 0
        slot.moodles.HeavyLoad = moodlesNow:getMoodleLevel(MoodleType.HEAVY_LOAD) or 0
    end

    print("[We] Slot " .. index .. " loaded.")
end

-- ─── Kill slot (NPC died) ─────────────────────────────────────────────────────

function WeData.killSlot(index)
    local data = ensureModData()
    local slot = data.slots[index]
    if not slot then return end

    slot.x = nil
    slot.y = nil
    slot.z = nil
    slot.npcId = nil
    WeNPC.Cache[index] = nil

    print("[We] Slot " .. index .. " killed (NPC died).")
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
    print("[We] switchTo: " .. prev .. " → " .. index)
    print("[We][TraitsFlow] switchTo begin"
        .. " | prev=" .. tostring(prev)
        .. " | target=" .. tostring(index)
        .. " | prevTraits=" .. summarizeTraits((data.slots[prev] and data.slots[prev].traits) or {})
        .. " | targetTraitsBefore=" .. summarizeTraits((data.slots[index] and data.slots[index].traits) or {}))

    WeData.saveSlot(prev)

    -- Entering this character: always try to use resident's live location.
    local targetResidentX, targetResidentY, targetResidentZ =
        WeNPC.getResidentPosition and WeNPC.getResidentPosition(index)
    if targetResidentX and targetResidentY then
        data.slots[index].x = targetResidentX
        data.slots[index].y = targetResidentY
        data.slots[index].z = targetResidentZ or data.slots[index].z or 0
        print("[We] switchTo: updated target slot " .. index .. " position from resident (" ..
            tostring(targetResidentX) .. "," .. tostring(targetResidentY) .. "," .. tostring(targetResidentZ) .. ")")
    end

    if data.slots[index].npcId or targetResidentX then
        WeNPC.despawnForSlot(index)
    end

    if data.slots[prev].x ~= nil then
        WeNPC.spawnForSlot(prev)
    end

    local player = getPlayer()
    if data.slots[index].x == nil then
        -- New character slot
        if player then
            print("[We] switchTo: creating new char for slot " .. index)
            dumpTraits("switchTo new-char player BEFORE randomize", player)
            local summary = WeCharCreate.randomize(player, index)
            dumpTraits("switchTo new-char player AFTER randomize", player)
            data.activeSlot = index
            data.slots[index].creation = summary
            if summary.charName then
                data.slots[index].name = summary.charName
            end
            -- Write traits directly from summary — getKnownTraits() is a snapshot on the
            -- client and won't reflect the server-side applyTraits command yet.
            data.slots[index].traits     = summary.savedTraits or {}
            data.slots[index].profession = summary.profRL
            print("[We] switchTo: slot" .. index .. " traits set from summary, count=" .. #(summary.savedTraits or {}))
            -- Save position/stats for the new character
            local s = player:getStats()
            local slot = data.slots[index]
            slot.x = player:getX()
            slot.y = player:getY()
            slot.z = player:getZ()
            for _, key in ipairs(We.STATS_KEYS) do
                local statEnum = STAT_ENUM[key]
                if statEnum then slot.stats[key] = s:get(statEnum) end
            end
            slot.appearance = WeNPC.captureAppearance(player)
            -- No creation popup by request.
        end
        print("[We] New character created for slot " .. index)
    else
        print("[We] switchTo: loading existing slot " .. index)
        data.activeSlot = index
        WeData.loadSlot(index)
    end
    print("[We][TraitsFlow] switchTo end"
        .. " | activeSlot=" .. tostring(data.activeSlot)
        .. " | activeTraits=" .. summarizeTraits((data.slots[data.activeSlot] and data.slots[data.activeSlot].traits) or {}))

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
Events.OnTick.Add(onTickReapplySkills)

-- ─── OnServerCommand — receive traitsApplied confirmation from server ──────────

local function onServerCommand(module, command, args)
    if module ~= "We" then return end
    if command ~= "traitsApplied" then return end

    local slotIndex = args.slotIndex
    if not slotIndex then return end

    print("[We] OnServerCommand traitsApplied: slot=" .. slotIndex
        .. " traits=" .. #(args.traits or {})
        .. " prof=" .. tostring(args.profession))

    local data = ensureModData()
    local slot = data.slots[slotIndex]
    if slot then
        slot.traits     = args.traits or {}
        slot.profession = args.profession or slot.profession
        dumpSlot("traitsApplied slot" .. slotIndex, slot)
        print("[We][TraitsFlow] traitsApplied recv"
            .. " | recvSlot=" .. tostring(slotIndex)
            .. " | activeSlot=" .. tostring(data.activeSlot)
            .. " | prof=" .. tostring(slot.profession)
            .. " | traits=" .. summarizeTraits(slot.traits))
    end

    local panel = getPlayerInfoPanel and getPlayerInfoPanel(0)
    if panel and panel.charScreen then
        panel.charScreen.refreshNeeded = true
    end
end

Events.OnServerCommand.Add(onServerCommand)
