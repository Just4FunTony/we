-- We: Client entry point — initialisation and NPC startup.

local function onGameStart()
    WeData.init()
    WeNPC.init()
    print("[We] Client ready. Use the Faction button to open the character panel.")
end

Events.OnGameStart.Add(onGameStart)
