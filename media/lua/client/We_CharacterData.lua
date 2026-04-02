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
    MuscleStrain = CharacterStat.MUSCLESTRAIN or CharacterStat.MUSCLE_STRAIN,
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

local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function moodleLevelFrom01(v)
    v = clamp01(v or 0)
    if v <= 0.10 then return 0 end
    if v <= 0.30 then return 1 end
    if v <= 0.55 then return 2 end
    if v <= 0.80 then return 3 end
    return 4
end

local function tryCall(obj, methodName, ...)
    if not obj or not methodName then return nil end
    local fn = obj[methodName]
    if not fn then return nil end
    local ok, res = pcall(fn, obj, ...)
    if ok then return res end
    return nil
end

local function normalizeHealthTo100(v)
    local n = tonumber(v)
    if not n then return nil end
    if n <= 1.5 then return n * 100 end
    return n
end

local function readPlayerHealth100(player)
    if not player then return nil end
    local bd = player.getBodyDamage and player:getBodyDamage()
    local h = tryCall(bd, "getOverallBodyHealth")
    if h == nil then h = tryCall(bd, "getHealth") end
    if h == nil then h = tryCall(player, "getHealth") end
    return normalizeHealthTo100(h)
end

local function writePlayerHealth100(player, value)
    if not player or value == nil then return end
    local hp = math.max(0, math.min(100, tonumber(value) or 100))
    local bd = player.getBodyDamage and player:getBodyDamage()

    local function appliedCloseEnough()
        local now = readPlayerHealth100(player)
        return now and math.abs(now - hp) <= 1.5
    end

    -- Most reliable B42 path: apply delta via body damage.
    if bd and bd.getOverallBodyHealth then
        local cur = tonumber(bd:getOverallBodyHealth()) or nil
        if cur ~= nil then
            if cur <= 1.5 then cur = cur * 100 end
            if hp < cur and bd.ReduceGeneralHealth then
                pcall(bd.ReduceGeneralHealth, bd, cur - hp)
            elseif hp > cur and bd.AddGeneralHealth then
                pcall(bd.AddGeneralHealth, bd, hp - cur)
            end
            if appliedCloseEnough() then return end
        end
    end

    if bd and bd.setOverallBodyHealth then
        pcall(bd.setOverallBodyHealth, bd, hp)
        if appliedCloseEnough() then return end
        pcall(bd.setOverallBodyHealth, bd, hp / 100)
        if appliedCloseEnough() then return end
    end
    if bd and bd.setHealth then
        pcall(bd.setHealth, bd, hp)
        if appliedCloseEnough() then return end
        pcall(bd.setHealth, bd, hp / 100)
        if appliedCloseEnough() then return end
    end
    if player.setHealth then
        -- Build compatibility: some builds expect 0..100, some 0..1.
        pcall(player.setHealth, player, hp)
        if not appliedCloseEnough() then
            pcall(player.setHealth, player, hp / 100)
        end
    end
end

local function hasTraitLike(slot, needle)
    local n = tostring(needle or ""):lower()
    for _, t in ipairs(slot.traits or {}) do
        local s = tostring(t):lower()
        if s:find(n, 1, true) then return true end
    end
    return false
end

local function traitRateModifiers(slot)
    local m = {
        hunger = 1.0,
        thirst = 1.0,
        fatigue = 1.0,
        boredom = 1.0,
        stress = 1.0,
        painRecover = 1.0,
    }

    -- Needs
    if hasTraitLike(slot, "highthirst") then m.thirst = m.thirst * 1.6 end
    if hasTraitLike(slot, "lowthirst") then m.thirst = m.thirst * 0.65 end
    if hasTraitLike(slot, "heartyappetite") or hasTraitLike(slot, "heartyappitite") then
        m.hunger = m.hunger * 1.5
    end
    if hasTraitLike(slot, "lighteater") then m.hunger = m.hunger * 0.70 end
    if hasTraitLike(slot, "needsmoresleep") or hasTraitLike(slot, "sleepyhead") then
        m.fatigue = m.fatigue * 1.35
    end
    if hasTraitLike(slot, "needlesssleep") or hasTraitLike(slot, "wakeful") then
        m.fatigue = m.fatigue * 0.70
    end

    -- Mental state
    if hasTraitLike(slot, "agoraphobic") or hasTraitLike(slot, "claustrophobic") then
        m.stress = m.stress * 1.35
    end
    if hasTraitLike(slot, "brave") then m.stress = m.stress * 0.80 end
    if hasTraitLike(slot, "cowardly") then m.stress = m.stress * 1.25 end
    if hasTraitLike(slot, "prone to boredom") or hasTraitLike(slot, "pronetoboredom") then
        m.boredom = m.boredom * 1.4
    end

    -- Pain recovery tendency (coarse)
    if hasTraitLike(slot, "fasthealer") then m.painRecover = m.painRecover * 1.25 end
    if hasTraitLike(slot, "slowhealer") then m.painRecover = m.painRecover * 0.80 end

    return m
end

local function simulateInactiveWounds(slot, dtHours)
    slot.bodyDamage = slot.bodyDamage or {}
    local out = {
        painDelta = 0.0,
        stressDelta = 0.0,
        thirstDelta = 0.0,
        bleed01 = 0.0,
        infection01 = 0.0,
        healthDelta = 0.0,
    }

    for k, e in pairs(slot.bodyDamage) do
        if e then
            print("[We][HealthSim] part=" .. tostring(k)
                .. " cut=" .. tostring(e.cut)
                .. " scratch=" .. tostring(e.scratch)
                .. " laceration=" .. tostring(e.laceration)
                .. " deep=" .. tostring(e.deepWound)
                .. " bleed=" .. tostring(e.bleeding)
                .. " bandaged=" .. tostring(e.bandaged)
                .. " stitched=" .. tostring(e.stitched)
                .. " inf=" .. tostring(e.infLevel))
            local bandaged = e.bandaged and ((e.bandageLife or 0) > 0)
            local treated = bandaged or e.stitched or e.disinfected
            local healMul = treated and 1.35 or 0.65

            if e.scratch then
                e.scratchTime = math.max(0, (tonumber(e.scratchTime) or 5) - 1.00 * healMul * dtHours)
                if e.scratchTime <= 0 then
                    e.scratch = nil
                    e.scratchTime = nil
                end
            end

            if e.cut then
                e.cutTime = math.max(0, (tonumber(e.cutTime) or 8) - 0.85 * healMul * dtHours)
                if e.cutTime <= 0 then
                    e.cut = nil
                    e.cutTime = nil
                end
            end
            if e.laceration then
                e.lacerationTime = math.max(0, (tonumber(e.lacerationTime) or 12) - 0.60 * healMul * dtHours)
                if e.lacerationTime <= 0 then
                    e.laceration = nil
                    e.lacerationTime = nil
                end
            end

            if e.deepWound then
                local dwHeal = treated and 0.55 or 0.20
                e.deepTime = math.max(0, (tonumber(e.deepTime) or 20) - dwHeal * dtHours)
                if e.deepTime <= 0 then
                    e.deepWound = nil
                    e.deepTime = nil
                    e.stitched = nil
                end
            end

            if e.fracture then
                e.fracTime = math.max(0, (tonumber(e.fracTime) or 24) - 0.06 * dtHours)
                if e.fracTime <= 0 then
                    e.fracture = nil
                    e.fracTime = nil
                end
            end

            if e.bandageLife ~= nil then
                e.bandageLife = math.max(0, (tonumber(e.bandageLife) or 0) - 1.20 * dtHours)
                if e.bandageLife <= 0 then
                    e.bandaged = nil
                    e.bandageLife = nil
                end
            end

            if e.infLevel ~= nil then
                local inf = tonumber(e.infLevel) or 0
                if treated then
                    inf = math.max(0, inf - 0.012 * dtHours)
                else
                    inf = math.min(1.0, inf + 0.020 * dtHours)
                end
                e.infLevel = inf
                out.infection01 = math.max(out.infection01, inf)
            end

            local bleeding = false
            if e.deepWound and not e.stitched and not bandaged then bleeding = true end
            if (e.cut or e.scratch) and not bandaged then bleeding = true end
            if e.laceration and not bandaged then bleeding = true end
            if e.bleeding then bleeding = true end

            if bleeding then
                -- Bleeding moodle is severity-driven, not dt-driven.
                -- Any currently open bleed should instantly show the moodle.
                local sev = e.deepWound and 0.90 or ((e.laceration or e.bleeding) and 0.75 or 0.55)
                out.bleed01 = math.max(out.bleed01, sev)
                out.thirstDelta = out.thirstDelta + (e.deepWound and 0.035 or ((e.laceration or e.bleeding) and 0.025 or 0.018)) * dtHours
                out.stressDelta = out.stressDelta + (e.deepWound and 0.030 or 0.018) * dtHours
                out.healthDelta = out.healthDelta - (e.deepWound and 5.50 or ((e.laceration or e.bleeding) and 3.50 or 2.50)) * dtHours
                print("[We][HealthSim] bleeding part=" .. tostring(k)
                    .. " sev=" .. tostring(out.bleed01)
                    .. " healthDeltaNow=" .. tostring(out.healthDelta))
            end

            if e.deepWound then out.painDelta = out.painDelta + 0.030 * dtHours end
            if e.cut then out.painDelta = out.painDelta + 0.018 * dtHours end
            if e.scratch then out.painDelta = out.painDelta + 0.010 * dtHours end
            if e.laceration then out.painDelta = out.painDelta + 0.022 * dtHours end
            if e.fracture then out.painDelta = out.painDelta + 0.028 * dtHours end
            if e.infLevel and e.infLevel > 0 then
                out.painDelta = out.painDelta + (0.012 * e.infLevel) * dtHours
            end

            local hasAny = e.cut or e.scratch or e.deepWound or e.fracture or e.laceration or e.bleeding
                or ((e.infLevel or 0) > 0.001)
            if not hasAny then
                slot.bodyDamage[k] = nil
            end
        end
    end

    return out
end

local function simulateInactiveSlot(slot, dtHours)
    if not slot then return end
    slot.stats = slot.stats or {}
    slot.moodles = slot.moodles or {}

    -- Approximate vanilla-like passive progression while character is unloaded.
    local mod = traitRateModifiers(slot)
    local hpBefore = tonumber(slot.health) or 100
    local wounds = simulateInactiveWounds(slot, dtHours)

    local hunger = clamp01((slot.stats.Hunger or 0) + 0.040 * mod.hunger * dtHours)
    local thirst = clamp01((slot.stats.Thirst or 0) + 0.070 * mod.thirst * dtHours + (wounds.thirstDelta or 0))
    local fatigue = clamp01((slot.stats.Fatigue or 0) + 0.030 * mod.fatigue * dtHours)
    local boredom = clamp01((slot.stats.Boredom or 0) + 0.020 * mod.boredom * dtHours)
    local stress = clamp01((slot.stats.Stress or 0) + 0.015 * mod.stress * dtHours + (wounds.stressDelta or 0))
    local pain = clamp01((slot.stats.Pain or 0) - 0.005 * mod.painRecover * dtHours + (wounds.painDelta or 0))
    local mstrain = clamp01((slot.stats.MuscleStrain or 0) - 0.010 * dtHours)

    -- Unhappiness grows from prolonged bad needs.
    local unhappyBase = slot.stats.Unhappiness or 0
    local unhappyDelta = math.max(0, hunger - 0.50) * 0.020 * dtHours
        + math.max(0, thirst - 0.50) * 0.020 * dtHours
        + math.max(0, fatigue - 0.60) * 0.015 * dtHours
    local unhappiness = clamp01(unhappyBase + unhappyDelta)

    slot.stats.Hunger = hunger
    slot.stats.Thirst = thirst
    slot.stats.Fatigue = fatigue
    slot.stats.Endurance = clamp01(1 - fatigue)
    slot.stats.Boredom = boredom
    slot.stats.Stress = stress
    slot.stats.Pain = pain
    slot.stats.Unhappiness = unhappiness
    slot.stats.MuscleStrain = mstrain
    slot.health = math.max(0, math.min(100, hpBefore + (wounds.healthDelta or 0)))

    slot.moodles.Hungry = moodleLevelFrom01(hunger)
    slot.moodles.Thirst = moodleLevelFrom01(thirst)
    slot.moodles.Tired = moodleLevelFrom01(fatigue)
    slot.moodles.Bored = moodleLevelFrom01(boredom)
    slot.moodles.Stress = moodleLevelFrom01(stress)
    slot.moodles.Pain = moodleLevelFrom01(pain)
    slot.moodles.Unhappy = moodleLevelFrom01(unhappiness)
    slot.moodles.Endurance = moodleLevelFrom01(1 - (slot.stats.Endurance or 1))
    slot.moodles.Bleeding = moodleLevelFrom01(wounds.bleed01 or 0)

    if (wounds.bleed01 or 0) > 0 or math.abs((wounds.healthDelta or 0)) > 0.0001 then
        print("[We][HealthSim] slot=" .. tostring(slot.name or "?")
            .. " dtH=" .. tostring(dtHours)
            .. " bleed01=" .. tostring(wounds.bleed01 or 0)
            .. " healthDelta=" .. tostring(wounds.healthDelta or 0)
            .. " hp: " .. tostring(hpBefore) .. " -> " .. tostring(slot.health)
            .. " moodle.Bleeding=" .. tostring(slot.moodles.Bleeding))
    end
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
local pendingHealthRestore = nil
local pendingSlotTeleport = nil
local weDeathHudCleanupFrames = 0
local weSwitchPoseCleanupFrames = 0
-- When we trigger vanilla respawn from our death roster UI, we apply the chosen slot
-- to the newly created player on a short delay (avoids fighting the respawn pipeline).
local weDeathPendingSlotIndex = nil
local weDeathPendingApplyFrames = 0
-- Death swap: multiple resetModel/resetModelNextFrame in one frame hits Java AnimationTrack (null currentClip) + MultiTrack IOOBE — defer one reset.
local weDeathDeferredModelResetTicks = 0

local function scheduleDeferredDeathModelReset(ticksFromNow)
    local t = tonumber(ticksFromNow) or 4
    if weDeathDeferredModelResetTicks < t then
        weDeathDeferredModelResetTicks = t
    end
end

local function onTickDeferredDeathModelReset()
    if weDeathDeferredModelResetTicks <= 0 then return end
    weDeathDeferredModelResetTicks = weDeathDeferredModelResetTicks - 1
    if weDeathDeferredModelResetTicks ~= 0 then return end
    local p = getSpecificPlayer(0)
    if not p then return end
    print("[We] deferredDeathModelReset: applying resetModel (death-swap defer)")
    pcall(function() p:resetModelNextFrame() end)
    pcall(function() p:resetModel() end)
end
-- B42: After revive-from-death on the same IsoPlayer, Events.OnPlayerDeath often does NOT fire again.
-- Track rising edge isDead() for local player 0 so the second (and later) deaths still run the faction swap.
local wePrevLocalPlayerDead = false
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

local function onTickReapplyHealth()
    if not pendingHealthRestore then return end
    local player = getSpecificPlayer(0)
    local data = WeData and WeData.getData and WeData.getData()
    local slot = data and data.slots and data.slots[pendingHealthRestore.slotIndex]
    if player and slot and slot.health ~= nil then
        local now = readPlayerHealth100(player) or slot.health
        local saved = tonumber(slot.health) or now
        local playerDead = player.isDead and player:isDead()
        local target
        -- If we just switched from a dead character to a living slot, allow recovery to saved HP.
        -- Otherwise keep the conservative "no free heal" behavior.
        if saved > 0 and (playerDead or now <= 0.5) then
            target = saved
        else
            target = math.min(saved, now)
        end
        writePlayerHealth100(player, target)
        if pendingHealthRestore.ticks % 20 == 0 then
            print("[We][HealthSim] delayed apply health slot=" .. tostring(pendingHealthRestore.slotIndex)
                .. " target=" .. tostring(target) .. " now=" .. tostring(now)
                .. " dead=" .. tostring(playerDead)
                .. " ticksLeft=" .. tostring(pendingHealthRestore.ticks))
        end
    end
    pendingHealthRestore.ticks = pendingHealthRestore.ticks - 1
    if pendingHealthRestore.ticks > 0 then return end
    pendingHealthRestore = nil
end

local function onTickReapplyPosition()
    if not pendingSlotTeleport then return end
    local player = getSpecificPlayer(0)
    if not player then return end
    local x = pendingSlotTeleport.x
    local y = pendingSlotTeleport.y
    local z = pendingSlotTeleport.z
    if x ~= nil and y ~= nil then
        pcall(player.setX, player, x)
        pcall(player.setY, player, y)
        pcall(player.setZ, player, z or 0)
    end
    pendingSlotTeleport.ticks = pendingSlotTeleport.ticks - 1
    if pendingSlotTeleport.ticks > 0 then return end
    pendingSlotTeleport = nil
end

-- B42: Knox progression lives in CharacterStat (see debug ISStatsAndBody), not only BodyDamage flags.
local function clearB42KnoxVisualState(player, deferModelReset)
    if not player then return end
    local stats = player.getStats and player:getStats()
    if stats and CharacterStat then
        if CharacterStat.ZOMBIE_INFECTION then
            pcall(function() stats:set(CharacterStat.ZOMBIE_INFECTION, 0) end)
        end
        if CharacterStat.ZOMBIE_FEVER then
            pcall(function() stats:set(CharacterStat.ZOMBIE_FEVER, 0) end)
        end
    end
    -- Death / admin paths can leave the pawn invisible; user sees "no character" + zombie moodle.
    pcall(function() if player.setInvisible then player:setInvisible(false) end end)
    pcall(function() if player.setGodMod then player:setGodMod(false) end end)
    if deferModelReset then
        scheduleDeferredDeathModelReset(4)
    else
        pcall(function() if player.resetModelNextFrame then player:resetModelNextFrame() end end)
        pcall(function() if player.resetModel then player:resetModel() end end)
    end
end

local function clearPostDeathZombieState(player, slot, fullReset, deferModelReset)
    if not player then return end
    local hp = tonumber(slot and slot.health or 100) or 100
    if hp <= 0 then return end

    local bd = player.getBodyDamage and player:getBodyDamage()

    -- After custom post-death switch, vanilla may keep dead/infection flags from previous body.
    -- Clear them defensively so the "zombie" moodle/icon doesn't persist on a living slot.
    if bd then
        if fullReset then
            pcall(bd.RestoreToFullHealth, bd)
        end
        pcall(bd.setInfectionLevel, bd, 0)
        pcall(bd.setInfected, bd, false)
        pcall(bd.setIsInfected, bd, false)
        pcall(bd.setFakeInfected, bd, false)
        pcall(bd.setHasACold, bd, false)
    end
    clearB42KnoxVisualState(player, deferModelReset == true)
    pcall(player.setHealth, player, math.max(1, math.min(100, hp)))
    pcall(player.setHealth, player, math.max(0.01, math.min(1, hp / 100)))
end

-- Death / debug paths can leave the local player in ghost or invincible state; clear before normal play.
local function clearRuntimePlayerFightFlags(player)
    if not player then return end
    pcall(function()
        if player.setGhostMode then player:setGhostMode(false) end
    end)
    pcall(function()
        if player.setInvincible then player:setInvincible(false) end
    end)
end

-- ISUIHandler.setVisibleAllUI(true) does not set allUIVisible; HUD/vehicle UI stay hidden if player hid UI with V.
function WeData.restoreGameHudVisibility()
    if ISUIHandler then
        ISUIHandler.allUIVisible = true
    end
    if ISUIHandler and ISUIHandler.setVisibleAllUI then
        pcall(ISUIHandler.setVisibleAllUI, true)
    end
    if UIManager and UIManager.setVisibleAllUI then
        pcall(UIManager.setVisibleAllUI, true)
    end
end

-- Vanilla Events.OnPlayerDeath -> destroyPlayerData() nils ISPlayerData and removes inventory/hotbar/minimap UIs.
-- Reviving the same IsoPlayer does not fire OnCreatePlayer, so the HUD never comes back unless we recreate it.
function WeData.recreatePlayerHudAfterDeathRevive(player)
    if not player then return end
    if getCore and getCore():isDedicated() then return end
    if not createPlayerData then return end
    local id = 0
    if player.getPlayerNum then
        local ok, n = pcall(player.getPlayerNum, player)
        if ok and n ~= nil then id = n end
    end
    local ok, err = pcall(createPlayerData, id)
    if not ok then
        print("[We][DbgSwitch] recreatePlayerHudAfterDeathRevive failed: " .. tostring(err))
    else
        print("[We][DbgSwitch] recreatePlayerHudAfterDeathRevive ok playerNum=" .. tostring(id))
    end
    if WeData.restoreGameHudVisibility then
        WeData.restoreGameHudVisibility()
    end
end

-- Switching survivors can leave quick-slot UI stale (old attached items/icons).
-- Force hotbar to rebuild its slot list and attached icon mapping.
function WeData.refreshPlayerHotbarUi(player)
    if not player then return end
    local id = 0
    if player.getPlayerNum then
        local ok, n = pcall(player.getPlayerNum, player)
        if ok and n ~= nil then id = n end
    end
    local hb = getPlayerHotbar and getPlayerHotbar(id)
    if not hb then return end
    pcall(function() hb.needsRefresh = true end)
    pcall(function() hb:refresh() end)
    pcall(function() hb:reloadIcons() end)
end

-- Important: global setGameSpeed(1) in B42 SP is immediately followed by setGameSpeed(3) in the engine (ExitDebug),
-- which breaks real-time input feel. Use GameTime + UI speed control only — no global setGameSpeed here.
function WeData.normalizeGameSpeedToRealtime()
    local gt = getGameTime()
    if gt then
        if gt.setMultiplier then pcall(gt.setMultiplier, gt, 1) end
        if gt.setTrueMultiplier then pcall(gt.setTrueMultiplier, gt, 1) end
    end
    if UIManager and UIManager.getSpeedControls then
        local sc = UIManager.getSpeedControls()
        if sc and sc.SetCurrentGameSpeed then
            pcall(sc.SetCurrentGameSpeed, sc, 1)
        end
    end
end

-- After revive-from-death, the same IsoPlayer keeps skin blood/dirt from the dead body; clear it (vanilla ISHealthPanel pattern).
function WeData.clearPlayerBloodDirtVisual(player)
    if not player then return end
    local vis = player.getVisual and player:getVisual()
    if vis and BloodBodyPartType and BloodBodyPartType.MAX then
        local n = BloodBodyPartType.MAX:index()
        for i = 1, n do
            local part = BloodBodyPartType.FromIndex(i - 1)
            if part then
                pcall(function() vis:setBlood(part, 0) end)
                pcall(function() vis:setDirt(part, 0) end)
            end
        end
    end
    local inv = player.getInventory and player:getInventory()
    if inv and inv.getItems then
        local items = inv:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            if it then
                pcall(function()
                    if it.setBloodLevel then it:setBloodLevel(0) end
                    if it.setDirtiness then it:setDirtiness(0) end
                end)
            end
        end
    end
    -- Same-frame reset after loadSlot stacks with deferred skin reset — avoid extra AnimationTrack tear-down.
    if weDeathDeferredModelResetTicks > 0 then
        return
    end
    pcall(function() player:resetModelNextFrame() end)
end

-- Verbose movement diagnostics after death swap (search console for [We][MoveDbg]).
local WE_MOVE_DBG = true

local function logMovementSnapshot(player, tag)
    if not WE_MOVE_DBG or not player then return end
    local bits = {}
    local function add(label, fn)
        local ok, v = pcall(fn)
        bits[#bits + 1] = label .. "=" .. (ok and tostring(v) or "?")
    end
    add("blockMv", function() return player:isBlockMovement() end)
    add("ignDir", function() return player:isIgnoreInputsForDirection() end)
    add("invis", function() return player:isInvisible() end)
    add("sitGrnd", function() return player:isSitOnGround() end)
    add("sitFrn", function() return player:isSittingOnFurniture() end)
    add("dead", function() return player:isDead() end)
    add("ghost", function() return player:isGhostMode() end)
    add("asleep", function() return player:isAsleep() end)
    add("state", function()
        local s = player:getCurrentState()
        return s and tostring(s) or "nil"
    end)
    add("actEmpty", function() return player:getCharacterActions():isEmpty() end)
    local pn = 0
    pcall(function() pn = player:getPlayerNum() end)
    bits[#bits + 1] = "pnum=" .. tostring(pn)
    pcall(function()
        if ISTimedActionQueue and ISTimedActionQueue.hasActionType and ISWaitWhileGettingUp then
            bits[#bits + 1] = "qGetUp=" .. tostring(ISTimedActionQueue.hasActionType(player, ISWaitWhileGettingUp))
        end
    end)
    pcall(function()
        if JoypadState and JoypadState.players and JoypadState.players[pn + 1] then
            local jd = JoypadState.players[pn + 1]
            local f = jd.focus
            local fs = "nil"
            if f then
                if f.javaObject and f.javaObject.getClass then
                    fs = tostring(f.javaObject:getClass():getSimpleName())
                else
                    fs = tostring(f.type or f.Type or f)
                end
            end
            bits[#bits + 1] = "joyF=" .. fs
            bits[#bits + 1] = "joyDisMv=" .. tostring(JoypadState.disableMovement)
        end
    end)
    pcall(function()
        local sc = UIManager and UIManager.getSpeedControls and UIManager.getSpeedControls()
        if sc and sc.getCurrentGameSpeed then
            bits[#bits + 1] = "uiSpd=" .. tostring(sc:getCurrentGameSpeed())
        end
    end)
    pcall(function()
        local gt = getGameTime()
        if gt and gt.getTrueMultiplier then
            bits[#bits + 1] = "timeMult=" .. tostring(gt:getTrueMultiplier())
        end
    end)
    pcall(function()
        if isGamePaused then
            local ok, v = pcall(isGamePaused)
            bits[#bits + 1] = "paused=" .. (ok and tostring(v) or "?")
        else
            bits[#bits + 1] = "paused=n/a"
        end
    end)
    pcall(function()
        bits[#bits + 1] = "postDeathUI=" .. tostring(ISPostDeathUI and ISPostDeathUI.instance and ISPostDeathUI.instance[pn] ~= nil)
    end)
    pcall(function()
        if JoypadState then
            bits[#bits + 1] = "joyDisMvGlob=" .. tostring(JoypadState.disableMovement)
        end
    end)
    pcall(function()
        if getJoypadFocus then
            local f = getJoypadFocus(pn)
            local fs = "nil"
            if f then
                if f.javaObject and f.javaObject.getClass then
                    fs = tostring(f.javaObject:getClass():getSimpleName())
                else
                    fs = tostring(f.type or f.Type or f)
                end
            end
            bits[#bits + 1] = "getJoypadFocus=" .. fs
        end
    end)
    print("[We][MoveDbg] " .. tostring(tag) .. " | " .. table.concat(bits, " | "))
end

-- B42: IsoPlayer has no working setOnFloor/setKnockedDown in Lua (pcall always no-ops).
-- Sitting / "lying" idle uses isSitOnGround + setSitOnGround; emotes use PlayerSitOnGroundState + forceGetUp (vanilla).
local function forceExitBadPlayerLocomotionStates(player)
    if not (player and player.getCurrentState and player.changeState and IdleState and IdleState.instance) then return end
    local st = player:getCurrentState()
    if not st then return end
    local name = tostring(st)
    local isIdle = false
    pcall(function() isIdle = player:isCurrentState(IdleState.instance()) end)
    if isIdle then return end
    -- Logs showed PlayerFallDownState + PlayerHitReactionState persisting across revive — no movement, zombies ignore target.
    local bad = name:find("HitReactionState")
        or name:find("PlayerFallDownState")
        or name:find("FallDownState")
        or name:find("PlayerBumpState")
        or name:find("PlayerOnGroundState")
    if bad then
        -- Drop bump / fall anim drivers before FSM snap so we don't briefly play fall after revive.
        pcall(function()
            player:setVariable("BumpFall", false)
            player:setVariable("BumpDone", true)
        end)
        player:changeState(IdleState.instance())
        if WE_MOVE_DBG then
            local short = name:match("(Player[%w]+State)") or name
            print("[We][MoveDbg] changeState -> IdleState (was " .. tostring(short) .. ")")
        end
    end
end

local function clearPlayerStuckPoseAndActions(player)
    if not player then return end
    clearRuntimePlayerFightFlags(player)
    pcall(function() player:setInvisible(false) end)
    forceExitBadPlayerLocomotionStates(player)
    pcall(function() player:setIgnoreInputsForDirection(false) end)
    pcall(function()
        if ISTimedActionQueue and ISTimedActionQueue.clear then
            ISTimedActionQueue.clear(player)
        elseif player.StopAllActionQueue then
            player:StopAllActionQueue()
        end
    end)
    pcall(function()
        if player.isSitOnGround and player:isSitOnGround() and player.setSitOnGround then
            player:setSitOnGround(false)
        end
    end)
    pcall(function()
        if PlayerSitOnGroundState and player.isCurrentState
            and player:isCurrentState(PlayerSitOnGroundState.instance()) then
            player:setVariable("forceGetUp", true)
        end
    end)
    pcall(function()
        if player.isSittingOnFurniture and player:isSittingOnFurniture() and player.setSitOnFurnitureObject then
            player:setSitOnFurnitureObject(nil)
        end
    end)
    pcall(function() if player.setOnFloor then player:setOnFloor(false) end end)
    pcall(function() if player.setKnockedDown then player:setKnockedDown(false) end end)
    -- Death / UI can leave movement disabled (map, joypad focus, radial) — not covered by sit/prone clears.
    pcall(function()
        if player.isBlockMovement and player:isBlockMovement() and player.setBlockMovement then
            player:setBlockMovement(false)
        end
    end)
    -- Global joypad flag must be off BEFORE updateJoypadFocus, or that function forces movement inactive (JoyPadSetup.lua).
    pcall(function()
        if JoypadState then JoypadState.disableMovement = false end
    end)
    -- setJoypadFocus(nil) does not call updateJoypadFocus — setPlayerMovementActive can stay false while IsoPlayer flags look fine.
    pcall(function()
        if not player.getPlayerNum then return end
        local ok, n = pcall(player.getPlayerNum, player)
        if not ok or n == nil then return end
        if setJoypadFocus then setJoypadFocus(n, nil) end
        if JoypadState and JoypadState.players and JoypadState.players[n + 1] and updateJoypadFocus then
            updateJoypadFocus(JoypadState.players[n + 1])
        end
        if setPlayerMovementActive then setPlayerMovementActive(n, true) end
        pcall(function() player:setJoypadIgnoreAimUntilCentered(false) end)
        pcall(function()
            local cell = getCell()
            if cell and cell.setDrag then cell:setDrag(nil, n) end
        end)
    end)
    -- Stuck walk after death swap: cancel any active pathfind / walk-to.
    pcall(function()
        if player.getPathFindBehavior2 then
            local b = player:getPathFindBehavior2()
            if b and b.cancel then b:cancel() end
        end
    end)
    pcall(function() player:setIgnoreInputsForDirection(false) end)
    pcall(function() if player.updateMovementRates then player:updateMovementRates() end end)
    pcall(function()
        player:setVariable("BumpFall", false)
        -- stagger / fall uses BumpDone=false until anim ends; force done so AI targets us again
        player:setVariable("BumpDone", true)
    end)
    forceExitBadPlayerLocomotionStates(player)
end

local function restorePlayerControlAfterRevive(player, includeUiRestore)
    if not player then return end
    clearPlayerStuckPoseAndActions(player)
    if includeUiRestore and WeData.restoreGameHudVisibility then
        WeData.restoreGameHudVisibility()
    end
end

-- Death swap keeps the same IsoPlayer: vanilla drops an IsoDeadBody at the death cell — strip it after revive.
-- Zombies keep the same IsoMovingObject as chase target — clear so they don't migrate to the new body coords.
local function removeCorpsesNearWorldCoords(x, y, z, radius)
    local cell = getCell()
    if not cell or x == nil or y == nil then return end
    local fx = math.floor(x)
    local fy = math.floor(y)
    local fz = math.floor(z or 0)
    local r = tonumber(radius) or 2
    local removed = 0
    for dx = -r, r do
        for dy = -r, r do
            local sq = cell:getGridSquare(fx + dx, fy + dy, fz)
            if sq then
                local function stripFrom(list)
                    if not list then return end
                    for ii = list:size() - 1, 0, -1 do
                        local o = list:get(ii)
                        if o then
                            local isCorpse = false
                            pcall(function() isCorpse = instanceof(o, "IsoDeadBody") end)
                            if isCorpse then
                                pcall(function() sq:removeCorpse(o, false) end)
                                pcall(function() o:removeFromWorld() end)
                                pcall(function() o:removeFromSquare() end)
                                removed = removed + 1
                            end
                        end
                    end
                end
                stripFrom(sq.getObjects and sq:getObjects())
                stripFrom(sq.getStaticMovingObjects and sq:getStaticMovingObjects())
            end
        end
    end
    if removed > 0 then
        print("[We][DeathSwap] removed " .. tostring(removed) .. " corpse object(s) near death spot")
    end
end

local function clearZombieMemoryOfPlayer(player)
    if not player then return end
    local cell = getCell()
    if not cell then return end
    local zList = cell:getZombieList()
    local n = 0
    for i = 0, zList:size() - 1 do
        local z = zList:get(i)
        local zmd = z.getModData and z:getModData()
        if z and not z:isDead() and not (zmd and zmd.weBrain) then
            local t = nil
            pcall(function() t = z:getTarget() end)
            if t == player then
                pcall(function() z:setTarget(nil) end)
                pcall(function()
                    if z.setTargetSeenTime then z:setTargetSeenTime(0) end
                end)
                n = n + 1
            end
        end
    end
    if n > 0 then
        print("[We][DeathSwap] cleared chase target on " .. tostring(n) .. " zombie(s)")
    end
end

local wePostDeathZombieClearFrames = 0
-- Extra ticks: revive + vanilla FF keeps fighting our normalizeGameSpeed; re-apply control + speed.
local wePostDeathMoveUnlockFrames = 0
-- Runs once per frame after other We OnTick handlers: final normalize + control (see file end).
local wePostDeathLateFrames = 0

local function onTickPostDeathZombieClear()
    if wePostDeathZombieClearFrames <= 0 then return end
    wePostDeathZombieClearFrames = wePostDeathZombieClearFrames - 1
    local p = getSpecificPlayer(0)
    if p then clearZombieMemoryOfPlayer(p) end
end

local function onTickPostDeathMoveUnlock()
    if wePostDeathMoveUnlockFrames <= 0 then return end
    wePostDeathMoveUnlockFrames = wePostDeathMoveUnlockFrames - 1
    local p = getSpecificPlayer(0)
    if not p then return end
    restorePlayerControlAfterRevive(p, true)
    if WeData.normalizeGameSpeedToRealtime then
        WeData.normalizeGameSpeedToRealtime()
    end
    pcall(function()
        if JoypadState then JoypadState.disableMovement = false end
    end)
    pcall(function()
        if not p.getPlayerNum then return end
        local ok, n = pcall(p.getPlayerNum, p)
        if not ok or n == nil then return end
        if setJoypadFocus then setJoypadFocus(n, nil) end
        if JoypadState and JoypadState.players and JoypadState.players[n + 1] and updateJoypadFocus then
            updateJoypadFocus(JoypadState.players[n + 1])
        end
        if setPlayerMovementActive then setPlayerMovementActive(n, true) end
    end)
end

local _moveDbgReviveSeq = 0

function WeData.reviveRuntimePlayerForSwitch(targetHealth, fromDeath)
    local player = getSpecificPlayer(0)
    if not player then
        print("[We][DbgSwitch] reviveRuntimePlayerForSwitch: no player")
        return false
    end
    local hp = tonumber(targetHealth or 100) or 100
    if hp <= 0 then hp = 100 end
    local death = fromDeath == true
    if death then
        _moveDbgReviveSeq = _moveDbgReviveSeq + 1
    end
    local seqStr = death and ("seq=" .. tostring(_moveDbgReviveSeq) .. " ") or ""
    print("[We][DbgSwitch] reviveRuntimePlayerForSwitch begin"
        .. " hp=" .. tostring(hp)
        .. " fromDeath=" .. tostring(death)
        .. " isDead=" .. tostring(player.isDead and player:isDead())
        .. " " .. seqStr)

    if death then
        logMovementSnapshot(player, "revive_entry " .. seqStr)
    end

    clearPostDeathZombieState(player, { health = hp }, death, death)
    writePlayerHealth100(player, hp)
    restorePlayerControlAfterRevive(player, death)

    if death then
        logMovementSnapshot(player, "revive_afterRestoreCtrl " .. seqStr)
    end

    if death then
        if WeData.normalizeGameSpeedToRealtime then
            WeData.normalizeGameSpeedToRealtime()
        end

        -- Fully remove vanilla death panel instance so it doesn't keep player in death context.
        local pd = ISPostDeathUI and ISPostDeathUI.instance and ISPostDeathUI.instance[0]
        if pd then
            pcall(pd.setVisible, pd, false)
            pcall(pd.removeFromUIManager, pd)
            ISPostDeathUI.instance[0] = nil
        end

        if WeData.recreatePlayerHudAfterDeathRevive then
            WeData.recreatePlayerHudAfterDeathRevive(player)
        end
        -- Post-death UI may have left joypad focus on the removed panel → movement stays off.
        pcall(function()
            if setJoypadFocus and player.getPlayerNum then
                local ok, n = pcall(player.getPlayerNum, player)
                if ok and n ~= nil then setJoypadFocus(n, nil) end
            end
        end)
        pcall(function() player:setIgnoreInputsForDirection(false) end)
        pcall(function() if player.updateMovementRates then player:updateMovementRates() end end)
        logMovementSnapshot(player, "revive_afterDeathUi " .. seqStr)
    end
    local ghostStr = "?"
    do
        local ok, v = pcall(function() return player:isGhostMode() end)
        if ok then ghostStr = tostring(v) end
    end
    print("[We][DbgSwitch] reviveRuntimePlayerForSwitch end"
        .. " hpNow=" .. tostring(readPlayerHealth100(player))
        .. " isDeadNow=" .. tostring(player.isDead and player:isDead())
        .. " ghostNow=" .. ghostStr)
    if death then
        logMovementSnapshot(player, "revive_final " .. seqStr)
    end
    return true
end

-- Console / debug: call WeData.dumpMovementState("tag") when stuck after death swap.
function WeData.dumpMovementState(tag)
    logMovementSnapshot(getSpecificPlayer(0), tag or "manual_dump")
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
    -- Never persist this; a stuck true blocks every later OnPlayerDeath (silent early return).
    data._deathProcessing = false
    local p0 = getSpecificPlayer(0)
    if p0 and p0.isDead then
        wePrevLocalPlayerDead = p0:isDead() == true
    else
        wePrevLocalPlayerDead = false
    end
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
                        local localizedDefault = We.getText and We.getText("UI_We_DefaultCharacter", tostring(data.activeSlot))
                            or ("Character " .. tostring(data.activeSlot))
                        local legacyDefault = "Character " .. tostring(data.activeSlot)
                        if curName == "" or curName == localizedDefault or curName == legacyDefault then
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
    local bodyDamage = player:getBodyDamage()
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
    if bodyDamage and bodyDamage.getMuscleStrain then
        slot.stats.MuscleStrain = tonumber(bodyDamage:getMuscleStrain()) or (slot.stats.MuscleStrain or 0)
    end
    slot.health = readPlayerHealth100(player) or slot.health or 100
    print("[We][HealthSim] saveSlot(" .. tostring(index) .. ") read player health -> " .. tostring(slot.health))

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
        Bleeding = moodles and (moodles:getMoodleLevel(MoodleType.BLEEDING) or 0) or 0,
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
            local isBleeding = tryCall(bp, "isBleeding")
            if isBleeding then
                entry.bleeding = true
            end

            if bp.getScratchTime then
                local scratchTime = bp:getScratchTime()
                if scratchTime and scratchTime > 0 then
                    entry.scratch = true
                    entry.scratchTime = scratchTime
                end
            end
            local lacTime = tryCall(bp, "getLacerationTime")
            if lacTime and lacTime > 0 then
                entry.laceration = true
                entry.lacerationTime = lacTime
            end
            local bleedTime = tryCall(bp, "getBleedingTime")
            if bleedTime and bleedTime > 0 then
                entry.bleeding = true
                entry.bleedingTime = bleedTime
            end

            if bp.getWoundInfectionLevel then
                local infLvl = bp:getWoundInfectionLevel()
                if infLvl and infLvl > 0 then entry.infLevel = infLvl end
            end
            if bp.getStiffness then
                local stiff = bp:getStiffness()
                if stiff and stiff > 0 then entry.stiffness = stiff end
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
            local bandaged = tryCall(bp, "isBandaged")
            if bandaged == nil then
                bandaged = tryCall(bp, "bandaged")
            end
            if bandaged then
                entry.bandaged = true
                local bLife = tryCall(bp, "getBandageLife")
                if bLife ~= nil then entry.bandageLife = tonumber(bLife) or 0 end
            end
            local stitched = tryCall(bp, "isStitched")
            if stitched == nil then
                stitched = tryCall(bp, "stitched")
            end
            if stitched then entry.stitched = true end
            local disinfected = tryCall(bp, "isInfectedWound")
            if disinfected ~= nil then
                entry.disinfected = (not disinfected)
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
    local bodyDamage = player:getBodyDamage()

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
    pendingSlotTeleport = { x = slot.x, y = slot.y, z = slot.z, ticks = 45 }

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
                if saved.laceration and bp.setLacerationTime then
                    bp:setLacerationTime(saved.lacerationTime or 10)
                end
                if saved.bleeding and bp.setBleedingTime then
                    bp:setBleedingTime(saved.bleedingTime or 5)
                end
                if saved.infLevel and saved.infLevel > 0 then
                    bp:setWoundInfectionLevel(saved.infLevel)
                end
                if saved.stiffness and bp.setStiffness then
                    bp:setStiffness(saved.stiffness)
                end
                if saved.fracture then
                    bp:setFractureTime(saved.fracTime or 21)
                end
                if saved.deepWound then
                    bp:generateDeepWound()
                    if bp.setDeepWoundTime and saved.deepTime then bp:setDeepWoundTime(saved.deepTime) end
                end
                if saved.bandaged then
                    pcall(bp.setBandaged, bp, true, tonumber(saved.bandageLife) or 0)
                end
                if saved.stitched then
                    pcall(bp.setStitched, bp, true)
                end
            end
        end
    end
    if slot.health ~= nil then
        print("[We][HealthSim] loadSlot(" .. tostring(index) .. ") apply player health <- " .. tostring(slot.health))
        writePlayerHealth100(player, slot.health)
        pendingHealthRestore = { slotIndex = index, ticks = 120 }
    end
    local deferDeathModel = ensureModData()._deathSelectionMode == true
    clearPostDeathZombieState(player, slot, nil, deferDeathModel)
    if bodyDamage and bodyDamage.setMuscleStrain and slot.stats and slot.stats.MuscleStrain ~= nil then
        bodyDamage:setMuscleStrain(tonumber(slot.stats.MuscleStrain) or 0)
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
        if deferDeathModel then
            scheduleDeferredDeathModelReset(4)
        else
            player:resetModelNextFrame()
            player:resetModel()
        end
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
        slot.moodles.Bleeding = moodlesNow:getMoodleLevel(MoodleType.BLEEDING) or 0
    end

    -- Traits/model pipeline can run after infection clear; zero Knox again so moodle/model stay correct.
    clearB42KnoxVisualState(player, deferDeathModel)
    -- Post-death switch: first revive already restored UI; loadSlot can leave HUD/input wrong again.
    restorePlayerControlAfterRevive(player, ensureModData()._deathSelectionMode == true)

    print("[We] Slot " .. index .. " loaded.")
end

-- ─── Kill slot (NPC died) ─────────────────────────────────────────────────────

function WeData.killSlot(index)
    local data = ensureModData()
    local slot = data.slots[index]
    if not slot then return end

    -- A dead slot must be removed from rotation entirely.
    data.slots[index] = We.defaultSlot(index)
    WeNPC.Cache[index] = nil

    print("[We] Slot " .. index .. " killed (NPC died).")
end

-- ─── Switch ───────────────────────────────────────────────────────────────────

function WeData.switchTo(index)
    return WeData._switchTo(index, false)
end

function WeData._switchTo(index, ignoreHomeCheck)
    local data = ensureModData()
    local targetSlot = data.slots[index]
    if not targetSlot then return false end
    local deathMode = data._deathSelectionMode == true
    -- After killSlot the active row is empty (x nil) but activeSlot still points here — allow
    -- continuing on the same index only in post-death new-character flow.
    if index == data.activeSlot then
        local emptySame = targetSlot.x == nil
            and (deathMode or data._weLethalSwapFlow == true)
        if not emptySame then
            return false
        end
    end
    -- Block switching to dead *existing* slots only.
    -- Empty/new rows (x == nil) must remain selectable even if stale health <= 0.
    if targetSlot.x ~= nil and (tonumber(targetSlot.health) or 100) <= 0 then
        local player = getPlayer()
        if player then
            HaloTextHelper.addBadText(player, We.getText("UI_We_Switch_noSafehouse"))
        end
        print("[We] switchTo: blocked dead slot " .. tostring(index))
        return false
    end

    local playerNow = getPlayer()
    local postDeathUIActive = ISPostDeathUI and ISPostDeathUI.instance and ISPostDeathUI.instance[0]
    local playerDead = playerNow and playerNow.isDead and playerNow:isDead()
    local ok = ignoreHomeCheck or deathMode or postDeathUIActive or playerDead or WeData.isAtHomeBase()
    print("[We][DbgSwitch] precheck"
        .. " target=" .. tostring(index)
        .. " ignoreHome=" .. tostring(ignoreHomeCheck)
        .. " deathMode=" .. tostring(deathMode)
        .. " postDeathUI=" .. tostring(postDeathUIActive ~= nil)
        .. " playerDead=" .. tostring(playerDead)
        .. " ok=" .. tostring(ok)
        .. " targetHealth=" .. tostring(targetSlot.health))
    if not ok then
        local player = getPlayer()
        if player then
            HaloTextHelper.addBadText(player, We.getText("UI_We_Switch_noSafehouse"))
        end
        return false
    end

    local prev = data.activeSlot
    print("[We] switchTo: " .. prev .. " → " .. index)
    print("[We][TraitsFlow] switchTo begin"
        .. " | prev=" .. tostring(prev)
        .. " | target=" .. tostring(index)
        .. " | prevTraits=" .. summarizeTraits((data.slots[prev] and data.slots[prev].traits) or {})
        .. " | targetTraitsBefore=" .. summarizeTraits((data.slots[index] and data.slots[index].traits) or {}))

    local player = getPlayer()
    if not player then
        print("[We] switchTo: aborted (no local player object)")
        return false
    end

    -- In post-death selection flow we must explicitly recover the runtime player state
    -- before switching, otherwise the next slot may be treated as still dead.
    if deathMode and WeData.reviveRuntimePlayerForSwitch then
        WeData.reviveRuntimePlayerForSwitch(100, true)
    end

    local prevSlot = data.slots[prev]
    local prevAlive = prevSlot and (tonumber(prevSlot.health) or 100) > 0
    local shouldSavePrev = (not deathMode) and prevAlive and (data._weLethalSwapFlow ~= true)
    if shouldSavePrev then
        WeData.saveSlot(prev)
        print("[We][DbgSwitch] after saveSlot prev=" .. tostring(prev)
            .. " prevHealth=" .. tostring(data.slots[prev] and data.slots[prev].health))
    else
        print("[We][DbgSwitch] skip saveSlot prev=" .. tostring(prev)
            .. " deathMode=" .. tostring(deathMode)
            .. " prevAlive=" .. tostring(prevAlive))
    end

    -- Entering this character: use resident NPC live location when switching normally.
    -- After player death, scanning world zombies can match the wrong body; use saved slot coords only.
    local targetResidentX, targetResidentY, targetResidentZ = nil, nil, nil
    if not deathMode then
        targetResidentX, targetResidentY, targetResidentZ =
            WeNPC.getResidentPosition and WeNPC.getResidentPosition(index)
        if targetResidentX and targetResidentY then
            data.slots[index].x = targetResidentX
            data.slots[index].y = targetResidentY
            data.slots[index].z = targetResidentZ or data.slots[index].z or 0
            print("[We] switchTo: updated target slot " .. index .. " position from resident (" ..
                tostring(targetResidentX) .. "," .. tostring(targetResidentY) .. "," .. tostring(targetResidentZ) .. ")")
        end
    else
        print("[We] switchTo: deathMode — skip resident position scan, using saved slot coords for slot " .. tostring(index))
    end

    if data.slots[index].npcId or targetResidentX then
        WeNPC.despawnForSlot(index)
    end

    if (not deathMode) and data.slots[prev].x ~= nil and ((tonumber(data.slots[prev].health) or 100) > 0) then
        WeNPC.spawnForSlot(prev)
    else
        print("[We][DbgSwitch] skip spawnForSlot prev=" .. tostring(prev)
            .. " deathMode=" .. tostring(deathMode)
            .. " prevX=" .. tostring(data.slots[prev] and data.slots[prev].x)
            .. " prevHealth=" .. tostring(data.slots[prev] and data.slots[prev].health))
    end

    if data.slots[index].x == nil then
        local targetSlot = data.slots[index]
        local hasExistingData = (targetSlot.creation ~= nil)
            or (targetSlot.traits and #targetSlot.traits > 0)
            or (targetSlot.profession ~= nil)
            or (targetSlot.inventory and #targetSlot.inventory > 0)
            or (targetSlot.skillsList and #targetSlot.skillsList > 0)

        -- Existing slot lost coordinates (usually due death/edge-case): restore to home point
        -- instead of randomizing a brand new character over it.
        if hasExistingData and data.homeX ~= nil then
            targetSlot.x = data.homeX
            targetSlot.y = data.homeY
            targetSlot.z = data.homeZ or 0
            print("[We] switchTo: restored missing coords for slot " .. index
                .. " -> home (" .. tostring(targetSlot.x) .. "," .. tostring(targetSlot.y) .. "," .. tostring(targetSlot.z) .. ")")
        end
    end

    if data.slots[index].x == nil then
        -- New character slot
        if player then
            print("[We] switchTo: creating new char for slot " .. index)
            if (deathMode or data._weLethalSwapFlow == true) and data.homeX ~= nil then
                player:setX(data.homeX)
                player:setY(data.homeY)
                player:setZ(data.homeZ or 0)
            end
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
            slot.health = 100
            slot.appearance = WeNPC.captureAppearance(player)
            if WeData.reviveRuntimePlayerForSwitch then
                WeData.reviveRuntimePlayerForSwitch(slot.health or 100, deathMode)
            else
                clearPostDeathZombieState(player, slot)
            end
            pendingHealthRestore = { slotIndex = index, ticks = 120 }
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
    -- Death switch: same IsoPlayer is revived then loaded as another survivor — scrub blood/dirt and fix UI for several frames.
    if deathMode and player then
        if We and We.closeWeTabPanelIfOpen then
            We.closeWeTabPanelIfOpen()
        end
        WeData.clearPlayerBloodDirtVisual(player)
        WeData.restoreGameHudVisibility()
        restorePlayerControlAfterRevive(player, true)
        if WeData.normalizeGameSpeedToRealtime then
            WeData.normalizeGameSpeedToRealtime()
        end
        weDeathHudCleanupFrames = 30
    end
    data._deathSelectionMode = nil
    data._weLethalSwapFlow = nil
    print("[We][DbgSwitch] switchTo done target=" .. tostring(index)
        .. " active=" .. tostring(data.activeSlot)
        .. " playerDeadNow=" .. tostring(player.isDead and player:isDead())
        .. " playerHealthNow=" .. tostring(readPlayerHealth100(player)))
    if deathMode and player then
        logMovementSnapshot(player, "switchTo_death_done")
    end
    if player and WeData.refreshPlayerHotbarUi then
        WeData.refreshPlayerHotbarUi(player)
    end
    -- Pose/input can stick after loadSlot or death revive — same cleanup as non-death switches.
    if player then
        -- Extra frames: post-death bump/fall anims can still flash once on the *next* roster switch.
        weSwitchPoseCleanupFrames = 32
    end
    return true
end

-- ─── Faction swap on death (SP host): OnPlayerDeath always runs for lethal hits, including one-shot overkill.
-- There is no dependable Lua frame with 0 < HP ≤ ε before isDead() when damage exceeds remaining health.

local function resolveFactionSwapTarget(data, deadSlot)
    local candidates = {}
    for i = 1, We.MAX_SLOTS do
        if i ~= deadSlot then
            local s = data.slots[i]
            if s and s.x ~= nil and (tonumber(s.health) or 100) > 0 then
                candidates[#candidates + 1] = i
            end
        end
    end
    if #candidates > 0 then
        return candidates[ZombRand(#candidates) + 1]
    end
    -- New body at safehouse: use any empty row, or the row we are about to clear (full roster / no spare empty slot).
    if data.homeX ~= nil then
        for i = 1, We.MAX_SLOTS do
            if i ~= deadSlot then
                local s = data.slots[i]
                if not s or s.x == nil then
                    return i
                end
            end
        end
        print("[We][DeathSwap] resolve: safehouse — no free row except dead slot; new survivor at home in slot "
            .. tostring(deadSlot))
        return deadSlot
    end
    return nil
end

-- Post-death switch: vanilla may re-hide HUD or force fast-forward for several frames after revive.
local function onTickWeDeathHudCleanup()
    if weDeathHudCleanupFrames <= 0 then return end
    local leftBefore = weDeathHudCleanupFrames
    weDeathHudCleanupFrames = weDeathHudCleanupFrames - 1
    local p = getSpecificPlayer(0)
    if not p then return end
    if leftBefore == 30 or leftBefore == 20 or leftBefore == 10 or leftBefore == 1 then
        logMovementSnapshot(p, "deathHud_tick left=" .. tostring(leftBefore))
    end
    WeData.restoreGameHudVisibility()
    restorePlayerControlAfterRevive(p, true)
    if WeData.normalizeGameSpeedToRealtime then
        WeData.normalizeGameSpeedToRealtime()
    end
    if weDeathHudCleanupFrames == 7 or weDeathHudCleanupFrames == 0 then
        WeData.clearPlayerBloodDirtVisual(p)
    end
end

local function onTickWeSwitchPoseCleanup()
    if weSwitchPoseCleanupFrames <= 0 then return end
    local leftBefore = weSwitchPoseCleanupFrames
    weSwitchPoseCleanupFrames = weSwitchPoseCleanupFrames - 1
    local p = getSpecificPlayer(0)
    if not p then return end
    -- First ticks after switch: clear bump drivers only — resetModel here stacked with loadSlot and caused AnimationTrack NPE.
    if leftBefore > 28 then
        pcall(function() p:setVariable("BumpFall", false) end)
        pcall(function() p:setVariable("BumpDone", true) end)
    end
    clearPlayerStuckPoseAndActions(p)
end

-- ─── Auto-save on game write ──────────────────────────────────────────────────

local function onSave()
    local data = ensureModData()
    local player = getPlayer()
    -- While the vanilla player is dead, saving would write corpse XY into the active slot row and corrupt it.
    if data._deathSelectionMode then
        print("[We] onSave: skipped — post-death selection active")
        return
    end
    if player and player.isDead and player:isDead() then
        print("[We] onSave: skipped — player dead")
        return
    end
    WeData.saveSlot(data.activeSlot)
end

Events.OnSave.Add(onSave)
local function onEveryOneMinute()
    local data = ensureModData()
    local nowH = getGameTime() and getGameTime():getWorldAgeHours() or nil
    if not nowH then return end
    local player = getSpecificPlayer(0)
    if player and data.slots and data.slots[data.activeSlot] then
        data.slots[data.activeSlot].health = readPlayerHealth100(player) or data.slots[data.activeSlot].health or 100
    end
    for i = 1, We.MAX_SLOTS do
        if i ~= data.activeSlot then
            local slot = data.slots[i]
            if slot and slot.x ~= nil then
                local last = tonumber(slot._lastSimHour) or nowH
                local dt = nowH - last
                if dt > 0 then
                    simulateInactiveSlot(slot, dt)
                end
                if (tonumber(slot.health) or 100) <= 0 then
                    local p = getSpecificPlayer(0)
                    if p then
                        sendClientCommand(p, "We", "killResident", { slotIndex = i })
                    end
                    WeData.killSlot(i)
                end
                slot._lastSimHour = nowH
            end
        end
    end
end
Events.EveryOneMinute.Add(onEveryOneMinute)

-- ─── Vanilla respawn after death menu selection ─────────────────────────
-- Your requirement:
--   vanilla death -> show roster menu -> clicking NPC/new slot triggers vanilla
--   respawn -> after the new player exists, we apply the chosen slot state.
function WeData.requestVanillaRespawnForDeathSlot(slotIndex)
    local data = ensureModData()
    if not data or data._deathSelectionMode ~= true then
        print("[We][DeathSwap] requestVanillaRespawnForDeathSlot: not in death selection mode")
        return false
    end
    if not slotIndex then return false end

    local p0 = getSpecificPlayer and getSpecificPlayer(0) or nil
    local p0Dead = p0 and p0.isDead and p0:isDead()
    print("[We][DeathSwap] requestVanillaRespawnForDeathSlot(slotIndex=" .. tostring(slotIndex)
        .. ") deathSelMode=" .. tostring(data._deathSelectionMode)
        .. " openDeathRoster=" .. tostring(data._openDeathRoster)
        .. " p0Dead=" .. tostring(p0Dead))

    weDeathPendingSlotIndex = slotIndex
    weDeathPendingApplyFrames = 40

    -- Do not keep re-opening roster panel while vanilla respawn is running.
    data._openDeathRoster = false

    -- Close our tab panel immediately so it can't steal keyboard/joypad.
    if We and We.closeWeTabPanelIfOpen then
        We.closeWeTabPanelIfOpen()
    end

    local pd = ISPostDeathUI and ISPostDeathUI.instance and ISPostDeathUI.instance[0]
    if not (pd and pd.onRespawn) then
        print("[We][DeathSwap] requestVanillaRespawnForDeathSlot: ISPostDeathUI missing")
        weDeathPendingSlotIndex = nil
        weDeathPendingApplyFrames = 0
        return false
    end

    print("[We][DeathSwap] roster click -> vanilla respawn slot=" .. tostring(slotIndex))
    local okRespawn, errRespawn = pcall(function() pd:onRespawn() end)
    print("[We][DeathSwap] pd:onRespawn result ok=" .. tostring(okRespawn) .. " err=" .. tostring(errRespawn))

    -- In mouse respawn, CoopCharacterCreation UI is created by onRespawn().
    -- Auto-accept so the game returns control immediately.
    if CoopCharacterCreation and CoopCharacterCreation.instance and CoopCharacterCreation.instance.accept then
        local okAcc, errAcc = pcall(function() CoopCharacterCreation.instance:accept() end)
        print("[We][DeathSwap] CoopCharacterCreation:accept ok=" .. tostring(okAcc) .. " err=" .. tostring(errAcc))
    else
        print("[We][DeathSwap] CoopCharacterCreation.instance.accept not ready (skip auto-accept)")
    end

    return true
end

local function onTickWeApplyDeathPendingRespawn()
    if weDeathPendingSlotIndex == nil then return end
    local framesLeft = weDeathPendingApplyFrames or 0

    -- Read vanilla post-death panel presence: when it's gone, we can safely
    -- apply our slot state (even if IsoPlayer.isDead() hasn't flipped yet).
    local pdActive = ISPostDeathUI and ISPostDeathUI.instance and ISPostDeathUI.instance[0] ~= nil

    if framesLeft <= 0 and not pdActive then
        pdActive = false
    end

    if framesLeft == 39 or framesLeft == 30
        or framesLeft == 20 or framesLeft == 10
        or framesLeft <= 3 then
        print("[We][DeathSwap] pendingRespawn tick framesLeft=" .. tostring(framesLeft)
            .. " pdActive=" .. tostring(pdActive))
    end

    -- Always wait at least until vanilla respawn UI is removed.
    -- Do not block on IsoPlayer.isDead(), because in your log p:isDead()
    -- stays true for too long even after CoopCharacterCreation:accept().
    if pdActive then
        if framesLeft <= 1 then
            print("[We][DeathSwap] pendingRespawn: vanilla death UI still active; forcing later.")
        end
    else
        local p = getSpecificPlayer(0)
        if p then
            -- Apply even if p isDead() (better: correct model/appearance + exit death selection).
            local slotIndex = weDeathPendingSlotIndex
            weDeathPendingSlotIndex = nil
            weDeathPendingApplyFrames = 0

            local data = ensureModData()
            print("[We][DeathSwap] pendingRespawn applying slotIndex=" .. tostring(slotIndex)
                .. " deathSelMode(before)=" .. tostring(data and data._deathSelectionMode))
            -- Make it a normal switch. If _deathSelectionMode stays true, _switchTo runs
            -- the old death-revive path, which we're removing in this variant.
            data._deathSelectionMode = nil
            data._openDeathRoster = nil
            -- Prevent saving prev slot data into the killed row.
            data._weLethalSwapFlow = true

            logMovementSnapshot(p, "pendingRespawn_preSwitch")

            local ok = WeData._switchTo(slotIndex, true)
            if ok then
                print("[We][DeathSwap] applied pending respawn slotIndex=" .. tostring(slotIndex))
                local pAfter = getSpecificPlayer(0)
                if pAfter then
                    logMovementSnapshot(pAfter, "pendingRespawn_postSwitch")
                    clearZombieMemoryOfPlayer(pAfter)
                end
            else
                print("[We][DeathSwap] apply pending respawn failed for slotIndex=" .. tostring(slotIndex))
            end
            return
        else
            -- Player object not ready yet; keep waiting.
        end
    end

    -- Countdown after each tick.
    weDeathPendingApplyFrames = framesLeft - 1
    if weDeathPendingApplyFrames < 0 then weDeathPendingApplyFrames = 0 end
end

Events.OnTick.Add(onTickReapplySkills)
Events.OnTick.Add(onTickReapplyHealth)
Events.OnTick.Add(onTickReapplyPosition)
Events.OnTick.Add(onTickDeferredDeathModelReset)
Events.OnTick.Add(onTickWeApplyDeathPendingRespawn)
Events.OnTick.Add(onTickWeDeathHudCleanup)
Events.OnTick.Add(onTickWeSwitchPoseCleanup)
Events.OnTick.Add(onTickPostDeathZombieClear)
Events.OnTick.Add(onTickPostDeathMoveUnlock)

local function tryBeginFactionDeathSwap(player, sourceTag)
    if not player then
        print("[We][DeathSwap] skip: player is nil (" .. tostring(sourceTag) .. ")")
        return
    end
    local pn = player.getPlayerNum and player:getPlayerNum()
    if pn ~= 0 then
        print("[We][DeathSwap] skip: playerNum=" .. tostring(pn) .. " (" .. tostring(sourceTag) .. ")")
        return
    end
    local dead = player.isDead and player:isDead()
    if not dead then
        -- Stops duplicate work if OnPlayerDeath queues after we already revived in the same frame.
        return
    end
    local data = ensureModData()
    if data._deathProcessing then
        print("[We][DeathSwap] skip: _deathProcessing (" .. tostring(sourceTag) .. ")")
        return
    end
    data._deathProcessing = true

    local function runDeathSwap()
        local deadSlot = data.activeSlot
        local deathX, deathY, deathZ = player:getX(), player:getY(), player:getZ()
        print("[We][DeathSwap] death detected activeSlot=" .. tostring(deadSlot) .. " via " .. tostring(sourceTag))

        -- Final requirement:
        -- vanilla death -> we show roster choice
        -- then on user click we trigger vanilla respawn and only afterwards apply slot state.

        data._deathSelectionMode = true
        data._openDeathRoster = true
        data._weLethalSwapFlow = nil

        -- Remove the dead row from the roster list.
        WeData.killSlot(deadSlot)

        -- Cleanup: prevent zombies from sticking to corpse/old target around death spot.
        removeCorpsesNearWorldCoords(deathX, deathY, deathZ, 2)
        pcall(function()
            sendClientCommand(player, "We", "deathSwapCleanup", {
                x = deathX, y = deathY, z = deathZ, radius = 2,
            })
        end)
    end

    local ok, err = pcall(runDeathSwap)
    if not ok then
        print("[We][DeathSwap] ERROR in death swap: " .. tostring(err))
        data._weLethalSwapFlow = nil
        data._deathSelectionMode = nil
        data._openDeathRoster = true
    end
    data._deathProcessing = false
end

local function onPlayerDeath(player)
    tryBeginFactionDeathSwap(player, "OnPlayerDeath")
end
Events.OnPlayerDeath.Add(onPlayerDeath)

local function onLocalPlayerUpdateDeathEdge(player)
    if not player or (player.getPlayerNum and player:getPlayerNum() ~= 0) then return end
    local dead = player.isDead and player:isDead()
    if dead and not wePrevLocalPlayerDead then
        print("[We][DeathSwap] isDead edge (OnPlayerUpdate) — OnPlayerDeath is unreliable after revive")
        tryBeginFactionDeathSwap(player, "isDeadEdge")
    end
    wePrevLocalPlayerDead = dead == true
end
Events.OnPlayerUpdate.Add(onLocalPlayerUpdateDeathEdge)

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

-- Late pass: other OnTick code (and vanilla) may run after our handlers; re-apply realtime speed + movement.
local function onTickWeDeathLatePass()
    if wePostDeathLateFrames <= 0 then return end
    wePostDeathLateFrames = wePostDeathLateFrames - 1
    local p = getSpecificPlayer(0)
    if not p then return end
    if WeData.normalizeGameSpeedToRealtime then
        WeData.normalizeGameSpeedToRealtime()
    end
    restorePlayerControlAfterRevive(p, true)
end
Events.OnTick.Add(onTickWeDeathLatePass)
