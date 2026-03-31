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

local function applyTraitsToCollections(player, traitsList)
    local applied = 0
    local traitEnums = {}
    for _, traitName in ipairs(traitsList or {}) do
        local traitType = CharacterTrait.get(ResourceLocation.of(traitName))
        if traitType then
            traitEnums[#traitEnums + 1] = traitType
        else
            print("[We] applyTraits: unknown trait " .. tostring(traitName))
        end
    end

    local knownTraits = player:getCharacterTraits():getKnownTraits()
    knownTraits:clear()
    for _, traitType in ipairs(traitEnums) do
        knownTraits:add(traitType)
        applied = applied + 1
    end

    if player.hasTrait and player.removeTrait then
        local defs = CharacterTraitDefinition.getTraits()
        for i = 0, defs:size() - 1 do
            local def = defs:get(i)
            local traitType = def and def:getType()
            if traitType and player:hasTrait(traitType) then
                pcall(player.removeTrait, player, traitType)
            end
        end
    end
    if player.addTrait then
        for _, traitType in ipairs(traitEnums) do
            pcall(player.addTrait, player, traitType)
        end
    end

    -- B42 may use a separate runtime trait collection for gameplay checks/UI.
    local runtimeTraits = player.getTraits and player:getTraits()
    if runtimeTraits then
        if runtimeTraits.clear then runtimeTraits:clear() end
        for _, traitType in ipairs(traitEnums) do
            if runtimeTraits.add then
                runtimeTraits:add(traitType)
            end
        end
    end

    return applied
end

local function onClientCommand(module, command, player, args)
    if module ~= "We" then return end

    -- ── spawnResident ──────────────────────────────────────────────────────────
    if command == "spawnResident" then
        local x, y, z = args.x, args.y, args.z
        local slotIndex = args.slotIndex
        if not x or not y then
            print("[We] spawnResident: missing coords for slot " .. tostring(args.slotIndex))
            return
        end
        if not slotIndex then
            print("[We] spawnResident: missing slotIndex")
            return
        end

        -- Deduplicate by slot: on load the client can request spawn while resident
        -- already exists in-world/persisted ModData.
        local cell = getCell()
        if cell then
            local zList = cell:getZombieList()
            for i = 0, zList:size() - 1 do
                local z = zList:get(i)
                if z and z:getModData().weSlot == slotIndex and not z:isDead() then
                    local brain = args.brain
                    if brain then
                        z:getModData().weBrain = brain
                        applyAppearance(z, brain.appearance)
                    end
                    local weMD = ModData.getOrCreate("We")
                    if not weMD.residents then weMD.residents = {} end
                    weMD.residents[tostring(slotIndex)] = {slotIndex = slotIndex, brain = brain}
                    ModData.transmit("We")
                    print("[We] spawnResident: dedup hit, resident already exists for slot=" .. tostring(slotIndex))
                    return
                end
            end
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

    -- ── applyTraits ────────────────────────────────────────────────────────────
    -- Client getKnownTraits() returns a snapshot; only server-side changes persist.
    elseif command == "applyTraits" then
        local desc = player:getDescriptor()
        local pnum = player.getPlayerNum and player:getPlayerNum()
        local username = player.getUsername and player:getUsername()
        print("[We][Server] applyTraits request"
            .. " | user=" .. tostring(username)
            .. " | pnum=" .. tostring(pnum)
            .. " | slot=" .. tostring(args and args.slotIndex)
            .. " | prof=" .. tostring(args and args.profession)
            .. " | traits=" .. summarizeTraits(args and args.traits or {}))

        -- Profession first so engine grants are loaded before we overwrite
        if args.profession and desc then
            local profEnum = CharacterProfession.get(ResourceLocation.of(args.profession))
            if profEnum then desc:setCharacterProfession(profEnum) end
        end

        -- Clear and rebuild trait list
        local count = applyTraitsToCollections(player, args.traits or {})
        print("[We] applyTraits: applied " .. count .. "/" .. #(args.traits or {}) .. " traits")
        -- In SP the server and client share the same Lua VM, so we can refresh the
        -- Info panel directly here (same pattern as NPCs/SurvivorSwap.lua).
        if pnum ~= nil then
            local panel = getPlayerInfoPanel and getPlayerInfoPanel(pnum)
            if panel and panel.charScreen then
                panel.charScreen.refreshNeeded = true
            end
        end
        -- Confirm back to client so it can update slot.traits and refresh the Info panel
        sendServerCommand(player, "We", "traitsApplied", {
            slotIndex  = args.slotIndex,
            traits     = args.traits or {},
            profession = args.profession,
        })
        print("[We][Server] traitsApplied sent"
            .. " | user=" .. tostring(username)
            .. " | slot=" .. tostring(args and args.slotIndex)
            .. " | prof=" .. tostring(args and args.profession)
            .. " | traitsCount=" .. tostring(#(args and args.traits or {})))

    -- ── requestTraits ──────────────────────────────────────────────────────────
    -- Client requests current authoritative trait list (used on game load to
    -- initialize slot.traits for the player's existing character).
    elseif command == "requestTraits" then
        local knownTraits = player:getCharacterTraits():getKnownTraits()
        local traits = {}
        for i = 0, knownTraits:size() - 1 do
            local t = knownTraits:get(i)
            if t then table.insert(traits, tostring(t)) end
        end
        local desc = player:getDescriptor()
        local prof = desc and desc:getCharacterProfession()
        sendServerCommand(player, "We", "traitsApplied", {
            slotIndex  = args.slotIndex,
            traits     = traits,
            profession = prof and tostring(prof) or nil,
        })
        print("[We] requestTraits: slot=" .. tostring(args.slotIndex) .. " count=" .. #traits)
    end
end

Events.OnClientCommand.Add(onClientCommand)
