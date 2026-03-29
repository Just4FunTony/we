-- We: Home base context menu.
-- Right-click any ground tile to set it as the active character's home base.
-- When standing at the home base, also shows "Switch to <character>" options
-- for every inactive slot — this is the in-world "base management menu".

local function distToHome(player, slot)
    if not slot.homeX then return math.huge end
    local dx = player:getX() - slot.homeX
    local dy = player:getY() - slot.homeY
    return math.sqrt(dx * dx + dy * dy)
end

local function onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if playerNum ~= 0 then return end

    local player = getSpecificPlayer(0)
    if not player then return end

    local fetch  = ISWorldObjectContextMenu.fetchVars
    local square = fetch and fetch.clickedSquare
    if not square then return end

    local activeSlot = WeData.getActiveSlot()
    local activeData = WeData.getData()
    local activeSlotData = activeData.slots[activeSlot]
    local sx, sy, sz = square:getX(), square:getY(), square:getZ()

    -- ── "Set home base" option — always available ─────────────────────────────
    context:addOption(
        getText("UI_We_SetHome", activeSlotData.name or ("Slot " .. activeSlot)),
        nil,
        function()
            WeData.setHome(activeSlot, sx, sy, sz)
            HaloTextHelper.addTextWithArrow(
                player,
                getText("UI_We_HomeSet"),
                HaloTextHelper.getColorGreen()
            )
        end
    )

    -- ── Switch options — only when player is at their home base ───────────────
    local atBase = distToHome(player, activeSlotData) <= We.HOME_SWITCH_RADIUS

    if atBase then
        local data = WeData.getData()

        -- Separator (empty disabled option acts as visual divider)
        local sep = context:addOption("──── " .. getText("UI_We_BaseMenu_Title") .. " ────")
        sep.notAvailable = true

        for i = 1, We.MAX_SLOTS do
            if i ~= activeSlot then
                local slot = data.slots[i]
                local label

                if slot.x == nil then
                    -- Slot never used — offer to start as this character
                    label = getText("UI_We_BaseMenu_StartAs", slot.name)
                else
                    -- Slot has data — switch into it
                    label = getText("UI_We_BaseMenu_SwitchTo", slot.name)
                end

                local idx = i   -- capture for closure
                context:addOption(label, nil, function()
                    WeData.switchTo(idx)
                end)
            end
        end
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
