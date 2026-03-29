-- We: Client entry point — initialisation, key binding, NPC startup.

local function onGameStart()
    WeData.init()
    WeNPC.init()
    print("[We] Client ready. Press " .. tostring(We.HOTKEY) .. " to open the character panel.")
end

local function onKeyPressed(key)
    if key == We.HOTKEY then
        WePanel.toggle()
    end
end

Events.OnGameStart.Add(onGameStart)
Events.OnKeyPressed.Add(onKeyPressed)
