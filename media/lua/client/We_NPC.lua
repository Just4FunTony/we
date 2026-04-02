-- We: Client-side NPC manager.
-- Spawns, maintains, and despawns NPC stand-ins for inactive characters.
-- SP: uses createNPCPlayer for proper idle animations.
-- MP: falls back to server-side zombie via sendClientCommand.

WeNPC = WeNPC or {}
pcall(require, "XpSystem/ISUI/ISHealthPanel")
pcall(require, "TimedActions/ISMedicalCheckAction")
require "ISUI/ISCollapsableWindow"
require "ISUI/ISScrollingListBox"
require "ISUI/ISButton"

-- Live NPC cache: slotIndex → IsoPlayer or IsoZombie
WeNPC.Cache = {}

-- Slots whose zombie has been despawned but may still be alive for 1-2 frames.
-- onZombieUpdate must not re-cache these until the zombie is confirmed gone.
WeNPC.PendingDespawn = {}

local function getDataSafe(label)
    if not WeData or not WeData.getData then
        print("[We][NPC] WeData not ready in " .. tostring(label))
        return nil
    end
    return WeData.getData()
end

-- ─── Appearance capture ────────────────────────────────────────────────────────
-- Captures the player's hair/skin/beard visuals plus a list of worn item types.
-- Uses getWornItems() which is the authoritative clothing source for IsoPlayer.

function WeNPC.captureAppearance(player)
    local app = {}
    app.female      = player:isFemale()
    app.itemVisuals = {}
    app.clothingVisuals = {}

    local vis = player:getHumanVisual()
    if vis then
        if vis.getLastStandString then
            app.humanVisualLS = vis:getLastStandString()
        end
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

    -- Exact worn visuals snapshot (preserves tint, dirt, blood, patches, etc).
    local ivContainer = ItemVisuals and ItemVisuals.new()
    if ivContainer then
        player:getItemVisuals(ivContainer)
        for i = 0, ivContainer:size() - 1 do
            local iv = ivContainer:get(i)
            if iv and iv.getLastStandString then
                local s = iv:getLastStandString()
                if s and s ~= "" then
                    table.insert(app.clothingVisuals, s)
                end
            end
        end
    end

    -- B42: getItemVisuals can be empty briefly; fall back to each worn item's ItemVisual string.
    if #app.clothingVisuals == 0 then
        local worn = player.getWornItems and player:getWornItems()
        if worn and worn.size then
            for i = 0, worn:size() - 1 do
                local wi = worn.get and worn:get(i) or nil
                local item = wi and wi.getItem and wi:getItem() or nil
                if item and item.getVisual then
                    local v = item:getVisual()
                    if v and v.getLastStandString then
                        local s = v:getLastStandString()
                        if s and s ~= "" then
                            table.insert(app.clothingVisuals, s)
                        end
                    end
                end
            end
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

-- Copy appearance for network commands so clothingVisuals stays a plain sequential array.
function WeNPC.shallowAppearanceForBrain(app)
    if not app then return nil end
    local o = {
        female = app.female,
        skinTexture = app.skinTexture,
        hairStyle = app.hairStyle,
        hairColor = app.hairColor,
        beardStyle = app.beardStyle,
        beardColor = app.beardColor,
        humanVisualLS = app.humanVisualLS,
        itemVisuals = app.itemVisuals,
    }
    local cv = {}
    local src = app.clothingVisuals
    if type(src) == "table" then
        for i = 1, #src do
            cv[i] = src[i]
        end
    end
    o.clothingVisuals = cv
    return o
end

function WeNPC.applyVisuals(char, app)
    if not app or not char or not char.getHumanVisual then return end
    local vis = char:getHumanVisual()
    if not vis then return end
    -- Full-body LS on zombies then overwritten by itemVisuals still tends to reset clothing to "clean";
    -- when we have per-piece LS, skip human LS and rely on skin/hair fields + clothingVisuals.
    local skipHumanLs = instanceof(char, "IsoZombie") and app.clothingVisuals and #app.clothingVisuals > 0
    if app.humanVisualLS and vis.loadLastStandString and not skipHumanLs then
        pcall(vis.loadLastStandString, vis, app.humanVisualLS)
    end

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

    local itemVisuals = char.getItemVisuals and char:getItemVisuals()
    if itemVisuals then
        itemVisuals:clear()
        if app.clothingVisuals and #app.clothingVisuals > 0 then
            for _, ls in ipairs(app.clothingVisuals) do
                local item = ItemVisual.createLastStandItem and ItemVisual.createLastStandItem(ls)
                if item and item.getVisual then
                    local iv = item:getVisual()
                    if iv then
                        pcall(itemVisuals.add, itemVisuals, iv)
                    end
                end
            end
        elseif app.itemVisuals then
            for _, entry in ipairs(app.itemVisuals) do
                local t = type(entry) == "table" and (entry.itemType or "") or tostring(entry)
                local iv = ItemVisual.new()
                iv:setItemType(t)
                iv:setClothingItemName(t)
                itemVisuals:add(iv)
            end
        end
    end

    char:resetModelNextFrame()
    char:resetModel()
end

local function clearZombieAttachments(zombie)
    if not zombie then return end
    -- Clear by attachment locations (most reliable for "knife in back" visuals).
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
    local att = zombie.getAttachedItems and zombie:getAttachedItems()
    if att and att.clear then
        pcall(att.clear, att)
    end
    local body = zombie.getBodyDamage and zombie:getBodyDamage()
    local parts = body and body.getBodyParts and body:getBodyParts()
    if parts then
        for i = 0, parts:size() - 1 do
            local bp = parts:get(i)
            if bp and bp.setHaveBullet then pcall(bp.setHaveBullet, bp, false, 0) end
            if bp and bp.setBleedingTime and (bp.getBleedingTime and bp:getBleedingTime() or 0) <= 0 then
                pcall(bp.setBleedingTime, bp, 0)
            end
        end
    end
end

-- ─── Brain builder ─────────────────────────────────────────────────────────────

function WeNPC.buildBrain(slot, slotIndex)
    local app = WeNPC.shallowAppearanceForBrain(slot.appearance)
    -- If appearance snapshot missed clothing visuals, recover from serialized slot inventory.
    if app and (not app.clothingVisuals or #app.clothingVisuals == 0) and slot and slot.inventory then
        app.clothingVisuals = app.clothingVisuals or {}
        for _, itemData in ipairs(slot.inventory) do
            if itemData and itemData.lastStandStr then
                app.clothingVisuals[#app.clothingVisuals + 1] = itemData.lastStandStr
            end
        end
    end
    -- NPC anchors to the character's last saved position so they stay where you left them
    return {
        slotIndex  = slotIndex,
        slotName   = slot.name,
        homeX      = slot.x or 0,
        homeY      = slot.y or 0,
        homeZ      = slot.z or 0,
        appearance = app,
        female     = (slot.appearance and slot.appearance.female) or false,
    }
end

-- ─── Spawn / Despawn ──────────────────────────────────────────────────────────

function WeNPC.spawnForSlot(slotIndex)
    local player = getSpecificPlayer(0)
    if not player then return end

    local data = getDataSafe("spawnForSlot")
    if not data then return end
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
    local data = getDataSafe("despawnForSlot")
    if not data then return end
    local slot = data.slots[slotIndex]
    if slot then slot.npcId = nil end
    print("[We] Despawned NPC for slot " .. slotIndex)
end

-- Returns resident world position for a slot when available.
-- Used by character switch to spawn at NPC's current location, not stale saved one.
function WeNPC.getResidentPosition(slotIndex)
    local npc = WeNPC.Cache[slotIndex]
    if npc and npc ~= "pending" and npc.getX and npc.getY and npc.getZ then
        return npc:getX(), npc:getY(), npc:getZ()
    end

    local cell = getCell()
    if not cell then return nil end
    local zList = cell:getZombieList()
    for i = 0, zList:size() - 1 do
        local z = zList:get(i)
        if z and not z:isDead() then
            local zmd = z:getModData()
            local brain = zmd and zmd.weBrain
            local sameSlot = zmd and (
                zmd.weSlot == slotIndex
                or (brain and brain.slotIndex == slotIndex)
            )
            if sameSlot then
                return z:getX(), z:getY(), z:getZ()
            end
        end
    end
    return nil
end

function WeNPC.inspectResident(slotIndex)
    local data = getDataSafe("inspectResident")
    if not data or not data.slots then return end
    local slot = data.slots[slotIndex]
    if not slot then return end

    local wounds = slot.bodyDamage or {}
    local changed = 0
    for _, e in pairs(wounds) do
        if e then
            local hadUntreated = false
            if (e.cut or e.scratch) and not e.bandaged then hadUntreated = true end
            if e.deepWound and not e.stitched then hadUntreated = true end
            if (tonumber(e.infLevel) or 0) > 0.01 then hadUntreated = true end
            if hadUntreated then
                changed = changed + 1
            end

            if e.cut or e.scratch or e.deepWound then
                e.bandaged = true
                e.bandageLife = math.max(6.0, tonumber(e.bandageLife) or 0)
            end
            if e.deepWound then
                e.stitched = true
            end
            if (tonumber(e.infLevel) or 0) > 0 then
                e.infLevel = math.max(0, (tonumber(e.infLevel) or 0) - 0.25)
                e.disinfected = true
            end
        end
    end
    slot.bodyDamage = wounds

    local p = getSpecificPlayer(0)
    local name = tostring(slot.name or We.getText("UI_We_SlotFallback", tostring(slotIndex)))
    if p then
        if changed > 0 then
            HaloTextHelper.addGoodText(p, We.getText("UI_We_Inspect_Done", name))
        else
            HaloTextHelper.addText(p, We.getText("UI_We_Inspect_NoWounds", name))
        end
    end
end

local function buildHealthCheckText(slot)
    local wounds = slot.bodyDamage or {}
    local lines = {}
    local untreated = 0
    local total = 0

    for _, e in pairs(wounds) do
        if e then
            local tags = {}
            if e.scratch then tags[#tags + 1] = We.getText("UI_We_Wound_Scratch") end
            if e.cut then tags[#tags + 1] = We.getText("UI_We_Wound_Cut") end
            if e.deepWound then tags[#tags + 1] = We.getText("UI_We_Wound_DeepWound") end
            if e.fracture then tags[#tags + 1] = We.getText("UI_We_Wound_Fracture") end
            if e.bleeding then tags[#tags + 1] = We.getText("UI_We_Wound_Bleeding") end
            if (tonumber(e.infLevel) or 0) > 0.01 then tags[#tags + 1] = We.getText("UI_We_Wound_Infected") end
            if #tags > 0 then
                total = total + 1
                local isUntreated = false
                if (e.cut or e.scratch) and not e.bandaged then isUntreated = true end
                if e.deepWound and not e.stitched then isUntreated = true end
                if (tonumber(e.infLevel) or 0) > 0.01 and not e.disinfected then isUntreated = true end
                if isUntreated then untreated = untreated + 1 end
                lines[#lines + 1] = "- " .. table.concat(tags, ", ")
            end
        end
    end

    if total == 0 then
        return We.getText("UI_We_Health_NoWounds"), untreated
    end

    local head = We.getText("UI_We_Health_Wounds", tostring(total))
        .. "\n" .. We.getText("UI_We_Health_Untreated", tostring(untreated))
    return head .. "\n\n" .. table.concat(lines, "\n"), untreated
end

local WeTreatmentPanel = nil

local function collectWounds(slot)
    local out = {}
    for idx, e in pairs(slot.bodyDamage or {}) do
        if e then
            local tags = {}
            if e.scratch then tags[#tags + 1] = We.getText("UI_We_Wound_Scratch") end
            if e.cut then tags[#tags + 1] = We.getText("UI_We_Wound_Cut") end
            if e.laceration then tags[#tags + 1] = We.getText("UI_We_Wound_Laceration") end
            if e.deepWound then tags[#tags + 1] = We.getText("UI_We_Wound_DeepWound") end
            if e.fracture then tags[#tags + 1] = We.getText("UI_We_Wound_Fracture") end
            if e.bleeding then tags[#tags + 1] = We.getText("UI_We_Wound_Bleeding") end
            if (tonumber(e.infLevel) or 0) > 0.01 then tags[#tags + 1] = We.getText("UI_We_Wound_Infected") end
            if #tags > 0 then
                out[#out + 1] = {
                    idx = idx,
                    text = We.getText("UI_We_Health_Part", tostring((tonumber(idx) or 0) + 1))
                        .. ": " .. table.concat(tags, ", "),
                    data = e,
                }
            end
        end
    end
    table.sort(out, function(a, b) return (tonumber(a.idx) or 0) < (tonumber(b.idx) or 0) end)
    return out
end

local function applyTreatmentToWound(e, action)
    if not e then return end
    local changed = false
    if action == "bandage" then
        local hasOpen = (e.cut or e.scratch or e.laceration or e.deepWound or e.bleeding)
        if hasOpen and not e.bandaged then
            e.bandaged = true
            e.bandageLife = math.max(8.0, tonumber(e.bandageLife) or 0)
            e.bleeding = nil
            e.bleedingTime = nil
            changed = true
        end
    elseif action == "disinfect" then
        if ((tonumber(e.infLevel) or 0) > 0.01) and not e.disinfected then
            e.disinfected = true
            e.infLevel = math.max(0, (tonumber(e.infLevel) or 0) - 0.35)
            changed = true
        end
    elseif action == "stitch" then
        if e.deepWound and not e.stitched then
            e.stitched = true
            e.bleeding = nil
            e.bleedingTime = nil
            changed = true
        end
    elseif action == "splint" then
        if e.fracture and not e.splinted then
            e.splinted = true
            changed = true
        end
    end
    return changed
end

local function openTreatmentPanel(slotIndex)
    local data = getDataSafe("openTreatmentPanel")
    if not data or not data.slots then return false end
    local slot = data.slots[slotIndex]
    if not slot then return false end

    if WeTreatmentPanel and WeTreatmentPanel:isVisible() then
        WeTreatmentPanel:removeFromUIManager()
        WeTreatmentPanel = nil
    end

    local title = We.getText("UI_We_Treatment_Title", tostring(slot.name or We.getText("UI_We_SlotFallback", tostring(slotIndex))))
    local win = ISCollapsableWindow:new(getCore():getScreenWidth()/2 - 210, getCore():getScreenHeight()/2 - 170, 420, 340)
    win:initialise()
    win:setTitle(title)
    win.resizable = false
    win.moveWithMouse = true
    win:addToUIManager()
    win:setAlwaysOnTop(true)
    win:bringToTop()

    local list = ISScrollingListBox:new(10, 28, 400, 220)
    list:initialise()
    list:instantiate()
    list.itemheight = 22
    list.font = UIFont.Small
    win:addChild(list)
    win.woundList = list

    local function refreshList()
        list:clear()
        local wounds = collectWounds(slot)
        if #wounds == 0 then
            list:addItem(We.getText("UI_We_Treatment_None"), { idx = -1, data = nil })
            return
        end
        for _, w in ipairs(wounds) do
            list:addItem(w.text, w)
        end
        list.selected = 1
    end

    local function selectedWound()
        local it = list.items[list.selected]
        return it and it.item and it.item.data or nil
    end

    local function feedback(ok)
        local p = getSpecificPlayer(0)
        if not p then return end
        if ok then
            HaloTextHelper.addGoodText(p, We.getText("UI_We_Inspect_Done", tostring(slot.name or "")))
        else
            HaloTextHelper.addText(p, We.getText("UI_We_Inspect_NoWounds", tostring(slot.name or "")))
        end
    end

    local y = 258
    local bw = 95
    local gap = 7
    local bBandage = ISButton:new(10, y, bw, 24, We.getText("UI_We_Treatment_Bandage"), win, function()
        local e = selectedWound(); if not e then return end
        feedback(applyTreatmentToWound(e, "bandage")); refreshList()
    end)
    bBandage:initialise(); bBandage:instantiate(); win:addChild(bBandage)

    local bDisinfect = ISButton:new(10 + (bw + gap), y, bw, 24, We.getText("UI_We_Treatment_Disinfect"), win, function()
        local e = selectedWound(); if not e then return end
        feedback(applyTreatmentToWound(e, "disinfect")); refreshList()
    end)
    bDisinfect:initialise(); bDisinfect:instantiate(); win:addChild(bDisinfect)

    local bStitch = ISButton:new(10 + (bw + gap) * 2, y, bw, 24, We.getText("UI_We_Treatment_Stitch"), win, function()
        local e = selectedWound(); if not e then return end
        feedback(applyTreatmentToWound(e, "stitch")); refreshList()
    end)
    bStitch:initialise(); bStitch:instantiate(); win:addChild(bStitch)

    local bSplint = ISButton:new(10 + (bw + gap) * 3, y, bw, 24, We.getText("UI_We_Treatment_Splint"), win, function()
        local e = selectedWound(); if not e then return end
        feedback(applyTreatmentToWound(e, "splint")); refreshList()
    end)
    bSplint:initialise(); bSplint:instantiate(); win:addChild(bSplint)

    local bAll = ISButton:new(10, y + 28, 400, 24, We.getText("UI_We_Treatment_All"), win, function()
        local changedAny = false
        for _, e in pairs(slot.bodyDamage or {}) do
            changedAny = applyTreatmentToWound(e, "bandage") or changedAny
            changedAny = applyTreatmentToWound(e, "disinfect") or changedAny
            changedAny = applyTreatmentToWound(e, "stitch") or changedAny
            changedAny = applyTreatmentToWound(e, "splint") or changedAny
        end
        feedback(changedAny)
        refreshList()
    end)
    bAll:initialise(); bAll:instantiate(); win:addChild(bAll)

    refreshList()
    WeTreatmentPanel = win
    return true
end

function WeNPC.openHealthCheck(slotIndex)
    local data = getDataSafe("openHealthCheck")
    if not data or not data.slots then return end
    local slot = data.slots[slotIndex]
    if not slot then return end

    local displayName = tostring(slot.name or We.getText("UI_We_SlotFallback", tostring(slotIndex)))
    local report, untreated = buildHealthCheckText(slot)
    local msg = We.getText("UI_We_CheckHealth_Title", displayName) .. "\n\n"
        .. report .. "\n\n" .. We.getText("UI_We_CheckHealth_Treat")

    local modal = ISModalDialog:new(
        getCore():getScreenWidth() / 2 - 220,
        getCore():getScreenHeight() / 2 - 110,
        440, 220,
        msg,
        true,
        nil,
        function(_, button)
            if button and button.internal == "YES" then
                WeNPC.inspectResident(slotIndex)
            end
        end
    )
    modal.moveWithMouse = true
    modal:setCapture(true)
    modal:initialise()
    modal:addToUIManager()
    modal:setAlwaysOnTop(true)
    modal:bringToTop()

    if untreated <= 0 then
        -- If no untreated wounds, keep window informational (no action needed).
        if modal.no then modal.no:setTitle(We.getText("UI_We_Health_ActionOk")) end
        if modal.yes then modal.yes:setTitle(We.getText("UI_We_Health_TreatAnyway")) end
    end
end

local function openVanillaHealthPanelForResident(slotIndex)
    local npc = WeNPC.Cache and WeNPC.Cache[slotIndex] or nil
    if not npc or npc == "pending" then return false end
    if not ISHealthPanel then return false end
    if not (instanceof(npc, "IsoPlayer") or instanceof(npc, "IsoSurvivor")) then
        print("[We][NPC] vanilla health panel skipped (non-player resident) slot " .. tostring(slotIndex))
        return false
    end

    local me = getSpecificPlayer(0)
    if not me then return false end
    local playerNum = me:getPlayerNum()
    local x = getPlayerScreenLeft(playerNum) + 70
    local y = getPlayerScreenTop(playerNum) + 50

    -- Close previous medical check window for this target if present.
    local existing = ISMedicalCheckAction and ISMedicalCheckAction.getHealthWindowForPlayer
        and ISMedicalCheckAction.getHealthWindowForPlayer(npc)
    if existing and existing.close then
        pcall(existing.close, existing)
    end

    -- Vanilla path mirrors ISMedicalCheckAction:perform().
    local okPanel, panel = pcall(ISHealthPanel.new, ISHealthPanel, npc, x, y, 400, 400)
    if not okPanel or not panel then
        print("[We][NPC] vanilla health panel new() failed for slot " .. tostring(slotIndex))
        return false
    end
    if panel.initialise then pcall(panel.initialise, panel) end

    local title = getText("IGUI_health_playerHealth", tostring(npc:getDisplayName() or "NPC"))
    local okWrap, wrap = pcall(panel.wrapInCollapsableWindow, panel, title)
    if not okWrap or not wrap then
        print("[We][NPC] vanilla health panel wrap failed for slot " .. tostring(slotIndex))
        return false
    end
    if wrap.setResizable then wrap:setResizable(false) end
    if wrap.addToUIManager then wrap:addToUIManager() end
    if wrap.setAlwaysOnTop then wrap:setAlwaysOnTop(true) end
    if wrap.bringToTop then wrap:bringToTop() end

    if ISMedicalCheckAction and ISMedicalCheckAction.HealthWindows then
        ISMedicalCheckAction.HealthWindows[npc] = wrap
    end
    if panel.setOtherPlayer then
        panel:setOtherPlayer(me)
    end
    return true
end

local function resolveResidentSlotFromContext(worldObjects)
    local fetch = ISWorldObjectContextMenu and ISWorldObjectContextMenu.fetchVars
    local clickedChar = fetch and (fetch.clickedCharacter or fetch.clickedZombie or fetch.clickedObject)
    if clickedChar and clickedChar.getModData then
        local md = clickedChar:getModData()
        local brain = md and md.weBrain
        local s = md and (md.weSlot or (brain and brain.slotIndex))
        if s then return tonumber(s) end
    end

    for _, obj in ipairs(worldObjects or {}) do
        if obj and obj.getModData then
            local md = obj:getModData()
            local brain = md and md.weBrain
            local s = md and (md.weSlot or (brain and brain.slotIndex))
            if s then return tonumber(s) end
        end
    end

    local square = fetch and fetch.clickedSquare
    if square then
        local zlist = square.getMovingObjects and square:getMovingObjects()
        if zlist then
            for i = 0, zlist:size() - 1 do
                local z = zlist:get(i)
                if z and z.getModData then
                    local md = z:getModData()
                    local brain = md and md.weBrain
                    local s = md and (md.weSlot or (brain and brain.slotIndex))
                    if s then return tonumber(s) end
                end
            end
        end
    end

    -- Fallback: choose closest cached resident to player.
    local p = getSpecificPlayer(0)
    if p then
        local px, py = p:getX(), p:getY()
        local bestSlot, bestD2 = nil, 4.0 * 4.0
        for sidx, npc in pairs(WeNPC.Cache or {}) do
            if npc and npc ~= "pending" and npc.getX and npc.getY then
                local dx = npc:getX() - px
                local dy = npc:getY() - py
                local d2 = dx * dx + dy * dy
                if d2 <= bestD2 then
                    bestD2 = d2
                    bestSlot = tonumber(sidx)
                end
            end
        end
        if bestSlot then return bestSlot end
    end
    return nil
end

local function onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if test or playerNum ~= 0 then return end
    local slotIndex = resolveResidentSlotFromContext(worldObjects)
    if not slotIndex then return end
    context:addOption(We.getText("UI_We_CheckHealth"), nil, function()
        local ok, opened = pcall(openTreatmentPanel, slotIndex)
        if not ok or not opened then
            local ok2 = pcall(WeNPC.openHealthCheck, slotIndex)
            if not ok2 then WeNPC.inspectResident(slotIndex) end
        end
    end)
end

-- ─── OnZombieUpdate — per-tick maintenance for server-side zombie NPCs (MP) ──

local function onZombieUpdate(zombie)
    local zmd = zombie:getModData()
    local brain = zmd.weBrain
    -- B42 save-load safety: recover resident brain by slot id if zombie lost weBrain.
    if (not brain or not brain.slotIndex) and zmd.weSlot then
        local weMD = ModData.getOrCreate("We")
        local resident = weMD and weMD.residents and weMD.residents[tostring(zmd.weSlot)]
        if resident and resident.brain then
            brain = resident.brain
            zmd.weBrain = brain
            print("[We][NPC] Restored weBrain from ModData for slot " .. tostring(zmd.weSlot))
        end
    end
    if not brain or not brain.slotIndex then return end
    if not zmd.weSlot then zmd.weSlot = brain.slotIndex end

    -- Zombie confirmed dead: if this is not a managed despawn (PendingDespawn is nil),
    -- the NPC was killed by external means — remove the slot entirely.
    if zombie:isDead() or not zombie:getCurrentSquare() then
        if not WeNPC.PendingDespawn[brain.slotIndex] then
            -- Killed by player or world — remove the slot
            if WeData and WeData.killSlot then
                WeData.killSlot(brain.slotIndex)
            else
                print("[We][NPC] WeData not ready in onZombieUpdate.killSlot")
            end
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

    -- Persist resident's live location as the authoritative character location.
    -- This allows switching into the character at the NPC's current position.
    local zx, zy, zz = zombie:getX(), zombie:getY(), zombie:getZ()
    if math.abs((brain.homeX or zx) - zx) > 0.10 or math.abs((brain.homeY or zy) - zy) > 0.10
            or math.abs((brain.homeZ or zz) - zz) > 0.10 then
        brain.homeX, brain.homeY, brain.homeZ = zx, zy, zz
        local data = getDataSafe("onZombieUpdate.persistPos")
        if data and data.slots and data.slots[brain.slotIndex] then
            local slot = data.slots[brain.slotIndex]
            slot.x, slot.y, slot.z = zx, zy, zz
        end
    end

    -- Re-apply visuals if lost after cell reload
    if not brain.visualsApplied and brain.appearance then
        WeNPC.applyVisuals(zombie, brain.appearance)
        brain.visualsApplied = true
    end
    clearZombieAttachments(zombie)

    -- Keep zombie on floor and avoid random vertical glitches.
    if brain.homeZ and math.abs((zombie:getZ() or 0) - brain.homeZ) > 0.01 then
        zombie:setZ(brain.homeZ)
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
    local data = getDataSafe("onEveryMinute")
    if not data then return end
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

    local data = getDataSafe("onReceiveModData")
    if not data then return end
    for slotStr, resident in pairs(gData.residents) do
        local slotIndex = tonumber(slotStr)
        local slot = data.slots[slotIndex]
        if slot then slot.npcId = slotIndex end
    end
end

Events.OnReceiveGlobalModData.Add(onReceiveModData)
Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

-- ─── Init ──────────────────────────────────────────────────────────────────────

function WeNPC.init()
    WeNPC.Cache         = {}
    WeNPC.PendingDespawn = {}

    local data = getDataSafe("WeNPC.init")
    if not data then return end
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
            -- Always request spawn on load. Server-side dedup prevents duplicates if resident
            -- already exists; this also restores NPCs that were unloaded between sessions.
            WeNPC.spawnForSlot(i)
        end
    end

    print("[We] WeNPC initialised")
end
