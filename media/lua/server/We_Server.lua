-- We: Server-side Lua
-- Reserved for multiplayer command relay (anti-cheat validation, etc.)

local function onClientCommand(module, command, player, args)
    if module ~= "We" then return end
    -- Future: handle "switchCharacter" commands from clients
end

Events.OnClientCommand.Add(onClientCommand)
