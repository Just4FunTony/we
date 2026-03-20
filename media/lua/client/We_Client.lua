-- We: Client entry point — initialisation and key binding

local function onGameStart()
    WeData.init()
    print("[We] Client ready. Press " .. tostring(We.HOTKEY) .. " to open the character panel.")
end

local function onKeyPressed(key)
    if key == We.HOTKEY then
        WePanel.toggle()
    end
end

Events.OnGameStart.Add(onGameStart)
Events.OnKeyPressed.Add(onKeyPressed)
