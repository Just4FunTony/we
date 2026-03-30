-- We: Client-side NPC manager.
-- Spawns, maintains, and despawns NPC stand-ins for inactive characters.
-- SP: uses createNPCPlayer for proper idle animations.
-- MP: falls back to server-side zombie via sendClientCommand.

WeNPC = WeNPC or {}

-- Live NPC cache: slotIndex → IsoPlayer or IsoZombie
WeNPC.Cache = {}

-- Slots whose zombie has been despawned but may still be alive for 1-2 frames.
-- onZombieUpdate must not re-cache these until the zombie is confirmed gone.
WeNPC.PendingDespawn = {}

-- ─── Appearance capture ────────────────────────────────────────────────────────
-- Captures the player's hair/skin/beard visuals plus a list of worn item types.
-- Uses getWornItems() which is the authoritative clothing source for IsoPlayer.

function WeNPC.captureAppearance(player)
    local app = {}
    app.female      = player:isFemale()
    app.itemVisuals = {}

    local vis = player:getHumanVisual()
    if vis then
        local st = vis:getSkinTexture()
        app.skinTexture = (st and st ~= "") and tostring(st) or nil
        app.hairStyle   = vis:getHairModel()
        local hc = vis:getHairColor()
        if hc then app.hairColor = {r=hc:getRedFloat(), g=hc:getGreenFloat(), b=hc:getBlueFloat()} end
        if not app.female then
            app.beardStyle = vis:getBeardModel()
            local bc = vis:getBeardColor()
            if bc then app.beardColor = {r=bc:getRedFloat(), g=bc:getGreenFloat(), b=bc:getBlueFloat()} end
        end
    end

    -- Capture worn clothing item types (for NPC dressing; iterate inventory for worn items)
    local items = player:getInventory():getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local loc = item.getBodyLocation and item:getBodyLocation()
        if loc then
            local t = item:getFullType()
            if t and t ~= "" then
                table.insert(app.itemVisuals, t)
            end
        end
    end

    return app
end

-- ─── Visual application ────────────────────────────────────────────────────────
-- Works on any IsoGameCharacter (IsoPlayer NPC or IsoZombie).

function WeNPC.applyVisuals(char, app)
    if not app then return end
    local vis = char:getHumanVisual()
    if not vis then return end

    -- setFemaleEtc exists on IsoZombie; IsoSurvivor/IsoPlayer use setFemale via descriptor
    if char.setFemaleEtc then char:setFemaleEtc(app.female or false) end

    if app.skinTexture and app.skinTexture ~= "" and vis.setSkinTextureName then
        vis:setSkinTextureName(app.skinTexture)
    end
    if app.hairStyle   and vis.setHairModel  then vis:setHairModel(app.hairStyle)   end
    if app.hairColor   and vis.setHairColor  then
        vis:setHairColor(ImmutableColor.new(app.hairColor.r, app.hairColor.g, app.hairColor.b, 1))
    end
    if app.beardStyle  and vis.setBeardModel then vis:setBeardModel(app.beardStyle) end
    if app.beardColor  and vis.setBeardColor then
        vis:setBeardColor(ImmutableColor.new(app.beardColor.r, app.beardColor.g, app.beardColor.b, 1))
    end

    local itemVisuals = char:getItemVisuals()
    itemVisuals:clear()
    if app.itemVisuals then
        for _, entry in ipairs(app.itemVisuals) do
            local t = type(entry) == "table" and (entry.itemType or "") or tostring(entry)
            local iv = ItemVisual.new()
            iv:setItemType(t)
            iv:setClothingItemName(t)
            itemVisuals:add(iv)
        end
    end

    -- Remove blood and dirt so the NPC looks like a living survivor
    local maxIdx = BloodBodyPartType.MAX:index()
    for i = 0, maxIdx - 1 do
        local part = BloodBodyPartType.FromIndex(i)
        vis:setBlood(part, 0)
        vis:setDirt(part, 0)
    end

    char:resetModelNextFrame()
    char:resetModel()
end

-- ─── Brain builder ─────────────────────────────────────────────────────────────

function WeNPC.buildBrain(slot, slotIndex)
    -- NPC anchors to the character's last saved position so they stay where you left them
    return {
        slotIndex  = slotIndex,
        slotName   = slot.name,
        homeX      = slot.x or 0,
        homeY      = slot.y or 0,
        homeZ      = slot.z or 0,
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
    if WeNPC.Cache[slotIndex]    then return end

    local brain = WeNPC.buildBrain(slot, slotIndex)
    local isSP  = not (getWorld and getWorld():getGameMode() == "Multiplayer")

    -- createNPCPlayer: debug-only native, nil in release builds
    if isSP and createNPCPlayer then
        local npc = createNPCPlayer(brain.homeX, brain.homeY, brain.homeZ or 0)
        if npc then
            npc:getModData().weBrain = brain
            npc:setVariable("WeResident", true)
            WeNPC.applyVisuals(npc, brain.appearance)
            WeNPC.Cache[slotIndex] = npc
            slot.npcId = slotIndex
            print("[We] Spawned NPC player for slot " .. slotIndex)
            return
        end
    end

    -- Server-side zombie (sitting, invulnerable — best available fallback).
    -- Set a sentinel in Cache immediately so onEveryMinute doesn't spawn a duplicate
    -- before onZombieUpdate fires for the new zombie (can be several frames later).
    WeNPC.Cache[slotIndex] = "pending"
    sendClientCommand(player, "We", "spawnResident", {
        slotIndex = slotIndex,
        brain     = brain,
        x         = brain.homeX,
        y         = brain.homeY,
        z         = brain.homeZ,
        female    = brain.female,
    })
    slot.npcId = slotIndex
    print("[We] Requested server zombie for slot " .. slotIndex)
end

function WeNPC.despawnForSlot(slotIndex)
    local npc = WeNPC.Cache[slotIndex]

    if npc and npc ~= "pending" and instanceof(npc, "IsoSurvivor") then
        npc:Despawn()
    elseif npc and npc ~= "pending" and instanceof(npc, "IsoPlayer") then
        npc:removeFromMap()
    else
        -- Server zombie (or pending sentinel): remove via server command
        local player = getSpecificPlayer(0)
        if player then
            sendClientCommand(player, "We", "despawnResident", {slotIndex = slotIndex})
        end
    end

    WeNPC.Cache[slotIndex]         = nil
    WeNPC.PendingDespawn[slotIndex] = true   -- block re-caching until zombie is confirmed gone
    local data = WeData.getData()
    local slot = data.slots[slotIndex]
    if slot then slot.npcId = nil end
    print("[We] Despawned NPC for slot " .. slotIndex)
end

-- ─── OnZombieUpdate — per-tick maintenance for server-side zombie NPCs (MP) ──

local function onZombieUpdate(zombie)
    local brain = zombie:getModData().weBrain
    if not brain or not brain.slotIndex then return end

    -- Zombie confirmed dead: if this is not a managed despawn (PendingDespawn is nil),
    -- the NPC was killed by external means — remove the slot entirely.
    if zombie:isDead() or not zombie:getCurrentSquare() then
        if not WeNPC.PendingDespawn[brain.slotIndex] then
            -- Killed by player or world — remove the slot
            WeData.killSlot(brain.slotIndex)
        end
        if WeNPC.Cache[brain.slotIndex] == zombie then
            WeNPC.Cache[brain.slotIndex] = nil
        end
        WeNPC.PendingDespawn[brain.slotIndex] = nil
        return
    end

    -- Keep outline green even during despawn transition so the zombie never flashes red.
    if zombie.setOutlineHighlight then
        zombie:setOutlineHighlight(0, true)
        zombie:setOutlineHighlightCol(0, 0.2, 0.9, 0.2, 1.0)
    end

    -- Do not re-cache a zombie that is being despawned — the despawn command is in flight
    -- and the zombie may still be alive for a frame or two.
    if WeNPC.PendingDespawn[brain.slotIndex] then return end

    if not zombie:getVariableBoolean("WeResident") then
        zombie:setVariable("WeResident", true)
    end

    WeNPC.Cache[brain.slotIndex] = zombie

    -- Human animation + sound suppression (re-applied each tick; cell reloads can reset these)
    if zombie.setWalkType then zombie:setWalkType("Walk") end
    if zombie.setNoTeeth  then zombie:setNoTeeth(true)   end
    local zDesc = zombie:getDescriptor()
    if zDesc and zDesc.setVoicePrefix then
        zDesc:setVoicePrefix(brain.female and "VoiceFemale" or "VoiceMale")
    end
    if zombie.getEmitter then
        local emitter = zombie:getEmitter()
        if emitter and emitter.stopAll then emitter:stopAll() end
    end

    -- Make NPC unhittable: useless flag disables attack reactions; ZombieHitReaction
    -- prevents engine crash (testDefense) when the zombie object is hit.
    if zombie.setUseless then zombie:setUseless(true) end
    zombie:setVariable("ZombieHitReaction", "Chainsaw")
    zombie:setVariable("NoLungeTarget", true)

    -- Green outline so the player can tell this is a friendly resident
    if zombie.setOutlineHighlight then
        zombie:setOutlineHighlight(0, true)
        zombie:setOutlineHighlightCol(0, 0.2, 0.9, 0.2, 1.0)
    end

    -- Suppress hostile behaviour every tick
    zombie:setTarget(nil)
    if zombie.setTargetSeenTime then zombie:setTargetSeenTime(0) end

    -- Re-apply visuals if lost after cell reload
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

-- ─── OnPlayerUpdate — maintenance + home-snap for NPC players and panic ──────

local _panicTick = 0
local function onPlayerUpdate(player)
    local pnum = player:getPlayerNum()

    -- ── Actual player (player 0): panic suppression ──────────────────────────
    if pnum == 0 then
        _panicTick = _panicTick + 1
        if _panicTick < 15 then return end
        _panicTick = 0

        local stats = player:getStats()
        if stats:get(CharacterStat.PANIC) <= 0 then return end

        local px, py = player:getX(), player:getY()
        local radius = 16
        local r2     = radius * radius

        local cell = getCell()
        if not cell then return end

        local zList = cell:getZombieList()
        for i = 0, zList:size() - 1 do
            local z = zList:get(i)
            if z and not z:isDead() then
                local dx = z:getX() - px
                local dy = z:getY() - py
                if dx*dx + dy*dy <= r2 then
                    if not z:getModData().weBrain then
                        return  -- a real zombie is nearby — keep panic
                    end
                end
            end
        end

        stats:set(CharacterStat.PANIC, 0)

        -- Re-apply green outline on all cached NPCs after the engine's targeting pass.
        -- This overrides any red "hostile target" highlight the engine may have set.
        for _, npc in pairs(WeNPC.Cache) do
            if npc and npc ~= "pending" and instanceof(npc, "IsoZombie") then
                if npc.setOutlineHighlight then
                    npc:setOutlineHighlight(0, true)
                    npc:setOutlineHighlightCol(0, 0.2, 0.9, 0.2, 1.0)
                end
            end
        end
        return
    end

    -- ── NPC players created by createNPCPlayer: home-snap ────────────────────
    local brain = player:getModData().weBrain
    if not brain or not brain.slotIndex then return end

    WeNPC.Cache[brain.slotIndex] = player

    if brain.homeX then
        local dx = player:getX() - brain.homeX
        local dy = player:getY() - brain.homeY
        if dx * dx + dy * dy > 9 then
            player:setX(brain.homeX)
            player:setY(brain.homeY)
            player:setZ(brain.homeZ or 0)
        end
    end
end

Events.OnPlayerUpdate.Add(onPlayerUpdate)

-- ─── EveryOneMinute — respawn if NPC was unloaded ─────────────────────────────

local function onEveryMinute()
    local data   = WeData.getData()
    local active = data.activeSlot

    for i = 1, We.MAX_SLOTS do
        if i ~= active and data.slots[i] and data.slots[i].x ~= nil then
            if not WeNPC.Cache[i] then
                WeNPC.spawnForSlot(i)
            end
        end
    end
end

Events.EveryOneMinute.Add(onEveryMinute)

-- ─── OnReceiveGlobalModData — sync npcIds from server (MP zombie path) ────────

local function onReceiveModData(key, gData)
    if key ~= "We" then return end
    if not gData or not gData.residents then return end

    local data = WeData.getData()
    for slotStr, resident in pairs(gData.residents) do
        local slotIndex = tonumber(slotStr)
        local slot = data.slots[slotIndex]
        if slot then slot.npcId = slotIndex end
    end
end

Events.OnReceiveGlobalModData.Add(onReceiveModData)

-- ─── Init ──────────────────────────────────────────────────────────────────────

function WeNPC.init()
    WeNPC.Cache         = {}
    WeNPC.PendingDespawn = {}

    local data   = WeData.getData()
    local active = data.activeSlot

    -- Clear stale npcIds: NPC players don't persist across game reloads.
    -- The MP zombie path syncs them back below from ModData.
    for i = 1, We.MAX_SLOTS do
        if data.slots[i] then data.slots[i].npcId = nil end
    end

    -- MP zombie path: restore npcIds from server ModData
    local weMD = ModData.getOrCreate("We")
    if weMD.residents then
        for slotStr, resident in pairs(weMD.residents) do
            local slotIndex = tonumber(slotStr)
            local slot = data.slots[slotIndex]
            if slot then slot.npcId = slotIndex end
        end
    end

    -- Spawn NPCs for all inactive slots that have save data
    for i = 1, We.MAX_SLOTS do
        if i ~= active and data.slots[i] and data.slots[i].x ~= nil then
            WeNPC.spawnForSlot(i)
        end
    end

    print("[We] WeNPC initialised")
end
