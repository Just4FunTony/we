-- We: Shared constants and data schema (loaded on client and server)

We = We or {}
We.Version      = "2.0"
We.MAX_SLOTS    = 4
We.MOD_DATA_KEY = "We_Characters"
We.HOME_SWITCH_RADIUS = 8            -- max tiles from home base to allow switching

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

        -- Home base position (set via right-click context menu)
        homeX = nil, homeY = nil, homeZ = nil,

        -- Appearance snapshot captured when switching away from this character.
        -- Used to dress the NPC standing-in at home.
        appearance = {
            female      = false,
            skinTexture = nil,
            hairStyle   = nil,
            hairColor   = nil,   -- {r, g, b}
            beardStyle  = nil,
            beardColor  = nil,   -- {r, g, b}
            clothing    = {},    -- bodyLocation -> itemFullType
        },

        -- Rolled character loadout (set on first use, nil until then)
        creation = nil,  -- {profession, positive={...}, negative={...}}

        -- Persistent outfit ID of the NPC zombie representing this character.
        -- nil when the character is active (being played by the player).
        npcId = nil,
    }
end

print("[We] Shared loaded. Version: " .. We.Version)
