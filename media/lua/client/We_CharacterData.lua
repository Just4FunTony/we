-- We: Character data manager (client-side)
-- Handles saving, loading, appearance capture, and character switching.

WeData = WeData or {}

local modDataRef = nil   -- cached reference into getGameTime():getModData()

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
            slots      = {},
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
            -- Back-fill fields added in v2
            if not data.slots[i].appearance then
                data.slots[i].appearance = We.defaultSlot(i).appearance
            end
            if data.slots[i].homeX == nil then
                data.slots[i].homeX = nil
                data.slots[i].homeY = nil
                data.slots[i].homeZ = nil
            end
            if data.slots[i].npcId == nil then
                data.slots[i].npcId = nil
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

function WeData.setHome(slotIndex, x, y, z)
    local slot  = ensureModData().slots[slotIndex]
    slot.homeX  = x
    slot.homeY  = y
    slot.homeZ  = z
    print("[We] Home set for slot " .. slotIndex .. " → " .. x .. "," .. y .. "," .. z)
end

-- ─── Save slot ────────────────────────────────────────────────────────────────

function WeData.saveSlot(index)
    local player = getPlayer()
    if not player then return end

    local data  = ensureModData()
    local slot  = data.slots[index]
    local stats = player:getStats()
    local xpSys = player:getXp()

    -- Position
    slot.x = player:getX()
    slot.y = player:getY()
    slot.z = player:getZ()

    -- Stats
    for _, key in ipairs(We.STATS_KEYS) do
        slot.stats[key] = stats["get" .. key](stats)
    end

    -- Inventory
    slot.inventory = {}
    local items = player:getInventory():getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        table.insert(slot.inventory, {
            fullType  = item:getFullType(),
            condition = item:getCondition(),
            uses      = item:getUsedDelta(),
        })
    end

    -- Skills
    slot.skills = {}
    local perks = Perks.getList()
    for i = 0, perks:size() - 1 do
        local perk = perks:get(i)
        local key  = tostring(perk)
        slot.skills[key] = {
            level = xpSys:getPerkLevel(perk),
            xp    = xpSys:getXP(perk),
        }
    end

    -- Appearance (for NPC dressing)
    slot.appearance = WeNPC.captureAppearance(player)

    print("[We] Slot " .. index .. " saved.")
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

    -- Stats
    for _, key in ipairs(We.STATS_KEYS) do
        if slot.stats[key] then
            stats["set" .. key](stats, slot.stats[key])
        end
    end

    -- Position
    player:setX(slot.x)
    player:setY(slot.y)
    player:setZ(slot.z)
    player:resetMoveSpeed()

    -- Inventory
    player:getInventory():clear()
    for _, itemData in ipairs(slot.inventory) do
        local item = instanceItem(itemData.fullType)
        if item then
            item:setCondition(itemData.condition)
            item:setUsedDelta(itemData.uses)
            player:getInventory():AddItem(item)
        end
    end

    -- Skills
    local perks = Perks.getList()
    for i = 0, perks:size() - 1 do
        local perk  = perks:get(i)
        local key   = tostring(perk)
        local saved = slot.skills[key]
        if saved then
            xpSys:setCurrentLevel(perk, saved.level)
            local delta = saved.xp - xpSys:getXP(perk)
            if delta > 0 then xpSys:AddXP(perk, delta) end
        end
    end

    print("[We] Slot " .. index .. " loaded.")
end

-- ─── Base proximity check ────────────────────────────────────────────────────

-- Returns true if the player is within We.HOME_SWITCH_RADIUS of their home base.
-- Also returns a status string for UI feedback.
function WeData.isAtHomeBase()
    local player = getPlayer()
    if not player then return false, "noPlayer" end

    local slot = ensureModData().slots[ensureModData().activeSlot]
    if not slot.homeX then
        return false, "noHome"
    end

    local dx   = player:getX() - slot.homeX
    local dy   = player:getY() - slot.homeY
    local dist = math.sqrt(dx * dx + dy * dy)

    if dist > We.HOME_SWITCH_RADIUS then
        return false, "tooFar"
    end

    return true, "ok"
end

-- ─── Switch ───────────────────────────────────────────────────────────────────

function WeData.switchTo(index)
    local data = ensureModData()
    if index == data.activeSlot then return end

    -- Must be at home base to switch characters
    local ok, reason = WeData.isAtHomeBase()
    if not ok then
        local player = getPlayer()
        if player then
            local msg = getText("UI_We_Switch_" .. reason)
            HaloTextHelper.addTextWithArrow(player, msg, HaloTextHelper.getColorRed())
        end
        return
    end

    local prev = data.activeSlot

    -- 1. Save the character we are leaving (captures appearance too)
    WeData.saveSlot(prev)

    -- 2. Despawn the NPC for the slot we are switching INTO (we are taking over)
    if data.slots[index].npcId then
        WeNPC.despawnForSlot(index)
    end

    -- 3. Spawn an NPC for the character we are leaving
    if data.slots[prev].x ~= nil then
        WeNPC.spawnForSlot(prev)
    end

    -- 4. Activate the new slot
    data.activeSlot = index

    -- 5. Load the target character or initialise a brand-new one
    local player = getPlayer()
    if data.slots[index].x == nil then
        -- First time in this slot: randomize profession + traits, then snapshot
        if player then
            local summary = WeCharCreate.randomize(player)
            data.slots[index].creation = summary
            WeData.saveSlot(index)
            WeCharCreate.showPopup(summary)
        end
        print("[We] New character created for slot " .. index)
    else
        WeData.loadSlot(index)
    end

    -- 6. Feedback text
    if player then
        HaloTextHelper.addTextWithArrow(
            player,
            getText("UI_We_SwitchedTo") .. data.slots[index].name,
            HaloTextHelper.getColorGreen()
        )
    end
end

-- ─── Auto-save on game write ──────────────────────────────────────────────────

local function onSave()
    local data = ensureModData()
    WeData.saveSlot(data.activeSlot)
end

Events.OnSave.Add(onSave)
