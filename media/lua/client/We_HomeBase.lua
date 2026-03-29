-- We: Home base context menu.
-- Right-click any ground tile to set it as the active character's home base.

local function onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if playerNum ~= 0 then return end

    local player = getSpecificPlayer(0)
    if not player then return end

    local fetch  = ISWorldObjectContextMenu.fetchVars
    local square = fetch and fetch.clickedSquare
    if not square then return end

    local activeSlot     = WeData.getActiveSlot()
    local activeSlotData = WeData.getData().slots[activeSlot]
    local sx, sy, sz     = square:getX(), square:getY(), square:getZ()

    context:addOption(
        getText("UI_We_SetHome", activeSlotData.name or ("Slot " .. activeSlot)),
        nil,
        function()
            WeData.setHome(activeSlot, sx, sy, sz)
            HaloTextHelper.addGoodText(player, getText("UI_We_HomeSet"))
        end
    )
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
