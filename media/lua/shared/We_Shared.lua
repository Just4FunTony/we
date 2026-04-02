-- We: Shared constants and data schema (loaded on client and server)

We = We or {}
We.Version      = "2.0"
We.MAX_SLOTS    = 16
We.MOD_DATA_KEY = "We_Characters"
We.HOME_SWITCH_RADIUS = 30   -- tiles radius around the custom home point

-- Stat keys for save/load, paired with CharacterStat enum values (B42 API)
We.STATS_KEYS = {
    "Hunger", "Thirst", "Fatigue", "Endurance", "Boredom",
    "Stress", "Pain", "Unhappiness", "MuscleStrain",
}

-- Returns a fresh, empty slot table (slot.x == nil means "never saved")
function We.defaultSlot(index)
    return {
        name      = We.getText and We.getText("UI_We_DefaultCharacter", tostring(index)) or ("Character " .. tostring(index)),
        x         = nil, y = nil, z = nil,
        stats     = {},
        moodles   = {},
        inventory = {},
        skills    = {},

        -- Appearance snapshot captured when switching away from this character.
        -- Used to dress the NPC standing-in at home.
        appearance = {
            female      = false,
            skinTexture = nil,  -- string name, e.g. "MaleBody01a"
            hairStyle   = nil,
            hairColor   = nil,  -- {r, g, b}
            beardStyle  = nil,
            beardColor  = nil,  -- {r, g, b}
            itemVisuals = {},   -- ordered list of itemFullType strings (rendered layer order)
        },

        -- Profession and traits (ResourceLocation name strings, serialization-safe)
        profession = nil,
        traits     = {},

        -- Rolled character loadout (set on first use, nil until then)
        creation = nil,  -- {profession, positive={...}, negative={...}}
        temperature = nil,
        health = 100,

        -- Persistent outfit ID of the NPC zombie representing this character.
        -- nil when the character is active (being played by the player).
        npcId = nil,
    }
end

-- ─── Translations ─────────────────────────────────────────────────────────────
-- Use the game's standard translation loader from media/lua/shared/Translate/*.
local FALLBACK_EN = {
    UI_We_DefaultCharacter = "Character %1",
    UI_We_Switch = "Switch",
    UI_We_NeverUsed = "Not used yet",
    UI_We_SwitchedTo = "Switched to: ",
    UI_We_SetHome = "Set as Safehouse",
    UI_We_HomeSet = "Safehouse set!",
    UI_We_RemoveHome = "Remove Safehouse",
    UI_We_HomeRemoved = "Safehouse removed.",
    UI_We_Status_AtBase = "Inside safehouse  -  switching available",
    UI_We_Status_NoHome = "Right-click any tile to set your safehouse",
    UI_We_Status_TooFar = "Return to your safehouse to switch",
    UI_We_Status_PostDeath = "Post-death switch available",
    UI_We_Switch_noSafehouse = "You must be inside your safehouse to switch!",
    UI_We_NewChar_Title = "New Character",
    UI_We_NPC_AtHome = "[ NPC: at safehouse ]",
    UI_We_NPC_Unspawned = "[ NPC: not yet spawned ]",
    UI_We_Tab_Faction = "Faction",
    UI_We_Tab_Characters = "Characters",
    UI_We_EmptySlot = "[ + New Character ]",
    UI_We_CreateChar = "Create",
    UI_We_Kick = "Dismiss",
    UI_We_Kick_Confirm = "Are you sure you want to dismiss %1?",
    UI_We_Kick_Done = "Character dismissed: %1",
    UI_We_Portrait_Profession = "Profession:",
    UI_We_Portrait_Perks = "Perks:",
    UI_We_Portrait_None = "none",
    UI_We_Moodles = "Moodles",
    UI_We_Inspect = "Inspect",
    UI_We_CheckHealth = "Check health",
    UI_We_Inspect_Done = "Wounds treated: %1",
    UI_We_Inspect_NoWounds = "No untreated wounds: %1",
    UI_We_CheckHealth_Title = "Health check: %1",
    UI_We_CheckHealth_Treat = "Treat wounds?",
    UI_We_Treatment_Title = "Medical: %1",
    UI_We_Treatment_None = "No wounds",
    UI_We_Treatment_Bandage = "Bandage",
    UI_We_Treatment_Disinfect = "Disinfect",
    UI_We_Treatment_Stitch = "Stitch",
    UI_We_Treatment_Splint = "Splint",
    UI_We_Treatment_All = "Treat all",
    UI_We_SlotFallback = "Slot %1",
    UI_We_Health_NoWounds = "No wounds",
    UI_We_Health_Wounds = "Wounds: %1",
    UI_We_Health_Untreated = "Untreated: %1",
    UI_We_Health_Part = "Part #%1",
    UI_We_Health_Level = "Lv.%1",
    UI_We_Health_ActionOk = "OK",
    UI_We_Health_TreatAnyway = "Treat anyway",
    UI_We_Wound_Scratch = "scratch",
    UI_We_Wound_Cut = "cut",
    UI_We_Wound_Laceration = "laceration",
    UI_We_Wound_DeepWound = "deep wound",
    UI_We_Wound_Fracture = "fracture",
    UI_We_Wound_Bleeding = "bleeding",
    UI_We_Wound_Infected = "infected",
    UI_We_Moodle_Hunger = "Hunger",
    UI_We_Moodle_Thirst = "Thirst",
    UI_We_Moodle_Exertion = "Exertion",
    UI_We_Moodle_Fatigue = "Fatigue",
    UI_We_Moodle_Stress = "Stress",
    UI_We_Moodle_Pain = "Pain",
    UI_We_Moodle_Boredom = "Boredom",
    UI_We_Moodle_Unhappy = "Unhappy",
    UI_We_Moodle_Panic = "Panic",
    UI_We_Moodle_Sick = "Sick",
    UI_We_Moodle_Hyperthermia = "Hyperthermia",
    UI_We_Moodle_Hypothermia = "Hypothermia",
    UI_We_Moodle_HeavyLoad = "Heavy Load",
    UI_We_Moodle_Bleeding = "Bleeding",
    UI_We_Moodle_Wet = "Wet",
    UI_We_Moodle_Cold = "Cold",
    UI_We_Moodle_Windchill = "Windchill",
    UI_We_Moodle_Injured = "Injured",
}


function We.getText(key, ...)
    if getText then
        local ok, text = pcall(getText, key, ...)
        if ok and text and text ~= key then
            return text
        end
    end
    local str = FALLBACK_EN[key] or key
    local args = { ... }
    if #args > 0 and type(str) == "string" then
        str = str:gsub("%%(%d+)", function(n)
            return tostring(args[tonumber(n)] or "")
        end)
    end
    return str
end

local function logTranslationProbe(tag)
    local lang = "unknown"
    if Translator and Translator.getLanguage then
        local t = Translator.getLanguage()
        if t and t.name then lang = tostring(t:name()) end
    end
    local raw = "n/a"
    if getText then
        local ok, txt = pcall(getText, "UI_We_Switch")
        if ok then raw = tostring(txt) end
    end
    print("[We][I18N] " .. tostring(tag) .. " lang=" .. tostring(lang) .. " getText(UI_We_Switch)=" .. tostring(raw))
end

print("[We] Shared loaded. Version: " .. We.Version)
logTranslationProbe("shared_load")
