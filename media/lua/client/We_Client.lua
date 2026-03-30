-- We: Client entry point — initialisation and NPC startup.

local function onGameStart()
    WeData.init()
    WeNPC.init()
    print("[We] Client ready. Press O to open the character panel.")
end

-- O opens the Characters panel in both SP and MP
local function onKeyPressed(key)
    if key == Keyboard.KEY_O then
        if getSpecificPlayer(0) then
            openWeTabPanel(nil)
        end
    end
end

Events.OnGameStart.Add(onGameStart)
Events.OnKeyPressed.Add(onKeyPressed)
