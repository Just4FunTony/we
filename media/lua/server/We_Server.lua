-- We: Server-side command handler.
-- Spawns and despawns NPC zombies for inactive character slots.

-- Apply appearance to a zombie on the server side.
-- Must be duplicated here because We_NPC.lua is client-only.
local function applyAppearance(zombie, app)
    if not app then return end
    local vis = zombie:getHumanVisual()
    if not vis then return end

    if app.skinTexture and app.skinTexture ~= "" then
        vis:setSkinTextureName(app.skinTexture)
    end
    if app.hairStyle then vis:setHairModel(app.hairStyle) end
    if app.hairColor then
        vis:setHairColor(ImmutableColor.new(app.hairColor.r, app.hairColor.g, app.hairColor.b, 1))
    end
    if app.beardStyle then vis:setBeardModel(app.beardStyle) end
    if app.beardColor then
        vis:setBeardColor(ImmutableColor.new(app.beardColor.r, app.beardColor.g, app.beardColor.b, 1))
    end

    local iv = zombie:getItemVisuals()
    iv:clear()
    if app.itemVisuals then
        for _, itemType in ipairs(app.itemVisuals) do
            local ivItem = ItemVisual.new()
            ivItem:setItemType(itemType)
            ivItem:setClothingItemName(itemType)
            iv:add(ivItem)
        end
    end

    -- Remove blood / dirt so NPC looks like a living survivor
    local maxIdx = BloodBodyPartType.MAX:index()
    for i = 0, maxIdx - 1 do
        local part = BloodBodyPartType.FromIndex(i)
        vis:setBlood(part, 0)
        vis:setDirt(part, 0)
    end

    zombie:resetModelNextFrame()
    zombie:resetModel()
end

local function onClientCommand(module, command, player, args)
    if module ~= "We" then return end

    -- ── spawnResident ──────────────────────────────────────────────────────────
    if command == "spawnResident" then
        local x, y, z = args.x, args.y, args.z
        if not x or not y then
            print("[We] spawnResident: missing coords for slot " .. tostring(args.slotIndex))
            return
        end

        -- Spawn with a naked outfit so applyAppearance has full control
        local femaleChance = args.female and 100 or 0
        local outfit       = femaleChance > 0 and "F_Naked1" or "M_Naked1"

        local zombieList = addZombiesInOutfit(
            x, y, z,
            1,              -- count
            outfit,
            femaleChance,
            false,          -- crawler
            false,          -- fallOnFront
            false,          -- fakeDead
            false,          -- knockedDown
            true,           -- invulnerable (NPCs shouldn't die)
            false,          -- sitting (false = standing idle)
            1               -- health multiplier
        )

        if not zombieList or zombieList:size() == 0 then
            print("[We] spawnResident: spawn failed for slot " .. tostring(args.slotIndex))
            return
        end

        local zombie = zombieList:get(0)

        -- Set gender before applying appearance
        zombie:setFemaleEtc(args.female or false)

        -- Tag for identification
        zombie:getModData().weSlot = args.slotIndex
        zombie:setVariable("WeResident", true)

        -- Store brain in zombie moddata (persists across saves)
        local brain = args.brain
        zombie:getModData().weBrain = brain

        -- Apply appearance immediately on the server so the zombie is never naked
        applyAppearance(zombie, brain and brain.appearance)

        -- Human animation and sound suppression (from Bandits mod pattern)
        if zombie.setWalkType then zombie:setWalkType("Walk") end
        local zDesc = zombie:getDescriptor()
        if zDesc then
            zDesc:setVoicePrefix(args.female and "VoiceFemale" or "VoiceMale")
        end
        if zombie.getEmitter then
            local emitter = zombie:getEmitter()
            if emitter then emitter:stopAll() end
        end
        if zombie.setNoTeeth then zombie:setNoTeeth(true) end
        if zombie.setUseless then zombie:setUseless(true) end
        zombie:setVariable("ZombieHitReaction", "Chainsaw")
        zombie:setVariable("NoLungeTarget", true)

        -- Suppress initial hostility
        zombie:setTarget(nil)
        if zombie.setTargetSeenTime then zombie:setTargetSeenTime(0) end

        -- Store in global ModData for persistence across cell reloads
        local weMD = ModData.getOrCreate("We")
        if not weMD.residents then weMD.residents = {} end
        weMD.residents[tostring(args.slotIndex)] = {slotIndex = args.slotIndex, brain = brain}
        ModData.transmit("We")

        print("[We] Spawned resident NPC slot=" .. tostring(args.slotIndex))

    -- ── despawnResident ────────────────────────────────────────────────────────
    elseif command == "despawnResident" then
        local slotIndex = args.slotIndex
        if not slotIndex then return end

        local cell = getCell()
        if cell then
            local zList = cell:getZombieList()
            for i = 0, zList:size() - 1 do
                local z = zList:get(i)
                if z and z:getModData().weSlot == slotIndex then
                    z:removeFromWorld()
                    z:removeFromSquare()
                    print("[We] Removed NPC zombie slot=" .. slotIndex)
                    break
                end
            end
        end

        local weMD = ModData.getOrCreate("We")
        if weMD.residents then
            weMD.residents[tostring(slotIndex)] = nil
        end
        ModData.transmit("We")

        print("[We] Despawned resident NPC slot=" .. tostring(slotIndex))
    end
end

Events.OnClientCommand.Add(onClientCommand)
