-- We: Shared constants and data schema (loaded on client and server)

We = We or {}
We.Version    = "1.0"
We.MAX_SLOTS  = 4
We.MOD_DATA_KEY = "We_Characters"
We.HOTKEY     = Keyboard.KEY_F6   -- open/close the character panel

-- Stat keys used for save/load; each maps to stats:get<Key>() / stats:set<Key>()
We.STATS_KEYS = {
    "Hunger", "Thirst", "Fatigue", "Boredom",
    "Stress", "Panic", "Pain", "Endurance", "Unhappiness",
}

-- Returns a fresh, empty slot table (slot.x == nil means "never saved")
function We.defaultSlot(index)
    return {
        name      = "Character " .. index,
        x         = nil, y = nil, z = nil,
        stats     = {},
        inventory = {},
        skills    = {},
    }
end

print("[We] Shared loaded. Version: " .. We.Version)
