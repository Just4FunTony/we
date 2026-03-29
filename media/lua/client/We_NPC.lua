-- We: Client-side NPC manager.
-- Spawns, maintains, and despawns zombie stand-ins for inactive characters.
-- Uses only vanilla Project Zomboid B42 APIs.

WeNPC = WeNPC or {}

-- B42 body-location render order (determines clothing layer priority)
WeNPC.BODY_LOCATIONS = {
    "UnderwearBottom", "UnderwearTop", "UnderwearExtra1", "UnderwearExtra2", "Underwear",
    "Torso1Legs1", "Legs1",
    "Ears", "EarTop", "Nose", "Hat", "FullHat",
    "Mask", "MaskEyes", "Eyes", "RightEye", "LeftEye",
    "Neck", "Necklace", "Gorget", "Scarf",
    "TankTop", "Tshirt", "ShortSleeveShirt", "Shirt",
    "VestTexture", "Sweater", "SweaterHat", "TorsoExtraVest", "Cuirass", "TorsoExtra",
    "Jacket", "JacketHat", "Jacket_Down", "JacketHat_Bulky", "Jacket_Bulky", "JacketSuit", "FullTop",
    "RightWrist", "Right_MiddleFinger", "Right_RingFinger",
    "LeftWrist",  "Left_MiddleFinger",  "Left_RingFinger",
    "Hands", "HandsRight", "HandsLeft",
    "Pants", "PantsExtra", "ShortPants", "ShortsShort",
    "LongSkirt", "Skirt", "Dress", "LongDress",
    "BathRobe", "FullSuit", "FullSuitHead", "Boilersuit", "Tail", "TorsoExtraVestBullet",
    "ShoulderpadRight", "ShoulderpadLeft",
    "Elbow_Right", "Elbow_Left", "ForeArm_Right", "ForeArm_Left",
    "Thigh_Right", "Thigh_Left", "Knee_Right", "Knee_Left", "Calf_Right", "Calf_Left",
    "FannyPackFront", "FannyPackBack", "Webbing",
    "AmmoStrap", "AnkleHolster", "BeltExtra", "ShoulderHolster",
    "Socks", "Shoes",
}

-- Live zombie cache: persistentOutfitID → IsoZombie
WeNPC.Cache = {}

-- ─── Appearance capture ────────────────────────────────────────────────────────

function WeNPC.captureAppearance(player)
    local app    = {}
    app.female   = player:isFemale()
    app.clothing = {}

    local vis = player:getHumanVisual()
    if vis then
        app.skinTexture = vis:getSkinTextureName()
        app.hairStyle   = vis:getHairModel()
        local hc = vis:getHairColor()
        if hc then app.hairColor = {r=hc:getR(), g=hc:getG(), b=hc:getB()} end
        if not app.female then
            app.beardStyle = vis:getBeardModel()
            local bc = vis:getBeardColor()
            if bc then app.beardColor = {r=bc:getR(), g=bc:getG(), b=bc:getB()} end
        end
    end

    local worn = player:getWornItems()
    for i = 0, worn:size() - 1 do
        local wi   = worn:get(i)
        local item = wi and wi:getItem()
        local loc  = wi and wi:getBodyLocation()
        if item and loc then
            app.clothing[loc] = item:getFullType()
        end
    end

    return app
end

-- ─── Visual application ────────────────────────────────────────────────────────

function WeNPC.applyVisuals(zombie, app)
    local vis = zombie:getHumanVisual()
    if not vis then return end

    if app.skinTexture then vis:setSkinTextureName(app.skinTexture) end
    if app.hairStyle   then vis:setHairModel(app.hairStyle)         end
    if app.hairColor   then
        vis:setHairColor(ImmutableColor.new(app.hairColor.r, app.hairColor.g, app.hairColor.b))
    end
    if app.beardStyle  then vis:setBeardModel(app.beardStyle)       end
    if app.beardColor  then
        vis:setBeardColor(ImmutableColor.new(app.beardColor.r, app.beardColor.g, app.beardColor.b))
    end

    -- Clothing in layer order
    local itemVisuals = zombie:getItemVisuals()
    itemVisuals:clear()
    for _, loc in ipairs(WeNPC.BODY_LOCATIONS) do
        local itemType = app.clothing and app.clothing[loc]
        if itemType then
            local iv = ItemVisual.new()
            iv:setItemType(itemType)
            iv:setClothingItemName(itemType)
            itemVisuals:add(iv)
        end
    end

    -- Remove blood / dirt from a freshly "spawned" survivor
    local maxIdx = BloodBodyPartType.MAX:index()
    for i = 0, maxIdx - 1 do
        local part = BloodBodyPartType.FromIndex(i)
        vis:setBlood(part, 0)
        vis:setDirt(part, 0)
    end

    zombie:resetModelNextFrame()
    zombie:resetModel()
end

-- ─── Brain builder ─────────────────────────────────────────────────────────────

function WeNPC.buildBrain(slot, slotIndex)
    local homeX = slot.homeX or slot.x or 0
    local homeY = slot.homeY or slot.y or 0
    local homeZ = slot.homeZ or slot.z or 0

    return {
        id         = nil,           -- assigned after spawn
        slotIndex  = slotIndex,
        slotName   = slot.name,
        homeX      = homeX,
        homeY      = homeY,
        homeZ      = homeZ,
        appearance = slot.appearance,
        female     = (slot.appearance and slot.appearance.female) or false,
    }
end

-- ─── Spawn / Despawn ──────────────────────────────────────────────────────────

function WeNPC.spawnForSlot(slotIndex)
    local player = getSpecificPlayer(0)
    if not player then return end

    local data = WeData.getData()
    local slot = data.slots[slotIndex]
    if not slot or slot.x == nil then return end
    if slot.npcId then return end   -- already alive

    local brain = WeNPC.buildBrain(slot, slotIndex)

    sendServerCommand(player, "We", "spawnResident", {
        slotIndex = slotIndex,
        brain     = brain,
        x         = brain.homeX,
        y         = brain.homeY,
        z         = brain.homeZ,
        female    = brain.female,
    })

    print("[We] Requested spawn for slot " .. slotIndex)
end

function WeNPC.despawnForSlot(slotIndex)
    local player = getSpecificPlayer(0)
    if not player then return end

    local data = WeData.getData()
    local slot = data.slots[slotIndex]
    if not slot or not slot.npcId then return end

    sendServerCommand(player, "We", "despawnResident", {
        slotIndex = slotIndex,
        npcId     = slot.npcId,
    })

    slot.npcId = nil
    print("[We] Requested despawn for slot " .. slotIndex)
end

-- ─── OnZombieUpdate — per-tick NPC maintenance ────────────────────────────────

local function onZombieUpdate(zombie)
    if not zombie:getVariableBoolean("WeResident") then return end

    local brain = zombie:getModData().weBrain
    if not brain then return end

    local id = zombie:getPersistentOutfitID()

    -- Keep in cache
    WeNPC.Cache[id] = zombie

    -- Apply visuals once (flag prevents re-running every tick)
    if not brain.visualsApplied and brain.appearance then
        WeNPC.applyVisuals(zombie, brain.appearance)
        brain.visualsApplied = true
    end

    -- Prevent wandering: snap back if more than 3 tiles from home
    if brain.homeX then
        local dx = zombie:getX() - brain.homeX
        local dy = zombie:getY() - brain.homeY
        if dx * dx + dy * dy > 9 then
            zombie:setX(brain.homeX)
            zombie:setY(brain.homeY)
            zombie:setZ(brain.homeZ or 0)
        end
    end
end

Events.OnZombieUpdate.Add(onZombieUpdate)

-- ─── EveryOneMinute — re-spawn if zombie was unloaded and cell is back ────────

local function onEveryMinute()
    local data   = WeData.getData()
    local active = data.activeSlot
    local player = getSpecificPlayer(0)
    if not player then return end

    local weMD = ModData.getOrCreate("We")
    if not weMD.residents then return end

    for slotStr, resident in pairs(weMD.residents) do
        local slotIndex = tonumber(slotStr)
        if slotIndex ~= active then
            local id = resident.id
            -- If the zombie is no longer in our cache, request a respawn
            if not WeNPC.Cache[id] then
                local slot = data.slots[slotIndex]
                if slot then slot.npcId = nil end   -- force re-spawn
                local brain = resident.brain
                if brain then
                    local cell   = getCell()
                    local square = cell and cell:getGridSquare(brain.homeX, brain.homeY, brain.homeZ or 0)
                    if square then
                        WeNPC.spawnForSlot(slotIndex)
                    end
                end
            end
        end
    end
end

Events.EveryOneMinute.Add(onEveryMinute)

-- ─── OnReceiveGlobalModData — sync npcIds sent from server ────────────────────

local function onReceiveModData(key, gData)
    if key ~= "We" then return end
    if not gData or not gData.residents then return end

    local data = WeData.getData()
    for slotStr, resident in pairs(gData.residents) do
        local slot = data.slots[tonumber(slotStr)]
        if slot then slot.npcId = resident.id end
    end
end

Events.OnReceiveGlobalModData.Add(onReceiveModData)

-- ─── Init ──────────────────────────────────────────────────────────────────────

function WeNPC.init()
    -- Restore npcIds from our own global ModData (survives game reloads)
    local weMD = ModData.getOrCreate("We")
    if weMD.residents then
        local data = WeData.getData()
        for slotStr, resident in pairs(weMD.residents) do
            local slot = data.slots[tonumber(slotStr)]
            if slot then slot.npcId = resident.id end
        end
    end

    -- Spawn NPCs for inactive slots that don't have one yet
    local data   = WeData.getData()
    local active = data.activeSlot
    for i = 1, We.MAX_SLOTS do
        if i ~= active and data.slots[i].x ~= nil and not data.slots[i].npcId then
            WeNPC.spawnForSlot(i)
        end
    end

    print("[We] WeNPC initialised")
end
