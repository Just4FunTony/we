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

    -- Remove any zombie-style attached weapons like "knife in back".
    local ai = zombie.getAttachedItems and zombie:getAttachedItems()
    local grp = ai and ai.getGroup and ai:getGroup()
    if grp and grp.size and zombie.setAttachedItem then
        for i = 0, grp:size() - 1 do
            local loc = grp:getLocationByIndex(i)
            local locId = loc and loc.getId and loc:getId()
            if locId then
                pcall(zombie.setAttachedItem, zombie, locId, nil)
            end
        end
    end
    if ai and ai.clear then pcall(ai.clear, ai) end

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

    local charTraits = player:getCharacterTraits()
    local knownTraits = charTraits:getKnownTraits()
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
    for _, traitType in ipairs(traitEnums) do
        pcall(charTraits.add, charTraits, traitType)
        applied = applied + 1
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

        -- Hard dedup by persistent resident registry.
        -- On reconnect/reload client may request spawn again while resident for this slot
        -- already exists in the world (possibly currently unloaded).
        local weMD = ModData.getOrCreate("We")
        if not weMD.residents then weMD.residents = {} end
        local existingResident = weMD.residents[tostring(slotIndex)]
        if existingResident then
            -- If loaded right now, refresh its brain/appearance; otherwise keep persisted one.
            local cell = getCell()
            local updatedLoaded = false
            if cell then
                local zList = cell:getZombieList()
                for i = 0, zList:size() - 1 do
                    local z = zList:get(i)
                    local zmd = z and z:getModData()
                    local zBrain = zmd and zmd.weBrain
                    local sameSlot = zmd and (
                        zmd.weSlot == slotIndex
                        or (zBrain and zBrain.slotIndex == slotIndex)
                    )
                    if z and sameSlot and not z:isDead() then
                        local brain = args.brain or existingResident.brain
                        if brain then
                            zmd.weSlot = slotIndex
                            z:getModData().weBrain = brain
                            z:setVariable("WeResident", true)
                            z:setTarget(nil)
                            if z.setTargetSeenTime then z:setTargetSeenTime(0) end
                            applyAppearance(z, brain.appearance)
                            existingResident.brain = brain
                        end
                        updatedLoaded = true
                        break
                    end
                end
            end
            if updatedLoaded then
                weMD.residents[tostring(slotIndex)] = existingResident
                ModData.transmit("We")
                print("[We] spawnResident: skipped duplicate for slot=" .. tostring(slotIndex)
                    .. " loadedUpdated=" .. tostring(updatedLoaded))
                return
            end

            -- Stale resident registry entry (no actual zombie loaded for this slot).
            -- Drop stale record and proceed with a fresh spawn to avoid hostile/default zombie fallback.
            weMD.residents[tostring(slotIndex)] = nil
            ModData.transmit("We")
            print("[We] spawnResident: stale resident cleared for slot=" .. tostring(slotIndex) .. ", spawning fresh")
        end

        -- Deduplicate by slot: on load the client can request spawn while resident
        -- already exists in-world/persisted ModData.
        local cell = getCell()
        if cell then
            local zList = cell:getZombieList()
            for i = 0, zList:size() - 1 do
                local z = zList:get(i)
                local zmd = z and z:getModData()
                local zBrain = zmd and zmd.weBrain
                local sameSlot = zmd and (
                    zmd.weSlot == slotIndex
                    or (zBrain and zBrain.slotIndex == slotIndex)
                )
                if z and sameSlot and not z:isDead() then
                    local brain = args.brain
                    if brain then
                        zmd.weSlot = slotIndex
                        z:getModData().weBrain = brain
                        z:setVariable("WeResident", true)
                        z:setTarget(nil)
                        if z.setTargetSeenTime then z:setTargetSeenTime(0) end
                        applyAppearance(z, brain.appearance)
                    end
                    weMD.residents[tostring(slotIndex)] = {slotIndex = slotIndex, brain = brain}
                    ModData.transmit("We")
                    print("[We] spawnResident: dedup hit, resident already exists for slot=" .. tostring(slotIndex))
                    return
                end
            end

            -- Remove stale/hostile zombie that occupies resident spawn area.
            -- This prevents "extra zombie on NPC spot" after reconnect/load.
            for i = zList:size() - 1, 0, -1 do
                local z = zList:get(i)
                if z and not z:isDead() then
                    local sameZ = math.floor(z:getZ() or 0) == math.floor(args.z or 0)
                    local dx = (z:getX() or 0) - x
                    local dy = (z:getY() or 0) - y
                    local close = (dx * dx + dy * dy) <= (1.5 * 1.5)
                    if sameZ and close then
                        local zmd = z:getModData()
                        local zBrain = zmd and zmd.weBrain
                        local sameSlot = zmd and (
                            zmd.weSlot == slotIndex
                            or (zBrain and zBrain.slotIndex == slotIndex)
                        )
                        if not sameSlot then
                            z:removeFromWorld()
                            z:removeFromSquare()
                            print("[We] spawnResident: removed stale zombie at spawn point for slot=" .. tostring(slotIndex))
                        end
                    end
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

    -- ── killResident (play death) ───────────────────────────────────────────────
    elseif command == "killResident" then
        local slotIndex = args.slotIndex
        if not slotIndex then return end
        local cell = getCell()
        if cell then
            local zList = cell:getZombieList()
            for i = 0, zList:size() - 1 do
                local z = zList:get(i)
                local zmd = z and z:getModData()
                local zBrain = zmd and zmd.weBrain
                local sameSlot = zmd and (
                    zmd.weSlot == slotIndex
                    or (zBrain and zBrain.slotIndex == slotIndex)
                )
                if z and sameSlot and not z:isDead() then
                    if z.setInvulnerable then pcall(z.setInvulnerable, z, false) end
                    z:Kill(nil)
                    print("[We] Killed resident NPC slot=" .. tostring(slotIndex))
                    break
                end
            end
        end

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

    -- ── deathSwapCleanup ───────────────────────────────────────────────────────
    -- MP / host: remove the vanilla player corpse at the death cell and drop zombie
    -- chase targets on this player so AI doesn't follow the same IsoPlayer to a new slot position.
    elseif command == "deathSwapCleanup" then
        local x, y, z = args.x, args.y, args.z
        local r = tonumber(args.radius) or 2
        local cell = getCell()
        if cell and x and y then
            local fx = math.floor(x)
            local fy = math.floor(y)
            local fz = math.floor(z or 0)
            for dx = -r, r do
                for dy = -r, r do
                    local sq = cell:getGridSquare(fx + dx, fy + dy, fz)
                    if sq then
                        local function strip(list)
                            if not list then return end
                            for ii = list:size() - 1, 0, -1 do
                                local o = list:get(ii)
                                if o and instanceof(o, "IsoDeadBody") then
                                    pcall(function() sq:removeCorpse(o, false) end)
                                    pcall(function() o:removeFromWorld() end)
                                    pcall(function() o:removeFromSquare() end)
                                end
                            end
                        end
                        strip(sq:getObjects())
                        if sq.getStaticMovingObjects then strip(sq:getStaticMovingObjects()) end
                    end
                end
            end
        end
        if player then
            local cell2 = getCell()
            if cell2 then
                local zList = cell2:getZombieList()
                for i = 0, zList:size() - 1 do
                    local z = zList:get(i)
                    local zmd = z and z.getModData and z:getModData()
                    if z and not z:isDead() and not (zmd and zmd.weBrain) then
                        local t = nil
                        pcall(function() t = z:getTarget() end)
                        if t == player then
                            pcall(function() z:setTarget(nil) end)
                            pcall(function()
                                if z.setTargetSeenTime then z:setTargetSeenTime(0) end
                            end)
                        end
                    end
                end
            end
        end

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
