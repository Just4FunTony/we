-- We: Character data manager (client-side)
-- Handles saving, loading, and switching between character slots.

WeData = WeData or {}

local modDataRef = nil   -- direct reference into getGameTime():getModData()

-- ─── Internal helpers ───────────────────────────────────────────────────────

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

-- ─── Public API ─────────────────────────────────────────────────────────────

function WeData.init()
    modDataRef = nil  -- force re-fetch on game load
    local data = ensureModData()
    -- Fill in any missing slots (e.g. after MAX_SLOTS was increased)
    for i = 1, We.MAX_SLOTS do
        if not data.slots[i] then
            data.slots[i] = We.defaultSlot(i)
        end
    end
    print("[We] CharacterData initialised. Active slot: " .. data.activeSlot)
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

-- Save the current player state into the given slot.
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

    print("[We] Slot " .. index .. " saved.")
end

-- Restore player state from the given slot.
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

    -- Position (find nearest safe tile to avoid spawning inside walls)
    local safeX, safeY, safeZ = slot.x, slot.y, slot.z
    player:setX(safeX)
    player:setY(safeY)
    player:setZ(safeZ)
    player:resetMoveSpeed()

    -- Inventory
    player:getInventory():clear()
    for _, itemData in ipairs(slot.inventory) do
        local item = InventoryItemFactory.CreateItem(itemData.fullType)
        if item then
            item:setCondition(itemData.condition)
            item:setUsedDelta(itemData.uses)
            player:getInventory():AddItem(item)
        end
    end

    -- Skills
    local perks = Perks.getList()
    for i = 0, perks:size() - 1 do
        local perk    = perks:get(i)
        local key     = tostring(perk)
        local saved   = slot.skills[key]
        if saved then
            xpSys:setCurrentLevel(perk, saved.level)
            local delta = saved.xp - xpSys:getXP(perk)
            if delta > 0 then
                xpSys:AddXP(perk, delta)
            end
        end
    end

    print("[We] Slot " .. index .. " loaded.")
end

-- Save current slot, then load the target slot.
function WeData.switchTo(index)
    local data = ensureModData()
    if index == data.activeSlot then return end
    if data.slots[index].x == nil then
        -- First time visiting this slot: just move there without restoring
        WeData.saveSlot(data.activeSlot)
        data.activeSlot = index
        -- Save an initial snapshot so the slot is no longer "empty"
        WeData.saveSlot(index)
        print("[We] Switched to new slot " .. index)
    else
        WeData.saveSlot(data.activeSlot)
        data.activeSlot = index
        WeData.loadSlot(index)
    end
    -- Feedback text above the player
    local player = getPlayer()
    if player then
        HaloTextHelper.addTextWithArrow(player, getText("UI_We_SwitchedTo") .. data.slots[index].name, HaloTextHelper.getColorGreen())
    end
end

-- Ensure the active slot is saved before the game writes to disk.
local function onSave()
    WeData.saveSlot(ensureModData().activeSlot)
end
Events.OnSave.Add(onSave)
