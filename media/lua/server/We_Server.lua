-- We: Server-side command handler.
-- Spawns and despawns NPC zombies for inactive character slots.

local function onClientCommand(module, command, player, args)
    if module ~= "We" then return end

    -- ── spawnResident ──────────────────────────────────────────────────────────
    if command == "spawnResident" then
        local x, y, z = args.x, args.y, args.z
        if not x or not y then
            print("[We] spawnResident: missing coords for slot " .. tostring(args.slotIndex))
            return
        end

        local femaleChance = args.female and 100 or 0
        local outfit       = femaleChance > 0 and "F_Survivor_Base" or "M_Survivor_Base"

        local zombieList = addZombiesInOutfit(
            x, y, z,
            1,              -- count
            outfit,
            femaleChance,
            false,          -- crawler
            false,          -- fallOnFront
            false,          -- fakeDead
            false,          -- knockedDown
            false,          -- invulnerable
            false,          -- sitting
            1               -- health multiplier
        )

        if not zombieList or zombieList:size() == 0 then
            print("[We] spawnResident: spawn failed for slot " .. tostring(args.slotIndex))
            return
        end

        local zombie = zombieList:get(0)
        local id     = zombie:getPersistentOutfitID()

        -- Tag the zombie so OnZombieUpdate can identify it
        zombie:setVariable("WeResident", true)

        -- Store brain in the zombie's own ModData
        local brain    = args.brain
        brain.id       = id
        zombie:getModData().weBrain = brain

        -- Store in our global ModData for persistence across cell reloads
        local weMD = ModData.getOrCreate("We")
        if not weMD.residents then weMD.residents = {} end
        weMD.residents[tostring(args.slotIndex)] = {id=id, brain=brain}
        ModData.transmit("We")

        print("[We] Spawned resident NPC slot=" .. tostring(args.slotIndex) .. " id=" .. id)

    -- ── despawnResident ────────────────────────────────────────────────────────
    elseif command == "despawnResident" then
        local id = args.npcId
        if not id then return end

        -- Find the zombie in the loaded cell and remove it
        local cell = getCell()
        if cell then
            local zombieList = cell:getZombieList()
            for i = 0, zombieList:size() - 1 do
                local z = zombieList:get(i)
                if z:getPersistentOutfitID() == id then
                    z:removeFromMap()
                    print("[We] Removed NPC zombie id=" .. id)
                    break
                end
            end
        end

        -- Remove from global ModData
        local weMD = ModData.getOrCreate("We")
        if weMD.residents then
            weMD.residents[tostring(args.slotIndex)] = nil
        end
        ModData.transmit("We")

        print("[We] Despawned resident NPC slot=" .. tostring(args.slotIndex) .. " id=" .. id)
    end
end

Events.OnClientCommand.Add(onClientCommand)
