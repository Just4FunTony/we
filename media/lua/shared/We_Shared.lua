-- We: Shared constants and data schema (loaded on client and server)

We = We or {}
We.Version      = "2.0"
We.MAX_SLOTS    = 16
We.MOD_DATA_KEY = "We_Characters"
We.HOME_SWITCH_RADIUS = 30   -- tiles radius around the custom home point

-- Stat keys for save/load, paired with CharacterStat enum values (B42 API)
We.STATS_KEYS = {
    "Hunger", "Thirst", "Fatigue", "Boredom",
    "Stress", "Pain", "Unhappiness",
}

-- Returns a fresh, empty slot table (slot.x == nil means "never saved")
function We.defaultSlot(index)
    return {
        name      = "Character " .. index,
        x         = nil, y = nil, z = nil,
        stats     = {},
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

        -- Persistent outfit ID of the NPC zombie representing this character.
        -- nil when the character is active (being played by the player).
        npcId = nil,
    }
end

-- ─── Translations ─────────────────────────────────────────────────────────────
-- Loaded directly in Lua to bypass B42 file-based translation discovery.

local T = {
    EN = {
        UI_We_Switch              = "Switch",
        UI_We_NeverUsed           = "Not used yet",
        UI_We_SwitchedTo          = "Switched to: ",
        UI_We_SetHome             = "Set as Safehouse",
        UI_We_HomeSet             = "Safehouse set!",
        UI_We_RemoveHome          = "Remove Safehouse",
        UI_We_HomeRemoved         = "Safehouse removed.",
        UI_We_Status_AtBase       = "Inside safehouse  —  switching available",
        UI_We_Status_NoHome       = "Right-click any tile to set your safehouse",
        UI_We_Status_TooFar       = "Return to your safehouse to switch",
        UI_We_Switch_noSafehouse  = "You must be inside your safehouse to switch!",
        UI_We_NewChar_Title       = "New Character",
        UI_We_NPC_AtHome          = "[ NPC: at safehouse ]",
        UI_We_NPC_Unspawned       = "[ NPC: not yet spawned ]",
        UI_We_Tab_Faction         = "Faction",
        UI_We_Tab_Characters      = "Characters",
        UI_We_EmptySlot           = "[ + New Character ]",
        UI_We_CreateChar          = "Create",
    },
    RU = {
        UI_We_Switch              = "Играть",
        UI_We_NeverUsed           = "Ещё не использован",
        UI_We_SwitchedTo          = "Переключено на: ",
        UI_We_SetHome             = "Назначить сейвхаус",
        UI_We_HomeSet             = "Сейвхаус назначен!",
        UI_We_RemoveHome          = "Удалить сейвхаус",
        UI_We_HomeRemoved         = "Сейвхаус удалён.",
        UI_We_Status_AtBase       = "В сейвхаусе  —  переключение доступно",
        UI_We_Status_NoHome       = "Нажмите ПКМ на любой тайл чтобы назначить сейвхаус",
        UI_We_Status_TooFar       = "Вернитесь в сейвхаус для переключения",
        UI_We_Switch_noSafehouse  = "Для переключения нужно быть в сейвхаусе!",
        UI_We_NewChar_Title       = "Новый персонаж",
        UI_We_NPC_AtHome          = "[ NPC: в сейвхаусе ]",
        UI_We_NPC_Unspawned       = "[ NPC: ещё не заспавнен ]",
        UI_We_Tab_Faction         = "Фракция",
        UI_We_Tab_Characters      = "Персонажи",
        UI_We_EmptySlot           = "[ + Новый персонаж ]",
        UI_We_CreateChar          = "Создать",
    },
}

local function detectLang()
    if not Translator then return "EN" end
    local tLang = Translator.getLanguage and Translator.getLanguage()
    if not tLang then return "EN" end
    return tostring(tLang:name())
end

function We.getText(key, ...)
    local lang = detectLang()
    local tbl  = T[lang] or T["EN"]
    local str  = (tbl and tbl[key]) or (T["EN"][key]) or key
    local args = {...}
    if #args > 0 then
        str = str:gsub("%%(%d+)", function(n)
            return tostring(args[tonumber(n)] or "")
        end)
    end
    return str
end

print("[We] Shared loaded. Version: " .. We.Version)
