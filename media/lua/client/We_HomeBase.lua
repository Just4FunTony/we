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

    if not WeData or not WeData.getData then
        print("[We][HomeBase] WeData not ready; skipping context option")
        return
    end
    local data = WeData.getData()
    if not data then return end
    if data.homeX then return end  -- already set; remove via F2 panel

    local sx, sy, sz = square:getX(), square:getY(), square:getZ()

    context:addOption(
        We.getText("UI_We_SetHome"),
        nil,
        function()
            if not WeData or not WeData.setHome then return end
            WeData.setHome(sx, sy, sz)
            HaloTextHelper.addGoodText(player, We.getText("UI_We_HomeSet"))
        end
    )
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)
