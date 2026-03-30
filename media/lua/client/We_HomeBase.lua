-- We: Right-click any tile to set it as the home base for character switching.

local function onFillWorldObjectContextMenu(playerNum, context, worldObjects, test)
    if playerNum ~= 0 then return end
    local player = getSpecificPlayer(0)
    if not player then return end

    local fetch  = ISWorldObjectContextMenu.fetchVars
    local square = fetch and fetch.clickedSquare
    if not square then return end

    -- Only show when no safehouse is set yet (MP uses PZ safehouse system)
    local isMP = getWorld and getWorld():getGameMode() == "Multiplayer"
    if isMP then return end

    local data = WeData.getData()
    if data.homeX then return end  -- already set; remove via F2 panel

    local sx, sy, sz = square:getX(), square:getY(), square:getZ()

    context:addOption(
        We.getText("UI_We_SetHome"),
        nil,
        function()
            WeData.setHome(sx, sy, sz)
            HaloTextHelper.addGoodText(player, We.getText("UI_We_HomeSet"))
        end
    )
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
